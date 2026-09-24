'use strict';

// PRODUCTION-ADAPTER tests for profileShowcaseV2 (categories + RE Points).
//
// The unit tests pin the arithmetic against an in-memory store. These run the
// REAL Firestore adapter (firestore_store.js) against the emulator: the V2
// layout (showcase/stateV2, showcase/v2/days), the users/{uid}.sex and
// weigh-in reads issued INSIDE the transaction, the mergeFields mirror that
// must not disturb V1 or any other users_public field, and concurrency.
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
}

async function weighIn(uid, dateKey, weight) {
  const [y, m, d] = dateKey.split('-').map(Number);
  const ts = admin.firestore.Timestamp.fromMillis(Date.UTC(y, m - 1, d, 0, 0, 0));
  return admin.firestore().collection('users').doc(uid).collection('weights')
    .add({ weight, unit: 'kg', tod: 'am', timestamp: ts });
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
    await store.applyWorkoutDayTransactionally(uid, '2026-06-02', data);
    await store.applyWorkoutDayV2Transactionally(uid, '2026-06-02', data);

    const pub = (await db.collection('users_public').doc(uid).get()).data();
    assert.equal(pub.bio, 'keep me');
    assert.equal(pub.rePoints, 12.5);
    assert.ok(pub.profileShowcaseV1.lifts.bench);
    const v2 = pub.profileShowcaseV2;
    assert.equal(v2.schema, 'profileShowcaseV2');
    const hp = v2.categories.horizontalPress;
    assert.equal(hp.bestExerciseId, DB_BENCH);
    assert.equal(hp.exercises[BENCH].rePoints, pts(100, 1, 80));
    assert.equal(hp.exercises[DB_BENCH].rePoints, pts(50, 2.35, 80));
    // The V2 bench record IS the V1 bench record: same proof fingerprint.
    assert.equal(hp.exercises[BENCH].e1rm.fingerprint, pub.profileShowcaseV1.lifts.bench.e1rm.fingerprint);

    const days = await store.daysV2Col(uid).get();
    assert.deepEqual(
      days.docs.map((d) => d.id).sort(),
      ['horizontalPress__bench__2026-06-02', 'horizontalPress__dbBenchFlat__2026-06-02'],
    );
    const state = (await store.stateV2Ref(uid).get()).data();
    assert.equal(state.schema, 'profileShowcaseV2');
    assert.equal(state.latestDateKey, '2026-06-02');
    // V1's own documents are untouched by V2.
    const v1days = await store.daysCol(uid).get();
    assert.deepEqual(v1days.docs.map((d) => d.id), ['bench__2026-06-02']);
  } finally {
    await wipe(uid);
  }
});

test('deleting the workout removes the V2 exercise; out-of-order converges on the rebuild', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-01-01', 90);
    const later = workout([SUMO, [{ weight: 200, reps: 1 }]]);
    const earlier = workout([DEADLIFT, [{ weight: 220, reps: 1 }]]);
    await store.applyWorkoutDayV2Transactionally(uid, '2026-03-01', later);
    await store.applyWorkoutDayV2Transactionally(uid, '2026-02-01', earlier);
    let v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.hipHinge.bestExerciseId, DEADLIFT);

    const rebuilt = await store.rebuildAthleteV2(uid, { apply: false });
    assert.equal(rebuilt.workoutDays, 0); // no workout docs written in this test
    await store.applyWorkoutDayV2Transactionally(uid, '2026-02-01', null);
    v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.hipHinge.exercises[DEADLIFT], undefined);
    assert.equal(v2.categories.hipHinge.bestExerciseId, SUMO);
  } finally {
    await wipe(uid);
  }
});

test('a later weigh-in re-scores through the real trigger path; a Triceps Dip uses combined load', async () => {
  const uid = freshUid();
  try {
    await admin.firestore().collection('users').doc(uid).set({ sex: 'F' });
    const data = workout(
      [DIP, [{ weight: 10, reps: 1, setIndex: 0 }]],
      [BENCH, [{ weight: 60, reps: 1 }]],
    );
    await store.applyWorkoutDayV2Transactionally(uid, '2026-06-10', data);
    let v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.overheadPress.exercises[DIP].rePoints, null);
    assert.equal(v2.categories.horizontalPress.exercises[BENCH].rePoints, null);

    await weighIn(uid, '2026-06-10', 60);
    const res = await store.refreshV2Transactionally(uid, { bodyweight: true, sinceDateKey: '2026-06-10' });
    assert.equal(res.changed, true);
    v2 = await store.readPublishedSnapshotV2(uid);
    const dip = v2.categories.overheadPress.exercises[DIP];
    assert.equal(dip.e1rm.totalKg, 70);
    assert.equal(dip.rePoints, pts(70, 0.73, 60, 'female'));
    assert.equal(v2.categories.horizontalPress.exercises[BENCH].rePoints, pts(60, 1, 60, 'female'));

    // Sex change re-scores.
    await admin.firestore().collection('users').doc(uid).set({ sex: 'M' }, { merge: true });
    await store.refreshV2Transactionally(uid, { sex: true });
    v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.horizontalPress.exercises[BENCH].rePoints, pts(60, 1, 60, 'male'));
  } finally {
    await wipe(uid);
  }
});

test('the first V2 write after rollout bootstraps from the stored workout history', async () => {
  const uid = freshUid();
  const db = admin.firestore();
  try {
    await weighIn(uid, '2025-01-01', 85);
    const workouts = db.collection('users').doc(uid).collection('workouts');
    await workouts.doc('2025-05-01').set(workout([BENCH, [{ weight: 150, reps: 1 }]]));
    await workouts.doc('2025-07-01').set(workout([SUMO, [{ weight: 230, reps: 1 }]]));
    await workouts.doc('not-a-date').set(workout([BENCH, [{ weight: 500, reps: 1 }]]));
    const today = workout([DB_BENCH, [{ weight: 30, reps: 10 }]]);
    await workouts.doc('2026-06-01').set(today);

    const res = await store.applyWorkoutDayV2Transactionally(uid, '2026-06-01', today);
    assert.equal(res.path, 'bootstrap');
    const v2 = await store.readPublishedSnapshotV2(uid);
    assert.equal(v2.categories.horizontalPress.exercises[BENCH].e1rm.weight, 150);
    assert.ok(v2.categories.horizontalPress.exercises[DB_BENCH]);
    assert.equal(v2.categories.hipHinge.exercises[SUMO].e1rm.weight, 230);

    const rebuilt = await store.rebuildAthleteV2(uid, { apply: false });
    assert.equal(rebuilt.workoutDays, 3);
    const strip = (s) => JSON.stringify(s.categories);
    assert.equal(strip(v2), strip(rebuilt.snapshot));
  } finally {
    await wipe(uid);
  }
});

test('concurrent V2 writes for one athlete both survive', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-01-01', 80);
    await Promise.all([
      store.applyWorkoutDayV2Transactionally(uid, '2026-02-01', workout([BENCH, [{ weight: 100, reps: 1 }]])),
      store.applyWorkoutDayV2Transactionally(uid, '2026-02-02', workout([SUMO, [{ weight: 180, reps: 1 }]])),
    ]);
    const v2 = await store.readPublishedSnapshotV2(uid);
    assert.ok(v2.categories.horizontalPress.exercises[BENCH]);
    assert.ok(v2.categories.hipHinge.exercises[SUMO]);
  } finally {
    await wipe(uid);
  }
});
