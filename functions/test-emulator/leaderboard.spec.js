'use strict';

// PRODUCTION-ADAPTER tests for the RE Points leaderboard, against the
// Firestore emulator: the real document layout, the transactional month
// re-sum, the users_public-driven all-time entry, identity propagation, the
// queue and the reconciliation's Firestore dependencies, and the ordered,
// paginated query the app issues.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
const SQUAT = 'heeBViVINHO6tUScSd6y';
const SUMO = '10pEctikt6PP8eAg9Eip';

let showcase;
let lb;
let reCoefficient;

test.before(() => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'run through `npm run test:emulator`');
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  showcase = require('../showcase/firestore_store');
  lb = require('../leaderboard/firestore_store');
  reCoefficient = require('../showcase/re_points').reCoefficient;
});

const db = () => admin.firestore();
const workout = (...rows) => ({ exercises: rows.map(([exerciseId, sets]) => ({ exerciseId, name: 'x', sets })) });
const units = (e1rm, factor, bw) => Math.round(Number((e1rm * factor * reCoefficient('male', bw)).toFixed(4)) * 10000);

let seq = 0;
function freshUid() {
  seq += 1;
  return `lb_${Date.now()}_${seq}`;
}

async function wipe(uid) {
  await db().recursiveDelete(db().collection('users').doc(uid));
  await db().collection('users_public').doc(uid).delete().catch(() => {});
  for (const p of ['2026-08', '2026-09', 'all_time', lb.currentPeriodKey()]) {
    await lb.entryRef(p, uid).delete().catch(() => {});
  }
  await lb.queueRef(uid).delete().catch(() => {});
}

async function weighIn(uid, dateKey, weight) {
  const [y, m, d] = dateKey.split('-').map(Number);
  return db().collection('users').doc(uid).collection('weights')
    .add({ weight, unit: 'kg', tod: 'am', timestamp: admin.firestore.Timestamp.fromMillis(Date.UTC(y, m - 1, d, 0, 0, 0)) });
}

/** What showcaseOnWorkoutWrite does for one workout write. */
async function logWorkout(uid, dateKey, data) {
  const ref = db().collection('users').doc(uid).collection('workouts').doc(dateKey);
  if (data) await ref.set(data);
  else await ref.delete();
  const v2 = await showcase.applyWorkoutDayV2Transactionally(uid, dateKey, data);
  if (v2.changed) await lb.applyForWorkout(uid, dateKey, { full: v2.path === 'bootstrap' });
  return v2;
}

/** Runs the leaderboardOnPublicProfileWrite handler for a users_public change. */
async function firePublic(uid, before, after) {
  return lb.handlePublicProfileWrite(uid, before, after);
}

test('a workout builds day, month and (via users_public) all-time entries', async () => {
  const uid = freshUid();
  try {
    await db().collection('users').doc(uid).set({ sex: 'M', email: 'private@x' });
    await db().collection('users_public').doc(uid).set({ username: 'amy', photoURL: 'https://p/a.jpg' });
    await weighIn(uid, '2026-09-01', 80);
    await logWorkout(uid, '2026-09-02', workout([BENCH, [{ weight: 100, reps: 1 }]], [SQUAT, [{ weight: 150, reps: 1 }]]));
    await logWorkout(uid, '2026-09-03', workout([BENCH, [{ weight: 90, reps: 1 }]]));

    const day = (await lb.daysCol(uid).doc('2026-09-02').get()).data();
    assert.equal(day.periodKey, '2026-09');
    assert.equal(day.totalPointsUnits, units(100, 1, 80) + units(150, 0.8, 80));
    const month = (await lb.entryRef('2026-09', uid).get()).data();
    assert.equal(month.totalPointsUnits, units(100, 1, 80) + units(150, 0.8, 80) + units(90, 1, 80));
    assert.equal(month.username, 'amy');
    assert.equal(month.scoredDayCount, 2);
    assert.ok(!JSON.stringify(month).includes('private@x'));
    const period = (await lb.periodRef('2026-09').get()).data();
    assert.ok(period && period.periodKey === '2026-09');

    // users_public now carries profileShowcaseV2; its trigger writes all time.
    const pub = (await db().collection('users_public').doc(uid).get()).data();
    await firePublic(uid, { username: 'amy' }, pub);
    const at = (await lb.entryRef('all_time', uid).get()).data();
    assert.equal(at.totalPointsUnits, units(100, 1, 80) + units(150, 0.8, 80));
  } finally {
    await wipe(uid);
  }
});

