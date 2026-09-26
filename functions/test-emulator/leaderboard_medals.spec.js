'use strict';

// PRODUCTION-ADAPTER tests for the leaderboard category medals, against the
// Firestore emulator: the transactional snapshot refresh with its bounded
// podium queries, the entry-write trigger handler, concurrency, out-of-order
// delivery, identity-only writes, withdrawal, the dirty-board safety net, and
// the one-time backfill's dry run / apply / verify.
//
// Months far in the future (2031-xx) keep these boards isolated from the
// other emulator specs.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
const SQUAT = 'heeBViVINHO6tUScSd6y';
const SUMO = '10pEctikt6PP8eAg9Eip';
const DIP = 'FtayDmR5BVnGS1FXlXLL';

let showcase;
let lb;
let medalsFs;
let M;
let backfill;

test.before(() => {
  assert.ok(process.env.FIRESTORE_EMULATOR_HOST, 'run through `npm run test:emulator`');
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  showcase = require('../showcase/firestore_store');
  lb = require('../leaderboard/firestore_store');
  medalsFs = require('../leaderboard/medals_firestore');
  M = require('../leaderboard/medals');
  backfill = require('../scripts/backfill_leaderboard_medals');
});

const db = () => admin.firestore();
const workout = (...rows) => ({ exercises: rows.map(([exerciseId, sets]) => ({ exerciseId, name: 'x', sets })) });

let seq = 0;
function freshUid(tag) {
  seq += 1;
  return `md_${tag || 'u'}_${Date.now()}_${seq}`;
}

async function snapshotOf(p) {
  const s = await medalsFs.medalsRef(p).get();
  return s.exists ? s.data() : null;
}

async function entriesOf(p) {
  const q = await lb.periodRef(p).collection('entries').get();
  return new Map(q.docs.map((d) => [d.id, d.data()]));
}

/**
 * Runs [fn] and then, for every entry of [periods] it created, changed or
 * deleted, the medal trigger handler — what leaderboardMedalsOnEntryWrite
 * does in production.
 */
async function withTriggers(periods, fn) {
  const before = new Map();
  for (const p of periods) before.set(p, await entriesOf(p));
  const out = await fn();
  const results = [];
  for (const p of periods) {
    const after = await entriesOf(p);
    for (const uid of new Set([...before.get(p).keys(), ...after.keys()])) {
      const b = before.get(p).get(uid) || null;
      const a = after.get(uid) || null;
      if (JSON.stringify(b) === JSON.stringify(a)) continue;
      if (!M.entryWriteAffectsMedals(b, a, null, require('../leaderboard/reducer').LEADERBOARD_FORMULA_VERSION)) {
        results.push({ p, uid, path: 'skipped' });
        continue;
      }
      results.push(Object.assign({ p, uid }, await medalsFs.handleEntryWrite(p, uid, b, a)));
    }
  }
  return { out, results };
}

async function weighIn(uid, dateKey, weight) {
  const [y, m, d] = dateKey.split('-').map(Number);
  return db().collection('users').doc(uid).collection('weights')
    .add({ weight, unit: 'kg', tod: 'am', timestamp: admin.firestore.Timestamp.fromMillis(Date.UTC(y, m - 1, d, 0, 0, 0)) });
}

/** showcaseOnWorkoutWrite + the users_public trigger for one workout write. */
async function logWorkout(uid, dateKey, data) {
  const ref = db().collection('users').doc(uid).collection('workouts').doc(dateKey);
  if (data) await ref.set(data);
  else await ref.delete();
  const v2 = await showcase.applyWorkoutDayV2Transactionally(uid, dateKey, data);
  if (v2.changed && v2.path !== 'queued') await lb.applyForWorkout(uid, dateKey);
  await showcase.runRebuildFor(uid);
  const pub = (await db().collection('users_public').doc(uid).get()).data();
  await lb.handlePublicProfileWrite(uid, { username: pub.username }, pub);
}

