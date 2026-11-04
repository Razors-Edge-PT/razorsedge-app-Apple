#!/usr/bin/env node
'use strict';

// One-time default of an athlete's leaderboard choice to HIDDEN
// (users/{uid}.leaderboardVisible = false) — for an athlete who asked for
// leaderboard privacy before the in-app switch existed.
//
// Safety contract:
//   * dry-run by default; --apply writes, --verify is read-only;
//   * the target is named on the command line (--uid) and VERIFIED against
//     Firebase Auth with --expect-email before anything is read or written;
//     neither the email nor any training data is ever printed;
//   * it only ever writes a field that is still ABSENT. Once the athlete has
//     saved any choice — including turning visibility back ON — re-running it
//     changes nothing, so their own setting always wins;
//   * apply then withdraws the athlete's public leaderboard projections
//     directly (functions/leaderboard/firestore_store.js withdrawUser — the
//     same routine the leaderboardOnVisibilityWrite trigger runs), so the
//     outcome does not depend on trigger timing. Idempotent;
//   * private data — workouts, rePointDays, showcase, E1RM history — is never
//     touched.
//
// Production rollout (after leaderboardOnVisibilityWrite and the updated
// leaderboard functions are deployed — see the release notes):
//   node scripts/seed_leaderboard_visibility.js --project goodlift-us-storage \
//     --uid <UID> --expect-email <EMAIL>              # dry run: review
//   ... same arguments --apply                         # write + withdraw
//   ... same arguments --verify                        # expect CLEAN

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const FIELD = 'leaderboardVisible';

function usage() {
  return [
    'Seed an athlete\'s leaderboard visibility to hidden (only if never set)',
    '',
    '  node scripts/seed_leaderboard_visibility.js --project goodlift-us-storage \\',
    '    --uid <uid> --expect-email <email> [--apply | --verify]',
  ].join('\n');
}

