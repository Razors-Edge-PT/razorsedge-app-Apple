// Structure, prescriptions and provenance across a reload.
//
// Three separate things used to go wrong once a day was saved and reopened:
//   * a set the athlete had deleted came back, because the hint pass grew the
//     row to the planned count again;
//   * BB3 prescriptions were read back out of whatever the row's hints
//     happened to be, so a generated - or draft-recovered - number could act
//     like a BB3 lock;
//   * the draft dropped hint provenance entirely, so nothing could tell a
//     prescription from a display value after a reload.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/wes2_hint_input.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
const _blockId = 'b1';
final _blockStart = DateTime(2026, 1, 5);
final _day = DateTime(2026, 1, 12);

/// The plan asks for FOUR sets; the athlete's saved day has two.
Map<String, dynamic> _settings() => <String, dynamic>{
      _exId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': 2.5},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': '10 x 4'},
          'week2': <String, dynamic>{'instance1': '10 x 4'},
        },
        'rirPlan': <String, dynamic>{
          for (final String wk in const <String>['week1', 'week2'])
            wk: <String, dynamic>{
              'session1': <String, dynamic>{
                for (int i = 1; i <= 4; i++)
                  'set$i': <String, dynamic>{'rir': '2'},
              }
            }
        },
      }
    };

Wes2HintServiceImpl _svc() => Wes2HintServiceImpl(
      exerciseSettings: _settings(),
      blockStartDate: _blockStart,
      blockEndDate: null,
      uid: _uid,
    );