async function athlete(tag, sex) {
  const uid = freshUid(tag);
  await db().collection('users').doc(uid).set({ sex: sex || 'M', email: `${tag}@private` });
  await db().collection('users_public').doc(uid).set({ username: tag, photoURL: `https://p/${tag}.jpg` });
  await weighIn(uid, '2030-12-01', 80);
  return uid;
}

async function wipe(uids, periods) {
  for (const uid of uids) {
    await db().recursiveDelete(db().collection('users').doc(uid));
    await db().collection('users_public').doc(uid).delete().catch(() => {});
    for (const p of [...periods, 'all_time', lb.currentPeriodKey()]) await lb.entryRef(p, uid).delete().catch(() => {});
    await lb.queueRef(uid).delete().catch(() => {});
    await showcase.jobRef(uid).delete().catch(() => {});
  }
  for (const p of periods) {
    await medalsFs.medalsRef(p).delete().catch(() => {});
    await medalsFs.medalQueueRef(p).delete().catch(() => {});
  }
  // all_time is shared: refresh it so it no longer names wiped athletes.
  await medalsFs.refreshMedals('all_time');
}

test('workouts → entries → podium: gold/silver/bronze per category, fewer than three allowed', async () => {
  const P = '2031-01';
  const [a, b, c, d] = [await athlete('ann'), await athlete('bob'), await athlete('cat'), await athlete('dan')];
  try {
    await withTriggers([P], async () => {
      await logWorkout(a, '2031-01-05', workout([BENCH, [{ weight: 100, reps: 1 }]], [SQUAT, [{ weight: 150, reps: 1 }]]));
      await logWorkout(b, '2031-01-06', workout([BENCH, [{ weight: 110, reps: 1 }]]));
      await logWorkout(c, '2031-01-07', workout([BENCH, [{ weight: 90, reps: 1 }]]));
      await logWorkout(d, '2031-01-08', workout([BENCH, [{ weight: 80, reps: 1 }]]));
    });
    const s = await snapshotOf(P);
    assert.equal(s.schema, 'leaderboardMedals');
    assert.equal(s.boardType, 'month');
    assert.equal(s.monthKey, P);
    assert.deepEqual(s.categories.horizontalPress.map((w) => [w.uid, w.place]), [[b, 1], [a, 2], [c, 3]]);
    assert.deepEqual(s.categories.squatPattern.map((w) => w.uid), [a], 'one eligible user → one medal');
    assert.deepEqual(s.categories.hipHinge, []);
    const e = (await lb.entryRef(P, b).get()).data();
    assert.equal(s.categories.horizontalPress[0].pointsUnits, e.categoryTotalsUnits.horizontalPress);
    assert.equal(s.categories.horizontalPress[0].achievedDateKey, '2031-01-06');
    assert.ok(!JSON.stringify(s).includes('@private'));

    // Update and delete move medals; the refresh reads live entries.
    await withTriggers([P], () => logWorkout(d, '2031-01-08', workout([BENCH, [{ weight: 130, reps: 1 }]])));
    assert.deepEqual((await snapshotOf(P)).categories.horizontalPress.map((w) => w.uid), [d, b, a]);
    await withTriggers([P], () => logWorkout(d, '2031-01-08', null));
    assert.deepEqual((await snapshotOf(P)).categories.horizontalPress.map((w) => w.uid), [b, a, c]);
  } finally {
    await wipe([a, b, c, d], [P]);
  }
});

