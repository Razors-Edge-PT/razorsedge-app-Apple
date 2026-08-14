// Storage-shape core for coach PB analytics. Pure module: all persistence
// goes through an injected `store` object, so the exact same code runs
// against Firestore in production (transactional adapter in index.js) and an
// in-memory store in tests.
//
// Bounded storage shape (no document grows with training history):
//
//   coachAnalytics/{athleteUid}/exerciseDays/{exerciseId}_{dateKey}
//     { exerciseId, dateKey, day: { name, bestByReps, bestE1rm, bestE1rmSet } }
//   coachAnalytics/{athleteUid}/exercises/{exerciseId}
//     { name, repBest, e1rmBest, latestDateKey, formulaVersion, dayCount }
//     – bounded summary + provenance: repBest has at most one entry per
//       distinct rep count; latestDateKey enables the append fast path
//   coachAnalytics/{athleteUid}/events/{eventId}
//     – one small doc per PB event, deterministic ids
//
// Store interface (all async):
//   getSummary(exerciseId) → summary | null
//   getDay(exerciseId, dateKey) → day | null
//   listDaysForExercise(exerciseId) → [{dateKey, day}]
//   listExerciseIdsForDate(dateKey) → [exerciseId]
//   setDay / deleteDay / setSummary / deleteSummary
//   listEventIdsForExercise(exerciseId) → [eventId]
//   setEvent(event) / deleteEvent(eventId)
//   withExerciseLock(exerciseId, fn(store)) – serialises reconciliation per
//     exercise (a Firestore transaction in production, an async mutex in the
//     memory store); fn must perform all reads before any write.
//   flush()
//
// ── Cost model ──────────────────────────────────────────────────────────────
// FAST PATH (normal chronological append — the common case):
//   1 summary read + 1 day-doc read + 1 day write + ≤(distinct reps + 1)
//   event writes + 1 summary write. Independent of history size: no
//   exerciseDays listing, no events listing.
// REBUILD FALLBACK (edit, delete, out-of-order insert, exercise removal):
//   reads that exercise's day docs + event ids, rewrites deterministically.
// Both paths are idempotent (deterministic ids/content), so at-least-once
// trigger delivery and retries are safe.

'use strict';

const { E1RM_FORMULA_VERSION } = require('./e1rm');
const { summarizeWorkoutDay, deriveExerciseEvents } = require('./pb_engine');

function dayDocId(exerciseId, dateKey) {
  return `${exerciseId}_${dateKey}`;
}

function summaryFrom(exerciseId, history) {
  const derived = deriveExerciseEvents(exerciseId, history);
  const dateKeys = Object.keys(history);
  return {
    summary: {
      name: derived.name,
      repBest: derived.repBest,
      e1rmBest: derived.e1rmBest,
      latestDateKey: dateKeys.length ? dateKeys.sort()[dateKeys.length - 1] : null,
      formulaVersion: E1RM_FORMULA_VERSION,
      dayCount: dateKeys.length,
    },
    events: derived.events,
  };
}

/**
 * PURE fast-path computation: appending a strictly-later day to an existing
 * summary. Produces exactly the events a full chronological rebuild would —
 * the append is the final step of the walk, so comparing against the current
 * bests is sufficient (verified by the equivalence property test).
 */
function fastAppendCompute(exerciseId, dateKey, day, summary) {
  const events = [];
  const repBest = { ...(summary.repBest || {}) };
  const name = day.name || summary.name || exerciseId;

  for (const repKey of Object.keys(day.bestByReps || {})) {
    const weight = Number(day.bestByReps[repKey]);
    if (!(weight > 0)) continue;
    const prior = repBest[repKey];
    if (!prior) {
      repBest[repKey] = { weightKg: weight, dateKey };
    } else if (weight > prior.weightKg) {
      events.push({
        id: `${dateKey}_${exerciseId}_rep${repKey}`,
        type: 'repPB',
        dateKey,
        exerciseId,
        exerciseName: name,
        reps: Number(repKey),
        weightKg: weight,
        prevWeightKg: prior.weightKg,
        pctImprovement: (weight - prior.weightKg) / prior.weightKg,
      });
      repBest[repKey] = { weightKg: weight, dateKey };
    }
  }

  let e1rmBest = summary.e1rmBest || null;
  const e1 = Number(day.bestE1rm) || 0;
  if (e1 > 0 && day.bestE1rmSet) {
    if (!e1rmBest) {
      e1rmBest = {
        e1rmKg: e1, dateKey,
        weightKg: day.bestE1rmSet.weight, reps: day.bestE1rmSet.reps,
      };
    } else if (e1 > e1rmBest.e1rmKg) {
      events.push({
        id: `${dateKey}_${exerciseId}_e1rm`,
        type: 'e1rmPB',
        dateKey,
        exerciseId,
        exerciseName: name,
        e1rmKg: e1,
        prevE1rmKg: e1rmBest.e1rmKg,
        pctImprovement: (e1 - e1rmBest.e1rmKg) / e1rmBest.e1rmKg,
        weightKg: day.bestE1rmSet.weight,
        reps: day.bestE1rmSet.reps,
        formulaVersion: E1RM_FORMULA_VERSION,
      });
      e1rmBest = {
        e1rmKg: e1, dateKey,
        weightKg: day.bestE1rmSet.weight, reps: day.bestE1rmSet.reps,
      };
    }
  }

  return {
    events,
    summary: {
      name,
      repBest,
      e1rmBest,
      latestDateKey: dateKey,
      formulaVersion: summary.formulaVersion || E1RM_FORMULA_VERSION,
      dayCount: (summary.dayCount || 0) + 1,
    },
  };
}

