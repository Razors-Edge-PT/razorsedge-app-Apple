#!/usr/bin/env node
// Coach Mode migration / audit.
//
// DRY RUN BY DEFAULT. Nothing is written unless --apply is passed explicitly.
// This script NEVER deletes legacy data and is safe to rerun: every write is
// deterministic and idempotent.
//
//   node functions/migrate_coach_mode.js                 # dry run (default)
//   node functions/migrate_coach_mode.js --apply         # perform writes
//   node functions/migrate_coach_mode.js --apply --claims  # also refresh claims
//   node functions/migrate_coach_mode.js --json          # machine-readable summary
//   node functions/migrate_coach_mode.js --apply --allow-unresolved
//                                                        # only after review
//
// SAFETY GATES on --apply (a dry run is safe anywhere):
//   1. The resolved Firebase project MUST be exactly goodlift-us-storage.
//   2. Every uid that legacy data would authorise as a coach must either be in
//      the reviewed set below or already actively entitled. Unresolved uids
//      are a BLOCKING conflict and are never auto-entitled.
//
// FAIL-CLOSED PREFLIGHT (applies to dry runs too):
//   Every REQUIRED read runs first, in a planning phase that writes nothing.
//   If any of them fails, the audit is marked auditComplete:false and the run
//   exits 4 — a dry run too, because its counts would otherwise be mistaken
//   for findings. Under --apply the abort happens BEFORE the first write, so a
//   read failure can never leave a half-applied migration.
//   --allow-unresolved overrides reviewed DATA only; it never overrides an
//   operational read failure.
//
// EXIT-CODE CONTRACT
//   0  OK               dry run completed, or apply completed with no failures
//   1  UNEXPECTED       unhandled exception
//   2  PROJECT BLOCKED  wrong or unresolved Firebase project (no reads at all)
//   3  UNRESOLVED       legacy coach uids need super-admin review (DATA);
//                       overridable with --allow-unresolved
//   4  INCOMPLETE AUDIT a REQUIRED read failed, so the report is untrustworthy.
//                       Dry runs return this too. --apply performs ZERO writes.
//                       NOT overridable by --allow-unresolved.
//   5  APPLY FAILED     one or more MUTATIONS failed. Does NOT imply zero
//                       writes - Firestore+Auth cannot be globally atomic.
//                       The report names what landed and what did not; every
//                       operation is idempotent, so RERUN.
//
// Credentials: uses GOOGLE_APPLICATION_CREDENTIALS or the ambient service
// account, exactly like the other admin scripts in this folder.
//
// What it does:
//   1. Creates ACTIVE manual entitlements for the existing hard-coded coach
//      accounts, so nobody is locked out when the rules start requiring one.
//   2. Leaves Richard as the hard-coded super admin — he is never given an
//      entitlement and never treated as an ordinary coach applicant.
//   3. Migrates athlete-APPROVED relationships from athleteAssignments into
//      ACTIVE canonical coachAthleteLinks.
//   4. Leaves coachAssignments (super-admin-seeded) completely untouched.
//   5. Reports malformed / conflicting / ambiguous records rather than guessing.

'use strict';

const admin = require('firebase-admin');
const M = require('./coach/coach_mode_model');

// ── Arguments ───────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const APPLY = argv.includes('--apply');
const REFRESH_CLAIMS = argv.includes('--claims');
const AS_JSON = argv.includes('--json');
// Escape hatch for a super admin who has REVIEWED the unresolved legacy coach
// uids and deliberately intends to proceed without granting them Coach Mode.
const ALLOW_UNRESOLVED = argv.includes('--allow-unresolved');

// ── The hard-coded ordinary-coach accounts being migrated ───────────────────
// Mirrors _devCoachUids in lib/main.dart and UserContext.isAdmin, minus the
// super admin. These get a real entitlement so they keep working once the
// hard-coded lists are eventually removed.
const LEGACY_COACH_UIDS = Object.freeze([
  'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
  'jhIB7Yi1whYwPvBSmK27KltJGn23',
  'ejBDKEZPFfQz2Sdzd7BZlNydxZ33', // Adam — primary coach account
  'LGxzlyBNh5f1zclM1F0l6tl6Py82', // Adam Wells — secondary coach account
  'L7YjSMnm7tXD3BwyskmmrgVhKsS2', // Ruby cakes
  'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2', // Google Play reviewer — MUST retain Coach Mode
]);
// REMOVED (reviewed by Richard, 2026-08-29):
//   SMTEVGPH1MXgOgbcBbJFU1HjU8G3 — Adam's obsolete account. The Firebase Auth
//     record and the users/ document are both gone, so it must never receive
//     an entitlement, profile or claim. Adam's live accounts are
//     ejBDKEZP… (primary) and LGxzly… (secondary), both listed above.
//   tlmT17Jlgfe63OYfk8P2IPAs4072 — Aja Cranna-Powell is NOT a coach and is
//     deliberately absent from every list in this repository.

// The legacy free-membership list, kept here only so the report can flag any
// account that is comped but has no coach entitlement (informational).
const LEGACY_FREE_MEMBERSHIP_UIDS = Object.freeze([
  'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard (super admin)
  'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
  'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2', // Google Play Reviewer Account
  'L7YjSMnm7tXD3BwyskmmrgVhKsS2', // Ruby cakes
]);
// Mirrors freeMembershipUids in lib/membership_gate.dart. Adam's secondary
// coach account is deliberately NOT here: it receives a real entitlement
// through the reviewed set above, which is the whole point of Coach Mode —
// a new coach must never need a code change.

