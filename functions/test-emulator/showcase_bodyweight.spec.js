'use strict';

// PRODUCTION-ADAPTER tests for the Chin-Up bodyweight context.
//
// The unit tests pin the arithmetic against an in-memory store. These run the
// REAL Firestore adapter (firestore_store.js) against the Firestore emulator,
// because the parts that can only fail for real are here: the weigh-in query
// issued INSIDE the showcase transaction, Timestamp handling, and a weigh-in
// refresh racing a workout write over the same users_public document.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

const CHIN = 'XM9026peNIu0R8qh7UqY';
const BENCH = 'AmfUWbF1DH3I7qPAdh5k';

let store;

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  store = require('../showcase/firestore_store');
});

function workout(exerciseId, sets) {
  return { exercises: [{ exerciseId, name: 'x', sets }] };
}

let seq = 0;
function freshUid() {
  seq += 1;
  return `bodyweight_${Date.now()}_${seq}`;
}

async function wipe(uid) {
  const db = admin.firestore();
  await db.recursiveDelete(db.collection('users').doc(uid));
  await db.collection('users_public').doc(uid).delete().catch(() => {});
}

/** A weigh-in exactly as BodyWeightTracker writes it: device-local noon. */
async function weighIn(uid, dateKey, weight, extra) {
  const [y, m, d] = dateKey.split('-').map(Number);
  // Noon NZST (UTC+12) — the winter dates below are all NZST.
  const ts = admin.firestore.Timestamp.fromMillis(Date.UTC(y, m - 1, d, 0, 0, 0));
  return admin
    .firestore()
    .collection('users')
    .doc(uid)
    .collection('weights')
    .add(Object.assign({ weight, unit: 'kg', tod: 'am', timestamp: ts }, extra || {}));
}

test('a Chin-Up record is published with the bodyweight for its own date', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-05-31', 85);
    await weighIn(uid, '2026-06-14', 83.4);
    await weighIn(uid, '2026-06-20', 80); // after both lifts
    // Best E1RM: 120 × 8 at 85 kg (+64.0); heaviest: 142 × 2 at 83.4 (+58.6).
    await store.applyWorkoutDayTransactionally(uid, '2026-06-01',
      workout(CHIN, [{ weight: 120, reps: 8 }]));
    await store.applyWorkoutDayTransactionally(uid, '2026-06-15',
      workout(CHIN, [{ weight: 142, reps: 2 }]));

    const chin = (await store.readPublishedSnapshot(uid)).lifts.chinUp;
    assert.equal(chin.e1rm.weight, 120);
    assert.equal(chin.e1rm.bodyweightKg, 85);
    assert.equal(chin.e1rm.bodyweightDateKey, '2026-05-31');
    assert.equal(chin.e1rm.loadBasis, 'absolute');
    assert.equal(chin.e1rm.addedKg, 35);
    assert.equal(chin.heaviest.weight, 142);
    assert.equal(chin.heaviest.bodyweightKg, 83.4);
    assert.equal(chin.heaviest.bodyweightDateKey, '2026-06-14');
  } finally {
    await wipe(uid);
  }
});

test('with no weigh-in on or before the lift, no bodyweight is published', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-07-01', 80);
    await weighIn(uid, '2026-05-01', 190, { unit: 'lb' });
    await store.applyWorkoutDayTransactionally(uid, '2026-06-01',
      workout(CHIN, [{ setIndex: 0, weight: 20, reps: 5 }]));
    const r = (await store.readPublishedSnapshot(uid)).lifts.chinUp.e1rm;
    assert.equal(r.loadBasis, 'added');
    assert.equal('bodyweightKg' in r, false);
    assert.equal('bodyweightDateKey' in r, false);
  } finally {
    await wipe(uid);
  }
});

test('a weigh-in logged after training refreshes only the bodyweight, once', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-05-20', 86);
    await store.applyWorkoutDayTransactionally(uid, '2026-06-01',
      workout(CHIN, [{ weight: 138.5, reps: 3 }]));
    const before = await store.readPublishedSnapshot(uid);
    assert.equal(before.lifts.chinUp.e1rm.bodyweightKg, 86);

    await weighIn(uid, '2026-06-01', 85);
    const first = await store.refreshBodyweightTransactionally(uid);
    assert.equal(first.changed, true);
    const after = await store.readPublishedSnapshot(uid);
    assert.equal(after.lifts.chinUp.e1rm.bodyweightKg, 85);
    assert.equal(after.lifts.chinUp.e1rm.fingerprint, before.lifts.chinUp.e1rm.fingerprint);
    assert.equal(after.lifts.chinUp.e1rm.weight, 138.5);

    const second = await store.refreshBodyweightTransactionally(uid);
    assert.deepEqual(second, { changed: false, reason: 'unchanged' });
  } finally {
    await wipe(uid);
  }
});

