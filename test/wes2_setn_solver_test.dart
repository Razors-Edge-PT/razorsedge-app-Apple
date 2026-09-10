import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/wes2_setn_solver.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/periodization_model_utils.dart';

/// Unit cover for the WES2 Set 2+ bounded weight × reps candidate solver.
///
/// These tests are pure: no Firestore, no controller, no progression model.
/// They pin the candidate BOUNDS (which weights and reps are legal), the
/// SCORING rule (minimum absolute E1RM error), and the deterministic TIE
/// ladder — the three things the cascade depends on.

/// Brute-force reference implementation, written independently of the solver.
/// Used to prove the solver's pick really is the global minimum-error pairing.
({double weight, int reps, double e1rm, double error}) _bruteForce({
  required double targetE1rm,
  required List<double> weights,
  required List<int> reps,
  required double thisRir,
  double Function(double)? toAbsolute,
}) {
  double bestErr = double.infinity;
  double bestW = weights.first;
  int bestR = reps.first;
  double bestE = 0;
  for (final w in weights) {
    final absW = toAbsolute == null ? w : toAbsolute(w);
    for (final r in reps) {
      final e =
          PeriodizationModelUtils.calculateE1RM(absW, r.toDouble(), thisRir);
      final err = (e - targetE1rm).abs();
      if (err < bestErr) {
        bestErr = err;
        bestW = w;
        bestR = r;
        bestE = e;
      }
    }
  }
  return (weight: bestW, reps: bestR, e1rm: bestE, error: bestErr);
}

double _e1rm(double w, int r, double rir) =>
    PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), rir);

