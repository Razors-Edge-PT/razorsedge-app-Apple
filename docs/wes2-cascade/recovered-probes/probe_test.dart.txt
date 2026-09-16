// THROWAWAY DIAGNOSTIC PROBE — not part of the repo. Prints traces only.
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
const _blockId = 'b1';
final _blockStart = DateTime(2026, 1, 5);
final _blockEnd = DateTime(2026, 4, 1);
final _day = DateTime(2026, 1, 12);

List<Map<String, dynamic>> _history(double w, int r, double rir) => [
      {
        'date': DateTime(2026, 1, 5),
        'exercises': [
          {
            'exerciseId': _exId,
            'name': _exName,
            'sets': [
              {'weight': w, 'reps': r, 'rir': rir}
            ]
          }
        ]
      }
    ];

Map<String, dynamic> _settings({String rep = '7 x 3', String s1Rir = '2', int sets = 5}) => {
      _exId: {
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': {'primary': 2.5},
        'repTargets': {
          'week1': {'instance1': rep},
          'week2': {'instance1': rep},
        },
        'rirPlan': {
          for (final wk in const ['week1', 'week2'])
            wk: {
              'session1': {
                'set1': {'rir': s1Rir},
                for (int i = 2; i <= sets; i++) 'set$i': {'rir': '2'},
              }
            }
        },
      }
    };

class Spy implements Wes2HintService {
  Spy(this.inner);
  final Wes2HintService inner;
  final inputs = <Wes2ExerciseRow>[];
  @override
  Wes2ExerciseRow computeRowHints({required Wes2ExerciseRow row, required String blockId, required String uid, required DateTime date}) {
    inputs.add(row);
    return inner.computeRowHints(row: row, blockId: blockId, uid: uid, date: date);
  }
  @override
  List<Wes2ExerciseRow> computeAllHints({required List<Wes2ExerciseRow> rows, required String blockId, required String uid, required DateTime date}) =>
      inner.computeAllHints(rows: rows, blockId: blockId, uid: uid, date: date);
}

({Wes2SessionController c, Spy spy, Wes2HintServiceImpl svc}) load(Map<String, dynamic> s, {int setCount = 3}) {
  final svc = Wes2HintServiceImpl(exerciseSettings: s, blockStartDate: _blockStart, blockEndDate: _blockEnd, uid: _uid);
  final spy = Spy(svc);
  final c = Wes2SessionController(_day)
    ..initIdentity(actorUid: _uid, actingUid: _uid, isCoach: false, activeBlockId: _blockId, blockStartDate: _blockStart, blockEndDate: _blockEnd)
    ..setExerciseSettings(s);
  final e = c.beginLoad();
  c.setRows([
    Wes2ExerciseRow(exerciseId: _exId, name: _exName, circuitIndex: 0, orderIndex: 0, setCount: setCount, source: Wes2RowSource.wes2Manual, sets: List.generate(setCount, (i) => Wes2SetState(setIndex: i)))
  ], e);
  screenPass(c, svc);
  c.setHintService(spy, _blockId);
  return (c: c, spy: spy, svc: svc);
}

/// Mirrors WES2_screen._loadAndApplyHints' synchronous tail.
void screenPass(Wes2SessionController c, Wes2HintService svc) {
  for (final r in c.rows.toList()) {
    c.applyModelHints(r.exerciseId, svc.computeRowHints(row: r, blockId: _blockId, uid: _uid, date: _day));
  }
  c.captureBaselineHintRows();
}

void t(Wes2SessionController c, int i, Wes2FieldKey k, String v) =>
    c.updateSetField(exerciseId: _exId, setIndex: i, fieldKey: k, rawText: v);

String f(Wes2SetState s) {
  String fld<T>(Wes2FieldState<T> x) => x.actualValue != null ? '${x.actualValue}*' : '${x.hintValue}';
  final w = s.weight.actualValue ?? s.weight.hintValue;
  final r = s.reps.actualValue ?? s.reps.hintValue;
  final rir = s.rir.actualValue ?? s.rir.hintValue ?? 0.0;
  final e = (w != null && r != null) ? PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), rir).toStringAsFixed(1) : '-';
  return 'S${s.setIndex + 1} ${fld(s.weight)} x ${fld(s.reps)} @ ${fld(s.rir)} e1rm=$e';
}