// ── Process exit codes ──────────────────────────────────────────────────────
// The CLI contract. main() RETURNS one of these; the wrapper below is the only
// place that calls process.exit, and it always honours the returned code.
//
// A previous version set process.exitCode inside main() and then ended with
// `.then(() => process.exit(0))`, which overrode every blocker and reported
// success for a refused run — so CI and deploy scripts could not detect it.
const EXIT_OK = 0;                 // dry run or apply completed
const EXIT_UNEXPECTED_ERROR = 1;   // unhandled exception
const EXIT_PROJECT_BLOCKED = 2;    // wrong / unresolved Firebase project
const EXIT_UNRESOLVED_COACHES = 3; // unresolved legacy coach uids
// A REQUIRED discovery/preflight read failed, so the audit is incomplete and
// its counts mean nothing. Returned by BOTH dry runs and --apply, and --apply
// aborts before its first write. Deliberately distinct from 3: a data conflict
// (unresolved coach uids) and an operational read failure are different
// conditions and must never be conflated.
const EXIT_INCOMPLETE_AUDIT = 4;
// One or more MUTATIONS failed. A multi-service migration (Firestore + Auth)
// cannot be globally atomic, so this does NOT promise zero prior writes — it
// promises an honest non-zero result naming exactly what succeeded and what
// did not. Every operation is idempotent, so the fix is always: rerun.
const EXIT_APPLY_FAILED = 5;

// ── Project guard ───────────────────────────────────────────────────────────
// The ONLY project this migration may write to. A dry run is safe anywhere;
// --apply and --apply --claims refuse to run unless the resolved project is
// exactly this, so the script can never mutate a staging, personal or
// mistyped project.
const REQUIRED_PROJECT_ID = 'goodlift-us-storage';

function resolveProjectId() {
  return (
    process.env.GCLOUD_PROJECT
    || process.env.GOOGLE_CLOUD_PROJECT
    || process.env.FIREBASE_PROJECT
    || (() => {
      try {
        // eslint-disable-next-line global-require
        const cfg = JSON.parse(process.env.FIREBASE_CONFIG || '{}');
        return cfg.projectId || '';
      } catch (_) {
        return '';
      }
    })()
    || ''
  );
}

/**
 * Pure guard, exported for tests: may this invocation write?
 * Returns { allowed, reason }.
 */
function projectGuard({ apply, projectId }) {
  if (!apply) {
    return { allowed: true, reason: 'dry run — no writes attempted' };
  }
  if (!projectId) {
    return {
      allowed: false,
      reason:
        'REFUSING TO APPLY: the Firebase project could not be resolved. Set '
        + 'GCLOUD_PROJECT=' + REQUIRED_PROJECT_ID + ' (or GOOGLE_CLOUD_PROJECT) '
        + 'and ensure GOOGLE_APPLICATION_CREDENTIALS points at that project.',
    };
  }
  if (projectId !== REQUIRED_PROJECT_ID) {
    return {
      allowed: false,
      reason:
        'REFUSING TO APPLY: resolved project is "' + projectId + '" but this '
        + 'migration may only write to "' + REQUIRED_PROJECT_ID + '".',
    };
  }
  return { allowed: true, reason: 'project verified: ' + projectId };
}

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();
const FV = admin.firestore.FieldValue;

// ── Report ──────────────────────────────────────────────────────────────────
const report = {
  mode: APPLY ? 'APPLY' : 'DRY-RUN',
  startedAt: new Date().toISOString(),
  counts: {
    entitlementsCreated: 0,
    entitlementsAlreadyActive: 0,
    entitlementsSkippedNonActive: 0,
    claimsRefreshed: 0,
    linksCreated: 0,
    linksAlreadyActive: 0,
    linksSkippedConflicting: 0,
    athleteAssignmentDocsScanned: 0,
    approvedRelationshipsFound: 0,
    legacyCoachesUnresolved: 0,
    legacyCoachesAlreadyEntitled: 0,
    reviewedCoachesMissing: 0,
    linksSkippedMissingParty: 0,
    claimsRevoked: 0,
  },
  // false as soon as ANY required read fails. Every count above is then
  // untrustworthy and must not be read as a finding.
  auditComplete: true,
  unresolvedLegacyCoaches: [],
  actions: [],
  // DATA conditions: malformed records, ambiguous approvals, conflicts.
  // These are findings about the data and never block on their own.
  problems: [],
  // OPERATIONAL failures: a required Firestore/Auth read did not complete
  // (expired credentials, permission denied, network). These are NOT findings
  // about the data — they mean we could not look. They always fail closed.
  operationalFailures: [],
  // MUTATION failures. Non-empty ⇒ exit 5 and "rerun required".
  applyFailures: [],
  // True once the mutation phase has BEGUN. Until then the script can prove
  // that nothing was written; afterwards it cannot, so the report must never
  // claim zero writes.
  mutationStarted: false,
  // How many individual writes actually landed. Kept in step with `applied`.
  writesPerformed: 0,
  // What actually got written, so a partial run is honestly reportable.
  applied: {
    entitlements: [],
    profiles: [],
    claims: [],
    links: [],
  },
  notes: [],
};

function act(kind, detail) {
  report.actions.push(Object.assign({ kind }, detail));
}

/** A DATA-level finding. Never blocks by itself. */
function problem(kind, detail) {
  report.problems.push(Object.assign({ kind }, detail));
}

/**
 * A required read did not complete. Marks the whole audit incomplete, which
 * blocks --apply before any write and makes a dry run exit non-zero.
 *
 * This is what makes a failed scan fail CLOSED. Previously a scan error was
 * swallowed into `problem()` and the scan returned an empty array, so an
 * expired credential looked exactly like "there is nothing here": every count
 * read 0, the unresolved-coach gate passed vacuously, and the run reported
 * success.
 */
function operationalFailure(kind, detail) {
  report.auditComplete = false;
  report.operationalFailures.push(Object.assign({ kind }, detail));
}

/**
 * A MUTATION failed. Distinct from both problem() (data findings) and
 * operationalFailure() (we could not read). Forces exit 5.
 */
function applyFailure(kind, detail) {
  report.applyFailures.push(Object.assign({ kind }, detail));
}

/** Records one write that genuinely landed. */
function recordWrite(bucket, uid) {
  report.applied[bucket].push(uid);
  report.writesPerformed += 1;
}

// ── Step 1 (PLAN): entitlements for the reviewed coach accounts ─────────────
//
// PLANNING IS READ-ONLY. Every write moved into the apply* functions below and
// runs only after the ENTIRE preflight has completed successfully, so a read
// failure part-way through can never leave a half-applied migration.

