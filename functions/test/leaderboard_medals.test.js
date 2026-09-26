'use strict';

// Leaderboard category medals (leaderboard/medals.js): the podium of each RE
// category per board, derived from the entries the existing reducer writes.
//
// Workouts go through the REAL profile V2 store and leaderboard reducer, so
// the category scores the medals rank are exactly the production ones.

const test = require('node:test');
const assert = require('node:assert/strict');

const { applyWorkoutDayV2, memoryStoreV2 } = require('../showcase/store_v2');
const { pickBodyweightAsOf } = require('../showcase/bodyweight');
const { reCoefficient, Sex } = require('../showcase/re_points');
const {
  toUnits,
  monthEntryFromDays,
  allTimeEntryFromSnapshot,
  LEADERBOARD_FORMULA_VERSION,
  ALL_TIME_PERIOD,
} = require('../leaderboard/reducer');
const { applyRequest, refreshAllTime, memoryLeaderboardStore } = require('../leaderboard/store');
const { runReconciliation } = require('../leaderboard/reconcile');
const M = require('../leaderboard/medals');

const ID = {
  bench: 'AmfUWbF1DH3I7qPAdh5k',
  dbBench: 'kTs5fLSTKjUkUZL10iii',
  chin: 'XM9026peNIu0R8qh7UqY',
  lat: '1XOIXxeLFhgmgjZS9Cyq',
  dip: 'FtayDmR5BVnGS1FXlXLL',
  sumo: '10pEctikt6PP8eAg9Eip',
  squat: 'heeBViVINHO6tUScSd6y',
};
const CATS = ['horizontalPress', 'verticalPull', 'overheadPress', 'hipHinge', 'squatPattern'];
const V = LEADERBOARD_FORMULA_VERSION;

const row = (exerciseId, sets) => ({ exerciseId, name: 'x', sets });
const workout = (...rows) => ({ exercises: rows });
const units = (e1rm, factor, bw, sex) =>
  toUnits(Number((e1rm * factor * reCoefficient(sex || Sex.MALE, bw)).toFixed(4)));

/** One athlete over shared entries: profile V2 store + leaderboard store. */
function athlete(uid, entries, options) {
  const o = options || {};
  const weighIns = (o.weighIns || [['2026-01-01', 80]]).map(([dateKey, weight], i) => ({ id: `w${i}`, dateKey, weight }));
  let sex = o.sex || 'M';
  const bw = (d) => pickBodyweightAsOf(weighIns, d);
  const v2 = memoryStoreV2({ bodyweightAsOf: bw, sex });
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
    lb,
    weighIns,
    async log(dateKey, data) {
      const r = await applyWorkoutDayV2(v2, dateKey, data);
      if (r.changed) {
        await applyRequest(lb, r.path === 'bootstrap' ? { full: true } : { dateKeys: [dateKey] });
        await refreshAllTime(lb);
      }
      return r;
    },
    async setSex(next) {
      sex = next;
      v2.setSex(next);
      await applyRequest(lb, { full: true });
      await refreshAllTime(lb);
    },
    async setIdentity(next) {
      identity = next;
      await refreshAllTime(lb);
    },
  };
}

/** What the five bounded podium queries return for [periodKey] (a Map of entries). */
function podiumCandidates(entries, periodKey) {
  const all = [...entries.entries()]
    .filter(([k]) => k.startsWith(`${periodKey}/`))
    .map(([, e]) => e)
    .filter((e) => e.formulaVersion === V);
  const out = {};
  for (const c of CATS) {
    out[c] = all
      .filter((e) => e.medalRankKeys && e.medalRankKeys[c])
      .sort((a, b) => (a.medalRankKeys[c] < b.medalRankKeys[c] ? -1 : 1))
      .slice(0, 3);
  }
  return out;
}

function board(entries, periodKey) {
  return M.allocateMedals(podiumCandidates(entries, periodKey), { allTime: periodKey === ALL_TIME_PERIOD });
}

const uidsOf = (b, c) => b[c].map((w) => w.uid);

/** A synthetic entry with the given per-category units and dates. */
function entry(uid, catUnits, catDates, { allTime = false, version = V } = {}) {
  const u = {};
  const d = {};
  for (const c of CATS) {
    u[c] = catUnits[c] === undefined ? 0 : catUnits[c];
    d[c] = (catDates && catDates[c]) || (u[c] > 0 ? '2026-09-10' : null);
  }
  const e = { uid, formulaVersion: version, categoryDateKeys: d };
  if (allTime) e.categoryBestUnits = u;
  else e.categoryTotalsUnits = u;
  e.medalRankKeys = M.medalRankKeysOf(uid, u, d);
  return e;
}

