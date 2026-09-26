'use strict';

// Best RE Points selected independently of Best E1RM, and the bounded,
// resumable rebuild job (showcase/rebuild_job.js).

const test = require('node:test');
const assert = require('node:assert');

const { applyWorkoutDayV2, refreshV2, memoryStoreV2, isBuiltV2 } = require('../showcase/store_v2');
const {
  buildShowcaseV2,
  summarizeWorkoutDayV2,
  SHOWCASE_V2_AGGREGATION_VERSION,
  liveFingerprintsV2,
} = require('../showcase/reducer_v2');
const {
  rebuildStep,
  runRebuildToCompletion,
  memoryIo,
  mergeRebuildRequest,
  noteTouch,
  PAGE_DATES,
  MAX_ATTEMPTS,
} = require('../showcase/rebuild_job');
const { pickBodyweightAsOf } = require('../showcase/bodyweight');
const { reCoefficient, Sex } = require('../showcase/re_points');
const { memoryLeaderboardStore, rebuildUser } = require('../leaderboard/store');
const { mergeQueueItem, requestsOfItem, mergeRanges } = require('../leaderboard/reconcile');
const { allTimeEntryFromSnapshot, toUnits } = require('../leaderboard/reducer');

const ID = {
  bench: 'AmfUWbF1DH3I7qPAdh5k',
  dbBench: 'kTs5fLSTKjUkUZL10iii',
  chin: 'XM9026peNIu0R8qh7UqY',
  dip: 'FtayDmR5BVnGS1FXlXLL',
  deadlift: 'MsGl7e9yanDeEnYX0e4X',
  sumo: '10pEctikt6PP8eAg9Eip',
  squat: 'heeBViVINHO6tUScSd6y',
};
const row = (exerciseId, sets) => ({ exerciseId, name: 'x', sets });
const workout = (...rows) => ({ exercises: rows });
const pts = (e1rm, factor, bw) => Number((e1rm * factor * reCoefficient(Sex.MALE, bw)).toFixed(4));

function weighIns(list) {
  const entries = list.map(([dateKey, weight], i) => ({ id: `w${i}`, dateKey, weight }));
  const fn = (dateKey) => pickBodyweightAsOf(entries, dateKey);
  fn.entries = entries;
  return fn;
}
function bwByDateFor(history, resolver) {
  const out = {};
  for (const d of Object.keys(history)) out[d] = resolver(d);
  return out;
}
const entry = (snap, cat, id) => snap.categories[cat].exercises[id];

// ── Best RE Points is its own record ────────────────────────────────────────