const plan = {
  entitlements: [],   // { uid, identity }
  claims: [],         // { uid, next }
  links: [],          // { coachUid, athleteUid, legacyEntry, coachIdentity, athleteIdentity }
};

// uid -> resolved identity. Populated during PLANNING only.
const identityCache = new Map();
// uids confirmed ABSENT from Firebase Auth (a data fact, not a read failure).
const missingAccounts = new Set();

/**
 * What planning concluded about each reviewed uid entitlement. The mirrored
 * `isCoach` claim follows this: a claim is only ever a routing hint, but it
 * must never contradict a deliberate suspension or revocation.
 */
const entitlementDisposition = {
  alreadyActive: new Set(),      // active at preflight
  willActivate: new Set(),       // planned for activation this run
  suspendedOrRevoked: new Set(), // deliberately withheld - claim must be OFF
};

/**
 * Resolves one account display identity. READ-ONLY, planning phase only.
 *
 * Previously this ran inside applyEntitlements()/applyRelationships(), i.e.
 * AFTER writes had begun, so a credential/permission/network failure during
 * identity resolution could strike mid-mutation. It is now part of the
 * preflight and its failures fail closed like any other required read.
 *
 * `auth/user-not-found` is a DATA fact: the account is gone. It is recorded in
 * `missingAccounts` and does NOT mark the audit incomplete.
 */
async function resolveIdentity(uid) {
  if (identityCache.has(uid)) return identityCache.get(uid);

  let displayName = '';
  let email = '';
  let photoUrl = '';
  let authMissing = false;

  try {
    const rec = await admin.auth().getUser(uid);
    displayName = rec.displayName || '';
    email = rec.email || '';
    photoUrl = rec.photoURL || '';
  } catch (err) {
    if (err && err.code === 'auth/user-not-found') {
      authMissing = true;
      missingAccounts.add(uid);
    } else {
      operationalFailure('identity-auth-lookup-failed', { uid, error: String(err) });
      return null;
    }
  }

  try {
    const snap = await db.collection('users').doc(uid).get();
    const d = snap.exists ? (snap.data() || {}) : {};
    displayName = displayName || String(d.username || d.displayName || d.fullName || '');
    email = email || String(d.email || '');
  } catch (err) {
    // REQUIRED read: a snapshot built from a half-read profile would be wrong,
    // and this used to run mid-mutation.
    operationalFailure('identity-user-doc-read-failed', { uid, error: String(err) });
    return null;
  }

  const identity = { uid, displayName, email, photoUrl, authMissing };
  identityCache.set(uid, identity);
  return identity;
}

// -- Step 1 (PLAN): entitlements for the reviewed coach accounts -------------

async function planEntitlements() {
  for (const uid of LEGACY_COACH_UIDS) {
    if (M.isSuperAdminUid(uid)) {
      // Defensive: the super admin must never be given an entitlement.
      report.notes.push({
        note: 'super admin present in legacy coach list - skipped by design',
        uid,
      });
      continue;
    }

    let snap;
    try {
      snap = await db.collection(M.COL_ENTITLEMENTS).doc(uid).get();
    } catch (err) {
      operationalFailure('entitlement-read-failed', { uid, error: String(err) });
      continue;
    }

    const data = snap.exists ? (snap.data() || {}) : null;
    const coach = data && data.coach ? data.coach : null;
    const state = coach ? coach.state : null;

    if (state === 'active') {
      report.counts.entitlementsAlreadyActive += 1;
      entitlementDisposition.alreadyActive.add(uid);
      act('entitlement-already-active', { uid });
      continue;
    }

    if (state === 'suspended' || state === 'revoked') {
      report.counts.entitlementsSkippedNonActive += 1;
      entitlementDisposition.suspendedOrRevoked.add(uid);
      problem('entitlement-conflict', {
        uid,
        currentState: state,
        detail: 'Account is in the hard-coded coach list but its entitlement '
          + 'was explicitly ' + state + '. Left unchanged - resolve manually.',
      });
      continue;
    }

    // Identity is resolved HERE, in the read phase.
    const identity = await resolveIdentity(uid);
    if (identity === null) continue; // operational failure already recorded

    if (identity.authMissing) {
      // A deleted account must not be planned for an entitlement or profile:
      // that would create a grant nobody can use, attached to a blank identity.
      report.counts.reviewedCoachesMissing += 1;
      problem('reviewed-coach-account-missing', {
        uid,
        detail: 'No Firebase Auth record for this reviewed coach uid - the '
          + 'account no longer exists. No entitlement, profile or claim is '
          + 'planned. Remove it from LEGACY_COACH_UIDS.',
      });
      continue;
    }

    report.counts.entitlementsCreated += 1;
    act('entitlement-create', { uid, state: 'active', source: 'manual_review' });
    entitlementDisposition.willActivate.add(uid);
    plan.entitlements.push({ uid, identity });
  }
}

/**
 * Writes the entitlement AND its coach profile in ONE Firestore transaction,
 * revalidating the entitlement state inside that transaction.
 *
 * Without the revalidation, an entitlement a super admin suspended or revoked
 * between preflight and mutation would be silently resurrected to active.
 * Without the transaction, a profile could exist for an entitlement that never
 * landed.
 */