function parseArgs(argv) {
  const out = { projectId: DEFAULT_PROJECT_ID, uid: null, expectEmail: null, apply: false, verify: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--uid') out.uid = argv[++i];
    else if (arg === '--expect-email') out.expectEmail = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (out.help) return out;
  if (!out.projectId) throw new Error('--project requires a value');
  if (!out.uid || !/^[A-Za-z0-9]{20,128}$/.test(out.uid)) throw new Error('--uid requires a Firebase Auth UID');
  if (!out.expectEmail || !out.expectEmail.includes('@')) throw new Error('--expect-email requires the account email');
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify, not both');
  return out;
}

/** Case- and whitespace-insensitive comparison of an Auth email. */
function emailMatches(actual, expected) {
  const norm = (v) => (typeof v === 'string' ? v.trim().toLowerCase() : '');
  return norm(actual) !== '' && norm(actual) === norm(expected);
}

/**
 * What the seed does for this users/{uid} data (pure):
 *   'missing-user'   no private profile: refuse
 *   'explicit'       a choice is already saved (true or false): leave it
 *   'seed'           absent: set it to false
 */
function planSeed(userData) {
  if (!userData) return 'missing-user';
  if (typeof userData[FIELD] === 'boolean') return 'explicit';
  return 'seed';
}

/**
 * Writes the default only while the field is still absent, re-checked inside
 * a transaction so a choice the athlete saves at the same moment wins.
 * Returns the plan that was applied.
 */
async function applySeed(db, admin, uid) {
  return db.runTransaction(async (tx) => {
    const ref = db.collection('users').doc(uid);
    const snap = await tx.get(ref);
    const plan = planSeed(snap.exists ? snap.data() : null);
    if (plan !== 'seed') return plan;
    tx.set(ref, {
      [FIELD]: false,
      leaderboardVisibilitySource: 'admin-seed',
      leaderboardVisibilitySeededAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return plan;
  });
}

/**
 * Read-only: every public leaderboard projection that still names [uid]
 * (counts and board ids only — no scores or identity are returned).
 */
async function publicTraces(db, uid) {
  const lb = require('../leaderboard/firestore_store');
  const out = { entries: [], ageEntries: [], silver: [], medals: [], sexBoards: [], websiteRows: [] };
  const lbRefs = await db.collection('leaderboards').listDocuments();
  const ageRefs = await db.collection('leaderboardsAge').listDocuments();
  for (const ref of lbRefs) {
    if (lb.isBoardPeriod(ref.id)) {
      if ((await ref.collection('entries').doc(uid).get()).exists) out.entries.push(ref.id);
      const medal = await db.collection('leaderboardMedals').doc(ref.id).get();
      if (medal.exists && lb.medalSnapshotNames(medal.data(), uid)) out.medals.push(ref.id);
    }
  }
  for (const ref of [...lbRefs, ...ageRefs]) {
    const snap = await ref.get();
    const data = snap.exists ? snap.data() : null;
    if (!data) continue;
    if (Array.isArray(data.entries) && data.entries.some((e) => e && e.uid === uid)) out.sexBoards.push(ref.path);
    if (lb.isBoardPeriod(ref.id) && ref.parent.id === 'leaderboardsAge') {
      if ((await ref.collection('entries').doc(uid).get()).exists) out.ageEntries.push(ref.id);
      if (Array.isArray(data.silverUids) && data.silverUids.includes(uid)) out.silver.push(ref.id);
    }
  }
  // The website rows carry the public username only, never a uid.
  const pub = await db.collection('users_public').doc(uid).get();
  const username = pub.exists ? pub.get('username') : null;
  if (typeof username === 'string' && username) {
    for (const snap of (await db.collection('leaderboardPublic').get()).docs) {
      const rows = (snap.data() || {}).entries;
      if (Array.isArray(rows) && rows.some((r) => r && r.username === username)) out.websiteRows.push(snap.id);
    }
  }
  return out;
}

function traceCount(t) {
  return Object.values(t).reduce((n, list) => n + list.length, 0);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return 0;
  }
  const admin = require('firebase-admin');
  admin.initializeApp({ projectId: options.projectId });
  const db = admin.firestore();
  const mode = options.apply ? 'apply' : options.verify ? 'verify' : 'dry-run';
  process.stdout.write(`Leaderboard visibility seed — mode: ${mode}\nProject: ${options.projectId}\nUID: ${options.uid}\n`);

  // 1. Verify the target before reading anything else.
  let user;
  try {
    user = await admin.auth().getUser(options.uid);
  } catch (err) {
    process.stdout.write('Auth account: NOT FOUND — nothing done.\n');
    return 1;
  }
  if (!emailMatches(user.email, options.expectEmail)) {
    process.stdout.write('Auth account: found, but its email does NOT match --expect-email — nothing done.\n');
    return 1;
  }
  process.stdout.write('Auth account: found; email matches.\n');

  const snap = await db.collection('users').doc(options.uid).get();
  const plan = planSeed(snap.exists ? snap.data() : null);
  if (plan === 'missing-user') {
    process.stdout.write('users/{uid}: missing — nothing done.\n');
    return 1;
  }
  const saved = snap.get(FIELD);
  process.stdout.write(`Saved choice: ${plan === 'explicit' ? (saved ? 'VISIBLE (explicit)' : 'HIDDEN (explicit)') : 'none (defaults to visible)'}\n`);

  const before = await publicTraces(db, options.uid);
  process.stdout.write(`Public projections naming this athlete: ${traceCount(before)}\n`);
  for (const [k, list] of Object.entries(before)) if (list.length) process.stdout.write(`  ${k}: ${list.join(', ')}\n`);

  if (options.verify) {
    const hidden = saved === false;
    const clean = !hidden || traceCount(before) === 0;
    process.stdout.write(`\nVerification: ${hidden ? (clean ? 'CLEAN (hidden, no public projections)' : 'NOT CLEAN') : 'athlete has chosen to be visible — nothing to verify'}\n`);
    return clean ? 0 : 1;
  }
  if (!options.apply) {
    process.stdout.write(plan === 'seed'
      ? '\nDry run only. --apply would set leaderboardVisible=false and withdraw the projections above.\n'
      : '\nDry run only. A choice is already saved, so --apply would leave it unchanged.\n');
    return 0;
  }

  const applied = await applySeed(db, admin, options.uid);
  process.stdout.write(`\nSeed: ${applied === 'seed' ? 'leaderboardVisible set to false' : 'left unchanged (a choice is already saved)'}\n`);
  const now = await db.collection('users').doc(options.uid).get();
  if (now.get(FIELD) === false) {
    const lb = require('../leaderboard/firestore_store');
    const res = await lb.withdrawUser(options.uid, Date.now());
    process.stdout.write(`Withdrawn: ${res.entries.length} entries, ${res.ageEntries.length} age entries, ${res.medals.length} medal boards refreshed; website snapshots republished.\n`);
  }
  process.stdout.write('Run again with --verify once the entry-write triggers have settled.\n');
  return 0;
}

module.exports = { parseArgs, emailMatches, planSeed, applySeed, publicTraces, traceCount };

if (require.main === module) {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`\nLeaderboard visibility seed failed: ${err && err.message}\n`);
      process.exit(1);
    });
}