test('a lower E1RM at a lower bodyweight holds Best RE Points; Best E1RM stays the heavier set', () => {
  const bw = weighIns([['2026-01-01', 110], ['2026-03-01', 65]]);
  const history = {
    '2026-01-10': workout(row(ID.bench, [{ weight: 150, reps: 1, id: 'heavy' }])),
    '2026-03-10': workout(row(ID.bench, [{ weight: 140, reps: 1, id: 'light' }])),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  const e = entry(snap, 'horizontalPress', ID.bench);
  assert.strictEqual(e.e1rm.setKey, 'heavy');
  assert.strictEqual(e.e1rm.e1rm, 150);
  assert.strictEqual(e.points.setKey, 'light');
  assert.strictEqual(e.points.dateKey, '2026-03-10');
  assert.strictEqual(e.rePoints, pts(140, 1, 65));
  assert.ok(e.rePoints > pts(150, 1, 110), 'the independent pick really scores more');
  // Each record names its own set: a proof of one is never shown on the other.
  assert.notStrictEqual(e.points.fingerprint, e.e1rm.fingerprint);
  assert.ok(liveFingerprintsV2(snap).has(e.points.fingerprint));
});

for (const [label, id, cat, factor] of [
  ['Chin-Up', ID.chin, 'verticalPull', 1.0],
  ['Triceps Dip', ID.dip, 'overheadPress', 0.63],
]) {
  test(`${label}: the best added-load E1RM is not the best combined-load RE Points`, () => {
    const bw = weighIns([['2026-01-01', 60], ['2026-05-01', 110]]);
    const history = {
      '2026-01-10': workout(row(id, [{ weight: 30, reps: 1, setIndex: 0, id: 'light-bw' }])),
      '2026-05-10': workout(row(id, [{ weight: 25, reps: 1, setIndex: 0, id: 'heavy-bw' }])),
    };
    const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
    const e = entry(snap, cat, id);
    // Best E1RM keeps the established added-load ranking…
    assert.strictEqual(e.e1rm.setKey, 'light-bw');
    // …while Best RE Points runs every set through the combined-load path.
    assert.strictEqual(e.points.setKey, 'heavy-bw');
    assert.strictEqual(e.points.totalKg, 135);
    assert.strictEqual(e.points.bodyweightKg, 110);
    assert.strictEqual(e.rePoints, pts(135, factor, 110));
    assert.ok(e.rePoints > pts(90, factor, 60));
  });
}

test('within a day every set is scored and the best one kept', () => {
  const day = summarizeWorkoutDayV2('2026-02-02', workout(row(ID.squat, [
    { weight: 100, reps: 8, id: 'a' },
    { weight: 140, reps: 1, id: 'b' },
    { weight: 120, reps: 5, id: 'c', rir: 0 },
  ])), { bodyweight: { weightKg: 80, dateKey: '2026-02-01' }, sex: Sex.MALE });
  const d = day.squat;
  assert.strictEqual(d.sets.length, 3);
  // 140×1 → E1RM 140 beats 120×5 (135) and 100×8 (124): the most points.
  assert.strictEqual(d.bestPoints.setKey, 'b');
  assert.deepStrictEqual(d.bodyweight, { weightKg: 80, dateKey: '2026-02-01' });
  // No bodyweight: nothing can score, the day holds no points candidate.
  const none = summarizeWorkoutDayV2('2026-02-02', workout(row(ID.squat, [{ weight: 100, reps: 1 }])), {});
  assert.strictEqual(none.squat.bestPoints, undefined);
});

test('the category default follows lifetime Best RE Points', () => {
  // Bench has the bigger E1RM (150) but at a heavy bodyweight; the DB press
  // scores more.
  const bw = weighIns([['2026-01-01', 110], ['2026-03-01', 65]]);
  const history = {
    '2026-01-10': workout(row(ID.bench, [{ weight: 150, reps: 1 }])),
    '2026-03-10': workout(row(ID.dbBench, [{ weight: 55, reps: 1 }])),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  assert.ok(pts(55, 2.11, 65) > pts(150, 1, 110));
  assert.strictEqual(snap.categories.horizontalPress.bestExerciseId, ID.dbBench);
});

test('equal Best RE Points across days: the earlier record stands (no card flipping)', () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const history = {
    '2026-01-10': workout(row(ID.squat, [{ weight: 150, reps: 1, id: 'first' }])),
    '2026-02-10': workout(row(ID.squat, [{ weight: 150, reps: 1, id: 'later' }])),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  assert.strictEqual(entry(snap, 'squatPattern', ID.squat).points.setKey, 'first');
});

test('all time sums the category-winning Best RE Points and dates the tie on them', () => {
  const bw = weighIns([['2026-01-01', 110], ['2026-03-01', 65]]);
  const history = {
    '2026-01-10': workout(row(ID.bench, [{ weight: 150, reps: 1 }])),
    '2026-03-10': workout(row(ID.bench, [{ weight: 140, reps: 1 }]), row(ID.deadlift, [{ weight: 200, reps: 1 }])),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  const { entry: at } = allTimeEntryFromSnapshot('u', snap, { username: 'u' });
  assert.strictEqual(at.totalPointsUnits, toUnits(pts(140, 1, 65)) + toUnits(pts(200, 0.74, 65)));
  assert.strictEqual(at.tieBreakDateKey, '2026-03-10');
});

test('a stale aggregation version is never treated as built', async () => {
  const store = memoryStoreV2({ bodyweightAsOf: weighIns([['2026-01-01', 80]]), workouts: () => [] });
  await store.setState({ schema: 'profileShowcaseV2', e1rmFormulaVersion: 1, rePointsFormulaVersion: 1, aggregationVersion: 1 });
  await store.setSnapshot({ schema: 'profileShowcaseV2', e1rmFormulaVersion: 1, rePointsFormulaVersion: 1, aggregationVersion: 1, categories: {} });
  assert.strictEqual(isBuiltV2(await store.getState(), await store.getSnapshot()), false);
  const r = await applyWorkoutDayV2(store, '2026-02-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  assert.strictEqual(r.path, 'queued');
  const job = await store.getRebuildJob();
  assert.strictEqual(job.status, 'queued');
  assert.strictEqual(job.mode, 'full');
  assert.strictEqual(SHOWCASE_V2_AGGREGATION_VERSION, 2);
});

// ── The bounded rebuild job ─────────────────────────────────────────────────

function bigHistory(n) {
  const history = {};
  const start = Date.UTC(2024, 0, 1);
  for (let i = 0; i < n; i += 1) {
    const d = new Date(start + i * 2 * 86400000).toISOString().slice(0, 10);
    history[d] = workout(
      row(ID.bench, [{ weight: 80 + (i % 17), reps: 1 + (i % 6) }]),
      row(i % 2 ? ID.deadlift : ID.sumo, [{ weight: 150 + (i % 23), reps: 1 + (i % 4) }]),
      ...(i % 5 === 0 ? [row(ID.chin, [{ weight: i % 20, reps: 3, setIndex: 0 }])] : []),
    );
  }
  return history;
}

function jobHarness(history, weigh) {
  const bw = weighIns(weigh || [['2023-12-01', 82], ['2024-06-01', 78], ['2025-01-01', 85]]);
  const v2 = memoryStoreV2({ bodyweightAsOf: bw, sex: 'M', workouts: () => Object.entries(history) });
  const entries = new Map();
  const lb = memoryLeaderboardStore('u', {
    v2Days: () => [...v2._days.values()],
    bodyweightAsOf: bw,
    sex: 'M',
    publicProfile: async () => ({ username: 'u', profileShowcaseV2: await v2.getSnapshot() }),
    entries,
  });
  return { bw, v2, lb, entries };
}

test('a large history rebuilds in bounded pages and equals the pure rebuild', async () => {
  const history = bigHistory(130); // > 5 pages of PAGE_DATES
  const h = jobHarness(history);
  await h.v2.requestRebuild({ mode: 'full', reason: 'test' });
  const run = await runRebuildToCompletion(memoryIo(h.v2, h.lb));
  assert.strictEqual(run.job.status, 'done');
  assert.ok(run.steps > Math.ceil(130 / PAGE_DATES), 'paged, one bounded unit per step');
  const expected = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, h.bw), sex: Sex.MALE });
  assert.deepStrictEqual(await h.v2.getSnapshot(), expected);
  assert.ok(isBuiltV2(await h.v2.getState(), await h.v2.getSnapshot()));
  // The job's leaderboard equals a from-scratch leaderboard rebuild.
  const other = new Map();
  const lb2 = memoryLeaderboardStore('u', {
    v2Days: () => [...h.v2._days.values()],
    sex: 'M',
    publicProfile: async () => ({ username: 'u', profileShowcaseV2: await h.v2.getSnapshot() }),
    entries: other,
  });
  await rebuildUser(lb2);
  assert.deepStrictEqual([...h.entries.entries()].sort(), [...other.entries()].sort());
});

test('nothing is published until the job completes; an interrupted job resumes', async () => {
  const history = bigHistory(60);
  const h = jobHarness(history);
  const previous = { schema: 'profileShowcaseV2', aggregationVersion: 1, categories: { old: true } };
  await h.v2.setSnapshot(previous);
  await h.v2.requestRebuild({ mode: 'full', reason: 'test' });
  const io = memoryIo(h.v2, h.lb);
  for (let i = 0; i < 2; i += 1) await rebuildStep(io); // "timeout" mid-way through the day pages
  assert.deepStrictEqual(await h.v2.getSnapshot(), previous, 'the old snapshot stays until publish');
  const job = await h.v2.getRebuildJob();
  assert.strictEqual(job.status, 'running');
  assert.strictEqual(job.phase, 'days');
  assert.ok(job.cursor, 'progress is recorded');
  const run = await runRebuildToCompletion(memoryIo(h.v2, h.lb));
  assert.strictEqual(run.job.status, 'done');
  assert.deepStrictEqual(
    await h.v2.getSnapshot(),
    buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, h.bw), sex: Sex.MALE }),
  );
});

