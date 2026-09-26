// RE Points for ONE exercise performance.
//
//   RE Points = E1RM (kg) × exercise weighting factor × sex/bodyweight coefficient
//
// The coefficient is a byte-for-byte port of reCoefficient() in
// lib/formula.dart (the rolling RE / GoodLift calculation); both suites assert
// the vectors in functions/test/fixtures/re_catalog_parity.json.
//
// Sex handling is the existing production rule (lib/stats_snapshot.dart): the
// `sex` field of users/{uid}; 'F' is scored female, anything else — 'M', 'N'
// or absent — male.
//
// Pure module: no Firebase.

'use strict';

/**
 * Version of the RE Points arithmetic AND the factor table. Bump when either
 * changes, so every stored V2 snapshot is rebuilt rather than mixing values.
 *   1 — first release (DB overhead press 2.61, lat pull down 0.85).
 *   2 — Flat Bench Dumbbell Press 2.35 → 2.11, Triceps Dip 0.73 → 0.63.
 */
const RE_POINTS_FORMULA_VERSION = 2;

const Sex = { MALE: 'male', FEMALE: 'female' };

/** users/{uid}.sex → the sex the coefficient is evaluated for. */
function scoringSexOf(raw) {
  return typeof raw === 'string' && raw.trim().toUpperCase() === 'F' ? Sex.FEMALE : Sex.MALE;
}

const MEN_DEN = [
  -216.0475144,
  16.2606339,
  -0.002388645,
  -0.00113732,
  0.00000701863,
  -0.00000001291,
];
const WOMEN_DEN = [
  594.31747775582,
  -27.23842536447,
  0.82112226871,
  -0.00930733913,
  0.00004731582,
  -0.00000009054,
];

function horner(coeffs, x) {
  let acc = 0;
  for (let i = coeffs.length - 1; i >= 0; i--) acc = acc * x + coeffs[i];
  return acc;
}

/**
 * The sex/bodyweight coefficient, or null when it cannot be evaluated
 * (no positive bodyweight, or a degenerate denominator).
 */
function reCoefficient(sex, bodyweightKg) {
  if (typeof bodyweightKg !== 'number' || !Number.isFinite(bodyweightKg) || bodyweightKg <= 0) {
    return null;
  }
  const female = sex === Sex.FEMALE;
  const denom = horner(female ? WOMEN_DEN : MEN_DEN, bodyweightKg);
  if (!Number.isFinite(denom) || denom === 0) return null;
  const c = (500.0 * (female ? 0.9454 : 0.9725)) / denom;
  return Number.isFinite(c) && c > 0 ? c : null;
}

/** Four-decimal storage rounding — the convention lib/formula.dart uses. */
function round4(v) {
  return Number(v.toFixed(4));
}

/**
 * RE Points for an E1RM, or null when they cannot be known. Null is NOT zero:
 * a missing bodyweight means "unavailable", never "scored nothing".
 */
function rePoints({ e1rmKg, factor, bodyweightKg, sex }) {
  if (typeof e1rmKg !== 'number' || !Number.isFinite(e1rmKg) || e1rmKg <= 0) return null;
  if (typeof factor !== 'number' || !Number.isFinite(factor) || factor <= 0) return null;
  const coeff = reCoefficient(sex, bodyweightKg);
  if (coeff === null) return null;
  return round4(e1rmKg * factor * coeff);
}

module.exports = {
  RE_POINTS_FORMULA_VERSION,
  Sex,
  scoringSexOf,
  reCoefficient,
  rePoints,
  round4,
};