async function applyEntitlements() {
  for (const item of plan.entitlements) {
    const uid = item.uid;
    try {
      await db.runTransaction(async (tx) => {
        const entRef = db.collection(M.COL_ENTITLEMENTS).doc(uid);
        const snap = await tx.get(entRef);
        const coach = snap.exists ? ((snap.data() || {}).coach || null) : null;
        const state = coach ? coach.state : null;

        // MUTATION-TIME REVALIDATION.
        if (state === 'active') {
          const e = new Error('already active');
          e.__skip = true;
          throw e;
        }
        if (state === 'suspended' || state === 'revoked') {
          const e = new Error('entitlement became ' + state + ' after preflight');
          e.__conflict = state;
          throw e;
        }

        const now = FV.serverTimestamp();
        tx.set(entRef, {
          uid,
          coach: {
            state: 'active',
            source: 'manual_review',
            grantedAt: now,
            grantedBy: M.SUPER_ADMIN_UID,
            approvedAt: now,
            approvedBy: M.SUPER_ADMIN_UID,
            migratedFrom: 'hardcoded_coach_list',
            updatedAt: now,
          },
          updatedAt: now,
        }, { merge: true });

        // Same transaction: entitlement and profile land together or not at all.
        tx.set(
          db.collection(M.COL_PROFILES).doc(uid),
          Object.assign(M.buildCoachProfile(item.identity), { updatedAt: now }),
          { merge: true },
        );
      });

      recordWrite('entitlements', uid);
      recordWrite('profiles', uid);
    } catch (err) {
      if (err && err.__skip) {
        // Became active concurrently - the desired end state, not a failure.
        act('entitlement-already-active-at-write', { uid });
        continue;
      }
      if (err && err.__conflict) {
        applyFailure('entitlement-state-conflict', {
          uid,
          state: err.__conflict,
          detail: 'The entitlement changed to ' + err.__conflict + ' between '
            + 'preflight and mutation and was NOT overwritten. Review the '
            + 'account, then rerun.',
        });
        continue;
      }
      applyFailure('entitlement-write-failed', { uid, error: String(err) });
    }
  }
}

// ── Step 2 (PLAN): mirrored custom claims (opt-in, --claims) ────────────────

async function planClaims() {
  for (const uid of LEGACY_COACH_UIDS) {
    let rec;
    try {
      rec = await admin.auth().getUser(uid);
    } catch (err) {
      // DISTINGUISH the two cases. "This account does not exist" is a DATA
      // condition - the uid is stale, and blocking on it forever would be
      // wrong. Anything else (expired credentials, permission denied, network)
      // means we could not look, and must fail closed.
      if (err && err.code === 'auth/user-not-found') {
        missingAccounts.add(uid);
        problem('claim-refresh-account-missing', {
          uid,
          detail: 'No Firebase Auth record for this uid - the account no '
            + 'longer exists. No claim can be set; review whether it should '
            + 'still be in the reviewed coach list.',
        });
      } else {
        operationalFailure('claim-refresh-lookup-failed', {
          uid, error: String(err),
        });
      }
      continue;
    }

    const existing = rec.customClaims || {};
    const hasClaim = existing.isCoach === true;

    // THE CLAIM FOLLOWS THE ENTITLEMENT.
    //
    // The mirrored `isCoach` claim is only a routing hint, but it must never
    // contradict a deliberate suspension or revocation. Previously this
    // planned `isCoach: true` for every reviewed uid regardless of entitlement
    // state, so a suspended coach could be handed a claim saying otherwise.

    // 1. Deliberately withheld: the claim must be OFF, not ON.
    if (entitlementDisposition.suspendedOrRevoked.has(uid)) {
      if (hasClaim) {
        // Remove ONLY isCoach; every unrelated custom claim survives.
        const next = M.mergeCoachClaim(existing, false);
        report.counts.claimsRevoked += 1;
        act('claim-revoke', {
          uid,
          reason: 'entitlement is suspended or revoked',
          preservedKeys: Object.keys(next),
        });
        plan.claims.push({ uid, next, action: 'revoke' });
      } else {
        act('claim-correctly-absent', { uid });
      }
      continue;
    }

    if (hasClaim) {
      act('claim-already-set', { uid });
      continue;
    }

    // 2. Entitlement already ACTIVE at preflight: grant, but revalidate at
    //    mutation time so a concurrent suspension cannot be contradicted.
    if (entitlementDisposition.alreadyActive.has(uid)) {
      const next = M.mergeCoachClaim(existing, true);
      report.counts.claimsRefreshed += 1;
      act('claim-set', { uid, preservedKeys: Object.keys(existing) });
      plan.claims.push({
        uid, next, action: 'grant', revalidateEntitlement: true,
      });
      continue;
    }

    // 3. Entitlement will be ACTIVATED this run: grant only if that
    //    transaction actually succeeds.
    if (entitlementDisposition.willActivate.has(uid)) {
      const next = M.mergeCoachClaim(existing, true);
      report.counts.claimsRefreshed += 1;
      act('claim-set', {
        uid,
        preservedKeys: Object.keys(existing),
        conditionalOn: 'entitlement activation succeeding',
      });
      plan.claims.push({
        uid, next, action: 'grant', requiresEntitlementWrite: true,
      });
      continue;
    }

    // 4. No confirmed active entitlement (missing account, unreadable
    //    entitlement, super admin, ...): never grant a coach claim.
    act('claim-skipped-no-entitlement', { uid });
  }
}

async function applyClaims() {
  for (const item of plan.claims) {
    // A grant conditional on this run activating the entitlement: skip when
    // that transaction did not succeed. The entitlement failure is already an
    // apply failure, so this is not double-reported.
    if (item.action === 'grant' && item.requiresEntitlementWrite
        && !report.applied.entitlements.includes(item.uid)) {
      act('claim-skipped-entitlement-not-activated', { uid: item.uid });
      continue;
    }

    // A grant against an entitlement that was active at PREFLIGHT: revalidate
    // now, so a suspension landing in between cannot be contradicted by a
    // claim. This read happens after mutation has begun, so a failure here is
    // an APPLY failure (exit 5), never an incomplete-preflight error.
    if (item.action === 'grant' && item.revalidateEntitlement) {
      let stillActive;
      try {
        const snap = await db.collection(M.COL_ENTITLEMENTS).doc(item.uid).get();
        const coach = snap.exists ? ((snap.data() || {}).coach || null) : null;
        stillActive = !!(coach && coach.state === 'active');
      } catch (err) {
        applyFailure('claim-entitlement-revalidation-failed', {
          uid: item.uid,
          error: String(err),
          detail: 'Could not confirm the entitlement is still active before '
            + 'setting the mirrored claim. The claim was NOT set. Rerun.',
        });
        continue;
      }
      if (!stillActive) {
        applyFailure('claim-entitlement-conflict', {
          uid: item.uid,
          detail: 'The entitlement stopped being active between preflight and '
            + 'the claim write, so isCoach was NOT set. Rerun.',
        });
        continue;
      }
    }

    try {
      await admin.auth().setCustomUserClaims(item.uid, item.next);
      recordWrite('claims', item.uid);
    } catch (err) {
      applyFailure('claim-write-failed', {
        uid: item.uid, action: item.action, error: String(err),
      });
    }
  }
}


