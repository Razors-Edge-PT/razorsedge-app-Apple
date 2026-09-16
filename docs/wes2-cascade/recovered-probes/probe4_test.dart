// THROWAWAY PROBE — exhaustive check of the recursive accepted-hint rule.
// raw(E)  = production Wes2HintServiceImpl.computeRowHints with set k entries E
//           (inputs carry prescriptions + entries only, no generated hints).
// view(E) = recursive rule from the plan (precedence weight, reps, rir).
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

enum F { w, r, rir }

class H {
  H(this.w, this.r, this.rir, this.cw, this.cr, this.crir);
  final double? w;
  final int? r;
  final double? rir;
  final bool cw, cr, crir;
  num? of(F f) => f == F.w ? w : (f == F.r ? r : rir);
  bool cue(F f) => f == F.w ? cw : (f == F.r ? cr : crir);
}

String fmtW(double v) => v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
num displayed(F f, num h) => f == F.w ? double.parse(fmtW(h.toDouble())) : (f == F.r ? h : double.parse(h.toDouble().toStringAsFixed(1)));
bool accepts(F f, num a, num? h) {
  if (h == null) return false;
  if (f == F.w) return (a - h).abs() <= 0.0005;
  if (f == F.r) return a == h;
  return (a - h).abs() <= 0.05 + 1e-9;
}

Wes2FieldState<double> dField(double? actual, double? bb3) => Wes2FieldState<double>(
    actualValue: actual,
    hintValue: bb3,
    hintOrigin: bb3 != null ? FieldOrigin.bb3Hint : FieldOrigin.empty,
    origin: actual != null ? FieldOrigin.typed : (bb3 != null ? FieldOrigin.bb3Hint : FieldOrigin.empty));
Wes2FieldState<int> iField(int? actual, int? bb3) => Wes2FieldState<int>(
    actualValue: actual,
    hintValue: bb3,
    hintOrigin: bb3 != null ? FieldOrigin.bb3Hint : FieldOrigin.empty,
    origin: actual != null ? FieldOrigin.typed : (bb3 != null ? FieldOrigin.bb3Hint : FieldOrigin.empty));

class SetSpec {
  const SetSpec({this.w, this.r, this.rir, this.bw, this.br, this.brir});
  final double? w, rir, bw, brir;
  final int? r, br;
}

class Fixture {
  Fixture(this.name, this.exId, this.exName, this.settings, this.history, this.sets, this.k);
  final String name, exId, exName;
  final Map<String, dynamic> settings;
  final List<Map<String, dynamic>> history;
  final List<SetSpec> sets;
  final int k;
}

Map<String, dynamic> settings(String id, {String rep = '7 x 3', List<String> rir = const ['2', '2', '2.5', '2.5'], double primary = 2.5, String? category}) => {
      id: {
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        if (category != null) 'category': category,
        'increments': {'primary': primary},
        'repTargets': {'week1': {'instance1': rep}, 'week2': {'instance1': rep}},
        'rirPlan': {
          for (final wk in const ['week1', 'week2'])
            wk: {'session1': {for (int i = 0; i < rir.length; i++) 'set${i + 1}': {'rir': rir[i]}}}
        },
      }
    };

List<Map<String, dynamic>> hist(String id, String name, double w, int r, double rir) => [
      {'date': DateTime(2026, 1, 5), 'exercises': [{'exerciseId': id, 'name': name, 'sets': [{'weight': w, 'reps': r, 'rir': rir}]}]}
    ];

const press = 'ex_press', pressName = 'Seated Shoulder Dumbbell Press';
const pull = 'ex_pullup', pullName = 'Pull-Up';

