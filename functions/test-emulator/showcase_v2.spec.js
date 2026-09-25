'use strict';

// PRODUCTION-ADAPTER tests for profileShowcaseV2 (categories + RE Points),
// the bounded rebuild job and the per-exercise unit publication, against the
// Firestore emulator: the real document layout, the reads made INSIDE each
// transaction, the job's generation/step guard, and the mergeFields mirror
// that must not disturb V1 or any other users_public field.
//
// No functions run in the emulator here, so `settle(uid)` drives the athlete's
// job with the worker's own step function (rebuildIo) — exactly what the
// deployed showcaseRebuildWorker does, one step per invocation.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
const DB_BENCH = 'kTs5fLSTKjUkUZL10iii';
const SUMO = '10pEctikt6PP8eAg9Eip';
const DEADLIFT = 'MsGl7e9yanDeEnYX0e4X';
const DIP = 'FtayDmR5BVnGS1FXlXLL';

let store;
let reCoefficient;
let buildShowcaseV2;
let pickBodyweightAsOf;

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  store = require('../showcase/firestore_store');
  reCoefficient = require('../showcase/re_points').reCoefficient;
  buildShowcaseV2 = require('../showcase/reducer_v2').buildShowcaseV2;
  pickBodyweightAsOf = require('../showcase/bodyweight').pickBodyweightAsOf;
});

function workout(...rows) {
  return { exercises: rows.map(([exerciseId, sets]) => ({ exerciseId, name: 'x', sets })) };
}

let seq = 0;
function freshUid() {
  seq += 1;
  return `showcasev2_${Date.now()}_${seq}`;
}

async function wipe(uid) {
  const db = admin.firestore();
  await db.recursiveDelete(db.collection('users').doc(uid));
  await db.collection('users_public').doc(uid).delete().catch(() => {});
  await store.jobRef(uid).delete().catch(() => {});
}

async function weighIn(uid, dateKey, weight) {
  const [y, m, d] = dateKey.split('-').map(Number);
  const ts = admin.firestore.Timestamp.fromMillis(Date.UTC(y, m - 1, d, 0, 0, 0));
  return admin.firestore().collection('users').doc(uid).collection('weights')
    .add({ weight, unit: 'kg', tod: 'am', timestamp: ts });
}

/** What the workout trigger does: the document, then the V2 transaction. */
async function logWorkout(uid, dateKey, data) {
  const ref = admin.firestore().collection('users').doc(uid).collection('workouts').doc(dateKey);
  if (data) await ref.set(data);
  else await ref.delete();
  return store.applyWorkoutDayV2Transactionally(uid, dateKey, data);
}

/** The worker: runs the athlete's job (if any) to completion. */
async function settle(uid) {
  const run = await store.runRebuildFor(uid);
  return run.job;
}

function pts(e1rm, factor, bw, sex) {
  return Number((e1rm * factor * reCoefficient(sex || 'male', bw)).toFixed(4));
}

test('V2 is published beside V1 without touching V1 or neighbouring fields', async () => {
  const uid = freshUid();
  const db = admin.firestore();
  try {
    await db.collection('users').doc(uid).set({ sex: 'M' });
    await db.collection('users_public').doc(uid).set({ bio: 'keep me', rePoints: 12.5 });
    await weighIn(uid, '2026-06-01', 80);
    const data = workout([BENCH, [{ weight: 100, reps: 1 }]], [DB_BENCH, [{ weight: 50, reps: 1 }]]);
    await db.collection('users').doc(uid).collection('workouts').doc('2026-06-02').set(data);
    await store.applyWorkoutDayTransactionally(uid, '2026-06-02', data);
    const r = await store.applyWorkoutDayV2Transactionally(uid, '2026-06-02', data);
    assert.equal(r.path, 'append', 'a first training day ever is published directly');

    const pub = (await db.collection('users_public').doc(uid).get()).data();
    assert.equal(pub.bio, 'keep me');
    assert.equal(pub.rePoints, 12.5);
    assert.ok(pub.profileShowcaseV1.lifts.bench);
    const v2 = pub.profileShowcaseV2;
    assert.equal(v2.schema, 'profileShowcaseV2');
    assert.equal(v2.aggregationVersion, 2);
    const hp = v2.categories.horizontalPress;
    assert.equal(hp.bestExerciseId, DB_BENCH);
    assert.equal(hp.exercises[BENCH].rePoints, pts(100, 1, 80));
    assert.equal(hp.exercises[BENCH].points.setKey, hp.exercises[BENCH].e1rm.setKey);
    assert.equal(hp.exercises[DB_BENCH].rePoints, pts(50, 2.35, 80));
    assert.equal(hp.exercises[BENCH].e1rm.fingerprint, pub.profileShowcaseV1.lifts.bench.e1rm.fingerprint);

    const days = await store.daysV2Col(uid).get();
    assert.deepEqual(
      days.docs.map((d) => d.id).sort(),
      ['horizontalPress__bench__2026-06-02', 'horizontalPress__dbBenchFlat__2026-06-02'],
    );
    for (const d of days.docs) {
      assert.ok(Array.isArray(d.data().sets));
      assert.equal(d.data().bodyweight.weightKg, 80);
      assert.ok(d.data().bestPoints);
    }
  } finally {
    await wipe(uid);
  }
});

