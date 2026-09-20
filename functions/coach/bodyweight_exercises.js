// Exercises lifted as the athlete's bodyweight plus an added load.
//
// Pinned mirror of PeriodizationModelUtils._bwById / _bwByName in
// lib/periodization_model_utils.dart — test/bodyweight_exercises_parity_test
// .dart reads the two lists below and holds them to the app's.
//
// Their stored loads are not one basis (see showcase/bodyweight.js): the
// legacy workout screen stored the TOTAL, WES2 stores the ADDED load. The coach
// PB engine therefore compares their sets on the total load.

'use strict';

// ids:start
const BODYWEIGHT_EXERCISE_IDS = Object.freeze([
  'XM9026peNIu0R8qh7UqY', // Chin-Up
  'RFyjAjezFs8Rf7CQoaXz', // Pull-Up
  'KPewxxYYrhsOp84lIQr5', // Suspended High Row
  'YrwqLg6c9CJLu7yfLYn0', // Alternating Plank
  'BpO7e9KsDJsvwhfo09uU', // Hanging Knee Raise
  'P88Vj5pBydqmiEzFowag', // Hanging Straight Leg Raise
  '8CIXN12uS2xwF4JzVLq3', // Long Lever Plank
  'xU7MNEvnaoSwz5jy3uHw', // Plank
  '63ryIPxgXVPX7jLtAecC', // Pull-Up, Wide Arm
  'jSC34DLH5C7t9jH0pWfo', // Push Up Off Bench
  'pJQaGJlTAOoyZ8TyEmrY', // Push Up, Banded
  '0P4ECDHtfF7oKExmNhbN', // Push Up, Decline
  'Da2xWZqbeCsbGCwdbwbs', // Push Up, Deficit
  'EFbQl9i9NdYi13F3DqHr', // Push Up, Suspended
  '0YNV3P4D7QaN6xLI9lo8', // Push Up, Weighted
  '0d1HmQpwesdOESqoQHBq', // Russian Twist
  'Ei4x9i5mirIUdMxWKZCk', // Side Plank
  'iPaRtXsLXcXHQg5vmVA0', // Suspended Fly
  'oiQ7EJsGLgJG3Sx9m2sB', // Suspended High Row, Unilateral
  'PXqhBA8ib7FWAcPjDlES', // Suspended Leg Curl
  '7gc2YEj9ZQe6A0kr5NcX', // Suspended Leg Curl, Unilateral
  'mJKwE9Fc2opMiiy7yUFt', // Suspended Reverse Fly
  '9Oovma2yszjmSm420awp', // Suspended Triceps Extension
  'jRDb5LbN9e7PyiQMQcPn', // Suspended Triceps Extension, Unilateral
  'FtayDmR5BVnGS1FXlXLL', // Triceps Dip
  'lGaQiv5BwE1H5eJSkesj', // Weighted Long Lever Plank
  'DTkkN5pi05RWQyNYhizQ', // Weighted Plank
  'wrCwLDvwMYAgQtoiaJTh', // Weighted Push Up, Deficit
]);
// ids:end

// names:start
const BODYWEIGHT_EXERCISE_NAMES = Object.freeze([
  'chin-up',
  'pull-up',
  'suspended high row',
  'alternating plank',
  'hanging knee raise',
  'hanging straight leg raise',
  'long lever plank',
  'plank',
  'pull-up, wide arm',
  'push up off bench',
  'push up, banded',
  'push up, decline',
  'push up, deficit',
  'push up, suspended',
  'push up, weighted',
  'russian twist',
  'side plank',
  'suspended fly',
  'suspended high row, unilateral',
  'suspended leg curl',
  'suspended leg curl, unilateral',
  'suspended reverse fly',
  'suspended triceps extension',
  'suspended triceps extension, unilateral',
  'triceps dip',
  'weighted long lever plank',
  'weighted plank',
  'weighted push up, deficit',
]);
// names:end

const ID_SET = new Set(BODYWEIGHT_EXERCISE_IDS.map((s) => s.toLowerCase()));
const NAME_SET = new Set(BODYWEIGHT_EXERCISE_NAMES);

/**
 * The canonical catalogue `type`, exactly as the app's Add Exercise dialog
 * offers it and ExerciseCatalog.addExercise stores it on
 * `/exercises/{id}` and `/users/{uid}/customExercises/{id}`.
 *
 * Pinned mirror of kBodyweightExerciseType in lib/exercise_type.dart —
 * test/bodyweight_exercises_parity_test.dart reads the marked line below and
 * holds it to the app's constant.
 */
