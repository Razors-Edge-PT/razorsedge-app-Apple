// Reconciles usernames written OUTSIDE the reservation service back into the
// uniqueness index.
//
// ── Why this exists ─────────────────────────────────────────────────────────
// firestore.rules denies every client identity write except one: the FIRST
// username on an account that has none, until the compatibility cutoff. That
// exception exists only so installed pre-1.7.13 builds can still finish
// signup — those builds stamp username/usernameLower straight onto users and
// users_public and never call profileChangeUsername.
//
// A write that skips the reservation service skips the uniqueness transaction
// with it, so two of those installs can claim the same name at the same
// moment. This trigger is what makes that survivable: every claim is checked
// against usernames/{sha256(normalised)} immediately after it lands, and one
// of exactly three things happens.
//
//   FREE      the reservation is created for the claimant. The legacy write
//             becomes indistinguishable from a callable-made one.
//   OURS      nothing, beyond correcting stored display casing. This is the
//             path every callable-made change takes, so the callable is never
//             fought by its own reconciler.
//   TAKEN     the claimant loses. The account that already holds the
//             reservation keeps the name; the claimant is moved to the first
//             free numbered variant and both of its documents are rewritten.
//
// The loser is moved rather than emptied because an account with no username
// is a broken account: it cannot be searched for, and every historical comment
// and roster row that mentions it resolves to nothing.
//
// ── Convergence ─────────────────────────────────────────────────────────────
// The trigger writes users_public, so it re-fires itself. The second pass sees
// a name that matches its own reservation, takes the OURS path and writes
// nothing, so the loop terminates after exactly one extra invocation. Every
// path is idempotent, which is what makes retry: true safe.
//
// ── Drift ───────────────────────────────────────────────────────────────────
// A reconciliation also releases any OTHER reservation still pointing at this
// uid. That is what cleans up the drift a legacy in-place rename leaves
// behind: the old key would otherwise keep the previous name reserved forever
// with nobody displaying it.

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const {
  normalizeUsername,
  displayUsername,
  usernameIndexKey,
  MAX_LENGTH,
} = require('./username_rules');

const USERNAMES = 'usernames';

/** What a reconciliation should do. */
const Reconciliation = {
  /** The stored name already matches its own reservation. Write nothing. */
  NOOP: 'noop',
  /** The name is free (or already ours). Index it to this account. */
  CLAIM: 'claim',
  /** Another account holds it. Move this account to a free variant. */
  RENAME: 'rename',
};

/**
 * Numbered variants of a name that has been lost to another account, in the
 * order they should be tried.
 *
 * The suffix is appended INSIDE the 22-character limit rather than beyond it,
 * so a variant is always a legal username. The count is bounded because an
 * unbounded search would turn one contested name into an unbounded number of
 * reads inside a transaction.
 */
function usernameVariants(display, count = 8) {
  const base = displayUsername(display);
  const out = [];
  for (let n = 2; out.length < count && n < 1000; n += 1) {
    const suffix = String(n);
    const room = MAX_LENGTH - suffix.length;
    const stem = base.length > room ? base.slice(0, room) : base;
    const candidate = stem + suffix;
    if (!out.includes(candidate)) out.push(candidate);
  }
  return out;
}

/**
 * Pure decision core, so the rules that decide who keeps a contested name are
 * unit-tested without an emulator.
 *
 * @param {object} args
 * @param {string} args.uid               the account whose document changed
 * @param {string} args.storedUsername    the name now on users_public
 * @param {object|null} args.reservation  usernames/{hash(storedUsername)}
 * @param {string[]} args.freeVariants    variants known to be unreserved
 */
function planReconciliation({ uid, storedUsername, reservation, freeVariants }) {
  const lower = normalizeUsername(storedUsername);
  const display = displayUsername(storedUsername);
  if (!lower) return { decision: Reconciliation.NOOP, reason: 'no-username' };

  // A contested marker (written by the backfill for a name several legacy
  // accounts already display) carries no uid, so it belongs to nobody and
  // every claimant loses it.
  const holder = reservation && reservation.uid ? reservation.uid : null;

  if (!reservation || holder === uid) {
    const casingMatches = !!reservation && reservation.username === display;
    if (casingMatches) {
      return {
        decision: Reconciliation.NOOP,
        reason: 'already-ours',
        username: display,
        usernameLower: lower,
      };
    }
    return { decision: Reconciliation.CLAIM, username: display, usernameLower: lower };
  }

  const replacement = freeVariants && freeVariants.length ? freeVariants[0] : null;
  if (!replacement) {
    // Nothing free within the bounded search. Leave the account alone and say
    // so loudly rather than writing a name that is also taken.
    return { decision: Reconciliation.NOOP, reason: 'no-free-variant', heldBy: holder };
  }
  return {
    decision: Reconciliation.RENAME,
    heldBy: holder,
    username: displayUsername(replacement),
    usernameLower: normalizeUsername(replacement),
  };
}

function db() {
  return admin.firestore();
}