test('workouts added, edited, deleted and backdated during a rebuild all end up in it', async () => {
  const history = bigHistory(80);
  const h = jobHarness(history);
  await h.v2.requestRebuild({ mode: 'full', reason: 'test' });
  let step = 0;
  const io = memoryIo(h.v2, h.lb, {
    async beforeUnit() {
      step += 1;
      // A trigger for each change runs between steps, while the job is active.
      const change = async (date, data) => {
        if (data) history[date] = data;
        else delete history[date];
        const r = await applyWorkoutDayV2(h.v2, date, data);
        assert.ok(['queued', 'noop'].includes(r.path), `no publish while the job runs (${r.path})`);
      };
      if (step === 3) await change('2023-06-01', workout(row(ID.bench, [{ weight: 200, reps: 1 }]))); // backdated, ahead of cursor
      if (step === 9) await change(Object.keys(history).sort()[1], workout(row(ID.squat, [{ weight: 180, reps: 2 }]))); // edit behind cursor
      if (step === 14) await change(Object.keys(history).sort()[5], null); // delete behind cursor
      if (step === 20) await change('2030-01-01', workout(row(ID.dbBench, [{ weight: 60, reps: 1 }]))); // new, after publish
    },
  });
  const run = await runRebuildToCompletion(io);
  assert.strictEqual(run.job.status, 'done');
  const expected = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, h.bw), sex: Sex.MALE });
  assert.deepStrictEqual(await h.v2.getSnapshot(), expected);
  // And the leaderboard matches a from-scratch rebuild of the final data.
  const other = new Map();
  await rebuildUser(memoryLeaderboardStore('u', {
    v2Days: () => [...h.v2._days.values()],
    sex: 'M',
    publicProfile: async () => ({ username: 'u', profileShowcaseV2: await h.v2.getSnapshot() }),
    entries: other,
  }));
  assert.deepStrictEqual([...h.entries.entries()].sort(), [...other.entries()].sort());
});

