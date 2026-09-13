// Social activity — what somebody did to your content, kept where you can see
// it whether or not a phone alert ever arrived.
//
// ── Why a record, and not just a push ───────────────────────────────────────
// A push notification is a courtesy: it needs permission, it needs a category
// left switched on, it can be swiped away, and it is gone the moment the
// person taps it or the OS decides to age it out. None of that is a good place
// to keep "three people commented on your post". So every interaction writes a
// durable record under the person it is addressed to, and the alert is a view
// OF that record — not the other way round. The unread badge, the Activity
// list, and which phone alerts get cancelled when something is read all come
// from this one collection.
//
//   users/{recipientUid}/socialActivity/{activityId}
//     { type, actorUid, subject, postId?, commentId?,
//       conversationId?, messageId?, emoji?, preview?, tag,
//       read: false, createdAt, occurrence }
//
// ── Identity, replays and read state ────────────────────────────────────────
// The id is derived from the interaction's OCCURRENCE (push_model.js), so:
//
//   * a redelivered Firestore event, a retry, or an out-of-order write finds
//     the record already there and writes nothing — an interaction the person
//     has already read is never resurrected as unread;
//   * a like removed and given again, or a reaction whose emoji is swapped, is
//     the same occurrence and so stays one record and one alert;
//   * two different people reacting are two occurrences and two records.
//
// Records are created and never deleted by the server. Removing a like
// deliberately does NOT delete its record: deleting it would let the next like
// recreate it and alert again, which is precisely the notification spam the
// occurrence is there to prevent. The delivery worker re-checks the live
// interaction before sending, so a removed like that has not been delivered
// yet is dropped rather than announced.
//
// ── Withdrawn and edited interactions ───────────────────────────────────────
// An interaction that no longer exists must stop COUNTING while still being
// remembered, which is what [retireActivity] does:
//
//   { invalidated: true, invalidatedAt, invalidReason }
//
// The id stays, so the same occurrence returning is still a duplicate and
// still cannot alert; `invalidated` takes it out of the badge, the Activity
// list, the delivery worker's pre-send check and any replay. `read` is left
// exactly as it was, so an interaction that comes back — a like taken away
// and given again — comes back as it was rather than as freshly unread; see
// [reviveActivity].
//
// An interaction that CHANGED rather than went away — a comment edited, a
// reaction's emoji swapped — is refreshed in place by [refreshActivity], with
// no new record and so no second alert: the person has already been told.
//
// The ONE field a client may change is `read` (false → true, with `readAt`),
// and only its owner may change it — see firestore.rules. That makes read
// state monotonic: no screen, no replay and no offline write can move an
// interaction back to unread.

'use strict';

const admin = require('firebase-admin');

const P = require('./push_model');

const SUB_ACTIVITY = 'socialActivity';
const COL_USERS = 'users';

/** How much of a comment is kept for the in-app list. */
const PREVIEW_MAX = 140;

/** Deterministic record id for one occurrence. */
function activityIdFor(type, recipientUid, occurrence) {
  const prefix = {
    [P.PushType.DM_REACTION]: 'dr',
    [P.PushType.POST_COMMENT]: 'pc',
    [P.PushType.POST_LIKE]: 'pl',
    [P.PushType.POST_GOOD_LIFT]: 'pg',
  }[type];
  if (!prefix) throw new Error(`no activity record for push type ${type}`);
  return `${prefix}_${P.sha256Hex(`${type}|${recipientUid}|${occurrence}`).slice(0, 40)}`;
}

function activityRef(db, recipientUid, activityId) {
  return db
    .collection(COL_USERS)
    .doc(recipientUid)
    .collection(SUB_ACTIVITY)
    .doc(activityId);
}

/** `post:<id>` / `dm:<convId>` — what reading this interaction means reading. */
function subjectOf({ type, postId, conversationId }) {
  return P.POST_TYPES.has(type) ? `post:${postId}` : `dm:${conversationId}`;
}

function truncatePreview(text) {
  const s = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  if (s.length <= PREVIEW_MAX) return s;
  return `${s.slice(0, PREVIEW_MAX - 1)}…`;
}

