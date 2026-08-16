// Pure PB (personal best) engine for coach check-ins.
//
// Works on plain data extracted from users/{uid}/workouts/{YYYY-MM-DD} docs.
// No Firebase imports — fully unit-testable.
//
// Identity rules:
//   - exercise identity = stable exercise id ("exerciseId" on WES2 rows,
//     legacy "id" on older rows). Rows with no id are ignored.
//   - every PB stream is keyed on that exercise id; rep counts are TARGETS,
//     not independent streams (see below).
//
// A set participates only when weight > 0 AND reps > 0 (matches the app's
// completed-set convention in HomeV2CalendarService).
//
// ── PB semantics (lifetime, dominance-aware) ────────────────────────────────
//
// REP-TARGET PB. For a set of weight W at R reps this is new only when W is
// STRICTLY greater than the heaviest weight from every prior set on that
// exercise with reps >= R. A higher-rep set therefore establishes all of the
// lower rep targets at that weight: a previous 25kg x 15 means a later
// 25kg x 14 is dominated, not new, and a previous 28kg x 15 means a later
// 27kg x 15 is not a PB. Equal weight is never new.
//
// (The pre-2026-08 engine keyed rep PBs on the EXACT rep count, so each rep
// count was an isolated bucket and a dominated performance could be published
// as a "new 14 rep target PB". That defect is what this module now fixes.)
//
// ALL-TIME HEAVIEST. A set whose weight is strictly greater than every prior
// weight ever lifted on that exercise, regardless of reps. Highest priority
// praise. It necessarily also satisfies the rep-target rule, so the two are
// emitted as one achievement (see praise.js dedupe) rather than two.
//
// E1RM PB. Strict improvement over the complete prior lifetime E1RM maximum
// for the exercise. RIR is excluded from the E1RM entirely (see e1rm.js).
//
// PB MATCH AT LOWER RIR. The ONLY place RIR participates. Emitted when a set
// exactly equals the standing PB (same exercise, weight and reps), is NOT a
// new rep-target PB, and both the standing PB and the current set carry a
// valid numeric RIR with the current one strictly lower. The stored RIR
// baseline moves down with each such event, so the same improvement can never
// be praised twice. RIR never leaks into any other calculation.
//
// All comparisons go through strictlyGreater/strictlyLess, which apply a
// relative epsilon: float noise (e.g. two mathematically equal E1RMs that
// differ by 1e-14) is absorbed, but genuine equality never passes as an
// improvement.
//
// Event derivation is a deterministic chronological walk over per-day
// summaries, so recomputing after a workout edit/delete reproduces exactly
// the events that the surviving data justifies (self-healing reconciliation).
// The bootstrap walk and the incremental append share ONE step function
// (applyDayToState) so the two paths cannot drift apart.

'use strict';

const { coachE1rm, E1RM_FORMULA_VERSION } = require('./e1rm');

// Relative epsilon. Absorbs representation noise without ever letting an
// exact tie count as an improvement.
const EPS_REL = 1e-9;

/** a > b, ignoring float representation noise. Equality is NEVER true. */
function strictlyGreater(a, b) {
  if (!Number.isFinite(a) || !Number.isFinite(b)) return false;
  return (a - b) > EPS_REL * Math.max(1, Math.abs(a), Math.abs(b));
}

/** a < b, ignoring float representation noise. Equality is NEVER true. */
function strictlyLess(a, b) {
  return strictlyGreater(b, a);
}

/** a == b within the same tolerance used by strictlyGreater/strictlyLess. */
function approxEqual(a, b) {
  if (!Number.isFinite(a) || !Number.isFinite(b)) return false;
  return !strictlyGreater(a, b) && !strictlyGreater(b, a);
}

/**
 * Heaviest weight ever recorded at reps >= minReps.
 *
 * repBest holds one entry per distinct rep count (the heaviest weight ever
 * lifted at exactly that many reps), so the maximum over the keys >= minReps
 * is exactly the maximum over all prior sets with reps >= minReps — an exact
 * answer from a bounded structure, no history scan.
 *
 * @returns {number} 0 when no prior set reached minReps.
 */
function bestWeightAtOrAboveReps(repBest, minReps) {
  let best = 0;
  for (const key of Object.keys(repBest || {})) {
    const reps = Number(key);
    if (!Number.isFinite(reps) || reps < minReps) continue;
    const entry = repBest[key];
    const w = toNum(entry && entry.weightKg);
    if (w > best) best = w;
  }
  return best;
}

