'use strict';

// Coach PB analytics for bodyweight exercises (Chin-Up, Pull-Up, Dips …).
//
// The legacy workout screen stored bodyweight + added load; WES2 stores the
// added load alone. Analytics v4 compared the raw numbers, so once an athlete
// moved to WES2 a bodyweight-exercise PB could never fire against their legacy
// history. v5 compares every set on its TOTAL load at the bodyweight recorded
// on or before its day (showcase/bodyweight.js), and the praise presents the
// added load.

const test = require('node:test');
const assert = require('node:assert/strict');

const { summarizeWorkoutDay, deriveExerciseEvents } = require('../coach/pb_engine');
const { applyWorkoutDay, bulkRebuild } = require('../coach/analytics_store');
const { isBodyweightExercise } = require('../coach/bodyweight_exercises');
const { trainingParagraph } = require('../coach/message');
const { pickBodyweightAsOf } = require('../showcase/bodyweight');
const { memoryStore, snapshotOf } = require('../test-helpers/memory_store');

const CHIN = 'XM9026peNIu0R8qh7UqY';
const KEY = CHIN.toLowerCase();
const chin = (sets) => ({ exercises: [{ exerciseId: CHIN, name: 'Chin-Up', sets }] });
/** Legacy screen: total stored, typed added load beside it. */
const legacy = (total, added, reps) => ({ weight: total, weightAdded: added, reps });
/** WES2: the added load, verbatim. */
const wes2 = (added, reps, setIndex = 0) => ({ setIndex, weight: added, reps });
const weighIn = (dateKey, weight) => ({ id: `w-${dateKey}`, weight, unit: 'kg', dateKey });

/** The shared memory store, resolving bodyweight from [entries]. */
function storeWith(entries) {
  const c = memoryStore();
  c.store.getBodyweightAsOfMany = async (keys) =>
    new Map(keys.map((d) => [d, pickBodyweightAsOf(entries, d)]));
  return c;
}

const HISTORY = [
  ['2026-05-01', chin([legacy(138.5, 53.5, 3)])],
  ['2026-08-01', chin([wes2(40, 3)])], // 125 total: below the legacy record
  ['2026-08-10', chin([wes2(60, 3)])], // 145 total: a new all-time heaviest
];
const WEIGH_INS = [weighIn('2026-04-01', 85)];

test('the bodyweight-exercise catalogue', () => {
  assert.equal(isBodyweightExercise(CHIN, 'x'), true);
  assert.equal(isBodyweightExercise(KEY, 'x'), true, 'lowercased catalogue copies');
  assert.equal(isBodyweightExercise(null, ' Chin-Up '), true);
  assert.equal(isBodyweightExercise('FtayDmR5BVnGS1FXlXLL', ''), true, 'Triceps Dip');
  assert.equal(isBodyweightExercise('AmfUWbF1DH3I7qPAdh5k', 'Bench Press, Barbell'), false);
});

test('bodyweight-exercise sets are compared on total load at the recorded bodyweight', () => {
  const w = summarizeWorkoutDay(chin([wes2(60, 3)]), { bodyweightKg: 85 });
  assert.equal(w[KEY].bestWeight, 145);
  assert.equal(w[KEY].bodyweightKg, 85);
  // The typed added load is authoritative; the total is rebuilt from it.
  assert.equal(summarizeWorkoutDay(chin([legacy(135, 55, 3)]), { bodyweightKg: 85 })[KEY].bestWeight, 140);
  // No bodyweight recorded: a WES2 set is left out, a legacy total stands.
  assert.deepEqual(summarizeWorkoutDay(chin([wes2(60, 3)]), { bodyweightKg: null }), {});
  assert.equal(summarizeWorkoutDay(chin([legacy(135, 55, 3)]), { bodyweightKg: null })[KEY].bestWeight, 135);
  // Counting which exercises were trained still reads sets as stored.
  assert.equal(Object.keys(summarizeWorkoutDay(chin([wes2(60, 3)]))).length, 1);
});