void main() {
  final grid25 = IncrementGrid(primary: 2.5);

  List<double> weightsFor(double prev, double? prevActualRir,
          {IncrementGrid? grid}) =>
      Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: prev,
        previousActualRir: prevActualRir,
        grid: grid ?? grid25,
      );

  Wes2SetNChoice? choose({
    required double target,
    required List<double> weights,
    required List<int> reps,
    required double rir,
    required int preferredRep,
    required double prevWeight,
    double Function(double)? toAbsolute,
  }) =>
      Wes2SetNSolver.choose(
        targetE1rm: target,
        weightCandidates: weights,
        repCandidates: reps,
        thisRir: rir,
        preferredRep: preferredRep,
        previousResolvedDisplayWeight: prevWeight,
        toAbsolute: toAbsolute,
      );

  // ───────────────────────────────────────────────────────────────────────────
  // Weight candidate bounds
  // ───────────────────────────────────────────────────────────────────────────
  group('weight candidates', () {
    test('TEST 7 — previous ACTUAL RIR 2.5 gives exactly W0/W-1/W-2', () {
      expect(weightsFor(37.5, 2.5), <double>[32.5, 35.0, 37.5]);
    });

    test('null previous actual RIR gives exactly W0/W-1/W-2', () {
      expect(weightsFor(37.5, null), <double>[32.5, 35.0, 37.5]);
    });

    for (final rir in const [0.0, 1.0, 1.5, 2.0, 2.5]) {
      test('previous actual RIR $rir stays at or below the previous weight',
          () {
        final w = weightsFor(37.5, rir);
        expect(w, <double>[32.5, 35.0, 37.5]);
        expect(w.every((x) => x <= 37.5), isTrue);
      });
    }

    test('TEST 8 — previous ACTUAL RIR 3.0 adds W+1/W+2', () {
      expect(weightsFor(37.5, 3.0), <double>[32.5, 35.0, 37.5, 40.0, 42.5]);
    });

    test('TEST 12 — previous ACTUAL RIR 5.0 keeps heavier candidates', () {
      expect(weightsFor(37.5, 5.0), <double>[32.5, 35.0, 37.5, 40.0, 42.5]);
    });

    test('boundary: 2.5 locked, 2.5000001 unlocked', () {
      expect(Wes2SetNSolver.mayIncrease(2.5), isFalse);
      expect(Wes2SetNSolver.mayIncrease(2.5000001), isTrue);
      expect(Wes2SetNSolver.mayIncrease(null), isFalse);
      expect(weightsFor(37.5, 2.5).contains(40.0), isFalse);
      expect(weightsFor(37.5, 2.5000001).contains(40.0), isTrue);
    });

    test('TEST 13 — off-grid previous weight never snaps upward', () {
      // 38.2 is off-grid. W0 must be 37.5, never 40.
      expect(weightsFor(38.2, null), <double>[32.5, 35.0, 37.5]);
      expect(weightsFor(38.2, null).contains(40.0), isFalse);

      // With an actual RIR above 2.5 the heavier members open from W0 = 37.5.
      expect(weightsFor(38.2, 3.0), <double>[32.5, 35.0, 37.5, 40.0, 42.5]);
    });

    test('TEST 14 — primary 2.5 + secondary 1.25 uses true lattice members',
        () {
      final g = IncrementGrid(primary: 2.5, secondary: 1.25);
      // The lattice is 0, 1.25, 2.5, 3.75 … so the members below 37.5 are
      // 36.25 and 35.0 — NOT 35.0 and 32.5.
      expect(weightsFor(37.5, null, grid: g), <double>[35.0, 36.25, 37.5]);
      expect(weightsFor(37.5, 3.0, grid: g),
          <double>[35.0, 36.25, 37.5, 38.75, 40.0]);

      // Every candidate really is on the lattice.
      for (final w in weightsFor(37.5, 3.0, grid: g)) {
        expect(g.contains(w), isTrue, reason: '$w must be a grid member');
      }
    });

    test('TEST 15 — 280 kg has no ceiling regression', () {
      expect(weightsFor(280.0, null), <double>[275.0, 277.5, 280.0]);
      expect(weightsFor(280.0, 3.0),
          <double>[275.0, 277.5, 280.0, 282.5, 285.0]);
      // The old materialised 100-position list stopped at 247.5.
      expect(weightsFor(280.0, null).every((w) => w > 247.5), isTrue);
    });

    test('candidates clamp gracefully at the bottom of the lattice', () {
      final w = weightsFor(2.5, null);
      expect(w.every((x) => x >= 0), isTrue);
      expect(w.contains(2.5), isTrue);
    });

    test('keepCandidate filter drops non-positive absolute loads', () {
      final w = Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: 5.0,
        previousActualRir: null,
        grid: grid25,
        keepCandidate: (x) => x > 0,
      );
      expect(w.contains(0.0), isFalse);
      expect(w, <double>[2.5, 5.0]);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Rep candidate bounds
  // ───────────────────────────────────────────────────────────────────────────
  group('rep candidates', () {
    test('TEST 6 — preferred 7 searches exactly 2..12', () {
      expect(Wes2SetNSolver.repCandidates(preferredRep: 7),
          <int>[2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    });

    test('TEST 6 — preferred 3 searches exactly 1..8', () {
      expect(Wes2SetNSolver.repCandidates(preferredRep: 3),
          <int>[1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('range is exactly +/- 5 and never leaves it', () {
      for (final p in const [1, 2, 5, 8, 12, 20]) {
        final c = Wes2SetNSolver.repCandidates(preferredRep: p);
        expect(c.every((r) => (r - p).abs() <= Wes2SetNSolver.repSpan), isTrue);
        expect(c.every((r) => r >= 1), isTrue);
        expect(c.first, p - 5 < 1 ? 1 : p - 5);
        expect(c.last, p + 5);
      }
      expect(Wes2SetNSolver.repSpan, 5);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Joint search + scoring
  // ───────────────────────────────────────────────────────────────────────────
  group('joint weight x reps search', () {
    // The shoulder-press cascade target: Set 1 resolved 37.5 x 7 @ RIR 2.0,
    // group C raw drop 1.0 gated to 0.8 → target 47.4143.
    final spTarget = _e1rm(37.5, 7, 2.0) - 0.8;

    test('TEST 1 — best pairing is not the old sequential result', () {
      final weights = weightsFor(37.5, null);
      final reps = Wes2SetNSolver.repCandidates(preferredRep: 7);
      final c = choose(
        target: spTarget,
        weights: weights,
        reps: reps,
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;

      // The old solver anchored on 37.5 and chose a rep near 7.
      expect(c.weight, 32.5);
      expect(c.reps, 10);
      expect(c.error, closeTo(0.6143, 0.001));

      // and it genuinely beats the anchored pairing.
      final anchored = (_e1rm(37.5, 7, 2.0) - spTarget).abs();
      expect(c.error, lessThan(anchored));
    });

    test('TEST 2 — no legal candidate has a smaller error (full enumeration)',
        () {
      // Swept across targets, RIRs and previous weights so the property is
      // asserted over the whole space, not one lucky fixture.
      for (final prevActualRir in const <double?>[null, 1.0, 2.5, 3.0, 5.0]) {
        for (final prevW in const [32.5, 37.5, 100.0, 280.0]) {
          for (final preferred in const [3, 7, 12]) {
            for (final rir in const [0.0, 1.0, 2.0, 3.0]) {
              for (final targetShift in const [-6.0, -1.5, 0.0, 2.0, 9.0]) {
                final weights = weightsFor(prevW, prevActualRir);
                final reps =
                    Wes2SetNSolver.repCandidates(preferredRep: preferred);
                final target = _e1rm(prevW, preferred, rir) + targetShift;

                final c = choose(
                  target: target,
                  weights: weights,
                  reps: reps,
                  rir: rir,
                  preferredRep: preferred,
                  prevWeight: prevW,
                )!;
                final ref = _bruteForce(
                  targetE1rm: target,
                  weights: weights,
                  reps: reps,
                  thisRir: rir,
                );

                expect(c.error, lessThanOrEqualTo(ref.error + 1e-9),
                    reason: 'prevW=$prevW prevRir=$prevActualRir '
                        'pref=$preferred rir=$rir shift=$targetShift → '
                        'solver ${c.weight}x${c.reps} err=${c.error} '
                        'vs brute ${ref.weight}x${ref.reps} err=${ref.error}');
                // The chosen pairing must itself be legal.
                expect(weights.contains(c.weight), isTrue);
                expect(reps.contains(c.reps), isTrue);
              }
            }
          }
        }
      }
    });

    test('TEST 3 — lower weight + same reps can win', () {
      // Target IS the E1RM of 35.0 x 7, so that pairing has zero error.
      final target = _e1rm(35.0, 7, 2.0);
      final c = choose(
        target: target,
        weights: weightsFor(37.5, null),
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, 35.0);
      expect(c.reps, 7);
      expect(c.error, closeTo(0.0, 1e-9));
    });

    test('TEST 4 — same weight + changed reps can win', () {
      final target = _e1rm(37.5, 9, 2.0);
      final c = choose(
        target: target,
        weights: weightsFor(37.5, null),
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, 37.5);
      expect(c.reps, 9);
      expect(c.error, closeTo(0.0, 1e-9));
    });

    test('TEST 5 — lower weight + changed reps can win', () {
      final target = _e1rm(32.5, 10, 2.0);
      final c = choose(
        target: target,
        weights: weightsFor(37.5, null),
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, 32.5);
      expect(c.reps, 10);
      expect(c.error, closeTo(0.0, 1e-9));
    });

    test('TEST 9 — a heavier weight wins when previous ACTUAL RIR is 3.0', () {
      final target = _e1rm(40.0, 6, 2.0);
      final c = choose(
        target: target,
        weights: weightsFor(37.5, 3.0),
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, 40.0);
      expect(c.reps, 6);
      expect(c.error, closeTo(0.0, 1e-9));
    });

    test('TEST 10 — the same target at previous ACTUAL RIR 2.5 excludes 40',
        () {
      final target = _e1rm(40.0, 6, 2.0); // identical target to TEST 9
      final weights = weightsFor(37.5, 2.5);
      expect(weights.contains(40.0), isFalse);
      expect(weights.contains(42.5), isFalse);

      final c = choose(
        target: target,
        weights: weights,
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, lessThanOrEqualTo(37.5));
      // Still the best of what IS legal.
      final ref = _bruteForce(
        targetE1rm: target,
        weights: weights,
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        thisRir: 2.0,
      );
      expect(c.error, closeTo(ref.error, 1e-9));
    });

    test('TEST 11 — a hinted RIR of 3.0 does not unlock heavier weights', () {
      // The solver is only ever given the previous ACTUAL RIR. A hint-only 3.0
      // reaches it as null, so the heavier members never appear.
      final weights = weightsFor(37.5, null);
      expect(weights.contains(40.0), isFalse);
      expect(weights.contains(42.5), isFalse);
      expect(weights, <double>[32.5, 35.0, 37.5]);

      final target = _e1rm(40.0, 6, 2.0);
      final c = choose(
        target: target,
        weights: weights,
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, lessThanOrEqualTo(37.5));
    });

    test('constrained reps: only the weight moves', () {
      final target = _e1rm(35.0, 6, 2.0);
      final c = choose(
        target: target,
        weights: weightsFor(37.5, null),
        reps: const <int>[6],
        rir: 2.0,
        preferredRep: 6,
        prevWeight: 37.5,
      )!;
      expect(c.reps, 6);
      expect(c.weight, 35.0);
    });

    test('constrained weight: only the reps move', () {
      final target = _e1rm(42.5, 9, 2.0);
      final c = choose(
        target: target,
        weights: const <double>[42.5],
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, 42.5);
      expect(c.reps, 9);
    });

    test('empty candidate lists return null rather than guessing', () {
      expect(
          choose(
              target: 100,
              weights: const <double>[],
              reps: const <int>[5],
              rir: 2,
              preferredRep: 5,
              prevWeight: 37.5),
          isNull);
      expect(
          choose(
              target: 100,
              weights: const <double>[37.5],
              reps: const <int>[],
              rir: 2,
              preferredRep: 5,
              prevWeight: 37.5),
          isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 32 — deterministic tie behaviour
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 32 — deterministic ties', () {
    final g = IncrementGrid(primary: 2.5, secondary: 1.25);

    // At RIR 0, E1RM = w * 36 / (37 - r). These pairings are EXACTLY equal:
    //   37.5 x 7  = 37.5 * 36 / 30 = 45.0
    //   36.25 x 8 = 36.25 * 36 / 29 = 45.0
    //   38.75 x 6 = 38.75 * 36 / 31 = 45.0
    const target = 45.0;

    test('the fixture really is an exact tie', () {
      expect(_e1rm(37.5, 7, 0), closeTo(45.0, 1e-9));
      expect(_e1rm(36.25, 8, 0), closeTo(45.0, 1e-9));
      expect(_e1rm(38.75, 6, 0), closeTo(45.0, 1e-9));
    });

    test('tie-break 1 — closest to the preferred rep wins', () {
      final weights = weightsFor(37.5, null, grid: g); // 35, 36.25, 37.5

      final atSeven = choose(
        target: target,
        weights: weights,
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(atSeven.reps, 7);
      expect(atSeven.weight, 37.5);

      final atEight = choose(
        target: target,
        weights: weights,
        reps: Wes2SetNSolver.repCandidates(preferredRep: 8),
        rir: 0,
        preferredRep: 8,
        prevWeight: 37.5,
      )!;
      expect(atEight.reps, 8);
      expect(atEight.weight, 36.25);
    });

    test('tie-break 3 — equal rep AND weight distance falls to lower reps', () {
      // Previous actual RIR 3.0 puts 38.75 in play alongside 36.25.
      // Against preferred rep 7 both are rep-distance 1 and weight-distance
      // 1.25, so the ladder falls through to the lower rep count.
      final weights = weightsFor(37.5, 3.0, grid: g);
      expect(weights.contains(36.25), isTrue);
      expect(weights.contains(38.75), isTrue);

      final c = choose(
        target: target,
        weights: weights,
        reps: const <int>[6, 8], // exclude 7 so the tie is between 6 and 8
        rir: 0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.error, closeTo(0.0, 1e-9));
      expect(c.reps, 6, reason: 'lower rep count breaks the tie');
      expect(c.weight, 38.75);
    });

    test('the live shoulder-press fixture is a real three-way tie', () {
      // Set 1 resolved 37.5 x 7 @ ACTUAL RIR 1.0 → prevE1RM 46.5517, group C
      // raw drop 1.0 (not gated below RIR 1.8) → target 45.5517.
      // Three legal pairings land on EXACTLY 45.0, all err 0.5517:
      //   32.5 x 9, 35.0 x 7, 37.5 x 5.
      // Tie-break 1 (closest to preferred rep 7) picks 35.0 x 7.
      final target = _e1rm(37.5, 7, 1.0) - 1.0;
      expect(target, closeTo(45.5517, 0.0001));
      for (final p in const <(double, int)>[(32.5, 9), (35.0, 7), (37.5, 5)]) {
        expect(_e1rm(p.$1, p.$2, 2.0), closeTo(45.0, 1e-9));
      }

      final weights = weightsFor(37.5, 1.0);
      final reps = Wes2SetNSolver.repCandidates(preferredRep: 7);
      final c = choose(
        target: target,
        weights: weights,
        reps: reps,
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, 35.0);
      expect(c.reps, 7);
      expect(c.error, closeTo(0.5517, 0.0001));

      // Nothing in the space does better, and order does not decide it.
      final ref = _bruteForce(
          targetE1rm: target, weights: weights, reps: reps, thisRir: 2.0);
      expect(c.error, closeTo(ref.error, 1e-9));
      final rev = choose(
        target: target,
        weights: weights.reversed.toList(),
        reps: reps.reversed.toList(),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(rev.weight, 35.0);
      expect(rev.reps, 7);
    });

    test('heavier candidates do not automatically win at prev ACTUAL RIR 3.0',
        () {
      // Same target, heavier members legal — but they are only CANDIDATES.
      final target = _e1rm(37.5, 7, 1.0) - 1.0;
      final weights = weightsFor(37.5, 3.0);
      expect(weights, <double>[32.5, 35.0, 37.5, 40.0, 42.5]);
      final c = choose(
        target: target,
        weights: weights,
        reps: Wes2SetNSolver.repCandidates(preferredRep: 7),
        rir: 2.0,
        preferredRep: 7,
        prevWeight: 37.5,
      )!;
      expect(c.weight, 35.0, reason: '40/42.5 are legal but not closest');
      expect(c.reps, 7);
    });

    test('candidate ordering never changes the result', () {
      for (final prevRir in const <double?>[null, 3.0]) {
        final weights = weightsFor(37.5, prevRir, grid: g);
        final reps = Wes2SetNSolver.repCandidates(preferredRep: 7);

        for (final t in const [40.0, 45.0, 47.4143, 50.0, 52.5]) {
          final forward = choose(
            target: t,
            weights: weights,
            reps: reps,
            rir: 0,
            preferredRep: 7,
            prevWeight: 37.5,
          )!;
          final reversed = choose(
            target: t,
            weights: weights.reversed.toList(),
            reps: reps.reversed.toList(),
            rir: 0,
            preferredRep: 7,
            prevWeight: 37.5,
          )!;
          expect(reversed.weight, forward.weight, reason: 'target $t');
          expect(reversed.reps, forward.reps, reason: 'target $t');
        }
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 30 (unit half) — bodyweight units
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 30 — bodyweight display-added units', () {
    test('bounds are display-added; only scoring converts to absolute', () {
      const bodyweight = 80.0;
      double toAbs(double added) => bodyweight + added;

      // Previous resolved display-added load is +20 kg, so the candidate space
      // sits around 20 — never around 100.
      final weights = Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: 20.0,
        previousActualRir: null,
        grid: grid25,
        keepCandidate: (w) => toAbs(w) > 0,
      );
      expect(weights, <double>[15.0, 17.5, 20.0]);
      expect(weights.every((w) => w < 30), isTrue);

      // Scoring uses absolute load: target is the E1RM of bodyweight + 17.5.
      final target = _e1rm(toAbs(17.5), 8, 2.0);
      final c = choose(
        target: target,
        weights: weights,
        reps: Wes2SetNSolver.repCandidates(preferredRep: 8),
        rir: 2.0,
        preferredRep: 8,
        prevWeight: 20.0,
        toAbsolute: toAbs,
      )!;

      // Returned in DISPLAY-ADDED units.
      expect(c.weight, 17.5);
      expect(c.reps, 8);
      expect(c.error, closeTo(0.0, 1e-9));
      // and the reported E1RM is the absolute-load one.
      expect(c.e1rm, closeTo(_e1rm(97.5, 8, 2.0), 1e-9));
    });

    test('a zero display-added candidate survives when absolute load is real',
        () {
      double toAbs(double added) => 80.0 + added;
      final weights = Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: 5.0,
        previousActualRir: null,
        grid: grid25,
        keepCandidate: (w) => toAbs(w) > 0,
      );
      // Bodyweight-only (+0 kg) is a legitimate load here.
      expect(weights, <double>[0.0, 2.5, 5.0]);
    });
  });
}
