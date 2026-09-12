// Focused regression coverage for the analytics velocity feature added to
// lib/exercise_details_screen.dart (E1RM/Velocity metric selector, dependent
// reps/load dropdowns, per-day maximum velocity, and ID-first exercise
// identity). All pure helpers — no Firebase/UserContext harness needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/exercise_details_screen.dart';

VelocitySample sample(
        DateTime date, int reps, double weight, double velocity) =>
    VelocitySample(date: date, reps: reps, weight: weight, velocity: velocity);

void main() {
  group('exerciseEntryMatches — ID-first exercise identity', () {
    test('an entry with an id matches only that exact id', () {
      expect(
        exerciseEntryMatches('abc', 'Bench Press',
            targetId: 'abc', targetName: 'Bench Press'),
        isTrue,
      );
    });

    test(
        'a same-named entry with a DIFFERENT id never matches — a name match must not override a conflicting id',
        () {
      expect(
        exerciseEntryMatches('other-id', 'Bench Press',
            targetId: 'target-id', targetName: 'Bench Press'),
        isFalse,
      );
    });

    test('an entry with no id at all falls back to a name match (legacy data)',
        () {
      expect(
        exerciseEntryMatches(null, 'Bench Press',
            targetId: 'target-id', targetName: 'Bench Press'),
        isTrue,
      );
      expect(
        exerciseEntryMatches('', 'Bench Press',
            targetId: 'target-id', targetName: 'Bench Press'),
        isTrue,
      );
    });

    test('an entry with no id and a non-matching name does not match', () {
      expect(
        exerciseEntryMatches(null, 'Squat',
            targetId: 'target-id', targetName: 'Bench Press'),
        isFalse,
      );
    });

    test('searching with no target id relies on name for both sides', () {
      expect(
        exerciseEntryMatches(null, 'Bench Press',
            targetId: null, targetName: 'Bench Press'),
        isTrue,
      );
      expect(
        exerciseEntryMatches('some-id', 'Bench Press',
            targetId: null, targetName: 'Bench Press'),
        isFalse,
        reason:
            'the entry carries a real id, so an empty/absent target id must not match it by name',
      );
    });
  });

  group('ExerciseHistoryOption — identity key', () {
    test('two options with the same id are equal regardless of name', () {
      const a = ExerciseHistoryOption(id: 'x1', name: 'Bench Press');
      const b = ExerciseHistoryOption(id: 'x1', name: 'Bench Press (renamed)');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('two id-less options are keyed by name (case-insensitive)', () {
      const a = ExerciseHistoryOption(id: null, name: 'Bench Press');
      const b = ExerciseHistoryOption(id: null, name: 'bench press');
      expect(a, b);
    });

    test('an id-bearing option never equals an id-less option of the same name',
        () {
      const a = ExerciseHistoryOption(id: 'x1', name: 'Bench Press');
      const b = ExerciseHistoryOption(id: null, name: 'Bench Press');
      expect(a, isNot(b));
    });
  });

  group('normalizeLoadForGrouping', () {
    test('absorbs floating-point representation noise', () {
      expect(normalizeLoadForGrouping(82.5),
          normalizeLoadForGrouping(82.49999999999999));
    });

    test('preserves genuinely distinct loads — never plate-rounds', () {
      expect(normalizeLoadForGrouping(82.5),
          isNot(normalizeLoadForGrouping(82.7)));
      expect(normalizeLoadForGrouping(100.1),
          isNot(normalizeLoadForGrouping(100.2)));
    });
  });

  group('VelocityCombinations.fromSamples', () {
    test('only offers combinations backed by actual recorded velocity data',
        () {
      final combos = VelocityCombinations.fromSamples([
        sample(DateTime(2026, 1, 1), 1, 100.0, 0.35),
        sample(DateTime(2026, 1, 8), 3, 80.0, 0.55),
      ]);
      expect(combos.reps, [1, 3]);
      expect(combos.weightsByReps[1], [100.0]);
      expect(combos.weightsByReps[3], [80.0]);
    });

    test('isEligible matches the exact combination, ignoring float noise only',
        () {
      final combos = VelocityCombinations.fromSamples([
        sample(DateTime(2026, 1, 1), 1, 100.0, 0.35),
      ]);
      expect(combos.isEligible(1, 100.0), isTrue);
      expect(combos.isEligible(1, 99.99999999999999), isTrue);
      expect(combos.isEligible(1, 102.5), isFalse);
      expect(combos.isEligible(5, 100.0), isFalse);
    });

    test('no samples means no combinations', () {
      final combos = VelocityCombinations.fromSamples(const []);
      expect(combos.reps, isEmpty);
    });
  });

  group('dailyMaxVelocity — the daily-maximum aggregation rule', () {
    test(
        'takes the FASTEST recorded velocity among every matching set that day, including a set outside the fastest workout\'s selection',
        () {
      final samples = [
        // Two separate workouts/entries the same day, same reps/load.
        sample(DateTime(2026, 3, 1), 1, 100.0, 0.30),
        sample(DateTime(2026, 3, 1), 1, 100.0, 0.42), // the fastest of the day
        sample(DateTime(2026, 3, 1), 1, 100.0, 0.38),
      ];
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100.0);
      expect(points, [VelocityPoint(DateTime(2026, 3, 1), 0.42)]);
    });

    test(
        'exact reps AND load must both match — different reps or loads never blend into one line',
        () {
      final samples = [
        sample(DateTime(2026, 3, 1), 1, 100.0, 0.40),
        sample(DateTime(2026, 3, 1), 3, 100.0, 0.60), // different reps
        sample(DateTime(2026, 3, 1), 1, 90.0, 0.55), // different load
      ];
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100.0);
      expect(points, [VelocityPoint(DateTime(2026, 3, 1), 0.40)]);
    });

    test(
        'one series is one exercise + one rep count + one load, across many weeks',
        () {
      final samples = [
        sample(DateTime(2026, 1, 1), 1, 100.0, 0.30),
        sample(DateTime(2026, 2, 1), 1, 100.0, 0.32),
        sample(DateTime(2026, 3, 1), 3, 80.0,
            0.55), // a different selection entirely
      ];
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100.0);
      expect(points.map((p) => p.date),
          [DateTime(2026, 1, 1), DateTime(2026, 2, 1)]);
    });

    test(
        'excludes invalid, absent, or non-positive velocities rather than treating them as zero',
        () {
      final samples = [
        sample(DateTime(2026, 3, 1), 1, 100.0, 0.0),
        sample(DateTime(2026, 3, 1), 1, 100.0, -0.5),
        sample(DateTime(2026, 3, 1), 1, 100.0, double.nan),
        sample(DateTime(2026, 3, 1), 1, 100.0, double.infinity),
      ];
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100.0);
      expect(points, isEmpty);
    });

    test(
        'accepts three-decimal recorded values without collapsing distinct readings',
        () {
      final samples = [
        sample(DateTime(2026, 3, 1), 1, 100.0, 0.256),
        sample(DateTime(2026, 3, 2), 1, 100.0, 0.258),
      ];
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100.0);
      expect(points.map((p) => p.velocity), [0.256, 0.258]);
    });

    test('an empty combination is safe and returns no points', () {
      expect(
          dailyMaxVelocity(samples: const [], reps: 1, weight: 100.0), isEmpty);
    });

    test('a single matching day is a valid one-point series', () {
      final points = dailyMaxVelocity(
        samples: [sample(DateTime(2026, 3, 1), 1, 100.0, 0.4)],
        reps: 1,
        weight: 100.0,
      );
      expect(points.length, 1);
    });

    test('chronological ordering is preserved regardless of input order', () {
      final samples = [
        sample(DateTime(2026, 3, 10), 1, 100.0, 0.30),
        sample(DateTime(2026, 3, 1), 1, 100.0, 0.31),
        sample(DateTime(2026, 3, 5), 1, 100.0, 0.32),
      ];
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100.0);
      expect(points.map((p) => p.date),
          [DateTime(2026, 3, 1), DateTime(2026, 3, 5), DateTime(2026, 3, 10)]);
    });
  });

  group('VelocityAxisScale — velocity-appropriate scaling, not kg-oriented',
      () {
    test('the empty placeholder is sized for m/s values, not kilograms', () {
      expect(VelocityAxisScale.empty.maxY, lessThanOrEqualTo(2.0),
          reason:
              'ChartAxisScale.empty (0-20, interval 5) would be wildly wrong for velocity');
    });

    test('a realistic velocity spread produces a tight, readable axis', () {
      final s = VelocityAxisScale.fromValues([0.30, 0.35, 0.42, 0.38]);
      expect(s.maxY, greaterThan(s.minY));
      expect(s.maxY, lessThan(1.0));
      expect(s.minY, greaterThanOrEqualTo(0.0));
    });

    test('never goes negative', () {
      final s = VelocityAxisScale.fromValues([0.02, 0.03]);
      expect(s.minY, greaterThanOrEqualTo(0.0));
    });

    test('format always keeps three decimals, matching recorded precision', () {
      const s = VelocityAxisScale(minY: 0, maxY: 1, interval: 0.2);
      expect(s.format(0.4), '0.400');
      expect(s.format(0.256), '0.256');
    });

    test('a single point still gets a non-collapsed axis', () {
      final s = VelocityAxisScale.fromValues([0.4]);
      expect(s.maxY, greaterThan(s.minY));
    });

    test('no points falls back to the empty placeholder', () {
      expect(VelocityAxisScale.fromValues(const []), VelocityAxisScale.empty);
    });
  });
}
