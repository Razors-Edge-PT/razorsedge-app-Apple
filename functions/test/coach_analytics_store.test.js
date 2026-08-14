'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { applyWorkoutDay, bulkRebuild } = require('../coach/analytics_store');

// In-memory implementation of the store interface — the production Firestore
// adapter (functions/coach/index.js) implements the same contract, so these
// tests exercise the exact reconciliation code that runs in production.
function memoryStore() {
  const days = new Map();      // `${exerciseId}_${dateKey}` -> {exerciseId, dateKey, day}
  const summaries = new Map(); // exerciseId -> summary
  const events = new Map();    // eventId -> event
  const store = {
    async listDaysForExercise(exerciseId) {
      return [...days.values()]
        .filter((d) => d.exerciseId === exerciseId)
        .map((d) => ({ dateKey: d.dateKey, day: d.day }));
    },
    async listExerciseIdsForDate(dateKey) {
      return [...new Set([...days.values()]
        .filter((d) => d.dateKey === dateKey)
        .map((d) => d.exerciseId))];
    },
    async setDay(exerciseId, dateKey, day) {
      days.set(`${exerciseId}_${dateKey}`, { exerciseId, dateKey, day });
    },
    async deleteDay(exerciseId, dateKey) {
      days.delete(`${exerciseId}_${dateKey}`);
    },
    async setSummary(exerciseId, data) { summaries.set(exerciseId, data); },
    async deleteSummary(exerciseId) { summaries.delete(exerciseId); },
    async listEventIdsForExercise(exerciseId) {
      return [...events.values()]
        .filter((e) => e.exerciseId === exerciseId)
        .map((e) => e.id);
    },
    async setEvent(ev) { events.set(ev.id, ev); },
    async deleteEvent(id) { events.delete(id); },
    async flush() {},
  };
  return { store, days, summaries, events };
}

function snapshotOf(s) {
  const sortEntries = (m) => [...m.entries()].sort(([a], [b]) => (a < b ? -1 : 1));
  return JSON.stringify({
    days: sortEntries(s.days),
    summaries: sortEntries(s.summaries),
    events: sortEntries(s.events),
  });
}

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

// ── Incremental self-heal (create / edit / delete) ──────────────────────────

test('store: create then edit then delete converges to a fresh rebuild each time', async () => {
  const live = memoryStore();
  await applyWorkoutDay(live.store, '2026-01-05', bench(100));
  await applyWorkoutDay(live.store, '2026-01-12', bench(102.5));

  // Edit: the PB workout is corrected downward → PB event must disappear.
  await applyWorkoutDay(live.store, '2026-01-12', bench(100));
  let control = memoryStore();
  await bulkRebuild(control.store, [['2026-01-05', bench(100)], ['2026-01-12', bench(100)]]);
  assert.equal(snapshotOf(live), snapshotOf(control));
  assert.equal(live.events.size, 0);

  // Delete the day entirely.
  await applyWorkoutDay(live.store, '2026-01-12', null);
  control = memoryStore();
  await bulkRebuild(control.store, [['2026-01-05', bench(100)]]);
  assert.equal(snapshotOf(live), snapshotOf(control));
});

// ── Bootstrap ↔ workout-write race ──────────────────────────────────────────
//
// Scenario per stabilisation item 2: the bootstrap's scan captured a STALE
// version of a workout (the athlete edited it mid-bootstrap). The trigger
// deferred the write into dirtyDates; the reconciliation loop replays the
// day via applyWorkoutDay from its CURRENT truth. The final state must equal
// a clean build from the final data — with no later workout write needed.

test('race: edit during bootstrap is repaired by reconciliation replay', async () => {
  const OLD = bench(102.5); // what the scan saw
  const NEW = bench(107.5); // what the athlete saved mid-bootstrap

  const live = memoryStore();
  await bulkRebuild(live.store, [['2026-01-05', bench(100)], ['2026-01-12', OLD]]);
  // reconciliation drains dirtyDates = ['2026-01-12']:
  await applyWorkoutDay(live.store, '2026-01-12', NEW);

  const control = memoryStore();
  await bulkRebuild(control.store, [['2026-01-05', bench(100)], ['2026-01-12', NEW]]);

  assert.equal(snapshotOf(live), snapshotOf(control));
  // Exactly one rep PB (plus its legitimate E1RM twin) — none missed, none
  // duplicated, and the stale 102.5 event is gone.
  const repEvents = [...live.events.values()].filter((e) => e.type === 'repPB');
  assert.equal(repEvents.length, 1);
  assert.equal(repEvents[0].weightKg, 107.5);
  assert.equal(repEvents[0].prevWeightKg, 100);
  assert.ok(!live.events.has('2026-01-12_bench_rep5') || repEvents[0].weightKg === 107.5);
});