const every = (n) => Object.fromEntries(CATS.map((c) => [c, n]));

// ── Allocation ──────────────────────────────────────────────────────────────

test('five categories × gold/silver/bronze: exactly fifteen awards when every category has three scorers', () => {
  const es = ['a', 'b', 'c', 'd'].map((u, i) => entry(u, every(1000000 - i * 1000)));
  const b = M.allocateMedals(Object.fromEntries(CATS.map((c) => [c, es])));
  assert.deepEqual(Object.keys(b), CATS);
  let n = 0;
  for (const c of CATS) {
    assert.deepEqual(uidsOf(b, c), ['a', 'b', 'c']);
    assert.deepEqual(b[c].map((w) => w.place), [1, 2, 3]);
    n += b[c].length;
  }
  assert.equal(n, 15);
  assert.deepEqual(M.MEDALS, ['gold', 'silver', 'bronze']);
});

test('a user can hold one medal per category — up to five on one board', () => {
  const es = [entry('star', every(9000000)), entry('x', every(10)), entry('y', every(5))];
  const b = M.allocateMedals(Object.fromEntries(CATS.map((c) => [c, es])));
  assert.equal(CATS.filter((c) => b[c][0].uid === 'star').length, 5);
});

test('fewer than three eligible users: no zero, null or invalid score is ever awarded', () => {
  const es = [
    entry('a', { horizontalPress: 500 }),
    entry('zero', { horizontalPress: 0 }),
    Object.assign(entry('nul', {}), { categoryTotalsUnits: { horizontalPress: null } }),
    Object.assign(entry('neg', {}), { categoryTotalsUnits: { horizontalPress: -4 } }),
    Object.assign(entry('frac', {}), { categoryTotalsUnits: { horizontalPress: 12.5 } }),
    Object.assign(entry('str', {}), { categoryTotalsUnits: { horizontalPress: '999' } }),
  ];
  const b = M.allocateMedals({ horizontalPress: es });
  assert.deepEqual(uidsOf(b, 'horizontalPress'), ['a']);
  for (const c of CATS.slice(1)) assert.deepEqual(b[c], []);
  assert.equal(M.medalRankKey(0, '2026-09-01', 'u'), null);
  assert.equal(M.medalRankKey(Number.NaN, '2026-09-01', 'u'), null);
  assert.deepEqual(entry('zero', { horizontalPress: 0 }).medalRankKeys, {});
});

test('scaled integers order exactly, including one-unit differences and large totals', () => {
  const es = [entry('lo', { hipHinge: 123456788 }), entry('hi', { hipHinge: 123456789 }), entry('big', { hipHinge: 9876543210 })];
  const b = M.allocateMedals({ hipHinge: es });
  assert.deepEqual(uidsOf(b, 'hipHinge'), ['big', 'hi', 'lo']);
  // The sortable key orders exactly like the integers.
  const keys = es.map((e) => e.medalRankKeys.hipHinge).sort();
  assert.deepEqual(keys.map((k) => k.split('~')[2]), ['big', 'hi', 'lo']);
  assert.equal(b.hipHinge[1].pointsUnits, 123456789);
});

test('ties: earlier achievement date wins per category, then uid ascending', () => {
  const a = entry('a', { horizontalPress: 700, squatPattern: 700 }, { horizontalPress: '2026-09-20', squatPattern: '2026-09-02' });
  const b = entry('b', { horizontalPress: 700, squatPattern: 700 }, { horizontalPress: '2026-09-05', squatPattern: '2026-09-02' });
  const c = entry('c', { horizontalPress: 700, squatPattern: 700 }, { horizontalPress: '2026-09-05', squatPattern: '2026-09-30' });
  const res = M.allocateMedals({ horizontalPress: [a, b, c], squatPattern: [c, b, a] });
  assert.deepEqual(uidsOf(res, 'horizontalPress'), ['b', 'c', 'a'], 'date, then uid');
  assert.deepEqual(uidsOf(res, 'squatPattern'), ['a', 'b', 'c'], 'category-specific dates');
  assert.equal(res.horizontalPress[0].achievedDateKey, '2026-09-05');
  // Exactly one medal per place, never shared.
  assert.equal(new Set(res.horizontalPress.map((w) => w.place)).size, 3);
});

