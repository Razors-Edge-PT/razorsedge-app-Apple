import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/periodization_model_utils.dart';

/// FIX 1 — the increment grid is a mathematical lattice, not a 100-entry list.
///
/// Every progression path used to materialise its valid weights with
/// `for (int i = 0; i < 100; i++) opts.add(i * primary)`. With a 2.5 kg primary
/// that list ends at 247.5 kg, which is BELOW real training loads (a Lat Pull
/// Down logged at 265-285 kg). Smart Progression therefore snapped its centre
/// down to the ceiling and bought the missing E1RM with reps, turning a 3-rep
/// plan into ~247.5 × 6.
///
/// These tests pin the lattice semantics, prove the ceiling is gone from every
/// progression model, and prove nothing below the old ceiling moved.

/// The pre-fix generator, kept verbatim so "below the ceiling nothing changed"
/// is asserted against the real old behaviour rather than against a guess.
List<double> _legacyGrid(double primary, [double? secondary]) {
  final opts = <double>{};
  for (int i = 0; i < 100; i++) {
    opts.add(i * primary);
  }
  if (secondary != null && secondary > 0 && secondary != primary) {
    for (final base in opts.toList()) {
      opts.add(base + secondary);
    }
  }
  return opts.toList()..sort();
}

double _legacyNearest(List<double> grid, double target) =>
    grid.reduce((a, b) => (a - target).abs() < (b - target).abs() ? a : b);

final DateTime _asOf = DateTime(2026, 3, 10);

