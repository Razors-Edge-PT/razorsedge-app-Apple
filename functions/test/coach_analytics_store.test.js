'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  applyWorkoutDay, bulkRebuild, fastAppendCompute,
} = require('../coach/analytics_store');

// The in-memory store lives in ../test-helpers/memory_store.js so the PB
// regression suite exercises the identical store contract.
const { memoryStore, snapshotOf } = require('../test-helpers/memory_store');

const bench = (w, reps = 5) => ({
  exercises: [{
    exerciseId: 'bench', name: 'Bench Press, Barbell',
    sets: [{ weight: w, reps }],
  }],
});
const benchAndSquat = (bw, sw) => ({
  exercises: [
    { exerciseId: 'bench', name: 'Bench Press, Barbell', sets: [{ weight: bw, reps: 5 }] },
    { exerciseId: 'squat', name: 'Back Squat, Barbell', sets: [{ weight: sw, reps: 3 }] },
  ],
});

async function controlBuild(entries) {
  const c = memoryStore();
  await bulkRebuild(c.store, entries);
  return c;
}

// ── Fast path: bounded normal append (item G) ───────────────────────────────

test('fast path: chronological append never lists lifetime days or events', async () => {
  const live = memoryStore();
  // Seed a large history via bulk build (200 days).
  const entries = [];
  for (let i = 0; i < 200; i++) {
    const d = new Date(Date.UTC(2024, 0, 1 + i * 2));
    entries.push([d.toISOString().slice(0, 10), bench(100 + (i % 5))]);
  }
  await bulkRebuild(live.store, entries);

  // Normal append: a new latest day.
  const before = { ...live.counts };
  const paths = await applyWorkoutDay(live.store, '2026-08-12', bench(120));
  assert.equal(paths.bench, 'fast');

  // Bounded ops regardless of the 200-day history:
  assert.equal(live.counts.listDaysForExercise - before.listDaysForExercise, 0);
  assert.equal(live.counts.listEventIdsForExercise - before.listEventIdsForExercise, 0);
  assert.equal(live.counts.getSummary - before.getSummary, 1);
  assert.equal(live.counts.getDay - before.getDay, 1);
  assert.equal(live.counts.setDay - before.setDay, 1);
  assert.equal(live.counts.setSummary - before.setSummary, 1);
});

test('fast path: equals a clean rebuild for appended sequences (equivalence)', async () => {
  // Apply a whole sequence via the incremental path…
  const seq = [
    ['2026-01-05', bench(100)],
    ['2026-01-12', bench(102.5)],
    ['2026-01-19', benchAndSquat(101, 140)],
    ['2026-01-26', bench(105, 5)],
    ['2026-02-02', { exercises: [{ exerciseId: 'bench', name: 'Bench Press, Barbell', sets: [{ weight: 90, reps: 12 }, { weight: 106, reps: 5 }] }] }],
  ];
  const live = memoryStore();
  for (const [dateKey, data] of seq) {
    await applyWorkoutDay(live.store, dateKey, data);
  }
  const control = await controlBuild(seq);
  assert.equal(snapshotOf(live), snapshotOf(control));
});

test('fast path: first-ever exercise day is a baseline with no events', async () => {
  const live = memoryStore();
  const paths = await applyWorkoutDay(live.store, '2026-01-05', bench(100));
  assert.equal(paths.bench, 'baseline');
  assert.equal(live.events.size, 0);
  assert.equal(live.summaries.get('bench').repBest['5'].weightKg, 100);
  assert.equal(live.summaries.get('bench').latestDateKey, '2026-01-05');
});

test('fast path: duplicate/retried trigger delivery is idempotent', async () => {
  const live = memoryStore();
  await applyWorkoutDay(live.store, '2026-01-05', bench(100));
  await applyWorkoutDay(live.store, '2026-01-12', bench(102.5));
  const once = snapshotOf(live);
  // Redelivery of the same event: same day, same data → rebuild fallback
  // (day doc exists) converging to the identical state.
  const paths = await applyWorkoutDay(live.store, '2026-01-12', bench(102.5));
  assert.equal(paths.bench, 'rebuild');
  assert.equal(snapshotOf(live), once);
});

// ── Rebuild fallback: edits / deletes / out-of-order (items G/H) ────────────

