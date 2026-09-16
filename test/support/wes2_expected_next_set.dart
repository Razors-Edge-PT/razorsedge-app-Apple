// An independent reference model for "what the next set should be".
//
// Deliberately not a call into the cascade: it recomputes the target from what
// the previous row SHOWS (actual where entered, hint otherwise) using the
// unchanged formulas, then brute-forces the documented candidate space and
// applies the documented tie ladder. If production and this model agree, the
// cascade consumed the displayed predecessor and nothing else.
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/wes2_cascade_resolver.dart';
import 'package:localtest222/wes2_setn_solver.dart';

class ExpectedNextSet {
  const ExpectedNextSet(this.weight, this.reps, this.target, this.centre);
  final double weight;
  final int reps;
  final double target;
  final int centre;

  @override
  String toString() => '$weight x $reps (target $target, centre $centre)';
}

/// The group C drop (1.0 at every set index), gated by the previous RIR.
double gatedDropC(double prevRir) {
  if (prevRir > 2.0) return 0.0;
  if (prevRir >= 1.8 && prevRir <= 2.0) return 0.8;
  return 1.0;
}

ExpectedNextSet expectedNextSet({
  required Wes2SetState previousFinal,
  required double thisRir,
  required IncrementGrid grid,
}) {
  final v = Wes2CascadeResolver.resolvedValues(previousFinal);
  final double prevRir = v.rir ?? 0.0;
  final double prevE1rm = PeriodizationModelUtils.calculateE1RM(
      v.weight!, v.reps!.toDouble(), prevRir);
  final double target = (prevE1rm - gatedDropC(prevRir)).clamp(1.0, 9999.0);

  final List<double> weights = Wes2SetNSolver.weightCandidates(
    previousResolvedDisplayWeight: v.weight!,
    // Only an ENTERED previous RIR may unlock heavier loads.
    previousActualRir: previousFinal.rir.actualValue,
    grid: grid,
  );
  final int centre = Wes2SetNSolver.centre(
    targetE1rm: target,
    absoluteWeight: grid.previousOrSame(v.weight!),
    thisRir: thisRir,
    fallbackReps: v.reps,
  ).rep;
  final List<int> reps = Wes2SetNSolver.repCandidates(preferredRep: centre);

  double bestErr = double.infinity;
  double bw = weights.first;
  int br = reps.first;
  for (final double w in weights) {
    for (final int r in reps) {
      final double err =
          (PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), thisRir) -
                  target)
              .abs();
      if (err < bestErr - 1e-9) {
        bestErr = err;
        bw = w;
        br = r;
        continue;
      }
      if (err > bestErr + 1e-9) continue;
      // Documented tie ladder: rep distance, then weight distance, then lower
      // reps, then lower weight.
      final int repDist = (r - centre).abs();
      final int bestRepDist = (br - centre).abs();
      final double wDist = (w - v.weight!).abs();
      final double bestWDist = (bw - v.weight!).abs();
      final bool take;
      if (repDist != bestRepDist) {
        take = repDist < bestRepDist;
      } else if ((wDist - bestWDist).abs() > 1e-9) {
        take = wDist < bestWDist;
      } else if (r != br) {
        take = r < br;
      } else {
        take = w < bw;
      }
      if (take) {
        bestErr = err;
        bw = w;
        br = r;
      }
    }
  }
  return ExpectedNextSet(bw, br, target, centre);
}
