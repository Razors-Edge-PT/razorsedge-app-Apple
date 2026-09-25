#!/usr/bin/env node
'use strict';

// Backfill of the RE Points leaderboard for existing athletes: every day
// score (users/{uid}/rePointDays), every monthly entry — the current month and
// every earlier one — and the all-time entry.
//
// It is built FROM the profile V2 projection (showcase/v2 day contributions
// and profileShowcaseV2), exactly as the triggers build it, so run the V2
// backfill first:
//   npm run backfill:showcase-v2 -- --apply
//
// SAFETY CONTRACT
//   * Dry run by default: nothing is written without --apply.
//   * Read-only on workouts, weigh-ins, users/{uid} and users_public.
//   * Idempotent: an athlete's derived documents are recomputed from their
//     sources and replaced, never incremented, so a rerun cannot accumulate.
//     Every document is stamped with the leaderboard formula version.
//   * Resumable: finished athletes are recorded in
//     migrations/leaderboardBackfill/progress/{uid} and skipped next time
//     (--force redoes them); the account listing is paged and its cursor is
//     checkpointed in migrations/leaderboardBackfill (--restart ignores it).
//   * Bounded: --concurrency athletes at a time (default 4, max 8).
//   * Per-athlete failures are reported and do not stop the run.
//
// Athletes without a profile V2 are skipped under --apply (counted as
// needsV2); the dry run computes their V2 in memory so its totals are real.

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const PROGRESS_DOC = 'migrations/leaderboardBackfill';

function usage() {
  return [
    'RE Points leaderboard backfill',
    '',
    'Dry run (default — writes nothing):',
    '  node scripts/backfill_leaderboard.js --project goodlift-us-storage',
    '',
    'One athlete:',
    '  node scripts/backfill_leaderboard.js --project goodlift-us-storage --uid <uid>',
    '',
    'Apply (resumable; rerun the same command after an interruption):',
    '  node scripts/backfill_leaderboard.js --project goodlift-us-storage --apply',
    '',
    'Options: --concurrency N (1-8, default 4)  --page N (accounts per page, default 200)',
    '         --limit N (stop after N accounts)  --force (redo finished athletes)',
    '         --restart (ignore the saved listing cursor)',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    uid: null,
    apply: false,
    force: false,
    restart: false,
    limit: 0,
    concurrency: 4,
    page: 200,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--force') out.force = true;
    else if (arg === '--restart') out.restart = true;
    else if (arg === '--uid') out.uid = argv[++i];
    else if (arg === '--limit') out.limit = Number(argv[++i]) || 0;
    else if (arg === '--concurrency') out.concurrency = Number(argv[++i]);
    else if (arg === '--page') out.page = Number(argv[++i]);
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!out.projectId) throw new Error('--project requires a value');
  if (!Number.isInteger(out.concurrency) || out.concurrency < 1 || out.concurrency > 8) {
    throw new Error('--concurrency must be 1..8');
  }
  if (!Number.isInteger(out.page) || out.page < 1 || out.page > 1000) {
    throw new Error('--page must be 1..1000');
  }
  return out;
}