test('fallback: edit then delete converge to fresh rebuilds', async () => {
  const live = memoryStore();
  await applyWorkoutDay(live.store, '2026-01-05', bench(100));
  await applyWorkoutDay(live.store, '2026-01-12', bench(102.5));

  await applyWorkoutDay(live.store, '2026-01-12', bench(100)); // edit down
  assert.equal(snapshotOf(live), snapshotOf(await controlBuild([
    ['2026-01-05', bench(100)], ['2026-01-12', bench(100)],
  ])));
  assert.equal(live.events.size, 0);

  await applyWorkoutDay(live.store, '2026-01-12', null); // delete
  assert.equal(snapshotOf(live), snapshotOf(await controlBuild([['2026-01-05', bench(100)]])));
});

test('fallback: out-of-order (older) date insert self-heals downstream events', async () => {
  const live = memoryStore();
  await applyWorkoutDay(live.store, '2026-01-05', bench(100));
  await applyWorkoutDay(live.store, '2026-01-19', bench(102.5));
  // Older date inserted afterwards with a higher weight: the Jan 19 event's
  // provenance changes (prev becomes 101? No — Jan 12 at 103 outranks it).
  const paths = await applyWorkoutDay(live.store, '2026-01-12', bench(103));
  assert.equal(paths.bench, 'rebuild');
  const control = await controlBuild([
    ['2026-01-05', bench(100)], ['2026-01-12', bench(103)], ['2026-01-19', bench(102.5)],
  ]);
  assert.equal(snapshotOf(live), snapshotOf(control));
  // Jan 19 is no longer a PB (103 came before it); Jan 12 is.
  assert.ok(live.events.has('2026-01-12_bench_rep5'));
  assert.ok(!live.events.has('2026-01-19_bench_rep5'));
});

test('fallback: exercise removed from a day is detected without a before-snapshot', async () => {
  const live = memoryStore();
  await applyWorkoutDay(live.store, '2026-01-05', benchAndSquat(100, 140));
  await applyWorkoutDay(live.store, '2026-01-12', benchAndSquat(102.5, 145));
  await applyWorkoutDay(live.store, '2026-01-12', bench(102.5)); // squat removed
  const control = await controlBuild([
    ['2026-01-05', benchAndSquat(100, 140)], ['2026-01-12', bench(102.5)],
  ]);
  assert.equal(snapshotOf(live), snapshotOf(control));
  assert.equal([...live.events.values()].filter((e) => e.exerciseId === 'squat').length, 0);
});

// ── Concurrency (item H): simultaneous triggers converge ────────────────────

test('concurrency: parallel appends to the same exercise serialise and converge', async () => {
  const live = memoryStore();
  await applyWorkoutDay(live.store, '2026-01-05', bench(100));
  // Two triggers firing at once for different dates on the same exercise.
  await Promise.all([
    applyWorkoutDay(live.store, '2026-01-12', bench(102.5)),
    applyWorkoutDay(live.store, '2026-01-19', bench(105)),
  ]);
  const control = await controlBuild([
    ['2026-01-05', bench(100)], ['2026-01-12', bench(102.5)], ['2026-01-19', bench(105)],
  ]);
  assert.equal(snapshotOf(live), snapshotOf(control));
  // Both PBs present — neither overwrote the other's stronger result.
  assert.ok(live.events.has('2026-01-12_bench_rep5'));
  assert.ok(live.events.has('2026-01-19_bench_rep5'));
});

test('concurrency: rapid edits of the same date converge to the last truth', async () => {
  const live = memoryStore();
  await applyWorkoutDay(live.store, '2026-01-05', bench(100));
  // Simulate rapid successive edits (at-least-once, possibly interleaved):
  await Promise.all([
    applyWorkoutDay(live.store, '2026-01-12', bench(102.5)),
    applyWorkoutDay(live.store, '2026-01-12', bench(107.5)),
  ]);
  // Final Firestore truth is 107.5; replay it once more (idempotent) to
  // model the trigger for the final write landing last.
  await applyWorkoutDay(live.store, '2026-01-12', bench(107.5));
  const control = await controlBuild([
    ['2026-01-05', bench(100)], ['2026-01-12', bench(107.5)],
  ]);
  assert.equal(snapshotOf(live), snapshotOf(control));
});

