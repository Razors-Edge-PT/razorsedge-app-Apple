// The buddy relationship callables: send, respond, cancel, remove.
//
// ── Why these are callables and not client writes ──────────────────────────
// Every mutation here touches TWO accounts. Accepting writes the acceptor's
// assignment document AND the sender's; removing a friend must clear both
// sides or the friendship survives in the half that was not cleared, which is
// exactly the bug the legacy client-side remove had. A client can only ever
// write documents the rules let it write, and a batch it commits is not
// something the rules can constrain as a unit — so "both sides or neither" is
// not expressible on the client. It is expressible in a transaction here.
//
// ── Coach impersonation ────────────────────────────────────────────────────
// Every function below derives the acting account from `request.auth.uid` and
// NOTHING else. There is no athleteUid parameter, no "acting as" argument, and
// no branch that reads one. A coach with an athlete selected in the app is
// still their own authenticated account here, so they cannot send, accept,
// decline or remove a friendship on the athlete's behalf — the app's
// `actingAsUid` never reaches this file. That is a structural guarantee rather
// than a check that could be forgotten: the value simply does not exist here.
//
// Super-admin behaviour is deliberately NOT extended into these callables.
// The existing super admin can already read social data through the rules for
// moderation; nothing here lets them fabricate a friendship between two other
// people, and no existing feature needs that.
//
// ── Idempotency and retries ────────────────────────────────────────────────
// The invite document id is the SENDER's uid, so a repeated send cannot create
// a second invite. Accept, decline, cancel and remove all write an absolute
// desired state rather than a delta, so running one twice lands on the same
// result. Every one of them returns success when the work is already done,
// because a retry after a dropped response is the common case and reporting a
// failure would make the client undo a change that actually succeeded.

'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const M = require('./buddy_model');

const CALLABLE_OPTS = { invoker: 'public' };

const db = () => admin.firestore();
const ts = () => admin.firestore.FieldValue.serverTimestamp();
const del = () => admin.firestore.FieldValue.delete();

const assignmentRef = (uid) => db().collection(M.COL_ASSIGNMENTS).doc(uid);
const inviteRef = (receiverUid, senderUid) =>
  db()
    .collection(M.COL_USERS)
    .doc(receiverUid)
    .collection(M.SUB_INVITES)
    .doc(senderUid);
const rateRef = (uid) => db().collection(M.COL_RATE).doc(uid);

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError('unauthenticated', 'Sign in required.');
  }
  return request.auth.uid;
}

function asHttps(err) {
  if (err instanceof M.ValidationError) {
    return new HttpsError('invalid-argument', err.message, { field: err.field });
  }
  return err;
}

function dataOf(snap) {
  return snap && snap.exists ? snap.data() : null;
}

/**
 * A display name for the invite row, read from the PUBLIC profile.
 *
 * Best effort: the invite carries a denormalised name so an old client can
 * render "X added you!" without a second read. A missing name is not a reason
 * to fail the request — the new client resolves identity from the search
 * projection anyway.
 */
async function publicDisplayName(uid) {
  try {
    const snap = await db().collection('users_public').doc(uid).get();
    const d = snap.exists ? snap.data() : null;
    if (!d) return '';
    return (
      (typeof d.username === 'string' && d.username.trim()) ||
      (typeof d.displayName === 'string' && d.displayName.trim()) ||
      (typeof d.fullName === 'string' && d.fullName.trim()) ||
      ''
    );
  } catch (err) {
    logger.warn('[buddies] display name lookup failed for %s: %s', uid, err.message);
    return '';
  }
}

/**
 * Consumes one unit of the sender's request budget.
 *
 * Runs in its OWN transaction, before the relationship transaction, and is not
 * rolled back if the relationship transaction later decides the send was a
 * no-op. Spending a unit on a duplicate send is the safe direction to be wrong
 * in: the alternative is a retry loop that costs nothing and can be run
 * without limit.
 *
 * `socialRateLimits` has no client rules at all, so the counter cannot be
 * read, reset or forged from a device.
 */
