// Storage-shape core for coach PB analytics. Pure module: all persistence
// goes through an injected `store` object, so the exact same code runs
// against Firestore in production (transactional adapter in index.js) and an
// in-memory store in tests.
//
// Bounded storage shape (no document grows with training history):
//
//   coachAnalytics/{athleteUid}/exerciseDays/{exerciseId}_{dateKey}
//     { exerciseId, dateKey, day: { name, bestByReps, bestRirByReps,
//       bestWeight, bestWeightReps, bestE1rm, bestE1rmSet } }
//   coachAnalytics/{athleteUid}/exercises/{exerciseId}
//     { name, repBest, repRir, maxWeight, e1rmBest, latestDateKey,
//       formulaVersion, dayCount }
//     – bounded summary + provenance: repBest/repRir have at most one entry
//       per distinct rep count, maxWeight is a single record; latestDateKey
//       enables the append fast path. repBest holds the heaviest weight per
//       EXACT rep count, which is what makes the dominance query
//       (bestWeightAtOrAboveReps) exact without scanning history.
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
const {
  summarizeWorkoutDay, deriveExerciseEvents, applyDayToState, emptyState,
} = require('./pb_engine');

function dayDocId(exerciseId, dateKey) {
  return `${exerciseId}_${dateKey}`;
}

/** Lifetime state → persisted summary document. */
function summaryDocFrom(state, formulaVersion) {
  return {
    name: state.name,
    repBest: state.repBest,
    repRir: state.repRir,
    maxWeight: state.maxWeight,
    e1rmBest: state.e1rmBest,
    latestDateKey: state.latestDateKey,
    formulaVersion: formulaVersion || E1RM_FORMULA_VERSION,
    dayCount: state.dayCount,
  };
}

/** Persisted summary document → lifetime state (tolerates pre-v3 documents,
 *  which carried no repRir/maxWeight; a version bump rebuilds them anyway). */
function stateFromSummary(exerciseId, summary) {
  const state = emptyState(exerciseId);
  if (!summary) return state;
  state.name = summary.name || exerciseId;
  state.repBest = summary.repBest || {};
  state.repRir = summary.repRir || {};
  state.maxWeight = summary.maxWeight || null;
  state.e1rmBest = summary.e1rmBest || null;
  state.dayCount = summary.dayCount || 0;
  state.latestDateKey = summary.latestDateKey || null;
  return state;
}

function summaryFrom(exerciseId, history) {
  const derived = deriveExerciseEvents(exerciseId, history);
  return {
    summary: {
      name: derived.name,
      repBest: derived.repBest,
      repRir: derived.repRir,
      maxWeight: derived.maxWeight,
      e1rmBest: derived.e1rmBest,
      latestDateKey: derived.latestDateKey,
      formulaVersion: E1RM_FORMULA_VERSION,
      dayCount: derived.dayCount,
    },
    events: derived.events,
  };
}

/**
 * PURE fast-path computation: appending a strictly-later day to an existing
 * summary. It calls the SAME step function as the full chronological rebuild
 * (pb_engine.applyDayToState) with the state the rebuild would have reached,
 * so the fast path cannot drift from the bootstrap by construction — the
 * append is simply the final step of the walk.
 */
function fastAppendCompute(exerciseId, dateKey, day, summary) {
  const state = stateFromSummary(exerciseId, summary);
  const events = applyDayToState(state, exerciseId, dateKey, day);
  return {
    events,
    summary: summaryDocFrom(state, summary && summary.formulaVersion),
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
