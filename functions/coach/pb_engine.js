// Pure PB (personal best) engine for coach check-ins.
//
// Works on plain data extracted from users/{uid}/workouts/{YYYY-MM-DD} docs.
// No Firebase imports — fully unit-testable.
//
// Identity rules:
//   - exercise identity = stable exercise id ("exerciseId" on WES2 rows,
//     legacy "id" on older rows). Rows with no id are ignored.
//   - rep-target PB stream identity = exerciseId + exact rep count.
//   - E1RM PB stream identity = exerciseId.
//
// A set participates only when weight > 0 AND reps > 0 (matches the app's
// completed-set convention in HomeV2CalendarService). RIR presence is ignored.
//
// Event derivation is a deterministic chronological walk over per-day
// summaries, so recomputing after a workout edit/delete reproduces exactly
// the events that the surviving data justifies (self-healing reconciliation).

'use strict';

const { coachE1rm, E1RM_FORMULA_VERSION } = require('./e1rm');

/**
 * Extracts a compact per-exercise day summary from one workout document's
 * data. Returns Map-like plain object:
 *   { [exerciseId]: {
 *       name,                      // last seen display name
 *       bestByReps: { [reps]: weight },  // best weight that day per exact rep count
 *       bestE1rm: number,          // best no-RIR E1RM that day
 *       bestE1rmSet: {weight, reps},
 *     } }
 * Only the completed `exercises[]` array participates; wesPlannedExercises
 * are plans, not results.
 */
function summarizeWorkoutDay(workoutData) {
  const out = {};
  const exercises = Array.isArray(workoutData && workoutData.exercises)
    ? workoutData.exercises
    : [];
  for (const ex of exercises) {
    if (!ex || typeof ex !== 'object') continue;
    const exerciseId = typeof ex.exerciseId === 'string' && ex.exerciseId
      ? ex.exerciseId
      : (typeof ex.id === 'string' && ex.id ? ex.id : null);
    if (!exerciseId) continue;
    const sets = Array.isArray(ex.sets) ? ex.sets : [];
    for (const s of sets) {
      if (!s || typeof s !== 'object') continue;
      const weight = toNum(s.weight != null ? s.weight : s.actualWeight);
      const reps = toNum(s.reps != null ? s.reps : s.actualReps);
      if (!(weight > 0) || !(reps > 0)) continue;
      const repKey = String(Math.round(reps));
      let entry = out[exerciseId];
      if (!entry) {
        entry = { name: strOr(ex.name, exerciseId), bestByReps: {}, bestE1rm: 0, bestE1rmSet: null };
        out[exerciseId] = entry;
      }
      if (!(repKey in entry.bestByReps) || weight > entry.bestByReps[repKey]) {
        entry.bestByReps[repKey] = weight;
      }
      const e1 = coachE1rm(weight, Math.round(reps));
      if (e1 > entry.bestE1rm) {
        entry.bestE1rm = e1;
        entry.bestE1rmSet = { weight, reps: Math.round(reps) };
      }
    }
  }
  return out;
}

/**
 * Derives the full monotonic PB event stream for ONE exercise from its
 * per-day history.
 *
 * @param {string} exerciseId
 * @param {Object} history  { [dateKey]: { name, bestByReps, bestE1rm, bestE1rmSet } }
 * @returns {{ events: Array, repBest: Object, e1rmBest: Object|null, name: string }}
 *
 * Event shapes (deterministic ids):
 *   rep :  { id: `${dateKey}_${exerciseId}_rep${reps}`, type:'repPB', dateKey,
 *            exerciseId, exerciseName, reps, weightKg, prevWeightKg, pctImprovement }
 *   e1rm:  { id: `${dateKey}_${exerciseId}_e1rm`, type:'e1rmPB', dateKey,
 *            exerciseId, exerciseName, e1rmKg, prevE1rmKg, pctImprovement,
 *            weightKg, reps, formulaVersion }
 *
 * First-ever result for a stream establishes the baseline and emits NO event.
 * Multiple improvements inside one day collapse to the single day-best.
 */
function deriveExerciseEvents(exerciseId, history) {
  const dateKeys = Object.keys(history || {}).sort(); // YYYY-MM-DD sorts chronologically
  const repBest = {};   // reps -> { weightKg, dateKey }
  let e1rmBest = null;  // { e1rmKg, dateKey, weightKg, reps }
  const events = [];
  let name = exerciseId;

  for (const dateKey of dateKeys) {
    const day = history[dateKey];
    if (!day) continue;
    if (day.name) name = day.name;

    const bestByReps = day.bestByReps || {};
    for (const repKey of Object.keys(bestByReps)) {
      const weight = toNum(bestByReps[repKey]);
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
          exerciseName: day.name || name,
          reps: Number(repKey),
          weightKg: weight,
          prevWeightKg: prior.weightKg,
          pctImprovement: (weight - prior.weightKg) / prior.weightKg,
        });
        repBest[repKey] = { weightKg: weight, dateKey };
      }
    }

    const e1 = toNum(day.bestE1rm);
    if (e1 > 0 && day.bestE1rmSet) {
      if (!e1rmBest) {
        e1rmBest = {
          e1rmKg: e1,
          dateKey,
          weightKg: day.bestE1rmSet.weight,
          reps: day.bestE1rmSet.reps,
        };
      } else if (e1 > e1rmBest.e1rmKg) {
        events.push({
          id: `${dateKey}_${exerciseId}_e1rm`,
          type: 'e1rmPB',
          dateKey,
          exerciseId,
          exerciseName: day.name || name,
          e1rmKg: e1,
          prevE1rmKg: e1rmBest.e1rmKg,
          pctImprovement: (e1 - e1rmBest.e1rmKg) / e1rmBest.e1rmKg,
          weightKg: day.bestE1rmSet.weight,
          reps: day.bestE1rmSet.reps,
          formulaVersion: E1RM_FORMULA_VERSION,
        });
        e1rmBest = {
          e1rmKg: e1,
          dateKey,
          weightKg: day.bestE1rmSet.weight,
          reps: day.bestE1rmSet.reps,
        };
      }
    }
  }

  return { events, repBest, e1rmBest, name };
}

function toNum(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string') {
    const p = parseFloat(v);
    if (Number.isFinite(p)) return p;
  }
  return 0;
}

function strOr(v, fallback) {
  return typeof v === 'string' && v ? v : fallback;
}

module.exports = { summarizeWorkoutDay, deriveExerciseEvents };