async function consumeRateBudget(uid) {
  const ref = rateRef(uid);
  const nowMs = Date.now();
  const outcome = await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const result = M.nextRateState(dataOf(snap), nowMs);
    if (!result.allowed) return result;
    tx.set(ref, { ...result.state, updatedAt: ts() }, { merge: true });
    return result;
  });
  if (!outcome.allowed) {
    throw new HttpsError(
      'resource-exhausted',
      'Too many buddy requests. Try again a little later.',
      { retryAfterMs: outcome.retryAfterMs },
    );
  }
}

/**
 * Writes the two assignment entries that make a friendship, plus the invite's
 * resolution, inside [tx].
 *
 * Both sides are set to `accepted` in the SAME transaction. That is the whole
 * point: a friendship that exists on one side only is either invisible (under
 * the mutual rule) or forgeable (under the old either-side rule), and the only
 * way to never have one is to write both at once.
 */
function writeAcceptance(tx, { senderUid, receiverUid }) {
  tx.set(
    assignmentRef(senderUid),
    {
      athletes: {
        [receiverUid]: { status: M.LinkStatus.ACCEPTED, acceptedAt: ts() },
      },
    },
    { merge: true },
  );
  tx.set(
    assignmentRef(receiverUid),
    {
      athletes: {
        [senderUid]: { status: M.LinkStatus.ACCEPTED, acceptedAt: ts() },
      },
    },
    { merge: true },
  );
  tx.set(
    inviteRef(receiverUid, senderUid),
    {
      status: M.InviteStatus.ACCEPTED,
      fromUid: senderUid,
      buddyUid: receiverUid,
      respondedAt: ts(),
    },
    { merge: true },
  );
}

// ── Send ────────────────────────────────────────────────────────────────────

/**
 * Sends a buddy request from the authenticated account to `targetUid`.
 *
 * Returns `{ state }` where state is one of the [M.Relationship] values, so
 * the caller can render the row without a follow-up read.
 */
const buddySendRequest = onCall(CALLABLE_OPTS, async (request) => {
  const senderUid = requireAuth(request);
  let targetUid;
  try {
    targetUid = M.requireUid((request.data || {}).targetUid, 'targetUid');
    if (targetUid === senderUid) {
      throw new M.ValidationError('You cannot add yourself.', 'targetUid');
    }
  } catch (err) {
    throw asHttps(err);
  }

  // A request to an account that does not exist would leave an invite nobody
  // can ever answer, and answering "does this uid exist?" for arbitrary input
  // is an enumeration primitive of its own — so the target must be a
  // discoverable account, which is precisely what the search projection means.
  const targetPublic = await db().collection('users_public').doc(targetUid).get();
  if (!targetPublic.exists) {
    throw new HttpsError('not-found', 'That account is not available.');
  }

  await consumeRateBudget(senderUid);
  const senderName = await publicDisplayName(senderUid);
  const targetName = await publicDisplayName(targetUid);

  const outcome = await db().runTransaction(async (tx) => {
    const [senderAssign, targetAssign, outgoing, incoming] = await Promise.all([
      tx.get(assignmentRef(senderUid)),
      tx.get(assignmentRef(targetUid)),
      tx.get(inviteRef(targetUid, senderUid)),
      tx.get(inviteRef(senderUid, targetUid)),
    ]);

    const decision = M.resolveSendOutcome({
      senderUid,
      targetUid,
      senderAssignment: dataOf(senderAssign),
      targetAssignment: dataOf(targetAssign),
      outgoingInvite: dataOf(outgoing),
      incomingInvite: dataOf(incoming),
    });

    if (decision === M.SendOutcome.ALREADY_FRIENDS) {
      return M.Relationship.FRIENDS;
    }
    if (decision === M.SendOutcome.ALREADY_REQUESTED) {
      return M.Relationship.REQUESTED;
    }
    if (decision === M.SendOutcome.ACCEPT_REVERSE) {
      // They asked first. Tapping Add is an acceptance in everything but name.
      writeAcceptance(tx, { senderUid: targetUid, receiverUid: senderUid });
      return M.Relationship.FRIENDS;
    }

    tx.set(
      assignmentRef(senderUid),
      {
        athletes: {
          [targetUid]: {
            status: M.LinkStatus.PENDING,
            displayName: targetName,
            addedAt: ts(),
          },
        },
      },
      { merge: true },
    );
    tx.set(inviteRef(targetUid, senderUid), {
      status: M.InviteStatus.PENDING,
      fromUid: senderUid,
      fromDisplayName: senderName,
      buddyUid: targetUid,
      buddyDisplayName: targetName,
      createdAt: ts(),
    });
    return M.Relationship.REQUESTED;
  });

  logger.info('[buddies] send %s -> %s = %s', senderUid, targetUid, outcome);
  return { state: outcome };
});

