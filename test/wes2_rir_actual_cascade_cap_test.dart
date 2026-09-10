import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

/// Regression cover for the WES2 same-set recalculation bug where changing
/// Set 1's ACTUAL RIR could make Set 2's generated weight hint EXCEED Set 1's
/// resolved weight, despite the later-set cap rule.
///
/// Root cause (lib/WES2_controller.dart, _rowWithCurrentActualsOverBaseline):
/// the "any E1RM-relevant actual differs from baseline" test checked weight and
/// reps but NOT RIR. An RIR-only edit therefore looked like "nothing changed",
/// so the same-as-hint weight/reps actuals were suppressed to null before
/// recalculation. _computeSet1Hints then re-solved a hidden Set 1 weight hint
/// under the new RIR, and _capWeightToPrevSet measured Set 2 against that
/// re-solved hint (prev actual ?? prev hint) instead of the athlete's real
/// resolved load — letting Set 2 propose MORE weight than Set 1.
///
/// The cap rule in WES2_hint_service._capWeightToPrevSet is correct and is not
/// changed by this fix; these tests pin it end-to-end through the cascade.
///
/// Every scenario here uses modelHint origins only — there is no BB3 value or
/// override anywhere in this file, matching the confirmed production report.

const String _exId = 'ex_shoulder_press';
const String _exName = 'Seated Shoulder Dumbbell Press';
const String _blockId = 'block_1';
const String _uid = 'u1';

final DateTime _blockStart = DateTime(2026, 1, 5);
final DateTime _blockEnd = DateTime(2026, 4, 1);
final DateTime _day = DateTime(2026, 1, 12); // week 2, session 1

/// One prior top set. The E1RM this implies is what the progression engine
/// projects the day's Set 1 target from.
List<Map<String, dynamic>> _history(double weight, int reps, double rir) => [
      {
        'date': DateTime(2026, 1, 5),
        'exercises': [
          {
            'exerciseId': _exId,
            'name': _exName,
            'sets': [
              {'weight': weight, 'reps': reps, 'rir': rir},
            ],
          }
        ],
      },
    ];

Map<String, dynamic> _settings({
  required String repTarget,
  required String set1Rir,
  double increment = 2.5,
}) =>
    {
      _exId: {
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': {'primary': increment},
        'repTargets': {
          'week1': {'instance1': repTarget},
          'week2': {'instance1': repTarget},
        },
        'rirPlan': {
          for (final wk in const ['week1', 'week2'])
            wk: {
              'session1': {
                'set1': {'rir': set1Rir},
                'set2': {'rir': '2'},
                'set3': {'rir': '2.5'},
              }
            }
        },
      }
    };

Wes2HintServiceImpl _service(Map<String, dynamic> settings) =>
    Wes2HintServiceImpl(
      exerciseSettings: settings,
      blockStartDate: _blockStart,
      blockEndDate: _blockEnd,
      uid: _uid,
    );

Wes2ExerciseRow _emptyRow({int setCount = 3}) => Wes2ExerciseRow(
      exerciseId: _exId,
      name: _exName,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: setCount,
      source: Wes2RowSource.wes2Manual,
      sets: List.generate(setCount, (i) => Wes2SetState(setIndex: i)),
    );

/// Records the row handed to computeRowHints — i.e. the recalculation INPUT
/// built by _rowWithCurrentActualsOverBaseline — while delegating to the real
/// hint service so the production cascade still runs.
class _SpyHintService implements Wes2HintService {
  _SpyHintService(this.inner);

  final Wes2HintService inner;
  final List<Wes2ExerciseRow> inputs = <Wes2ExerciseRow>[];

  Wes2ExerciseRow get lastInput => inputs.last;

  @override
  Wes2ExerciseRow computeRowHints({
    required Wes2ExerciseRow row,
    required String blockId,
    required String uid,
    required DateTime date,
  }) {
    inputs.add(row);
    return inner.computeRowHints(
        row: row, blockId: blockId, uid: uid, date: date);
  }