test('duplicates in the candidate list never award one uid twice in a category', () => {
  const a = entry('a', { verticalPull: 10 });
  const res = M.allocateMedals({ verticalPull: [a, a, entry('b', { verticalPull: 5 })] });
  assert.deepEqual(uidsOf(res, 'verticalPull'), ['a', 'b']);
});

// ── Monthly scores are the sum of daily category winners ───────────────────

test('monthly: one winner per category per date; different alternatives on different dates both count', async () => {
  const entries = new Map();
  const a = athlete('a', entries);
  // 09-02: bench AND db bench — only the higher counts for Horizontal Press.
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }]), row(ID.dbBench, [{ weight: 30, reps: 1 }])));
  // 09-03: only db bench — it wins that date.
  await a.log('2026-09-03', workout(row(ID.dbBench, [{ weight: 40, reps: 1 }])));
  const bench = units(100, 1, 80);
  const db2 = units(30, 2.11, 80);
  const db3 = units(40, 2.11, 80);
  const m = entries.get('2026-09/a');
  assert.equal(m.categoryTotalsUnits.horizontalPress, Math.max(bench, db2) + db3);
  assert.equal(m.categoryDateKeys.horizontalPress, '2026-09-03');
  assert.equal(m.categoryDateKeys.squatPattern, null);
  assert.equal(m.medalRankKeys.squatPattern, undefined, 'no score → no key');
  // Not the overall monthly total.
  await a.log('2026-09-04', workout(row(ID.squat, [{ weight: 100, reps: 1 }])));
  const m2 = entries.get('2026-09/a');
  assert.ok(m2.totalPointsUnits > m2.categoryTotalsUnits.horizontalPress);
  assert.equal(board(entries, '2026-09').horizontalPress[0].pointsUnits, m2.categoryTotalsUnits.horizontalPress);
});

test('monthly achievement date is the last date that added to THAT category', () => {
  const day = (dateKey, cats) => ({
    dateKey,
    periodKey: dateKey.slice(0, 7),
    categories: Object.fromEntries(Object.entries(cats).map(([k, v]) => [k, { pointsUnits: v }])),
    totalPointsUnits: Object.values(cats).reduce((s, v) => s + v, 0),
  });
  const e = monthEntryFromDays('u', '2026-09', [
    day('2026-09-01', { horizontalPress: 10, hipHinge: 5 }),
    day('2026-09-09', { hipHinge: 7 }),
    day('2026-08-31', { horizontalPress: 99 }),
  ], {});
  assert.equal(e.categoryDateKeys.horizontalPress, '2026-09-01');
  assert.equal(e.categoryDateKeys.hipHinge, '2026-09-09');
  assert.equal(e.categoryTotalsUnits.horizontalPress, 10, 'another month never counts');
  assert.equal(e.medalRankKeys.horizontalPress, M.medalRankKey(10, '2026-09-01', 'u'));
  // Order-independent (rebuild-safe).
  const again = monthEntryFromDays('u', '2026-09', [day('2026-09-09', { hipHinge: 7 }), day('2026-09-01', { horizontalPress: 10, hipHinge: 5 })], {});
  assert.deepEqual(again.medalRankKeys, e.medalRankKeys);
});

// ── All time: the profile card's winning record ─────────────────────────────