// ── Step 3 (PLAN): athleteAssignments → canonical coachAthleteLinks ─────────

async function planRelationships() {
  let snap;
  try {
    snap = await db.collection('athleteAssignments').get();
  } catch (err) {
    // REQUIRED scan. An empty result and a failed scan are NOT the same thing.
    operationalFailure('athlete-assignments-scan-failed', { error: String(err) });
    return;
  }

  for (const doc of snap.docs) {
    report.counts.athleteAssignmentDocsScanned += 1;
    const athleteUid = doc.id;
    const data = doc.data() || {};
    const coaches = data.coaches;

    if (coaches === undefined || coaches === null) continue;
    if (typeof coaches !== 'object' || Array.isArray(coaches)) {
      problem('malformed-athlete-assignment', {
        athleteUid,
        detail: 'coaches field is not a map — skipped, not guessed.',
      });
      continue;
    }

    for (const coachUid of Object.keys(coaches)) {
      const entry = coaches[coachUid];

      // Exactly the authorisation rule used by rules and authz.js: ONLY an
      // explicit approved === true migrates. Pending, approved:false and
      // malformed entries are reported, never promoted.
      if (!entry || typeof entry !== 'object') {
        problem('malformed-coach-entry', {
          athleteUid, coachUid,
          detail: 'entry is not an object — not migrated.',
        });
        continue;
      }
      if (entry.approved !== true) {
        if (entry.approved !== false && entry.approved !== undefined) {
          problem('ambiguous-approval', {
            athleteUid, coachUid,
            approved: entry.approved,
            detail: 'approved is neither true nor false — not migrated.',
          });
        }
        continue;
      }
      if (coachUid === athleteUid) {
        problem('self-assignment', {
          athleteUid,
          detail: 'coach and athlete are the same account — not migrated.',
        });
        continue;
      }

      report.counts.approvedRelationshipsFound += 1;
      await planOneLink(coachUid, athleteUid, entry);
    }
  }
}

async function planOneLink(coachUid, athleteUid, legacyEntry) {
  const id = M.linkId(coachUid, athleteUid);
  let existing;
  try {
    existing = await db.collection(M.COL_LINKS).doc(id).get();
  } catch (err) {
    // REQUIRED read: without it we cannot tell a missing link from a
    // deliberately terminated one, and writing blindly would resurrect a
    // relationship the athlete already ended.
    operationalFailure('link-read-failed', {
      coachUid, athleteUid, error: String(err),
    });
    return;
  }

  if (existing.exists) {
    const status = (existing.data() || {}).status;
    if (status === 'active') {
      report.counts.linksAlreadyActive += 1;
      act('link-already-active', { coachUid, athleteUid });
      return;
    }
    // The canonical document already records a DIFFERENT outcome - for example
    // the athlete revoked the coach after the legacy approval was written.
    // Never resurrect it; report and move on. DATA conflict.
    report.counts.linksSkippedConflicting += 1;
    problem('link-conflict', {
      coachUid, athleteUid,
      canonicalStatus: status,
      detail: 'Canonical link already exists with a non-active status; the '
        + 'legacy approval was NOT applied over it.',
    });
    return;
  }

  // Identities resolved in the READ phase and cached on the plan.
  const coachIdentity = await resolveIdentity(coachUid);
  const athleteIdentity = await resolveIdentity(athleteUid);
  if (coachIdentity === null || athleteIdentity === null) return; // op failure

  // A link whose coach or athlete no longer exists would be an ACTIVE
  // relationship with a blank snapshot that nobody can act on or revoke.
  // Report it and skip; never write it.
  const missing = [];
  if (coachIdentity.authMissing) missing.push('coach');
  if (athleteIdentity.authMissing) missing.push('athlete');
  if (missing.length) {
    report.counts.linksSkippedMissingParty += 1;
    problem('link-party-account-missing', {
      coachUid, athleteUid,
      missing,
      detail: 'The ' + missing.join(' and ') + ' account no longer exists in '
        + 'Firebase Auth, so this approved legacy relationship would become a '
        + 'blank active link. Skipped - clean up the stale athleteAssignments '
        + 'entry.',
    });
    return;
  }

  report.counts.linksCreated += 1;
  act('link-create', { coachUid, athleteUid, status: 'active' });
  plan.links.push({
    coachUid, athleteUid, legacyEntry, coachIdentity, athleteIdentity,
  });
}

async function applyRelationships() {
  for (const item of plan.links) {
    const { coachUid, athleteUid, legacyEntry, coachIdentity, athleteIdentity } = item;
    const id = M.linkId(coachUid, athleteUid);
    try {
      const now = FV.serverTimestamp();
      const approvedAt = legacyEntry.approvedAt || null;

      // create() FAILS if the document now exists. Previously this was
      // set(..., merge:false), which would silently overwrite a link created,
      // accepted, declined, revoked or released between preflight and
      // mutation - resurrecting a relationship the athlete had just ended.
      await db.collection(M.COL_LINKS).doc(id).create({
        coachUid,
        athleteUid,
        status: 'active',
        coachSnapshot: M.buildPartySnapshot(coachIdentity),
        athleteSnapshot: M.buildPartySnapshot(athleteIdentity),
        requestedAt: approvedAt,
        requestedBy: coachUid,
        respondedAt: approvedAt,
        respondedBy: athleteUid,
        endedAt: null,
        endedBy: null,
        lastAction: 'migrated_from_athlete_assignments',
        lastActorUid: M.SUPER_ADMIN_UID,
        reason: null,
        migratedFrom: 'athleteAssignments',
        createdAt: now,
        updatedAt: now,
      });
      recordWrite('links', id);
    } catch (err) {
      const code = err && (err.code === 6 || err.code === 'already-exists');
      if (code) {
        applyFailure('link-create-conflict', {
          coachUid, athleteUid,
          detail: 'A coachAthleteLinks document appeared between preflight and '
            + 'mutation and was NOT overwritten. Rerun: the next preflight '
            + 'will read its real status and act accordingly.',
        });
        continue;
      }
      applyFailure('link-write-failed', { coachUid, athleteUid, error: String(err) });
    }
  }
}

