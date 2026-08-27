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

// ── The hard-coded ordinary-coach accounts being migrated ───────────────────
// Mirrors _devCoachUids in lib/main.dart and UserContext.isAdmin, minus the
// super admin. These get a real entitlement so they keep working once the
// hard-coded lists are eventually removed.
const LEGACY_COACH_UIDS = Object.freeze([
  'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
  'SMTEVGPH1MXgOgbcBbJFU1HjU8G3', // Adam W
  'jhIB7Yi1whYwPvBSmK27KltJGn23',
  'ejBDKEZPFfQz2Sdzd7BZlNydxZ33', // Adam@razorsedgept
  'L7YjSMnm7tXD3BwyskmmrgVhKsS2', // Ruby cakes
  'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2', // Google Play reviewer
]);

// The legacy free-membership list, kept here only so the report can flag any
// account that is comped but has no coach entitlement (informational).
const LEGACY_FREE_MEMBERSHIP_UIDS = Object.freeze([
  'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard (super admin)
  'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
  'SMTEVGPH1MXgOgbcBbJFU1HjU8G3', // Adam
  'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2', // Google Play Reviewer Account
  'L7YjSMnm7tXD3BwyskmmrgVhKsS2', // Ruby cakes
]);

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
  },
  actions: [],
  problems: [],
  notes: [],
};

function act(kind, detail) {
  report.actions.push(Object.assign({ kind }, detail));
}

function problem(kind, detail) {
  report.problems.push(Object.assign({ kind }, detail));
}

// ── Step 1: entitlements for the hard-coded coaches ─────────────────────────