test('a refresh for an account with no Chin-Up record writes nothing', async () => {
  const uid = freshUid();
  try {
    await store.applyWorkoutDayTransactionally(uid, '2026-06-01',
      workout(BENCH, [{ weight: 120, reps: 3 }]));
    const before = await store.readPublishedSnapshot(uid);
    await weighIn(uid, '2026-06-01', 85);
    const r = await store.refreshBodyweightTransactionally(uid);
    assert.deepEqual(r, { changed: false, reason: 'no-bodyweight-lift' });
    assert.deepEqual(await store.readPublishedSnapshot(uid), before);
    assert.equal('bodyweightKg' in before.lifts.bench.e1rm, false);
  } finally {
    await wipe(uid);
  }
});

test('a refresh racing a workout write loses neither', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-05-31', 85);
    await store.applyWorkoutDayTransactionally(uid, '2026-06-01',
      workout(CHIN, [{ weight: 138.5, reps: 3 }]));
    await weighIn(uid, '2026-06-01', 84);

    await Promise.all([
      store.refreshBodyweightTransactionally(uid),
      store.applyWorkoutDayTransactionally(uid, '2026-06-02',
        workout(BENCH, [{ weight: 120, reps: 3 }])),
    ]);

    const snap = await store.readPublishedSnapshot(uid);
    assert.ok(snap.lifts.bench, 'the bench day survives the refresh');
    assert.equal(snap.lifts.chinUp.e1rm.bodyweightKg, 84, 'the refresh survives the bench day');
  } finally {
    await wipe(uid);
  }
});

test('a back-filled weigh-in re-ranks Chin-Up days inside the refresh transaction', async () => {
  const uid = freshUid();
  const db = admin.firestore();
  try {
    await weighIn(uid, '2026-04-01', 85);
    // Legacy +53.5 × 3 at 85 kg: +61.6.
    await store.applyWorkoutDayTransactionally(uid, '2026-05-01',
      workout(CHIN, [{ weight: 138.5, weightAdded: 53.5, reps: 3 }]));
    // WES2 +70 × 3 on a day before any weigh-in: its E1RM is not known yet.
    await store.applyWorkoutDayTransactionally(uid, '2026-03-10',
      workout(CHIN, [{ setIndex: 0, weight: 70, reps: 3 }]));
    let chin = (await store.readPublishedSnapshot(uid)).lifts.chinUp;
    assert.equal(chin.e1rm.dateKey, '2026-05-01');

    await weighIn(uid, '2026-03-09', 84);
    const r = await store.refreshBodyweightTransactionally(uid, { sinceDateKey: '2026-03-09' });
    assert.equal(r.changed, true);
    chin = (await store.readPublishedSnapshot(uid)).lifts.chinUp;
    assert.equal(chin.e1rm.dateKey, '2026-03-10', 'E1RM(154 × 3) − 84 = +79.1');
    assert.equal(chin.e1rm.bodyweightKg, 84);
    assert.equal(chin.e1rm.totalKg, 154);
    assert.equal(chin.e1rm.weight, 70, 'the stored set is untouched');
    const day = await db.collection('users').doc(uid)
      .collection('showcaseDays').doc('chinUp__2026-03-10').get();
    assert.deepEqual(day.data().bodyweight, { weightKg: 84, dateKey: '2026-03-09' });

    assert.deepEqual(
      await store.refreshBodyweightTransactionally(uid, { sinceDateKey: '2026-03-09' }),
      { changed: false, reason: 'unchanged' },
    );
  } finally {
    await wipe(uid);
  }
});

test('the offline rebuild annotates exactly as the triggers do', async () => {
  const uid = freshUid();
  const db = admin.firestore();
  try {
    await weighIn(uid, '2026-05-31', 85);
    const day = workout(CHIN, [{ weight: 138.5, reps: 3 }]);
    await db.collection('users').doc(uid).collection('workouts').doc('2026-06-01').set(day);
    await store.applyWorkoutDayTransactionally(uid, '2026-06-01', day);
    const published = await store.readPublishedSnapshot(uid);

    const { snapshot } = await store.rebuildAthlete(uid, { apply: false });
    delete published.updatedAtMs;
    assert.deepEqual(snapshot, published);
  } finally {
    await wipe(uid);
  }
});
