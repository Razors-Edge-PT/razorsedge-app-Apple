#!/usr/bin/env node
'use strict';

// Backfill of profileShowcaseV2 (categories + independently selected Best RE
// Points) — and, because the rebuild job continues into it, the RE Points
// leaderboard — for existing athletes. V1 (profileShowcaseV1, showcaseDays,
// showcase/state) is never read or written here.
//
// It runs the SAME bounded rebuild job the deployed worker runs
// (showcase/rebuild_job.js): the per-athlete job document
// (profileRebuildJobs/{uid}) is the checkpoint, every step is one bounded
// transaction guarded by the job's generation, and the previous snapshot stays
// published until the job publishes atomically.
//
// SAFETY CONTRACT
//   * Dry run by default: computes every athlete in memory, writes nothing.
//   * Read-only on workouts, weigh-ins, users/{uid}.
//   * Resumable: an interrupted run leaves each athlete's job where it
//     stopped; rerunning continues it. Finished athletes are recorded in
//     migrations/profileShowcaseV2Backfill/progress/{uid} (--force redoes
//     them). The account listing is paged; --concurrency bounds parallelism.
//   * Idempotent: derived documents are recomputed and replaced, never
//     incremented. users_public is only ever written field by field.
//
// Modes:
//   (default)  dry-run — in memory, writes nothing
//   --apply            — run each athlete's rebuild job to completion
//   --verify           — recompute in memory and compare with what is published
//
// Credentials: GOOGLE_APPLICATION_CREDENTIALS or the ambient account.

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const PROGRESS_DOC = 'migrations/profileShowcaseV2Backfill';

function usage() {
  return [
    'Profile showcase V2 (categories + RE Points) backfill',
    '',
    '  node scripts/backfill_profile_showcase_v2.js --project goodlift-us-storage            (dry run)',
    '  node scripts/backfill_profile_showcase_v2.js --project goodlift-us-storage --uid <uid>',
    '  node scripts/backfill_profile_showcase_v2.js --project goodlift-us-storage --apply',
    '  node scripts/backfill_profile_showcase_v2.js --project goodlift-us-storage --verify',
    '',
    'Options: --concurrency N (1-8, default 3)  --limit N  --force  --sample N (print N sample athletes)',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    uid: null,
    apply: false,
    verify: false,
    force: false,
    limit: 0,
    concurrency: 3,
    sample: 3,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--force') out.force = true;
    else if (arg === '--uid') out.uid = argv[++i];
    else if (arg === '--limit') out.limit = Number(argv[++i]) || 0;
    else if (arg === '--concurrency') out.concurrency = Number(argv[++i]);
    else if (arg === '--sample') out.sample = Number(argv[++i]) || 0;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!out.projectId) throw new Error('--project requires a value');
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify, not both');
  if (!Number.isInteger(out.concurrency) || out.concurrency < 1 || out.concurrency > 8) {
    throw new Error('--concurrency must be 1..8');
  }
  return out;
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = canonical(value[key]);
    return out;
  }
  return value;
}

/** Value comparison of two V2 snapshots, ignoring the mirror's updatedAtMs. */
function sameSnapshotV2(a, b) {
  const strip = (s) => {
    if (!s) return null;
    const copy = canonical(JSON.parse(JSON.stringify(s)));
    delete copy.updatedAtMs;
    if (copy.categories && Object.keys(copy.categories).length === 0) delete copy.categories;
    return copy;
  };
  return JSON.stringify(strip(a)) === JSON.stringify(strip(b));
}