test('an athlete with history gets a bounded rebuild job, never an in-trigger history read', async () => {
  const uid = freshUid();
  const db = admin.firestore();
  try {
    await db.collection('users').doc(uid).set({ sex: 'M' });
    await weighIn(uid, '2025-01-01', 110);
    await weighIn(uid, '2025-06-01', 65);
    const history = {};
    // 60 dates → several job pages.
    for (let i = 0; i < 60; i += 1) {
      const d = new Date(Date.UTC(2025, 0, 2) + i * 3 * 86400000).toISOString().slice(0, 10);
      history[d] = workout([BENCH, [{ weight: 100 + (i % 30), reps: 1 + (i % 3) }]], [SUMO, [{ weight: 180, reps: 1 }]]);
      await db.collection('users').doc(uid).collection('workouts').doc(d).set(history[d]);
    }
    await db.collection('users_public').doc(uid).set({ username: 'jobber' });
    const last = Object.keys(history).sort().pop();
    const r = await store.applyWorkoutDayV2Transactionally(uid, last, history[last]);
    assert.equal(r.path, 'queued');
    assert.equal((await store.readPublishedSnapshotV2(uid)), null, 'nothing partial is published');
    const queued = (await store.jobRef(uid).get()).data();
    assert.equal(queued.status, 'queued');

    const job = await settle(uid);
    assert.equal(job.status, 'done');
    const entries = [
      { id: 'a', dateKey: '2025-01-01', weight: 110 },
      { id: 'b', dateKey: '2025-06-01', weight: 65 },
    ];
    const bwByDate = {};
    for (const d of Object.keys(history)) bwByDate[d] = pickBodyweightAsOf(entries, d);
    const expected = buildShowcaseV2(history, { bodyweightByDate: bwByDate, sex: 'male' });
    const published = await store.readPublishedSnapshotV2(uid);
    assert.deepEqual(published.categories, expected.categories);
    // And the job carried on into the leaderboard.
    const at = await db.collection('leaderboards').doc('all_time').collection('entries').doc(uid).get();
    assert.ok(at.exists);
    assert.equal(at.data().username, 'jobber');
  } finally {
    await wipe(uid);
    await admin.firestore().collection('leaderboards').doc('all_time').collection('entries').doc(uid).delete();
  }
});