/**
 * Extracts a compact per-exercise day summary from one workout document's
 * data. Returns a plain object:
 *   { [exerciseId]: {
 *       name,                            // last seen display name
 *       bestByReps:    { [reps]: weight },  // heaviest that day per exact rep count
 *       bestRirByReps: { [reps]: rir },     // LOWEST valid RIR logged at that
 *                                           // rep count's heaviest weight; the
 *                                           // key is absent when no set there
 *                                           // carried a numeric RIR
 *       bestWeight: number,              // heaviest weight that day, any reps
 *       bestWeightReps: number,          // most reps achieved at bestWeight
 *       bestE1rm: number,                // best no-RIR E1RM that day
 *       bestE1rmSet: { weight, reps },
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
      const repsInt = Math.round(reps);
      const repKey = String(repsInt);
      // RIR is read here for the lower-RIR PB-match achievement ONLY. It is
      // deliberately not passed to coachE1rm and takes no part in any weight
      // or E1RM comparison.
      const rir = rirOrNull(s.rir != null ? s.rir : s.actualRir);

      let entry = out[exerciseId];
      if (!entry) {
        entry = {
          name: strOr(ex.name, exerciseId),
          bestByReps: {},
          bestRirByReps: {},
          bestWeight: 0,
          bestWeightReps: 0,
          bestE1rm: 0,
          bestE1rmSet: null,
        };
        out[exerciseId] = entry;
      }

      const priorAtReps = entry.bestByReps[repKey];
      if (priorAtReps == null || strictlyGreater(weight, priorAtReps)) {
        // New heaviest at this rep count today → its RIR baseline restarts.
        entry.bestByReps[repKey] = weight;
        if (rir != null) entry.bestRirByReps[repKey] = rir;
        else delete entry.bestRirByReps[repKey];
      } else if (approxEqual(weight, priorAtReps) && rir != null) {
        const knownRir = entry.bestRirByReps[repKey];
        if (knownRir == null || strictlyLess(rir, knownRir)) {
          entry.bestRirByReps[repKey] = rir;
        }
      }

      if (strictlyGreater(weight, entry.bestWeight)) {
        entry.bestWeight = weight;
        entry.bestWeightReps = repsInt;
      } else if (approxEqual(weight, entry.bestWeight) && repsInt > entry.bestWeightReps) {
        entry.bestWeightReps = repsInt;
      }

      const e1 = coachE1rm(weight, repsInt);
      if (strictlyGreater(e1, entry.bestE1rm)) {
        entry.bestE1rm = e1;
        entry.bestE1rmSet = { weight, reps: repsInt };
      }
    }
  }
  return out;
}

/** Empty lifetime state for one exercise. */
function emptyState(exerciseId) {
  return {
    name: exerciseId,
    repBest: {},    // reps -> { weightKg, dateKey }
    repRir: {},     // reps -> { weightKg, rir, dateKey }  (RIR at the record weight)
    maxWeight: null, // { weightKg, reps, dateKey }
    e1rmBest: null,  // { e1rmKg, dateKey, weightKg, reps }
    dayCount: 0,
    latestDateKey: null,
  };
}

/**
 * THE single step function: folds one day into the lifetime state and returns
 * the events that day justifies.
 *
 * All comparisons use the state as it stood BEFORE this day, so several
 * improvements inside one day are judged against history rather than against
 * each other, and the result does not depend on rep-key iteration order.
 *
 * Callers MUST apply days in ascending dateKey order. Both the bulk bootstrap
 * walk and the incremental append use this function, so the two paths produce
 * identical summaries and identical events by construction.
 */
