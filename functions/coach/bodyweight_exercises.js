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
 * True for a bodyweight exercise, by catalogue id (case-folded, as the coach
 * streams are — production briefly wrote lowercased copies of catalogue ids)
 * or by display name.
 */
function isBodyweightExercise(rawId, rawName) {
  const id = typeof rawId === 'string' ? rawId.trim().toLowerCase() : '';
  if (id && ID_SET.has(id)) return true;
  const name = typeof rawName === 'string' ? rawName.trim().toLowerCase() : '';
  return !!name && NAME_SET.has(name);
}

module.exports = {
  BODYWEIGHT_EXERCISE_IDS,
  BODYWEIGHT_EXERCISE_NAMES,
  isBodyweightExercise,
};