test('race: delete during bootstrap removes the stale day and its events', async () => {
  const live = memoryStore();
  await bulkRebuild(live.store, [['2026-01-05', bench(100)], ['2026-01-12', bench(102.5)]]);
  await applyWorkoutDay(live.store, '2026-01-12', null); // dirty replay of deleted doc

  const control = memoryStore();
  await bulkRebuild(control.store, [['2026-01-05', bench(100)]]);
  assert.equal(snapshotOf(live), snapshotOf(control));
  assert.equal(live.events.size, 0);
  assert.equal(live.summaries.get('bench').repBest['5'].weightKg, 100);
});

test('race: exercise removed from a day mid-bootstrap is detected without a before-snapshot', async () => {
  // Scan saw bench+squat on Jan 12; the edit removed squat.
  const live = memoryStore();
  await bulkRebuild(live.store, [
    ['2026-01-05', benchAndSquat(100, 140)],
    ['2026-01-12', benchAndSquat(102.5, 145)],
  ]);
  await applyWorkoutDay(live.store, '2026-01-12', bench(102.5));

  const control = memoryStore();
  await bulkRebuild(control.store, [
    ['2026-01-05', benchAndSquat(100, 140)],
    ['2026-01-12', bench(102.5)],
  ]);
  assert.equal(snapshotOf(live), snapshotOf(control));
  // Squat's phantom PB from the stale scan is gone; its baseline remains.
  assert.equal([...live.events.values()].filter((e) => e.exerciseId === 'squat').length, 0);
  assert.equal(live.summaries.get('squat').repBest['3'].weightKg, 140);
});

test('race: brand-new workout created during bootstrap lands via replay', async () => {
  const live = memoryStore();
  await bulkRebuild(live.store, [['2026-01-05', bench(100)]]); // scan missed Jan 19
  await applyWorkoutDay(live.store, '2026-01-19', bench(105));

  const control = memoryStore();
  await bulkRebuild(control.store, [['2026-01-05', bench(100)], ['2026-01-19', bench(105)]]);
  assert.equal(snapshotOf(live), snapshotOf(control));
  assert.equal([...live.events.values()][0].id, '2026-01-19_bench_rep5');
});

test('race: replay is idempotent — repeating the same reconciliation is a no-op', async () => {
  const live = memoryStore();
  await bulkRebuild(live.store, [['2026-01-05', bench(100)], ['2026-01-12', bench(102.5)]]);
  await applyWorkoutDay(live.store, '2026-01-12', bench(107.5));
  const once = snapshotOf(live);
  await applyWorkoutDay(live.store, '2026-01-12', bench(107.5));
  assert.equal(snapshotOf(live), once);
});

// ── Bounded storage shape ───────────────────────────────────────────────────

test('storage: summaries stay bounded — history lives in per-day docs', async () => {
  const live = memoryStore();
  const entries = [];
  for (let i = 0; i < 200; i++) {
    const d = new Date(Date.UTC(2024, 0, 1 + i * 2));
    entries.push([d.toISOString().slice(0, 10), bench(100 + (i % 5))]);
  }
  await bulkRebuild(live.store, entries);
  const summary = live.summaries.get('bench');
  assert.ok(summary);
  assert.equal(summary.dayCount, 200);
  // The summary contains only bests — no per-day history map.
  assert.equal(summary.history, undefined);
  assert.deepEqual(Object.keys(summary).sort(),
    ['dayCount', 'e1rmBest', 'formulaVersion', 'name', 'repBest']);
  // Per-day docs: exactly one small doc per trained day.
  assert.equal(live.days.size, 200);
});
