// Read-only dry run of one athlete's rebuild: the SAME job state machine
// (rebuild_job.js) and reducers as the worker, over in-memory stores fed from
// the athlete's real workouts, weigh-ins, sex and public profile. Writes
// nothing. Used by both backfill scripts' dry-run and verify modes.

'use strict';

const admin = require('firebase-admin');
const { memoryStoreV2 } = require('./store_v2');
const { runRebuildToCompletion, memoryIo } = require('./rebuild_job');
const { memoryLeaderboardStore } = require('../leaderboard/store');

const DATE_KEY_RE = /^\d{4}-\d{2}-\d{2}$/;

async function readWorkouts(db, uid) {
  const out = [];
  const PAGE = 300;
  let last = null;
  for (;;) {
    let q = db.collection('users').doc(uid).collection('workouts')
      .orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE);
    if (last) q = q.startAfter(last);
    const page = await q.get();
    if (page.empty) break;
    for (const d of page.docs) if (DATE_KEY_RE.test(d.id)) out.push([d.id, d.data()]);
    last = page.docs[page.docs.length - 1];
    if (page.size < PAGE) break;
  }
  return out;
}

/**
 * Computes the athlete's rebuilt V2 snapshot, day contributions, rePointDays
 * and leaderboard entries in memory. Returns
 * { snapshot, v2Days, dayScores, entries, workoutDays, steps, job }.
 */
async function dryRunUser(db, uid, bodyweightResolver) {
  const workouts = await readWorkouts(db, uid);
  const userSnap = await db.collection('users').doc(uid).get();
  const sex = userSnap.exists ? (userSnap.data() || {}).sex : null;
  const publicSnap = await db.collection('users_public').doc(uid).get();
  const publicData = publicSnap.exists ? publicSnap.data() : {};
  const bodyweightAsOf = bodyweightResolver(uid);

  const v2 = memoryStoreV2({ bodyweightAsOf, sex, workouts: () => workouts });
  const entries = new Map();
  const lb = memoryLeaderboardStore(uid, {
    v2Days: () => [...v2._days.values()],
    bodyweightAsOf,
    sex,
    publicProfile: async () => Object.assign({}, publicData, { profileShowcaseV2: await v2.getSnapshot() }),
    entries,
  });
  await v2.requestRebuild({ mode: 'full', reason: 'dry-run' });
  const run = await runRebuildToCompletion(memoryIo(v2, lb));
  return {
    snapshot: await v2.getSnapshot(),
    v2Days: [...v2._days.values()],
    dayScores: [...lb._days.values()],
    entries,
    workoutDays: workouts.length,
    steps: run.steps,
    job: run.job,
  };
}

module.exports = { dryRunUser, readWorkouts };
