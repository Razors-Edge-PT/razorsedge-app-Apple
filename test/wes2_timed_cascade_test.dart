// Timed sets propagate SECONDS, and an entered time counts.
//
// Set 2+ of a timed exercise copies the previous set's seconds (and, for a
// weighted timed exercise, its added load) instead of running the rep/RIR
// solver, which seconds-as-reps would corrupt. The defect: it copied the
// previous set's HINT only, so a plank the athlete actually held for 60 s
// still suggested the planned 45 s for every set after it.
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

/// Real timed, weighted ids from PeriodizationModelUtils.
const String _timedId = 'DTkkN5pi05RWQyNYhizQ';
const String _timedName = 'Weighted Plank';
const String _uid = 'u1';
const String _blockId = 'b1';
final DateTime _blockStart = DateTime(2026, 1, 5);
final DateTime _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings() => <String, dynamic>{
      _timedId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': 2.5},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': '9 x 3'},
          'week2': <String, dynamic>{'instance1': '9 x 3'},
        },
        'rirPlan': <String, dynamic>{
          for (final String wk in const <String>['week1', 'week2'])
            wk: <String, dynamic>{
              'session1': <String, dynamic>{
                'set1': <String, dynamic>{'rir': '2'},
                'set2': <String, dynamic>{'rir': '2'},
                'set3': <String, dynamic>{'rir': '2'},
              }
            }
        },
      }
    };

Wes2SessionController _load() {
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
  c.setRows(<Wes2ExerciseRow>[
    Wes2ExerciseRow(
      exerciseId: _timedId,
      name: _timedName,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: 3,
      source: Wes2RowSource.wes2Manual,
      sets:
          List<Wes2SetState>.generate(3, (int i) => Wes2SetState(setIndex: i)),
    )
  ], epoch);
  c.applyHintContext(
    Wes2HintServiceImpl(
      exerciseSettings: _settings(),
      blockStartDate: _blockStart,
      blockEndDate: null,
      uid: _uid,
    ),
    _blockId,
  );
  return c;
}

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  test('the fixture really is a timed, weighted exercise', () {
    expect(
        PeriodizationModelUtils.isTimedExercise(
            id: _timedId, name: _timedName),
        isTrue);
    expect(PeriodizationModelUtils.isWeightedTimedExercise(id: _timedId),
        isTrue);
  });

  test('H-TIMED plan seconds are converted once, not per pass', () {
    final Wes2SessionController c = _load();
    final int? first = c.rows.first.sets[0].reps.hintValue;
    expect(first, 45, reason: 'a planned 9 becomes 45 seconds (x5)');

    // Three further passes must not multiply it again.
    for (int i = 0; i < 3; i++) {
      c.applyHintContext(
        Wes2HintServiceImpl(
          exerciseSettings: _settings(),
          blockStartDate: _blockStart,
          blockEndDate: null,
          uid: _uid,
        ),
        _blockId,
      );
      expect(c.rows.first.sets[0].reps.hintValue, first);
    }
  });

  test('H-TIMED an entered time propagates to the sets after it', () {
    final Wes2SessionController c = _load();
    final int planned = c.rows.first.sets[0].reps.hintValue!;
    expect(c.rows.first.sets[1].reps.hintValue, planned);

    c.updateSetField(
        exerciseId: _timedId,
        setIndex: 0,
        fieldKey: Wes2FieldKey.reps,
        rawText: '60');

    expect(c.rows.first.sets[0].reps.actualValue, 60);
    expect(c.rows.first.sets[1].reps.hintValue, 60,
        reason: 'the held time must carry forward, not the planned hint');
    expect(c.rows.first.sets[2].reps.hintValue, 60);
  });

  test('H-TIMED an entered added load propagates for a weighted timed set',
      () {
    final Wes2SessionController c = _load();
    c.updateSetField(
        exerciseId: _timedId,
        setIndex: 0,
        fieldKey: Wes2FieldKey.weight,
        rawText: '12.5');

    expect(c.rows.first.sets[1].weight.hintValue, 12.5);
    expect(c.rows.first.sets[2].weight.hintValue, 12.5);
  });

  test('H-TIMED no RIR is invented for a timed set', () {
    final Wes2SessionController c = _load();
    for (final Wes2SetState s in c.rows.first.sets) {
      expect(s.rir.hintValue, isNull);
    }
  });
}
