'use strict';

// The RE Points leaderboard: daily category winners, monthly sums, all-time
// from the profile, and the recompute / reconciliation / backfill paths.
//
// Workouts go through the REAL profile V2 store (showcase/store_v2) and the
// leaderboard reads its day contributions, exactly as in production.

const test = require('node:test');
const assert = require('node:assert');

const { applyWorkoutDayV2, refreshV2, memoryStoreV2 } = require('../showcase/store_v2');
const { pickBodyweightAsOf } = require('../showcase/bodyweight');
const { showcaseE1rm } = require('../showcase/e1rm_spec');
const { reCoefficient, Sex, RE_POINTS_FORMULA_VERSION } = require('../showcase/re_points');
const { RE_EXERCISES, reExerciseById } = require('../showcase/re_catalog');
const {
  scoreDay,
  toUnits,
  periodKeyOf,
  monthEntryFromDays,
  allTimeEntryFromSnapshot,
  identityOf,
  LEADERBOARD_FORMULA_VERSION,
  ALL_TIME_PERIOD,
} = require('../leaderboard/reducer');
const { applyRequest, refreshAllTime, memoryLeaderboardStore, isBuilt } = require('../leaderboard/store');
const { runReconciliation, requestsOfItem, mergeQueueItem } = require('../leaderboard/reconcile');
const { parseArgs } = require('../scripts/backfill_leaderboard');

const ID = {
  bench: 'AmfUWbF1DH3I7qPAdh5k',
  dbBench: 'kTs5fLSTKjUkUZL10iii',
  chin: 'XM9026peNIu0R8qh7UqY',
  lat: '1XOIXxeLFhgmgjZS9Cyq',
  ohpDb: 'RdsGazgdH0xgpjek0n3u',
  dip: 'FtayDmR5BVnGS1FXlXLL',
  deadlift: 'MsGl7e9yanDeEnYX0e4X',
  sumo: '10pEctikt6PP8eAg9Eip',
  squat: 'heeBViVINHO6tUScSd6y',
  bssDb: 'ISXQqOEXLjMrPEs0xjgJ',
};

const row = (exerciseId, sets) => ({ exerciseId, name: 'x', sets });
const workout = (...rows) => ({ exercises: rows });
const units = (e1rm, factor, bw, sex) =>
  toUnits(Number((e1rm * factor * reCoefficient(sex || Sex.MALE, bw)).toFixed(4)));

/** One athlete: profile V2 store + leaderboard store over shared entries. */
function athlete(uid, options) {
  const o = options || {};
  const weighIns = (o.weighIns || []).map(([dateKey, weight], i) => ({ id: `w${i}`, dateKey, weight }));
  let sex = o.sex === undefined ? 'M' : o.sex;
  const bw = (d) => pickBodyweightAsOf(weighIns, d);
  const v2 = memoryStoreV2({ bodyweightAsOf: bw, sex });
  const entries = o.entries || new Map();
  let identity = { username: uid, photoURL: `https://x/${uid}.jpg` };
  const lb = memoryLeaderboardStore(uid, {
    v2Days: () => [...v2._days.values()],
    bodyweightAsOf: bw,
    sex: () => sex,
    publicProfile: async () =>
      Object.assign({}, identity, { email: 'secret@x', sex, profileShowcaseV2: await v2.getSnapshot() }),
    entries,
  });
  return {
    uid,
    v2,
    lb,
    entries,
    weighIns,
    /** A workout write: what showcaseOnWorkoutWrite + the users_public trigger do. */
    async log(dateKey, data) {
      const r = await applyWorkoutDayV2(v2, dateKey, data);
      if (r.changed) {
        await applyRequest(lb, r.path === 'bootstrap' ? { full: true } : { dateKeys: [dateKey] });
        await refreshAllTime(lb); // leaderboardOnPublicProfileWrite
      }
      return r;
    },
    month(p) {
      return entries.get(`${p}/${uid}`) || null;
    },
    allTime() {
      return entries.get(`${ALL_TIME_PERIOD}/${uid}`) || null;
    },
    day(d) {
      return lb._days.get(d) || null;
    },
    setSex(next) {
      sex = next;
      v2.setSex(next);
    },
    setIdentity(next) {
      identity = next;
    },
  };
}

