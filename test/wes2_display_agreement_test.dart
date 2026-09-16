// What the cascade CONSUMED must equal what the previous row SHOWS.
//
// Asserted at three levels, because each can hide a fault the others do not:
//   1. numerically, on the model values (a mismatch smaller than the display
//      precision would survive a text comparison);
//   2. on provenance, so an accepted value is still distinguishable from a
//      hint — the weight cap only answers to an ENTERED RIR;
//   3. on the rendered text, through the real row widget and its formatters.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/wes2_cascade_resolver.dart';
import 'package:localtest222/wes2_setn_solver.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
const _blockId = 'b1';
final _blockStart = DateTime(2026, 1, 5);
final _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings() => <String, dynamic>{
      _exId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': 1.25},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': '10 x 4'},
          'week2': <String, dynamic>{'instance1': '10 x 4'},
        },
        'rirPlan': <String, dynamic>{
          for (final String wk in const <String>['week1', 'week2'])
            wk: <String, dynamic>{
              'session1': <String, dynamic>{
                'set1': <String, dynamic>{'rir': '2'},
                'set2': <String, dynamic>{'rir': '2'},
                'set3': <String, dynamic>{'rir': '2.5'},
                'set4': <String, dynamic>{'rir': '2.5'},
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
      exerciseId: _exId,
      name: _exName,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: 4,
      source: Wes2RowSource.wes2Manual,
      sets:
          List<Wes2SetState>.generate(4, (int i) => Wes2SetState(setIndex: i)),
    )
  ], epoch);
  c.applyHintContext(_svc(), _blockId);
  return c;
}

void _type(Wes2SessionController c, int i, Wes2FieldKey k, String v) =>
    c.updateSetField(exerciseId: _exId, setIndex: i, fieldKey: k, rawText: v);

