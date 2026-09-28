import 'bodyweight_load.dart';
import 'periodization_model_utils.dart';
import 'workout_model.dart';

/// Display and ranking values for one bodyweight-exercise set.
///
/// The stored load is normalised before it reaches this class, so [addedKg]
/// never silently means the athlete's bodyweight. When a historical
/// bodyweight is unavailable, an added-load set can still display and compare
/// its known external load, but its added-load E1RM remains unavailable.
class TopSetBodyweightMetrics {
  const TopSetBodyweightMetrics({
    required this.load,
    required this.rankTier,
    required this.rankValue,
    required this.reps,
    required this.rir,
    this.addedE1rmKg,
  });

  final NormalizedLoad load;
  final double? addedE1rmKg;

  /// 2 = historical-BW E1RM, 1 = known added load, 0 = not rankable safely.
  final int rankTier;
  final double rankValue;
  final int reps;
  final double rir;
}

TopSetBodyweightMetrics topSetBodyweightMetrics(
  SetDetails set,
  double? bodyweightKg,
) {
  final NormalizedLoad load = set.bodyweightLoad(bodyweightKg);
  final int reps = set.reps ?? 0;
  final double rir = set.rir ?? 0.0;
  final double? total = load.totalKg;
  final double? historicalBodyweight =
      bodyweightKg != null && bodyweightKg.isFinite && bodyweightKg > 0
          ? bodyweightKg
          : null;

  if (historicalBodyweight != null && total != null && reps > 0) {
    final double addedE1rm =
        PeriodizationModelUtils.calculateE1RM(total, reps.toDouble(), rir) -
            historicalBodyweight;
    return TopSetBodyweightMetrics(
      load: load,
      addedE1rmKg: addedE1rm,
      rankTier: 2,
      rankValue: addedE1rm,
      reps: reps,
      rir: rir,
    );
  }

  final double? added = load.addedKg;
  if (added != null) {
    return TopSetBodyweightMetrics(
      load: load,
      rankTier: 1,
      rankValue: added,
      reps: reps,
      rir: rir,
    );
  }

  return TopSetBodyweightMetrics(
    load: load,
    rankTier: 0,
    rankValue: 0,
    reps: reps,
    rir: rir,
  );
}

/// True when [candidate] is the safer, stronger bodyweight performance.
/// Unknown historical bodyweight always sorts below a derived added-load
/// E1RM, and a legacy total with no derivable added load is never used as if it
/// were external weight.
bool bodyweightTopSetBeats(
  TopSetBodyweightMetrics candidate,
  TopSetBodyweightMetrics incumbent,
) {
  if (candidate.rankTier != incumbent.rankTier) {
    return candidate.rankTier > incumbent.rankTier;
  }
  if (candidate.rankValue != incumbent.rankValue) {
    return candidate.rankValue > incumbent.rankValue;
  }

  final double candidateAdded =
      candidate.load.addedKg ?? double.negativeInfinity;
  final double incumbentAdded =
      incumbent.load.addedKg ?? double.negativeInfinity;
  if (candidateAdded != incumbentAdded) return candidateAdded > incumbentAdded;
  if (candidate.reps != incumbent.reps) return candidate.reps > incumbent.reps;
  return candidate.rir < incumbent.rir;
}