// ── Config parity ───────────────────────────────────────────────────────────

test('scoring config is the profile catalogue (same factors, incl. 0.85 and 2.61)', () => {
  assert.strictEqual(reExerciseById(ID.lat).factor, 0.85);
  assert.strictEqual(reExerciseById(ID.ohpDb).factor, 2.61);
  assert.strictEqual(RE_EXERCISES.length, 13);
  assert.ok(LEADERBOARD_FORMULA_VERSION.includes(`re${RE_POINTS_FORMULA_VERSION}`));
});

test('period key comes from the canonical training date', () => {
  assert.strictEqual(periodKeyOf('2026-09-24'), '2026-09');
  assert.strictEqual(periodKeyOf('2026-10-01'), '2026-10');
  assert.strictEqual(periodKeyOf('bad'), null);
});

// ── Daily winners ───────────────────────────────────────────────────────────

test('best set of an exercise is the one that scores (RIR ignored)', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bench, [
    { weight: 100, reps: 5, rir: 0 },
    { weight: 110, reps: 3, rir: 4 },
    { weight: 90, reps: 8 },
  ])));
  const best = Math.max(showcaseE1rm(100, 5), showcaseE1rm(110, 3), showcaseE1rm(90, 8));
  assert.strictEqual(a.day('2026-09-02').categories.horizontalPress.pointsUnits, units(best, 1, 80));
});

test('best exercise in a category wins the day; only one score per category', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(
    row(ID.bench, [{ weight: 100, reps: 1 }]),
    row(ID.dbBench, [{ weight: 50, reps: 1 }]), // 117.5 > 100
    row(ID.bench, [{ weight: 105, reps: 1 }]), // duplicate row of the same exercise
  ));
  const day = a.day('2026-09-02');
  assert.deepStrictEqual(Object.keys(day.categories), ['horizontalPress']);
  assert.strictEqual(day.categories.horizontalPress.exerciseId, ID.dbBench);
  assert.strictEqual(day.totalPointsUnits, units(50, 2.35, 80));
});

test('multiple workouts on one date still give one category winner', () => {
  // Several workout documents for a date reach the leaderboard already merged
  // into ONE V2 contribution per exercise; two exercises of one category on
  // the date still yield one winner.
  const bw = { weightKg: 80, dateKey: '2026-09-01' };
  const v2Days = [
    { slot: 'deadlift', category: 'hipHinge', dateKey: '2026-09-02', exerciseId: ID.deadlift, bestE1rm: { setKey: 's0', weight: 200, reps: 1 }, heaviest: { setKey: 's0', weight: 200, reps: 1 } },
    { slot: 'deadliftSumo', category: 'hipHinge', dateKey: '2026-09-02', exerciseId: ID.sumo, bestE1rm: { setKey: 's0', weight: 210, reps: 1 }, heaviest: { setKey: 's0', weight: 210, reps: 1 } },
  ];
  const day = scoreDay('2026-09-02', v2Days, bw, Sex.MALE);
  assert.deepStrictEqual(Object.keys(day.categories), ['hipHinge']);
  assert.strictEqual(day.categories.hipHinge.exerciseId, ID.sumo);
});

test('equal scores in a category tie-break to catalogue order', () => {
  const bw = { weightKg: 80, dateKey: '2026-09-01' };
  const mk = (slot, id) => ({ slot, dateKey: '2026-09-02', exerciseId: id, bestE1rm: { setKey: 's0', weight: 200, reps: 1 }, heaviest: { setKey: 's0', weight: 200, reps: 1 } });
  const day = scoreDay('2026-09-02', [mk('deadliftSumo', ID.sumo), mk('deadlift', ID.deadlift)], bw, Sex.MALE);
  assert.strictEqual(day.categories.hipHinge.exerciseId, ID.deadlift);
});

test('different categories on the same date all count', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(
    row(ID.bench, [{ weight: 100, reps: 1 }]),
    row(ID.lat, [{ weight: 80, reps: 1 }]),
    row(ID.ohpDb, [{ weight: 30, reps: 1 }]),
    row(ID.deadlift, [{ weight: 200, reps: 1 }]),
    row(ID.squat, [{ weight: 150, reps: 1 }]),
  ));
  const day = a.day('2026-09-02');
  assert.strictEqual(Object.keys(day.categories).length, 5);
  assert.strictEqual(
    day.totalPointsUnits,
    units(100, 1, 80) + units(80, 0.85, 80) + units(30, 2.61, 80) + units(200, 0.74, 80) + units(150, 0.8, 80),
  );
});