/// The independent reference model: what the next set SHOULD be, derived only
/// from what the previous row shows plus the unchanged formulas.
///
/// This is deliberately not a call into the cascade — it recomputes the target
/// from the predecessor's DISPLAYED values (actual where entered, hint
/// otherwise), then brute-forces the documented candidate space.
({double weight, int reps}) _expectedFromDisplayed({
  required Wes2SetState previousFinal,
  required double thisRir,
  required int setIdx,
}) {
  final v = Wes2CascadeResolver.resolvedValues(previousFinal);
  final double prevE1rm = PeriodizationModelUtils.calculateE1RM(
      v.weight!, v.reps!.toDouble(), v.rir ?? 0.0);
  // Group C: raw drop 1.0 at every set index, gated by the previous RIR.
  final double prevRir = v.rir ?? 0.0;
  final double drop = prevRir > 2.0
      ? 0.0
      : (prevRir >= 1.8 && prevRir <= 2.0 ? 0.8 : 1.0);
  final double target = (prevE1rm - drop).clamp(1.0, 9999.0);

  final IncrementGrid grid = IncrementGrid(primary: 1.25);
  final List<double> weights = Wes2SetNSolver.weightCandidates(
    previousResolvedDisplayWeight: v.weight!,
    previousActualRir: previousFinal.rir.actualValue,
    grid: grid,
  );
  final int centre = Wes2SetNSolver.centre(
    targetE1rm: target,
    absoluteWeight: grid.previousOrSame(v.weight!),
    thisRir: thisRir,
    fallbackReps: v.reps,
  ).rep;
  final List<int> reps = Wes2SetNSolver.repCandidates(preferredRep: centre);

  double bestErr = double.infinity;
  double bw = weights.first;
  int br = reps.first;
  for (final double w in weights) {
    for (final int r in reps) {
      final double err =
          (PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), thisRir) -
                  target)
              .abs();
      if (err < bestErr - 1e-9) {
        bestErr = err;
        bw = w;
        br = r;
        continue;
      }
      if (err > bestErr + 1e-9) continue;
      // Documented tie ladder.
      final int repDist = (r - centre).abs();
      final int bestRepDist = (br - centre).abs();
      final double wDist = (w - v.weight!).abs();
      final double bestWDist = (bw - v.weight!).abs();
      final bool take;
      if (repDist != bestRepDist) {
        take = repDist < bestRepDist;
      } else if ((wDist - bestWDist).abs() > 1e-9) {
        take = wDist < bestWDist;
      } else if (r != br) {
        take = r < br;
      } else {
        take = w < bw;
      }
      if (take) {
        bestErr = err;
        bw = w;
        br = r;
      }
    }
  }
  return (weight: bw, reps: br);
}

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[
      <String, dynamic>{
        'date': DateTime(2026, 1, 5),
        'exercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': _exId,
            'name': _exName,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{'weight': 35.0, 'reps': 8, 'rir': 2.0}
            ],
          }
        ],
      }
    ];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });
  tearDown(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  group('H-AGREE-CONSUMED-NUMERIC — every set derives from what the previous '
      'set SHOWS', () {
    for (final String scenario in const <String>[
      'no entries',
      'set 1 entered',
      'set 2 partly entered',
      'accepted hints',
      'later set entered first',
    ]) {
      test(scenario, () {
        final Wes2SessionController c = _load();
        switch (scenario) {
          case 'set 1 entered':
            _type(c, 0, Wes2FieldKey.weight, '36.25');
            _type(c, 0, Wes2FieldKey.reps, '9');
            _type(c, 0, Wes2FieldKey.rir, '1');
            break;
          case 'set 2 partly entered':
            _type(c, 0, Wes2FieldKey.weight, '36.25');
            _type(c, 1, Wes2FieldKey.reps, '11');
            break;
          case 'accepted hints':
            final Wes2SetState s0 = c.rows.first.sets[0];
            _type(c, 0, Wes2FieldKey.weight, s0.weight.hintValue!.toString());
            _type(c, 0, Wes2FieldKey.reps, s0.reps.hintValue!.toString());
            break;
          case 'later set entered first':
            _type(c, 3, Wes2FieldKey.weight, '20');
            _type(c, 0, Wes2FieldKey.weight, '40');
            break;
        }

        final Wes2ExerciseRow row = c.rows.first;
        for (int i = 1; i < row.setCount; i++) {
          final Wes2SetState set = row.sets[i];
          // A set whose own weight or reps were entered is constrained; the
          // free-field assertion applies to the fields the cascade chose.
          if (set.weight.actualValue != null || set.reps.actualValue != null) {
            continue;
          }
          final double thisRir =
              set.rir.actualValue ?? set.rir.hintValue ?? 0.0;
          final expected = _expectedFromDisplayed(
            previousFinal: row.sets[i - 1],
            thisRir: thisRir,
            setIdx: i,
          );
          expect(set.weight.hintValue, expected.weight,
              reason: 'set \${i + 1} weight does not follow what set \$i shows');
          expect(set.reps.hintValue, expected.reps,
              reason: 'set \${i + 1} reps do not follow what set \$i shows');
        }
      });
    }
  });

  test('H-AGREE-PROVENANCE an accepted value stays an actual, not a hint', () {
    final Wes2SessionController c = _load();
    final Wes2SetState before = c.rows.first.sets[0];
    _type(c, 0, Wes2FieldKey.rir, before.rir.hintValue!.toString());

    final Wes2SetState after = c.rows.first.sets[0];
    expect(after.rir.actualValue, isNotNull,
        reason: 'accepting a hint records a real entry');
    expect(after.rir.origin, FieldOrigin.typed);
    // And the value the next set consumes is that actual.
    final v = Wes2CascadeResolver.resolvedValues(after);
    expect(v.rir, after.rir.actualValue);
  });

  testWidgets('H-AGREE-RENDERED-TEXT the row shows exactly what was consumed',
      (WidgetTester tester) async {
    final Wes2SessionController c = _load();
    _type(c, 0, Wes2FieldKey.weight, '36.25');
    _type(c, 1, Wes2FieldKey.reps, '11');

    final Wes2ExerciseRow row = c.rows.first;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            for (final Wes2SetState s in row.sets)
              Wes2SetRow(
                set: s,
                showVelocity: false,
                onFieldChanged: (_, __) {},
                onFieldUnfocused: (_, __) {},
              ),
          ],
        ),
      ),
    ));

    for (int i = 0; i < row.setCount; i++) {
      final v = Wes2CascadeResolver.resolvedValues(row.sets[i]);
      final Finder rowFinder = find.byType(Wes2SetRow).at(i);
      final Finder fields = find.descendant(
          of: rowFinder, matching: find.byType(TextField));

      // An entered value is the field's TEXT; a hint is its hintText. Either
      // way the string must be the formatted value the cascade consumed.
      String shownAt(int fieldIndex) {
        final TextField f = tester.widget<TextField>(fields.at(fieldIndex));
        final String typed = f.controller?.text ?? '';
        return typed.isNotEmpty ? typed : (f.decoration?.hintText ?? '');
      }

      expect(shownAt(0), Wes2HintFormat.weight(v.weight!),
          reason: 'set ${i + 1} weight');
      expect(shownAt(1), Wes2HintFormat.reps(v.reps!),
          reason: 'set ${i + 1} reps');
      expect(shownAt(2), Wes2HintFormat.rir(v.rir!), reason: 'set ${i + 1} RIR');
    }
  });
}