function applyDayToState(state, exerciseId, dateKey, day) {
  const events = [];
  if (!day) return events;
  if (day.name) state.name = day.name;

  const priorRepBest = state.repBest;
  const priorRepRir = state.repRir;
  const priorMaxWeight = state.maxWeight;

  const bestByReps = day.bestByReps || {};
  const bestRirByReps = day.bestRirByReps || {};
  const repKeys = Object.keys(bestByReps).sort((a, b) => Number(a) - Number(b));

  // ── 1. All-time heaviest weight (highest priority achievement) ────────────
  const dayBestWeight = toNum(day.bestWeight) || maxOfWeights(bestByReps);
  const dayBestWeightReps = toNum(day.bestWeightReps) || repsOfHeaviest(bestByReps, dayBestWeight);
  let maxWeightEvent = null;
  if (dayBestWeight > 0) {
    if (priorMaxWeight && strictlyGreater(dayBestWeight, priorMaxWeight.weightKg)) {
      maxWeightEvent = {
        id: `${dateKey}_${exerciseId}_maxweight`,
        type: 'maxWeightPB',
        dateKey,
        exerciseId,
        exerciseName: state.name,
        weightKg: dayBestWeight,
        reps: dayBestWeightReps,
        prevWeightKg: priorMaxWeight.weightKg,
        pctImprovement: (dayBestWeight - priorMaxWeight.weightKg) / priorMaxWeight.weightKg,
      };
      events.push(maxWeightEvent);
    }
  }

  // ── 2. Rep-target PBs (dominance-aware) ──────────────────────────────────
  const repPBReps = new Set();
  for (const repKey of repKeys) {
    const weight = toNum(bestByReps[repKey]);
    if (!(weight > 0)) continue;
    const reps = Number(repKey);
    // Heaviest prior weight at THIS rep target or any harder (higher-rep) one.
    const priorBest = bestWeightAtOrAboveReps(priorRepBest, reps);
    if (!(priorBest > 0)) continue; // no comparable history → baseline, no event
    if (!strictlyGreater(weight, priorBest)) continue; // equal or dominated
    repPBReps.add(repKey);
    events.push({
      id: `${dateKey}_${exerciseId}_rep${repKey}`,
      type: 'repPB',
      dateKey,
      exerciseId,
      exerciseName: state.name,
      reps,
      weightKg: weight,
      prevWeightKg: priorBest,
      pctImprovement: (weight - priorBest) / priorBest,
    });
  }

  // ── 3. PB match at strictly lower logged RIR (the only RIR consumer) ──────
  for (const repKey of repKeys) {
    if (repPBReps.has(repKey)) continue; // a genuine rep PB, not a match
    const weight = toNum(bestByReps[repKey]);
    if (!(weight > 0)) continue;
    const reps = Number(repKey);

    const priorAtReps = priorRepBest[repKey];
    if (!priorAtReps) continue;
    // Must equal the record at this exact rep count …
    if (!approxEqual(weight, toNum(priorAtReps.weightKg))) continue;
    // … and that record must still be the standing PB for this rep target
    // (nothing heavier at an equal-or-harder rep count).
    if (!approxEqual(weight, bestWeightAtOrAboveReps(priorRepBest, reps))) continue;

    const priorRirEntry = priorRepRir[repKey];
    if (!priorRirEntry || !approxEqual(toNum(priorRirEntry.weightKg), weight)) continue;
    const priorRir = rirOrNull(priorRirEntry.rir);
    const currentRir = rirOrNull(bestRirByReps[repKey]);
    if (priorRir == null || currentRir == null) continue;   // null never qualifies
    if (!strictlyLess(currentRir, priorRir)) continue;      // equal/higher never qualifies

    events.push({
      id: `${dateKey}_${exerciseId}_rirmatch${repKey}`,
      type: 'rirMatchPB',
      dateKey,
      exerciseId,
      exerciseName: state.name,
      reps,
      weightKg: weight,
      rir: currentRir,
      prevRir: priorRir,
      prevDateKey: priorRirEntry.dateKey || null,
    });
  }

  // ── 4. E1RM PB (strict, RIR excluded) ────────────────────────────────────
  const e1 = toNum(day.bestE1rm);
  if (e1 > 0 && day.bestE1rmSet) {
    if (state.e1rmBest && strictlyGreater(e1, state.e1rmBest.e1rmKg)) {
      events.push({
        id: `${dateKey}_${exerciseId}_e1rm`,
        type: 'e1rmPB',
        dateKey,
        exerciseId,
        exerciseName: state.name,
        e1rmKg: e1,
        prevE1rmKg: state.e1rmBest.e1rmKg,
        pctImprovement: (e1 - state.e1rmBest.e1rmKg) / state.e1rmBest.e1rmKg,
        weightKg: day.bestE1rmSet.weight,
        reps: day.bestE1rmSet.reps,
        formulaVersion: E1RM_FORMULA_VERSION,
      });
    }
  }

  // ── 5. Commit the day into the lifetime state ────────────────────────────
  const nextRepBest = { ...priorRepBest };
  const nextRepRir = { ...priorRepRir };
  for (const repKey of repKeys) {
    const weight = toNum(bestByReps[repKey]);
    if (!(weight > 0)) continue;
    const dayRir = rirOrNull(bestRirByReps[repKey]);
    const prior = nextRepBest[repKey];

    if (!prior || strictlyGreater(weight, toNum(prior.weightKg))) {
      nextRepBest[repKey] = { weightKg: weight, dateKey };
      // A heavier record restarts the RIR baseline for that rep count.
      if (dayRir != null) nextRepRir[repKey] = { weightKg: weight, rir: dayRir, dateKey };
      else delete nextRepRir[repKey];
    } else if (approxEqual(weight, toNum(prior.weightKg)) && dayRir != null) {
      const existing = nextRepRir[repKey];
      const existingRir = existing && approxEqual(toNum(existing.weightKg), weight)
        ? rirOrNull(existing.rir)
        : null;
      if (existingRir == null || strictlyLess(dayRir, existingRir)) {
        // Monotonically decreasing → the same improvement cannot re-fire.
        nextRepRir[repKey] = { weightKg: weight, rir: dayRir, dateKey };
      }
    }
  }
  state.repBest = nextRepBest;
  state.repRir = nextRepRir;

  if (dayBestWeight > 0) {
    if (!state.maxWeight || strictlyGreater(dayBestWeight, state.maxWeight.weightKg)) {
      state.maxWeight = {
        weightKg: dayBestWeight,
        reps: dayBestWeightReps,
        dateKey,
      };
    }
  }

  if (e1 > 0 && day.bestE1rmSet) {
    if (!state.e1rmBest || strictlyGreater(e1, state.e1rmBest.e1rmKg)) {
      state.e1rmBest = {
        e1rmKg: e1,
        dateKey,
        weightKg: day.bestE1rmSet.weight,
        reps: day.bestE1rmSet.reps,
      };
    }
  }

  state.dayCount += 1;
  state.latestDateKey = dateKey;
  return events;
}