// ── Step 4: informational audits (no writes at all) ─────────────────────────

async function auditSeededAssignments() {
  // coachAssignments is LEFT ENTIRELY UNTOUCHED in this pass — counted only so
  // the report shows how much legacy seeding still exists.
  let snap;
  try {
    snap = await db.collection('coachAssignments').get();
  } catch (err) {
    operationalFailure('coach-assignments-scan-failed', { error: String(err) });
    return;
  }
  let coachDocs = 0;
  let seededPairs = 0;
  for (const doc of snap.docs) {
    coachDocs += 1;
    const athletes = (doc.data() || {}).athletes;
    if (athletes && typeof athletes === 'object' && !Array.isArray(athletes)) {
      seededPairs += Object.keys(athletes).length;
    } else if (athletes !== undefined && athletes !== null) {
      problem('malformed-seeded-roster', {
        coachUid: doc.id,
        detail: 'athletes field is not a map — reported only, not modified.',
      });
    }
  }
  report.notes.push({
    note: 'coachAssignments left untouched by design',
    coachDocs,
    seededPairs,
  });
}

/**
 * Discovers EVERY uid that legacy data would authorise as a coach, from BOTH
 * assignment collections, and reports the ones that are neither in the
 * reviewed migration set (LEGACY_COACH_UIDS) nor already actively entitled.
 *
 * These are NEVER auto-entitled. `coachAssignments` was historically
 * self-writable, so any uid discovered there may be an account that simply
 * wrote itself a roster — auto-granting Coach Mode from that data would
 * re-open the very vulnerability this work closed. Each one needs a human
 * decision by the super admin.
 *
 * Because rules now require an ACTIVE entitlement for every ordinary source,
 * an unresolved uid here means a coach who will LOSE access at the rules
 * deploy — so this is treated as a BLOCKING apply conflict.
 */
async function auditUnresolvedLegacyCoaches() {
  const discovered = new Map(); // uid -> Set of source labels

  function note(uid, source) {
    if (!uid || typeof uid !== 'string') return;
    if (!discovered.has(uid)) discovered.set(uid, new Set());
    discovered.get(uid).add(source);
  }

  // Source 1: super-admin-seeded rosters.
  try {
    const snap = await db.collection('coachAssignments').get();
    for (const doc of snap.docs) {
      const athletes = (doc.data() || {}).athletes;
      if (athletes && typeof athletes === 'object' && !Array.isArray(athletes)
          && Object.keys(athletes).length > 0) {
        note(doc.id, 'coachAssignments');
      }
    }
  } catch (err) {
    // REQUIRED discovery scan. A failed scan must NEVER look like an empty
    // one: that is exactly what let the unresolved-coach gate pass vacuously.
    operationalFailure('unresolved-scan-failed',
      { collection: 'coachAssignments', error: String(err) });
  }

  // Source 2: athlete-approved entries.
  try {
    const snap = await db.collection('athleteAssignments').get();
    for (const doc of snap.docs) {
      const coaches = (doc.data() || {}).coaches;
      if (!coaches || typeof coaches !== 'object' || Array.isArray(coaches)) continue;
      for (const coachUid of Object.keys(coaches)) {
        const entry = coaches[coachUid];
        if (entry && typeof entry === 'object' && entry.approved === true) {
          note(coachUid, 'athleteAssignments');
        }
      }
    }
  } catch (err) {
    operationalFailure('unresolved-scan-failed',
      { collection: 'athleteAssignments', error: String(err) });
  }

  const unresolved = [];
  for (const [uid, sources] of discovered) {
    if (M.isSuperAdminUid(uid)) continue;            // hard-coded, never needs one
    if (LEGACY_COACH_UIDS.includes(uid)) continue;   // in the reviewed set

    let active = false;
    try {
      const snap = await db.collection(M.COL_ENTITLEMENTS).doc(uid).get();
      active = M.entitlementIsActive(snap.exists ? snap.data() : null);
    } catch (err) {
      operationalFailure('unresolved-entitlement-read-failed',
        { uid, error: String(err) });
    }
    if (active) {
      report.counts.legacyCoachesAlreadyEntitled += 1;
      continue;
    }

    unresolved.push({ uid, sources: Array.from(sources).sort() });
  }

  report.counts.legacyCoachesUnresolved = unresolved.length;
  report.unresolvedLegacyCoaches = unresolved;

  for (const u of unresolved) {
    problem('unresolved-legacy-coach', {
      uid: u.uid,
      sources: u.sources,
      detail:
        'This uid is authorised by legacy assignment data but has no active '
        + 'entitlement and is not in the reviewed migration set. It is NOT '
        + 'auto-entitled: coachAssignments was historically self-writable, so '
        + 'the data cannot be trusted to confer Coach Mode. Super admin must '
        + 'review the account and, if genuine, grant it explicitly via the '
        + 'Coach Management screen (or the coachModeGrantCoach callable) '
        + 'BEFORE the rules deploy — otherwise this account loses athlete '
        + 'access when active entitlement becomes mandatory.',
    });
  }

  return unresolved;
}

function auditFreeMembershipOverlap() {
  const comped = LEGACY_FREE_MEMBERSHIP_UIDS.filter(
    (uid) => !M.isSuperAdminUid(uid) && !LEGACY_COACH_UIDS.includes(uid),
  );
  if (comped.length) {
    report.notes.push({
      note: 'accounts on freeMembershipUids that are NOT migrated coaches — '
        + 'they keep free membership from the legacy list only',
      uids: comped,
    });
  }
}

// ── Main ────────────────────────────────────────────────────────────────────

