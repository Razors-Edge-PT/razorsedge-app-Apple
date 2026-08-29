// Pure decision core for username reservation.
//
// Separating the DECISION from the Firestore transaction means the rules that
// decide "who may hold this name" are unit-tested without an emulator, and the
// transaction below is a thin, obvious application of them.
//
// The reservation index is `usernames/{sha256(normalized)}` holding
// { uid, username, usernameLower }. Case-insensitive uniqueness is therefore a
// single-document existence check inside a transaction — NOT a query followed
// by a write, which can never be race-free.

'use strict';

const { normalizeUsername, displayUsername, validateUsername } = require('./username_rules');

/** Outcomes the caller must handle. */
const Decision = {
  /** Nothing to do — the caller already holds exactly this name. */
  NOOP: 'noop',
  /** Reserve the new key, release the old one, write the user documents. */
  CLAIM: 'claim',
  /** Someone else holds it. Fail closed. */
  TAKEN: 'taken',
  /** The requested name is not a legal username. */
  INVALID: 'invalid',
};

/**
 * Decides what a username change should do.
 *
 * @param {object} args
 * @param {string} args.callerUid            the authenticated actor
 * @param {string} args.requested            raw, user-typed name
 * @param {string|null} args.currentLower    the caller's stored usernameLower
 * @param {object|null} args.existingReservation  the doc at the NEW index key
 * @param {object|null} args.oldReservation       the doc at the caller's OLD key
 */
function planUsernameChange({
  callerUid,
  requested,
  currentLower,
  existingReservation,
  oldReservation,
}) {
  const validation = validateUsername(requested);
  if (!validation.ok) {
    return { decision: Decision.INVALID, code: validation.code, message: validation.message };
  }

  const username = displayUsername(requested);
  const usernameLower = normalizeUsername(requested);

  if (existingReservation && existingReservation.uid !== callerUid) {
    return { decision: Decision.TAKEN, code: 'taken', usernameLower };
  }

  // Same normalised name AND same display casing, already indexed to us.
  const alreadyExact =
    currentLower === usernameLower &&
    existingReservation &&
    existingReservation.uid === callerUid &&
    existingReservation.username === username;
  if (alreadyExact) {
    return { decision: Decision.NOOP, username, usernameLower };
  }

  // Release the previous reservation only when it is a DIFFERENT key AND it is
  // genuinely ours. Never delete a document some other account holds — that is
  // how a stale client could otherwise free someone else's name.
  const releaseOld =
    !!oldReservation &&
    oldReservation.uid === callerUid &&
    normalizeUsername(oldReservation.usernameLower || '') !== usernameLower;

  return {
    decision: Decision.CLAIM,
    username,
    usernameLower,
    releaseOld,
  };
}

module.exports = { Decision, planUsernameChange };