function reservationRef(lower) {
  return db().collection(USERNAMES).doc(usernameIndexKey(lower));
}

/** Deletes every reservation owned by this uid other than keepLower. */
function releaseStaleKeys(tx, ownedDocs, keepLower) {
  for (const doc of ownedDocs) {
    const d = doc.data() || {};
    if (normalizeUsername(d.usernameLower || '') === keepLower) continue;
    tx.delete(doc.ref);
  }
}

/**
 * Reconciles ONE account's stored username against the reservation index,
 * inside a single transaction.
 *
 * Returns the plan that was applied, which the trigger logs and the tests
 * assert on.
 */
async function reconcileAccount(uid) {
  return db().runTransaction(async (tx) => {
    const publicRef = db().collection('users_public').doc(uid);
    const userRef = db().collection('users').doc(uid);

    // ALL reads before ANY write — Firestore transaction contract.
    const publicSnap = await tx.get(publicRef);
    const stored = publicSnap.exists ? publicSnap.data() : {};
    const storedUsername = stored.username || stored.usernameLower || '';
    const lower = normalizeUsername(storedUsername);
    if (!lower) return { decision: Reconciliation.NOOP, reason: 'no-username' };

    const reservationSnap = await tx.get(reservationRef(lower));
    const reservation = reservationSnap.exists ? reservationSnap.data() : null;

    // Only read variants when they might be needed — the common case costs one
    // extra document read, not nine.
    let freeVariants = [];
    const holder = reservation && reservation.uid ? reservation.uid : null;
    if (reservation && holder !== uid) {
      const candidates = usernameVariants(storedUsername);
      const snaps = await tx.getAll(
        ...candidates.map((c) => reservationRef(normalizeUsername(c))),
      );
      freeVariants = candidates.filter((c, i) => {
        const s = snaps[i];
        if (!s.exists) return true;
        const d = s.data() || {};
        return d.uid === uid;
      });
    }

    // Drift: reservations still pointing at this uid under a DIFFERENT name.
    const ownedSnap = await tx.get(
      db().collection(USERNAMES).where('uid', '==', uid).limit(20),
    );
    const ownedDocs = ownedSnap.docs;

    const plan = planReconciliation({ uid, storedUsername, reservation, freeVariants });

    if (plan.decision === Reconciliation.NOOP) {
      // A no-op claim must still clear stale keys; a stuck one must not touch
      // anything, because we do not know which key is meant to survive.
      if (plan.reason !== 'no-free-variant') {
        releaseStaleKeys(tx, ownedDocs, plan.usernameLower || lower);
      }
      return plan;
    }

    const now = admin.firestore.FieldValue.serverTimestamp();
    tx.set(
      reservationRef(plan.usernameLower),
      {
        uid,
        username: plan.username,
        usernameLower: plan.usernameLower,
        updatedAt: now,
        reconciled: true,
      },
      { merge: true },
    );
    releaseStaleKeys(tx, ownedDocs, plan.usernameLower);

    if (plan.decision === Reconciliation.RENAME) {
      // Field-level merges only: nothing else on either document is disturbed.
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
    } else if (stored.displayName !== plan.username) {
      // Keep the public displayName mirror in step with the reserved name.
      tx.set(publicRef, { displayName: plan.username }, { merge: true });
    }

    return plan;
  });
}

/**
 * Fires on every users_public write and reconciles the identity it carries.
 *
 * Cheap in the normal case: a rename made through the callable already agrees
 * with its reservation, so the trigger reads a handful of documents and writes
 * nothing. It only does real work for a legacy client claim, which is exactly
 * the write the compatibility window in firestore.rules still permits.
 */
const identityOnPublicProfileWritten = onDocumentWritten(
  { document: 'users_public/{uid}', retry: true },
  async (event) => {
    const uid = event.params.uid;
    const before = event.data && event.data.before && event.data.before.exists
      ? event.data.before.data()
      : null;
    const after = event.data && event.data.after && event.data.after.exists
      ? event.data.after.data()
      : null;
    if (!after) return; // deleted; the backfill owns orphan reservations

    const beforeLower = normalizeUsername(
      (before && (before.username || before.usernameLower)) || '',
    );
    const afterLower = normalizeUsername(after.username || after.usernameLower || '');
    const beforeDisplay = displayUsername((before && before.username) || '');
    const afterDisplay = displayUsername(after.username || '');

    // Nothing identity-shaped changed — do not spend a transaction on it.
    if (beforeLower === afterLower && beforeDisplay === afterDisplay) return;
    if (!afterLower) return;

    try {
      const plan = await reconcileAccount(uid);
      if (plan.decision !== Reconciliation.NOOP) {
        logger.info('username reconciled', {
          uid,
          decision: plan.decision,
          heldBy: plan.heldBy || null,
        });
      }
    } catch (err) {
      logger.error('username reconciliation failed', { uid, error: err && err.message });
      throw err;
    }
  },
);

module.exports = {
  Reconciliation,
  planReconciliation,
  usernameVariants,
  reconcileAccount,
  identityOnPublicProfileWritten,
};
