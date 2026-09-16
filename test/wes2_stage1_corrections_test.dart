// Stage 1 review corrections, reproduced through production code first.
//
// 2. The "pure Set 1" fallback read the ORIGINAL row's hint fields, which are
//    whatever the previous position left there, while the main solve used the
//    authoritative prescription the input builder installs. After removing the
//    first set the two disagreed, and repeating the recalculation changed the
//    answer again.
// 4. Set 2+ returned early when the previous set had no weight, BEFORE the
//    timed branch. An unweighted plank has no weight by design, so an entered
//    time never reached the sets after it.
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
/// A genuinely UNWEIGHTED timed exercise (PeriodizationModelUtils._timedById).
const _plankId = 'xU7MNEvnaoSwz5jy3uHw';
const _plankName = 'Plank';
const _uid = 'u1';
const _blockId = 'b1';
final DateTime _blockStart = DateTime(2026, 1, 5);
final DateTime _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings({
  String exerciseId = _exId,
  String repTarget = '10 x 3',
}) =>
    <String, dynamic>{
      exerciseId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': 2.5},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': repTarget},
          'week2': <String, dynamic>{'instance1': repTarget},
        },
        'rirPlan': <String, dynamic>{
          for (final String wk in const <String>['week1', 'week2'])
            wk: <String, dynamic>{
              'session1': <String, dynamic>{
                for (int i = 1; i <= 3; i++)
                  'set$i': <String, dynamic>{'rir': '2'},
              }
            }
        },
      }
    };

Wes2HintServiceImpl _svc(Map<String, dynamic> settings) => Wes2HintServiceImpl(
      exerciseSettings: settings,
      blockStartDate: _blockStart,
      blockEndDate: null,
      uid: _uid,
    );

Wes2SessionController _controller({
  required Map<String, dynamic> settings,
  required Wes2ExerciseRow row,
  Map<String, Wes2Prescriptions> prescriptions =
      const <String, Wes2Prescriptions>{},
}) {
  final Wes2SessionController c = Wes2SessionController(_day)
    ..initIdentity(
      actorUid: _uid,
      actingUid: _uid,
      isCoach: false,
      activeBlockId: _blockId,
      blockStartDate: _blockStart,
      blockEndDate: null,
    )
    ..setExerciseSettings(settings);
  final int epoch = c.beginLoad();
  c.setRows(<Wes2ExerciseRow>[row], epoch);
  c.setPrescriptions(prescriptions, recompute: false);
  c.applyHintContext(_svc(settings), _blockId);
  return c;
}

Wes2ExerciseRow _row({
  required String exerciseId,
  required String name,
  required List<Wes2SetState> sets,
}) =>
    Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: sets.length,
      source: Wes2RowSource.wes2Manual,
      structureEstablished: true,
      sets: sets,
    );

