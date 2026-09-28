#!/usr/bin/env node
'use strict';

// Removes the centrally configured test/demo accounts from every published
// leaderboard period and refreshes affected medal snapshots.
//
// Safety contract:
//   * dry-run by default;
//   * the target UIDs are code-owned and cannot be supplied on the command line;
//   * only leaderboard entry docs and their leaderboard retry-queue docs are
//     deleted — workouts, profiles, V2 projections and private day scores stay;
//   * --verify is read-only and fails if an entry or medal still names a target;
//   * idempotent: applying it again produces zero entry deletions.

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';

function usage() {
  return [
    'Remove excluded accounts from RE Points leaderboards',
    '',
    'Dry run (default):',
    '  node scripts/remove_excluded_leaderboard_accounts.js --project goodlift-us-storage',
    '',
    'Apply:',
    '  node scripts/remove_excluded_leaderboard_accounts.js --project goodlift-us-storage --apply',
    '',
    'Verify:',
    '  node scripts/remove_excluded_leaderboard_accounts.js --project goodlift-us-storage --verify',
  ].join('\n');
}

function parseArgs(argv) {
  const out = { projectId: DEFAULT_PROJECT_ID, apply: false, verify: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!out.projectId) throw new Error('--project requires a value');
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify, not both');
  return out;
}

function excludedMedalUids(snapshot, targets) {
  const found = new Set();
  const categories = snapshot && snapshot.categories;
  if (!categories || typeof categories !== 'object') return [];
  for (const winners of Object.values(categories)) {
    if (!Array.isArray(winners)) continue;
    for (const winner of winners) {
      if (winner && targets.has(winner.uid)) found.add(winner.uid);
    }
  }
  return [...found].sort();
}

async function commitDeletes(db, refs, chunkSize = 400) {
  for (let i = 0; i < refs.length; i += chunkSize) {
    const batch = db.batch();
    for (const ref of refs.slice(i, i + chunkSize)) batch.delete(ref);
    await batch.commit();
  }
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
  const medalsFs = require('../leaderboard/medals_firestore');
  const { EXCLUDED_LEADERBOARD_UIDS } = require('../leaderboard/eligibility');
  const targets = new Set(EXCLUDED_LEADERBOARD_UIDS);
  const mode = options.apply ? 'apply' : options.verify ? 'verify' : 'dry-run';

  process.stdout.write(`Leaderboard exclusions — mode: ${mode}\n`);
  process.stdout.write(`Project: ${options.projectId}\n`);
  process.stdout.write(`Targets: ${EXCLUDED_LEADERBOARD_UIDS.join(', ')}\n\n`);

  const periods = (await db.collection('leaderboards').get()).docs
    .map((d) => d.id)
    .sort();
  const existing = [];
  const medalProblems = [];
  const queued = [];

  for (const periodKey of periods) {
    for (const uid of EXCLUDED_LEADERBOARD_UIDS) {
      const ref = db.collection('leaderboards').doc(periodKey).collection('entries').doc(uid);
      const snap = await ref.get();
      if (snap.exists) existing.push({ periodKey, uid, ref });
    }
    const medal = await db.collection('leaderboardMedals').doc(periodKey).get();
    if (medal.exists) {
      for (const uid of excludedMedalUids(medal.data(), targets)) {
        medalProblems.push({ periodKey, uid });
      }
    }
  }
  for (const uid of EXCLUDED_LEADERBOARD_UIDS) {
    const ref = db.collection('leaderboardRecalcQueue').doc(uid);
    if ((await ref.get()).exists) queued.push({ uid, ref });
  }

  process.stdout.write(`Boards inspected: ${periods.length}\n`);
  process.stdout.write(`Excluded entries present: ${existing.length}\n`);
  for (const x of existing) process.stdout.write(`  ${x.periodKey}/entries/${x.uid}\n`);
  process.stdout.write(`Excluded medal references present: ${medalProblems.length}\n`);
  for (const x of medalProblems) process.stdout.write(`  ${x.periodKey}: ${x.uid}\n`);
  process.stdout.write(`Excluded retry-queue items present: ${queued.length}\n`);
  for (const x of queued) process.stdout.write(`  leaderboardRecalcQueue/${x.uid}\n`);

  if (options.verify) {
    const clean = existing.length === 0 && medalProblems.length === 0 && queued.length === 0;
    process.stdout.write(`\nVerification: ${clean ? 'CLEAN' : 'NOT CLEAN'}\n`);
    return clean ? 0 : 1;
  }
  if (!options.apply) {
    process.stdout.write('\nDry run only. Re-run with --apply to delete these derived entries.\n');
    return 0;
  }

  await commitDeletes(db, [
    ...existing.map((x) => x.ref),
    ...EXCLUDED_LEADERBOARD_UIDS.map((uid) => db.collection('leaderboardRecalcQueue').doc(uid)),
  ]);

  const affectedPeriods = [...new Set([
    ...existing.map((x) => x.periodKey),
    ...medalProblems.map((x) => x.periodKey),
  ])].sort();
  for (const periodKey of affectedPeriods) {
    await medalsFs.refreshMedals(periodKey);
  }

  process.stdout.write(`\nDeleted entries: ${existing.length}\n`);
  process.stdout.write(`Medal boards refreshed: ${affectedPeriods.length}\n`);
  process.stdout.write('Run again with --verify after any entry-write triggers settle.\n');
  return 0;
}

module.exports = { parseArgs, excludedMedalUids, commitDeletes };

if (require.main === module) {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`\nLeaderboard exclusion cleanup failed: ${err && err.message}\n`);
      process.exit(1);
    });
}