void dump(String label, Wes2SessionController c) {
  // ignore: avoid_print
  print('--- $label');
  for (final s in c.rows.first.sets) {
    // ignore: avoid_print
    print('   ${f(s)}');
  }
}

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = _history(35.0, 8, 2.0);
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  test('P1 anchor: Set 2 window trapped on its own baseline rep hint', () {
    final d = load(_settings());
    dump('baseline', d.c);
    t(d.c, 0, Wes2FieldKey.weight, '20');
    t(d.c, 0, Wes2FieldKey.reps, '20');
    t(d.c, 0, Wes2FieldKey.rir, '0');
    dump('after S1 = 20x20@0', d.c);
  });

  test('P2 same-value suppression hides a later-set entry from the cascade', () {
    final d = load(_settings());
    final b = d.c.rows.first;
    dump('baseline', d.c);
    t(d.c, 0, Wes2FieldKey.weight, '30');
    dump('after S1 weight 30', d.c);
    final w2 = b.sets[1].weight.hintValue!;
    t(d.c, 1, Wes2FieldKey.weight, w2.toString());
    dump('after S2 weight typed = its BASELINE hint $w2', d.c);
    final inp = d.spy.inputs.last.sets[1];
    // ignore: avoid_print
    print('   recalc input S2 weight actual=${inp.weight.actualValue}');
    t(d.c, 1, Wes2FieldKey.weight, (w2 - 2.5).toString());
    dump('control: S2 weight typed ${w2 - 2.5} (≠ baseline)', d.c);
  });

  test('P3 actual RIR 3.0 equal to hint loses actual-only authority', () {
    for (final rir in ['3', '3.5']) {
      final d = load(_settings(rep: '8 x 3', s1Rir: '3'));
      dump('baseline (s1Rir plan 3)', d.c);
      t(d.c, 0, Wes2FieldKey.rir, rir);
      t(d.c, 1, Wes2FieldKey.reps, '3');
      dump('S1 actual RIR $rir, S2 reps 3', d.c);
      // ignore: avoid_print
      print('   recalc input S1 rir actual=${d.spy.inputs.last.sets[0].rir.actualValue}');
    }
  });

  test('P4 re-pass (addSet/settings/replace) recaptures contaminated baseline', () {
    final d = load(_settings());
    dump('load-time', d.c);
    t(d.c, 0, Wes2FieldKey.weight, '25');
    t(d.c, 0, Wes2FieldKey.reps, '15');
    dump('after S1 25x15', d.c);
    d.c.addSet(_exId);
    screenPass(d.c, d.svc); // what _onAddSet -> _loadAndApplyHints does
    dump('after addSet + screen pass (baseline recaptured)', d.c);
    t(d.c, 0, Wes2FieldKey.weight, '');
    t(d.c, 0, Wes2FieldKey.reps, '');
    dump('after clearing ALL S1 entries', d.c);
  });

  test('P5 repeated screen passes drift (own hint feeds preferredRep)', () {
    final d = load(_settings(), setCount: 5);
    t(d.c, 0, Wes2FieldKey.weight, '15');
    t(d.c, 0, Wes2FieldKey.reps, '30');
    t(d.c, 0, Wes2FieldKey.rir, '0');
    dump('edit path after S1 15x30@0', d.c);
    for (int i = 1; i <= 5; i++) {
      screenPass(d.c, d.svc);
      dump('screen pass #$i', d.c);
    }
    t(d.c, 3, Wes2FieldKey.weight, '40');
    t(d.c, 3, Wes2FieldKey.reps, '7');
    t(d.c, 3, Wes2FieldKey.rir, '0.5');
    dump('then S4 actual 40x7@0.5 (edit path, recaptured baseline)', d.c);
  });

  test('P6 removeSet leaves survivor hints from the old predecessor', () {
    final d = load(_settings());
    t(d.c, 0, Wes2FieldKey.weight, '25');
    t(d.c, 0, Wes2FieldKey.reps, '12');
    t(d.c, 1, Wes2FieldKey.weight, '20');
    t(d.c, 1, Wes2FieldKey.reps, '20');
    dump('before remove', d.c);
    d.c.removeSet(_exId, 1);
    dump('after removeSet(Set 2), no recalc', d.c);
    final fresh = d.svc.computeRowHints(row: d.c.rows.first, blockId: _blockId, uid: _uid, date: _day);
    // ignore: avoid_print
    print('   what a recompute from current state gives: ${fresh.sets.map(f).join(' | ')}');
  });

  test('P7 undo after deleteExercise loses baseline', () {
    final d = load(_settings());
    d.c.deleteExercise(_exId);
    d.c.undo();
    // ignore: avoid_print
    print('   baseline present after undo: ${d.c.debugBaselineHintRows.containsKey(_exId)}');
  });

  test('P8 unfinished input keeps previous actual', () {
    final d = load(_settings());
    t(d.c, 0, Wes2FieldKey.weight, '25');
    t(d.c, 0, Wes2FieldKey.weight, '-');
    // ignore: avoid_print
    print('   text "-" → model S1 weight actual=${d.c.rows.first.sets[0].weight.actualValue}');
    t(d.c, 0, Wes2FieldKey.weight, '.');
    // ignore: avoid_print
    print('   text "." → model S1 weight actual=${d.c.rows.first.sets[0].weight.actualValue}');
  });
}