test('legacy auto-id workouts (digit-prefixed) never end the job early', async () => {
  // Production regression: auto-ids such as "0RmEOT…" / "4b40…" sort INSIDE
  // the documentId date range, so a limit(n) page returned < n date-keyed
  // rows and the job mistook it for the end of history.
  const uid = freshUid();
  const db = admin.firestore();
  try {
    await db.collection('users').doc(uid).set({ sex: 'M' });
    await weighIn(uid, '2025-01-01', 80);
    const col = db.collection('users').doc(uid).collection('workouts');
    for (const id of ['0RmEOTjTFORCVeBLMG0i', '1cQcBIk4rVhrL1rYFcC6', '2025-01-0x', '3QrnMED1JStRCmhpvE9d', '4b400kbc6qYRLbanV98s']) {
      await col.doc(id).set(workout([BENCH, [{ weight: 300, reps: 1 }]])); // never counted
    }
    const history = {};
    for (let i = 0; i < 70; i += 1) {
      const d = new Date(Date.UTC(2025, 0, 2) + i * 2 * 86400000).toISOString().slice(0, 10);
      history[d] = workout([BENCH, [{ weight: 60 + i, reps: 1 }]]);
      await col.doc(d).set(history[d]);
    }
    const last = Object.keys(history).sort().pop();
    await store.requestRebuildFor(uid, { mode: 'full', reason: 'test' });
    const job = await settle(uid);
    assert.equal(job.status, 'done');
    assert.equal(job.latestDateKey, last, 'every page was read');
    const days = await db.collection('users').doc(uid).collection('showcase').doc('v2').collection('days').get();
    assert.equal(days.size, 70);
    const published = await store.readPublishedSnapshotV2(uid);
    const bench = published.categories.horizontalPress.exercises[BENCH];
    assert.equal(bench.e1rm.dateKey, last, 'the heaviest (latest) set is found');
    assert.equal(bench.e1rm.weight, 129);
  } finally {
    await wipe(uid);
    await admin.firestore().collection('leaderboards').doc('all_time').collection('entries').doc(uid).delete();
  }
});

test('workouts written while the job runs are part of its result (real adapter)', async () => {
  const uid = freshUid();
  const db = admin.firestore();
  try {
    await weighIn(uid, '2025-01-01', 80);
    const history = {};
    for (let i = 0; i < 40; i += 1) {
      const d = new Date(Date.UTC(2025, 0, 2) + i * 86400000).toISOString().slice(0, 10);
      history[d] = workout([DEADLIFT, [{ weight: 150 + i, reps: 1 }]]);
      await db.collection('users').doc(uid).collection('workouts').doc(d).set(history[d]);
    }
    await store.requestRebuildFor(uid, { mode: 'full', reason: 'test' });
    const io = store.rebuildIo(uid);
    const { rebuildStep } = require('../showcase/rebuild_job');
    await rebuildStep(io);
    // A trigger during the run: an edit ahead of the cursor and a backdated add.
    await logWorkout(uid, '2025-02-05', workout([DEADLIFT, [{ weight: 300, reps: 1 }]]));
    await logWorkout(uid, '2024-12-01', workout([SUMO, [{ weight: 250, reps: 1 }]]));
    const job = await settle(uid);
    assert.equal(job.status, 'done');
    const v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.hipHinge.exercises[DEADLIFT].e1rm.weight, 300);
    assert.equal(v2.categories.hipHinge.exercises[SUMO].e1rm.weight, 250);
  } finally {
    await wipe(uid);
  }
});

test('a stale step (old generation) cannot commit against the real job document', async () => {
  const uid = freshUid();
  try {
    await admin.firestore().collection('users').doc(uid).collection('workouts').doc('2025-01-01')
      .set(workout([BENCH, [{ weight: 100, reps: 1 }]]));
    const stale = await store.requestRebuildFor(uid, { mode: 'leaderboard', reason: 'a' });
    await store.requestRebuildFor(uid, { mode: 'full', reason: 'b' }); // supersedes
    const committed = await store.rebuildIo(uid).unit(stale, async () => ({ phase: 'publish' }));
    assert.equal(committed, false);
    assert.equal((await store.jobRef(uid).get()).data().phase, 'days');
  } finally {
    await wipe(uid);
  }
});

