// THROWAWAY PROBE — accepted-hint counterexample (prev 40x10@2, group C, grid 2.5).
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';

Map<String, dynamic> _settings() => {
      _exId: {
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': {'primary': 2.5},
        'repTargets': {'week1': {'instance1': '10 x 3'}, 'week2': {'instance1': '10 x 3'}},
        'rirPlan': {
          for (final wk in const ['week1', 'week2'])
            wk: {'session1': {'set1': {'rir': '2'}, 'set2': {'rir': '2'}, 'set3': {'rir': '2'}}}
        },
      }
    };

Wes2SetState set(int i, {double? w, int? r, double? rir}) => Wes2SetState(
    setIndex: i,
    weight: Wes2FieldState(actualValue: w, origin: w != null ? FieldOrigin.typed : FieldOrigin.empty),
    reps: Wes2FieldState(actualValue: r, origin: r != null ? FieldOrigin.typed : FieldOrigin.empty),
    rir: Wes2FieldState(actualValue: rir, origin: rir != null ? FieldOrigin.typed : FieldOrigin.empty));

String res(Wes2SetState s) {
  final w = s.weight.actualValue ?? s.weight.hintValue;
  final r = s.reps.actualValue ?? s.reps.hintValue;
  final i = s.rir.actualValue ?? s.rir.hintValue ?? 0.0;
  final e = (w != null && r != null) ? PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), i).toStringAsFixed(4) : '-';
  return '$w${s.weight.actualValue != null ? '*' : ''} x $r${s.reps.actualValue != null ? '*' : ''} @ $i${s.rir.actualValue != null ? '*' : ''} ($e)';
}

void main() {
  test('counterexample', () {
    PeriodizationModelUtils.savedWorkoutsList = [];
    final svc = Wes2HintServiceImpl(exerciseSettings: _settings(), blockStartDate: DateTime(2026, 1, 5), blockEndDate: null, uid: 'u1');
    void run(String label, Wes2SetState s2) {
      final row = Wes2ExerciseRow(exerciseId: _exId, name: _exName, circuitIndex: 0, orderIndex: 0, setCount: 3, source: Wes2RowSource.wes2Manual,
          sets: [set(0, w: 40, r: 10, rir: 2), s2, set(2)]);
      final out = svc.computeRowHints(row: row, blockId: 'b', uid: 'u1', date: DateTime(2026, 1, 12));
      // ignore: avoid_print
      print('$label → S2 ${res(out.sets[1])} | S3 ${res(out.sets[2])}');
    }
    run('no entries    ', set(1));
    run('weight 40     ', set(1, w: 40));
    run('w40 + r10     ', set(1, w: 40, r: 10));
    run('reps 10       ', set(1, r: 10));
    run('r10 + w40     ', set(1, w: 40, r: 10));
    run('w40+r10+rir2  ', set(1, w: 40, r: 10, rir: 2));
  });
}
