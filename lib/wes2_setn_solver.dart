/// Bounded weight × reps candidate solver for WES2 Set 2 and beyond.
///
/// The WES cascade gives every set after the first a target E1RM (previous
/// resolved E1RM minus the group drop-off). This solver answers the follow-up
/// question: which legal combination of weight and reps lands closest to that
/// target?
///
/// The old Set N logic was sequential — anchor on the previous weight, reverse
/// out a rep count, round it, reverse one weight back out for that rep, snap.
/// That can walk straight past a better pairing: a slightly lighter load with
/// one more rep is often much closer to the target than the same load with two
/// fewer. This solver instead enumerates a small bounded Cartesian space and
/// scores every member on absolute E1RM error.
///
/// Everything here is pure and progression-model agnostic. It never sees which
/// model produced Set 1's hint — only the previous set's *resolved* numbers
/// (`actual ?? hint`). Add Reps, Smart Progression and Linear all feed the same
/// cascade.
///
/// ## Units
///
/// Weights in and out are DISPLAY-ADDED units — for a bodyweight exercise that
/// is the load added on top of the athlete, not the absolute load. Candidate
/// generation, the previous-weight boundary and the tie-breakers all operate in
/// display units. Only the E1RM scoring converts, via the caller's
/// [toAbsolute] hook. Absolute and display kilos are never compared.
library;

import 'increment_grid.dart';
import 'periodization_model_utils.dart';

/// The winning weight × reps pairing, with the score that won it.
class Wes2SetNChoice {
  const Wes2SetNChoice({
    required this.weight,
    required this.reps,
    required this.e1rm,
    required this.error,
  });

  /// Chosen weight in DISPLAY-ADDED units.
  final double weight;

  /// Chosen rep count.
  final int reps;

  /// E1RM this pairing produces, computed on ABSOLUTE load.
  final double e1rm;

  /// Absolute distance from the set's target E1RM.
  final double error;

  @override
  String toString() => 'Wes2SetNChoice($weight × $reps, '
      'e1rm=${e1rm.toStringAsFixed(3)}, err=${error.toStringAsFixed(3)})';
}

/// Bounded candidate generation and scoring for Set 2+.
class Wes2SetNSolver {
  Wes2SetNSolver._();

  /// How far the rep search reaches either side of the preferred rep centre.
  static const int repSpan = 5;

  /// How many lattice members below the previous weight stay in play.
  static const int weightStepsDown = 2;

  /// How many lattice members above the previous weight open up once the
  /// previous set carries an ACTUAL RIR above [highRirThreshold].
  static const int weightStepsUp = 2;

  /// Only an ACTUAL previous-set RIR strictly above this unlocks heavier loads.
  static const double highRirThreshold = 2.5;

  /// Errors within this of each other count as equal and go to the tie-breakers.
  static const double _errEps = 1e-9;

  /// True when the previous set's ACTUAL RIR permits heavier generated loads.
  ///
  /// This is the single gate for the whole heavier-weight permission. A HINTED
  /// or planned RIR — however high — never opens it: the athlete has to have
  /// actually reported leaving more than [highRirThreshold] reps in reserve.
  static bool mayIncrease(double? previousActualRir) =>
      previousActualRir != null && previousActualRir > highRirThreshold;

  /// The legal generated-weight candidates for this set, ascending.
  ///
  /// Anchored on `W0 = greatest lattice member <= previousResolvedDisplayWeight`
  /// so an off-grid previous weight (say a hand-typed 38.2) never snaps UPWARD
  /// through itself. From there:
  ///
  ///  * always: `W0`, and [weightStepsDown] members below it;
  ///  * additionally, when [mayIncrease] holds for [previousActualRir],
  ///    [weightStepsUp] members above `W0`.
  ///
  /// Members come from [grid] itself rather than arithmetic — with a secondary
  /// increment the lattice is not uniform, so `w - primary` is not generally a
  /// valid weight.
  ///
  /// [keepCandidate] filters the result in display units; the caller uses it to
  /// drop weights that would produce a non-positive absolute load.
  static List<double> weightCandidates({
    required double previousResolvedDisplayWeight,
    required double? previousActualRir,
    required IncrementGrid grid,
    bool Function(double displayWeight)? keepCandidate,
  }) {
    final out = <double>[];

    final double? w0 = grid.previousOrSame(previousResolvedDisplayWeight);
    if (w0 == null) return const <double>[];
    out.add(w0);

    double cursor = w0;
    for (int i = 0; i < weightStepsDown; i++) {
      final next = grid.previous(cursor);
      if (next == null) break;
      out.add(next);
      cursor = next;
    }

    if (mayIncrease(previousActualRir)) {
      cursor = w0;
      for (int i = 0; i < weightStepsUp; i++) {
        cursor = grid.next(cursor);
        out.add(cursor);
      }
    }

    final seen = <double>[];
    for (final w in out) {
      if (!w.isFinite) continue;
      if (keepCandidate != null && !keepCandidate(w)) continue;
      if (seen.any((s) => (s - w).abs() < 1e-9)) continue;
      seen.add(w);
    }
    seen.sort();
    return seen;
  }