// type:start
const BODYWEIGHT_EXERCISE_TYPE = 'Body Weight';
// type:end

const BODYWEIGHT_TYPE_FOLDED = BODYWEIGHT_EXERCISE_TYPE.toLowerCase();

/**
 * True when a catalogue `type` is the bodyweight type — trimmed and
 * case-insensitive, because the field is free-form text in Firestore.
 *
 * Nothing else about the exercise is consulted: an exercise's NAME, CATEGORY
 * and BODY PARTS never imply bodyweight status.
 */
function isBodyweightType(rawType) {
  if (typeof rawType !== 'string') return false;
  const t = rawType.trim();
  return !!t && t.toLowerCase() === BODYWEIGHT_TYPE_FOLDED;
}

/**
 * True for a bodyweight exercise, by catalogue `type` (the canonical,
 * data-driven rule), by catalogue id (case-folded, as the coach streams are —
 * production briefly wrote lowercased copies of catalogue ids), or by display
 * name.
 *
 * [rawType] is the exercise's CATALOGUE type: the snapshot WES2 now writes
 * onto each workout row, or the value resolved from the catalogue for a
 * historical row that predates the snapshot (see exercise_types.js). The id
 * and name lists remain as backward-compatible fallbacks, so an exercise with
 * no type is classified exactly as it always was.
 */
function isBodyweightExercise(rawId, rawName, rawType) {
  if (isBodyweightType(rawType)) return true;
  const id = typeof rawId === 'string' ? rawId.trim().toLowerCase() : '';
  if (id && ID_SET.has(id)) return true;
  const name = typeof rawName === 'string' ? rawName.trim().toLowerCase() : '';
  return !!name && NAME_SET.has(name);
}

/**
 * The bodyweight classification of one stored workout row, given
 * `typesById` — a Map/object of exerciseId → catalogue type for rows that do
 * not carry their own `type` snapshot.
 *
 * Ids are looked up BOTH as stored and case-folded, matching the folding the
 * PB streams apply.
 */
function rowIsBodyweight(ex, typesById) {
  if (!ex || typeof ex !== 'object') return false;
  const rawId = typeof ex.exerciseId === 'string' && ex.exerciseId
    ? ex.exerciseId
    : (typeof ex.id === 'string' ? ex.id : '');
  let type = typeof ex.type === 'string' && ex.type.trim() ? ex.type : null;
  if (!type && typesById) {
    const get = (k) => (typeof typesById.get === 'function'
      ? typesById.get(k)
      : typesById[k]);
    const id = String(rawId || '').trim();
    type = get(id) || get(id.toLowerCase()) || null;
  }
  return isBodyweightExercise(rawId, ex.name, type);
}

/**
 * Whether a set's RAW STORED `weight` represents a performed load.
 *
 * Pinned mirror of isStoredWeightPerformed in lib/exercise_type.dart. WES2
 * stores exactly what the athlete typed, so on a bodyweight exercise a stored
 * `0` means "0 kg ADDED" — a real set at the athlete's own bodyweight — while
 * on every other exercise it still means "nothing logged". A NEGATIVE weight
 * is invalid everywhere, and so is a non-finite one.
 *
 * This is about the RAW stored field only: a normalised TOTAL load keeps its
 * existing positive requirement.
 */
function isStoredWeightPerformed(weightKg, isBodyweight) {
  if (typeof weightKg !== 'number' || !Number.isFinite(weightKg)) return false;
  if (weightKg < 0) return false;
  return !!isBodyweight || weightKg > 0;
}

/**
 * Whether one raw stored set counts as PERFORMED: a valid stored weight and
 * strictly positive reps. The ONE rule behind coach adherence, the coverage
 * counts and the PB engine's set participation.
 */
function isRawSetPerformed(weightKg, reps, isBodyweight) {
  if (!isStoredWeightPerformed(weightKg, isBodyweight)) return false;
  return typeof reps === 'number' && Number.isFinite(reps) && reps > 0;
}

module.exports = {
  BODYWEIGHT_EXERCISE_IDS,
  BODYWEIGHT_EXERCISE_NAMES,
  BODYWEIGHT_EXERCISE_TYPE,
  isBodyweightType,
  isBodyweightExercise,
  rowIsBodyweight,
  isStoredWeightPerformed,
  isRawSetPerformed,
};
