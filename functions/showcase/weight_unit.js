// The per-exercise display unit, `exerciseSettings[exerciseId].weightUnit`.
//
// Every stored and scored load is CANONICAL KILOGRAMS; the unit only decides
// how an exercise's loads are shown and entered in the app. The server reads
// it for exactly one purpose: publishing the owner's choice per exercise to
// users_public/{uid}.exerciseWeightUnits so a friend's view of the profile
// uses the owner's unit. Nothing here converts or rescales a stored number.
//
// Pinned mirror of lib/units/weight_unit.dart (ExerciseWeightUnit.parse).

'use strict';

const WEIGHT_UNIT_FIELD = 'weightUnit';
const WEIGHT_UNITS = Object.freeze(['kg', 'lb']);

/** 1 lb = 0.45359237 kg exactly (international avoirdupois pound). */
const KG_PER_LB = 0.45359237;
const LB_PER_KG = 2.2046226218487757;

/**
 * 'kg' | 'lb' for a valid stored value; [fallback] (default 'kg') for a
 * missing, null, malformed or legacy one.
 */
function parseWeightUnit(raw, fallback) {
  const fb = fallback === undefined ? 'kg' : fallback;
  if (typeof raw !== 'string') return fb;
  const v = raw.trim().toLowerCase();
  return WEIGHT_UNITS.includes(v) ? v : fb;
}

module.exports = { WEIGHT_UNIT_FIELD, WEIGHT_UNITS, KG_PER_LB, LB_PER_KG, parseWeightUnit };