  /// The legal rep candidates for this set: `preferredRep ± `[repSpan]`,
  /// inclusive, clamped to the valid WES rep range.
  ///
  /// The span is deliberately bounded — the search is meant to stay in the
  /// neighbourhood of the set's intended rep target, not roam the whole range
  /// hunting for an arithmetically closer E1RM.
  static List<int> repCandidates({
    required int preferredRep,
    int minRep = 1,
    int maxRep = 100,
  }) {
    final centre = preferredRep.clamp(minRep, maxRep);
    final out = <int>[];
    for (int r = centre - repSpan; r <= centre + repSpan; r++) {
      if (r < minRep || r > maxRep) continue;
      out.add(r);
    }
    return out;
  }

  /// Scores every `weight × reps` pairing and returns the best one.
  ///
  /// ## Scoring
  ///
  /// Primary criterion, always: the smallest absolute difference between the
  /// pairing's E1RM and [targetE1rm]. There is no standing preference for
  /// adjusting weight over reps or the other way round — whichever pairing gets
  /// closest to the target wins, whether that means the same load with fewer
  /// reps, a lighter load with the same reps, or two steps down with three more.
  ///
  /// ## Ties
  ///
  /// Candidate iteration order must never decide the outcome, so pairings whose
  /// errors are equal within [_errEps] fall through an explicit ladder:
  ///
  ///  1. smallest `|reps - preferredRep|`
  ///  2. smallest `|weight - previousResolvedDisplayWeight|`
  ///  3. lower rep count
  ///  4. lower weight
  ///
  /// Steps 3 and 4 are total over the candidate space, so the result is fully
  /// deterministic. Step 3 keeps the lower rep count, matching the tie-break the
  /// previous WES rep selector used.
  ///
  /// Returns null when either candidate list is empty.
  static Wes2SetNChoice? choose({
    required double targetE1rm,
    required List<double> weightCandidates,
    required List<int> repCandidates,
    required double thisRir,
    required int preferredRep,
    required double previousResolvedDisplayWeight,
    double Function(double displayWeight)? toAbsolute,
  }) {
    if (weightCandidates.isEmpty || repCandidates.isEmpty) return null;

    Wes2SetNChoice? best;
    double bestRepDist = double.infinity;
    double bestWeightDist = double.infinity;

    for (final w in weightCandidates) {
      final absW = toAbsolute == null ? w : toAbsolute(w);
      for (final r in repCandidates) {
        final e1rm =
            PeriodizationModelUtils.calculateE1RM(absW, r.toDouble(), thisRir);
        final err = (e1rm - targetE1rm).abs();
        final repDist = (r - preferredRep).abs().toDouble();
        final weightDist = (w - previousResolvedDisplayWeight).abs();

        if (best == null) {
          best = Wes2SetNChoice(weight: w, reps: r, e1rm: e1rm, error: err);
          bestRepDist = repDist;
          bestWeightDist = weightDist;
          continue;
        }

        if (err < best.error - _errEps) {
          best = Wes2SetNChoice(weight: w, reps: r, e1rm: e1rm, error: err);
          bestRepDist = repDist;
          bestWeightDist = weightDist;
          continue;
        }
        if (err > best.error + _errEps) continue;

        // Errors are effectively equal — walk the documented tie ladder.
        final bool take;
        if ((repDist - bestRepDist).abs() > _errEps) {
          take = repDist < bestRepDist;
        } else if ((weightDist - bestWeightDist).abs() > _errEps) {
          take = weightDist < bestWeightDist;
        } else if (r != best.reps) {
          take = r < best.reps;
        } else {
          take = w < best.weight - _errEps;
        }

        if (take) {
          best = Wes2SetNChoice(weight: w, reps: r, e1rm: e1rm, error: err);
          bestRepDist = repDist;
          bestWeightDist = weightDist;
        }
      }
    }

    return best;
  }
}
