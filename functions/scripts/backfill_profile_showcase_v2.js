#!/usr/bin/env node
'use strict';

// One-time backfill of profileShowcaseV2 (categories + RE Points) for existing
// workout history. V1 (profileShowcaseV1, showcaseDays, showcase/state) is
// never read or written by this script — backfill_profile_showcase.js owns it.
//
// SAFETY CONTRACT
//   * Read-only on workout documents, weigh-ins and users/{uid}: none is ever
//     written, mutated or deleted.
//   * Dry run by default. Nothing is written without --apply.
//   * Idempotent and resumable: progress is recorded per uid in
//     migrations/profileShowcaseV2Backfill/progress/{uid}, so an interrupted
//     run is finished by re-running the same command. --force reprocesses.
//   * Deterministic: the rebuild is a pure fold over the surviving workout
//     days, the recorded weigh-ins and the athlete's sex, so dry-run, apply
//     and verify compute the same answer from the same data — and the same
//     answer the triggers converge on.
//   * users_public is written with mergeFields: ['profileShowcaseV2'] only;
//     no neighbouring field (V1, rePoints*, avatar, bio, username) is touched.
//
// Modes:
//   (default)  dry-run — compute every snapshot in memory, write nothing
//   --apply            — write showcase/v2/days + showcase/stateV2 + the mirror
//   --verify           — recompute and compare against what is published
//
// Credentials come from GOOGLE_APPLICATION_CREDENTIALS or the ambient service
// account.

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const PROGRESS_DOC = 'migrations/profileShowcaseV2Backfill';