test('Chin-Up and Triceps Dip score the combined bodyweight + added load', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(
    row(ID.chin, [{ weight: 20, reps: 1, setIndex: 0 }]),
    row(ID.dip, [{ weight: 0, reps: 1, setIndex: 0 }]),
  ));
  const day = a.day('2026-09-02');
  assert.strictEqual(day.categories.verticalPull.pointsUnits, units(100, 1, 80));
  assert.strictEqual(day.categories.overheadPress.pointsUnits, units(80, 0.73, 80));
});

test('dumbbell loads are not doubled', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bssDb, [{ weight: 30, reps: 1 }])));
  assert.strictEqual(a.day('2026-09-02').categories.squatPattern.pointsUnits, units(30, 2.5, 80));
});

test('missing bodyweight scores nothing, exactly as on the profile', async () => {
  const a = athlete('a', { weighIns: [] });
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  const day = a.day('2026-09-02');
  assert.strictEqual(day.totalPointsUnits, 0);
  assert.deepStrictEqual(day.categories, {});
  assert.strictEqual(a.month('2026-09'), null);
  const snap = await a.v2.getSnapshot();
  assert.strictEqual(snap.categories.horizontalPress.exercises[ID.bench].rePoints, null);
});

// ── Monthly ─────────────────────────────────────────────────────────────────

test('monthly total sums the daily category winners; a second day adds more', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  assert.strictEqual(a.month('2026-09').totalPointsUnits, units(100, 1, 80));
  // Same category, a weaker lift on another day: it still adds its own day's winner.
  await a.log('2026-09-05', workout(row(ID.bench, [{ weight: 90, reps: 1 }]), row(ID.squat, [{ weight: 120, reps: 1 }])));
  const m = a.month('2026-09');
  assert.strictEqual(m.totalPointsUnits, units(100, 1, 80) + units(90, 1, 80) + units(120, 0.8, 80));
  assert.strictEqual(m.categoryTotalsUnits.horizontalPress, units(100, 1, 80) + units(90, 1, 80));
  assert.strictEqual(m.scoredDayCount, 2);
  assert.strictEqual(m.tieBreakDateKey, '2026-09-05');
  assert.ok(Number.isInteger(m.totalPointsUnits));
});

test('a new month writes a new period and keeps the previous one', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-30', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  await a.log('2026-10-01', workout(row(ID.bench, [{ weight: 102, reps: 1 }])));
  assert.strictEqual(a.month('2026-09').totalPointsUnits, units(100, 1, 80));
  assert.strictEqual(a.month('2026-10').totalPointsUnits, units(102, 1, 80));
  assert.ok(a.lb._periods.has('2026-09') && a.lb._periods.has('2026-10'));
});

test('an edit replaces the prior winner with the next-best surviving set', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 120, reps: 1 }]), row(ID.dbBench, [{ weight: 45, reps: 1 }])));
  assert.strictEqual(a.day('2026-09-02').categories.horizontalPress.exerciseId, ID.bench);
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 60, reps: 1 }]), row(ID.dbBench, [{ weight: 45, reps: 1 }])));
  assert.strictEqual(a.day('2026-09-02').categories.horizontalPress.exerciseId, ID.dbBench);
  assert.strictEqual(a.month('2026-09').totalPointsUnits, units(45, 2.35, 80));
});

test('deletion removes the contribution; deleting the only scored day zeroes the month', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  await a.log('2026-09-03', workout(row(ID.squat, [{ weight: 100, reps: 1 }])));
  await a.log('2026-09-03', null);
  assert.strictEqual(a.day('2026-09-03'), null);
  assert.strictEqual(a.month('2026-09').totalPointsUnits, units(100, 1, 80));
  await a.log('2026-09-02', null);
  assert.strictEqual(a.month('2026-09'), null, 'no scored day left: the entry is withdrawn');
});