  @override
  List<Wes2ExerciseRow> computeAllHints({
    required List<Wes2ExerciseRow> rows,
    required String blockId,
    required String uid,
    required DateTime date,
  }) =>
      inner.computeAllHints(rows: rows, blockId: blockId, uid: uid, date: date);
}

/// Builds a controller wired exactly the way WES2 wires it at day load:
/// rows in -> initial model hints applied -> baseline captured -> hint service
/// registered for same-set recalculation.
({
  Wes2SessionController controller,
  _SpyHintService spy,
  Wes2ExerciseRow baseline,
}) _loadDay(Map<String, dynamic> settings, {int setCount = 3}) {
  final real = _service(settings);
  final spy = _SpyHintService(real);
  final controller = Wes2SessionController(_day)
    ..initIdentity(
      actorUid: _uid,
      actingUid: _uid,
      isCoach: false,
      activeBlockId: _blockId,
      blockStartDate: _blockStart,
      blockEndDate: _blockEnd,
    )
    ..setExerciseSettings(settings);

  final epoch = controller.beginLoad();
  controller.setRows([_emptyRow(setCount: setCount)], epoch);

  // Initial hint pass (the screen's applyModelHints + captureBaselineHintRows).
  final hinted = real.computeAllHints(
    rows: controller.rows,
    blockId: _blockId,
    uid: _uid,
    date: _day,
  );
  controller.applyModelHints(_exId, hinted.first);
  controller.captureBaselineHintRows();
  controller.setHintService(spy, _blockId);

  return (
    controller: controller,
    spy: spy,
    baseline: controller.rows.first,
  );
}

void _type(Wes2SessionController c, int setIndex, Wes2FieldKey key, String v) =>
    c.updateSetField(
        exerciseId: _exId, setIndex: setIndex, fieldKey: key, rawText: v);

String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// Types weight/reps/RIR actuals onto Set 1 in the order the athlete would.
void _enterSet1(
  Wes2SessionController c, {
  double? weight,
  int? reps,
  required double rir,
}) {
  if (weight != null) {
    _type(c, 0, Wes2FieldKey.weight, _num(weight));
  }
  if (reps != null) {
    _type(c, 0, Wes2FieldKey.reps, '$reps');
  }
  _type(c, 0, Wes2FieldKey.rir, _num(rir));
}

