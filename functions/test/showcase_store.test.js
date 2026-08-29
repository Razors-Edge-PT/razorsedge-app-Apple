'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { applyWorkoutDay, rebuildAll, memoryStore } = require('../showcase/store');
const { buildShowcase } = require('../showcase/reducer');

const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
const SQUAT = 'heeBViVINHO6tUScSd6y';

function workout(exerciseId, sets) {
  return { exercises: [{ exerciseId, name: 'x', sets }] };
}

/** Applies a whole history through the incremental path, in the given order. */
async function applyAll(store, order, history) {
  for (const dateKey of order) {
    await applyWorkoutDay(store, dateKey, history[dateKey]);
  }
  return store.getSnapshot();
}

test('a chronological append takes the fast path and matches a full rebuild', async () => {
  const history = {
    '2026-01-01': workout(BENCH, [{ weight: 100, reps: 5 }]),
    '2026-02-01': workout(BENCH, [{ weight: 120, reps: 3 }]),
    '2026-03-01': workout(BENCH, [{ weight: 150, reps: 1 }]),
  };
  const store = memoryStore();
  const dates = Object.keys(history);
  const paths = [];
  for (const d of dates) {
    paths.push((await applyWorkoutDay(store, d, history[d])).path);
  }
  assert.deepStrictEqual(paths, ['append', 'append', 'append']);
  assert.deepStrictEqual(await store.getSnapshot(), buildShowcase(history));
});

test('duplicate delivery of the same day is a no-op', async () => {
  const store = memoryStore();
  const data = workout(BENCH, [{ weight: 100, reps: 5 }]);
  const first = await applyWorkoutDay(store, '2026-01-01', data);
  const before = JSON.stringify(await store.getSnapshot());
  const second = await applyWorkoutDay(store, '2026-01-01', data);
  const third = await applyWorkoutDay(store, '2026-01-01', JSON.parse(JSON.stringify(data)));

  assert.strictEqual(first.path, 'append');
  assert.strictEqual(second.path, 'noop');
  assert.strictEqual(third.path, 'noop');
  assert.strictEqual(JSON.stringify(await store.getSnapshot()), before);
});

test('an out-of-order (older) day rebuilds and still produces the right answer', async () => {
  const history = {
    '2026-01-01': workout(BENCH, [{ weight: 200, reps: 1 }]),
    '2026-06-01': workout(BENCH, [{ weight: 150, reps: 1 }]),
  };
  const store = memoryStore();
  // Newest first, then the older day arrives late.
  const newest = await applyWorkoutDay(store, '2026-06-01', history['2026-06-01']);
  const late = await applyWorkoutDay(store, '2026-01-01', history['2026-01-01']);

  assert.strictEqual(newest.path, 'append');
  assert.strictEqual(late.path, 'rebuild');
  assert.deepStrictEqual(await store.getSnapshot(), buildShowcase(history));
  assert.strictEqual((await store.getSnapshot()).lifts.bench.heaviest.weight, 200);
});

test('any arrival order converges on the same snapshot', async () => {
  const history = {
    '2026-01-01': workout(BENCH, [{ weight: 140, reps: 4 }]),
    '2026-02-01': workout(BENCH, [{ weight: 180, reps: 1 }]),
    '2026-03-01': workout(BENCH, [{ weight: 160, reps: 3 }]),
    '2026-04-01': workout(SQUAT, [{ weight: 220, reps: 2 }]),
  };
  const expected = buildShowcase(history);
  const orders = [
    ['2026-01-01', '2026-02-01', '2026-03-01', '2026-04-01'],
    ['2026-04-01', '2026-03-01', '2026-02-01', '2026-01-01'],
    ['2026-03-01', '2026-01-01', '2026-04-01', '2026-02-01'],
  ];
  for (const order of orders) {
    const store = memoryStore();
    assert.deepStrictEqual(await applyAll(store, order, history), expected, order.join(','));
  }
});

test('editing a workout down retires the record it used to justify', async () => {
  const store = memoryStore();
  await applyWorkoutDay(store, '2026-01-01', workout(BENCH, [{ weight: 100, reps: 5 }]));
  await applyWorkoutDay(store, '2026-02-01', workout(BENCH, [{ weight: 200, reps: 1 }]));
  const before = (await store.getSnapshot()).lifts.bench.heaviest;
  assert.strictEqual(before.weight, 200);

  // The 200kg set turns out to have been a typo: it was 120kg.
  const res = await applyWorkoutDay(
    store,
    '2026-02-01',
    workout(BENCH, [{ weight: 120, reps: 1 }]),
  );
  assert.strictEqual(res.path, 'rebuild');
  const after = (await store.getSnapshot()).lifts.bench.heaviest;
  assert.strictEqual(after.weight, 120);
  assert.notStrictEqual(after.fingerprint, before.fingerprint);
});

test('deleting the record workout falls back to the surviving history', async () => {
  const history = {
    '2026-01-01': workout(BENCH, [{ weight: 100, reps: 5 }]),
    '2026-02-01': workout(BENCH, [{ weight: 200, reps: 1 }]),
  };
  const store = memoryStore();
  await applyAll(store, Object.keys(history), history);
  assert.strictEqual((await store.getSnapshot()).lifts.bench.heaviest.weight, 200);

  const res = await applyWorkoutDay(store, '2026-02-01', null);
  assert.strictEqual(res.path, 'rebuild');
  assert.deepStrictEqual(
    await store.getSnapshot(),
    buildShowcase({ '2026-01-01': history['2026-01-01'] }),
  );
});

