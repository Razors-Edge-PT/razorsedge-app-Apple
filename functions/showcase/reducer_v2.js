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
// ── Day contributions ───────────────────────────────────────────────────────
// One per (category, exercise, date) — two exercises of the same category
// trained on the same day are two contributions and never overwrite each
// other. Same shape as V1 plus `category`.
//
// ── RE Points ───────────────────────────────────────────────────────────────
// Scored from the exercise's lifetime BEST E1RM record — the same source
// performance the profile displays — with the bodyweight recorded on or
// before THAT record's date (showcase/bodyweight.pickBodyweightAsOf):
//
//   ordinary exercise        E1RM of the stored load (never doubled)
//   bodyweight-loaded        E1RM of the combined system load (bodyweight +
//                            added), i.e. the record's `totalE1rm`, at the
//                            bodyweight the record was normalised with
//
// then × factor × coefficient (re_points.js). RIR never takes part. No
// bodyweight → null points ("unavailable"), never 0.
//
// ── Category default ────────────────────────────────────────────────────────
// selectDefaultExerciseId(): highest valid points; ties go to catalogue order;
// with no valid points, the first exercise (catalogue order) with a record;
// otherwise the category's primary exercise.

'use strict';

const {
  RE_CATEGORIES,
  RE_EXERCISES,
  reExerciseBySlot,
  reExercisesOfCategory,
  matchReExercise,
} = require('./re_catalog');
const {
  summarizeWorkoutDayWith,
  resummarizeDay,
  foldSlot,
  isEmptySnapshot,
  greater,
} = require('./reducer');
const { SHOWCASE_FORMULA_VERSION } = require('./e1rm_spec');
const { isBodyweightSlot, recordedBodyweight } = require('./bodyweight');
const { RE_POINTS_FORMULA_VERSION, rePoints } = require('./re_points');

/** Schema of users_public/{uid}.profileShowcaseV2. */
const PROFILE_SHOWCASE_V2_SCHEMA = 'profileShowcaseV2';

/** Every RE slot, in catalogue order. */
const RE_SLOT_ORDER = RE_EXERCISES.map((e) => e.slot);

/**
 * Reduces one workout document to at most one contribution per RE exercise.
 * `options.bodyweight` as in reducer.summarizeWorkoutDay.
 */
function summarizeWorkoutDayV2(dateKey, workoutData, options) {
  const out = summarizeWorkoutDayWith(
    dateKey,
    workoutData,
    options,
    matchReExercise,
    reExerciseBySlot,
  );
  for (const slot of Object.keys(out)) out[slot].category = reExerciseBySlot(slot).category;
  return out;
}

/** A stored V2 day re-ranked at [bodyweight] (bodyweight-loaded only). */
function resummarizeDayV2(day, bodyweight) {
  if (!isBodyweightSlot(day.slot)) return day;
  return Object.assign(resummarizeDay(day, bodyweight), { category: day.category });
}

/**
 * RE Points for an exercise's best-E1RM [record].
 *
 * [bodyweight] — `{ weightKg, dateKey }` recorded on or before the record's
 * date — is used for an ordinary exercise. A bodyweight-loaded record carries
 * the bodyweight it was normalised with, and that same one is used, so the
 * points always agree with the E1RM shown.
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

/** The published entry for one exercise. */
function exerciseEntry(def, e1rm, heaviest, points) {
  const out = {
    slot: def.slot,
    exerciseId: def.exerciseId,
    displayName: def.displayName,
    factor: def.factor,
    rePoints: typeof points === 'number' && Number.isFinite(points) ? points : null,
  };
  if (e1rm) out.e1rm = e1rm;
  if (heaviest) out.heaviest = heaviest;
  return out;
}

/** Folds one exercise's days into its records, or null when it has none. */
function foldExerciseV2(def, days) {
  const folded = foldSlot(def.slot, days);
  if (isEmptySnapshot(folded)) return null;
  return folded;
}

function validPoints(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

function hasRecord(entry) {
  return !!(entry && (entry.e1rm || entry.heaviest));
}

/**
 * The exercise a category shows by default. [exercisesById] maps catalogue
 * id → published entry (missing exercises are simply absent).
 */
function selectDefaultExerciseId(categoryKey, exercisesById) {
  const defs = reExercisesOfCategory(categoryKey);
  if (defs.length === 0) return null;
  const map = exercisesById || {};
  let best = null;
  for (const def of defs) {
    const e = map[def.exerciseId];
    if (!hasRecord(e) || !validPoints(e.rePoints)) continue;
    // Strictly greater: an equal score never displaces an earlier exercise.
    if (!best || greater(e.rePoints, best.rePoints)) best = e;
  }
  if (best) return best.exerciseId;
  for (const def of defs) {
    if (hasRecord(map[def.exerciseId])) return def.exerciseId;
  }
  return defs[0].exerciseId;
}

/**
 * The presentation-ready V2 snapshot from per-slot exercise entries.
 * Categories and exercises with no record are omitted.
 */
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

/** True when [snapshot] was produced by this schema and both formulas. */
function isCurrentSnapshotV2(snapshot) {
  return !!(
    snapshot &&
    snapshot.schema === PROFILE_SHOWCASE_V2_SCHEMA &&
    snapshot.e1rmFormulaVersion === SHOWCASE_FORMULA_VERSION &&
    snapshot.rePointsFormulaVersion === RE_POINTS_FORMULA_VERSION &&
    snapshot.categories &&
    typeof snapshot.categories === 'object'
  );
}

/**
 * Whole-history V2 rebuild, pure. `options.bodyweightByDate` as in
 * reducer.buildShowcase; `options.sex` is the scoring sex (re_points.Sex).
 */
function buildShowcaseV2(workoutsByDate, options) {
  const bodyweightByDate = (options && options.bodyweightByDate) || {};
  const sex = options && options.sex;
  const all = [];
  for (const dateKey of Object.keys(workoutsByDate).sort()) {
    const day = summarizeWorkoutDayV2(dateKey, workoutsByDate[dateKey], {
      bodyweight: bodyweightByDate[dateKey] || null,
    });
    for (const slot of Object.keys(day)) all.push(day[slot]);
  }
  const entries = {};
  for (const def of RE_EXERCISES) {
    const folded = foldExerciseV2(def, all);
    if (!folded) continue;
    const bw = folded.e1rm ? bodyweightByDate[folded.e1rm.dateKey] || null : null;
    entries[def.slot] = exerciseEntry(
      def,
      folded.e1rm,
      folded.heaviest,
      scoreRecord(def, folded.e1rm, bw, sex),
    );
  }
  return snapshotV2FromEntries(entries);
}

/** Every fingerprint standing as a live record in a V2 snapshot. */
function liveFingerprintsV2(snapshot) {
  const out = new Set();
  const entries = entriesOfSnapshotV2(snapshot);
  for (const slot of Object.keys(entries)) {
    const e = entries[slot];
    if (e.e1rm) out.add(e.e1rm.fingerprint);
    if (e.heaviest) out.add(e.heaviest.fingerprint);
  }
  return out;
}

module.exports = {
  PROFILE_SHOWCASE_V2_SCHEMA,
  RE_SLOT_ORDER,
  summarizeWorkoutDayV2,
  resummarizeDayV2,
  scoreRecord,
  exerciseEntry,
  foldExerciseV2,
  selectDefaultExerciseId,
  snapshotV2FromEntries,
  entriesOfSnapshotV2,
  isCurrentSnapshotV2,
  buildShowcaseV2,
  liveFingerprintsV2,
};
