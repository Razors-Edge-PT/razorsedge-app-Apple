// The friendship model, with no Firestore in it.
//
// ── What the authority is, and why it did not change ───────────────────────
// A confirmed friendship lives in `buddyAssignments/{uid}.athletes.{other}`
// with `status: 'accepted'`. That is not a new decision — it is what
// firestore.rules `isBuddyOf()` and storage.rules `isBuddyOf()` already read
// on every friend access to a post, a story, a lift video and the Storage
// objects behind them. Introducing a second friendship store would have meant
// two authorities disagreeing, with the security rules following the old one.
// So the collection, the document shape and the field names are untouched.
//
// ── The one thing that DID change: mutual, not either-side ─────────────────
// The rules used to accept a friendship claimed by EITHER side:
//
//     buddyAssignments/A.athletes[B].accepted   OR
//     buddyAssignments/B.athletes[A].accepted
//
// and `buddyAssignments/{ownerUid}` lets the owner write their own document.
// Those two facts together meant any signed-in account could write
// `athletes.{victim} = {status:'accepted'}` into its OWN document and
// immediately read the victim's posts, stories, lift videos and Storage media.
// Friendship was self-assertable.
//
// The same OR had a second consequence at the other end: the legacy
// "remove buddy" deleted only the remover's side, so the OTHER side's entry
// kept the friendship — and the media access — alive. Unfriending did not
// unfriend.
//
// Requiring BOTH sides fixes both, because an attacker can only write their
// own side. Acceptance is what writes the second side, and it is written here,
// in one transaction, by the account that actually accepted.
//
// The cost is that a genuinely-accepted legacy pair whose reciprocal write was
// lost now reads as not-friends. That is what
// scripts/symmetrise_buddy_assignments.js exists for, and why it must run
// BEFORE the tightened rules are deployed. See the deployment order.

'use strict';

const COL_ASSIGNMENTS = 'buddyAssignments';
const COL_USERS = 'users';
const SUB_INVITES = 'buddyInvites';
const COL_RATE = 'socialRateLimits';

/** Invite lifecycle. Mirrors what the legacy client already writes. */
const InviteStatus = {
  PENDING: 'pending',
  ACCEPTED: 'accepted',
  DENIED: 'denied',
};

/** `athletes.{uid}.status` values. A declined request removes the entry. */
const LinkStatus = {
  PENDING: 'pending',
  ACCEPTED: 'accepted',
};

/** Relationship as the viewer sees it, and as the People view renders it. */
const Relationship = {
  NONE: 'none',
  REQUESTED: 'requested',
  INCOMING: 'incoming',
  FRIENDS: 'friends',
  SELF: 'self',
};

/** What `buddySendRequest` should actually do. */
const SendOutcome = {
  CREATE: 'create',
  ALREADY_REQUESTED: 'already_requested',
  ALREADY_FRIENDS: 'already_friends',
  ACCEPT_REVERSE: 'accept_reverse',
};

/** At most this many requests may be sent in one rolling window. */
const RATE_LIMIT = 20;
const RATE_WINDOW_MS = 60 * 60 * 1000;

class ValidationError extends Error {
  constructor(message, field) {
    super(message);
    this.name = 'ValidationError';
    this.field = field;
  }
}

/** A required uid argument: a non-empty string of plausible length. */
function requireUid(value, field) {
  if (typeof value !== 'string') {
    throw new ValidationError(`${field} is required.`, field);
  }
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > 128) {
    throw new ValidationError(`${field} is required.`, field);
  }
  return trimmed;
}

function requireEnum(value, field, allowed) {
  if (typeof value !== 'string' || !allowed.includes(value)) {
    throw new ValidationError(
      `${field} must be one of ${allowed.join(', ')}.`,
      field,
    );
  }
  return value;
}

/** The `athletes` map of an assignment document, never null. */
function athletesOf(assignmentData) {
  const athletes = assignmentData && assignmentData.athletes;
  return athletes && typeof athletes === 'object' ? athletes : {};
}

/** The entry [ownerData] holds for [otherUid], or null. */
function entryFor(ownerData, otherUid) {
  const entry = athletesOf(ownerData)[otherUid];
  return entry && typeof entry === 'object' ? entry : null;
}

function isAccepted(entry) {
  return !!entry && entry.status === LinkStatus.ACCEPTED;
}

function isPending(entry) {
  return !!entry && entry.status === LinkStatus.PENDING;
}

/**
 * True when [a] and [b] are confirmed friends.
 *
 * BOTH sides must say so. See the header: either-side acceptance made
 * friendship self-assertable, because an account can always write its own
 * assignment document.
 */
