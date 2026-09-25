// Pure reducer for the V2 profile showcase: five CATEGORIES, every approved
// exercise inside each with its own lifetime records, and RE Points per
// exercise. No Firebase imports.
//
// ── Reuse, not a second engine ──────────────────────────────────────────────
// Each RE catalogue exercise is run through the SAME machinery as the V1 Big
// Five (reducer.js): set extraction, within-day and across-day ranking, the
// bodyweight normalisation of bodyweight-loaded lifts, record provenance and
// fingerprints — keyed by the exercise's stable `slot` (re_catalog.js). The
// five V1 exercises keep their V1 slot keys, so their V2 records, and the
// fingerprints proof videos are attached to, are identical to V1's.
//
// ── Three independent records per exercise ──────────────────────────────────
//   e1rm      the lifetime Best E1RM         (V1 ranking, unchanged)
//   heaviest  the lifetime Heaviest load      (V1 ranking, unchanged)
//   points    the lifetime Best RE Points     (THIS set's own RE Points)
// Best RE Points is NOT derived from Best E1RM. Every eligible set is scored
// through the approved path — recordOf (bodyweight-loaded combined load for
// the Chin-Up and the Triceps Dip) then scoreRecord (E1RM × factor × sex /
// bodyweight coefficient at the bodyweight recorded on or before that set's
// date) — and the highest-scoring set wins. A lower E1RM lifted at a lower
// bodyweight, or a Chin-Up whose added-load E1RM is not the best, can
// therefore hold the points record while another set holds Best E1RM. Each
// record carries its own date, set identity and fingerprint, so a proof video
// is only ever shown against the set it shows.
//
// ── Day contributions (aggregation version 2) ───────────────────────────────
// One per (category, exercise, date): the V1 shape (bestE1rm / heaviest
// candidates) plus, for EVERY exercise, the day's valid sets, the bodyweight
// recorded on or before the date, and `bestPoints` — that day's
// highest-scoring set (absent when no bodyweight is recorded, so no set can
// score). Keeping the sets makes a weigh-in change re-scorable without
// re-reading workouts. RIR never takes part.
//
// ── Versions ────────────────────────────────────────────────────────────────
// e1rmFormulaVersion / rePointsFormulaVersion change when the ARITHMETIC or
// the factor table changes. SHOWCASE_V2_AGGREGATION_VERSION changes when the
// SELECTION or the stored shape changes — version 1 took points from the Best
// E1RM record; version 2 selects the Best RE Points set independently. Any
// snapshot or state stamped with another aggregation version is stale.

'use strict';

const {
  RE_CATEGORIES,
  RE_EXERCISES,
  reExerciseBySlot,
  reExercisesOfCategory,
  matchReExercise,
} = require('./re_catalog');
const {
  extractSetsWith,
  casingForDay,
  candidateSet,
  summarizeSlotDay,
  foldSlot,
  recordOf,
  isEmptySnapshot,
  greater,
} = require('./reducer');
const { SHOWCASE_FORMULA_VERSION } = require('./e1rm_spec');
const { isBodyweightSlot, recordedBodyweight } = require('./bodyweight');
const { RE_POINTS_FORMULA_VERSION, Sex, rePoints } = require('./re_points');

/** Schema of users_public/{uid}.profileShowcaseV2. */
const PROFILE_SHOWCASE_V2_SCHEMA = 'profileShowcaseV2';

/**
 * Version of the V2 SELECTION semantics and stored shape (not the formula).
 *   1 — points taken from the Best E1RM record (retired)
 *   2 — Best RE Points selected independently, per set
 */
const SHOWCASE_V2_AGGREGATION_VERSION = 2;

/** Every RE slot, in catalogue order. */
const RE_SLOT_ORDER = RE_EXERCISES.map((e) => e.slot);