async function pool(items, limit, worker) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const i = next;
      next += 1;
      await worker(items[i]);
    }
  }));
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
  const fsStore = require('../showcase/firestore_store');
  const { dryRunUser } = require('../showcase/rebuild_dry_run');

  const mode = options.verify ? 'verify' : options.apply ? 'apply' : 'dry-run';
  process.stdout.write(`Profile showcase V2 backfill — mode: ${mode}\nProject: ${options.projectId}\n\n`);

  let uids;
  if (options.uid) uids = [options.uid];
  else {
    const snap = await db.collection('users').select().get();
    uids = snap.docs.map((d) => d.id);
    if (options.limit > 0) uids = uids.slice(0, options.limit);
  }
  process.stdout.write(`Accounts to consider: ${uids.length}\n`);
  const progressCol = db.doc(PROGRESS_DOC).collection('progress');

  const counts = {
    considered: uids.length,
    skippedAlreadyDone: 0,
    processed: 0,
    withWorkoutHistory: 0,
    workoutDaysRead: 0,
    withCategories: 0,
    exercisesWithPoints: 0,
    exercisesWithoutPoints: 0,
    pointsRecordDiffersFromE1rmRecord: 0,
    jobsCompleted: 0,
    jobsNotFinished: 0,
    verifiedOk: 0,
    verifiedMismatch: 0,
    verifiedMissing: 0,
    errors: 0,
  };
  const failures = [];
  const samples = [];

  function tally(uid, snapshot) {
    const cats = (snapshot && snapshot.categories) || {};
    if (Object.keys(cats).length) counts.withCategories += 1;
    for (const [key, cat] of Object.entries(cats)) {
      for (const e of Object.values(cat.exercises || {})) {
        if (typeof e.rePoints === 'number') counts.exercisesWithPoints += 1;
        else counts.exercisesWithoutPoints += 1;
        if (e.points && e.e1rm && e.points.fingerprint !== e.e1rm.fingerprint) {
          counts.pointsRecordDiffersFromE1rmRecord += 1;
        }
      }
      if (samples.length < options.sample && cat.exercises[cat.bestExerciseId]) {
        const b = cat.exercises[cat.bestExerciseId];
        samples.push(`${uid} ${key}: ${b.displayName} rePoints=${b.rePoints} ` +
          `(points ${b.points ? `${b.points.weight}x${b.points.reps} ${b.points.dateKey}` : '—'}; ` +
          `e1rm ${b.e1rm ? `${b.e1rm.weight}x${b.e1rm.reps} ${b.e1rm.dateKey}` : '—'})`);
      }
    }
  }

  await pool(uids, options.concurrency, async (uid) => {
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
        const res = await dryRunUser(db, uid, fsStore.bodyweightResolver);
        counts.workoutDaysRead += res.workoutDays;
        if (res.workoutDays > 0) counts.withWorkoutHistory += 1;
        tally(uid, res.snapshot);
        if (options.verify) {
          const published = await fsStore.readPublishedSnapshotV2(uid);
          const has = res.snapshot && Object.keys(res.snapshot.categories || {}).length > 0;
          if (!published) {
            if (has) {
              counts.verifiedMissing += 1;
              failures.push({ uid, error: 'missing' });
            } else counts.verifiedOk += 1;
          } else if (sameSnapshotV2(published, res.snapshot)) counts.verifiedOk += 1;
          else {
            counts.verifiedMismatch += 1;
            failures.push({ uid, error: 'differs' });
          }
        }
        return;
      }
      // Apply: the job (resumed if one is already active) run to completion
      // with the worker's own step function.
      await fsStore.requestRebuildFor(uid, { mode: 'full', reason: 'backfill' });
      const run = await fsStore.runRebuildFor(uid);
      if (run.job && run.job.status === 'done') {
        counts.jobsCompleted += 1;
        tally(uid, await fsStore.readPublishedSnapshotV2(uid));
        await progressCol.doc(uid).set({ status: 'done', at: admin.firestore.FieldValue.serverTimestamp() });
      } else {
        counts.jobsNotFinished += 1;
        failures.push({ uid, error: `job ${run.job && run.job.status}: ${run.job && run.job.lastError}` });
      }
    } catch (err) {
      counts.errors += 1;
      if (failures.length < 100) failures.push({ uid, error: String(err && err.message) });
    }
  });

  process.stdout.write('\nCOUNTS\n');
  for (const [k, v] of Object.entries(counts)) process.stdout.write(`  ${k}: ${v}\n`);
  if (samples.length) {
    process.stdout.write('\nSAMPLES\n');
    for (const s of samples) process.stdout.write(`  ${s}\n`);
  }
  if (failures.length) {
    process.stdout.write('\nFAILURES\n');
    for (const f of failures.slice(0, 100)) process.stdout.write(`  ${f.uid}: ${f.error}\n`);
  }
  if (options.verify) {
    const clean = counts.verifiedMismatch === 0 && counts.verifiedMissing === 0 && counts.errors === 0;
    process.stdout.write(`\nVerification: ${clean ? 'CLEAN' : 'NOT CLEAN'}\n`);
    return clean ? 0 : 1;
  }
  if (!options.apply) process.stdout.write('\nDry run only. Re-run with --apply to write.\n');
  return counts.errors > 0 || counts.jobsNotFinished > 0 ? 1 : 0;
}

module.exports = { parseArgs, sameSnapshotV2 };

if (require.main === module) {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`\nBackfill failed: ${err && err.message}\n`);
      process.exit(1);
    });
}