test('concurrency: two exercises in one workout reconcile independently', async () => {
  const live = memoryStore();
  await applyWorkoutDay(live.store, '2026-01-05', benchAndSquat(100, 140));
  await Promise.all([
    applyWorkoutDay(live.store, '2026-01-12', benchAndSquat(102.5, 145)),
    applyWorkoutDay(live.store, '2026-01-19', bench(105)),
  ]);
  const control = await controlBuild([
    ['2026-01-05', benchAndSquat(100, 140)],
    ['2026-01-12', benchAndSquat(102.5, 145)],
    ['2026-01-19', bench(105)],
  ]);
  assert.equal(snapshotOf(live), snapshotOf(control));
});

// ── Bootstrap race (item E context; replay via current truth) ───────────────

test('race: edit during bootstrap is repaired by reconciliation replay', async () => {
  const live = memoryStore();
  await bulkRebuild(live.store, [['2026-01-05', bench(100)], ['2026-01-12', bench(102.5)]]);
  await applyWorkoutDay(live.store, '2026-01-12', bench(107.5)); // dirty replay
  const control = await controlBuild([['2026-01-05', bench(100)], ['2026-01-12', bench(107.5)]]);
  assert.equal(snapshotOf(live), snapshotOf(control));
  const repEvents = [...live.events.values()].filter((e) => e.type === 'repPB');
  assert.equal(repEvents.length, 1);
  assert.equal(repEvents[0].weightKg, 107.5);
});

test('race: delete during bootstrap removes the stale day and its events', async () => {
  const live = memoryStore();
  await bulkRebuild(live.store, [['2026-01-05', bench(100)], ['2026-01-12', bench(102.5)]]);
  await applyWorkoutDay(live.store, '2026-01-12', null);
  assert.equal(snapshotOf(live), snapshotOf(await controlBuild([['2026-01-05', bench(100)]])));
});

// ── Bounded storage shape (item R) ──────────────────────────────────────────

test('storage: summaries stay bounded — history lives in per-day docs', async () => {
  const live = memoryStore();
  const entries = [];
  for (let i = 0; i < 200; i++) {
    const d = new Date(Date.UTC(2024, 0, 1 + i * 2));
    entries.push([d.toISOString().slice(0, 10), bench(100 + (i % 5))]);
  }
  await bulkRebuild(live.store, entries);
  const summary = live.summaries.get('bench');
  assert.equal(summary.dayCount, 200);
  assert.equal(summary.history, undefined);
  // repRir and maxWeight are single bounded records, not history: repRir holds
  // at most one entry per distinct rep count, maxWeight exactly one entry.
  assert.deepEqual(Object.keys(summary).sort(),
    ['dayCount', 'e1rmBest', 'formulaVersion', 'latestDateKey', 'maxWeight',
      'name', 'repBest', 'repRir']);
  assert.equal(live.days.size, 200);
});

// ── fastAppendCompute unit sanity ───────────────────────────────────────────

test('fastAppendCompute: strict improvement only, dominance-aware', () => {
  const summary = {
    name: 'Bench Press, Barbell',
    repBest: { 5: { weightKg: 100, dateKey: '2026-01-05' } },
    repRir: {},
    maxWeight: { weightKg: 100, reps: 5, dateKey: '2026-01-05' },
    e1rmBest: { e1rmKg: 112.5, dateKey: '2026-01-05', weightKg: 100, reps: 5 },
    latestDateKey: '2026-01-05', formulaVersion: 1, dayCount: 1,
  };
  const day = {
    name: 'Bench Press, Barbell',
    bestByReps: { 5: 100, 3: 110 }, // equal 5-rep (no PB); 110x3 beats the 100x5
    bestWeight: 110,
    bestWeightReps: 3,
    bestE1rm: 116.47, bestE1rmSet: { weight: 110, reps: 3 },
  };
  const { events, summary: next } = fastAppendCompute('bench', '2026-01-12', day, summary);

  const reps = events.filter((e) => e.type === 'repPB');
  assert.equal(reps.length, 1);            // the equal 5-rep set produces nothing
  assert.equal(reps[0].reps, 3);
  assert.equal(reps[0].prevWeightKg, 100); // judged against the 100 done for 5
  assert.equal(events.filter((e) => e.type === 'maxWeightPB').length, 1);
  assert.equal(events.filter((e) => e.type === 'e1rmPB').length, 1);
  assert.equal(next.repBest['3'].weightKg, 110);
  assert.equal(next.maxWeight.weightKg, 110);
  assert.equal(next.latestDateKey, '2026-01-12');
  assert.equal(next.dayCount, 2);
});
