#!/usr/bin/env node
'use strict';

// One-time backfill of the lifetime Big Five showcase projection for existing
// workout history.
//
// SAFETY CONTRACT
//   * NEVER reads-and-writes a workout document. Workout history is opened
//     read-only and is never mutated or deleted by this script.
//   * Idempotent and resumable: progress is recorded per uid in
//     migrations/profileShowcaseBackfill/progress/{uid}, so an interrupted run
//     is finished by re-running the same command. --force reprocesses.
//   * Deterministic: the rebuild is a pure fold over the surviving workout
//     days, so dry-run, apply and verify all compute the same answer from the
//     same data.
//
// Modes:
//   (default)  dry-run — compute every snapshot in memory, write nothing
//   --apply            — write showcaseDays + showcase/state + the users_public mirror
//   --verify           — recompute and compare against what is published
//
// Credentials come from GOOGLE_APPLICATION_CREDENTIALS or the ambient service
// account.

const admin = require('firebase-admin');

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const PROGRESS_DOC = 'migrations/profileShowcaseBackfill';

function usage() {
  return [
    'Profile showcase (Big Five) backfill',
    '',
    'Dry run (default — writes nothing):',
    '  node scripts/backfill_profile_showcase.js --project goodlift-us-storage',
    '',
    'Dry run for one athlete:',
    '  node scripts/backfill_profile_showcase.js --project goodlift-us-storage --uid <uid>',
    '',
    'Apply:',
    '  node scripts/backfill_profile_showcase.js --project goodlift-us-storage --apply',
    '',
    'Verify what is published matches a fresh recomputation:',
    '  node scripts/backfill_profile_showcase.js --project goodlift-us-storage --verify',
    '',
    'Resume is automatic. --force reprocesses users already marked done.',
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

/**
 * Compares two snapshots BY VALUE, ignoring the mirror's updatedAtMs stamp.
 *
 * Key order is normalised first. Firestore returns a document's fields in its
 * own order, which is not the order the reducer builds them in, so a plain
 * JSON.stringify comparison reports every single account as differing even
 * when the values are identical.
 */
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = canonical(value[key]);
    return out;
  }
  return value;
}

function sameSnapshot(a, b) {
  const strip = (s) => {
    if (!s) return null;
    const copy = canonical(JSON.parse(JSON.stringify(s)));
    delete copy.updatedAtMs;
    if (copy.lifts && Object.keys(copy.lifts).length === 0) delete copy.lifts;
    return copy;
  };
  return JSON.stringify(strip(a)) === JSON.stringify(strip(b));
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

  admin.initializeApp({ projectId: options.projectId });
  const db = admin.firestore();

  // Required after initializeApp so the modules bind to this app.
  const store = require('../showcase/store');
  const fsStore = require('../showcase/firestore_store');
  const { snapshotFromLifts } = require('../showcase/reducer');

  const mode = options.verify ? 'verify' : options.apply ? 'apply' : 'dry-run';
  process.stdout.write(`Profile showcase backfill — mode: ${mode}\n`);
  process.stdout.write(`Project: ${options.projectId}\n\n`);

  const uids = await listUids(db, options);
  process.stdout.write(`Accounts to consider: ${uids.length}\n`);

  const progressCol = db.doc(PROGRESS_DOC).collection('progress');

  const counts = {
    considered: uids.length,
    skippedAlreadyDone: 0,
    processed: 0,
    withWorkoutHistory: 0,
    withNoBigFive: 0,
    workoutDaysRead: 0,
    snapshotsWritten: 0,
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

      // Always compute into memory first: dry-run and verify must never write,
      // and apply gets the same deterministic answer.
      const memory = store.memoryStore();
      const { snapshot, workoutDays } = await fsStore.rebuildAthlete(uid, {
        apply: false,
        store: memory,
      });

      counts.processed += 1;
      counts.workoutDaysRead += workoutDays;
      if (workoutDays > 0) counts.withWorkoutHistory += 1;
      if (!snapshot || Object.keys(snapshot.lifts || {}).length === 0) {
        counts.withNoBigFive += 1;
      }

      if (options.verify) {
        const published = await fsStore.readPublishedSnapshot(uid);
        if (!published) {
          // Only a mismatch when there was something to publish.
          if (snapshot && Object.keys(snapshot.lifts || {}).length > 0) {
            counts.verifiedMissing += 1;
            mismatches.push({ uid, reason: 'missing' });
          } else {
            counts.verifiedOk += 1;
          }
        } else if (sameSnapshot(published, snapshot)) {
          counts.verifiedOk += 1;
        } else {
          counts.verifiedMismatch += 1;
          mismatches.push({ uid, reason: 'differs' });
        }
        continue;
      }

      if (!options.apply) continue;

      // Apply: replay the identical, already-computed day contributions
      // through the Firestore store, then drop any day document the rebuild
      // did not produce (history that has since been deleted).
      const target = fsStore.firestoreStore(uid);
      const keepIds = new Set();
      for (const [id, day] of memory._days) {
        keepIds.add(id);
        await target.setDay(day.slot, day.dateKey, day);
      }
      await target.setSnapshot(snapshotFromLifts((snapshot && snapshot.lifts) || {}));
      const state = await memory.getState();
      await target.setState(state);
      await target.flush();
      await fsStore.pruneStaleDays(uid, keepIds);

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

main()
  .then((code) => process.exit(code))
  .catch((err) => {
    process.stderr.write(`\nBackfill failed: ${err && err.message}\n`);
    process.exit(1);
  });