async function main() {
  report.notes.push({
    note: 'super admin is hard-coded and never migrated',
    uid: M.SUPER_ADMIN_UID,
  });

  // ── Gate 1: project ──────────────────────────────────────────────────────
  const projectId = resolveProjectId();
  report.projectId = projectId;
  const guard = projectGuard({ apply: APPLY, projectId });
  report.projectGuard = guard;
  if (!guard.allowed) {
    report.blocked = true;
    report.blockedReason = guard.reason;
    report.finishedAt = new Date().toISOString();
    emitReport();
    process.stderr.write('\n' + guard.reason + '\n');
    return EXIT_PROJECT_BLOCKED;
  }

  // ══ PREFLIGHT — every required READ, and not one write ══════════════════
  //
  // The whole plan is built first. Nothing is mutated until the entire
  // preflight has completed successfully, so a read that fails part-way
  // through can never leave a half-applied migration behind.
  const unresolved = await auditUnresolvedLegacyCoaches();
  await planEntitlements();
  if (REFRESH_CLAIMS) {
    await planClaims();
  } else {
    report.notes.push({
      note: 'custom claims not touched — rerun with --claims to refresh them',
    });
  }
  await planRelationships();
  await auditSeededAssignments();
  auditFreeMembershipOverlap();

  // ── Gate 2: audit completeness (operational) ─────────────────────────────
  // Checked BEFORE the unresolved-coach gate: if we could not read, we do not
  // know whether there are unresolved coaches either, so that gate's verdict
  // is meaningless. --allow-unresolved deliberately does NOT reach this gate:
  // it is an override for reviewed DATA, never for a failure to read.
  if (!report.auditComplete) {
    report.blocked = true;
    report.blockedReason =
      'INCOMPLETE AUDIT: ' + report.operationalFailures.length + ' required '
      + 'read(s) did not complete, so every count in this report is '
      + 'untrustworthy — a failed scan is NOT an empty one. '
      + (APPLY
        ? 'NOTHING WAS WRITTEN: --apply aborts before its first write. '
        : '')
      + 'Fix the underlying access problem (expired Application Default '
      + 'Credentials are the usual cause — run "gcloud auth '
      + 'application-default login" — otherwise check IAM read permission and '
      + 'connectivity) and rerun. --allow-unresolved does NOT override this.';
    report.finishedAt = new Date().toISOString();
    emitReport();
    process.stderr.write('\n' + report.blockedReason + '\n');
    return EXIT_INCOMPLETE_AUDIT;
  }

  // ── Gate 3: unresolved legacy coaches (data) ─────────────────────────────
  // Only reachable once the audit is known COMPLETE, so `unresolved` is a real
  // answer rather than the empty list a failed scan used to produce.
  if (APPLY && unresolved.length > 0 && !ALLOW_UNRESOLVED) {
    report.blocked = true;
    report.blockedReason =
      'REFUSING TO APPLY: ' + unresolved.length + ' legacy coach uid(s) are '
      + 'authorised by assignment data but have no active entitlement and are '
      + 'not in the reviewed migration set. Because an active entitlement is '
      + 'now mandatory for every ordinary authorization source, applying now '
      + 'would leave them unable to reach their athletes. Super admin must '
      + 'review each uid listed under unresolvedLegacyCoaches and grant Coach '
      + 'Mode explicitly (Coach Management screen, or coachModeGrantCoach), '
      + 'then rerun. If you have reviewed them and intend to proceed without '
      + 'granting, rerun with --allow-unresolved.';
    report.finishedAt = new Date().toISOString();
    emitReport();
    process.stderr.write('\n' + report.blockedReason + '\n');
    return EXIT_UNRESOLVED_COACHES;
  }

  // == MUTATION - reached only with a COMPLETE preflight and every gate passed
  if (APPLY) {
    // From here on the script can no longer prove that nothing was written.
    report.mutationStarted = true;
    await applyEntitlements();
    if (REFRESH_CLAIMS) await applyClaims();
    await applyRelationships();
  }

  // -- Gate 4: mutation outcome ---------------------------------------------
  // A Firestore+Auth migration cannot be globally atomic, so this does NOT
  // claim zero prior writes. It reports exactly what landed and what did not,
  // and never returns success when any write failed. Every operation is
  // idempotent, so a rerun finishes the job.
  if (report.applyFailures.length > 0) {
    report.blocked = true;
    report.blockedReason = report.writesPerformed > 0
      ? ('APPLY INCOMPLETE: ' + report.applyFailures.length + ' write(s) failed '
        + 'AFTER ' + report.writesPerformed + ' write(s) had already landed '
        + '(entitlements: ' + report.applied.entitlements.length
        + ', profiles: ' + report.applied.profiles.length
        + ', claims: ' + report.applied.claims.length
        + ', links: ' + report.applied.links.length + '). '
        + 'This migration spans Firestore and Auth and cannot be globally '
        + 'atomic, so those earlier writes DID land. Every operation is '
        + 'idempotent, so RERUN once the cause is fixed - the next preflight '
        + 'will skip whatever already succeeded. See applyFailures.')
      : ('APPLY FAILED: ' + report.applyFailures.length + ' write(s) failed and '
        + 'NO writes landed. The preflight completed normally; the failure was '
        + 'in the mutation phase. Every operation is idempotent, so RERUN once '
        + 'the cause is fixed. See applyFailures.');
    report.finishedAt = new Date().toISOString();
    emitReport();
    process.stderr.write("\n" + report.blockedReason + "\n");
    return EXIT_APPLY_FAILED;
  }

  report.finishedAt = new Date().toISOString();
  emitReport();
  return EXIT_OK;
}

