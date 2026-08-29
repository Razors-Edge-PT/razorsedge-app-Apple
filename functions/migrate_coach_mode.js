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
  },
  unresolvedLegacyCoaches: [],
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
    problem('unresolved-scan-failed',
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
    problem('unresolved-scan-failed',
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
      problem('unresolved-entitlement-read-failed', { uid, error: String(err) });
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

  // ── Gate 2: unresolved legacy coaches ────────────────────────────────────
  // Discovered BEFORE any write, so --apply aborts without a partial migration.
  const unresolved = await auditUnresolvedLegacyCoaches();
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
    line('  NOTHING WAS WRITTEN. Rerun with --apply to perform these writes.');
    line('');
  }
  line('  Project ............................. ' + (report.projectId || '(unresolved)'));
  if (report.blocked) {
    line('');
    line('  *** BLOCKED — NO WRITES PERFORMED ***');
    line('  ' + report.blockedReason);
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
  line('  Legacy coaches already entitled ..... ' + report.counts.legacyCoachesAlreadyEntitled);
  line('  Legacy coaches UNRESOLVED ........... ' + report.counts.legacyCoachesUnresolved);
  line('');

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
  _internals: {
    migrateEntitlements,
    migrateApprovedRelationships,
    migrateOneLink,
    auditUnresolvedLegacyCoaches,
    report,
  },
};