async function migrateEntitlements() {
  for (const uid of LEGACY_COACH_UIDS) {
    if (M.isSuperAdminUid(uid)) {
      // Defensive: the super admin must never be given an entitlement.
      report.notes.push({
        note: 'super admin present in legacy coach list — skipped by design',
        uid,
      });
      continue;
    }

    let snap;
    try {
      snap = await db.collection(M.COL_ENTITLEMENTS).doc(uid).get();
    } catch (err) {
      problem('entitlement-read-failed', { uid, error: String(err) });
      continue;
    }

    const data = snap.exists ? (snap.data() || {}) : null;
    const coach = data && data.coach ? data.coach : null;
    const state = coach ? coach.state : null;

    if (state === 'active') {
      report.counts.entitlementsAlreadyActive += 1;
      act('entitlement-already-active', { uid });
      continue;
    }

    if (state === 'suspended' || state === 'revoked') {
      // A deliberate later decision must not be undone by a rerun of this
      // script. Report it; never guess.
      report.counts.entitlementsSkippedNonActive += 1;
      problem('entitlement-conflict', {
        uid,
        currentState: state,
        detail: 'Account is in the hard-coded coach list but its entitlement '
          + 'was explicitly ' + state + '. Left unchanged — resolve manually.',
      });
      continue;
    }

    report.counts.entitlementsCreated += 1;
    act('entitlement-create', { uid, state: 'active', source: 'manual_review' });

    if (!APPLY) continue;

    try {
      const now = FV.serverTimestamp();
      await db.collection(M.COL_ENTITLEMENTS).doc(uid).set({
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

      // Invitation-safe profile, so migrated coaches can invite immediately.
      const identity = await identityFor(uid);
      await db.collection(M.COL_PROFILES).doc(uid).set(
        Object.assign(M.buildCoachProfile(identity), { updatedAt: now }),
        { merge: true },
      );
    } catch (err) {
      problem('entitlement-write-failed', { uid, error: String(err) });
    }
  }
}

async function identityFor(uid) {
  let displayName = '';
  let email = '';
  let photoUrl = '';
  try {
    const rec = await admin.auth().getUser(uid);
    displayName = rec.displayName || '';
    email = rec.email || '';
    photoUrl = rec.photoURL || '';
  } catch (err) {
    problem('auth-lookup-failed', { uid, error: String(err) });
  }
  try {
    const snap = await db.collection('users').doc(uid).get();
    const d = snap.exists ? (snap.data() || {}) : {};
    displayName = displayName || String(d.username || d.displayName || d.fullName || '');
    email = email || String(d.email || '');
  } catch (err) {
    problem('user-doc-read-failed', { uid, error: String(err) });
  }
  return { uid, displayName, email, photoUrl };
}

// ── Step 2: refresh mirrored custom claims (opt-in) ──────────────────────────

async function refreshClaims() {
  for (const uid of LEGACY_COACH_UIDS) {
    let rec;
    try {
      rec = await admin.auth().getUser(uid);
    } catch (err) {
      problem('claim-refresh-lookup-failed', { uid, error: String(err) });
      continue;
    }
    const existing = rec.customClaims || {};
    if (existing.isCoach === true) {
      act('claim-already-set', { uid });
      continue;
    }
    // CRITICAL: merge, never replace. Writing a bare { isCoach: true } would
    // destroy every unrelated claim the account carries.
    const next = M.mergeCoachClaim(existing, true);
    report.counts.claimsRefreshed += 1;
    act('claim-set', { uid, preservedKeys: Object.keys(existing) });
    if (!APPLY) continue;
    try {
      await admin.auth().setCustomUserClaims(uid, next);
    } catch (err) {
      problem('claim-write-failed', { uid, error: String(err) });
    }
  }
}

// ── Step 3: athleteAssignments → canonical coachAthleteLinks ────────────────

async function migrateApprovedRelationships() {
  let snap;
  try {
    snap = await db.collection('athleteAssignments').get();
  } catch (err) {
    problem('athlete-assignments-scan-failed', { error: String(err) });
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
      await migrateOneLink(coachUid, athleteUid, entry);
    }
  }
}

async function migrateOneLink(coachUid, athleteUid, legacyEntry) {
  const id = M.linkId(coachUid, athleteUid);
  let existing;
  try {
    existing = await db.collection(M.COL_LINKS).doc(id).get();
  } catch (err) {
    problem('link-read-failed', { coachUid, athleteUid, error: String(err) });
    return;
  }

  if (existing.exists) {
    const status = (existing.data() || {}).status;
    if (status === 'active') {
      report.counts.linksAlreadyActive += 1;
      act('link-already-active', { coachUid, athleteUid });
      return;
    }
    // The canonical document already records a DIFFERENT outcome — for
    // example the athlete revoked the coach after the legacy approval was
    // written. Never resurrect it; report and move on.
    report.counts.linksSkippedConflicting += 1;
    problem('link-conflict', {
      coachUid, athleteUid,
      canonicalStatus: status,
      detail: 'Canonical link already exists with a non-active status; the '
        + 'legacy approval was NOT applied over it.',
    });
    return;
  }

  report.counts.linksCreated += 1;
  act('link-create', { coachUid, athleteUid, status: 'active' });

  if (!APPLY) return;

  try {
    const now = FV.serverTimestamp();
    const [coachIdentity, athleteIdentity] = await Promise.all([
      identityFor(coachUid), identityFor(athleteUid),
    ]);
    const approvedAt = legacyEntry.approvedAt || null;

    // create() would throw on a concurrent write; set with merge:false on a
    // doc we just confirmed absent keeps the migration deterministic and
    // rerunnable (a second run takes the already-active branch above).
    await db.collection(M.COL_LINKS).doc(id).set({
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
  } catch (err) {
    problem('link-write-failed', { coachUid, athleteUid, error: String(err) });
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
    problem('coach-assignments-scan-failed', { error: String(err) });
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

  await migrateEntitlements();
  if (REFRESH_CLAIMS) {
    await refreshClaims();
  } else {
    report.notes.push({
      note: 'custom claims not touched — rerun with --claims to refresh them',
    });
  }
  await migrateApprovedRelationships();
  await auditSeededAssignments();
  auditFreeMembershipOverlap();

  report.finishedAt = new Date().toISOString();

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
    line('  NOTHING WAS WRITTEN. Rerun with --apply to perform these writes.');
    line('');
  }
  line('  Entitlements created ................ ' + report.counts.entitlementsCreated);
  line('  Entitlements already active ......... ' + report.counts.entitlementsAlreadyActive);
  line('  Entitlements skipped (suspended/revoked) ' + report.counts.entitlementsSkippedNonActive);
  line('  Custom claims refreshed ............. ' + report.counts.claimsRefreshed);
  line('  athleteAssignments docs scanned ..... ' + report.counts.athleteAssignmentDocsScanned);
  line('  Approved relationships found ........ ' + report.counts.approvedRelationshipsFound);
  line('  Canonical links created ............. ' + report.counts.linksCreated);
  line('  Canonical links already active ...... ' + report.counts.linksAlreadyActive);
  line('  Canonical links skipped (conflict) ... ' + report.counts.linksSkippedConflicting);
  line('');

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
    .then(() => process.exit(0))
    .catch((err) => {
      process.stderr.write('MIGRATION FAILED: ' + (err && err.stack ? err.stack : err) + '\n');
      process.exit(1);
    });
}

module.exports = {
  LEGACY_COACH_UIDS,
  LEGACY_FREE_MEMBERSHIP_UIDS,
  _internals: { migrateEntitlements, migrateApprovedRelationships, migrateOneLink, report },
};
