/// CANONICAL estimated-1RM specification for the profile achievement showcase.
///
/// This file and `functions/showcase/e1rm_spec.js` are pinned mirrors of each
/// other. `functions/coach/e1rm.js` already implements the identical curve for
/// coach analytics; `test/profile_e1rm_spec_test.dart` asserts the constants so
/// the three implementations cannot drift silently.
///
/// Rules (RIR takes NO part — it is never added to reps and never scales the
/// result):
///   * reps == 1        → E1RM == weight
///   * 2 <= reps <= 25  → Brzycki: weight * 36 / (37 - reps)
///   * reps > 25        → Epley:   weight * (1 + 0.0333 * reps)
///
/// Bump [kE1rmFormulaVersion] whenever the curve changes. Every persisted
/// record carries the version it was computed under, so a stale projection is
/// detectable and rebuildable.
library;

/// Schema/formula version stamped onto every persisted showcase record.
const int kE1rmFormulaVersion = 1;

/// Brzycki applies from 2 reps up to and including this rep count.
const int kBrzyckiMaxReps = 25;

/// Estimated 1RM from weight and reps alone.
///
/// Returns 0 for any non-positive or non-finite input, which is the same
/// "not a valid completed set" signal the reducers use.
double showcaseE1rm(num weight, num reps) {
  final w = weight.toDouble();
  final r = reps.toDouble();
  if (!w.isFinite || !r.isFinite || w <= 0 || r <= 0) return 0;
  if (r == 1) return w;
  if (r <= kBrzyckiMaxReps) return w * 36.0 / (37.0 - r);
  return w * (1 + 0.0333 * r);
}
