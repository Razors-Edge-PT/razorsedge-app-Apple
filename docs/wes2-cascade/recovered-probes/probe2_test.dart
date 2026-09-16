// THROWAWAY DIAGNOSTIC PROBE — accept-hint sibling stability without suppression.
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
final _blockStart = DateTime(2026, 1, 5);
final _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings(String rep, String s1Rir) => {
      _exId: {
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': {'primary': 2.5},
        'repTargets': {'week1': {'instance1': rep}, 'week2': {'instance1': rep}},
        'rirPlan': {
          for (final wk in const ['week1', 'week2'])
            wk: {'session1': {'set1': {'rir': s1Rir}, 'set2': {'rir': '2'}, 'set3': {'rir': '2.5'}}}
        },
      }
    };

Wes2ExerciseRow row(List<Wes2SetState> sets) => Wes2ExerciseRow(
    exerciseId: _exId, name: _exName, circuitIndex: 0, orderIndex: 0, setCount: sets.length, source: Wes2RowSource.wes2Manual, sets: sets);

Wes2SetState set(int i, {double? w, int? r, double? rir}) => Wes2SetState(
    setIndex: i,
    weight: Wes2FieldState(actualValue: w, origin: w != null ? FieldOrigin.typed : FieldOrigin.empty),
    reps: Wes2FieldState(actualValue: r, origin: r != null ? FieldOrigin.typed : FieldOrigin.empty),
    rir: Wes2FieldState(actualValue: rir, origin: rir != null ? FieldOrigin.typed : FieldOrigin.empty));

String res(Wes2SetState s) =>
    '${s.weight.actualValue ?? s.weight.hintValue}${s.weight.actualValue != null ? '*' : ''} x '
    '${s.reps.actualValue ?? s.reps.hintValue}${s.reps.actualValue != null ? '*' : ''} @ '
    '${s.rir.actualValue ?? s.rir.hintValue}${s.rir.actualValue != null ? '*' : ''}';

void main() {
  for (final fx in [
    (hist: [35.0, 8, 2.0], rep: '7 x 3', rir: '2'),
    (hist: [35.0, 8, 2.0], rep: '8 x 3', rir: '1.5'),
    (hist: [37.5, 8, 2.0], rep: '8 x 3', rir: '1.5'),
    (hist: [60.0, 5, 1.0], rep: '5 x 3', rir: '2'),
    (hist: [22.5, 12, 1.0], rep: '12 x 3', rir: '1'),
  ]) {
    test('fixture $fx', () {
      PeriodizationModelUtils.savedWorkoutsList = [
        {'date': DateTime(2026, 1, 5), 'exercises': [{'exerciseId': _exId, 'name': _exName, 'sets': [{'weight': fx.hist[0], 'reps': fx.hist[1], 'rir': fx.hist[2]}]}]}
      ];
      PeriodizationModelUtils.topSetsByExercise.clear();
      final svc = Wes2HintServiceImpl(exerciseSettings: _settings(fx.rep, fx.rir), blockStartDate: _blockStart, blockEndDate: null, uid: 'u1');
      Wes2ExerciseRow c(List<Wes2SetState> s) => svc.computeRowHints(row: row(s), blockId: 'b', uid: 'u1', date: _day);
      final free = c([set(0), set(1), set(2)]);
      final f1 = free.sets[0], f2 = free.sets[1];
      final W = f1.weight.hintValue!, R = f1.reps.hintValue!, I = f1.rir.hintValue!;
      final w2 = f2.weight.hintValue!, r2 = f2.reps.hintValue!, i2 = f2.rir.hintValue!;
      // ignore: avoid_print
      print('FREE  S1 ${res(f1)} | S2 ${res(f2)} | S3 ${res(free.sets[2])}');
      for (final m in [1, 2, 4, 3, 5, 6, 7]) {
        final a = c([
          set(0, w: m & 1 != 0 ? W : null, r: m & 2 != 0 ? R : null, rir: m & 4 != 0 ? I : null),
          set(1), set(2)
        ]);
        final b = c([
          set(0), set(1, w: m & 1 != 0 ? w2 : null, r: m & 2 != 0 ? r2 : null, rir: m & 4 != 0 ? i2 : null), set(2)
        ]);
        String tag(Wes2ExerciseRow x, int k) => res(x.sets[k]).replaceAll('*', '') == res(free.sets[k]) ? 'same' : 'JUMP';
        // ignore: avoid_print
        print('accept S1 mask=$m → S1 ${res(a.sets[0])} [${tag(a, 0)}] S2 ${res(a.sets[1])} [${tag(a, 1)}]   '
            '|| accept S2 mask=$m → S2 ${res(b.sets[1])} [${tag(b, 1)}] S3 ${res(b.sets[2])} [${tag(b, 2)}]');
      }
    });
  }
}