function emitReport() {

  if (AS_JSON) {
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
    return;
  }

  const line = (s) => process.stdout.write(s + '\n');
  line('');
  line('══════════════════════════════════════════════════════════════');
  line('  Coach Mode migration — ' + report.mode);
  line('══════════════════════════════════════════════════════════════');
  if (!APPLY) {
    line('  DRY RUN - NOTHING WAS WRITTEN. Rerun with --apply to perform these writes.');
    line('');
  }
  line('  Project ............................. ' + (report.projectId || '(unresolved)'));
  line('  Audit complete ...................... ' + (report.auditComplete ? 'yes' : 'NO'));
  if (report.blocked) {
    line('');
    if (!report.mutationStarted) {
      // Gate 1/2/3: the blocker fired BEFORE the mutation phase, so the script
      // can prove nothing was written.
      line('  *** BLOCKED - NO WRITES PERFORMED ***');
    } else if (report.writesPerformed > 0) {
      // Gate 4 after at least one successful write. Never claim zero.
      line('  *** APPLY INCOMPLETE - PARTIAL WRITES MAY HAVE LANDED ***');
      line('  *** RERUN REQUIRED ***');
    } else {
      // Mutation began but nothing landed. Accurate, and must not imply that
      // the preflight failed.
      line('  *** APPLY FAILED - NO WRITES LANDED (preflight was OK) ***');
      line('  *** RERUN REQUIRED ***');
    }
    if (report.mutationStarted) {
      line('      writes landed: ' + report.writesPerformed
        + '   (entitlements: ' + report.applied.entitlements.length
        + ', profiles: ' + report.applied.profiles.length
        + ', claims: ' + report.applied.claims.length
        + ', links: ' + report.applied.links.length + ')');
      line('      writes failed: ' + report.applyFailures.length);
    }
    line('  ' + report.blockedReason);
    line('');
  }
  line('  Entitlements created ................ ' + report.counts.entitlementsCreated);
  line('  Entitlements already active ......... ' + report.counts.entitlementsAlreadyActive);
  line('  Entitlements skipped (suspended/revoked) ' + report.counts.entitlementsSkippedNonActive);
  line('  Custom claims refreshed ............. ' + report.counts.claimsRefreshed);
  line('  Stale coach claims to REMOVE ........ ' + report.counts.claimsRevoked);
  line('  athleteAssignments docs scanned ..... ' + report.counts.athleteAssignmentDocsScanned);
  line('  Approved relationships found ........ ' + report.counts.approvedRelationshipsFound);
  line('  Canonical links created ............. ' + report.counts.linksCreated);
  line('  Canonical links already active ...... ' + report.counts.linksAlreadyActive);
  line('  Canonical links skipped (conflict) ... ' + report.counts.linksSkippedConflicting);
  line('  Legacy coaches already entitled ..... ' + report.counts.legacyCoachesAlreadyEntitled);
  line('  Legacy coaches UNRESOLVED ........... ' + report.counts.legacyCoachesUnresolved);
  line('  Reviewed coaches MISSING (deleted) .. ' + report.counts.reviewedCoachesMissing);
  line('  Links skipped (missing party) ....... ' + report.counts.linksSkippedMissingParty);
  line('');

  if (report.applyFailures.length) {
    line('  WRITE FAILURES (' + report.applyFailures.length + ') - RERUN REQUIRED');
    for (const f of report.applyFailures) line('    x ' + JSON.stringify(f));
    line('    Applied before/around the failures:');
    line('      entitlements: ' + report.applied.entitlements.length
      + '  profiles: ' + report.applied.profiles.length
      + '  claims: ' + report.applied.claims.length
      + '  links: ' + report.applied.links.length);
    line('    All operations are idempotent - rerunning is safe and completes.');
    line('');
  }

  if (report.operationalFailures.length) {
    line('  OPERATIONAL READ FAILURES (' + report.operationalFailures.length + ')'
      + ' — the audit is INCOMPLETE and its counts mean nothing');
    for (const f of report.operationalFailures) line('    ! ' + JSON.stringify(f));
    line('    A failed scan is NOT an empty scan. Fix access and rerun.');
    line('');
  }

  if (report.unresolvedLegacyCoaches.length) {
    line('  UNRESOLVED LEGACY COACH UIDS — super admin must review each');
    for (const u of report.unresolvedLegacyCoaches) {
      line('    ? ' + u.uid + '  via ' + u.sources.join(' + '));
    }
    line('    These are never auto-entitled: coachAssignments was historically');
    line('    self-writable, so the data cannot be trusted to confer Coach Mode.');
    line('    Grant genuine coaches explicitly, then rerun.');
    line('');
  }

  if (report.notes.length) {
    line('  NOTES');
    for (const n of report.notes) line('    · ' + JSON.stringify(n));
    line('');
  }

  if (report.problems.length) {
    line('  PROBLEMS REQUIRING A HUMAN DECISION (' + report.problems.length + ')');
    for (const p of report.problems) line('    ! ' + JSON.stringify(p));
    line('');
  } else {
    line('  No malformed, conflicting or ambiguous records found.');
    line('');
  }

  line('  Detailed actions (' + report.actions.length + '):');
  for (const a of report.actions) line('    - ' + JSON.stringify(a));
  line('');
  line('  No legacy data was deleted. This script is safe to rerun.');
  line('══════════════════════════════════════════════════════════════');
}

if (require.main === module) {
  main()
    .then((code) => {
      // NEVER a hard-coded 0 here: that is exactly what previously masked a
      // refused run, reporting success for a blocked migration.
      process.exit(typeof code === 'number' ? code : EXIT_OK);
    })
    .catch((err) => {
      process.stderr.write('MIGRATION FAILED: ' + (err && err.stack ? err.stack : err) + '\n');
      process.exit(EXIT_UNEXPECTED_ERROR);
    });
}

module.exports = {
  LEGACY_COACH_UIDS,
  LEGACY_FREE_MEMBERSHIP_UIDS,
  REQUIRED_PROJECT_ID,
  projectGuard,
  resolveProjectId,
  main,
  EXIT_OK,
  EXIT_UNEXPECTED_ERROR,
  EXIT_PROJECT_BLOCKED,
  EXIT_UNRESOLVED_COACHES,
  EXIT_INCOMPLETE_AUDIT,
  EXIT_APPLY_FAILED,
  _internals: {
    planEntitlements,
    applyEntitlements,
    planClaims,
    applyClaims,
    planRelationships,
    planOneLink,
    applyRelationships,
    auditUnresolvedLegacyCoaches,
    operationalFailure,
    applyFailure,
    resolveIdentity,
    identityCache,
    missingAccounts,
    entitlementDisposition,
    plan,
    report,
  },
};