test('all time: the single best category record — the profile default — and its own date', async () => {
  const entries = new Map();
  const a = athlete('a', entries);
  await a.log('2026-08-10', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  await a.log('2026-09-12', workout(row(ID.dbBench, [{ weight: 60, reps: 1 }])));
  const at = entries.get('all_time/a');
  const bench = units(100, 1, 80);
  const db = units(60, 2.11, 80);
  assert.equal(at.categoryBestUnits.horizontalPress, Math.max(bench, db), 'single best, not a sum');
  const winner = db > bench ? ID.dbBench : ID.bench;
  assert.equal(at.winningExerciseIds.horizontalPress, winner);
  assert.equal(at.categoryDateKeys.horizontalPress, db > bench ? '2026-09-12' : '2026-08-10');
  const b = board(entries, ALL_TIME_PERIOD);
  assert.equal(b.horizontalPress[0].exerciseId, winner);
  assert.equal(b.horizontalPress[0].recordDateKey, at.categoryDateKeys.horizontalPress);
});

test('all-time entry derivation ignores a stale showcase formula', () => {
  const res = allTimeEntryFromSnapshot('u', { schema: 'profileShowcaseV2', e1rmFormulaVersion: 1, rePointsFormulaVersion: 999, categories: {} }, {});
  assert.equal(res.stale, true);
});

// ── Workout create / update / delete, events, identity ──────────────────────

test('workout create, update and delete move medals; replayed events are idempotent', async () => {
  const entries = new Map();
  const a = athlete('a', entries);
  const b = athlete('b', entries);
  await a.log('2026-09-02', workout(row(ID.sumo, [{ weight: 200, reps: 1 }])));
  await b.log('2026-09-02', workout(row(ID.sumo, [{ weight: 180, reps: 1 }])));
  assert.deepEqual(uidsOf(board(entries, '2026-09'), 'hipHinge'), ['a', 'b']);
  await b.log('2026-09-02', workout(row(ID.sumo, [{ weight: 220, reps: 1 }])));
  assert.deepEqual(uidsOf(board(entries, '2026-09'), 'hipHinge'), ['b', 'a']);
  const snap1 = M.medalSnapshot('2026-09', board(entries, '2026-09'), { formulaVersion: V, rePointsFormulaVersion: 2 });
  // Replay: the same events again change nothing, so no new snapshot.
  await b.log('2026-09-02', workout(row(ID.sumo, [{ weight: 220, reps: 1 }])));
  await applyRequest(b.lb, { dateKeys: ['2026-09-02'] });
  assert.equal(M.medalSnapshot('2026-09', board(entries, '2026-09'), { formulaVersion: V, prev: snap1 }), null);
  await b.log('2026-09-02', null);
  assert.deepEqual(uidsOf(board(entries, '2026-09'), 'hipHinge'), ['a']);
});

test('out-of-order events converge on the same podium', async () => {
  const run = async (order) => {
    const entries = new Map();
    const a = athlete('a', entries);
    const b = athlete('b', entries);
    const events = {
      a1: () => a.log('2026-09-02', workout(row(ID.squat, [{ weight: 100, reps: 1 }]))),
      a2: () => a.log('2026-09-05', workout(row(ID.squat, [{ weight: 110, reps: 1 }]))),
      b1: () => b.log('2026-09-03', workout(row(ID.squat, [{ weight: 190, reps: 1 }]))),
    };
    for (const k of order) await events[k]();
    return board(entries, '2026-09');
  };
  const x = await run(['a1', 'a2', 'b1']);
  const y = await run(['b1', 'a2', 'a1']);
  assert.equal(M.awardsFingerprint(x), M.awardsFingerprint(y));
});

test('weigh-in and sex changes re-score through the reducer, and the podium follows', async () => {
  const entries = new Map();
  const a = athlete('a', entries, { weighIns: [['2026-01-01', 60]], sex: 'F' });
  const b = athlete('b', entries, { weighIns: [['2026-01-01', 80]] });
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 80, reps: 1 }])));
  await b.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  const before = board(entries, '2026-09').horizontalPress.map((w) => [w.uid, w.pointsUnits]);
  assert.deepEqual(before.map((x) => x[1]), [...before.map((x) => x[1])].sort((p, q) => q - p));
  await a.setSex('M');
  const after = board(entries, '2026-09').horizontalPress;
  const aUnits = after.find((w) => w.uid === 'a').pointsUnits;
  assert.equal(aUnits, units(80, 1, 60, 'M'));
  assert.notEqual(aUnits, before.find((x) => x[0] === 'a')[1]);
});

test('username / avatar changes never reallocate medals', async () => {
  const entries = new Map();
  const a = athlete('a', entries);
  await a.log('2026-09-02', workout(row(ID.dip, [{ weight: 20, reps: 5 }])));
  const before = entries.get('all_time/a');
  const snap = M.medalSnapshot(ALL_TIME_PERIOD, board(entries, ALL_TIME_PERIOD), { formulaVersion: V });
  await a.setIdentity({ username: 'renamed', photoURL: 'https://x/new.jpg' });
  const after = entries.get('all_time/a');
  assert.equal(after.username, 'renamed');
  assert.equal(M.entryWriteAffectsMedals(before, after, snap, V), false);
  assert.equal(M.medalSnapshot(ALL_TIME_PERIOD, board(entries, ALL_TIME_PERIOD), { formulaVersion: V, prev: snap }), null);
});

// ── When an entry write needs a refresh ─────────────────────────────────────

