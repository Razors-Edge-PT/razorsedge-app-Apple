// Canonical coach-analytics E1RM (NO RIR).
//
// This mirrors PeriodizationModelUtils.calculateE1RM(weight, reps, rir) in
// lib/periodization_model_utils.dart with rir fixed at 0:
//   - <= 25 reps  → Brzycki:  w * (36 / (37 - r))
//   - >  25 reps  → Epley:    w * (1 + 0.0333 * r)
// A Dart-side pin test (test/coach_checkins_e1rm_pin_test.dart) asserts the
// same constants so the two implementations cannot drift silently.
//
// E1RM_FORMULA_VERSION is persisted on every baseline/event document. When the
// owner replaces the high-rep formula, bump the version and re-run the athlete
// bootstrap: baselines and historical events are recomputed under the new
// formula, and no "new PB today" event can appear from the version change
// alone because events are only ever derived from historical workout days that
// strictly improved on the history before them.

'use strict';

const E1RM_FORMULA_VERSION = 1;

/**
 * Coach-analytics estimated 1RM from weight + reps only.
 * Invalid input (non-positive / non-finite weight or reps) → 0.
 */
function coachE1rm(weight, reps) {
  const w = Number(weight);
  const r = Number(reps);
  if (!Number.isFinite(w) || !Number.isFinite(r) || w <= 0 || r <= 0) return 0;
  if (r === 1) return w;
  if (r <= 25) return w * (36 / (37 - r));
  return w * (1 + 0.0333 * r);
}

module.exports = { coachE1rm, E1RM_FORMULA_VERSION };