test('edit, delete and replayed events converge; deleting the last day withdraws the entry', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-09-01', 80);
    const w = workout([SUMO, [{ weight: 200, reps: 1 }]]);
    await logWorkout(uid, '2026-09-05', w);
    await lb.applyForWorkout(uid, '2026-09-05');
    await lb.applyForWorkout(uid, '2026-09-05');
    let month = (await lb.entryRef('2026-09', uid).get()).data();
    assert.equal(month.totalPointsUnits, units(200, 0.74, 80));
    await logWorkout(uid, '2026-09-05', workout([SUMO, [{ weight: 150, reps: 1 }]]));
    month = (await lb.entryRef('2026-09', uid).get()).data();
    assert.equal(month.totalPointsUnits, units(150, 0.74, 80));
    await logWorkout(uid, '2026-09-05', null);
    assert.equal((await lb.entryRef('2026-09', uid).get()).exists, false);
    assert.equal((await lb.daysCol(uid).doc('2026-09-05').get()).exists, false);
  } finally {
    await wipe(uid);
  }
});

test('concurrent changes to one month both count', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-09-01', 80);
    await logWorkout(uid, '2026-09-02', workout([BENCH, [{ weight: 100, reps: 1 }]]));
    const a = workout([BENCH, [{ weight: 101, reps: 1 }]]);
    const b = workout([SQUAT, [{ weight: 140, reps: 1 }]]);
    await db().collection('users').doc(uid).collection('workouts').doc('2026-09-10').set(a);
    await db().collection('users').doc(uid).collection('workouts').doc('2026-09-11').set(b);
    await Promise.all([
      showcase.applyWorkoutDayV2Transactionally(uid, '2026-09-10', a),
      showcase.applyWorkoutDayV2Transactionally(uid, '2026-09-11', b),
    ]);
    await Promise.all([lb.applyForWorkout(uid, '2026-09-10'), lb.applyForWorkout(uid, '2026-09-11')]);
    const month = (await lb.entryRef('2026-09', uid).get()).data();
    assert.equal(month.totalPointsUnits, units(100, 1, 80) + units(101, 1, 80) + units(140, 0.8, 80));
  } finally {
    await wipe(uid);
  }
});

test('a back-dated weigh-in re-scores only the dates it governs', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-09-01', 80);
    await logWorkout(uid, '2026-09-05', workout([BENCH, [{ weight: 100, reps: 1 }]]));
    await logWorkout(uid, '2026-09-12', workout([BENCH, [{ weight: 100, reps: 1 }]]));
    await logWorkout(uid, '2026-09-20', workout([BENCH, [{ weight: 100, reps: 1 }]]));
    await weighIn(uid, '2026-09-18', 80);
    const ref = await weighIn(uid, '2026-09-10', 90);
    const snap = await ref.get();
    const event = { data: { before: { exists: false }, after: snap } };
    const range = await lb.weighInRange(uid, event);
    assert.deepEqual(range, { sinceDateKey: '2026-09-10', untilDateKey: '2026-09-18' });
    await lb.applyForWeighIn(uid, event);
    const d = async (k) => (await lb.daysCol(uid).doc(k).get()).data().totalPointsUnits;
    assert.equal(await d('2026-09-05'), units(100, 1, 80));
    assert.equal(await d('2026-09-12'), units(100, 1, 90));
    assert.equal(await d('2026-09-20'), units(100, 1, 80));
  } finally {
    await wipe(uid);
  }
});