/**
 * The record for one interaction. [tag] is the notification tag its alert
 * carries, stored so that reading THIS interaction cancels exactly its alert
 * rather than everything for the post or conversation.
 */
function activityRecord({
  type,
  actorUid,
  occurrence,
  postId,
  commentId,
  conversationId,
  messageId,
  emoji,
  preview,
  tag,
  now,
}) {
  return {
    type,
    actorUid,
    subject: subjectOf({ type, postId, conversationId }),
    occurrence,
    ...(postId ? { postId } : {}),
    ...(commentId ? { commentId } : {}),
    ...(conversationId ? { conversationId } : {}),
    ...(messageId ? { messageId } : {}),
    ...(emoji ? { emoji } : {}),
    ...(preview ? { preview: truncatePreview(preview) } : {}),
    ...(tag ? { tag } : {}),
    read: false,
    // Written explicitly so a withdrawn interaction is a field change rather
    // than a field appearing, and so the field can be queried on.
    invalidated: false,
    createdAt: now || admin.firestore.FieldValue.serverTimestamp(),
  };
}

/**
 * Stop [activityId] counting, without forgetting it happened.
 *
 * Absent record: nothing to do — the interaction was never notifiable (the
 * person's own action, a stranger's, a post that had gone), so there is no
 * badge to correct and no alert to cancel.
 */
async function retireActivity(db, recipientUid, activityId, reason) {
  if (!recipientUid || !activityId) return false;
  const ref = activityRef(db, recipientUid, activityId);
  try {
    await ref.update({
      invalidated: true,
      invalidatedAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(reason ? { invalidReason: String(reason).slice(0, 40) } : {}),
    });
    return true;
  } catch (err) {
    // NOT_FOUND: there is no record for this occurrence. Anything else is a
    // real failure and the caller's trigger should retry.
    if (err && (err.code === 5 || err.code === 'not-found')) return false;
    throw err;
  }
}

/** How many records one subject's cascade will retire in a single pass. */
const RETIRE_PAGE = 300;

/**
 * Retire every record for one subject — `post:<id>` when a post is deleted.
 *
 * One equality filter, so no composite index. Paged, because a popular post
 * can carry more interactions than one batch may hold.
 */
async function retireSubject(db, recipientUid, subject, reason) {
  if (!recipientUid || !subject) return 0;
  const col = db
    .collection(COL_USERS)
    .doc(recipientUid)
    .collection(SUB_ACTIVITY);
  let retired = 0;
  let cursor = null;
  for (;;) {
    let q = col.where('subject', '==', subject).limit(RETIRE_PAGE);
    if (cursor) q = q.startAfter(cursor);
    // eslint-disable-next-line no-await-in-loop
    const page = await q.get();
    if (page.empty) return retired;
    cursor = page.docs[page.docs.length - 1];
    const batch = db.batch();
    let writes = 0;
    for (const doc of page.docs) {
      if (doc.get('invalidated') === true) continue;
      writes += 1;
      batch.update(doc.ref, {
        invalidated: true,
        invalidatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(reason ? { invalidReason: String(reason).slice(0, 40) } : {}),
      });
    }
    // eslint-disable-next-line no-await-in-loop
    if (writes > 0) await batch.commit();
    retired += writes;
    if (page.size < RETIRE_PAGE) return retired;
  }
}

/**
 * Bring one record into line with the interaction it is about — as that
 * interaction is RIGHT NOW, not as some event said it was.
 *
 * ── Why current state, and not the event ────────────────────────────────────
 * Firestore events are at-least-once and are NOT ordered. A creation can be
 * redelivered after the like it announced has been taken back; a deletion can
 * arrive before the creation it undoes; an edit can arrive after a later edit.
 * Deciding from event payloads produced exactly the wrong answers: a replayed
 * creation revived a record for a like that was gone, a late creation made
 * fresh unread activity for a comment nobody could open, and a stale edit put
 * yesterday's words back on the row.
 *
 * So every write goes through here, and here reads the authoritative document
 * inside the transaction:
 *
 *   * the interaction is gone      → the record is retired (never deleted, so
 *                                    the occurrence still cannot re-alert);
 *   * the interaction is there     → the record counts again, with the read
 *                                    state it always had and no new job;
 *   * its wording has changed      → preview/emoji are taken FROM THE LIVE
 *                                    DOCUMENT, so no older value can win.
 *
 * Order of events stops mattering: whichever arrives last, the answer is what
 * is true now, and the same event arriving twice changes nothing the second
 * time.
 *
 * [canonical] is `{ ref, state }` where `state(snapshot)` returns
 * `{ present, preview?, emoji? }` for the live interaction document.
 *
 * Returns 'no-record' | 'retired' | 'revived' | 'refreshed' | 'unchanged'.
 */