/**
 * Reconciles ONE exercise for one day inside the exercise lock. All reads
 * happen before any write (Firestore-transaction compatible).
 *
 * Returns the path taken ('fast' | 'baseline' | 'rebuild' | 'noop') so the
 * instrumented tests can prove the normal append stays bounded.
 */
async function reconcileExercise(store, exerciseId, dateKey, dayOrNull) {
  const summary = await store.getSummary(exerciseId);
  const existingDay = await store.getDay(exerciseId, dateKey);

  // FAST PATH: brand-new, chronologically latest day for a known exercise.
  if (dayOrNull && !existingDay && summary && summary.latestDateKey
      && dateKey > summary.latestDateKey) {
    const { events, summary: next } = fastAppendCompute(exerciseId, dateKey, dayOrNull, summary);
    await store.setDay(exerciseId, dateKey, dayOrNull);
    for (const ev of events) await store.setEvent(ev);
    await store.setSummary(exerciseId, next);
    return 'fast';
  }

  // BASELINE: first-ever day for this exercise → summary only, no events.
  if (dayOrNull && !existingDay && !summary) {
    const { summary: next } = summaryFrom(exerciseId, { [dateKey]: dayOrNull });
    await store.setDay(exerciseId, dateKey, dayOrNull);
    await store.setSummary(exerciseId, next);
    return 'baseline';
  }

  // Nothing to remove and nothing to add.
  if (!dayOrNull && !existingDay && !summary) return 'noop';

  // REBUILD FALLBACK: edit / delete / out-of-order insert / removal — read
  // this exercise's day docs and events, patch the day in memory, rewrite
  // deterministically.
  const days = await store.listDaysForExercise(exerciseId);
  const existingEventIds = await store.listEventIdsForExercise(exerciseId);

  const history = {};
  for (const d of days) history[d.dateKey] = d.day;
  if (dayOrNull) history[dateKey] = dayOrNull;
  else delete history[dateKey];

  if (dayOrNull) await store.setDay(exerciseId, dateKey, dayOrNull);
  else await store.deleteDay(exerciseId, dateKey);

  if (Object.keys(history).length === 0) {
    await store.deleteSummary(exerciseId);
    for (const id of existingEventIds) await store.deleteEvent(id);
    return 'rebuild';
  }

  const { summary: next, events } = summaryFrom(exerciseId, history);
  const wantedIds = new Set(events.map((e) => e.id));
  for (const id of existingEventIds) {
    if (!wantedIds.has(id)) await store.deleteEvent(id);
  }
  for (const ev of events) await store.setEvent(ev);
  await store.setSummary(exerciseId, next);
  return 'rebuild';
}

/**
 * Applies the CURRENT content of one workout day (create, edit or delete —
 * pass null/absent data for a deleted workout). Touched exercises are the
 * union of the exercises in the current document and the exercises that
 * already have a day doc for this date, so removals are detected without a
 * before-snapshot. Each exercise reconciles under its own lock, so
 * concurrent triggers serialise per exercise and converge.
 *
 * @returns {Object} paths by exerciseId (for instrumentation in tests)
 */
async function applyWorkoutDay(store, dateKey, workoutData) {
  const after = summarizeWorkoutDay(workoutData || {});
  const existing = await store.listExerciseIdsForDate(dateKey);
  const touched = new Set([...Object.keys(after), ...existing]);

  const paths = {};
  for (const exerciseId of touched) {
    await store.withExerciseLock(exerciseId, async (s) => {
      paths[exerciseId] = await reconcileExercise(
        s, exerciseId, dateKey, after[exerciseId] || null);
    });
  }
  return paths;
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
    const { summary, events } = summaryFrom(exerciseId, history);
    await store.setSummary(exerciseId, summary);
    for (const ev of events) await store.setEvent(ev);
  }
  return Object.keys(histories).length;
}

module.exports = {
  dayDocId,
  summaryFrom,
  fastAppendCompute,
  reconcileExercise,
  applyWorkoutDay,
  bulkRebuild,
};