test('a stale or duplicate step cannot commit (generation / step guard)', async () => {
  const h = jobHarness(bigHistory(10));
  await h.v2.requestRebuild({ mode: 'full', reason: 'a' });
  const stale = await h.v2.getRebuildJob();
  // A newer request supersedes it (a stronger mode restarts the generation).
  await rebuildStep(memoryIo(h.v2, h.lb));
  const io = memoryIo(h.v2, h.lb);
  const committed = await io.unit(stale, async () => ({ phase: 'publish' }));
  assert.strictEqual(committed, false);
  assert.notStrictEqual((await h.v2.getRebuildJob()).phase, 'publish');
});

test('failures are explicit: attempts, lastError, then status error', async () => {
  const h = jobHarness(bigHistory(5));
  await h.v2.requestRebuild({ mode: 'full', reason: 'x' });
  const io = memoryIo(h.v2, h.lb);
  io.v2 = Object.assign(Object.create(io.v2), {
    async listWorkoutsFrom() {
      throw new Error('boom');
    },
  });
  let r;
  for (let i = 0; i < MAX_ATTEMPTS; i += 1) r = await rebuildStep(io);
  assert.strictEqual(r.done, true);
  const job = await h.v2.getRebuildJob();
  assert.strictEqual(job.status, 'error');
  assert.strictEqual(job.attempts, MAX_ATTEMPTS);
  assert.match(job.lastError, /boom/);
});

test('rebuild requests merge: stronger modes restart, weigh-ins rewind the day pages', () => {
  const now = 1;
  let job = mergeRebuildRequest(null, { mode: 'leaderboard', reason: 'lb' }, now);
  assert.strictEqual(job.phase, 'lbDays');
  const gen = job.generation;
  job = mergeRebuildRequest(job, { mode: 'full', reason: 'first' }, now);
  assert.strictEqual(job.generation, gen + 1);
  assert.strictEqual(job.phase, 'days');
  job = Object.assign(job, { status: 'running', cursor: '2025-05-01' });
  const same = mergeRebuildRequest(job, { mode: 'fold', reason: 'sex' }, now);
  assert.strictEqual(same.generation, job.generation, 'a weaker request rides along');
  const rewound = noteTouch(job, { sinceDateKey: '2024-02-01' }, now);
  assert.strictEqual(rewound.rewindDateKey, '2024-02-01');
  assert.strictEqual(rewound.touches, 1);
});

