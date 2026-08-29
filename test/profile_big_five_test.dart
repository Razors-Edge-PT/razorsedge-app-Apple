import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/big_five.dart';

/// Which exercises may claim a showcase slot, and — just as important — which
/// may not. The catalogue is full of near-namesakes ("Larsen Bench Press",
/// "Back Squat, Low bar", "Sumo Deadlift", "Pull-Up"), and a slot claimed by
/// the wrong one would put a number on someone's profile they never lifted.
void main() {
  const String bench = 'AmfUWbF1DH3I7qPAdh5k';
  const String squat = 'heeBViVINHO6tUScSd6y';
  const String deadlift = 'MsGl7e9yanDeEnYX0e4X';
  const String chinUp = 'XM9026peNIu0R8qh7UqY';
  const String ohp = 'RdsGazgdH0xgpjek0n3u';

  group('the five slots', () {
    test('are exactly the five lifts, in display order', () {
      expect(
        kBigFive.map((BigFiveLift l) => l.slot),
        <String>['bench', 'squat', 'deadlift', 'chinUp', 'ohpUnilateral'],
      );
      expect(BigFiveSlot.ordered, kBigFive.map((BigFiveLift l) => l.slot));
    });

    test('carry the audited catalogue ids', () {
      expect(
        kBigFive.map((BigFiveLift l) => l.exerciseId),
        <String>[bench, squat, deadlift, chinUp, ohp],
      );
    });

    test('name the lifts the way the catalogue does', () {
      expect(
        kBigFive.map((BigFiveLift l) => l.displayName),
        <String>[
          'Bench Press, Barbell',
          'Back Squat, Barbell',
          'Deadlift, Conventional',
          'Chin-Up',
          'Overhead Dumbbell Press, Unilateral',
        ],
      );
    });

    test('resolve by slot key', () {
      expect(bigFiveBySlot(BigFiveSlot.bench)!.exerciseId, bench);
      expect(bigFiveBySlot('notALift'), isNull);
    });
  });

  group('matching by stable id', () {
    test('the exact catalogue id matches', () {
      expect(matchBigFive(rawId: bench)!.slot, BigFiveSlot.bench);
      expect(matchBigFive(rawId: squat)!.slot, BigFiveSlot.squat);
      expect(matchBigFive(rawId: deadlift)!.slot, BigFiveSlot.deadlift);
      expect(matchBigFive(rawId: chinUp)!.slot, BigFiveSlot.chinUp);
      expect(matchBigFive(rawId: ohp)!.slot, BigFiveSlot.ohpUnilateral);
    });

    test('ids are case-folded, reuniting the 2026 lowercased-id history', () {
      // Production wrote lowercased copies of catalogue ids between
      // 2026-03-03 and 2026-05-07. Without folding, one lift's history splits
      // into two streams and the heavier half disappears from the showcase.
      expect(matchBigFive(rawId: bench.toLowerCase())!.slot, BigFiveSlot.bench);
      expect(matchBigFive(rawId: bench.toUpperCase())!.slot, BigFiveSlot.bench);
      expect(matchBigFive(rawId: squat.toLowerCase())!.slot, BigFiveSlot.squat);
    });

    test('surrounding whitespace is ignored', () {
      expect(matchBigFive(rawId: '  $bench  ')!.slot, BigFiveSlot.bench);
    });

    test('the legacy `id` field is accepted wherever `exerciseId` would be',
        () {
      expect(foldExerciseId(bench), bench.toLowerCase());
      expect(foldExerciseId('   '), isNull);
      expect(foldExerciseId(null), isNull);
      expect(foldExerciseId(42), isNull);
    });
  });

  group('matching id-less legacy rows by name', () {
    test('accepts the exact canonical names', () {
      expect(matchBigFive(rawName: 'Bench Press, Barbell')!.slot,
          BigFiveSlot.bench);
      expect(matchBigFive(rawName: 'Back Squat, Barbell')!.slot,
          BigFiveSlot.squat);
      expect(matchBigFive(rawName: 'Deadlift, Conventional')!.slot,
          BigFiveSlot.deadlift);
      expect(matchBigFive(rawName: 'Chin-Up')!.slot, BigFiveSlot.chinUp);
      expect(matchBigFive(rawName: 'Overhead Dumbbell Press, Unilateral')!.slot,
          BigFiveSlot.ohpUnilateral);
    });

    test('accepts the short pre-catalogue names the app once wrote', () {
      expect(matchBigFive(rawName: 'Bench Press')!.slot, BigFiveSlot.bench);
      expect(matchBigFive(rawName: 'Back Squat')!.slot, BigFiveSlot.squat);
      expect(matchBigFive(rawName: 'Deadlift')!.slot, BigFiveSlot.deadlift);
      expect(matchBigFive(rawName: 'Chin Up')!.slot, BigFiveSlot.chinUp);
    });

    test('is case and whitespace insensitive but still EXACT', () {
      expect(matchBigFive(rawName: '  bench press, barbell ')!.slot,
          BigFiveSlot.bench);
      // Not a prefix or substring match.
      expect(matchBigFive(rawName: 'Bench Press, Barbell (paused)'), isNull);
      expect(matchBigFive(rawName: 'My Bench Press'), isNull);
    });
  });

  group('rejecting similarly named variants', () {
    test('every near-namesake in the catalogue stays out', () {
      const List<String> mustNotMatch = <String>[
        'Larsen Bench Press',
        'Bench Press, Larsen Press',
        'Bench Press, Narrow Grip',
        'Bench Press, Touch n Go',
        'Bench Press, Pin Press',
        'Bench Press, Banded',
        'Bench Press, Long Pause',
        'Decline Bench Press, Barbell',
        'Decline Dumbbell Bench Press',
        'Back Squat, Low bar',
        'Back Squat, Pin Squat',
        'Back Squat, Paused Squat',
        'Back Squat, Banded',
        'Smith Machine Squat',
        'Sumo Deadlift',
        'Sumo Deadlift, Deficit',
        'Deadlift, Deficit',
        'Romanian Deadlift',
        'Romanian Deadlift, Unilateral',
        'Single Leg Deadlift',
        'Pull-Up',
        'Pull-Up, Wide Arm',
        'Overhead Dumbbell Press',
      ];
      for (final String name in mustNotMatch) {
        expect(matchBigFive(rawName: name), isNull, reason: name);
      }
    });

    test('the bilateral overhead press never fills the unilateral slot', () {
      expect(matchBigFive(rawName: 'Overhead Dumbbell Press'), isNull);
      // Its real catalogue id must not resolve either.
      expect(matchBigFive(rawId: '2yJSfLMfOnNDSeZ7DqZT'), isNull);
    });

    test('a Larsen press logged under the wrong NAME is still rejected', () {
      // A present id always decides. A row carrying Larsen's real id must
      // never be rescued into the bench slot by a mislabelled name.
      expect(
        matchBigFive(rawId: 'YvwK9kwc1hcA2omz1g4r', rawName: 'Bench Press'),
        isNull,
      );
      expect(
        matchBigFive(
            rawId: 'pU7wce56hFDsam53aKDr', rawName: 'Bench Press, Barbell'),
        isNull,
      );
    });

    test('an unknown id is not rescued by a matching name', () {
      expect(matchBigFive(rawId: 'someUnknownId', rawName: 'Deadlift'), isNull);
    });
  });

  group('catalogue agreement', () {
    test('every id and display name matches the exercise catalogue dump', () {
      final File dump = File('assets/exercise_dump_20251109_112626.json');
      expect(dump.existsSync(), isTrue);

      final Map<String, String> byId = <String, String>{};
      void walk(Object? node) {
        if (node is List) {
          for (final Object? child in node) {
            walk(child);
          }
          return;
        }
        if (node is Map) {
          final Object? id = node['id'];
          final Object? name = node['name'];
          if (id is String && name is String) byId[id] = name;
          for (final Object? child in node.values) {
            if (child is Map || child is List) walk(child);
          }
        }
      }

      walk(jsonDecode(dump.readAsStringSync()));

      for (final BigFiveLift lift in kBigFive) {
        expect(byId[lift.exerciseId], lift.displayName,
            reason:
                '${lift.slot} must point at the catalogue exercise it names');
      }
    });

    test('the Functions mirror declares the identical ids and aliases', () {
      final String js =
          File('functions/showcase/big_five.js').readAsStringSync();
      for (final BigFiveLift lift in kBigFive) {
        expect(js, contains("'${lift.exerciseId}'"), reason: lift.slot);
        expect(js, contains("'${lift.displayName}'"), reason: lift.slot);
        for (final String alias in lift.legacyNameAliases) {
          expect(js, contains("'$alias'"), reason: alias);
        }
      }
    });
  });
}
