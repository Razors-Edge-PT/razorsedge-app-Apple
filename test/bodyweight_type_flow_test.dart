// How an exercise's catalogue `type` reaches every surface that classifies it.
//
// The type is resolved ONCE, at the catalogue/I-O boundaries, and then travels
// as data:
//
//   catalogue  →  ExerciseTypeRegistry  →  Wes2ExerciseRow.exerciseType
//                                       →  the saved workout row's `type`
//                                       →  reload / local draft / offline
//                                       →  the shared bodyweight classifier
//
// Each path below is the one a row can enter WES2 through: a planned block, a
// template, the manual picker, an exercise replacement, and a reloaded
// workout. Every one of them must end with a classifiable row, and the row
// must keep its type through the WES2 qualifying-day rule and the shared
// exercise-analytics derivations.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/analytics_history_loader.dart';
import 'package:localtest222/exercise_details_screen.dart';
import 'package:localtest222/exercise_type.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/workout_model.dart';

const String kTypedId = 'typed-bw-exercise-id-02';
const String kTypedName = 'Another Untracked Movement';
const String kBenchId = 'AmfUWbF1DH3I7qPAdh5k';
const String kBenchName = 'Bench Press, Barbell';

bool _classifies(Wes2ExerciseRow r) =>
    PeriodizationModelUtils.isBodyweightExercise(
      id: r.exerciseId,
      name: r.name,
      type: r.exerciseType,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(ExerciseTypeRegistry.clear);
  tearDown(ExerciseTypeRegistry.clear);

  // ── 8. Plan, template, manual picker, replacement and reload paths ───────

  group('a planned-block row', () {
    Map<String, dynamic> plannedRow({String? type}) => <String, dynamic>{
          'exerciseId': kTypedId,
          'name': kTypedName,
          'circuitIndex': 0,
          'orderIndex': 0,
          if (type != null) 'type': type,
          'sets': <Map<String, dynamic>>[
            <String, dynamic>{'weight': 0, 'reps': 8, 'rir': 1},
          ],
        };

    test('picks up the registry type when the plan doc stores none', () {
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      final Wes2ExerciseRow row =
          FirestoreWes2PlanService.parseRowForTest(plannedRow(), 0)!;
      expect(row.exerciseType, 'Body Weight');
      expect(_classifies(row), isTrue);
    });

    test('prefers a type the planner wrote onto the row itself', () {
      ExerciseTypeRegistry.register(kTypedId, 'Barbell');
      final Wes2ExerciseRow row = FirestoreWes2PlanService.parseRowForTest(
          plannedRow(type: 'Body Weight'), 0)!;
      expect(row.exerciseType, 'Body Weight');
      expect(_classifies(row), isTrue);
    });

    test('stays unclassified when nothing knows a type', () {
      final Wes2ExerciseRow row =
          FirestoreWes2PlanService.parseRowForTest(plannedRow(), 0)!;
      expect(row.exerciseType, isNull);
      expect(_classifies(row), isFalse);
      expect(row.source, Wes2RowSource.bb3Planned);
    });
  });

  group('a template-loaded row', () {
    // WES2_template_service builds its rows from the registry and then
    // renumbers them with copyWith(orderIndex:) — the step that would silently
    // drop the type if copyWith stopped carrying it.
    test('keeps its type through the order renumbering pass', () {
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      final List<Wes2ExerciseRow> built = <Wes2ExerciseRow>[
        Wes2ExerciseRow(
          exerciseId: kBenchId,
          name: kBenchName,
          circuitIndex: 0,
          orderIndex: 3,
          setCount: 3,
          source: Wes2RowSource.templateLoaded,
          exerciseType: ExerciseTypeRegistry.typeOf(kBenchId),
        ),
        Wes2ExerciseRow(
          exerciseId: kTypedId,
          name: kTypedName,
          circuitIndex: 0,
          orderIndex: 7,
          setCount: 3,
          source: Wes2RowSource.templateLoaded,
          exerciseType: ExerciseTypeRegistry.typeOf(kTypedId),
        ),
      ]..sort((Wes2ExerciseRow a, Wes2ExerciseRow b) =>
          a.orderIndex.compareTo(b.orderIndex));
      final List<Wes2ExerciseRow> renumbered = List<Wes2ExerciseRow>.generate(
          built.length, (int i) => built[i].copyWith(orderIndex: i));

      expect(renumbered[1].orderIndex, 1);
      expect(renumbered[1].exerciseType, 'Body Weight');
      expect(_classifies(renumbered[1]), isTrue);
      expect(renumbered[0].exerciseType, isNull);
      expect(_classifies(renumbered[0]), isFalse);
    });
  });

  group('a reloaded workout row', () {
    Map<String, dynamic> storedRow({String? type}) => <String, dynamic>{
          'exerciseId': kTypedId,
          'name': kTypedName,
          'circuitIndex': 0,
          'orderIndex': 0,
          'setCount': 1,
          if (type != null) 'type': type,
          'sets': <Map<String, dynamic>>[
            <String, dynamic>{'setIndex': 0, 'weight': 0, 'reps': 8},
          ],
        };

    test('recovers its type from the stored snapshot, with no catalogue', () {
      expect(ExerciseTypeRegistry.typeOf(kTypedId), isNull);
      final Wes2ExerciseRow row = FirestoreWes2Repository.parseRowForTest(
          storedRow(type: 'Body Weight'), Wes2RowSource.completedServer)!;
      expect(row.exerciseType, 'Body Weight');
      expect(_classifies(row), isTrue);
      // The zero-added set survived the reload as an ACTUAL value.
      expect(row.sets.single.weight.actualValue, 0.0);
      expect(row.sets.single.weight.hasActual, isTrue);
    });

    test('falls back to the registry for a row written before the snapshot',
        () {
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      final Wes2ExerciseRow row = FirestoreWes2Repository.parseRowForTest(
          storedRow(), Wes2RowSource.completedServer)!;
      expect(row.exerciseType, 'Body Weight');
      expect(_classifies(row), isTrue);
    });

    test('a row map round trips its type through save and reload', () {
      final Wes2ExerciseRow loaded = FirestoreWes2Repository.parseRowForTest(
          storedRow(type: 'Body Weight'), Wes2RowSource.completedServer)!;
      final Map<String, dynamic> saved =
          FirestoreWes2Repository.buildRowMapForTest(loaded);
      expect(saved['type'], 'Body Weight');
      final Wes2ExerciseRow again = FirestoreWes2Repository.parseRowForTest(
          saved, Wes2RowSource.completedServer)!;
      expect(again.exerciseType, 'Body Weight');
    });
  });

  group('the WES2 controller', () {
    /// A controller in the loaded state with [rows] — the state a manual add
    /// or a replacement actually happens in.
    Wes2SessionController controller([List<Wes2ExerciseRow> rows = const []]) {
      final Wes2SessionController c = Wes2SessionController(DateTime(2026, 9, 10))
        ..initIdentity(
          actorUid: 'actor',
          actingUid: 'actor',
          isCoach: false,
          activeBlockId: 'block-1',
          blockStartDate: DateTime(2026, 9, 1),
          blockEndDate: DateTime(2026, 10, 13),
        );
      c.setRows(rows, c.beginLoad());
      return c;
    }

    test('a manually added exercise carries its registered type', () {
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      final Wes2SessionController c = controller();
      c.addExercise(kTypedId, kTypedName);
      final Wes2ExerciseRow row =
          c.rows.firstWhere((Wes2ExerciseRow r) => r.exerciseId == kTypedId);
      expect(row.exerciseType, 'Body Weight');
      expect(_classifies(row), isTrue);
    });

    test('a replacement carries the NEW exercise\'s type, not the old one\'s',
        () {
      ExerciseTypeRegistry.register(kBenchId, 'Barbell');
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      final Wes2SessionController c = controller();
      c.addExercise(kBenchId, kBenchName);
      c.replaceExercise(
        oldExerciseId: kBenchId,
        newExerciseId: kTypedId,
        newName: kTypedName,
      );
      final Wes2ExerciseRow row = c.rows.single;
      expect(row.exerciseId, kTypedId);
      expect(row.exerciseType, 'Body Weight');
      expect(_classifies(row), isTrue);
    });

    test('a replacement AWAY from a bodyweight exercise stops classifying', () {
      ExerciseTypeRegistry.register(kTypedId, 'Body Weight');
      ExerciseTypeRegistry.register(kBenchId, 'Barbell');
      final Wes2SessionController c = controller();
      c.addExercise(kTypedId, kTypedName);
      c.replaceExercise(
        oldExerciseId: kTypedId,
        newExerciseId: kBenchId,
        newName: kBenchName,
      );
      expect(c.rows.single.exerciseType, 'Barbell');
      expect(_classifies(c.rows.single), isFalse);
    });

    test('applyExerciseTypes stamps rows loaded before the catalogue was read',
        () {
      final Wes2SessionController c = controller(<Wes2ExerciseRow>[
        Wes2ExerciseRow(
          exerciseId: kTypedId,
          name: kTypedName,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 1,
          sets: const <Wes2SetState>[Wes2SetState(setIndex: 0)],
          source: Wes2RowSource.completedServer,
        ),
      ]);
      expect(c.rows.single.exerciseType, isNull);
      expect(
        c.applyExerciseTypes(<String, String>{kTypedId: 'Body Weight'}),
        isTrue,
      );
      expect(c.rows.single.exerciseType, 'Body Weight');
      expect(_classifies(c.rows.single), isTrue);
      // Idempotent: a second pass with the same answer changes nothing.
      expect(
        c.applyExerciseTypes(<String, String>{kTypedId: 'Body Weight'}),
        isFalse,
      );
      // An unrelated id leaves the row alone.
      expect(c.applyExerciseTypes(<String, String>{'other': 'Machine'}),
          isFalse);
    });
  });

  // ── 11. WES2 qualifying-day counting (the shared raw-set rule) ───────────

  group('WES2 qualifying-day counting', () {
    /// The rule WES2._checkQualifyingDate applies, over in-memory rows.
    int qualifyingSets(List<Wes2ExerciseRow> rows) {
      int n = 0;
      for (final Wes2ExerciseRow r in rows) {
        final bool isBw = _classifies(r);
        for (final Wes2SetState s in r.sets) {
          if (isRawSetPerformed(
              weightKg: s.weight.actualValue,
              reps: s.reps.actualValue,
              isBodyweight: isBw)) {
            n++;
          }
        }
      }
      return n;
    }

    Wes2ExerciseRow rowWith(
      String id,
      String name,
      List<double?> weights, {
      String? type,
    }) =>
        Wes2ExerciseRow(
          exerciseId: id,
          name: name,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: weights.length,
          sets: <Wes2SetState>[
            for (int i = 0; i < weights.length; i++)
              Wes2SetState(
                setIndex: i,
                weight: Wes2FieldState<double>(actualValue: weights[i]),
                reps: const Wes2FieldState<int>(actualValue: 8),
              ),
          ],
          source: Wes2RowSource.wes2Manual,
          exerciseType: type,
        );

    test('two bodyweight-only sets qualify the day', () {
      expect(
        qualifyingSets(<Wes2ExerciseRow>[
          rowWith(kTypedId, kTypedName, <double?>[0, 0], type: 'Body Weight'),
        ]),
        2,
      );
    });

    test('two zero-weight ORDINARY sets do not qualify', () {
      expect(
        qualifyingSets(<Wes2ExerciseRow>[
          rowWith(kBenchId, kBenchName, <double?>[0, 0]),
        ]),
        0,
      );
    });

    test('negative bodyweight sets do not qualify', () {
      expect(
        qualifyingSets(<Wes2ExerciseRow>[
          rowWith(kTypedId, kTypedName, <double?>[-1, -20],
              type: 'Body Weight'),
        ]),
        0,
      );
    });

    test('an unentered weight never qualifies, bodyweight or not', () {
      expect(
        qualifyingSets(<Wes2ExerciseRow>[
          rowWith(kTypedId, kTypedName, <double?>[null, null],
              type: 'Body Weight'),
        ]),
        0,
      );
    });

    test('ordinary positive sets still qualify (unchanged)', () {
      expect(
        qualifyingSets(<Wes2ExerciseRow>[
          rowWith(kBenchId, kBenchName, <double?>[100, 100]),
        ]),
        2,
      );
    });
  });

  // ── 10 & 12. Shared exercise analytics (Top Sets / E1RM chart source) ────

  group('shared exercise analytics derivation', () {
    RawWorkoutDoc doc(DateTime date, String id, String name, num weight,
            {String? type}) =>
        RawWorkoutDoc(
          id: '${date.year}-${date.month}-${date.day}-$id',
          date: date,
          exercises: <Map<String, dynamic>>[
            <String, dynamic>{
              'id': id,
              'name': name,
              if (type != null) 'type': type,
              'sets': <Map<String, dynamic>>[
                <String, dynamic>{
                  'setIndex': 0,
                  'weight': weight,
                  'reps': 8,
                  'rir': 1,
                  'velocity': 0.42,
                },
              ],
            },
          ],
        );

    final DateTime day = DateTime(2026, 9, 10);

    test('a zero-added bodyweight day still produces a charted workout', () {
      final List<Workout> out = deriveWorkoutsForExercise(
        docs: <RawWorkoutDoc>[doc(day, kTypedId, kTypedName, 0)],
        targetId: kTypedId,
        targetName: kTypedName,
        isBodyweight: true,
        bodyweightKgForDate: (_) => 80,
      );
      expect(out, hasLength(1),
          reason: 'a bodyweight-only day must not vanish from the chart');
    });

    test('the same day is dropped when the exercise is not bodyweight', () {
      expect(
        deriveWorkoutsForExercise(
          docs: <RawWorkoutDoc>[doc(day, kBenchId, kBenchName, 0)],
          targetId: kBenchId,
          targetName: kBenchName,
        ),
        isEmpty,
      );
    });

    test('a negative weight is dropped even for a bodyweight exercise', () {
      expect(
        deriveWorkoutsForExercise(
          docs: <RawWorkoutDoc>[doc(day, kTypedId, kTypedName, -5)],
          targetId: kTypedId,
          targetName: kTypedName,
          isBodyweight: true,
          bodyweightKgForDate: (_) => 80,
        ),
        isEmpty,
      );
    });

    test('velocity samples of a bodyweight set plot at the TOTAL load', () {
      final List<VelocitySample> s = deriveVelocitySamplesForExercise(
        docs: <RawWorkoutDoc>[doc(day, kTypedId, kTypedName, 0)],
        targetId: kTypedId,
        targetName: kTypedName,
        isBodyweight: true,
        bodyweightKgForDate: (_) => 80,
      );
      expect(s, hasLength(1));
      expect(s.single.weight, 80.0);
      expect(s.single.velocity, 0.42);
    });

    test('a velocity sample needing an unrecorded weigh-in is omitted', () {
      expect(
        deriveVelocitySamplesForExercise(
          docs: <RawWorkoutDoc>[doc(day, kTypedId, kTypedName, 0)],
          targetId: kTypedId,
          targetName: kTypedName,
          isBodyweight: true,
          bodyweightKgForDate: (_) => null,
        ),
        isEmpty,
        reason: 'omit rather than guess — never a default bodyweight',
      );
    });

    test('16. a non-bodyweight velocity sample is unchanged', () {
      final List<VelocitySample> s = deriveVelocitySamplesForExercise(
        docs: <RawWorkoutDoc>[doc(day, kBenchId, kBenchName, 100)],
        targetId: kBenchId,
        targetName: kBenchName,
      );
      expect(s.single.weight, 100.0);
    });
  });

  // ── Top Sets ranking of a zero-added bodyweight set ─────────────────────

  group('Top Sets ranking', () {
    test('a WES2 zero-added set ranks at the recorded bodyweight', () {
      final SetDetails s = SetDetails.fromFirestore(
        <String, dynamic>{'setIndex': 0, 'weight': 0, 'reps': 8, 'rir': 1},
        1,
      );
      expect(s.bodyweightLoad(80).totalKg, 80.0);
      expect(s.bodyweightLoad(80).addedKg, 0.0);
    });

    test('a WES2 positive set ranks at bodyweight PLUS the added load', () {
      final SetDetails s = SetDetails.fromFirestore(
        <String, dynamic>{'setIndex': 0, 'weight': 20, 'reps': 5, 'rir': 1},
        1,
      );
      expect(s.bodyweightLoad(80).totalKg, 100.0);
      expect(s.bodyweightLoad(80).addedKg, 20.0);
    });

    test('a legacy set keeps the existing absolute interpretation', () {
      final SetDetails s = SetDetails.fromFirestore(
        <String, dynamic>{'weight': 138.5, 'weightAdded': 53.5, 'reps': 3},
        1,
      );
      expect(s.bodyweightLoad(85).totalKg, 138.5);
      expect(s.bodyweightLoad(85).addedKg, 53.5);
    });

    test('a zero-added set with no weigh-in has an unknown total', () {
      final SetDetails s = SetDetails.fromFirestore(
        <String, dynamic>{'setIndex': 0, 'weight': 0, 'reps': 8},
        1,
      );
      expect(s.bodyweightLoad(null).totalKg, isNull);
    });
  });

  // ── The legacy workout model preserves the type snapshot ────────────────

  test('the legacy Exercise model round trips the type snapshot', () {
    final Exercise e = Exercise.fromFirestore(<String, dynamic>{
      'id': kTypedId,
      'name': kTypedName,
      'type': ' Body Weight ',
      'circuitIndex': 1,
      'sets': <Map<String, dynamic>>[
        <String, dynamic>{'setIndex': 0, 'weight': 0, 'reps': 8},
      ],
    });
    expect(e.type, 'Body Weight');
    expect(e.toFirestore()['type'], 'Body Weight');
    expect(
      PeriodizationModelUtils.isBodyweightExercise(
          id: e.id, name: e.name, type: e.type),
      isTrue,
    );
    // A row with no type serialises exactly as it always has.
    final Exercise plain = Exercise.fromFirestore(<String, dynamic>{
      'name': kBenchName,
      'sets': <Map<String, dynamic>>[],
    });
    expect(plain.type, isNull);
    expect(plain.toFirestore().containsKey('type'), isFalse);
  });
}