function usage() {
  return [
    'Profile showcase V2 (categories + RE Points) backfill',
    '',
    'Dry run (default — writes nothing):',
    '  node scripts/backfill_profile_showcase_v2.js --project goodlift-us-storage',
    '',
    'Dry run for one athlete:',
    '  node scripts/backfill_profile_showcase_v2.js --project goodlift-us-storage --uid <uid>',
    '',
    'Apply:',
    '  node scripts/backfill_profile_showcase_v2.js --project goodlift-us-storage --apply',
    '',
    'Verify what is published matches a fresh recomputation:',
    '  node scripts/backfill_profile_showcase_v2.js --project goodlift-us-storage --verify',
    '',
    'Resume is automatic. --force reprocesses users already marked done.',
    '--limit N restricts the run to the first N accounts.',
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
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--force') out.force = true;
    else if (arg === '--uid') out.uid = argv[++i];
    else if (arg === '--limit') out.limit = Number(argv[++i]) || 0;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!out.projectId) throw new Error('--project requires a value');
  if (out.apply && out.verify) throw new Error('Choose either --apply or --verify, not both');
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

function hasCategories(snapshot) {
  return !!(snapshot && Object.keys(snapshot.categories || {}).length > 0);
}

async function listUids(db, options) {
  if (options.uid) return [options.uid];
  const snap = await db.collection('users').select().get();
  const uids = snap.docs.map((d) => d.id);
  return options.limit > 0 ? uids.slice(0, options.limit) : uids;
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

  // Required after initializeApp so the modules bind to this app.
  const { memoryStoreV2 } = require('../showcase/store_v2');
  const fsStore = require('../showcase/firestore_store');

  const mode = options.verify ? 'verify' : options.apply ? 'apply' : 'dry-run';
  process.stdout.write(`Profile showcase V2 backfill — mode: ${mode}\n`);
  process.stdout.write(`Project: ${options.projectId}\n\n`);

  const uids = await listUids(db, options);
  process.stdout.write(`Accounts to consider: ${uids.length}\n`);

  const progressCol = db.doc(PROGRESS_DOC).collection('progress');

  const counts = {
    considered: uids.length,
    skippedAlreadyDone: 0,
    processed: 0,
    withWorkoutHistory: 0,
    withNoCategory: 0,
    workoutDaysRead: 0,
    exercisesWithPoints: 0,
    exercisesWithoutPoints: 0,
    snapshotsWritten: 0,
    staleDaysPruned: 0,
    verifiedOk: 0,
    verifiedMismatch: 0,
    verifiedMissing: 0,
    errors: 0,
  };
  const mismatches = [];

  for (const uid of uids) {
    try {
      if (options.apply && !options.force) {
        const done = await progressCol.doc(uid).get();
        if (done.exists && done.data() && done.data().status === 'done') {
          counts.skippedAlreadyDone += 1;
          continue;
        }
      }

      // Always compute into memory first: dry-run and verify must never
      // write, and apply replays the identical answer.
      const userSnap = await db.collection('users').doc(uid).get();
      const sex = userSnap.exists ? (userSnap.data() || {}).sex : null;
      const memory = memoryStoreV2({
        bodyweightAsOf: fsStore.bodyweightResolver(uid),
        sex,
      });
      const { snapshot, workoutDays } = await fsStore.rebuildAthleteV2(uid, {
        apply: false,
        store: memory,
      });

      counts.processed += 1;
      counts.workoutDaysRead += workoutDays;
      if (workoutDays > 0) counts.withWorkoutHistory += 1;
      if (!hasCategories(snapshot)) counts.withNoCategory += 1;
      for (const cat of Object.values((snapshot && snapshot.categories) || {})) {
        for (const e of Object.values(cat.exercises || {})) {
          if (typeof e.rePoints === 'number') counts.exercisesWithPoints += 1;
          else counts.exercisesWithoutPoints += 1;
        }
      }

      if (options.verify) {
        const published = await fsStore.readPublishedSnapshotV2(uid);
        if (!published) {
          if (hasCategories(snapshot)) {
            counts.verifiedMissing += 1;
            mismatches.push({ uid, reason: 'missing' });
          } else {
            counts.verifiedOk += 1;
          }
        } else if (sameSnapshotV2(published, snapshot)) {
          counts.verifiedOk += 1;
        } else {
          counts.verifiedMismatch += 1;
          mismatches.push({ uid, reason: 'differs' });
        }
        continue;
      }

      if (!options.apply) continue;

      // Apply: replay the already-computed day contributions through the
      // Firestore V2 store, publish, then drop any V2 day document the
      // rebuild did not produce (history deleted since).
      const target = fsStore.firestoreStoreV2(uid);
      const keepIds = new Set();
      for (const [id, day] of memory._days) {
        keepIds.add(id);
        await target.setDay(day.slot, day.dateKey, day);
      }
      await target.setSnapshot(snapshot);
      await target.setState(await memory.getState());
      await target.flush();
      counts.staleDaysPruned += await fsStore.pruneStaleDaysV2(uid, keepIds);

      counts.snapshotsWritten += 1;
      await progressCol.doc(uid).set(
        {
          status: 'done',
          workoutDays,
          at: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    } catch (err) {
      counts.errors += 1;
      process.stderr.write(`  ERROR ${uid}: ${err && err.message}\n`);
    }
  }

  process.stdout.write('\nCOUNTS\n');
  for (const [k, v] of Object.entries(counts)) {
    process.stdout.write(`  ${k}: ${v}\n`);
  }

  if (mismatches.length) {
    process.stdout.write('\nMISMATCHES\n');
    for (const m of mismatches.slice(0, 50)) {
      process.stdout.write(`  ${m.uid}: ${m.reason}\n`);
    }
    if (mismatches.length > 50) {
      process.stdout.write(`  ...and ${mismatches.length - 50} more\n`);
    }
  }

  if (options.verify) {
    const clean = counts.verifiedMismatch === 0 && counts.verifiedMissing === 0 && counts.errors === 0;
    process.stdout.write(`\nVerification: ${clean ? 'CLEAN' : 'NOT CLEAN'}\n`);
    return clean ? 0 : 1;
  }
  if (!options.apply) {
    process.stdout.write('\nDry run only. Re-run with --apply to write.\n');
  }
  return counts.errors > 0 ? 1 : 0;
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