test('ranked query: server ordering, deterministic ties, pagination', async () => {
  const period = '2026-08';
  const col = lb.periodRef(period).collection('entries');
  const rows = [
    { uid: 'zz_c', totalPointsUnits: 500, tieBreakDateKey: '2026-08-02' },
    { uid: 'zz_a', totalPointsUnits: 500, tieBreakDateKey: '2026-08-02' },
    { uid: 'zz_b', totalPointsUnits: 500, tieBreakDateKey: '2026-08-01' },
    { uid: 'zz_d', totalPointsUnits: 900, tieBreakDateKey: '2026-08-20' },
    { uid: 'zz_e', totalPointsUnits: 0, tieBreakDateKey: '2026-08-20' },
  ];
  try {
    for (const r of rows) await col.doc(r.uid).set(r);
    const q = () => col.where('totalPointsUnits', '>', 0)
      .orderBy('totalPointsUnits', 'desc').orderBy('tieBreakDateKey').orderBy('uid');
    const first = await q().limit(2).get();
    const rest = await q().startAfter(first.docs[1]).limit(10).get();
    assert.deepEqual(
      [...first.docs, ...rest.docs].map((d) => d.id),
      ['zz_d', 'zz_b', 'zz_a', 'zz_c'],
    );
  } finally {
    for (const r of rows) await col.doc(r.uid).delete();
  }
});

test('identity change updates the current month and all time only; deletion withdraws live entries', async () => {
  const uid = freshUid();
  const current = lb.currentPeriodKey();
  try {
    await lb.entryRef(current, uid).set({ uid, username: 'old', totalPointsUnits: 10 });
    await lb.entryRef('2026-08', uid).set({ uid, username: 'old', totalPointsUnits: 10 });
    await db().collection('users_public').doc(uid).set({ username: 'new', photoURL: 'https://p/n.jpg' });
    await firePublic(uid, { username: 'old' }, { username: 'new', photoURL: 'https://p/n.jpg' });
    assert.equal((await lb.entryRef(current, uid).get()).data().username, 'new');
    assert.equal((await lb.entryRef('2026-08', uid).get()).data().username, 'old', 'history keeps its snapshot');

    await db().collection('users_public').doc(uid).delete();
    await firePublic(uid, { username: 'new' }, null);
    assert.equal((await lb.entryRef(current, uid).get()).exists, false);
    assert.equal((await lb.entryRef('all_time', uid).get()).exists, false);
    assert.equal((await lb.entryRef('2026-08', uid).get()).exists, true);
  } finally {
    await lb.entryRef('2026-08', uid).delete();
    await wipe(uid);
  }
});

test('queue + reconciliation deps: enqueue merges, processing clears, months close', async () => {
  const uid = freshUid();
  try {
    await weighIn(uid, '2026-09-01', 80);
    await logWorkout(uid, '2026-09-02', workout([BENCH, [{ weight: 100, reps: 1 }]]));
    await lb.enqueueRecalc(uid, { dateKeys: ['2026-09-02'] }, 'test');
    await lb.enqueueRecalc(uid, { sinceDateKey: '2026-09-01' }, 'test2');
    const item = (await lb.queueRef(uid).get()).data();
    assert.deepEqual(item.dates, ['2026-09-02']);
    assert.equal(item.sinceDateKey, '2026-09-01');

    await lb.periodRef('2020-01').set({ periodKey: '2020-01', status: 'open' });
    const { runReconciliation } = require('../leaderboard/reconcile');
    const { counts } = await runReconciliation(lb.reconcileDeps(Date.now()), { maxUsers: 50 });
    assert.ok(counts.succeeded >= 1);
    assert.equal((await lb.queueRef(uid).get()).exists, false);
    assert.equal((await lb.periodRef('2020-01').get()).data().status, 'closed');
    assert.equal((await lb.entryRef('2026-09', uid).get()).data().totalPointsUnits, units(100, 1, 80));
  } finally {
    await lb.periodRef('2020-01').delete();
    await wipe(uid);
  }
});
