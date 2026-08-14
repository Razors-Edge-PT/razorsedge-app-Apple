// Storage-shape core for coach PB analytics. Pure module: all persistence
// goes through an injected `store` object, so the exact same code runs
// against Firestore in production and an in-memory store in tests.
//
// Bounded storage shape (no document grows with training history):
//
//   coachAnalytics/{athleteUid}/exerciseDays/{exerciseId}_{dateKey}
//     { exerciseId, dateKey, day: { name, bestByReps, bestE1rm, bestE1rmSet } }
//     – one small doc per exercise per trained day (the former unbounded
//       per-exercise `history` map, exploded into per-day docs)
//
//   coachAnalytics/{athleteUid}/exercises/{exerciseId}
//     { name, repBest, e1rmBest, formulaVersion, dayCount }
//     – bounded summary: repBest has at most one entry per distinct rep count
//
//   coachAnalytics/{athleteUid}/events/{eventId}
//     – one small doc per PB event, deterministic ids (unchanged shape)
//
// Store interface (all async):
//   listDaysForExercise(exerciseId) → [{dateKey, day}]
//   listExerciseIdsForDate(dateKey) → [exerciseId]
//   setDay(exerciseId, dateKey, day) / deleteDay(exerciseId, dateKey)
//   setSummary(exerciseId, data) / deleteSummary(exerciseId)
//   listEventIdsForExercise(exerciseId) → [eventId]
//   setEvent(event) / deleteEvent(eventId)
//   flush() – commit buffered writes (no-op for stores without buffering)
//
// Firestore mapping notes: both list operations are single-field equality
// queries (auto-indexed); day-doc ids are deterministic so every operation
// here is idempotent, which is what makes edit/delete reconciliation and the
// bootstrap race repair safe to retry.

'use strict';

const { E1RM_FORMULA_VERSION } = require('./e1rm');
const { summarizeWorkoutDay, deriveExerciseEvents } = require('./pb_engine');

function dayDocId(exerciseId, dateKey) {
  return `${exerciseId}_${dateKey}`;
}

/**
 * Rebuilds ONE exercise's summary + PB event stream from its per-day docs.
 * Deterministic: the event stream is derived by the same chronological walk
 * regardless of what sequence of edits produced the current day docs.
 */
async function rebuildExercise(store, exerciseId) {
  const days = await store.listDaysForExercise(exerciseId);

  if (days.length === 0) {
    await store.deleteSummary(exerciseId);
    for (const id of await store.listEventIdsForExercise(exerciseId)) {
      await store.deleteEvent(id);
    }
    return;
  }

  const history = {};
  for (const d of days) history[d.dateKey] = d.day;
  const derived = deriveExerciseEvents(exerciseId, history);

  await store.setSummary(exerciseId, {
    name: derived.name,
    repBest: derived.repBest,
    e1rmBest: derived.e1rmBest,
    formulaVersion: E1RM_FORMULA_VERSION,
    dayCount: days.length,
  });

  const wantedIds = new Set(derived.events.map((e) => e.id));
  for (const id of await store.listEventIdsForExercise(exerciseId)) {
    if (!wantedIds.has(id)) await store.deleteEvent(id);
  }
  for (const ev of derived.events) await store.setEvent(ev);
}

/**
 * Applies the CURRENT content of one workout day (create, edit or delete —
 * pass null/absent data for a deleted workout). Touched exercises are the
 * union of the exercises in the current document and the exercises that
 * already have a day doc for this date, so removals are detected without
 * needing a before-snapshot. That property is what lets the bootstrap
 * reconciliation loop replay a day from its current truth alone.
 */
async function applyWorkoutDay(store, dateKey, workoutData) {
  const after = summarizeWorkoutDay(workoutData || {});
  const existing = await store.listExerciseIdsForDate(dateKey);
  const touched = new Set([...Object.keys(after), ...existing]);

  for (const exerciseId of touched) {
    if (after[exerciseId]) {
      await store.setDay(exerciseId, dateKey, after[exerciseId]);
    } else {
      await store.deleteDay(exerciseId, dateKey);
    }
    await rebuildExercise(store, exerciseId);
  }
  return touched.size;
}

/**
 * Bulk build for the bootstrap: derives everything from a full chronological
 * scan held in memory. The caller must have cleared the three collections
 * first (deterministic wholesale rebuild).
 *
 * @param entries iterable of [dateKey, workoutData]
 * @returns number of exercises built
 */
async function bulkRebuild(store, entries) {
  const histories = {}; // exerciseId -> { dateKey: day }
  for (const [dateKey, data] of entries) {
    const summary = summarizeWorkoutDay(data || {});
    for (const [exerciseId, day] of Object.entries(summary)) {
      (histories[exerciseId] = histories[exerciseId] || {})[dateKey] = day;
    }
  }

  for (const [exerciseId, history] of Object.entries(histories)) {
    for (const [dateKey, day] of Object.entries(history)) {
      await store.setDay(exerciseId, dateKey, day);
    }
    const derived = deriveExerciseEvents(exerciseId, history);
    await store.setSummary(exerciseId, {
      name: derived.name,
      repBest: derived.repBest,
      e1rmBest: derived.e1rmBest,
      formulaVersion: E1RM_FORMULA_VERSION,
      dayCount: Object.keys(history).length,
    });
    for (const ev of derived.events) await store.setEvent(ev);
  }
  return Object.keys(histories).length;
}

module.exports = { dayDocId, rebuildExercise, applyWorkoutDay, bulkRebuild };