test('duplicate and out-of-order delivery never double-counts', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  const w1 = workout(row(ID.bench, [{ weight: 100, reps: 1 }]));
  const w2 = workout(row(ID.squat, [{ weight: 150, reps: 1 }]));
  await a.log('2026-09-10', w2);
  await a.log('2026-09-02', w1);
  const once = a.month('2026-09').totalPointsUnits;
  // Replays of both, and forced recomputes of the same dates.
  await a.log('2026-09-02', w1);
  await a.log('2026-09-10', w2);
  await applyRequest(a.lb, { dateKeys: ['2026-09-02', '2026-09-10'] });
  await applyRequest(a.lb, { dateKeys: ['2026-09-02'] });
  assert.strictEqual(a.month('2026-09').totalPointsUnits, once);
  assert.strictEqual(once, units(100, 1, 80) + units(150, 0.8, 80));
});

test('a targeted recompute equals a full rebuild', async () => {
  const a = athlete('a', { weighIns: [['2026-08-01', 80], ['2026-09-15', 82]] });
  await a.log('2026-08-20', workout(row(ID.deadlift, [{ weight: 180, reps: 3 }])));
  await a.log('2026-09-10', workout(row(ID.bench, [{ weight: 100, reps: 5 }]), row(ID.chin, [{ weight: 10, reps: 5, setIndex: 0 }])));
  await a.log('2026-09-20', workout(row(ID.sumo, [{ weight: 190, reps: 2 }])));
  const incremental = JSON.stringify([...a.entries.entries()].sort());
  const days = JSON.stringify([...a.lb._days.entries()].sort());
  await applyRequest(a.lb, { full: true });
  assert.strictEqual(JSON.stringify([...a.entries.entries()].sort()), incremental);
  assert.strictEqual(JSON.stringify([...a.lb._days.entries()].sort()), days);
});

// ── All time ────────────────────────────────────────────────────────────────

test('all time is one best-ever score per category and matches the profile winners', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }]), row(ID.deadlift, [{ weight: 200, reps: 1 }])));
  await a.log('2026-09-03', workout(row(ID.bench, [{ weight: 110, reps: 1 }]), row(ID.dbBench, [{ weight: 40, reps: 1 }])));
  await a.log('2026-09-04', workout(row(ID.sumo, [{ weight: 190, reps: 1 }])));
  const at = a.allTime();
  assert.strictEqual(at.totalPointsUnits, units(110, 1, 80) + units(200, 0.74, 80));
  assert.strictEqual(at.winningExerciseIds.horizontalPress, ID.bench);
  assert.strictEqual(at.winningExerciseIds.hipHinge, ID.deadlift);
  // Profile agreement, category by category.
  const snap = await a.v2.getSnapshot();
  for (const [cat, c] of Object.entries(snap.categories)) {
    const best = c.exercises[c.bestExerciseId];
    assert.strictEqual(at.categoryBestUnits[cat], toUnits(best.rePoints) || 0, cat);
  }
  // Never the monthly sum.
  assert.ok(at.totalPointsUnits < a.month('2026-09').totalPointsUnits);
});

test('all time refuses a snapshot from another formula version', () => {
  const res = allTimeEntryFromSnapshot('u', { schema: 'profileShowcaseV2', e1rmFormulaVersion: 1, rePointsFormulaVersion: 999, categories: {} }, {});
  assert.strictEqual(res.stale, true);
  assert.strictEqual(res.entry, null);
});

// ── Bodyweight and sex ──────────────────────────────────────────────────────

test('a weigh-in recomputes the affected date range for every exercise', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-05', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  await a.log('2026-09-12', workout(row(ID.squat, [{ weight: 150, reps: 1 }])));
  await a.log('2026-09-20', workout(row(ID.deadlift, [{ weight: 200, reps: 1 }])));
  // A back-dated weigh-in on 09-10, superseded by one on 09-18.
  a.weighIns.push({ id: 'b', dateKey: '2026-09-10', weight: 90 });
  a.weighIns.push({ id: 'c', dateKey: '2026-09-18', weight: 80 });
  await refreshV2(a.v2, { bodyweight: true, sinceDateKey: '2026-09-10' });
  const res = await applyRequest(a.lb, { sinceDateKey: '2026-09-10', untilDateKey: '2026-09-18' });
  assert.strictEqual(res.path, 'range');
  assert.deepStrictEqual(res.days, ['2026-09-12']);
  assert.strictEqual(a.day('2026-09-05').totalPointsUnits, units(100, 1, 80));
  assert.strictEqual(a.day('2026-09-12').totalPointsUnits, units(150, 0.8, 90));
  assert.strictEqual(a.day('2026-09-20').totalPointsUnits, units(200, 0.74, 80));
  assert.strictEqual(
    a.month('2026-09').totalPointsUnits,
    units(100, 1, 80) + units(150, 0.8, 90) + units(200, 0.74, 80),
  );
});