test('the first training day ever is published directly; anything with history is a job', async () => {
  const fresh = memoryStoreV2({ bodyweightAsOf: weighIns([['2026-01-01', 80]]), workouts: () => [['2026-02-02', {}]] });
  const r1 = await applyWorkoutDayV2(fresh, '2026-02-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  assert.strictEqual(r1.path, 'append');
  const withHistory = memoryStoreV2({
    bodyweightAsOf: weighIns([['2026-01-01', 80]]),
    workouts: () => [['2025-01-01', {}], ['2026-02-02', {}]],
  });
  const r2 = await applyWorkoutDayV2(withHistory, '2026-02-02', workout(row(ID.bench, [{ weight: 100, reps: 1 }])));
  assert.strictEqual(r2.path, 'queued');
  assert.strictEqual(await withHistory.getSnapshot(), null, 'no partial V2 is ever published');
});

test('a sex change requests a re-fold job rather than re-reading history in the trigger', async () => {
  const h = jobHarness(bigHistory(8));
  await h.v2.requestRebuild({ mode: 'full' });
  await runRebuildToCompletion(memoryIo(h.v2, h.lb));
  const r = await refreshV2(h.v2, { sex: true });
  assert.strictEqual(r.path, 'queued');
  assert.strictEqual((await h.v2.getRebuildJob()).mode, 'fold');
});

test('a bounded weigh-in range re-scores only its dates', async () => {
  const entries = [{ id: 'a', dateKey: '2026-01-01', weight: 80 }];
  const store = memoryStoreV2({ bodyweightAsOf: (d) => pickBodyweightAsOf(entries, d), workouts: () => [] });
  for (const [d, w] of [['2026-01-05', 100], ['2026-01-12', 100], ['2026-01-20', 100]]) {
    await applyWorkoutDayV2(store, d, workout(row(ID.squat, [{ weight: w, reps: 1, id: d }])));
  }
  entries.push({ id: 'b', dateKey: '2026-01-10', weight: 60 }, { id: 'c', dateKey: '2026-01-18', weight: 80 });
  const r = await refreshV2(store, { bodyweight: true, sinceDateKey: '2026-01-10', untilDateKey: '2026-01-18' });
  assert.deepStrictEqual(r.slots, ['squat']);
  const days = [...store._days.values()].sort((a, b) => (a.dateKey < b.dateKey ? -1 : 1));
  assert.deepStrictEqual(days.map((d) => d.bodyweight.weightKg), [80, 60, 80]);
  const snap = await store.getSnapshot();
  assert.strictEqual(snap.categories.squatPattern.exercises[ID.squat].points.dateKey, '2026-01-12');
});

// ── Leaderboard retry queue: ranges keep their bounds ───────────────────────

test('queue: a single bounded range stays bounded through write, merge and retry', () => {
  const item = mergeQueueItem(null, { sinceDateKey: '2026-01-10', untilDateKey: '2026-01-18' }, 'weigh-in');
  assert.strictEqual(item.untilDateKey, '2026-01-18');
  assert.deepStrictEqual(requestsOfItem(item), [{ sinceDateKey: '2026-01-10', untilDateKey: '2026-01-18' }]);
  // Merging dates does not open it.
  const withDates = mergeQueueItem(item, { dateKeys: ['2026-02-01'] }, 'workout');
  assert.deepStrictEqual(requestsOfItem(withDates)[0], { sinceDateKey: '2026-01-10', untilDateKey: '2026-01-18' });
});

test('queue: overlapping, disjoint and open-ended ranges merge safely', () => {
  const r = (since, until) => ({ since, until });
  assert.deepStrictEqual(mergeRanges(r('2026-01-10', '2026-01-18'), r('2026-01-15', '2026-01-25')), r('2026-01-10', '2026-01-25'));
  assert.deepStrictEqual(mergeRanges(r('2026-01-10', '2026-01-12'), r('2026-03-01', '2026-03-05')), r('2026-01-10', '2026-03-05'));
  assert.deepStrictEqual(mergeRanges(r('2026-01-10', '2026-01-12'), r('2026-03-01', null)), r('2026-01-10', null));
  assert.deepStrictEqual(mergeRanges(null, r('2026-03-01', '2026-03-05')), r('2026-03-01', '2026-03-05'));
  let item = mergeQueueItem(null, { sinceDateKey: '2026-03-01', untilDateKey: '2026-03-05' }, 'a');
  item = mergeQueueItem(item, { sinceDateKey: '2026-01-10', untilDateKey: '2026-01-12' }, 'b');
  assert.deepStrictEqual(requestsOfItem(item), [{ sinceDateKey: '2026-01-10', untilDateKey: '2026-03-05' }]);
  item = mergeQueueItem(item, { sinceDateKey: '2026-04-01' }, 'open');
  assert.deepStrictEqual(requestsOfItem(item), [{ sinceDateKey: '2026-01-10' }]);
});