test('all time uses the profile winning record; identity-only changes never reallocate', async () => {
  const [a, b] = [await athlete('eve'), await athlete('fay')];
  try {
    await withTriggers(['all_time'], async () => {
      await logWorkout(a, '2031-02-03', workout([DIP, [{ weight: 20, reps: 5 }]]));
      await logWorkout(b, '2031-02-04', workout([DIP, [{ weight: 10, reps: 5 }]]));
    });
    const s = await snapshotOf('all_time');
    const mine = s.categories.overheadPress.filter((w) => w.uid === a || w.uid === b);
    assert.deepEqual(mine.map((w) => w.uid), [a, b]);
    assert.equal(mine[0].exerciseId, DIP);
    assert.equal(mine[0].recordDateKey, '2031-02-03');
    const pubA = (await db().collection('users_public').doc(a).get()).data();
    assert.equal(mine[0].pointsUnits, Math.round(pubA.profileShowcaseV2.categories.overheadPress.exercises[DIP].rePoints * 10000));

    // Rename + new avatar: entries change, medal order does not.
    const rev = s.revision;
    const { results } = await withTriggers(['all_time'], async () => {
      const before = pubA;
      const after = Object.assign({}, pubA, { username: 'eve2', photoURL: 'https://p/new.jpg' });
      await db().collection('users_public').doc(a).set(after);
      await lb.handlePublicProfileWrite(a, before, after);
    });
    assert.ok(results.every((r) => r.path === 'skipped'), JSON.stringify(results));
    assert.equal((await snapshotOf('all_time')).revision, rev);
    assert.equal((await lb.entryRef('all_time', a).get()).data().username, 'eve2');
  } finally {
    await wipe([a, b], ['2031-02']);
  }
});

test('account withdrawal removes its live medals', async () => {
  const [a, b] = [await athlete('gus'), await athlete('hal')];
  try {
    await withTriggers(['all_time'], async () => {
      await logWorkout(a, '2031-03-03', workout([SUMO, [{ weight: 300, reps: 1 }]]));
      await logWorkout(b, '2031-03-04', workout([SUMO, [{ weight: 250, reps: 1 }]]));
    });
    let uids = (await snapshotOf('all_time')).categories.hipHinge.map((w) => w.uid);
    assert.ok(uids.includes(a));
    const pub = (await db().collection('users_public').doc(a).get()).data();
    await withTriggers(['all_time'], async () => {
      await db().collection('users_public').doc(a).delete();
      await lb.handlePublicProfileWrite(a, pub, null);
    });
    uids = (await snapshotOf('all_time')).categories.hipHinge.map((w) => w.uid);
    assert.ok(!uids.includes(a), 'withdrawn athlete holds no live medal');
  } finally {
    await wipe([a, b], ['2031-03']);
  }
});

test('concurrent refreshes and interleaved entry writes converge on the full allocation', async () => {
  const P = '2031-04';
  const uids = [];
  try {
    for (let i = 0; i < 6; i += 1) uids.push(await athlete(`c${i}`));
    for (let i = 0; i < 6; i += 1) await logWorkout(uids[i], `2031-04-0${i + 1}`, workout([SQUAT, [{ weight: 100 + i * 10, reps: 1 }]]));
    const writes = uids.slice(0, 3).map((u, i) => logWorkout(u, `2031-04-0${i + 1}`, workout([SQUAT, [{ weight: 300 - i, reps: 1 }]])));
    const refreshes = Array.from({ length: 6 }, () => medalsFs.refreshMedals(P));
    await Promise.all([...writes, ...refreshes]);
    await medalsFs.refreshMedals(P);
    const live = [...(await entriesOf(P)).entries()].map(([uid, e]) => Object.assign({ uid }, e));
    const expected = backfill.allocateFromEntries(P, live);
    const s = await snapshotOf(P);
    assert.equal(M.awardsFingerprint(s.categories), M.awardsFingerprint(expected));
    assert.deepEqual(s.categories.squatPattern.map((w) => w.uid), [uids[0], uids[1], uids[2]]);
    // Idempotent: one more refresh writes nothing.
    const again = await medalsFs.refreshMedals(P);
    assert.equal(again.path, 'unchanged');
  } finally {
    await wipe(uids, [P]);
  }
});

test('an out-of-order (older) event cannot overwrite a newer allocation', async () => {
  const P = '2031-05';
  const [a, b] = [await athlete('ian'), await athlete('jo')];
  try {
    await withTriggers([P], async () => {
      await logWorkout(a, '2031-05-02', workout([BENCH, [{ weight: 100, reps: 1 }]]));
      await logWorkout(b, '2031-05-02', workout([BENCH, [{ weight: 90, reps: 1 }]]));
    });
    const old = (await lb.entryRef(P, b).get()).data();
    await withTriggers([P], () => logWorkout(b, '2031-05-02', workout([BENCH, [{ weight: 150, reps: 1 }]])));
    const cur = (await lb.entryRef(P, b).get()).data();
    assert.deepEqual((await snapshotOf(P)).categories.horizontalPress.map((w) => w.uid), [b, a]);
    // The OLD event (cur → old) arrives late: the handler reads live entries.
    await medalsFs.handleEntryWrite(P, b, cur, old);
    await medalsFs.handleEntryWrite(P, b, null, old);
    assert.deepEqual((await snapshotOf(P)).categories.horizontalPress.map((w) => w.uid), [b, a]);
  } finally {
    await wipe([a, b], [P]);
  }
});