// ── Respond ─────────────────────────────────────────────────────────────────

/**
 * Accepts or declines a request addressed to the authenticated account.
 *
 * The invite lives at `users/{receiver}/buddyInvites/{sender}`, so the
 * receiver is the DOCUMENT PATH, not an argument. There is therefore no way to
 * answer a request addressed to somebody else: the only invite this call can
 * reach is one under the caller's own uid.
 */
const buddyRespondToRequest = onCall(CALLABLE_OPTS, async (request) => {
  const receiverUid = requireAuth(request);
  const d = request.data || {};
  let fromUid;
  let action;
  try {
    fromUid = M.requireUid(d.fromUid, 'fromUid');
    action = M.requireEnum(d.action, 'action', ['accept', 'decline']);
    if (fromUid === receiverUid) {
      throw new M.ValidationError('You cannot respond to yourself.', 'fromUid');
    }
  } catch (err) {
    throw asHttps(err);
  }

  const outcome = await db().runTransaction(async (tx) => {
    const [invite, receiverAssign, senderAssign] = await Promise.all([
      tx.get(inviteRef(receiverUid, fromUid)),
      tx.get(assignmentRef(receiverUid)),
      tx.get(assignmentRef(fromUid)),
    ]);

    const alreadyFriends = M.areMutualFriends(
      dataOf(receiverAssign),
      dataOf(senderAssign),
      receiverUid,
      fromUid,
    );

    if (action === 'accept') {
      // A retry after a successful accept, or an accept racing a send that
      // already resolved to ACCEPT_REVERSE. Both are success.
      if (alreadyFriends) return M.Relationship.FRIENDS;
      if (!invite.exists) {
        throw new HttpsError('not-found', 'That request is no longer available.');
      }
      const inviteData = dataOf(invite);
      if (inviteData.status === M.InviteStatus.DENIED) {
        throw new HttpsError(
          'failed-precondition',
          'That request was already declined.',
        );
      }
      writeAcceptance(tx, { senderUid: fromUid, receiverUid });
      return M.Relationship.FRIENDS;
    }

    // Decline. Idempotent: with no invite, or one already declined, there is
    // nothing left to do and nothing to report.
    if (alreadyFriends) {
      throw new HttpsError(
        'failed-precondition',
        'You are already buddies. Remove the buddy instead.',
      );
    }
    if (invite.exists) {
      tx.set(
        inviteRef(receiverUid, fromUid),
        {
          status: M.InviteStatus.DENIED,
          fromUid,
          buddyUid: receiverUid,
          respondedAt: ts(),
        },
        { merge: true },
      );
    }
    // Clear the sender's pending entry so a declined request stops showing as
    // outgoing on their device. Only the PENDING entry is removed; an accepted
    // one would mean these two are friends by another route.
    if (M.isPending(M.entryFor(dataOf(senderAssign), receiverUid))) {
      tx.set(
        assignmentRef(fromUid),
        { athletes: { [receiverUid]: del() } },
        { merge: true },
      );
    }
    return M.Relationship.NONE;
  });

  logger.info(
    '[buddies] respond %s <- %s (%s) = %s',
    receiverUid,
    fromUid,
    action,
    outcome,
  );
  return { state: outcome };
});