double _resolvedWeight(Wes2SetState s) =>
    s.weight.actualValue ?? s.weight.hintValue!;

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = [];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });
  tearDown(() {
    PeriodizationModelUtils.savedWorkoutsList = [];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 1 — the confirmed user-visible reproduction, end to end.
  //
  // Baseline hints produced by the REAL progression path for this fixture are
  // Set 1 = 37.5 x 7 @ 2.0 and Set 2 = 37.5. The athlete accepts Set 1 at
  // 37.5 x 7 and lowers the ACTUAL RIR to 1.0.
  //
  // Before the fix this produced Set 2 = 40.0 kg — MORE than Set 1's resolved
  // 37.5 kg, with no BB3 anywhere and Set 1's actual RIR well below 2.5.
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 1 — RIR-only edit must not let Set 2 exceed Set 1', () {
    late Map<String, dynamic> settings;

    setUp(() {
      PeriodizationModelUtils.savedWorkoutsList = _history(35.0, 8, 2.0);
      PeriodizationModelUtils.topSetsByExercise.clear();
      settings = _settings(repTarget: '7 x 3', set1Rir: '2');
    });

    test('baseline is a pure modelHint 37.5 kg day with no BB3 (TEST 10)', () {
      final d = _loadDay(settings);
      final s1 = d.baseline.sets[0];
      final s2 = d.baseline.sets[1];

      expect(s1.weight.hintValue, 37.5);
      expect(s1.reps.hintValue, 7);
      expect(s1.rir.hintValue, 2.0);
      // Set 2's exact pairing is chosen by the Set 2+ bounded weight x reps
      // solver (minimum absolute E1RM error), so it is not pinned to a literal
      // here — only the cascade invariant is. Wes2SetNSolver's own tests prove
      // the selection is the minimum-error legal candidate.
      expect(s2.weight.hintValue!, lessThanOrEqualTo(37.5));

      // No BB3 origin anywhere — this reproduction does not depend on BB3.
      for (final s in d.baseline.sets) {
        expect(s.weight.hintOrigin, isNot(FieldOrigin.bb3Hint));
        expect(s.reps.hintOrigin, isNot(FieldOrigin.bb3Hint));
        expect(s.rir.hintOrigin, isNot(FieldOrigin.bb3Hint));
      }
    });

    test('recalculation input preserves all three Set 1 actuals', () {
      final d = _loadDay(settings);
      _enterSet1(d.controller, weight: 37.5, reps: 7, rir: 1.0);

      final input = d.spy.lastInput.sets[0];
      expect(input.weight.actualValue, 37.5,
          reason: 'accepted weight must survive an RIR-only change');
      expect(input.reps.actualValue, 7,
          reason: 'accepted reps must survive an RIR-only change');
      expect(input.rir.actualValue, 1.0);
    });

    test('Set 2 generated weight stays at or below Set 1 resolved weight', () {
      final d = _loadDay(settings);
      _enterSet1(d.controller, weight: 37.5, reps: 7, rir: 1.0);

      final row = d.controller.rows.first;
      final s1Resolved = _resolvedWeight(row.sets[0]);
      final s2Generated = row.sets[1].weight.hintValue!;

      expect(s1Resolved, 37.5);
      expect(s2Generated, lessThanOrEqualTo(37.5));
      expect(s2Generated, isNot(40.0),
          reason: 'the pre-fix defect suggested 40.0 kg here');
      expect(s2Generated, lessThanOrEqualTo(s1Resolved));
    });

    test('every later set stays at or below the set before it', () {
      final d = _loadDay(settings);
      _enterSet1(d.controller, weight: 37.5, reps: 7, rir: 1.0);

      final sets = d.controller.rows.first.sets;
      for (int i = 1; i < sets.length; i++) {
        expect(sets[i].weight.hintValue!,
            lessThanOrEqualTo(_resolvedWeight(sets[i - 1])),
            reason: 'set ${i + 1} must not exceed set $i');
      }
    });

    test('reps are still free to adjust to the new RIR', () {
      final d = _loadDay(settings);
      final baselineS2Reps = d.baseline.sets[1].reps.hintValue;
      _enterSet1(d.controller, weight: 37.5, reps: 7, rir: 1.0);

      final s2 = d.controller.rows.first.sets[1];
      expect(s2.reps.hintValue, isNotNull);
      // Reps respond to the RIR change; only the WEIGHT is capped.
      expect(s2.reps.hintValue, isNot(baselineS2Reps));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // The literal values from the bug report (37.5 / 8 / RIR 1.5 -> 1.0). The
  // athlete's real history is not in the repo, so this fixture's own math does
  // not cross an increment boundary — but the invariant must hold here too.
  // ───────────────────────────────────────────────────────────────────────────
  test('reported 37.5 / 8 / 1.5 with RIR 1.0 keeps Set 2 at or below 37.5', () {
    PeriodizationModelUtils.savedWorkoutsList = _history(35.0, 8, 2.0);
    PeriodizationModelUtils.topSetsByExercise.clear();
    final settings = _settings(repTarget: '8 x 3', set1Rir: '1.5');

    final d = _loadDay(settings);
    expect(d.baseline.sets[0].weight.hintValue, 37.5);
    expect(d.baseline.sets[0].rir.hintValue, 1.5);

    final acceptedReps = d.baseline.sets[0].reps.hintValue!;
    _enterSet1(d.controller, weight: 37.5, reps: acceptedReps, rir: 1.0);

    final row = d.controller.rows.first;
    expect(row.sets[0].weight.actualValue, 37.5);
    expect(row.sets[0].reps.actualValue, acceptedReps);
    expect(row.sets[0].rir.actualValue, 1.0);
    expect(row.sets[1].weight.hintValue!, lessThanOrEqualTo(37.5));
    expect(row.sets[1].weight.hintValue, isNot(40.0));
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 2-6 — baseline-overlay preservation semantics, observed on the real
  // recalculation input the controller hands to the hint service.
  // ───────────────────────────────────────────────────────────────────────────
  group('baseline overlay — which actuals survive into the recalc input', () {
    late Map<String, dynamic> settings;

    setUp(() {
      PeriodizationModelUtils.savedWorkoutsList = _history(35.0, 8, 2.0);
      PeriodizationModelUtils.topSetsByExercise.clear();
      settings = _settings(repTarget: '8 x 3', set1Rir: '1.5');
    });

    /// Loads the day, asserts the baseline Set 1 hints are 37.5 / R / 1.5,
    /// types the given Set 1 actuals, and returns the recalculation input set.
    Wes2SetState inputAfter({
      required double weight,
      required int Function(int baselineReps) reps,
      required double rir,
    }) {
      final d = _loadDay(settings);
      final b = d.baseline.sets[0];
      expect(b.weight.hintValue, 37.5);
      expect(b.rir.hintValue, 1.5);
      _enterSet1(d.controller,
          weight: weight, reps: reps(b.reps.hintValue!), rir: rir);
      return d.spy.lastInput.sets[0];
    }

    test('TEST 2/6 — RIR differing keeps weight, reps AND RIR actuals', () {
      final input =
          inputAfter(weight: 37.5, reps: (r) => r, rir: 1.0); // RIR 1.5 -> 1.0

      expect(input.weight.actualValue, 37.5,
          reason: 'weight actual must NOT be suppressed');
      expect(input.reps.actualValue, isNotNull,
          reason: 'reps actual must NOT be suppressed');
      expect(input.rir.actualValue, 1.0,
          reason: 'RIR actual must NOT be suppressed');
      // The preserved actuals are what the cascade treats as authoritative.
      expect(input.weight.origin, FieldOrigin.typed);
      expect(input.reps.origin, FieldOrigin.typed);
      expect(input.rir.origin, FieldOrigin.typed);
    });

    test('TEST 3 — nothing differs: same-value suppression still applies', () {
      final input =
          inputAfter(weight: 37.5, reps: (r) => r, rir: 1.5); // all == hints

      expect(input.weight.actualValue, isNull,
          reason: 'accepted-verbatim weight is still suppressed');
      expect(input.reps.actualValue, isNull,
          reason: 'accepted-verbatim reps is still suppressed');
      expect(input.rir.actualValue, isNull,
          reason: 'accepted-verbatim RIR is still suppressed');
    });

    test('TEST 4 — weight differing preserves all three actuals', () {
      final input = inputAfter(weight: 40.0, reps: (r) => r, rir: 1.5);

      expect(input.weight.actualValue, 40.0);
      expect(input.reps.actualValue, isNotNull);
      expect(input.rir.actualValue, 1.5);
    });

    test('TEST 5 — reps differing preserves all three actuals', () {
      final input = inputAfter(weight: 37.5, reps: (r) => r - 1, rir: 1.5);

      expect(input.weight.actualValue, 37.5);
      expect(input.reps.actualValue, isNotNull);
      expect(input.rir.actualValue, 1.5);
    });

    test('clearing the RIR actual restores the original baseline hints', () {
      final d = _loadDay(settings);
      final baselineS2Weight = d.baseline.sets[1].weight.hintValue;
      final baselineS2Reps = d.baseline.sets[1].reps.hintValue;

      _type(d.controller, 0, Wes2FieldKey.rir, '1.0');
      _type(d.controller, 0, Wes2FieldKey.rir, ''); // cleared

      final s2 = d.controller.rows.first.sets[1];
      expect(s2.weight.hintValue, baselineS2Weight);
      expect(s2.reps.hintValue, baselineS2Reps);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 7-9 — the cap boundary, exercised through the full cascade rather
  // than the direct _capWeightToPrevSet unit test.
  //
  // The athlete performs Set 1 one increment BELOW the day's projected load and
  // then enters a LOW rep count on Set 2. With Set 2's reps locked, the cascade
  // solves Set 2's weight at those reps, and that solved weight genuinely lands
  // above Set 1's resolved weight — so the cap is actually load-bearing here.
  // ───────────────────────────────────────────────────────────────────────────
  group('cap boundary through the full cascade', () {
    late Map<String, dynamic> settings;

    setUp(() {
      PeriodizationModelUtils.savedWorkoutsList = _history(37.5, 8, 2.0);
      PeriodizationModelUtils.topSetsByExercise.clear();
      settings = _settings(repTarget: '8 x 3', set1Rir: '1.5');
    });

    ({double s1Resolved, double s2Generated}) run({
      double? set1ActualRir,
      int set2Reps = 3,
    }) {
      final d = _loadDay(settings);
      final projected = d.baseline.sets[0].weight.hintValue!;

      _type(d.controller, 0, Wes2FieldKey.weight, _num(projected - 2.5));
      _type(d.controller, 0, Wes2FieldKey.reps,
          '${d.baseline.sets[0].reps.hintValue}');
      if (set1ActualRir != null) {
        _type(d.controller, 0, Wes2FieldKey.rir, _num(set1ActualRir));
      }
      // Low rep count on Set 2 forces the cascade to solve a HIGHER weight.
      _type(d.controller, 1, Wes2FieldKey.reps, '$set2Reps');

      final row = d.controller.rows.first;
      return (
        s1Resolved: _resolvedWeight(row.sets[0]),
        s2Generated: row.sets[1].weight.hintValue!,
      );
    }

    test('the fixture really does propose an increase (cap is load-bearing)',
        () {
      // With RIR 3.0 the cap does not apply, so the raw proposal is visible.
      final uncapped = run(set1ActualRir: 3.0);
      expect(uncapped.s2Generated, greaterThan(uncapped.s1Resolved),
          reason: 'without the cap the model wants MORE than Set 1');
    });

    test('TEST 7 — actual RIR 2.5 (the boundary) still caps Set 2', () {
      final r = run(set1ActualRir: 2.5);
      expect(r.s2Generated, lessThanOrEqualTo(r.s1Resolved),
          reason: 'RIR 2.5 is NOT strictly greater than 2.5');
    });

    for (final rir in const [1.0, 1.5, 2.0, 2.5]) {
      test('actual RIR $rir permits no increase', () {
        final r = run(set1ActualRir: rir);
        expect(r.s2Generated, lessThanOrEqualTo(r.s1Resolved));
      });
    }

    test('TEST 8 — actual RIR 3.0 does not suppress a proposed increase', () {
      final capped = run(set1ActualRir: 2.5);
      final permitted = run(set1ActualRir: 3.0);

      // Permission only: above the boundary the cap must not clamp the model's
      // own proposal down to Set 1's weight. This asserts the cap stops
      // applying — it does not force progression to increase.
      expect(permitted.s2Generated, greaterThan(capped.s2Generated),
          reason: 'RIR > 2.5 must release the cap');
      expect(permitted.s2Generated, greaterThan(permitted.s1Resolved));
    });

    test('TEST 9 — hint-only RIR above 2.5 is still capped', () {
      final settings3 = _settings(repTarget: '8 x 3', set1Rir: '3');
      PeriodizationModelUtils.savedWorkoutsList = _history(37.5, 8, 2.0);
      PeriodizationModelUtils.topSetsByExercise.clear();

      final d = _loadDay(settings3);
      expect(d.baseline.sets[0].rir.hintValue, 3.0,
          reason: 'Set 1 carries a HINT RIR of 3.0 and no actual RIR');

      final projected = d.baseline.sets[0].weight.hintValue!;
      // Weight + reps entered, Set 1 RIR deliberately left untyped.
      _type(d.controller, 0, Wes2FieldKey.weight, _num(projected - 2.5));
      _type(d.controller, 0, Wes2FieldKey.reps,
          '${d.baseline.sets[0].reps.hintValue}');
      _type(d.controller, 1, Wes2FieldKey.reps, '3');

      final row = d.controller.rows.first;
      expect(row.sets[0].rir.actualValue, isNull);
      expect(row.sets[1].weight.hintValue!,
          lessThanOrEqualTo(_resolvedWeight(row.sets[0])),
          reason: 'only an ACTUAL RIR > 2.5 may permit an increase');
    });
  });
}