test('a sex change re-scores every day', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 63]] });
  await a.log('2026-09-02', workout(row(ID.lat, [{ weight: 60, reps: 1 }])));
  const male = a.month('2026-09').totalPointsUnits;
  a.setSex('F');
  await refreshV2(a.v2, { sex: true });
  await applyRequest(a.lb, { full: true });
  assert.strictEqual(a.month('2026-09').totalPointsUnits, units(60, 0.85, 63, Sex.FEMALE));
  assert.notStrictEqual(a.month('2026-09').totalPointsUnits, male);
});

// ── Versioning and privacy ──────────────────────────────────────────────────

test('a stale formula version is detected and rebuilt, never mixed', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  assert.ok(isBuilt(await a.lb.getState()));
  await a.lb.setState({ formulaVersion: 'lb0-old' });
  a.lb._days.set('2026-09-02', Object.assign({}, a.day('2026-09-02'), { formulaVersion: 'lb0-old', totalPointsUnits: 1 }));
  const res = await applyRequest(a.lb, { dateKeys: ['2026-09-02'] });
  assert.strictEqual(res.path, 'rebuild');
  assert.strictEqual(a.day('2026-09-02').formulaVersion, LEADERBOARD_FORMULA_VERSION);
  assert.strictEqual(a.month('2026-09').totalPointsUnits, units(100, 1, 80));
  assert.strictEqual(a.month('2026-09').formulaVersion, LEADERBOARD_FORMULA_VERSION);
});

test('public entries carry only uid, identity and points — no private data', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.chin, [{ weight: 20, reps: 1, setIndex: 0 }])));
  for (const e of [a.month('2026-09'), a.allTime()]) {
    const json = JSON.stringify(e);
    assert.ok(!/secret@x|"sex"|bodyweight|"email"/.test(json), json);
    assert.strictEqual(e.username, 'a');
    assert.strictEqual(e.photoURL, 'https://x/a.jpg');
  }
  assert.deepStrictEqual(identityOf({ displayName: ' Bo ', photoUrl: 'p', email: 'e' }), { username: 'Bo', photoURL: 'p' });
});

test('leaderboard is not marked built before the profile V2 exists', async () => {
  const lb = memoryLeaderboardStore('u', { v2Built: false });
  await applyRequest(lb, { dateKeys: ['2026-09-01'] });
  assert.strictEqual(await lb.getState(), null);
});

test('monthEntryFromDays is order-independent and exact in integers', () => {
  const d = (dateKey, t) => ({ dateKey, periodKey: '2026-09', totalPointsUnits: t, categories: { hipHinge: { pointsUnits: t } } });
  const a = monthEntryFromDays('u', '2026-09', [d('2026-09-01', 333333), d('2026-09-02', 666667)], {});
  const b = monthEntryFromDays('u', '2026-09', [d('2026-09-02', 666667), d('2026-09-01', 333333)], {});
  assert.deepStrictEqual(a, b);
  assert.strictEqual(a.totalPointsUnits, 1000000);
});

// ── Reconciliation ──────────────────────────────────────────────────────────

function fakeQueue(items) {
  const queue = items.map((x) => Object.assign({ attempts: 0 }, x));
  const log = { processed: [], done: [], failed: [], closed: [], enqueued: [] };
  return {
    queue,
    log,
    deps: (over) => Object.assign({
      currentPeriodKey: () => '2026-10',
      listOpenPeriods: async () => ['2026-08', '2026-09', '2026-10', ALL_TIME_PERIOD],
      closePeriod: async (p) => log.closed.push(p),
      listStaleUids: async () => [],
      enqueue: async (uid) => log.enqueued.push(uid),
      async listQueue(size, after) {
        const start = after ? queue.indexOf(after) + 1 : 0;
        return queue.slice(start, start + size);
      },
      async processItem(item) {
        log.processed.push(item.uid);
        if (item.fail) throw new Error('boom');
      },
      async markDone(item) {
        log.done.push(item.uid);
        queue.splice(queue.indexOf(item), 1);
      },
      async markFailed(item) {
        log.failed.push(item.uid);
        item.attempts += 1;
      },
    }, over || {}),
  };
}