test('deleting the only workout empties the snapshot without error', async () => {
  const store = memoryStore();
  await applyWorkoutDay(store, '2026-01-01', workout(BENCH, [{ weight: 100, reps: 5 }]));
  await applyWorkoutDay(store, '2026-01-01', null);
  assert.deepStrictEqual((await store.getSnapshot()).lifts, {});
});

test('removing one exercise from a day leaves the other lift untouched', async () => {
  const store = memoryStore();
  await applyWorkoutDay(store, '2026-01-01', {
    exercises: [
      { exerciseId: BENCH, name: 'b', sets: [{ weight: 100, reps: 5 }] },
      { exerciseId: SQUAT, name: 's', sets: [{ weight: 200, reps: 5 }] },
    ],
  });
  const res = await applyWorkoutDay(store, '2026-01-01', workout(SQUAT, [{ weight: 200, reps: 5 }]));
  assert.deepStrictEqual(res.slots, ['bench']);
  const snap = await store.getSnapshot();
  assert.deepStrictEqual(Object.keys(snap.lifts), ['squat']);
  assert.strictEqual(snap.lifts.squat.heaviest.weight, 200);
});

test('a rebuild only touches the affected lift', async () => {
  const store = memoryStore();
  await applyWorkoutDay(store, '2026-01-01', {
    exercises: [
      { exerciseId: BENCH, name: 'b', sets: [{ weight: 100, reps: 5 }] },
      { exerciseId: SQUAT, name: 's', sets: [{ weight: 200, reps: 5 }] },
    ],
  });
  const squatBefore = (await store.getSnapshot()).lifts.squat;
  const res = await applyWorkoutDay(store, '2026-01-01', {
    exercises: [
      { exerciseId: BENCH, name: 'b', sets: [{ weight: 110, reps: 5 }] },
      { exerciseId: SQUAT, name: 's', sets: [{ weight: 200, reps: 5 }] },
    ],
  });
  assert.deepStrictEqual(res.slots, ['bench']);
  assert.deepStrictEqual((await store.getSnapshot()).lifts.squat, squatBefore);
});

test('a retry after a crash reproduces the same state', async () => {
  const history = {
    '2026-01-01': workout(BENCH, [{ weight: 100, reps: 5 }]),
    '2026-02-01': workout(BENCH, [{ weight: 200, reps: 1 }]),
  };
  const store = memoryStore();
  await applyAll(store, Object.keys(history), history);
  const settled = JSON.stringify(await store.getSnapshot());
  // At-least-once delivery replays every event again, in a different order.
  await applyWorkoutDay(store, '2026-02-01', history['2026-02-01']);
  await applyWorkoutDay(store, '2026-01-01', history['2026-01-01']);
  assert.strictEqual(JSON.stringify(await store.getSnapshot()), settled);
});

test('rebuildAll is order independent and equals the incremental result', async () => {
  const history = {
    '2026-01-01': workout(BENCH, [{ weight: 140, reps: 4 }]),
    '2026-02-01': workout(BENCH, [{ weight: 180, reps: 1 }]),
    '2026-03-01': workout(SQUAT, [{ weight: 220, reps: 2 }]),
  };
  const shuffled = Object.entries(history).reverse();
  const a = memoryStore();
  await rebuildAll(a, shuffled);
  const b = memoryStore();
  await applyAll(b, Object.keys(history), history);
  assert.deepStrictEqual(await a.getSnapshot(), await b.getSnapshot());
  assert.deepStrictEqual(await a.getSnapshot(), buildShowcase(history));
});

test('a schema/formula version change forces a full rebuild of every lift', async () => {
  const store = memoryStore();
  await applyWorkoutDay(store, '2026-01-01', workout(BENCH, [{ weight: 100, reps: 5 }]));
  const state = await store.getState();
  await store.setState(Object.assign({}, state, { formulaVersion: 0 }));

  const res = await applyWorkoutDay(store, '2026-02-01', workout(SQUAT, [{ weight: 200, reps: 5 }]));
  assert.strictEqual(res.path, 'rebuild');
  assert.deepStrictEqual(
    await store.getSnapshot(),
    buildShowcase({
      '2026-01-01': workout(BENCH, [{ weight: 100, reps: 5 }]),
      '2026-02-01': workout(SQUAT, [{ weight: 200, reps: 5 }]),
    }),
  );
});

test('the high-water mark never decreases, so a re-added old day rebuilds', async () => {
  const store = memoryStore();
  await applyWorkoutDay(store, '2026-06-01', workout(BENCH, [{ weight: 100, reps: 5 }]));
  await applyWorkoutDay(store, '2026-06-01', null);
  assert.strictEqual((await store.getState()).latestDateKey, '2026-06-01');
  const res = await applyWorkoutDay(store, '2026-06-01', workout(BENCH, [{ weight: 100, reps: 5 }]));
  assert.strictEqual(res.path, 'rebuild');
  assert.strictEqual((await store.getSnapshot()).lifts.bench.heaviest.weight, 100);
});

test('non-Big-Five training never creates showcase state', async () => {
  const store = memoryStore();
  const res = await applyWorkoutDay(store, '2026-01-01', {
    exercises: [
      { exerciseId: 'YvwK9kwc1hcA2omz1g4r', name: 'Larsen Bench Press', sets: [{ weight: 300, reps: 1 }] },
      { exerciseId: 'RFyjAjezFs8Rf7CQoaXz', name: 'Pull-Up', sets: [{ weight: 90, reps: 10 }] },
    ],
  });
  assert.strictEqual(res.path, 'noop');
  assert.strictEqual(await store.getSnapshot(), null);
});
