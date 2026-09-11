// "Your buddy request was accepted" — a durable, per-account notice.
//
// ── Why this exists ─────────────────────────────────────────────────────────
// The header badge counted only requests addressed TO the viewer. When the
// other person accepted a request the viewer SENT, nothing anywhere said so:
// the friendship simply appeared in a list the viewer had no reason to open.
//
// ── What it is ──────────────────────────────────────────────────────────────
//   users/{senderUid}/socialNotifications/buddyAccepted_{acceptorUid}
//     { type: 'buddyAccepted', otherUid, seen: false, createdAt, acceptedAt,
//       sourceEventId }
//
// One document per PAIR, so an acceptance can never be counted twice however
// many times anything is delivered. It lives under the SENDER — the acceptor
// is the one who acted and needs no telling — and it is written only here,
// by trusted code: firestore.rules denies every client create and delete, and
// lets the owner change nothing but `seen`/`seenAt`. A device therefore cannot
// fabricate an acceptance, or touch anybody else's notices.
//
// ── Where it comes from ─────────────────────────────────────────────────────
// The invite document is the record of who asked whom:
// users/{receiver}/buddyInvites/{sender}. Every acceptance path moves it from
// `pending` to `accepted` — the buddyRespondToRequest callable, a crossed
// request resolved by buddySendRequest, and the batch older installed builds
// still commit directly — so a trigger on that transition covers all three
// without a second code path in each.
//
// The pair must be MUTUALLY accepted when the notice is written (read inside
// the transaction), so a half-written legacy acceptance never announces a
// friendship that does not exist.
//
// ── What it deliberately does NOT do ────────────────────────────────────────
// It never announces an acceptance that happened before it was deployed: an
// invite already `accepted` produces no transition, and an invite that APPEARS
// as accepted with no pending predecessor (scripts, repairs) is ignored too.
// The nine friendships already in production stay exactly as read as they
// are.
//
// ── Retries ─────────────────────────────────────────────────────────────────
// `retry: true` is safe. The notice records the event id that wrote it; a
// redelivery of the same event finds its own id and writes nothing — so a
// notice the athlete has already SEEN is not reset to unread by a retry. A new
// acceptance (after the pair unfriended and asked again) is a new event and
// does notify again, which is correct.
//
// When the friendship ends, the remove path deletes the invites; that delete
// lands here too and removes the now-meaningless notice, unless the pair is
// still friends (a receiver tidying an old invite changes nothing).

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const M = require('./buddy_model');

const SUB_NOTIFICATIONS = 'socialNotifications';

const NotificationType = {
  BUDDY_ACCEPTED: 'buddyAccepted',
};

/** What an invite write means for the sender's notices. */
const InviteChange = {
  ACCEPTED: 'accepted',
  REMOVED: 'removed',
  NONE: 'none',
};

const NoticeAction = {
  CREATE: 'create',
  DELETE: 'delete',
  NONE: 'none',
};

/** Document id of the notice [acceptorUid]'s acceptance produces. */
function acceptedNoticeId(acceptorUid) {
  return `${NotificationType.BUDDY_ACCEPTED}_${acceptorUid}`;
}

/** The notice held by [recipientUid] about [acceptorUid] accepting. */
function acceptedNoticeRef(db, recipientUid, acceptorUid) {
  return db
    .collection(M.COL_USERS)
    .doc(recipientUid)
    .collection(SUB_NOTIFICATIONS)
    .doc(acceptedNoticeId(acceptorUid));
}

/**
 * Classifies one invite write. Only a genuine pending → accepted transition
 * is an acceptance; a deleted invite may end one.
 */
function inviteChange(beforeData, afterData) {
  if (!afterData) return beforeData ? InviteChange.REMOVED : InviteChange.NONE;
  if (
    afterData.status === M.InviteStatus.ACCEPTED &&
    beforeData &&
    beforeData.status === M.InviteStatus.PENDING
  ) {
    return InviteChange.ACCEPTED;
  }
  return InviteChange.NONE;
}

/**
 * What to do with the sender's notice. Pure: every input is read inside the
 * caller's transaction.
 */