Wes2SetState _set(int i, {double? w, int? r, double? rir}) => Wes2SetState(
      setIndex: i,
      weight: Wes2FieldState<double>(
          actualValue: w,
          origin: w != null ? FieldOrigin.typed : FieldOrigin.empty),
      reps: Wes2FieldState<int>(
          actualValue: r,
          origin: r != null ? FieldOrigin.typed : FieldOrigin.empty),
      rir: Wes2FieldState<double>(
          actualValue: rir,
          origin: rir != null ? FieldOrigin.typed : FieldOrigin.empty),
    );

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 2. The pure Set 1 fallback must use the SAME authoritative prescriptions
  //    as the solve it backs up.
  // ───────────────────────────────────────────────────────────────────────────
  group('C2 — the Set 1 fallback uses the current prescription context', () {
    /// Weight-only prescriptions: position 0 = 50 kg, position 1 = 45 kg.
    Wes2Prescriptions weightsOnly() => const Wes2Prescriptions(
          sets: <Wes2PrescribedSet>[
            Wes2PrescribedSet(weight: 50),
            Wes2PrescribedSet(weight: 45),
          ],
        );

    Wes2SessionController build() => _controller(
          settings: _settings(),
          prescriptions: <String, Wes2Prescriptions>{_exId: weightsOnly()},
          row: _row(
            exerciseId: _exId,
            name: _exName,
            // Set 2 carries a real performance; Set 1 is untouched.
            sets: <Wes2SetState>[_set(0), _set(1, w: 40, r: 8)],
          ),
        );

    test('after removing Set 1 the survivor uses ITS position prescription',
        () {
      final Wes2SessionController c = build();
      // Position 1 is prescribed 45 kg while it is the second set.
      expect(c.rows.first.sets[1].weight.hintValue, 45.0);

      c.removeSet(_exId, 0);

      // The survivor is now position 0, whose prescription is 50 kg.
      expect(c.rows.first.setCount, 1);
      expect(c.rows.first.sets[0].weight.actualValue, 40.0);
      expect(c.rows.first.sets[0].reps.actualValue, 8);

      final double? solvedRir = c.rows.first.sets[0].rir.hintValue;
      expect(solvedRir, isNotNull);

      // Repeating the pass must not move it. Before the fix the fallback read
      // the row's leftover hint (45) on the first pass and the freshly
      // installed prescription (50) on the next, so the RIR walked 7 -> 9.
      for (int i = 0; i < 3; i++) {
        c.applyHintContext(_svc(_settings()), _blockId);
        expect(c.rows.first.sets[0].rir.hintValue, solvedRir,
            reason: 'pass ${i + 1} changed the solved RIR');
      }
    });

    test('the first pass already agrees with a freshly built controller', () {
      final Wes2SessionController mutated = build();
      mutated.removeSet(_exId, 0);

      // The same day, loaded fresh with the surviving set at position 0.
      final Wes2SessionController fresh = _controller(
        settings: _settings(),
        prescriptions: <String, Wes2Prescriptions>{_exId: weightsOnly()},
        row: _row(
          exerciseId: _exId,
          name: _exName,
          sets: <Wes2SetState>[_set(0, w: 40, r: 8)],
        ),
      );

      expect(mutated.rows.first.sets[0].rir.hintValue,
          fresh.rows.first.sets[0].rir.hintValue,
          reason: 'the in-session result must match a fresh load of the same '
              'state');
    });

    test('replacing the prescriptions moves the fallback with them', () {
      final Wes2SessionController c = _controller(
        settings: _settings(),
        prescriptions: <String, Wes2Prescriptions>{_exId: weightsOnly()},
        row: _row(
          exerciseId: _exId,
          name: _exName,
          sets: <Wes2SetState>[_set(0, w: 40, r: 8)],
        ),
      );
      final double? before = c.rows.first.sets[0].rir.hintValue;

      c.setPrescriptions(<String, Wes2Prescriptions>{
        _exId: const Wes2Prescriptions(
          sets: <Wes2PrescribedSet>[Wes2PrescribedSet(weight: 80)],
        )
      });

      expect(c.rows.first.sets[0].rir.hintValue, isNot(before),
          reason: 'a much heavier prescription implies a different RIR');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 4. An unweighted timed exercise must still propagate its seconds.
  // ───────────────────────────────────────────────────────────────────────────
  group('C4 — unweighted timed sets propagate seconds', () {
    test('the fixture is timed and NOT weighted', () {
      expect(
          PeriodizationModelUtils.isTimedExercise(
              id: _plankId, name: _plankName),
          isTrue);
      expect(PeriodizationModelUtils.isWeightedTimedExercise(id: _plankId),
          isFalse);
    });

    test('an entered 60 seconds feeds the sets after it', () {
      final Wes2SessionController c = _controller(
        settings: _settings(exerciseId: _plankId, repTarget: '9 x 3'),
        row: _row(
          exerciseId: _plankId,
          name: _plankName,
          sets: <Wes2SetState>[_set(0), _set(1), _set(2)],
        ),
      );

      c.updateSetField(
          exerciseId: _plankId,
          setIndex: 0,
          fieldKey: Wes2FieldKey.reps,
          rawText: '60');

      expect(c.rows.first.sets[0].reps.actualValue, 60);
      expect(c.rows.first.sets[1].reps.hintValue, 60,
          reason: 'the time actually held must carry forward');
      expect(c.rows.first.sets[2].reps.hintValue, 60);
    });

    test('no weight or RIR is invented for an unweighted timed set', () {
      final Wes2SessionController c = _controller(
        settings: _settings(exerciseId: _plankId, repTarget: '9 x 3'),
        row: _row(
          exerciseId: _plankId,
          name: _plankName,
          sets: <Wes2SetState>[_set(0), _set(1), _set(2)],
        ),
      );
      c.updateSetField(
          exerciseId: _plankId,
          setIndex: 0,
          fieldKey: Wes2FieldKey.reps,
          rawText: '60');

      for (final Wes2SetState s in c.rows.first.sets) {
        expect(s.weight.hintValue, isNull, reason: 'set ${s.setIndex + 1}');
        expect(s.rir.hintValue, isNull, reason: 'set ${s.setIndex + 1}');
      }
    });

    test('the planned seconds still show before anything is entered', () {
      final Wes2SessionController c = _controller(
        settings: _settings(exerciseId: _plankId, repTarget: '9 x 3'),
        row: _row(
          exerciseId: _plankId,
          name: _plankName,
          sets: <Wes2SetState>[_set(0), _set(1), _set(2)],
        ),
      );
      expect(c.rows.first.sets[0].reps.hintValue, 45);
      expect(c.rows.first.sets[1].reps.hintValue, 45);
    });
  });
}