Wes2SessionController _controllerWith(List<Wes2ExerciseRow> rows) {
  final Wes2SessionController c = Wes2SessionController(_day)
    ..initIdentity(
      actorUid: _uid,
      actingUid: _uid,
      isCoach: false,
      activeBlockId: _blockId,
      blockStartDate: _blockStart,
      blockEndDate: null,
    )
    ..setExerciseSettings(_settings());
  final int epoch = c.beginLoad();
  c.setRows(rows, epoch);
  return c;
}

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Saved structure survives a reload.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-STRUCT-RELOAD — a saved row keeps its own set count', () {
    test('a two-set saved row is not grown back to the planned four',
        () async {
      final FakeFirebaseFirestore fs = FakeFirebaseFirestore();
      await fs
          .collection('users')
          .doc(_uid)
          .collection('workouts')
          .doc('2026-01-12')
          .set(<String, dynamic>{
        'userId': _uid,
        'date': '2026-01-12',
        'exercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': _exId,
            'name': _exName,
            'circuitIndex': 0,
            'orderIndex': 0,
            'setCount': 2,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{'setIndex': 0, 'weight': 40.0, 'reps': 8},
              <String, dynamic>{'setIndex': 1, 'weight': 37.5, 'reps': 8},
            ],
          }
        ],
        'wesPlannedExercises': <dynamic>[],
      });

      final List<Wes2ExerciseRow> loaded = await FirestoreWes2Repository(
        firestore: fs,
      ).loadDay(uid: _uid, date: _day);

      expect(loaded.single.setCount, 2);
      expect(loaded.single.structureEstablished, isTrue,
          reason: 'a stored row carries the structure the athlete left');

      final Wes2SessionController c = _controllerWith(loaded);
      c.applyHintContext(_svc(), _blockId);
      expect(c.rows.first.setCount, 2,
          reason: 'the hint pass must not restore the planned fourth set');

      // And again on a second pass, as a refresh would do.
      c.applyHintContext(_svc(), _blockId);
      expect(c.rows.first.setCount, 2);
    });

    test('a plan-only row still takes the planned count', () {
      final Wes2SessionController c = _controllerWith(<Wes2ExerciseRow>[
        Wes2ExerciseRow(
          exerciseId: _exId,
          name: _exName,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 1,
          source: Wes2RowSource.bb3Planned,
          sets: const <Wes2SetState>[Wes2SetState(setIndex: 0)],
        )
      ]);
      c.applyHintContext(_svc(), _blockId);
      expect(c.rows.first.setCount, 4);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Prescriptions are positional and are the only BB3 authority.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-PRESCRIPTION — positional, and never inferred from a hint', () {
    Wes2Prescriptions threeSets() => const Wes2Prescriptions(
          sets: <Wes2PrescribedSet>[
            Wes2PrescribedSet(weight: 50, reps: 5),
            Wes2PrescribedSet(weight: 45, reps: 6),
            Wes2PrescribedSet(weight: 40, reps: 7),
          ],
        );

    /// A BB3 row the athlete has already worked in, so its structure is the
    /// session's: the plan's fourth set is not re-added underneath it.
    Wes2ExerciseRow row(int count) => Wes2ExerciseRow(
          exerciseId: _exId,
          name: _exName,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: count,
          source: Wes2RowSource.bb3Planned,
          structureEstablished: true,
          sets: List<Wes2SetState>.generate(
              count, (int i) => Wes2SetState(setIndex: i)),
        );

    test('each set shows its own prescription, as a BB3 lock', () {
      final Wes2ExerciseRow out = _svc().resolveRow(
        row: row(3),
        prescriptions: threeSets(),
        uid: _uid,
        date: _day,
      );
      expect(out.sets[0].weight.hintValue, 50.0);
      expect(out.sets[1].weight.hintValue, 45.0);
      expect(out.sets[2].weight.hintValue, 40.0);
      expect(out.sets[1].reps.hintValue, 6);
      for (final Wes2SetState s in out.sets) {
        expect(s.weight.hintOrigin, FieldOrigin.bb3Hint);
      }
    });

    test('after removing set 2, position 2 keeps prescription 2', () {
      final Wes2SessionController c = _controllerWith(<Wes2ExerciseRow>[row(3)]);
      c.setPrescriptions(<String, Wes2Prescriptions>{_exId: threeSets()},
          recompute: false);
      c.applyHintContext(_svc(), _blockId);
      expect(c.rows.first.sets[1].weight.hintValue, 45.0);

      c.removeSet(_exId, 1);

      expect(c.rows.first.setCount, 2);
      expect(c.rows.first.sets[0].weight.hintValue, 50.0);
      expect(c.rows.first.sets[1].weight.hintValue, 45.0,
          reason: 'prescriptions are positional, exactly as a reload shows '
              'them - they do not follow the surviving set');
    });

    test('a generated hint is never promoted to a prescription', () {
      // A row whose hints came from the model (or from a recovered draft).
      final Wes2ExerciseRow generated = Wes2ExerciseRow(
        exerciseId: _exId,
        name: _exName,
        circuitIndex: 0,
        orderIndex: 0,
        setCount: 1,
        source: Wes2RowSource.localDraft,
        sets: const <Wes2SetState>[
          Wes2SetState(
            setIndex: 0,
            weight: Wes2FieldState<double>(
                hintValue: 60,
                hintOrigin: FieldOrigin.modelHint,
                origin: FieldOrigin.modelHint),
          )
        ],
      );
      final Wes2Prescriptions read =
          Wes2HintInput.prescriptionsFromRow(generated);
      expect(read.at(0).weight, isNull,
          reason: 'only a bb3Hint origin is prescription authority');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Draft round trip: entries and provenance both survive.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-DRAFT — a reloaded draft keeps entries and provenance', () {
    test('actual values, notes, setId and hint provenance round trip', () {
      final Wes2ExerciseRow before = Wes2ExerciseRow(
        exerciseId: _exId,
        name: _exName,
        circuitIndex: 0,
        orderIndex: 0,
        setCount: 2,
        source: Wes2RowSource.localDraft,
        structureEstablished: true,
        sets: <Wes2SetState>[
          Wes2SetState(
            setIndex: 0,
            setId: 'sid-1',
            weight: const Wes2FieldState<double>(
                actualValue: 42.5,
                hintValue: 50,
                hintOrigin: FieldOrigin.bb3Hint,
                origin: FieldOrigin.typed),
            reps: const Wes2FieldState<int>(actualValue: 0),
            rir: const Wes2FieldState<double>(actualValue: 0),
            executionNote: 'felt heavy',
          ),
          const Wes2SetState(
            setIndex: 1,
            weight: Wes2FieldState<double>(
                hintValue: 47.5,
                hintOrigin: FieldOrigin.modelHint,
                origin: FieldOrigin.modelHint),
          ),
        ],
      );

      final Wes2ExerciseRow after =
          Wes2ExerciseRow.fromJson(before.toJson());

      // Entries survive, including an entered zero.
      expect(after.sets[0].weight.actualValue, 42.5);
      expect(after.sets[0].reps.actualValue, 0);
      expect(after.sets[0].rir.actualValue, 0);
      expect(after.sets[0].executionNote, 'felt heavy');
      expect(after.sets[0].setId, 'sid-1');
      expect(after.structureEstablished, isTrue);

      // Provenance survives: the BB3 lock is still a lock...
      expect(after.sets[0].weight.hintOrigin, FieldOrigin.bb3Hint);
      // ...and the generated hint is still only a display value.
      expect(after.sets[1].weight.hintOrigin, FieldOrigin.modelHint);

      // Which is what stops a recovered display value acting as a lock.
      final Wes2Prescriptions read = Wes2HintInput.prescriptionsFromRow(after);
      expect(read.at(0).weight, 50.0);
      expect(read.at(1).weight, isNull);
    });

    test('a schema-1 draft (no hintOrigin) yields no prescriptions', () {
      final Map<String, dynamic> legacy = <String, dynamic>{
        'exerciseId': _exId,
        'name': _exName,
        'circuitIndex': 0,
        'orderIndex': 0,
        'setCount': 1,
        'source': 'localDraft',
        'isMarkedDone': false,
        'sets': <Map<String, dynamic>>[
          <String, dynamic>{
            'setIndex': 0,
            'weight': <String, dynamic>{'actual': 40.0, 'hint': 45.0},
            'reps': <String, dynamic>{'actual': null, 'hint': 8},
            'rir': <String, dynamic>{'actual': null, 'hint': 2.0},
            'velocity': <String, dynamic>{'actual': null, 'hint': null},
          }
        ],
      };
      final Wes2ExerciseRow row = Wes2ExerciseRow.fromJson(legacy);

      expect(row.sets[0].weight.actualValue, 40.0,
          reason: 'the entry itself is still recovered');
      expect(row.sets[0].weight.hintOrigin, FieldOrigin.empty);
      expect(Wes2HintInput.prescriptionsFromRow(row).at(0).weight, isNull,
          reason: 'an old draft hint is a display cache, not a prescription');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Degraded inputs: no settings, no history.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-DEGRADED — missing settings or history', () {
    test('with no hint service the entry is still recorded and nothing is '
        'invented', () {
      // This is the offline/settings-unavailable state: the screen shows the
      // day, the athlete logs sets, and no model result is fabricated.
      final Wes2SessionController c = _controllerWith(<Wes2ExerciseRow>[
        Wes2ExerciseRow(
          exerciseId: _exId,
          name: _exName,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 3,
          source: Wes2RowSource.wes2Manual,
          sets: List<Wes2SetState>.generate(
              3, (int i) => Wes2SetState(setIndex: i)),
        )
      ]);

      c.updateSetField(
          exerciseId: _exId,
          setIndex: 0,
          fieldKey: Wes2FieldKey.weight,
          rawText: '40');

      expect(c.rows.first.sets[0].weight.actualValue, 40.0);
      for (final Wes2SetState s in c.rows.first.sets) {
        expect(s.weight.hintValue, isNull);
        expect(s.reps.hintValue, isNull);
      }
    });

    test('with settings but no history the plan still produces hints', () {
      PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
      final Wes2SessionController c = _controllerWith(<Wes2ExerciseRow>[
        Wes2ExerciseRow(
          exerciseId: _exId,
          name: _exName,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 3,
          source: Wes2RowSource.wes2Manual,
          sets: List<Wes2SetState>.generate(
              3, (int i) => Wes2SetState(setIndex: i)),
        )
      ]);
      c.applyHintContext(_svc(), _blockId);

      expect(c.rows.first.sets[0].reps.hintValue, isNotNull,
          reason: 'the planned rep target still applies without history');
      // And the cascade still runs forward from it.
      c.updateSetField(
          exerciseId: _exId,
          setIndex: 0,
          fieldKey: Wes2FieldKey.weight,
          rawText: '40');
      expect(c.rows.first.sets[1].weight.hintValue, isNotNull);
    });

    test('hints are never written into the entry fields', () {
      PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
      final Wes2SessionController c = _controllerWith(<Wes2ExerciseRow>[
        Wes2ExerciseRow(
          exerciseId: _exId,
          name: _exName,
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 3,
          source: Wes2RowSource.wes2Manual,
          sets: List<Wes2SetState>.generate(
              3, (int i) => Wes2SetState(setIndex: i)),
        )
      ]);
      c.applyHintContext(_svc(), _blockId);

      expect(workoutHasUserEnteredData(c.rows), isFalse);
      for (final Wes2SetState s in c.rows.first.sets) {
        expect(s.weight.actualValue, isNull);
        expect(s.reps.actualValue, isNull);
        expect(s.rir.actualValue, isNull);
      }
      // What a save would serialise: actuals only, so nothing at all here.
      final Map<String, dynamic> map =
          FirestoreWes2Repository.buildRowMapForTest(c.rows.first);
      for (final Object? raw in map['sets'] as List<dynamic>) {
        final Map<String, dynamic> set = raw as Map<String, dynamic>;
        expect(set.containsKey('weight'), isFalse);
        expect(set.containsKey('reps'), isFalse);
        expect(set.containsKey('rir'), isFalse);
      }
    });
  });
}
