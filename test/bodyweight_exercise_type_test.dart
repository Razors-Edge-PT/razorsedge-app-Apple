// A `Body Weight` catalogue TYPE makes an exercise bodyweight-loaded, and a
// bodyweight set's stored `0` is a real set at "0 kg added".
//
// Two independent rules meet here:
//
//   CLASSIFICATION — an exercise is bodyweight-loaded when its id/name is in
//   the hard-coded catalogue (unchanged, backward compatible) OR its catalogue
//   `type` is "Body Weight" (trimmed, case-insensitive). Never its name,
//   category or body parts.
//
//   RAW SET VALIDITY — WES2 stores what the athlete TYPED, so on a bodyweight
//   exercise a stored `0` means 0 kg ADDED: a real set at their own
//   bodyweight, whose TOTAL load is that bodyweight. On every other exercise a
//   stored 0 still means nothing logged, and a NEGATIVE weight is invalid on
//   every exercise.
//
// The exercise that motivated this ("Jump chin up") is deliberately never
// named here: it must qualify through its stored `type` alone, and the test
// below proves it is in neither hard-coded list.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/bodyweight_load.dart';
import 'package:localtest222/exercise_type.dart';
import 'package:localtest222/home_v2_calendar_service.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/core/showcase_reducer.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';

/// An exercise in NEITHER hard-coded list — it can only qualify by type.
const String kTypedId = 'typed-bw-exercise-id-01';
const String kTypedName = 'Some Untracked Movement';

const String kChinId = 'XM9026peNIu0R8qh7UqY';
const String kChinName = 'Chin-Up';
const String kBenchId = 'AmfUWbF1DH3I7qPAdh5k';
const String kBenchName = 'Bench Press, Barbell';

const String kUid = 'athlete-type-1';

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// A WES2 set: `setIndex` stamped, `weight` = the ADDED load.
Map<String, dynamic> wes2Set(num added, int reps, {int i = 0, double rir = 1}) =>
    <String, dynamic>{
      'setIndex': i,
      'weight': added,
      'reps': reps,
      'rir': rir,
    };

/// A legacy set: `weight` = the TOTAL, typed added load beside it.
Map<String, dynamic> legacySet(num total, num added, int reps,
        {double rir = 1}) =>
    <String, dynamic>{
      'weight': total,
      'weightAdded': added,
      'reps': reps,
      'rir': rir,
    };

Map<String, dynamic> workoutDoc(
  DateTime date,
  String id,
  String name,
  List<Map<String, dynamic>> sets, {
  String? type,
}) =>
    <String, dynamic>{
      'date': _ymd(date),
      '_uid': kUid,
      'exercises': <Map<String, dynamic>>[
        <String, dynamic>{
          'exerciseId': id,
          'name': name,
          if (type != null) 'type': type,
          'sets': sets,
        },
      ],
    };