/**
 * RE Points of one record. [bodyweight] — `{ weightKg, dateKey }` recorded on
 * or before the record's date — is used for an ordinary exercise; a
 * bodyweight-loaded record carries the bodyweight it was normalised with, and
 * that same one is used, so its points always agree with its combined load.
 */
function scoreRecord(def, record, bodyweight, sex) {
  if (!def || !record) return null;
  if (def.bodyweightLoaded) {
    return rePoints({
      e1rmKg: typeof record.totalE1rm === 'number' ? record.totalE1rm : null,
      factor: def.factor,
      bodyweightKg: typeof record.bodyweightKg === 'number' ? record.bodyweightKg : null,
      sex,
    });
  }
  const bw = recordedBodyweight(bodyweight);
  return rePoints({
    e1rmKg: record.e1rm,
    factor: def.factor,
    bodyweightKg: bw ? bw.weightKg : null,
    sex,
  });
}

/**
 * The points record for candidate [set] of day contribution [day]: the
 * ordinary published record plus its `rePoints` (null when unscorable).
 */
function pointsRecordOf(def, day, set, sex) {
  const record = recordOf(def.slot, day, set);
  record.rePoints = scoreRecord(def, record, day.bodyweight, sex);
  return record;
}

/** Deterministic ordering of two scored candidates of ONE day. */
function betterPointsWithinDay(a, b) {
  if (!b) return true;
  if (greater(a.rePoints, b.rePoints)) return true;
  if (greater(b.rePoints, a.rePoints)) return false;
  if (a.weight !== b.weight) return a.weight > b.weight;
  return a.setKey < b.setKey;
}

/**
 * The day's highest-scoring set, scored one by one through the approved path,
 * or null when no set scores (no bodyweight recorded).
 */
function bestPointsSetOfDay(def, day, sets, sex) {
  let best = null;
  let bestSet = null;
  for (const set of sets || []) {
    const rec = pointsRecordOf(def, day, candidateSet(set), sex);
    if (typeof rec.rePoints !== 'number') continue;
    if (betterPointsWithinDay(rec, best)) {
      best = rec;
      bestSet = set;
    }
  }
  return bestSet ? candidateSet(bestSet) : null;
}

/**
 * One exercise's V2 day contribution from that day's valid [sets].
 * options: { bodyweight, sex }.
 */
function summarizeExerciseDayV2(def, dateKey, exerciseId, sets, options) {
  const bw = recordedBodyweight(options && options.bodyweight);
  const sex = (options && options.sex) || Sex.MALE;
  const day = summarizeSlotDay(def.slot, dateKey, exerciseId, sets, bw);
  day.category = def.category;
  day.sets = sets.map(candidateSet);
  day.bodyweight = bw;
  const best = bestPointsSetOfDay(def, day, sets, sex);
  if (best) day.bestPoints = best;
  else delete day.bestPoints;
  return day;
}

/**
 * Reduces one workout document to at most one contribution per RE exercise.
 * options: { bodyweight: { weightKg, dateKey } | null, sex }.
 */
function summarizeWorkoutDayV2(dateKey, workoutData, options) {
  const setsBySlot = extractSetsWith(workoutData, matchReExercise);
  const casing = casingForDay(workoutData, matchReExercise);
  const out = {};
  for (const slot of Object.keys(setsBySlot)) {
    const sets = setsBySlot[slot];
    if (!sets.length) continue;
    const def = reExerciseBySlot(slot);
    out[slot] = summarizeExerciseDayV2(def, dateKey, casing[slot] || def.exerciseId, sets, options);
  }
  return out;
}

/**
 * A stored V2 day re-summarised at [bodyweight] (a weigh-in changed it). Uses
 * the day's stored sets; a day stored without them (aggregation version 1)
 * falls back to its candidates, which the rebuild then replaces.
 */