test('a stronger WES2 set is a PB against legacy history; a weaker one is not', async () => {
  const c = storeWith(WEIGH_INS);
  await bulkRebuild(c.store, HISTORY);
  const events = [...c.events.values()];
  assert.deepEqual(events.filter((e) => e.dateKey === '2026-08-01'), []);
  const max = events.find((e) => e.dateKey === '2026-08-10' && e.type === 'maxWeightPB');
  assert.ok(max, 'all-time heaviest');
  assert.equal(max.weightKg, 145);
  assert.equal(max.prevWeightKg, 138.5);
  assert.equal(max.bodyweightKg, 85);
  assert.ok(events.find((e) => e.dateKey === '2026-08-10' && e.type === 'e1rmPB'));

  // The v4 reading compared 60 with 138.5 and saw nothing at all.
  const raw = {};
  for (const [d, data] of HISTORY) raw[d] = summarizeWorkoutDay(data)[KEY];
  assert.deepEqual(
    deriveExerciseEvents(KEY, raw).events.filter((e) => e.dateKey === '2026-08-10'),
    [],
  );
});

test('the incremental path publishes exactly what the bootstrap does', async () => {
  const bulk = storeWith(WEIGH_INS);
  await bulkRebuild(bulk.store, HISTORY);
  const live = storeWith(WEIGH_INS);
  for (const [d, data] of HISTORY) await applyWorkoutDay(live.store, d, data);
  assert.equal(snapshotOf(live), snapshotOf(bulk));
});

test('a WES2 day before any weigh-in waits for one, then matches a fresh bootstrap', async () => {
  const entries = [];
  const live = storeWith(entries);
  for (const [d, data] of HISTORY) await applyWorkoutDay(live.store, d, data);
  assert.equal([...live.days.values()].filter((d) => d.dateKey >= '2026-08-01').length, 0);

  // The athlete back-fills a weigh-in; the weigh-in trigger replays the days.
  entries.push(weighIn('2026-04-01', 85));
  for (const [d, data] of HISTORY) await applyWorkoutDay(live.store, d, data);
  const bulk = storeWith(entries);
  await bulkRebuild(bulk.store, HISTORY);
  assert.equal(snapshotOf(live), snapshotOf(bulk));
});

test('every other exercise is analysed exactly as before', async () => {
  const bench = (w, reps = 5) => ({
    exercises: [{
      exerciseId: 'AmfUWbF1DH3I7qPAdh5k',
      name: 'Bench Press, Barbell',
      sets: [{ setIndex: 0, weight: w, reps }, { weight: w - 10, weightAdded: 12, reps: reps + 2 }],
    }],
  });
  const h = [['2026-01-05', bench(100)], ['2026-01-12', bench(102.5)], ['2026-01-19', bench(101)]];
  for (const [, data] of h) {
    assert.deepEqual(summarizeWorkoutDay(data, { bodyweightKg: 85 }), summarizeWorkoutDay(data));
  }
  const withBw = storeWith([weighIn('2026-01-01', 85)]);
  await bulkRebuild(withBw.store, h);
  const plain = memoryStore();
  await bulkRebuild(plain.store, h);
  assert.equal(snapshotOf(withBw), snapshotOf(plain));
  assert.ok([...withBw.events.values()].every((e) => !('bodyweightKg' in e)));
});

test('praise reads a bodyweight exercise as the load added to bodyweight', async () => {
  const c = storeWith(WEIGH_INS);
  await bulkRebuild(c.store, HISTORY);
  const ev = [...c.events.values()].find((e) => e.type === 'maxWeightPB');
  const text = trainingParagraph([{ kind: 'maxWeightPB', event: ev }], 1);
  assert.match(text, /\+60kg for 3/);
  assert.doesNotMatch(text, /145kg/);

  const bwOnly = trainingParagraph([{ kind: 'repPB', event: { ...ev, type: 'repPB', weightKg: 85 } }], 1);
  assert.match(bwOnly, /bodyweight for 3/);

  // Every other exercise reads exactly as before.
  const benchText = trainingParagraph([{
    kind: 'maxWeightPB',
    event: { exerciseName: 'Bench Press, Barbell', weightKg: 102.5, reps: 5 },
  }], 1);
  assert.match(benchText, /102\.5kg for 5/);
});
