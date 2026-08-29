// Central identity backend: the ONLY writer of the username uniqueness index.
//
// Why a callable and not a client write:
//   * Case-insensitive uniqueness needs an atomic read-then-write. A client
//     "query then set" is race-prone by construction — two devices can both
//     read "free" and both write.
//   * Firestore BATCHES queue offline, but TRANSACTIONS do not. Uniqueness can
//     therefore never be guaranteed offline, so this path is deliberately
//     online-only and fails closed (see kUsernameNeedsConnection in the app).
//   * The index key is sha256(normalised name), so a username containing '/',
//     '.' or '..' can never become an unsafe document path.
//
// One transaction atomically:
//   1. reserves usernames/{sha256(new)},
//   2. releases usernames/{sha256(old)} when it is genuinely ours,
//   3. writes username + usernameLower onto users/{uid} and users_public/{uid}.
//
// Firebase Auth displayName is updated AFTER the transaction commits, as an
// explicitly reported best-effort follow-up: Auth is not part of the Firestore
// transaction, so pretending otherwise would be a lie. The response carries
// `authDisplayNameUpdated` so the caller knows exactly what happened.

'use strict';

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const { normalizeUsername, usernameIndexKey } = require('./username_rules');
const { Decision, planUsernameChange } = require('./reservation');

const USERNAMES = 'usernames';

function db() {
  return admin.firestore();
}

function reservationRef(usernameLower) {
  return db().collection(USERNAMES).doc(usernameIndexKey(usernameLower));
}

async function readReservation(tx, usernameLower) {
  if (!usernameLower) return null;
  const snap = await tx.get(reservationRef(usernameLower));
  return snap.exists ? snap.data() : null;
}

/**
 * profileChangeUsername({ username }) → { changed, username, usernameLower,
 *                                         authDisplayNameUpdated }
 *
 * Throws 'already-exists' when another account holds the name (case
 * insensitively) and 'invalid-argument' when the name is not legal.
 */
const profileChangeUsername = onCall({ region: 'us-central1' }, async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'Sign in to change your username.');

  const requested = request.data && request.data.username;
  const requestedLower = normalizeUsername(requested);

  const result = await db().runTransaction(async (tx) => {
    const userRef = db().collection('users').doc(uid);
    const publicRef = db().collection('users_public').doc(uid);

    // ALL reads before ANY write — Firestore transaction contract.
    const userSnap = await tx.get(userRef);
    const publicSnap = await tx.get(publicRef);
    const stored = userSnap.exists ? userSnap.data() : {};
    const publicStored = publicSnap.exists ? publicSnap.data() : {};
    const currentLower =
      normalizeUsername(stored.usernameLower || stored.username || '') ||
      normalizeUsername(publicStored.usernameLower || publicStored.username || '') ||
      null;

    const existingReservation = await readReservation(tx, requestedLower);
    const oldReservation =
      currentLower && currentLower !== requestedLower
        ? await readReservation(tx, currentLower)
        : null;

    const plan = planUsernameChange({
      callerUid: uid,
      requested,
      currentLower,
      existingReservation,
      oldReservation,
    });

    if (plan.decision === Decision.INVALID) {
      throw new HttpsError('invalid-argument', plan.message, { code: plan.code });
    }
    if (plan.decision === Decision.TAKEN) {
      throw new HttpsError('already-exists', 'That username is already taken.', {
        code: 'taken',
      });
    }
    if (plan.decision === Decision.NOOP) {
      return { changed: false, username: plan.username, usernameLower: plan.usernameLower };
    }

    const now = admin.firestore.FieldValue.serverTimestamp();

    tx.set(
      reservationRef(plan.usernameLower),
      {
        uid,
        username: plan.username,
        usernameLower: plan.usernameLower,
        updatedAt: now,
      },
      { merge: true },
    );

    if (plan.releaseOld && currentLower) {
      tx.delete(reservationRef(currentLower));
    }

    // Field-level merges: nothing else on these documents is disturbed.
    tx.set(
      userRef,
      { username: plan.username, usernameLower: plan.usernameLower, updatedAt: now },
      { merge: true },
    );
    tx.set(
      publicRef,
      {
        username: plan.username,
        usernameLower: plan.usernameLower,
        displayName: plan.username,
        updatedAt: now,
      },
      { merge: true },
    );

    return { changed: true, username: plan.username, usernameLower: plan.usernameLower };
  });

  // Best-effort, explicitly reported. A failure here leaves Firestore — the
  // authoritative identity store — correct, and the client resolves usernames
  // by UID through the identity repository, never from Auth.displayName.
  let authDisplayNameUpdated = false;
  if (result.changed) {
    try {
      await admin.auth().updateUser(uid, { displayName: result.username });
      authDisplayNameUpdated = true;
    } catch (err) {
      logger.warn('profileChangeUsername: Auth displayName not updated', {
        uid,
        error: err && err.message,
      });
    }
  }

  return Object.assign({}, result, { authDisplayNameUpdated });
});

module.exports = { profileChangeUsername, reservationRef, USERNAMES };