function resummarizeDayV2(day, bodyweight, sex) {
  const def = reExerciseBySlot(day.slot);
  let sets = Array.isArray(day.sets) && day.sets.length ? day.sets : null;
  if (!sets) {
    sets = [day.bestE1rm];
    if (day.heaviest && day.heaviest.setKey !== day.bestE1rm.setKey) sets.push(day.heaviest);
  }
  return summarizeExerciseDayV2(def, day.dateKey, day.exerciseId, sets.map(candidateSet), {
    bodyweight,
    sex,
  });
}

/** Across days: higher points; equal → the EARLIER date, then set key. */
function betterPointsAcrossDays(a, b) {
  if (!b) return true;
  if (greater(a.rePoints, b.rePoints)) return true;
  if (greater(b.rePoints, a.rePoints)) return false;
  if (a.dateKey !== b.dateKey) return a.dateKey < b.dateKey;
  return a.setKey < b.setKey;
}

/** The lifetime Best RE Points record of [def] over [days], or null. */
function foldPoints(def, days, sex) {
  let best = null;
  for (const d of days) {
    if (!d || d.slot !== def.slot || !d.bestPoints) continue;
    const rec = pointsRecordOf(def, d, d.bestPoints, sex);
    if (typeof rec.rePoints !== 'number') continue;
    if (betterPointsAcrossDays(rec, best)) best = rec;
  }
  return best;
}

/** The published entry for one exercise. */
function exerciseEntry(def, e1rm, heaviest, points) {
  const out = {
    slot: def.slot,
    exerciseId: def.exerciseId,
    displayName: def.displayName,
    factor: def.factor,
    rePoints: points && typeof points.rePoints === 'number' ? points.rePoints : null,
  };
  if (e1rm) out.e1rm = e1rm;
  if (heaviest) out.heaviest = heaviest;
  if (points && typeof points.rePoints === 'number') out.points = points;
  return out;
}

/**
 * Folds one exercise's days into its three records, or null when it has
 * none. Returns { e1rm, heaviest, points }.
 */
function foldExerciseV2(def, days, sex) {
  const folded = foldSlot(def.slot, days);
  if (isEmptySnapshot(folded)) return null;
  return { e1rm: folded.e1rm, heaviest: folded.heaviest, points: foldPoints(def, days, sex || Sex.MALE) };
}

