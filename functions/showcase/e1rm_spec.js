// CANONICAL estimated-1RM specification for the profile achievement showcase.
//
// Pinned mirror of lib/profile/core/e1rm_spec.dart. functions/coach/e1rm.js
// implements the identical curve for coach analytics; this module re-exports
// that implementation rather than restating it, so there is exactly ONE
// arithmetic definition in the Functions codebase and drift is impossible by
// construction.
//
//   * reps == 1        → E1RM == weight
//   * 2 <= reps <= 25  → Brzycki: weight * 36 / (37 - reps)
//   * reps > 25        → Epley:   weight * (1 + 0.0333 * reps)
//
// RIR takes no part: it is never added to reps and never scales the result.
//
// SHOWCASE_FORMULA_VERSION is stamped onto every persisted record. It is
// pinned to the coach engine's E1RM_FORMULA_VERSION for the same reason —
// one curve, one version.

'use strict';

const { coachE1rm, E1RM_FORMULA_VERSION } = require('../coach/e1rm');

/** Brzycki applies from 2 reps up to and including this rep count. */
const BRZYCKI_MAX_REPS = 25;

/** Estimated 1RM from weight and reps alone. Invalid input → 0. */
function showcaseE1rm(weight, reps) {
  return coachE1rm(weight, reps);
}

module.exports = {
  showcaseE1rm,
  SHOWCASE_FORMULA_VERSION: E1RM_FORMULA_VERSION,
  BRZYCKI_MAX_REPS,
};