void main() {
  final fixtures = <Fixture>[
    Fixture('A S1 history', press, pressName, settings(press), hist(press, pressName, 35, 8, 2), const [SetSpec(), SetSpec(), SetSpec()], 0),
    Fixture('A S2 from S1 hints', press, pressName, settings(press), hist(press, pressName, 35, 8, 2), const [SetSpec(), SetSpec(), SetSpec()], 1),
    Fixture('A S3 after partial S1/S2', press, pressName, settings(press), hist(press, pressName, 35, 8, 2), const [SetSpec(w: 30, r: 12), SetSpec(r: 9), SetSpec()], 2),
    Fixture('B counterexample S2', press, pressName, settings(press, rep: '10 x 3', rir: const ['2', '2', '2']), const [], const [SetSpec(w: 40, r: 10, rir: 2), SetSpec(), SetSpec()], 1),
    Fixture('C BB3 S1 weight lock', press, pressName, settings(press), hist(press, pressName, 35, 8, 2), const [SetSpec(bw: 37.5), SetSpec(br: 10), SetSpec()], 0),
    Fixture('C BB3 S2 reps lock', press, pressName, settings(press), hist(press, pressName, 35, 8, 2), const [SetSpec(bw: 37.5), SetSpec(br: 10), SetSpec()], 1),
    Fixture('D BB3 S2 full lock + cues', press, pressName, settings(press), hist(press, pressName, 35, 8, 2), const [SetSpec(w: 40, r: 6, rir: 1), SetSpec(bw: 35, br: 8, brir: 2), SetSpec()], 1),
    Fixture('E extra set S4', press, pressName, settings(press), hist(press, pressName, 35, 8, 2), const [SetSpec(w: 37.5, r: 7, rir: 2), SetSpec(), SetSpec(), SetSpec()], 3),
    Fixture('F rounding rir 1.25 grid 1.25', press, pressName, settings(press, rir: const ['1.25', '1.25', '1.25'], primary: 1.25), hist(press, pressName, 30, 9, 1), const [SetSpec(w: 30, r: 9, rir: 1), SetSpec(), SetSpec()], 1),
    Fixture('G bodyweight S2', pull, pullName, settings(pull), hist(pull, pullName, 20, 8, 2), const [SetSpec(w: 20, r: 8, rir: 2), SetSpec(), SetSpec()], 1),
    Fixture('H zero RIR prev S2', press, pressName, settings(press), hist(press, pressName, 35, 8, 2), const [SetSpec(w: 37.5, r: 8, rir: 0), SetSpec(), SetSpec()], 1),
  ];

  for (final fx in fixtures) {
    test(fx.name, () {
      PeriodizationModelUtils.savedWorkoutsList = fx.history;
      PeriodizationModelUtils.topSetsByExercise.clear();
      final svc = Wes2HintServiceImpl(exerciseSettings: fx.settings, blockStartDate: DateTime(2026, 1, 5), blockEndDate: null, uid: 'u1');

      final rawMemo = <String, H>{};
      final viewMemo = <String, H>{};
      String key(Map<F, num> e) => F.values.map((f) => '${e[f]}').join('|');

      H raw(Map<F, num> e) => rawMemo.putIfAbsent(key(e), () {
            final sets = <Wes2SetState>[];
            for (int i = 0; i < fx.sets.length; i++) {
              final s = fx.sets[i];
              final isK = i == fx.k;
              sets.add(Wes2SetState(
                setIndex: i,
                weight: dField(isK ? e[F.w]?.toDouble() : s.w, s.bw),
                reps: iField(isK ? e[F.r]?.toInt() : s.r, s.br),
                rir: dField(isK ? e[F.rir]?.toDouble() : s.rir, s.brir),
              ));
            }
            final row = Wes2ExerciseRow(exerciseId: fx.exId, name: fx.exName, circuitIndex: 0, orderIndex: 0, setCount: fx.sets.length, source: Wes2RowSource.wes2Manual, sets: sets);
            final o = svc.computeRowHints(row: row, blockId: 'b', uid: 'u1', date: DateTime(2026, 1, 12)).sets[fx.k];
            return H(o.weight.hintValue, o.reps.hintValue, o.rir.hintValue, o.weightLockedByBb3OverrideCue, o.repsLockedByBb3OverrideCue, o.rirLockedByBb3OverrideCue);
          });

      H view(Map<F, num> e) {
        final k = key(e);
        final m = viewMemo[k];
        if (m != null) return m;
        for (final f in F.values) {
          if (!e.containsKey(f)) continue;
          final sub = view(Map.of(e)..remove(f));
          if (accepts(f, e[f]!, sub.of(f))) return viewMemo[k] = sub;
        }
        return viewMemo[k] = raw(e);
      }

      bool sameOthers(H a, H b, Set<F> entered) =>
          F.values.where((g) => !entered.contains(g)).every((g) => a.of(g) == b.of(g) && a.cue(g) == b.cue(g));

      int acceptSteps = 0, viewBreaks = 0, rawBreaks = 0, ambiguous = 0, ambiguousDiffer = 0, i1Violations = 0, states = 0;
      final seen = <String>{};

      void explore(Map<F, num> e) {
        if (!seen.add(key(e))) return;
        states++;
        // ambiguity: several matching f with differing remaining hints/cues
        final matches = <H>[];
        for (final f in F.values) {
          if (!e.containsKey(f)) continue;
          final sub = view(Map.of(e)..remove(f));
          if (accepts(f, e[f]!, sub.of(f))) matches.add(sub);
        }
        if (matches.length > 1) {
          ambiguous++;
          if (matches.any((m) => !sameOthers(m, matches.first, e.keys.toSet()))) {
            ambiguousDiffer++;
            // ignore: avoid_print
            print('   AMBIGUOUS-DIFFER E=$e');
          }
        }
        // I1: rir hint independent of this set's weight/reps entries (rir unentered, not both w&r)
        if (!e.containsKey(F.rir) && !(e.containsKey(F.w) && e.containsKey(F.r))) {
          if (raw(e).rir != raw({}).rir) {
            i1Violations++;
            // ignore: avoid_print
            print('   I1-VIOLATION E=$e raw.rir=${raw(e).rir} free.rir=${raw({}).rir}');
          }
        }
        final cur = view(e);
        for (final f in F.values) {
          if (e.containsKey(f)) continue;
          final h = cur.of(f);
          final values = <num>{};
          if (h != null) {
            final acc = displayed(f, h);
            values.add(acc);
            final e2 = Map.of(e)..[f] = acc;
            acceptSteps++;
            if (!sameOthers(view(e2), cur, e2.keys.toSet())) {
              viewBreaks++;
              // ignore: avoid_print
              print('   VIEW-BREAK E=$e accept $f=$acc');
            }
            if (!sameOthers(raw(e2), raw(e), e2.keys.toSet())) rawBreaks++;
            // non-hint alternatives
            if (f == F.w) { values.add(acc - 2.5); values.add(acc + 2.5); }
            if (f == F.r) { values.add(acc - 2); values.add(acc + 2); }
            if (f == F.rir) { values.add(acc + 1); values.add(0.0); }
          } else {
            values.addAll(f == F.w ? [30.0, 37.5] : f == F.r ? [6, 10] : [0.0, 2.0]);
          }
          for (final v in values) {
            if (v is int && v < 1) continue;
            if (v < 0) continue;
            explore(Map.of(e)..[f] = v);
          }
        }
      }

      explore({});
      final free = raw({});
      // ignore: avoid_print
      print('RESULT ${fx.name}: free=(${free.w}, ${free.r}, ${free.rir}) states=$states acceptSteps=$acceptSteps '
          'viewBreaks=$viewBreaks rawBreaks(no rule)=$rawBreaks ambiguous=$ambiguous ambiguousDiffer=$ambiguousDiffer I1violations=$i1Violations');
    });
  }
}