void recordBodyweight(DateTime day, double kg) {
  PeriodizationModelUtils.setBodyweightHistory(
    uid: kUid,
    entries: <Map<String, dynamic>>[
      <String, dynamic>{
        'date': DateTime(day.year, day.month, day.day, 12),
        'weight': kg,
        'unit': 'kg',
      },
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ExerciseTypeRegistry.clear();
    PeriodizationModelUtils.clearHistorySnapshot();
    PeriodizationModelUtils.setBodyweightHistory(
        uid: kUid, entries: const <Map<String, dynamic>>[]);
  });

  tearDown(ExerciseTypeRegistry.clear);

  // ── 1. The hard-coded catalogue still stands on its own ──────────────────

  group('hard-coded catalogue (no type available)', () {
    test('a catalogue id still classifies with no type at all', () {
      expect(
        PeriodizationModelUtils.isBodyweightExercise(id: kChinId),
        isTrue,
      );
      expect(
        PeriodizationModelUtils.isBodyweightExercise(
            id: kChinId, name: 'renamed beyond recognition'),
        isTrue,
      );
    });

    test('a catalogue display name still classifies with no id and no type',
        () {
      expect(
        PeriodizationModelUtils.isBodyweightExercise(name: ' Chin-Up '),
        isTrue,
      );
      expect(
        PeriodizationModelUtils.isBodyweightExercise(name: 'TRICEPS DIP'),
        isTrue,
      );
    });

    test('an explicit non-bodyweight type never overrides a catalogue id', () {
      // The hard-coded lists are a FALLBACK, not a veto: an exercise in them
      // stays bodyweight whatever else it carries, so existing history cannot
      // change interpretation because a `type` was filled in later.
      expect(
        PeriodizationModelUtils.isBodyweightExercise(
            id: kChinId, name: kChinName, type: 'Barbell'),
        isTrue,
      );
    });

    test('an ordinary exercise is not bodyweight', () {
      expect(
        PeriodizationModelUtils.isBodyweightExercise(
            id: kBenchId, name: kBenchName),
        isFalse,
      );
    });
  });

  // ── 2-4. Type-derived classification ─────────────────────────────────────

  group('catalogue type', () {
    test('an otherwise unknown exercise with type "Body Weight" qualifies', () {
      expect(
        PeriodizationModelUtils.isBodyweightExercise(
            id: kTypedId, name: kTypedName, type: 'Body Weight'),
        isTrue,
      );
    });

    test('matching is trimmed and case-insensitive', () {
      for (final String t in <String>[
        'Body Weight',
        '  Body Weight  ',
        'body weight',
        'BODY WEIGHT',
        '\tBoDy WeIgHt\n',
      ]) {
        expect(isBodyweightExerciseType(t), isTrue, reason: 'type "$t"');
        expect(
          PeriodizationModelUtils.isBodyweightExercise(
              id: kTypedId, name: kTypedName, type: t),
          isTrue,
          reason: 'type "$t"',
        );
      }
    });

    test('other types do not classify as bodyweight', () {
      for (final String t in <String>[
        'Barbell',
        'Dumbbell',
        'Machine',
        'Cable Stack',
        'Suspension System',
        'Bodyweight', // one word is NOT the catalogue value
        'Body  Weight', // doubled inner space is NOT the catalogue value
        'Body Weighted',
        '',
        '   ',
      ]) {
        expect(isBodyweightExerciseType(t), isFalse, reason: 'type "$t"');
        expect(
          PeriodizationModelUtils.isBodyweightExercise(
              id: kTypedId, name: kTypedName, type: t),
          isFalse,
          reason: 'type "$t"',
        );
      }
      expect(isBodyweightExerciseType(null), isFalse);
    });

    test('classification is never inferred from name, category or body parts',
        () {
      // Names that SOUND like bodyweight work but are not in the closed list.
      for (final String n in <String>[
        'Bodyweight Squat',
        'Body Weight Row',
        'Assisted Pull-Up Machine',
        'Chin-Up Variation',
      ]) {
        expect(
          PeriodizationModelUtils.isBodyweightExercise(id: 'x-$n', name: n),
          isFalse,
          reason: 'name "$n"',
        );
      }
    });
  });

  // ── 5. The motivating exercise is in neither hard-coded list ─────────────

  test('the hard-coded catalogues name no "jump chin up" variant', () {
    final Set<String> names =
        PeriodizationModelUtils.debugBodyweightExerciseNames;
    for (final String n in names) {
      expect(n.contains('jump'), isFalse,
          reason: 'hard-coded name list must not be extended: "$n"');
    }
    // The classifier must not recognise it by name either.
    for (final String n in <String>[
      'Jump chin up',
      'jump chin up',
      'Jump Chin-Up',
    ]) {
      expect(
        PeriodizationModelUtils.isBodyweightExercise(name: n),
        isFalse,
        reason: '"$n" must qualify through its stored type, not a hard list',
      );
    }
    // …and it must qualify purely from its catalogue type.
    expect(
      PeriodizationModelUtils.isBodyweightExercise(
          id: 'unknown-id', name: 'Jump chin up', type: 'Body Weight'),
      isTrue,
    );
  });

  // ── 6. The type registry (global + custom exercise loading) ──────────────

  group('ExerciseTypeRegistry', () {
    test('a registered type classifies an exercise known only by id', () {
      expect(
        PeriodizationModelUtils.isBodyweightExercise(
            id: kTypedId, name: kTypedName),
        isFalse,
      );
      // What ExerciseCatalog does after reading /exercises/{id} (global) or
      // /users/{uid}/customExercises/{id} (custom) — both funnel through here.
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      expect(
        PeriodizationModelUtils.isBodyweightExercise(
            id: kTypedId, name: kTypedName),
        isTrue,
      );
    });

    test('an explicitly supplied type always beats the cache', () {
      ExerciseTypeRegistry.register(kTypedId, 'Barbell');
      expect(
        PeriodizationModelUtils.isBodyweightExercise(
            id: kTypedId, type: 'Body Weight'),
        isTrue,
        reason: 'a row snapshot must not be overruled by a stale cache',
      );
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      expect(
        PeriodizationModelUtils.isBodyweightExercise(
            id: kTypedId, type: 'Barbell'),
        isFalse,
      );
    });

    test('a blank type removes rather than stores an empty entry', () {
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      ExerciseTypeRegistry.register(kTypedId, '   ');
      expect(ExerciseTypeRegistry.typeOf(kTypedId), isNull);
      expect(
        PeriodizationModelUtils.isBodyweightExercise(id: kTypedId),
        isFalse,
      );
    });

    test('registerAll / missingFrom drive the bounded catalogue fetch', () {
      ExerciseTypeRegistry.registerAll(<String, String?>{
        'a': 'Body Weight',
        'b': 'Barbell',
        'c': null,
      });
      expect(ExerciseTypeRegistry.typeOf('a'), 'Body Weight');
      expect(ExerciseTypeRegistry.typeOf('c'), isNull);
      expect(ExerciseTypeRegistry.missingFrom(<String>['a', 'b', 'c', 'd']),
          unorderedEquals(<String>['c', 'd']));
    });

    test('PeriodizationModelUtils.exerciseTypeById is the same live cache', () {
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      expect(PeriodizationModelUtils.exerciseTypeById[kTypedId], 'Body Weight');
      PeriodizationModelUtils.exerciseTypeById['other'] = 'Machine';
      expect(ExerciseTypeRegistry.typeOf('other'), 'Machine');
    });
  });

  // ── 14. Raw stored-set validity ──────────────────────────────────────────

  group('raw stored-set validity', () {
    test('0 is valid ONLY for a bodyweight exercise', () {
      expect(isStoredWeightPerformed(0, isBodyweight: true), isTrue);
      expect(isStoredWeightPerformed(0, isBodyweight: false), isFalse);
      expect(isStoredWeightPerformed(0.0, isBodyweight: true), isTrue);
    });

    test('negative is invalid everywhere', () {
      expect(isStoredWeightPerformed(-0.5, isBodyweight: true), isFalse);
      expect(isStoredWeightPerformed(-0.5, isBodyweight: false), isFalse);
      expect(isStoredWeightPerformed(-100, isBodyweight: true), isFalse);
    });

    test('positive is valid everywhere; absent and non-finite never are', () {
      expect(isStoredWeightPerformed(60, isBodyweight: true), isTrue);
      expect(isStoredWeightPerformed(60, isBodyweight: false), isTrue);
      expect(isStoredWeightPerformed(null, isBodyweight: true), isFalse);
      expect(isStoredWeightPerformed(double.nan, isBodyweight: true), isFalse);
      expect(
          isStoredWeightPerformed(double.infinity, isBodyweight: true), isFalse);
    });

    test('reps must remain positive whatever the weight', () {
      expect(
          isRawSetPerformed(weightKg: 0, reps: 5, isBodyweight: true), isTrue);
      expect(
          isRawSetPerformed(weightKg: 0, reps: 0, isBodyweight: true), isFalse);
      expect(
          isRawSetPerformed(weightKg: 0, reps: -3, isBodyweight: true), isFalse);
      expect(isRawSetPerformed(weightKg: 60, reps: null, isBodyweight: false),
          isFalse);
    });
  });

  // ── The normalisation contract (WES2 vs legacy bases) ────────────────────

  group('normalisation of a bodyweight set', () {
    test('WES2 stored 0 becomes a TOTAL equal to the recorded bodyweight', () {
      final double? total = totalLoadKg(
        basis: BodyweightLoadBasis.ofSetMap(wes2Set(0, 5)),
        storedKg: 0,
        bodyweightKg: 82.5,
      );
      expect(total, 82.5);
    });

    test('WES2 stored positive becomes bodyweight PLUS the added load', () {
      final double? total = totalLoadKg(
        basis: BodyweightLoadBasis.ofSetMap(wes2Set(20, 5)),
        storedKg: 20,
        bodyweightKg: 82.5,
      );
      expect(total, 102.5);
    });

    test('a legacy set keeps the existing normalisation', () {
      // Total stored, typed added beside it → total = typed + bodyweight.
      final Map<String, dynamic> s = legacySet(138.5, 53.5, 3);
      expect(BodyweightLoadBasis.ofSetMap(s), BodyweightLoadBasis.absolute);
      expect(
        totalLoadKg(
          basis: BodyweightLoadBasis.ofSetMap(s),
          storedKg: 138.5,
          typedAddedKg: typedAddedKgOf(s),
          bodyweightKg: 85,
        ),
        138.5, // 53.5 typed + 85 recorded
      );
      // No typed added load → the stored value IS the total, unchanged.
      expect(
        totalLoadKg(
          basis: BodyweightLoadBasis.absolute,
          storedKg: 138.5,
          bodyweightKg: 85,
        ),
        138.5,
      );
    });

    test('a WES2 set with no qualifying weigh-in has an UNKNOWN total', () {
      expect(
        totalLoadKg(
          basis: BodyweightLoadBasis.added,
          storedKg: 0,
          bodyweightKg: null,
        ),
        isNull,
        reason: 'omit rather than guess — never a default bodyweight',
      );
    });
  });

  // ── 9. Progression history ───────────────────────────────────────────────

  group('progression history', () {
    test('a zero-added bodyweight day enters history at the total load', () {
      final DateTime day = DateTime(2026, 9, 10);
      recordBodyweight(day.subtract(const Duration(days: 1)), 80);
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: kUid,
        workouts: <Map<String, dynamic>>[
          workoutDoc(day, kTypedId, kTypedName,
              <Map<String, dynamic>>[wes2Set(0, 8)],
              type: 'Body Weight'),
        ],
      );
      final List<Map<String, dynamic>> hist =
          PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kTypedId,
        exerciseName: kTypedName,
      );
      expect(hist, hasLength(1));
      expect(hist.single['weight'], 80.0);
      expect(hist.single['reps'], 8.0);
    });

    test('the type snapshot alone classifies a reloaded/offline workout', () {
      // No registry entry at all — only what the workout row itself stores.
      expect(ExerciseTypeRegistry.typeOf(kTypedId), isNull);
      final DateTime day = DateTime(2026, 9, 10);
      recordBodyweight(day, 80);
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: kUid,
        workouts: <Map<String, dynamic>>[
          workoutDoc(day, kTypedId, kTypedName,
              <Map<String, dynamic>>[wes2Set(0, 8)],
              type: 'Body Weight'),
        ],
      );
      expect(
        PeriodizationModelUtils.resolveTopSetHistory(
                exerciseId: kTypedId, exerciseName: kTypedName)
            .single['weight'],
        80.0,
      );
    });

    test('an ordinary exercise\'s zero-weight set is still excluded', () {
      final DateTime day = DateTime(2026, 9, 10);
      recordBodyweight(day, 80);
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: kUid,
        workouts: <Map<String, dynamic>>[
          workoutDoc(day, kBenchId, kBenchName,
              <Map<String, dynamic>>[wes2Set(0, 8)]),
        ],
      );
      expect(
        PeriodizationModelUtils.resolveTopSetHistory(
            exerciseId: kBenchId, exerciseName: kBenchName),
        isEmpty,
      );
    });

    test('a NEGATIVE bodyweight stored weight is excluded', () {
      final DateTime day = DateTime(2026, 9, 10);
      recordBodyweight(day, 80);
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: kUid,
        workouts: <Map<String, dynamic>>[
          workoutDoc(day, kTypedId, kTypedName,
              <Map<String, dynamic>>[wes2Set(-5, 8)],
              type: 'Body Weight'),
        ],
      );
      expect(
        PeriodizationModelUtils.resolveTopSetHistory(
            exerciseId: kTypedId, exerciseName: kTypedName),
        isEmpty,
      );
    });

    test('with no qualifying weigh-in the day is omitted, never guessed', () {
      final DateTime day = DateTime(2026, 9, 10);
      // The only weigh-in is AFTER the lift.
      recordBodyweight(day.add(const Duration(days: 3)), 80);
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: kUid,
        workouts: <Map<String, dynamic>>[
          workoutDoc(day, kTypedId, kTypedName,
              <Map<String, dynamic>>[wes2Set(0, 8)],
              type: 'Body Weight'),
        ],
      );
      expect(
        PeriodizationModelUtils.resolveTopSetHistory(
            exerciseId: kTypedId, exerciseName: kTypedName),
        isEmpty,
        reason: 'no default bodyweight may enter historical analytics',
      );
    });

    test('a missing weight field is not "0 kg added"', () {
      final DateTime day = DateTime(2026, 9, 10);
      recordBodyweight(day, 80);
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: kUid,
        workouts: <Map<String, dynamic>>[
          workoutDoc(day, kTypedId, kTypedName, <Map<String, dynamic>>[
            <String, dynamic>{'setIndex': 0, 'reps': 8, 'rir': 1},
          ], type: 'Body Weight'),
        ],
      );
      expect(
        PeriodizationModelUtils.resolveTopSetHistory(
            exerciseId: kTypedId, exerciseName: kTypedName),
        isEmpty,
      );
    });

    test('16. non-bodyweight history is unchanged', () {
      final DateTime day = DateTime(2026, 9, 10);
      PeriodizationModelUtils.applyHistorySnapshot(
        uid: kUid,
        workouts: <Map<String, dynamic>>[
          workoutDoc(day, kBenchId, kBenchName, <Map<String, dynamic>>[
            wes2Set(100, 5),
            wes2Set(110, 5, i: 1),
          ]),
        ],
      );
      final List<Map<String, dynamic>> hist =
          PeriodizationModelUtils.resolveTopSetHistory(
        exerciseId: kBenchId,
        exerciseName: kBenchName,
      );
      expect(hist, hasLength(1));
      expect(hist.single['weight'], 110.0);
    });
  });

  // ── 11. Calendar completion ──────────────────────────────────────────────

  group('calendar / workout completed-state detection', () {
    Map<String, dynamic> dayDoc(String id, String name, num weight,
            {String? type}) =>
        <String, dynamic>{
          'exercises': <Map<String, dynamic>>[
            <String, dynamic>{
              'exerciseId': id,
              'name': name,
              if (type != null) 'type': type,
              'sets': <Map<String, dynamic>>[
                <String, dynamic>{'setIndex': 0, 'weight': weight, 'reps': 6},
              ],
            },
          ],
        };

    test('a zero-added bodyweight day counts as completed (by type)', () {
      expect(
        HomeV2CalendarService.debugHasCompletedSets(
            dayDoc(kTypedId, kTypedName, 0, type: 'Body Weight')),
        isTrue,
      );
    });

    test('a zero-added bodyweight day counts as completed (hard-coded id)', () {
      expect(
        HomeV2CalendarService.debugHasCompletedSets(dayDoc(kChinId, kChinName, 0)),
        isTrue,
      );
    });

    test('a zero-weight ordinary day does NOT count as completed', () {
      expect(
        HomeV2CalendarService.debugHasCompletedSets(
            dayDoc(kBenchId, kBenchName, 0)),
        isFalse,
      );
    });

    test('a negative bodyweight day does NOT count as completed', () {
      expect(
        HomeV2CalendarService.debugHasCompletedSets(
            dayDoc(kTypedId, kTypedName, -10, type: 'Body Weight')),
        isFalse,
      );
    });

    test('an ordinary positive day still counts (unchanged)', () {
      expect(
        HomeV2CalendarService.debugHasCompletedSets(
            dayDoc(kBenchId, kBenchName, 100)),
        isTrue,
      );
    });
  });

  // ── 7. Type survives WES2 copying, JSON/draft and Firestore round trips ──

  group('type round trips', () {
    Wes2ExerciseRow row({String? type}) => Wes2ExerciseRow(
          exerciseId: kTypedId,
          name: kTypedName,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 1,
          sets: const <Wes2SetState>[
            Wes2SetState(
              setIndex: 0,
              weight: Wes2FieldState<double>(actualValue: 0),
              reps: Wes2FieldState<int>(actualValue: 8),
            ),
          ],
          source: Wes2RowSource.wes2Manual,
          exerciseType: type,
        );

    test('copyWith preserves the type, and can set it', () {
      expect(row(type: 'Body Weight').copyWith(setCount: 4).exerciseType,
          'Body Weight');
      expect(row().copyWith(exerciseType: 'Body Weight').exerciseType,
          'Body Weight');
      expect(row(type: 'Body Weight').copyWith().exerciseType, 'Body Weight');
    });

    test('local JSON draft round trip keeps the type', () {
      final Wes2ExerciseRow restored =
          Wes2ExerciseRow.fromJson(row(type: 'Body Weight').toJson());
      expect(restored.exerciseType, 'Body Weight');
      expect(restored.exerciseId, kTypedId);
      expect(restored.sets.single.weight.actualValue, 0.0);
    });

    test('a row with no type serialises exactly as it always did', () {
      expect(row().toJson().containsKey('type'), isFalse);
      expect(Wes2ExerciseRow.fromJson(row().toJson()).exerciseType, isNull);
    });

    test('a blank stored type reads back as "unknown", not as a blank', () {
      final Map<String, dynamic> json = row().toJson()..['type'] = '   ';
      expect(Wes2ExerciseRow.fromJson(json).exerciseType, isNull);
    });

    test('the Firestore row map carries the type snapshot', () {
      final Map<String, dynamic> m = FirestoreWes2Repository.buildRowMapForTest(
          row(type: 'Body Weight'));
      expect(m['type'], 'Body Weight');
      expect(m['exerciseId'], kTypedId);
      expect((m['sets'] as List).single['weight'], 0.0);
    });

    test('a surgical patch ADDS a missing type and preserves every other field',
        () {
      final Map<String, dynamic> stored = <String, dynamic>{
        'exerciseId': kTypedId,
        'name': kTypedName,
        'circuitIndex': 2,
        'orderIndex': 7,
        'setCount': 3,
        'isMarkedDone': true,
        'exerciseExecutionNote': 'felt strong',
        'sets': <Map<String, dynamic>>[
          <String, dynamic>{'setIndex': 0, 'weight': 0, 'reps': 8},
        ],
      };
      final Map<String, dynamic> patched =
          FirestoreWes2Repository.withExerciseTypeForTest(
              stored, 'Body Weight');
      expect(patched['type'], 'Body Weight');
      for (final String k in stored.keys) {
        expect(patched[k], stored[k], reason: 'field "$k" must be preserved');
      }
    });

    test('a surgical patch never overwrites a type already stored', () {
      final Map<String, dynamic> stored = <String, dynamic>{
        'exerciseId': kTypedId,
        'type': 'Barbell',
      };
      expect(
        FirestoreWes2Repository.withExerciseTypeForTest(
            stored, 'Body Weight')['type'],
        'Barbell',
      );
    });

    test('a surgical patch with no known type leaves the row untouched', () {
      final Map<String, dynamic> stored = <String, dynamic>{
        'exerciseId': kTypedId,
      };
      expect(
        FirestoreWes2Repository.withExerciseTypeForTest(stored, null),
        same(stored),
      );
      expect(
        FirestoreWes2Repository.withExerciseTypeForTest(stored, '  ')
            .containsKey('type'),
        isFalse,
      );
    });
  });

  // ── 10. Shared analytics: showcase reducer raw-set participation ─────────

  group('showcase raw-set participation', () {
    Object workoutWith(String id, String name, num weight) =>
        <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': id,
              'name': name,
              'sets': <Object?>[
                <String, Object?>{'setIndex': 0, 'weight': weight, 'reps': 5},
              ],
            },
          ],
        };

    test('a bodyweight-loaded slot accepts a stored 0 (0 kg added)', () {
      final Map<String, List<ShowcaseSet>> out =
          extractBigFiveSets(workoutWith(kChinId, kChinName, 0));
      expect(out['chinUp'], hasLength(1));
      expect(out['chinUp']!.single.weight, 0);
      expect(out['chinUp']!.single.basis, ShowcaseLoadBasis.added);
    });

    test('an ordinary slot still rejects a stored 0', () {
      expect(extractBigFiveSets(workoutWith(kBenchId, kBenchName, 0)), isEmpty);
    });

    test('a negative weight is rejected on every slot', () {
      expect(extractBigFiveSets(workoutWith(kChinId, kChinName, -5)), isEmpty);
      expect(extractBigFiveSets(workoutWith(kBenchId, kBenchName, -5)), isEmpty);
    });

    test('an ordinary positive set is unchanged', () {
      final Map<String, List<ShowcaseSet>> out =
          extractBigFiveSets(workoutWith(kBenchId, kBenchName, 100));
      expect(out['bench']!.single.weight, 100);
      expect(out['bench']!.single.basis, isNull);
    });

    test('only the bodyweight-loaded Big Five slot carries the flag', () {
      expect(isBodyweightLoadedSlot('chinUp'), isTrue);
      expect(isBodyweightLoadedSlot('bench'), isFalse);
    });
  });
}