test('entryWriteAffectsMedals: cheap exits and every case that must refresh', () => {
  const winners = ['a', 'b', 'c'].map((u, i) => entry(u, { squatPattern: 900 - i * 100 }));
  const snap = M.medalSnapshot('2026-09', M.allocateMedals({ squatPattern: winners }), { formulaVersion: V });
  const d = entry('d', { squatPattern: 10 });
  assert.equal(M.entryWriteAffectsMedals(d, Object.assign({}, d, { username: 'x' }), snap, V), false, 'same keys');
  assert.equal(M.entryWriteAffectsMedals(d, entry('d', { squatPattern: 20 }), snap, V), false, 'still below bronze');
  assert.equal(M.entryWriteAffectsMedals(d, entry('d', { squatPattern: 750 }), snap, V), true, 'beats bronze');
  assert.equal(M.entryWriteAffectsMedals(winners[2], entry('c', { squatPattern: 1 }), snap, V), true, 'a holder dropped');
  assert.equal(M.entryWriteAffectsMedals(winners[1], null, snap, V), true, 'a holder withdrew');
  assert.equal(M.entryWriteAffectsMedals(d, null, snap, V), false, 'a non-holder withdrew');
  assert.equal(M.entryWriteAffectsMedals(null, entry('e', { hipHinge: 1 }), snap, V), true, 'empty category fills');
  assert.equal(M.entryWriteAffectsMedals(d, entry('d', { squatPattern: 20 }), null, V), true, 'no snapshot yet');
  const staleSnap = Object.assign({}, snap, { formulaVersion: 'old' });
  assert.equal(M.entryWriteAffectsMedals(d, entry('d', { squatPattern: 20 }), staleSnap, V), true, 'snapshot formula changed');
  assert.equal(M.entryWriteAffectsMedals(d, entry('d', { squatPattern: 5000 }, null, { version: 'old' }), snap, V), false, 'a stale entry is not eligible');
});

test('account withdrawal (entry deleted) removes its medals from the next allocation', async () => {
  const entries = new Map();
  const a = athlete('a', entries);
  const b = athlete('b', entries);
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 120, reps: 1 }])));
  await b.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  const snap = M.medalSnapshot('2026-09', board(entries, '2026-09'), { formulaVersion: V });
  const gone = entries.get('2026-09/a');
  entries.delete('2026-09/a');
  entries.delete('all_time/a');
  assert.equal(M.entryWriteAffectsMedals(gone, null, snap, V), true);
  const next = M.medalSnapshot('2026-09', board(entries, '2026-09'), { formulaVersion: V, prev: snap });
  assert.deepEqual(next.categories.horizontalPress.map((w) => [w.uid, w.place]), [['b', 1]]);
  assert.equal(next.revision, 2);
});

// ── Snapshot shape, versions, months ────────────────────────────────────────

test('snapshot: versioned, public-only, idempotent, month vs all time', () => {
  const es = [entry('a', { horizontalPress: 5 }, null, { allTime: true })];
  es[0].winningExerciseIds = { horizontalPress: ID.bench };
  es[0].email = 'secret@x';
  es[0].sex = 'F';
  const at = M.medalSnapshot(ALL_TIME_PERIOD, M.allocateMedals({ horizontalPress: es }, { allTime: true }), { formulaVersion: V, rePointsFormulaVersion: 2 });
  assert.equal(at.schema, 'leaderboardMedals');
  assert.equal(at.schemaVersion, 1);
  assert.equal(at.boardType, 'allTime');
  assert.equal(at.monthKey, null);
  assert.equal(at.formulaVersion, V);
  assert.equal(at.rePointsFormulaVersion, 2);
  assert.equal(at.revision, 1);
  assert.deepEqual(at.categories.horizontalPress, [
    { uid: 'a', place: 1, pointsUnits: 5, achievedDateKey: '2026-09-10', exerciseId: ID.bench, recordDateKey: '2026-09-10' },
  ]);
  assert.deepEqual(Object.keys(at.categories), CATS);
  const text = JSON.stringify(at);
  for (const secret of ['secret@x', '"sex"', 'username', 'photoURL']) assert.ok(!text.includes(secret), secret);
  const m = M.medalSnapshot('2026-09', {}, { formulaVersion: V });
  assert.equal(m.boardType, 'month');
  assert.equal(m.monthKey, '2026-09');
  assert.equal(M.medalSnapshot('2026-09', {}, { formulaVersion: V, prev: m }), null, 'unchanged → no write');
});