function validPoints(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

function hasRecord(entry) {
  return !!(entry && (entry.e1rm || entry.heaviest));
}

/**
 * The exercise a category shows by default: the highest lifetime Best RE
 * Points; equal scores keep catalogue order; with no valid points the first
 * exercise (catalogue order) with a record; otherwise the primary exercise.
 */
function selectDefaultExerciseId(categoryKey, exercisesById) {
  const defs = reExercisesOfCategory(categoryKey);
  if (defs.length === 0) return null;
  const map = exercisesById || {};
  let best = null;
  for (const def of defs) {
    const e = map[def.exerciseId];
    if (!hasRecord(e) || !validPoints(e.rePoints)) continue;
    if (!best || greater(e.rePoints, best.rePoints)) best = e;
  }
  if (best) return best.exerciseId;
  for (const def of defs) {
    if (hasRecord(map[def.exerciseId])) return def.exerciseId;
  }
  return defs[0].exerciseId;
}

/** The presentation-ready V2 snapshot from per-slot exercise entries. */
function snapshotV2FromEntries(entriesBySlot) {
  const categories = {};
  for (const cat of RE_CATEGORIES) {
    const exercises = {};
    for (const def of reExercisesOfCategory(cat.key)) {
      const e = entriesBySlot[def.slot];
      if (hasRecord(e)) exercises[def.exerciseId] = e;
    }
    if (Object.keys(exercises).length === 0) continue;
    categories[cat.key] = {
      bestExerciseId: selectDefaultExerciseId(cat.key, exercises),
      exercises,
    };
  }
  return {
    schema: PROFILE_SHOWCASE_V2_SCHEMA,
    e1rmFormulaVersion: SHOWCASE_FORMULA_VERSION,
    rePointsFormulaVersion: RE_POINTS_FORMULA_VERSION,
    aggregationVersion: SHOWCASE_V2_AGGREGATION_VERSION,
    categories,
  };
}

/** Per-slot exercise entries of a published V2 snapshot. */
function entriesOfSnapshotV2(snapshot) {
  const out = {};
  const cats = (snapshot && snapshot.categories) || {};
  for (const key of Object.keys(cats)) {
    const exercises = (cats[key] && cats[key].exercises) || {};
    for (const id of Object.keys(exercises)) {
      const e = exercises[id];
      const def = e && reExerciseBySlot(e.slot);
      if (def && def.exerciseId === id) out[def.slot] = e;
    }
  }
  return out;
}

/** True when [snapshot] was produced by this schema, formulas and aggregation. */
function isCurrentSnapshotV2(snapshot) {
  return !!(
    snapshot &&
    snapshot.schema === PROFILE_SHOWCASE_V2_SCHEMA &&
    snapshot.e1rmFormulaVersion === SHOWCASE_FORMULA_VERSION &&
    snapshot.rePointsFormulaVersion === RE_POINTS_FORMULA_VERSION &&
    snapshot.aggregationVersion === SHOWCASE_V2_AGGREGATION_VERSION &&
    snapshot.categories &&
    typeof snapshot.categories === 'object'
  );
}

/** True when a stored day contribution has the current (version 2) shape. */
function isCurrentDayV2(day) {
  return !!(day && Array.isArray(day.sets) && 'bodyweight' in day);
}

/**
 * Entries for every exercise from a full set of day contributions — the one
 * fold every path (trigger, rebuild, backfill, tests) shares.
 */
function entriesFromDays(allDays, sex) {
  const entries = {};
  for (const def of RE_EXERCISES) {
    const folded = foldExerciseV2(def, allDays, sex);
    if (folded) entries[def.slot] = exerciseEntry(def, folded.e1rm, folded.heaviest, folded.points);
  }
  return entries;
}

/**
 * Whole-history V2 rebuild, pure. `options.bodyweightByDate`:
 * { 'YYYY-MM-DD': { weightKg, dateKey } | null }; `options.sex`: re_points.Sex.
 */
function buildShowcaseV2(workoutsByDate, options) {
  const bodyweightByDate = (options && options.bodyweightByDate) || {};
  const sex = (options && options.sex) || Sex.MALE;
  const all = [];
  for (const dateKey of Object.keys(workoutsByDate).sort()) {
    const day = summarizeWorkoutDayV2(dateKey, workoutsByDate[dateKey], {
      bodyweight: bodyweightByDate[dateKey] || null,
      sex,
    });
    for (const slot of Object.keys(day)) all.push(day[slot]);
  }
  return snapshotV2FromEntries(entriesFromDays(all, sex));
}

/** Every fingerprint standing as a live record in a V2 snapshot. */
function liveFingerprintsV2(snapshot) {
  const out = new Set();
  const entries = entriesOfSnapshotV2(snapshot);
  for (const slot of Object.keys(entries)) {
    const e = entries[slot];
    for (const r of [e.e1rm, e.heaviest, e.points]) if (r && r.fingerprint) out.add(r.fingerprint);
  }
  return out;
}

module.exports = {
  PROFILE_SHOWCASE_V2_SCHEMA,
  SHOWCASE_V2_AGGREGATION_VERSION,
  RE_SLOT_ORDER,
  summarizeWorkoutDayV2,
  summarizeExerciseDayV2,
  resummarizeDayV2,
  scoreRecord,
  pointsRecordOf,
  bestPointsSetOfDay,
  foldPoints,
  exerciseEntry,
  foldExerciseV2,
  entriesFromDays,
  selectDefaultExerciseId,
  snapshotV2FromEntries,
  entriesOfSnapshotV2,
  isCurrentSnapshotV2,
  isCurrentDayV2,
  buildShowcaseV2,
  liveFingerprintsV2,
  isBodyweightSlot,
};