/// A single top set whose E1RM is EXACTLY its weight: at 1 total rep Brzycki is
/// `w * 36 / (37 - 1)` = `w`. Base E1RM therefore lands on the requested value
/// with no floating-point slack, via the two-week-average branch.
List<Map<String, dynamic>> _historyWithBaseE1RM(double e1rm) => [
      {
        'weight': e1rm,
        'reps': 1,
        'rir': 0.0,
        'date': _asOf.subtract(const Duration(days: 3)),
      },
    ];

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = [];
    PeriodizationModelUtils.topSetsByExercise.clear();
    PeriodizationModelUtils.setExerciseSettings({});
  });
  tearDown(() {
    PeriodizationModelUtils.savedWorkoutsList = [];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // THE regression: Lat Pull Down, Supinated at 270 kg.
  // ───────────────────────────────────────────────────────────────────────────
  group('Lat Pull Down ceiling regression', () {
    const String exercise = 'Lat Pull Down, Supinated';
    final List<double> cappedGrid = _legacyGrid(2.5); // ends at 247.5

    test('reverse-calculated centre is ~269.93 and snaps to 270.0', () {
      final implied = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: 299.0,
        reps: 3,
        rir: 1.5,
      );
      expect(implied, closeTo(269.93, 0.01));

      final grid = IncrementGrid(primary: 2.5);
      expect(grid.snap(implied), 270.0);
      expect(grid.previous(270.0), 267.5);
      expect(grid.next(270.0), 272.5);

      // The old list literally cannot represent this neighbourhood.
      expect(cappedGrid.last, 247.5);
      expect(_legacyNearest(cappedGrid, implied), 247.5);
    });

    test('Smart Progression picks 270.0 × 3, not the 247.5-ceiling fallback',
        () {
      final result = PeriodizationModelUtils.smartProgressionModel(
        exerciseName: exercise,
        repTarget: 3,
        defaultWeight: 245.0,
        rirValue: 1.5,
        // Deliberately hand it the OLD capped list: the grid is what decides
        // now, so the ceiling in the compatibility payload is inert.
        increments: cappedGrid,
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: _historyWithBaseE1RM(299.0),
        weekIndex: 1,
        exerciseId: 'latPullDownSupinatedTestId',
        asOfDate: _asOf,
      );

      final double w = (result['weight'] as num).toDouble();
      final int r = (result['reps'] as num).toInt();

      expect(w, 270.0);
      expect(r, 3);

      final e1rm = PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), 1.5);
      expect(e1rm, closeTo(299.08, 0.01));
      expect(e1rm, greaterThanOrEqualTo(299.0));
    });

    test('245 × 6 / 247.5 × 6 is no longer reachable — the ceiling is gone', () {
      final result = PeriodizationModelUtils.smartProgressionModel(
        exerciseName: exercise,
        repTarget: 3,
        defaultWeight: 245.0,
        rirValue: 1.5,
        increments: cappedGrid,
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: _historyWithBaseE1RM(299.0),
        weekIndex: 1,
        exerciseId: 'latPullDownSupinatedTestId',
        asOfDate: _asOf,
      );

      final double w = (result['weight'] as num).toDouble();
      final int r = (result['reps'] as num).toInt();

      // The rep target is 3. The old ceiling forced 6 reps at ~247.5 because no
      // heavier weight existed in the list.
      expect(w, greaterThan(247.5),
          reason: 'centre must be able to exceed the old 99 × 2.5 ceiling');
      expect(r, lessThanOrEqualTo(4),
          reason: 'reps must not be inflated to compensate for a clamped '
              'weight');
      expect([245.0, 247.5, 250.0], isNot(contains(w)));
    });

    test('router (getWeightByProgressionModel) agrees — no overlay re-snap', () {
      final result = PeriodizationModelUtils.getWeightByProgressionModel(
        model: ProgressionModelType.smartProgression,
        exerciseName: exercise,
        repTarget: 3,
        defaultWeight: 245.0,
        rirValue: 1.5,
        increments: cappedGrid,
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: _historyWithBaseE1RM(299.0),
        weekIndex: 1,
        exerciseId: 'latPullDownSupinatedTestId',
        asOfDate: _asOf,
      );

      // The model's answer must survive the final overlay snap unchanged: both
      // now use the same lattice.
      expect((result['weight'] as num).toDouble(), 270.0);
      expect((result['reps'] as num).toInt(), 3);
    });

    test('getSuggestedWeightFromRep snaps the baseline at 270 too', () {
      final w = PeriodizationModelUtils.getSuggestedWeightFromRep(
        exercise,
        3,
        1.5,
        exerciseId: 'latPullDownSupinatedTestId',
        topSetHistory: _historyWithBaseE1RM(299.0),
        increments: cappedGrid,
        grid: IncrementGrid(primary: 2.5),
        asOfDate: _asOf,
      );
      expect(w, 270.0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Snapping at magnitudes the old list could never reach.
  // ───────────────────────────────────────────────────────────────────────────
  group('snapping has no upper bound', () {
    test('primary 2.5 around 270 kg', () {
      final g = IncrementGrid(primary: 2.5);
      expect(g.snap(269.93), 270.0);
      expect(g.snap(268.7), 267.5); // 268.75 is the midpoint; 268.7 sits below
      expect(g.snap(271.3), 272.5);
      expect(g.neighborhood(269.93), [267.5, 270.0, 272.5]);
    });

    test('primary 2.5 around 500 kg', () {
      final g = IncrementGrid(primary: 2.5);
      expect(g.snap(500.0), 500.0);
      expect(g.snap(501.2), 500.0);
      expect(g.snap(501.3), 502.5);
      expect(g.previous(500.0), 497.5);
      expect(g.next(500.0), 502.5);
    });

    test('primary 1.25 above 123.75 kg (the old 99 × 1.25 ceiling)', () {
      final g = IncrementGrid(primary: 1.25);
      expect(_legacyGrid(1.25).last, 123.75);
      expect(g.snap(200.4), 200.0);
      expect(g.snap(200.7), 201.25);
      expect(g.next(200.0), 201.25);
      expect(g.previous(200.0), 198.75);
    });

    test('primary 0.5 at a high target (old ceiling 49.5 kg)', () {
      final g = IncrementGrid(primary: 0.5);
      expect(_legacyGrid(0.5).last, 49.5);
      expect(g.snap(312.4), 312.5);
      expect(g.snap(312.2), 312.0);
      expect(g.neighborhood(312.4), [312.0, 312.5, 313.0]);
    });

    test('an absurd magnitude still resolves locally, not by generation', () {
      final g = IncrementGrid(primary: 2.5);
      expect(g.snap(10000.4), 10000.0);
      expect(g.next(10000.0), 10002.5);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // primary + secondary semantics: {kP} ∪ {kP + S}, preserved exactly.
  // ───────────────────────────────────────────────────────────────────────────
  group('primary + secondary lattice', () {
    test('2.5 + 1.25 keeps the true sorted union at high weight', () {
      final g = IncrementGrid(primary: 2.5, secondary: 1.25);

      // primary sequence around 270
      expect(g.contains(267.5), isTrue);
      expect(g.contains(270.0), isTrue);
      expect(g.contains(272.5), isTrue);
      // secondary-offset sequence around 270
      expect(g.contains(268.75), isTrue);
      expect(g.contains(271.25), isTrue);

      expect(g.snap(269.93), 270.0);
      expect(g.previous(270.0), 268.75);
      expect(g.next(270.0), 271.25);
      expect(g.neighborhood(269.93), [268.75, 270.0, 271.25]);
    });

    test('non-uniform 2.5 + 1.0 never invents an off-grid neighbour', () {
      // Valid: 0, 1, 2.5, 3.5, 5, 6 …  `centre - delta` (2.5 - 1.0 = 1.5) is
      // NOT a valid weight; the old trial construction produced exactly that.
      final g = IncrementGrid(primary: 2.5, secondary: 1.0);
      expect(g.contains(1.5), isFalse);
      expect(g.neighborhood(2.5), [1.0, 2.5, 3.5]);
      for (final w in g.neighborhood(268.0, span: 2)) {
        expect(g.contains(w), isTrue, reason: '$w must be on the lattice');
      }
    });

    test('removing the secondary restores primary-only semantics', () {
      final withSecondary =
          PeriodizationModelUtils.gridFromRaw({'primary': 2.5, 'secondary': 1.25});
      final withoutSecondary =
          PeriodizationModelUtils.gridFromRaw({'primary': 2.5});

      expect(withSecondary.hasSecondary, isTrue);
      expect(withoutSecondary.hasSecondary, isFalse);
      expect(withoutSecondary.contains(16.25), isFalse);
      expect(withoutSecondary.contains(268.75), isFalse);
      expect(withoutSecondary.snap(269.93), 270.0);
      expect(withoutSecondary.neighborhood(269.93), [267.5, 270.0, 272.5]);
    });

    test('secondary == primary adds nothing and changes nothing', () {
      final same = IncrementGrid(primary: 2.5, secondary: 2.5);
      final plain = IncrementGrid(primary: 2.5);
      expect(same.hasSecondary, isFalse);
      expect(same, plain);
      expect(same.expand(), plain.expand());
      for (final t in [0.0, 3.1, 99.9, 269.93, 512.4]) {
        expect(same.snap(t), plain.snap(t));
      }
    });

    test('a zero / missing / negative primary falls back to 2.5', () {
      expect(IncrementGrid(primary: 0).primary, 2.5);
      expect(IncrementGrid(primary: -5).primary, 2.5);
      expect(IncrementGrid(primary: double.nan).primary, 2.5);
      expect(PeriodizationModelUtils.gridFromMap(null).primary, 2.5);
      expect(PeriodizationModelUtils.gridFromRaw(null).primary, 2.5);
      expect(IncrementGrid(primary: 0).snap(269.93), 270.0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Edges: exact members, ties, zero.
  // ───────────────────────────────────────────────────────────────────────────
  group('snapping edges', () {
    test('an exact grid member does not move', () {
      final g = IncrementGrid(primary: 2.5);
      for (final w in [0.0, 2.5, 100.0, 247.5, 270.0, 502.5]) {
        expect(g.snap(w), w);
        expect(g.contains(w), isTrue);
      }
      final s = IncrementGrid(primary: 2.5, secondary: 1.25);
      for (final w in [1.25, 16.25, 268.75, 271.25]) {
        expect(s.snap(w), w);
      }
    });

    test('ties resolve upward, exactly as the old list reduce did', () {
      // `reduce((a, b) => (a - t).abs() < (b - t).abs() ? a : b)` over an
      // ascending list keeps `b` on a tie — the HIGHER member. The lattice
      // must not silently flip that.
      final g = IncrementGrid(primary: 2.5);
      final legacy = _legacyGrid(2.5);
      expect(_legacyNearest(legacy, 11.25), 12.5);
      expect(g.snap(11.25), 12.5);
      // 268.75 is exactly between 267.5 and 270.0 — above the old ceiling.
      expect(g.snap(268.75), 270.0);

      final s = IncrementGrid(primary: 2.5, secondary: 1.0);
      final legacyS = _legacyGrid(2.5, 1.0);
      // 0.5 is equidistant between the primary member 0.0 and the
      // secondary-offset member 1.0.
      expect(_legacyNearest(legacyS, 0.5), 1.0);
      expect(s.snap(0.5), 1.0);
    });

    test('never returns a negative weight', () {
      for (final g in [
        IncrementGrid(primary: 2.5),
        IncrementGrid(primary: 2.5, secondary: 1.25),
        IncrementGrid(primary: 0.5),
      ]) {
        expect(g.snap(-100.0), 0.0);
        expect(g.snap(-0.4), 0.0);
        expect(g.snap(0.0), 0.0);
        expect(g.previous(0.0), isNull);
        expect(g.previousOrSame(-1.0), isNull);
        expect(g.neighborhood(0.0).every((w) => w >= 0), isTrue);
        expect(g.neighborhood(0.0).first, 0.0);
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Nothing below the old ceiling moved.
  // ───────────────────────────────────────────────────────────────────────────
  group('parity below the old ceiling', () {
    test('snap matches the legacy list nearest for every 0.1 kg step', () {
      for (final cfg in <List<double?>>[
        [2.5, null],
        [1.25, null],
        [5.0, null],
        [2.5, 1.25],
        [2.5, 1.0],
      ]) {
        final primary = cfg[0]!;
        final secondary = cfg[1];
        final legacy = _legacyGrid(primary, secondary);
        final grid = IncrementGrid(primary: primary, secondary: secondary);
        final double ceiling = legacy.last;

        for (double t = 0.0; t <= ceiling - primary; t += 0.1) {
          final target = double.parse(t.toStringAsFixed(1));
          expect(grid.snap(target), closeTo(_legacyNearest(legacy, target), 1e-9),
              reason: 'primary=$primary secondary=$secondary target=$target');
        }
      }
    });

    test('expandIncrementOptions output is byte-for-byte the legacy list', () {
      expect(
        PeriodizationModelUtils.expandIncrementOptions({'primary': 2.5}),
        _legacyGrid(2.5),
      );
      expect(
        PeriodizationModelUtils.expandIncrementOptions(
            {'primary': 2.5, 'secondary': 1.25}),
        _legacyGrid(2.5, 1.25),
      );
      expect(
        PeriodizationModelUtils.expandIncrementOptions({'primary': 1.25}),
        _legacyGrid(1.25),
      );
    });

    test('IncrementGrid.fromWeights recovers the lattice a list lies on', () {
      expect(IncrementGrid.fromWeights(_legacyGrid(2.5)),
          IncrementGrid(primary: 2.5));
      // {2.5k} ∪ {2.5k + 1.25} IS the uniform 1.25 lattice, so the recovered
      // grid is the same set of weights expressed in its simplest form.
      final recovered = IncrementGrid.fromWeights(_legacyGrid(2.5, 1.25));
      expect(recovered, IncrementGrid(primary: 1.25));
      final declared = IncrementGrid(primary: 2.5, secondary: 1.25);
      for (final t in [0.0, 3.3, 16.1, 269.93, 501.1]) {
        expect(recovered.snap(t), declared.snap(t),
            reason: 'the two spellings must snap identically at $t');
      }
      expect(IncrementGrid.fromWeights(_legacyGrid(2.5, 1.0)),
          IncrementGrid(primary: 2.5, secondary: 1.0));
      // Degenerate inputs keep the safe default.
      expect(IncrementGrid.fromWeights(const []), IncrementGrid(primary: 2.5));
      expect(IncrementGrid.fromWeights(const [2.5]), IncrementGrid(primary: 2.5));
      // A list that does not start at zero still yields its own step.
      expect(IncrementGrid.fromWeights(const [5.0, 7.5, 10.0, 12.5]),
          IncrementGrid(primary: 2.5));
    });

    test('roundToNearestValidIncrement is unchanged below the ceiling and '
        'no longer clamps above it', () {
      PeriodizationModelUtils.setExerciseSettings({
        'Lat Pull Down, Supinated': {
          'increments': {'primary': 2.5}
        },
      });
      final legacy = _legacyGrid(2.5);
      for (final t in [0.0, 42.4, 100.0, 201.3, 247.4]) {
        expect(
          PeriodizationModelUtils.roundToNearestValidIncrement(
              targetWeight: t, exerciseName: 'Lat Pull Down, Supinated'),
          _legacyNearest(legacy, t),
        );
      }
      expect(
        PeriodizationModelUtils.roundToNearestValidIncrement(
            targetWeight: 269.93, exerciseName: 'Lat Pull Down, Supinated'),
        270.0,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // The other progression models progress above the old ceiling.
  // ───────────────────────────────────────────────────────────────────────────
  group('models progress above the old ceiling', () {
    final List<double> cappedGrid = _legacyGrid(2.5);

    test('Linear promotes 270.0 → 272.5 instead of stalling at the ceiling',
        () {
      final history = <Map<String, dynamic>>[
        {
          'weight': 270.0,
          'reps': 5,
          'rir': 1.0,
          'date': _asOf.subtract(const Duration(days: 5)),
        },
      ];

      final w = PeriodizationModelUtils.getProgressedWeight(
        exerciseName: 'Lat Pull Down, Supinated',
        repTarget: 5,
        defaultWeight: 270.0,
        rirValue: 1.0,
        increments: cappedGrid,
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: history,
        weekIndex: 1,
        exerciseId: 'latPullDownSupinatedTestId',
        asOfDate: _asOf,
      );

      expect(w, 272.5,
          reason: 'the old scan over a 247.5-capped list found no higher '
              'option and returned 270.0 forever');
    });

    test('Add Reps promotes to the next weight above the ceiling', () {
      final history = <Map<String, dynamic>>[
        {
          'weight': 270.0,
          'reps': 8,
          'rir': 0.0,
          'date': _asOf.subtract(const Duration(days: 2)),
        },
        {
          'weight': 265.0,
          'reps': 5,
          'rir': 0.0,
          'date': _asOf.subtract(const Duration(days: 9)),
        },
      ];

      final result = PeriodizationModelUtils.addRepsProgressionModel(
        exerciseName: 'Lat Pull Down, Supinated',
        repTarget: 5,
        defaultWeight: 270.0,
        rirValue: 0.0,
        increments: cappedGrid,
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: history,
        weekIndex: 1,
        exerciseId: 'latPullDownSupinatedTestId',
        asOfDate: _asOf,
      );

      expect((result['weight'] as num).toDouble(), 272.5,
          reason: 'indexOf(270.0) missed the capped list, so Add Reps used to '
              'stay at 270 and only add a rep');
      expect((result['reps'] as num).toInt(), 5);
    });

    test('Add Reps keeps the "last weight is off-grid" guard', () {
      // 271.3 is not a member of the 2.5 lattice: the old indexOf returned -1
      // and the model stayed put with +1 rep. That behaviour is unchanged —
      // only the ceiling half of the old guard was removed.
      final history = <Map<String, dynamic>>[
        {
          'weight': 271.3,
          'reps': 8,
          'rir': 0.0,
          'date': _asOf.subtract(const Duration(days: 2)),
        },
        {
          'weight': 265.0,
          'reps': 5,
          'rir': 0.0,
          'date': _asOf.subtract(const Duration(days: 9)),
        },
      ];

      final result = PeriodizationModelUtils.addRepsProgressionModel(
        exerciseName: 'Lat Pull Down, Supinated',
        repTarget: 5,
        defaultWeight: 270.0,
        rirValue: 0.0,
        increments: cappedGrid,
        grid: IncrementGrid(primary: 2.5),
        topSetHistory: history,
        weekIndex: 1,
        exerciseId: 'latPullDownSupinatedTestId',
        asOfDate: _asOf,
      );

      expect((result['weight'] as num).toDouble(), 271.3);
      expect((result['reps'] as num).toInt(), 9);
    });

    test('Smart Progression centres above the ceiling on a secondary grid', () {
      final result = PeriodizationModelUtils.smartProgressionModel(
        exerciseName: 'Lat Pull Down, Supinated',
        repTarget: 3,
        defaultWeight: 245.0,
        rirValue: 1.5,
        increments: _legacyGrid(2.5, 1.25),
        grid: IncrementGrid(primary: 2.5, secondary: 1.25),
        topSetHistory: _historyWithBaseE1RM(299.0),
        weekIndex: 1,
        exerciseId: 'latPullDownSupinatedTestId',
        asOfDate: _asOf,
      );

      final double w = (result['weight'] as num).toDouble();
      // With the 1.25 offset available, the neighbourhood around the 269.93
      // centre is 268.75 / 270.0 / 271.25 — all valid, all above the ceiling.
      expect(IncrementGrid(primary: 2.5, secondary: 1.25).contains(w), isTrue);
      expect(w, greaterThan(247.5));
      expect(w, 270.0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Bodyweight ADDED-load snapping uses the same lattice.
  // ───────────────────────────────────────────────────────────────────────────
  group('bodyweight added-weight snapping', () {
    test('added load snaps on the lattice, clamps at zero, has no ceiling', () {
      final g = IncrementGrid(primary: 2.5);
      // Added load is snapped in display-added units before conversion to
      // absolute; the same grid, and the same non-negative clamp.
      expect(g.snap(-12.0), 0.0);
      expect(g.snap(0.4), 0.0);
      expect(g.snap(61.3), 62.5);
      expect(g.snap(262.4), 262.5);
      expect(g.next(250.0), 252.5);
    });

    test('the engine snaps every path (incl. bodyweight ADDED) on the grid',
        () {
      final src = File('lib/progression_engine.dart').readAsStringSync();
      expect(src, contains('incGrid.snap('));
      expect(src, isNot(contains('_incOpts.reduce(')),
          reason: 'no engine path may snap by scanning a finite list — the '
              'model grid and the final overlay must be the same lattice');
    });

    test('no progression model materialises a 100-position grid any more', () {
      final src = File('lib/periodization_model_utils.dart').readAsStringSync();
      int bodyStart(String signature) {
        final i = src.indexOf(signature);
        expect(i, isNonNegative, reason: 'signature not found: $signature');
        return i;
      }

      for (final signature in <String>[
        'static double getProgressedWeight({',
        'static Map<String, dynamic> smartProgressionModel({',
        'static Map<String, dynamic> addRepsProgressionModel({',
        'static Map<String, dynamic> getWeightByProgressionModel({',
      ]) {
        final start = bodyStart(signature);
        final end =
            src.indexOf(RegExp(r'\n  static '), start + signature.length);
        final body = src.substring(start, end == -1 ? src.length : end);
        expect(body, isNot(contains('i < 100')),
            reason: '$signature must not generate a finite weight grid');
        expect(body, isNot(contains('increments[0]')),
            reason: '$signature must not treat increments[0] as the primary '
                'step size — the list holds absolute weights and starts at 0');
      }
    });
  });
}
