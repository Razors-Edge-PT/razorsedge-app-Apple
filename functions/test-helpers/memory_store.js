// In-memory implementation of the analytics store interface — the production
// Firestore adapter (functions/coach/index.js) implements the same contract,
// including withExerciseLock (a transaction there, an async mutex here), so
// tests built on this exercise the exact reconciliation code that runs in
// production. Instrumented: per-operation counts prove the bounded fast path.
//
// Lives outside functions/test/ so `node --test` does not treat it as a suite.

'use strict';

function memoryStore() {
  const days = new Map();      // `${exerciseId}_${dateKey}` -> {exerciseId, dateKey, day}
  const summaries = new Map(); // exerciseId -> summary
  const events = new Map();    // eventId -> event
  const counts = {
    getSummary: 0, getDay: 0, listDaysForExercise: 0,
    listExerciseIdsForDate: 0, listEventIdsForExercise: 0,
    setDay: 0, setEvent: 0, setSummary: 0,
  };
  const locks = new Map(); // exerciseId -> Promise chain (real serialisation)

  const store = {
    async getSummary(exerciseId) {
      counts.getSummary++;
      return summaries.has(exerciseId) ? clone(summaries.get(exerciseId)) : null;
    },
    async getDay(exerciseId, dateKey) {
      counts.getDay++;
      const d = days.get(`${exerciseId}_${dateKey}`);
      return d ? clone(d.day) : null;
    },
    async listDaysForExercise(exerciseId) {
      counts.listDaysForExercise++;
      return [...days.values()]
        .filter((d) => d.exerciseId === exerciseId)
        .map((d) => ({ dateKey: d.dateKey, day: clone(d.day) }));
    },
    async listExerciseIdsForDate(dateKey) {
      counts.listExerciseIdsForDate++;
      return [...new Set([...days.values()]
        .filter((d) => d.dateKey === dateKey)
        .map((d) => d.exerciseId))];
    },
    async listEventIdsForExercise(exerciseId) {
      counts.listEventIdsForExercise++;
      return [...events.values()]
        .filter((e) => e.exerciseId === exerciseId)
        .map((e) => e.id);
    },
    async setDay(exerciseId, dateKey, day) {
      counts.setDay++;
      days.set(`${exerciseId}_${dateKey}`, { exerciseId, dateKey, day: clone(day) });
    },
    async deleteDay(exerciseId, dateKey) { days.delete(`${exerciseId}_${dateKey}`); },
    async setSummary(exerciseId, data) { counts.setSummary++; summaries.set(exerciseId, clone(data)); },
    async deleteSummary(exerciseId) { summaries.delete(exerciseId); },
    async setEvent(ev) { counts.setEvent++; events.set(ev.id, clone(ev)); },
    async deleteEvent(id) { events.delete(id); },
    async withExerciseLock(exerciseId, fn) {
      // Genuine async mutex per exercise: concurrent callers serialise.
      const prev = locks.get(exerciseId) || Promise.resolve();
      let release;
      const next = new Promise((res) => { release = res; });
      locks.set(exerciseId, prev.then(() => next));
      await prev;
      try {
        await fn(store);
      } finally {
        release();
      }
    },
    async flush() {},
  };
  return { store, days, summaries, events, counts };
}

function clone(v) { return v == null ? v : JSON.parse(JSON.stringify(v)); }

/** Stable JSON snapshot of a store's three collections, for equality asserts. */
function snapshotOf(s) {
  const sortEntries = (m) => [...m.entries()].sort(([a], [b]) => (a < b ? -1 : 1));
  return JSON.stringify({
    days: sortEntries(s.days),
    summaries: sortEntries(s.summaries),
    events: sortEntries(s.events),
  });
}

module.exports = { memoryStore, clone, snapshotOf };