test('reconciliation processes only queued users, bounded and paginated', async () => {
  const f = fakeQueue(Array.from({ length: 7 }, (_, i) => ({ uid: `u${i}` })));
  const { counts } = await runReconciliation(f.deps(), { maxUsers: 5, pageSize: 2 });
  assert.strictEqual(counts.processed, 5);
  assert.deepStrictEqual(f.log.processed, ['u0', 'u1', 'u2', 'u3', 'u4']);
  assert.strictEqual(f.queue.length, 2, 'the rest waits for the next run');
  // Resumable: the next run picks up where the queue stands.
  await runReconciliation(f.deps(), { maxUsers: 5, pageSize: 2 });
  assert.strictEqual(f.queue.length, 0);
});

test('reconciliation closes past months only and keeps them', async () => {
  const f = fakeQueue([]);
  const { counts } = await runReconciliation(f.deps());
  assert.deepStrictEqual(f.log.closed, ['2026-08', '2026-09']);
  assert.strictEqual(counts.periodsClosed, 2);
});

test('reconciliation retries failures, then skips exhausted items without blocking', async () => {
  const f = fakeQueue([{ uid: 'bad', fail: true }, { uid: 'ok' }]);
  for (let i = 0; i < 6; i += 1) await runReconciliation(f.deps(), { maxAttempts: 3 });
  assert.strictEqual(f.log.failed.filter((u) => u === 'bad').length, 3);
  assert.ok(f.log.done.includes('ok'));
  const last = await runReconciliation(f.deps(), { maxAttempts: 3 });
  assert.strictEqual(last.counts.skippedExhausted, 1);
});

test('stale entries are queued for a full rebuild', async () => {
  const f = fakeQueue([]);
  const { counts } = await runReconciliation(f.deps({ listStaleUids: async () => ['s1', 's2'] }));
  assert.strictEqual(counts.staleEnqueued, 2);
  assert.deepStrictEqual(f.log.enqueued, ['s1', 's2']);
});

test('queue items merge; too many dates collapse into a full rebuild', () => {
  let item = mergeQueueItem(null, { dateKeys: ['2026-09-02'] }, 'workout');
  item = mergeQueueItem(item, { sinceDateKey: '2026-09-10' }, 'weigh-in');
  item = mergeQueueItem(item, { sinceDateKey: '2026-09-01' }, 'weigh-in');
  assert.deepStrictEqual(requestsOfItem(item), [{ sinceDateKey: '2026-09-01' }, { dateKeys: ['2026-09-02'] }]);
  const many = Array.from({ length: 70 }, (_, i) => `2026-01-${String((i % 28) + 1).padStart(2, '0')}-${i}`);
  assert.strictEqual(mergeQueueItem(null, { dateKeys: many }, 'x').full, true);
  assert.deepStrictEqual(requestsOfItem({ full: true }), [{ full: true }]);
});

// ── Backfill ────────────────────────────────────────────────────────────────

test('backfill is a dry run by default; apply is explicit', () => {
  const d = parseArgs([]);
  assert.strictEqual(d.apply, false);
  assert.ok(d.concurrency >= 1 && d.concurrency <= 8);
  assert.strictEqual(parseArgs(['--apply']).apply, true);
  assert.throws(() => parseArgs(['--nope']));
  assert.throws(() => parseArgs(['--concurrency', '50']));
});

test('a rebuild twice produces identical documents (no accumulation)', async () => {
  const a = athlete('a', { weighIns: [['2026-09-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  await applyRequest(a.lb, { full: true });
  const first = JSON.stringify([...a.entries.entries()].sort());
  await applyRequest(a.lb, { full: true });
  await applyRequest(a.lb, { full: true });
  assert.strictEqual(JSON.stringify([...a.entries.entries()].sort()), first);
});