test('dirty boards are refreshed and cleared by the reconciliation deps', async () => {
  const P = '2031-06';
  const [a] = [await athlete('kim')];
  try {
    await logWorkout(a, '2031-06-02', workout([BENCH, [{ weight: 100, reps: 1 }]]));
    assert.equal(await snapshotOf(P), null, 'no trigger ran: no snapshot yet');
    await medalsFs.markMedalBoardDirty(P, 'test');
    const deps = lb.reconcileDeps(Date.now());
    const dirty = (await deps.listDirtyMedalBoards(50)).filter((x) => x.periodKey === P);
    assert.equal(dirty.length, 1);
    await deps.refreshMedals(P);
    await deps.clearMedalBoard(dirty[0]);
    assert.deepEqual((await snapshotOf(P)).categories.horizontalPress.map((w) => w.uid), [a]);
    assert.equal((await medalsFs.medalQueueRef(P).get()).exists, false);
  } finally {
    await wipe([a], [P]);
  }
});

test('backfill: dry run writes nothing; apply patches only medal fields and writes snapshots; verify is clean', async () => {
  const P = '2031-07';
  const [a, b] = [await athlete('lee'), await athlete('max')];
  const quiet = () => {};
  try {
    await logWorkout(a, '2031-07-02', workout([SQUAT, [{ weight: 180, reps: 1 }]]));
    await logWorkout(b, '2031-07-03', workout([SQUAT, [{ weight: 170, reps: 1 }]]));
    // Simulate entries written before the medal fields existed.
    const FV = admin.firestore.FieldValue;
    for (const u of [a, b]) {
      await lb.entryRef(P, u).update({ categoryDateKeys: FV.delete(), medalRankKeys: FV.delete(), username: `old-${u}` });
    }
    const before = await entriesOf(P);

    const dry = await backfill.run({ projectId: 'rules-test', period: P }, quiet);
    assert.equal(dry.counts.patch, 2);
    assert.equal(dry.counts.snapshotsCreate, 1);
    assert.equal(await snapshotOf(P), null, 'dry run wrote no snapshot');
    assert.deepEqual(await entriesOf(P), before, 'dry run wrote no entry');

    const applied = await backfill.run({ projectId: 'rules-test', period: P, apply: true }, quiet);
    assert.equal(applied.counts.patched, 2);
    const after = await entriesOf(P);
    for (const u of [a, b]) {
      const x = Object.assign({}, after.get(u));
      assert.ok(x.medalRankKeys.squatPattern);
      assert.equal(x.username, `old-${u}`, 'identity untouched');
      delete x.medalRankKeys;
      delete x.categoryDateKeys;
      assert.deepEqual(x, before.get(u), 'nothing else changed');
    }
    assert.deepEqual((await snapshotOf(P)).categories.squatPattern.map((w) => w.uid), [a, b]);

    // Resumable/idempotent: a rerun skips the finished board.
    const rerun = await backfill.run({ projectId: 'rules-test', period: P, apply: true }, quiet);
    assert.equal(rerun.counts.boardsSkippedDone, 1);

    const verified = await backfill.run({ projectId: 'rules-test', period: P, verify: true }, quiet);
    assert.equal(verified.counts.verifyMismatches, 0, JSON.stringify(verified.problems));
    assert.deepEqual(verified.problems.filter((p) => p.startsWith(P)), []);
  } finally {
    await db().doc(`migrations/leaderboardMedalsBackfill/progress/${P}`).delete().catch(() => {});
    await wipe([a, b], [P]);
  }
});