// ── Cancel ──────────────────────────────────────────────────────────────────

/** Withdraws a request the authenticated account sent. */
const buddyCancelRequest = onCall(CALLABLE_OPTS, async (request) => {
  const senderUid = requireAuth(request);
  let targetUid;
  try {
    targetUid = M.requireUid((request.data || {}).targetUid, 'targetUid');
  } catch (err) {
    throw asHttps(err);
  }

  const outcome = await db().runTransaction(async (tx) => {
    const [invite, senderAssign, targetAssign] = await Promise.all([
      tx.get(inviteRef(targetUid, senderUid)),
      tx.get(assignmentRef(senderUid)),
      tx.get(assignmentRef(targetUid)),
    ]);

    // Cancelling after they accepted must NOT quietly unfriend them — that is
    // a different action with a different confirmation in front of it.
    if (
      M.areMutualFriends(
        dataOf(senderAssign),
        dataOf(targetAssign),
        senderUid,
        targetUid,
      )
    ) {
      return M.Relationship.FRIENDS;
    }

    if (invite.exists) tx.delete(inviteRef(targetUid, senderUid));
    if (M.isPending(M.entryFor(dataOf(senderAssign), targetUid))) {
      tx.set(
        assignmentRef(senderUid),
        { athletes: { [targetUid]: del() } },
        { merge: true },
      );
    }
    return M.Relationship.NONE;
  });

  logger.info('[buddies] cancel %s -> %s = %s', senderUid, targetUid, outcome);
  return { state: outcome };
});

// ── Remove ──────────────────────────────────────────────────────────────────

/**
 * Removes a confirmed friendship, from BOTH sides.
 *
 * The legacy client deleted only the remover's entry. Under the old either-side
 * rule the other entry kept the friendship — and therefore the media access —
 * alive, so "remove buddy" removed the row from one screen and nothing else.
 * Clearing both entries is what actually ends the relationship, and it is why
 * this cannot be a client write.
 *
 * Stale invites in both directions go too, so a removed pair can send a fresh
 * request afterwards instead of finding an old `accepted` invite in the way.
 */
const buddyRemoveFriend = onCall(CALLABLE_OPTS, async (request) => {
  const actorUid = requireAuth(request);
  let buddyUid;
  try {
    buddyUid = M.requireUid((request.data || {}).buddyUid, 'buddyUid');
    if (buddyUid === actorUid) {
      throw new M.ValidationError('You cannot remove yourself.', 'buddyUid');
    }
  } catch (err) {
    throw asHttps(err);
  }

  await db().runTransaction(async (tx) => {
    const [actorAssign, buddyAssign, inviteIn, inviteOut] = await Promise.all([
      tx.get(assignmentRef(actorUid)),
      tx.get(assignmentRef(buddyUid)),
      tx.get(inviteRef(actorUid, buddyUid)),
      tx.get(inviteRef(buddyUid, actorUid)),
    ]);

    if (M.entryFor(dataOf(actorAssign), buddyUid)) {
      tx.set(
        assignmentRef(actorUid),
        { athletes: { [buddyUid]: del() } },
        { merge: true },
      );
    }
    if (M.entryFor(dataOf(buddyAssign), actorUid)) {
      tx.set(
        assignmentRef(buddyUid),
        { athletes: { [actorUid]: del() } },
        { merge: true },
      );
    }
    if (inviteIn.exists) tx.delete(inviteRef(actorUid, buddyUid));
    if (inviteOut.exists) tx.delete(inviteRef(buddyUid, actorUid));
  });

  logger.info('[buddies] remove %s x %s', actorUid, buddyUid);
  return { state: M.Relationship.NONE };
});

module.exports = {
  buddySendRequest,
  buddyRespondToRequest,
  buddyCancelRequest,
  buddyRemoveFriend,
};