async function settleActivity(db, { recipientUid, activityId, canonical, reason }) {
  if (!recipientUid || !activityId || !canonical) return 'no-record';
  const ref = activityRef(db, recipientUid, activityId);
  return db.runTransaction(async (tx) => {
    const record = await tx.get(ref);
    if (!record.exists) return 'no-record';
    const liveSnap = await tx.get(canonical.ref);
    const live = canonical.state(liveSnap) || { present: false };
    const wasInvalid = record.get('invalidated') === true;

    if (!live.present) {
      if (wasInvalid) return 'unchanged';
      tx.update(ref, {
        invalidated: true,
        invalidatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(reason ? { invalidReason: String(reason).slice(0, 40) } : {}),
      });
      return 'retired';
    }

    const patch = {};
    if (wasInvalid) {
      patch.invalidated = false;
      patch.invalidatedAt = admin.firestore.FieldValue.delete();
      patch.invalidReason = admin.firestore.FieldValue.delete();
    }
    if (live.preview !== undefined) {
      const preview = truncatePreview(live.preview);
      if (preview !== (record.get('preview') || '')) patch.preview = preview;
    }
    if (live.emoji !== undefined) {
      const emoji = String(live.emoji).slice(0, 8);
      if (emoji !== record.get('emoji')) patch.emoji = emoji;
    }
    if (Object.keys(patch).length === 0) return 'unchanged';
    tx.update(ref, patch);
    // `read` is never touched here, in either direction: an interaction that
    // comes back comes back as it was, and none of this is a second alert.
    return wasInvalid ? 'revived' : 'refreshed';
  });
}

/**
 * Canonical-state descriptors. Each says where the authoritative document
 * lives and how to read the interaction out of it.
 */
const canonicalComment = (db, postId, commentId, actorUid) => ({
  ref: db.collection('posts').doc(postId).collection('comments').doc(commentId),
  state: (snap) => {
    if (!snap.exists) return { present: false };
    const data = snap.data() || {};
    // Re-authored under somebody else's name is not the same interaction.
    if (actorUid && data.uid && data.uid !== actorUid) return { present: false };
    return { present: true, preview: typeof data.text === 'string' ? data.text : '' };
  },
});

const canonicalPostReaction = (db, postId, kind, actorUid) => ({
  ref: db
    .collection('posts')
    .doc(postId)
    .collection(kind === 'goodLift' ? 'goodLifts' : 'likes')
    .doc(actorUid),
  state: (snap) => ({ present: snap.exists }),
});

const canonicalDmReaction = (db, convId, messageId, actorUid) => ({
  ref: db.collection('conversations').doc(convId).collection('messages').doc(messageId),
  state: (snap) => {
    if (!snap.exists) return { present: false };
    const data = snap.data() || {};
    const reactions = data.reactions && typeof data.reactions === 'object'
      ? data.reactions
      : {};
    const emoji = reactions[actorUid];
    if (typeof emoji !== 'string' || !emoji) return { present: false };
    return { present: true, emoji };
  },
});

module.exports = {
  SUB_ACTIVITY,
  PREVIEW_MAX,
  RETIRE_PAGE,
  activityIdFor,
  activityRef,
  activityRecord,
  subjectOf,
  truncatePreview,
  retireActivity,
  retireSubject,
  settleActivity,
  canonicalComment,
  canonicalPostReaction,
  canonicalDmReaction,
};