test('a weigh-in re-scores through the real trigger path; a Triceps Dip uses combined load', async () => {
  const uid = freshUid();
  try {
    await admin.firestore().collection('users').doc(uid).set({ sex: 'F' });
    const data = workout(
      [DIP, [{ weight: 10, reps: 1, setIndex: 0 }]],
      [BENCH, [{ weight: 60, reps: 1 }]],
    );
    await logWorkout(uid, '2026-06-10', data);
    let v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.overheadPress.exercises[DIP].rePoints, null);
    assert.equal(v2.categories.horizontalPress.exercises[BENCH].rePoints, null);

    await weighIn(uid, '2026-06-10', 60);
    const res = await store.refreshV2Transactionally(uid, { bodyweight: true, sinceDateKey: '2026-06-10' });
    assert.equal(res.changed, true);
    v2 = await store.readPublishedSnapshotV2(uid);
    const dip = v2.categories.overheadPress.exercises[DIP];
    assert.equal(dip.points.totalKg, 70);
    assert.equal(dip.rePoints, pts(70, 0.73, 60, 'female'));
    assert.equal(v2.categories.horizontalPress.exercises[BENCH].rePoints, pts(60, 1, 60, 'female'));

    // A change of sex is a job (fold + leaderboard), not an in-trigger rescore.
    await admin.firestore().collection('users').doc(uid).set({ sex: 'M' }, { merge: true });
    const s = await store.refreshV2Transactionally(uid, { sex: true });
    assert.equal(s.path, 'queued');
    assert.equal((await settle(uid)).status, 'done');
    v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.horizontalPress.exercises[BENCH].rePoints, pts(60, 1, 60, 'male'));
  } finally {
    await wipe(uid);
  }
});

test('deleting a workout removes the V2 exercise; the day contributions go too', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-01-01', 90);
    await logWorkout(uid, '2026-03-01', workout([SUMO, [{ weight: 200, reps: 1 }]]));
    await logWorkout(uid, '2026-02-01', workout([DEADLIFT, [{ weight: 220, reps: 1 }]]));
    let v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.hipHinge.bestExerciseId, DEADLIFT);
    await logWorkout(uid, '2026-02-01', null);
    v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.hipHinge.exercises[DEADLIFT], undefined);
    assert.equal(v2.categories.hipHinge.bestExerciseId, SUMO);
    const days = await store.daysV2Col(uid).get();
    assert.deepEqual(days.docs.map((d) => d.id), ['hipHinge__deadliftSumo__2026-03-01']);
  } finally {
    await wipe(uid);
  }
});

test('concurrent V2 writes for one athlete both survive', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-01-01', 80);
    await logWorkout(uid, '2026-01-15', workout([SUMO, [{ weight: 170, reps: 1 }]]));
    await Promise.all([
      logWorkout(uid, '2026-02-01', workout([BENCH, [{ weight: 100, reps: 1 }]])),
      logWorkout(uid, '2026-02-02', workout([SUMO, [{ weight: 180, reps: 1 }]])),
    ]);
    const v2 = await store.readPublishedSnapshotV2(uid);
    assert.ok(v2.categories.horizontalPress.exercises[BENCH]);
    assert.equal(v2.categories.hipHinge.exercises[SUMO].e1rm.weight, 180);
  } finally {
    await wipe(uid);
  }
});

test('unit publication: only explicit, valid, changed kg/lb values reach users_public', async () => {
  const uid = freshUid();
  const db = admin.firestore();
  const snap = (data) => ({ exists: !!data, data: () => data });
  try {
    await db.collection('users_public').doc(uid).set({ username: 'u', bio: 'b' });
    const before = snap({ exerciseSettings: { [BENCH]: { weightUnit: 'kg', rirModel: 'x' } } });
    const after = snap({
      exerciseSettings: {
        [BENCH]: { weightUnit: 'lb', rirModel: 'x' },
        [SUMO]: { weightUnit: 'stone' }, // invalid: ignored
        [DEADLIFT]: { rirModel: 'y' }, // no explicit unit: untouched
      },
    });
    const update = store.exerciseUnitUpdate(before, after);
    assert.deepEqual(update, { [`exerciseWeightUnits.${BENCH}`]: 'lb' });
    await db.collection('users_public').doc(uid).update(update);
    // The same block write again: nothing changed, nothing to publish.
    assert.equal(store.exerciseUnitUpdate(after, after), null);
    const pub = (await db.collection('users_public').doc(uid).get()).data();
    assert.deepEqual(pub.exerciseWeightUnits, { [BENCH]: 'lb' });
    assert.equal(pub.bio, 'b');
    // Switching back is published too; nothing numeric anywhere is touched.
    const back = store.exerciseUnitUpdate(after, snap({ exerciseSettings: { [BENCH]: { weightUnit: 'kg' } } }));
    assert.deepEqual(back, { [`exerciseWeightUnits.${BENCH}`]: 'kg' });
  } finally {
    await wipe(uid);
  }
});