function decideNotice({ change, mutual, existing, eventId }) {
  if (change === InviteChange.ACCEPTED) {
    if (!mutual) return { action: NoticeAction.NONE, reason: 'not-mutual' };
    if (existing && eventId && existing.sourceEventId === eventId) {
      return { action: NoticeAction.NONE, reason: 'duplicate-delivery' };
    }
    return { action: NoticeAction.CREATE, reason: 'accepted' };
  }
  if (change === InviteChange.REMOVED) {
    if (mutual) return { action: NoticeAction.NONE, reason: 'still-friends' };
    if (!existing) return { action: NoticeAction.NONE, reason: 'nothing-to-remove' };
    return { action: NoticeAction.DELETE, reason: 'friendship-ended' };
  }
  return { action: NoticeAction.NONE, reason: 'not-an-acceptance' };
}

/** The notice document for [acceptorUid]'s acceptance. */
function acceptedNotice({ acceptorUid, eventId, acceptedAt, now }) {
  return {
    type: NotificationType.BUDDY_ACCEPTED,
    otherUid: acceptorUid,
    seen: false,
    createdAt: now,
    acceptedAt: acceptedAt || now,
    sourceEventId: eventId || null,
  };
}

function dataOf(snap) {
  return snap && snap.exists ? snap.data() : null;
}

/**
 * Applies one invite write to the sender's notices, in ONE transaction.
 *
 * The invite lives at users/{receiverUid}/buddyInvites/{senderUid}: the
 * receiver is the account that accepted, the sender the one who asked.
 */
async function applyInviteWrite(
  db,
  { receiverUid, senderUid, beforeData, afterData, eventId },
) {
  const change = inviteChange(beforeData, afterData);
  if (change === InviteChange.NONE) {
    return { action: NoticeAction.NONE, reason: 'not-an-acceptance' };
  }
  if (!senderUid || !receiverUid || senderUid === receiverUid) {
    return { action: NoticeAction.NONE, reason: 'invalid-pair' };
  }

  const ref = acceptedNoticeRef(db, senderUid, receiverUid);
  return db.runTransaction(async (tx) => {
    const [senderAssign, receiverAssign, notice] = await Promise.all([
      tx.get(db.collection(M.COL_ASSIGNMENTS).doc(senderUid)),
      tx.get(db.collection(M.COL_ASSIGNMENTS).doc(receiverUid)),
      tx.get(ref),
    ]);
    const decision = decideNotice({
      change,
      mutual: M.areMutualFriends(
        dataOf(senderAssign),
        dataOf(receiverAssign),
        senderUid,
        receiverUid,
      ),
      existing: dataOf(notice),
      eventId,
    });

    if (decision.action === NoticeAction.CREATE) {
      const respondedAt = afterData && afterData.respondedAt;
      tx.set(
        ref,
        acceptedNotice({
          acceptorUid: receiverUid,
          eventId,
          acceptedAt:
            respondedAt && typeof respondedAt.toMillis === 'function'
              ? respondedAt
              : null,
          now: admin.firestore.FieldValue.serverTimestamp(),
        }),
      );
    } else if (decision.action === NoticeAction.DELETE) {
      tx.delete(ref);
    }
    return decision;
  });
}

const socialOnBuddyInviteWritten = onDocumentWritten(
  { document: 'users/{receiverUid}/buddyInvites/{senderUid}', retry: true },
  async (event) => {
    const { receiverUid, senderUid } = event.params;
    const before = event.data && event.data.before;
    const after = event.data && event.data.after;
    try {
      const result = await applyInviteWrite(admin.firestore(), {
        receiverUid,
        senderUid,
        beforeData: before && before.exists ? before.data() : null,
        afterData: after && after.exists ? after.data() : null,
        eventId: event.id,
      });
      if (result.action !== NoticeAction.NONE) {
        logger.info(
          '[social] invite %s <- %s: notice %s (%s)',
          receiverUid,
          senderUid,
          result.action,
          result.reason,
        );
      }
    } catch (err) {
      logger.error(
        '[social] invite %s <- %s failed: %s',
        receiverUid,
        senderUid,
        err && err.message,
      );
      throw err;
    }
  },
);

module.exports = {
  SUB_NOTIFICATIONS,
  NotificationType,
  InviteChange,
  NoticeAction,
  acceptedNoticeId,
  acceptedNoticeRef,
  inviteChange,
  decideNotice,
  acceptedNotice,
  applyInviteWrite,
  socialOnBuddyInviteWritten,
};