test('a formula-version change forces a new snapshot and excludes stale entries', () => {
  const fresh = entry('a', { hipHinge: 5 });
  const stale = entry('z', { hipHinge: 99999 }, null, { version: 'lb1-old' });
  const entries = new Map([['2026-09/a', fresh], ['2026-09/z', stale]]);
  const b = board(entries, '2026-09');
  assert.deepEqual(uidsOf(b, 'hipHinge'), ['a']);
  const prev = Object.assign(M.medalSnapshot('2026-09', b, { formulaVersion: 'lb1-old' }), {});
  const next = M.medalSnapshot('2026-09', b, { formulaVersion: V, prev });
  assert.ok(next, 'same awards, new formula → rewritten');
  assert.equal(next.formulaVersion, V);
});

test('month rollover: each month has its own podium; closed months keep theirs', async () => {
  const entries = new Map();
  const a = athlete('a', entries);
  const b = athlete('b', entries);
  await a.log('2026-08-30', workout(row(ID.squat, [{ weight: 200, reps: 1 }])));
  await b.log('2026-09-01', workout(row(ID.squat, [{ weight: 100, reps: 1 }])));
  assert.deepEqual(uidsOf(board(entries, '2026-08'), 'squatPattern'), ['a']);
  assert.deepEqual(uidsOf(board(entries, '2026-09'), 'squatPattern'), ['b']);
  // Monthly medals are independent of all time.
  assert.deepEqual(uidsOf(board(entries, ALL_TIME_PERIOD), 'squatPattern'), ['a', 'b']);
});

// ── Reconciliation safety net ───────────────────────────────────────────────

test('a delayed reconciliation refreshes dirty boards, then the current month and all time', async () => {
  const refreshed = [];
  const cleared = [];
  const deps = {
    currentPeriodKey: () => '2026-10',
    listOpenPeriods: async () => ['2026-09', '2026-10', 'all_time'],
    closePeriod: async () => {},
    listStaleUids: async () => [],
    enqueue: async () => {},
    listQueue: async () => [],
    processItem: async () => {},
    markDone: async () => {},
    markFailed: async () => {},
    allTimePeriodKey: 'all_time',
    listDirtyMedalBoards: async () => [{ periodKey: '2026-09' }, { periodKey: 'all_time' }, { periodKey: '2026-07' }],
    refreshMedals: async (p) => {
      refreshed.push(p);
      if (p === '2026-07') throw new Error('boom');
    },
    clearMedalBoard: async (item) => cleared.push(item.periodKey),
  };
  const { counts, failures } = await runReconciliation(deps);
  assert.deepEqual(refreshed, ['2026-09', 'all_time', '2026-07', '2026-10']);
  assert.deepEqual(cleared, ['2026-09', 'all_time'], 'a failed board stays dirty');
  assert.equal(counts.medalBoardsRefreshed, 3);
  assert.equal(counts.medalBoardsFailed, 1);
  assert.equal(failures[0].periodKey, '2026-07');
});

test('reconciliation without medal deps behaves exactly as before', async () => {
  const { counts } = await runReconciliation({
    currentPeriodKey: () => '2026-10',
    listOpenPeriods: async () => [],
    closePeriod: async () => {},
    listStaleUids: async () => [],
    enqueue: async () => {},
    listQueue: async () => [],
    processItem: async () => {},
    markDone: async () => {},
    markFailed: async () => {},
  });
  assert.equal(counts.medalBoardsRefreshed, undefined);
});

// ── Additive only ───────────────────────────────────────────────────────────

test('existing entry fields are unchanged; medal data is purely additive', async () => {
  const entries = new Map();
  const a = athlete('a', entries);
  await a.log('2026-09-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }]), row(ID.chin, [{ weight: 80, reps: 3 }])));
  const m = entries.get('2026-09/a');
  const at = entries.get('all_time/a');
  for (const k of ['uid', 'periodKey', 'username', 'photoURL', 'totalPointsUnits', 'categoryTotalsUnits', 'scoredDayCount', 'tieBreakDateKey', 'formulaVersion']) {
    assert.ok(k in m, `month ${k}`);
  }
  for (const k of ['uid', 'periodKey', 'username', 'photoURL', 'totalPointsUnits', 'categoryBestUnits', 'winningExerciseIds', 'tieBreakDateKey', 'formulaVersion']) {
    assert.ok(k in at, `all time ${k}`);
  }
  assert.equal(m.totalPointsUnits, Object.values(m.categoryTotalsUnits).reduce((s, v) => s + v, 0));
  assert.deepEqual(Object.keys(m.medalRankKeys).sort(), ['horizontalPress', 'verticalPull']);
  assert.equal(m.formulaVersion, V, 'no formula-version change');
});