/** Runs [worker] over [items] with at most [limit] in flight. */
async function pool(items, limit, worker) {
  let next = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const i = next;
      next += 1;
      await worker(items[i]);
    }
  });
  await Promise.all(runners);
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

  const showcaseFs = require('../showcase/firestore_store');
  const { dryRunUser } = require('../showcase/rebuild_dry_run');
  const { isBuiltV2 } = require('../showcase/store_v2');

  const mode = options.apply ? 'apply' : 'dry-run';
  process.stdout.write(`RE Points leaderboard backfill — mode: ${mode}\n`);
  process.stdout.write(`Project: ${options.projectId}\n\n`);

  const progressRoot = db.doc(PROGRESS_DOC);
  const progressCol = progressRoot.collection('progress');
  const counts = {
    considered: 0,
    skippedAlreadyDone: 0,
    processed: 0,
    needsV2: 0,
    withMonthlyEntries: 0,
    withAllTimeEntry: 0,
    dayDocs: 0,
    monthEntries: 0,
    applied: 0,
    errors: 0,
  };
  const failures = [];
  const samples = [];

  async function dryRun(uid) {
    // Everything computed in memory — the same job and reducers — from
    // read-only sources.
    const res = await dryRunUser(db, uid, showcaseFs.bodyweightResolver);
    const v2StateSnap = await showcaseFs.stateV2Ref(uid).get();
    if (!v2StateSnap.exists) counts.needsV2 += 1;
    counts.dayDocs += res.dayScores.length;
    const months = [...res.entries.keys()].filter((k) => !k.startsWith('all_time/'));
    counts.monthEntries += months.length;
    if (months.length) counts.withMonthlyEntries += 1;
    const at = res.entries.get(`all_time/${uid}`);
    if (at) {
      counts.withAllTimeEntry += 1;
      if (samples.length < 5) {
        samples.push(`${uid} all-time ${(at.totalPointsUnits / 10000).toFixed(2)} ` +
          `(${Object.entries(at.categoryBestUnits).map(([k, v]) => `${k}=${(v / 10000).toFixed(2)}`).join(' ')})`);
      }
    }
  }

  async function apply(uid) {
    // Built FROM the corrected profile V2: an athlete whose V2 is not built
    // (or stale) is left for the showcase backfill, which continues into the
    // leaderboard itself.
    const state = (await showcaseFs.stateV2Ref(uid).get()).data() || null;
    const pub = (await db.collection('users_public').doc(uid).get()).data() || {};
    if (!isBuiltV2(state, pub.profileShowcaseV2 || null)) {
      counts.needsV2 += 1;
      return false;
    }
    await showcaseFs.requestRebuildFor(uid, { mode: 'leaderboard', reason: 'backfill' });
    const run = await showcaseFs.runRebuildFor(uid);
    if (!run.job || run.job.status !== 'done') {
      throw new Error(`job ${run.job && run.job.status}: ${run.job && run.job.lastError}`);
    }
    const days = await db.collection('users').doc(uid).collection('rePointDays').select().get();
    counts.dayDocs += days.size;
    const at = await db.collection('leaderboards').doc('all_time').collection('entries').doc(uid).get();
    if (at.exists) counts.withAllTimeEntry += 1;
    counts.applied += 1;
    return true;
  }

  async function processUid(uid) {
    counts.considered += 1;
    try {
      if (options.apply && !options.force) {
        const done = await progressCol.doc(uid).get();
        if (done.exists && (done.data() || {}).status === 'done') {
          counts.skippedAlreadyDone += 1;
          return;
        }
      }
      counts.processed += 1;
      if (!options.apply) {
        await dryRun(uid);
        return;
      }
      if (await apply(uid)) {
        await progressCol.doc(uid).set({
          status: 'done',
          at: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    } catch (err) {
      counts.errors += 1;
      if (failures.length < 100) failures.push({ uid, error: String(err && err.message) });
    }
  }

  if (options.uid) {
    await processUid(options.uid);
  } else {
    let cursor = null;
    if (options.apply && !options.restart) {
      const root = await progressRoot.get();
      cursor = root.exists ? (root.data() || {}).lastUid || null : null;
      if (cursor) process.stdout.write(`Resuming after ${cursor}\n`);
    }
    for (;;) {
      let q = db
        .collection('users')
        .orderBy(admin.firestore.FieldPath.documentId())
        .select()
        .limit(options.page);
      if (cursor) q = q.startAfter(cursor);
      const page = await q.get();
      if (page.empty) break;
      let uids = page.docs.map((d) => d.id);
      if (options.limit > 0) uids = uids.slice(0, Math.max(0, options.limit - counts.considered));
      await pool(uids, options.concurrency, processUid);
      cursor = page.docs[page.docs.length - 1].id;
      if (options.apply) await progressRoot.set({ lastUid: cursor }, { merge: true });
      process.stdout.write(`  … ${counts.considered} accounts\n`);
      if (page.size < options.page) break;
      if (options.limit > 0 && counts.considered >= options.limit) break;
    }
    if (options.apply && !(options.limit > 0)) {
      // A complete pass: the next run starts from the beginning again.
      await progressRoot.set({ lastUid: null, completedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
    }
  }

  process.stdout.write('\nCOUNTS\n');
  for (const [k, v] of Object.entries(counts)) process.stdout.write(`  ${k}: ${v}\n`);
  if (samples.length) {
    process.stdout.write('\nSAMPLES\n');
    for (const x of samples) process.stdout.write(`  ${x}\n`);
  }
  if (failures.length) {
    process.stdout.write('\nFAILURES\n');
    for (const f of failures) process.stdout.write(`  ${f.uid}: ${f.error}\n`);
  }
  if (counts.needsV2 && options.apply) {
    process.stdout.write('\nSome athletes have no profile V2 yet — run backfill:showcase-v2 --apply, then rerun this.\n');
  }
  if (!options.apply) process.stdout.write('\nDry run only. Re-run with --apply to write.\n');
  return counts.errors > 0 ? 1 : 0;
}

module.exports = { parseArgs, pool };

if (require.main === module) {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`\nBackfill failed: ${err && err.message}\n`);
      process.exit(1);
    });
}