function areMutualFriends(aData, bData, aUid, bUid) {
  return isAccepted(entryFor(aData, bUid)) && isAccepted(entryFor(bData, aUid));
}

/**
 * The relationship [viewerUid] has with [otherUid].
 *
 * `incoming` beats `requested` because a pending invite addressed TO the
 * viewer is the one they can act on; showing "Requested" while the other
 * person is waiting for an answer is the wrong instruction.
 */
function relationshipState({
  viewerUid,
  otherUid,
  viewerAssignment,
  otherAssignment,
  incomingInvite,
}) {
  if (viewerUid === otherUid) return Relationship.SELF;
  if (areMutualFriends(viewerAssignment, otherAssignment, viewerUid, otherUid)) {
    return Relationship.FRIENDS;
  }
  if (incomingInvite && incomingInvite.status === InviteStatus.PENDING) {
    return Relationship.INCOMING;
  }
  if (isPending(entryFor(viewerAssignment, otherUid))) {
    return Relationship.REQUESTED;
  }
  return Relationship.NONE;
}

/**
 * What sending a request from [senderUid] to [targetUid] should do.
 *
 * Every branch other than CREATE exists to make the callable IDEMPOTENT and
 * race-safe rather than to report an error:
 *
 *   ALREADY_FRIENDS   a retry after the accept already landed, or two devices
 *                     both tapping Add. Returning success is correct — the
 *                     caller's intent ("be friends with this person") holds.
 *   ALREADY_REQUESTED a retry of the same send. Must NOT create a second
 *                     invite; the invite id is the sender's uid, so it cannot
 *                     anyway, but the pending entry must not be re-stamped.
 *   ACCEPT_REVERSE    they asked first and the user tapped Add instead of
 *                     Accept. Two crossed pending invites would otherwise sit
 *                     there forever, each side waiting for the other, so the
 *                     send resolves into the acceptance it obviously means.
 */
function resolveSendOutcome({
  senderUid,
  targetUid,
  senderAssignment,
  targetAssignment,
  outgoingInvite,
  incomingInvite,
}) {
  if (senderUid === targetUid) {
    throw new ValidationError('You cannot add yourself.', 'targetUid');
  }
  if (
    areMutualFriends(senderAssignment, targetAssignment, senderUid, targetUid)
  ) {
    return SendOutcome.ALREADY_FRIENDS;
  }
  if (incomingInvite && incomingInvite.status === InviteStatus.PENDING) {
    return SendOutcome.ACCEPT_REVERSE;
  }
  if (outgoingInvite && outgoingInvite.status === InviteStatus.PENDING) {
    return SendOutcome.ALREADY_REQUESTED;
  }
  return SendOutcome.CREATE;
}

/**
 * The next rate-limit state, and whether this attempt is allowed.
 *
 * A fixed window rather than a true sliding log: one small document, one read
 * and one write, and no unbounded array of timestamps to grow. The worst case
 * is 2×[limit] sends across a window boundary, which is a rate limit doing its
 * job, not a hole.
 */
function nextRateState(previous, nowMs, options) {
  const limit = (options && options.limit) || RATE_LIMIT;
  const windowMs = (options && options.windowMs) || RATE_WINDOW_MS;
  const prev =
    previous && typeof previous.windowStart === 'number' ? previous : null;

  if (!prev || nowMs - prev.windowStart >= windowMs) {
    return { allowed: true, state: { windowStart: nowMs, count: 1 } };
  }
  if (prev.count < limit) {
    return {
      allowed: true,
      state: { windowStart: prev.windowStart, count: prev.count + 1 },
    };
  }
  return {
    allowed: false,
    state: prev,
    retryAfterMs: prev.windowStart + windowMs - nowMs,
  };
}

/**
 * Accepted friend uids in [assignmentData].
 *
 * One side only — a caller that needs CONFIRMED friendships must intersect
 * this with the other side, or use [areMutualFriends]. Used by the feed
 * fan-out, which reads both documents.
 */
function acceptedUids(assignmentData) {
  const athletes = athletesOf(assignmentData);
  return Object.keys(athletes).filter((uid) => isAccepted(athletes[uid]));
}

module.exports = {
  COL_ASSIGNMENTS,
  COL_USERS,
  SUB_INVITES,
  COL_RATE,
  InviteStatus,
  LinkStatus,
  Relationship,
  SendOutcome,
  RATE_LIMIT,
  RATE_WINDOW_MS,
  ValidationError,
  requireUid,
  requireEnum,
  athletesOf,
  entryFor,
  isAccepted,
  isPending,
  areMutualFriends,
  relationshipState,
  resolveSendOutcome,
  nextRateState,
  acceptedUids,
};