/**
 * Derives the full PB event stream for ONE exercise from its per-day history
 * by folding applyDayToState over the days in chronological order.
 *
 * @param {string} exerciseId
 * @param {Object} history  { [dateKey]: day }
 * @returns {{ events, repBest, repRir, maxWeight, e1rmBest, name, dayCount, latestDateKey }}
 *
 * The first day that establishes a baseline emits no event for that stream.
 */
function deriveExerciseEvents(exerciseId, history) {
  const dateKeys = Object.keys(history || {}).sort(); // YYYY-MM-DD sorts chronologically
  const state = emptyState(exerciseId);
  const events = [];
  for (const dateKey of dateKeys) {
    const day = history[dateKey];
    if (!day) continue;
    events.push(...applyDayToState(state, exerciseId, dateKey, day));
  }
  return {
    events,
    repBest: state.repBest,
    repRir: state.repRir,
    maxWeight: state.maxWeight,
    e1rmBest: state.e1rmBest,
    name: state.name,
    dayCount: state.dayCount,
    latestDateKey: state.latestDateKey,
  };
}

function maxOfWeights(bestByReps) {
  let best = 0;
  for (const k of Object.keys(bestByReps || {})) {
    const w = toNum(bestByReps[k]);
    if (w > best) best = w;
  }
  return best;
}

function repsOfHeaviest(bestByReps, weight) {
  let reps = 0;
  for (const k of Object.keys(bestByReps || {})) {
    if (approxEqual(toNum(bestByReps[k]), weight)) {
      const r = Number(k);
      if (Number.isFinite(r) && r > reps) reps = r;
    }
  }
  return reps;
}

/** Valid numeric RIR or null. Negative values are treated as invalid. */
function rirOrNull(v) {
  if (v == null) return null;
  const n = typeof v === 'number' ? v : (typeof v === 'string' ? parseFloat(v) : NaN);
  if (!Number.isFinite(n) || n < 0) return null;
  return n;
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

module.exports = {
  summarizeWorkoutDay,
  deriveExerciseEvents,
  applyDayToState,
  emptyState,
  bestWeightAtOrAboveReps,
  strictlyGreater,
  strictlyLess,
  approxEqual,
  rirOrNull,
};
