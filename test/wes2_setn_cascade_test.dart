import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/wes2_setn_solver.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/periodization_model_utils.dart';

/// End-to-end cover for the WES2 Set 2+ bounded candidate cascade.
///
/// `wes2_setn_solver_test.dart` pins the pure solver. This file proves the
/// hint service actually routes Set 2+ through it: that the target E1RM still
/// comes from the immediately preceding RESOLVED set (`actual ?? hint`), that
/// the cascade stays sequential (Set 3 from Set 2, not from Set 1), that
/// constraints and BB3 locks stay authoritative, and that the whole thing is
/// blind to which progression model produced Set 1.

const String _exId = 'ex_press';
const String _exName = 'Seated Shoulder Dumbbell Press';
const String _bwId = 'ex_pullup';
const String _bwName = 'Pull-Up';
/// Real timed exercise id from PeriodizationModelUtils._timedById.
const String _timedId = 'DTkkN5pi05RWQyNYhizQ';
const String _timedName = 'Weighted Plank';
const String _uid = 'u1';
const String _blockId = 'b1';

final DateTime _blockStart = DateTime(2026, 1, 5);
final DateTime _blockEnd = DateTime(2026, 4, 1);
final DateTime _day = DateTime(2026, 1, 12); // week 2, session 1

double _e1rm(double w, num r, double rir) =>
    PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), rir);

/// Reference copy of the WES drop rule for the default group C, used to derive
/// the expected target E1RM independently of the service.
double _gatedDropC(double prevRir) {
  const raw = 1.0; // group C raw drop, every set index
  if (prevRir > 2.0) return 0.0;
  if (prevRir >= 1.8 && prevRir <= 2.0) return raw * 0.8;
  return raw;
}

double _targetFrom({
  required double prevWeightAbs,
  required int prevReps,
  required double prevRir,
}) {
  final prevE1rm = _e1rm(prevWeightAbs, prevReps, prevRir);
  return (prevE1rm - _gatedDropC(prevRir)).clamp(1.0, 9999.0);
}

/// Independent brute force over the legal candidate space.
({double weight, int reps, double error}) _bestLegal({
  required double target,
  required double prevDisplayWeight,
  required double? prevActualRir,
  required int preferredRep,
  required double thisRir,
  IncrementGrid? grid,
  double Function(double)? toAbs,
  List<int>? repsOverride,
  List<double>? weightsOverride,
}) {
  final weights = weightsOverride ??
      Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: prevDisplayWeight,
        previousActualRir: prevActualRir,
        grid: grid ?? IncrementGrid(primary: 2.5),
      );
  final reps =
      repsOverride ?? Wes2SetNSolver.repCandidates(preferredRep: preferredRep);

  double bestErr = double.infinity;
  double bw = weights.first;
  int br = reps.first;
  for (final w in weights) {
    final aw = toAbs == null ? w : toAbs(w);
    for (final r in reps) {
      final err = (_e1rm(aw, r, thisRir) - target).abs();
      if (err < bestErr - 1e-12) {
        bestErr = err;
        bw = w;
        br = r;
      }
    }
  }
  return (weight: bw, reps: br, error: bestErr);
}

Map<String, dynamic> _settings({
  String repTarget = '7 x 3',
  String set1Rir = '2',
  String set2Rir = '2',
  String set3Rir = '2.5',
  double primary = 2.5,
  double? secondary,
  String? progressionModel,
  String exerciseId = _exId,
}) =>
    {
      exerciseId: {
        'periodizationModel': 'Linear, Classic',
        if (progressionModel != null) 'progressionModel': progressionModel,
        'weeklyFrequency': 1,
        'increments': {
          'primary': primary,
          if (secondary != null) 'secondary': secondary,
        },
        'repTargets': {
          'week1': {'instance1': repTarget},
          'week2': {'instance1': repTarget},
        },
        'rirPlan': {
          for (final wk in const ['week1', 'week2'])
            wk: {
              'session1': {
                'set1': {'rir': set1Rir},
                'set2': {'rir': set2Rir},
                'set3': {'rir': set3Rir},
                'set4': {'rir': set3Rir},
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

Wes2FieldState<T> _field<T extends Object>({
  T? actual,
  T? hint,
  FieldOrigin hintOrigin = FieldOrigin.modelHint,
}) =>
    Wes2FieldState<T>(
      actualValue: actual,
      hintValue: hint,
      hintOrigin: hint == null ? FieldOrigin.empty : hintOrigin,
      origin: actual != null
          ? FieldOrigin.typed
          : (hint == null ? FieldOrigin.empty : hintOrigin),
    );

Wes2SetState _set(
  int i, {
  double? w,
  int? r,
  double? rir,
  double? wHint,
  int? rHint,
  double? rirHint,
  FieldOrigin wHintOrigin = FieldOrigin.modelHint,
  FieldOrigin rHintOrigin = FieldOrigin.modelHint,
}) =>
    Wes2SetState(
      setIndex: i,
      weight: _field<double>(actual: w, hint: wHint, hintOrigin: wHintOrigin),
      reps: _field<int>(actual: r, hint: rHint, hintOrigin: rHintOrigin),
      rir: _field<double>(actual: rir, hint: rirHint),
    );

Wes2ExerciseRow _row(
  List<Wes2SetState> sets, {
  String exerciseId = _exId,
  String name = _exName,
}) =>
    Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: sets.length,
      source: Wes2RowSource.wes2Manual,
      sets: sets,
    );

Wes2ExerciseRow _compute(Map<String, dynamic> settings, Wes2ExerciseRow row) =>
    _service(settings)
        .computeRowHints(row: row, blockId: _blockId, uid: _uid, date: _day);

double _resolvedW(Wes2SetState s) => s.weight.actualValue ?? s.weight.hintValue!;
int _resolvedR(Wes2SetState s) => s.reps.actualValue ?? s.reps.hintValue!;

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
  // TEST 16 — shoulder-press regression through the real controller.
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 16 — shoulder press through controller + hint service', () {
    late Map<String, dynamic> settings;
    late Wes2SessionController controller;
    late Wes2ExerciseRow baseline;

    setUp(() {
      PeriodizationModelUtils.savedWorkoutsList = [
        {
          'date': DateTime(2026, 1, 5),
          'exercises': [
            {
              'exerciseId': _exId,
              'name': _exName,
              'sets': [
                {'weight': 35.0, 'reps': 8, 'rir': 2.0},
              ],
            }
          ],
        }
      ];
      PeriodizationModelUtils.topSetsByExercise.clear();
      settings = _settings();

      final svc = _service(settings);
      controller = Wes2SessionController(_day)
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
      controller.setRows(
        [_row(List.generate(3, (i) => Wes2SetState(setIndex: i)))],
        epoch,
      );
      final hinted = svc.computeAllHints(
          rows: controller.rows, blockId: _blockId, uid: _uid, date: _day);
      controller.applyModelHints(_exId, hinted.first);
      controller.captureBaselineHintRows();
      controller.setHintService(svc, _blockId);
      baseline = controller.rows.first;
    });

    void type(int i, Wes2FieldKey k, String v) => controller.updateSetField(
        exerciseId: _exId, setIndex: i, fieldKey: k, rawText: v);

    test('baseline is a no-BB3 37.5 kg day', () {
      expect(baseline.sets[0].weight.hintValue, 37.5);
      expect(baseline.sets[0].reps.hintValue, 7);
      expect(baseline.sets[0].rir.hintValue, 2.0);
      for (final s in baseline.sets) {
        expect(s.weight.hintOrigin, isNot(FieldOrigin.bb3Hint));
        expect(s.reps.hintOrigin, isNot(FieldOrigin.bb3Hint));
        expect(s.rir.hintOrigin, isNot(FieldOrigin.bb3Hint));
      }
    });

    test('Set 2 is the minimum-error legal candidate for the live target', () {
      // Athlete accepts 37.5 x 7 and drops the actual RIR to 1.0.
      type(0, Wes2FieldKey.weight, '37.5');
      type(0, Wes2FieldKey.reps, '7');
      type(0, Wes2FieldKey.rir, '1.0');

      final row = controller.rows.first;
      final s1 = row.sets[0];
      expect(_resolvedW(s1), 37.5);
      expect(_resolvedR(s1), 7);
      expect(s1.rir.actualValue, 1.0);

      // Target derives from the LATEST resolved Set 1.
      final target =
          _targetFrom(prevWeightAbs: 37.5, prevReps: 7, prevRir: 1.0);
      final best = _bestLegal(
        target: target,
        prevDisplayWeight: 37.5,
        prevActualRir: 1.0,
        preferredRep: baseline.sets[1].reps.hintValue!,
        thisRir: 2.0,
      );

      final s2 = row.sets[1];
      expect(s2.weight.hintValue, best.weight);
      expect(s2.reps.hintValue, best.reps);

      // Legal, and never above Set 1 while the previous actual RIR is <= 2.5.
      expect(s2.weight.hintValue!, lessThanOrEqualTo(37.5));
      expect(s2.weight.hintValue, isNot(40.0));
      expect(
        Wes2SetNSolver.weightCandidates(
          previousResolvedDisplayWeight: 37.5,
          previousActualRir: 1.0,
          grid: IncrementGrid(primary: 2.5),
        ),
        contains(s2.weight.hintValue),
      );
    });

    test('no later set exceeds the set before it', () {
      type(0, Wes2FieldKey.weight, '37.5');
      type(0, Wes2FieldKey.reps, '7');
      type(0, Wes2FieldKey.rir, '1.0');
      final sets = controller.rows.first.sets;
      for (int i = 1; i < sets.length; i++) {
        expect(_resolvedW(sets[i]), lessThanOrEqualTo(_resolvedW(sets[i - 1])));
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 17 / 19 — cascade sourcing with no user input at all.
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 17 / 19 — sequential cascade', () {
    test('Set 2 uses Set 1 hints; Set 3 uses the NEW Set 2 hints', () {
      final s = _settings();
      final out = _compute(
        s,
        _row([
          _set(0, w: 37.5, r: 7, rir: 2.0), // resolved Set 1
          _set(1),
          _set(2),
        ]),
      );

      final t2 = _targetFrom(prevWeightAbs: 37.5, prevReps: 7, prevRir: 2.0);
      final best2 = _bestLegal(
        target: t2,
        prevDisplayWeight: 37.5,
        prevActualRir: 2.0,
        preferredRep: 7,
        thisRir: 2.0,
      );
      expect(out.sets[1].weight.hintValue, best2.weight);
      expect(out.sets[1].reps.hintValue, best2.reps);

      // Set 3 must cascade from the NEWLY chosen Set 2, not from Set 1 and not
      // from any stale baseline.
      final s2w = out.sets[1].weight.hintValue!;
      final s2r = out.sets[1].reps.hintValue!;
      final s2rir = out.sets[1].rir.hintValue!;
      final t3 = _targetFrom(prevWeightAbs: s2w, prevReps: s2r, prevRir: s2rir);
      final best3 = _bestLegal(
        target: t3,
        prevDisplayWeight: s2w,
        prevActualRir: null, // Set 2 has no ACTUAL rir
        preferredRep: 7,
        thisRir: 2.5,
      );
      expect(out.sets[2].weight.hintValue, best3.weight);
      expect(out.sets[2].reps.hintValue, best3.reps);

      // Sanity: a Set 3 derived straight from Set 1 would differ.
      final wrong = _bestLegal(
        target: _targetFrom(prevWeightAbs: 37.5, prevReps: 7, prevRir: 2.0),
        prevDisplayWeight: 37.5,
        prevActualRir: 2.0,
        preferredRep: 7,
        thisRir: 2.5,
      );
      expect(
        out.sets[2].weight.hintValue != wrong.weight ||
            out.sets[2].reps.hintValue != wrong.reps,
        isTrue,
        reason: 'Set 3 must not be derived directly from Set 1',
      );
    });

    test('before any actuals, Set 2 responds to Set 1 HINTS', () {
      final s = _settings();
      final out = _compute(
        s,
        _row([
          _set(0, wHint: 37.5, rHint: 7, rirHint: 2.0),
          _set(1),
          _set(2),
        ]),
      );
      // Set 1 has no actuals at all, yet the cascade still runs from its hints.
      expect(out.sets[0].weight.actualValue, isNull);
      expect(out.sets[1].weight.hintValue, isNotNull);
      expect(out.sets[1].reps.hintValue, isNotNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 18 — each Set 1 actual moves the Set 2 target.
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 18 — Set 1 actuals drive the Set 2 target', () {
    Wes2ExerciseRow run({double? w, int? r, double? rir}) => _compute(
          _settings(),
          _row([
            Wes2SetState(
              setIndex: 0,
              weight: _field<double>(actual: w, hint: 37.5),
              reps: _field<int>(actual: r, hint: 7),
              rir: _field<double>(actual: rir, hint: 2.0),
            ),
            _set(1),
            _set(2),
          ]),
        );

    /// Reads Set 1 back from the OUTPUT and proves Set 2 is the minimum-error
    /// candidate for the target those RESOLVED values imply. Any actual that
    /// was supplied must have survived as the resolved value.
    void expectSet2FollowsResolvedSet1(
      Wes2ExerciseRow out, {
      double? typedWeight,
      int? typedReps,
      double? typedRir,
    }) {
      final s1 = out.sets[0];
      final resolvedW = _resolvedW(s1);
      final resolvedR = _resolvedR(s1);
      final resolvedRir = s1.rir.actualValue ?? s1.rir.hintValue ?? 0.0;

      if (typedWeight != null) expect(resolvedW, typedWeight);
      if (typedReps != null) expect(resolvedR, typedReps);
      if (typedRir != null) expect(resolvedRir, typedRir);

      final best = _bestLegal(
        target: _targetFrom(
          prevWeightAbs: resolvedW,
          prevReps: resolvedR,
          prevRir: resolvedRir,
        ),
        prevDisplayWeight: resolvedW,
        prevActualRir: s1.rir.actualValue,
        preferredRep: 7,
        thisRir: 2.0,
      );
      expect(out.sets[1].weight.hintValue, best.weight,
          reason: 'resolved S1 = $resolvedW x $resolvedR @ $resolvedRir');
      expect(out.sets[1].reps.hintValue, best.reps);
    }

    test('hints only', () {
      expectSet2FollowsResolvedSet1(run());
    });

    test('weight actual alone', () {
      expectSet2FollowsResolvedSet1(run(w: 35.0), typedWeight: 35.0);
    });

    test('reps actual alone', () {
      expectSet2FollowsResolvedSet1(run(r: 5), typedReps: 5);
    });

    test('RIR actual alone', () {
      expectSet2FollowsResolvedSet1(run(rir: 1.0), typedRir: 1.0);
    });

    test('all three actuals together', () {
      expectSet2FollowsResolvedSet1(run(w: 35.0, r: 5, rir: 1.0),
          typedWeight: 35.0, typedReps: 5, typedRir: 1.0);
    });

    test('changing one Set 1 actual moves the Set 2 result', () {
      final a = run(w: 37.5, r: 7, rir: 2.0);
      final b = run(w: 37.5, r: 7, rir: 0.5);
      String key(Wes2ExerciseRow x) =>
          '${x.sets[1].weight.hintValue}x${x.sets[1].reps.hintValue}';
      expect(key(a), isNot(key(b)),
          reason: 'a different resolved Set 1 RIR must move the Set 2 target');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 20-23 — constraints on the CURRENT set.
  // ───────────────────────────────────────────────────────────────────────────
  group('TESTS 20-23 — current-set constraints', () {
    Wes2ExerciseRow run(Wes2SetState set2) => _compute(
          _settings(),
          _row([_set(0, w: 37.5, r: 7, rir: 2.0), set2, _set(2)]),
        );

    test('TEST 20 — weight actual is kept; only reps are searched', () {
      final out = run(_set(1, w: 42.5));
      final s2 = out.sets[1];
      expect(s2.weight.actualValue, 42.5, reason: 'never overwritten');

      final target =
          _targetFrom(prevWeightAbs: 37.5, prevReps: 7, prevRir: 2.0);
      final best = _bestLegal(
        target: target,
        prevDisplayWeight: 37.5,
        prevActualRir: 2.0,
        preferredRep: 7,
        thisRir: 2.0,
        weightsOverride: const <double>[42.5],
      );
      expect(s2.reps.hintValue, best.reps);
      // A manually entered heavier load is NOT capped to the previous set.
      expect(s2.weight.actualValue!, greaterThan(37.5));
    });

    test('TEST 21 — reps actual is kept; only legal weights are searched', () {
      final out = run(_set(1, r: 4));
      final s2 = out.sets[1];
      expect(s2.reps.actualValue, 4, reason: 'never overwritten');

      final legal = Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: 37.5,
        previousActualRir: 2.0,
        grid: IncrementGrid(primary: 2.5),
      );
      expect(legal, contains(s2.weight.hintValue));
      expect(s2.weight.hintValue!, lessThanOrEqualTo(37.5));

      final best = _bestLegal(
        target: _targetFrom(prevWeightAbs: 37.5, prevReps: 7, prevRir: 2.0),
        prevDisplayWeight: 37.5,
        prevActualRir: 2.0,
        preferredRep: 4,
        thisRir: 2.0,
        repsOverride: const <int>[4],
      );
      expect(s2.weight.hintValue, best.weight);
    });

    test('TEST 22 — both actuals: neither generated field is produced', () {
      final out = run(_set(1, w: 42.5, r: 4));
      final s2 = out.sets[1];
      expect(s2.weight.actualValue, 42.5);
      expect(s2.reps.actualValue, 4);
      expect(s2.weight.hintValue, isNull);
      expect(s2.reps.hintValue, isNull);
    });

    test('TEST 23 — RIR-only actual runs the FULL joint search', () {
      // The old solver pinned the existing rep hint whenever only RIR was
      // typed. It must not any more: both fields adapt together.
      final staleRepHint = 7;
      final out = run(_set(1, rir: 0.5, rHint: staleRepHint, wHint: 37.5));
      final s2 = out.sets[1];

      final target =
          _targetFrom(prevWeightAbs: 37.5, prevReps: 7, prevRir: 2.0);
      final best = _bestLegal(
        target: target,
        prevDisplayWeight: 37.5,
        prevActualRir: 2.0,
        preferredRep: staleRepHint,
        thisRir: 0.5, // the typed actual RIR is used for scoring
      );
      expect(s2.weight.hintValue, best.weight);
      expect(s2.reps.hintValue, best.reps);
      expect(s2.reps.hintValue, isNot(staleRepHint),
          reason: 'reps must be free to move under an RIR-only edit');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 24-25 — BB3 locks.
  // ───────────────────────────────────────────────────────────────────────────
  group('TESTS 24-25 — BB3 locks stay authoritative', () {
    test('TEST 24 — BB3 weight lock is untouched; reps are searched', () {
      final out = _compute(
        _settings(),
        _row([
          _set(0, w: 37.5, r: 7, rir: 2.0),
          _set(1, wHint: 45.0, wHintOrigin: FieldOrigin.bb3Hint),
          _set(2),
        ]),
      );
      final s2 = out.sets[1];
      expect(s2.weight.hintValue, 45.0, reason: 'BB3 weight is never rewritten');
      expect(s2.weight.hintOrigin, FieldOrigin.bb3Hint);
      expect(s2.reps.hintValue, isNotNull);
    });

    test('TEST 25 — BB3 reps lock is untouched; weight is searched', () {
      final out = _compute(
        _settings(),
        _row([
          _set(0, w: 37.5, r: 7, rir: 2.0),
          _set(1, rHint: 4, rHintOrigin: FieldOrigin.bb3Hint),
          _set(2),
        ]),
      );
      final s2 = out.sets[1];
      expect(s2.reps.hintValue, 4, reason: 'BB3 reps are never rewritten');
      expect(s2.reps.hintOrigin, FieldOrigin.bb3Hint);

      final legal = Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: 37.5,
        previousActualRir: 2.0,
        grid: IncrementGrid(primary: 2.5),
      );
      expect(legal, contains(s2.weight.hintValue));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TESTS 26-29 — progression-model agnosticism.
  // ───────────────────────────────────────────────────────────────────────────
  group('TESTS 26-29 — Set 2+ is blind to the progression model', () {
    const models = <String>[
      'Add Reps',
      'Smart Progression',
      'Linear Weight Increase',
    ];

    void seedHistory() {
      PeriodizationModelUtils.savedWorkoutsList = [
        {
          'date': DateTime(2026, 1, 5),
          'exercises': [
            {
              'exerciseId': _exId,
              'name': _exName,
              'sets': [
                {'weight': 35.0, 'reps': 8, 'rir': 2.0},
              ],
            }
          ],
        }
      ];
      PeriodizationModelUtils.topSetsByExercise.clear();
    }

    for (final model in models) {
      test('$model — Set 2 derives from resolved Set 1 via the new solver', () {
        seedHistory();
        final out = _compute(
          _settings(progressionModel: model),
          _row([
            // The athlete has logged Set 1; whatever the model hinted, THIS is
            // the resolved combination the cascade must consume.
            _set(0, w: 37.5, r: 7, rir: 2.0),
            _set(1),
            _set(2),
          ]),
        );
        final best = _bestLegal(
          target: _targetFrom(prevWeightAbs: 37.5, prevReps: 7, prevRir: 2.0),
          prevDisplayWeight: 37.5,
          prevActualRir: 2.0,
          preferredRep: 7,
          thisRir: 2.0,
        );
        expect(out.sets[1].weight.hintValue, best.weight,
            reason: 'model $model must not change the Set 2 solver');
        expect(out.sets[1].reps.hintValue, best.reps);
      });
    }

    test('TEST 29 — identical resolved Set 1 gives identical Set 2 for all',
        () {
      final results = <String, String>{};
      for (final model in models) {
        seedHistory();
        final out = _compute(
          _settings(progressionModel: model),
          _row([
            _set(0, w: 37.5, r: 7, rir: 2.0),
            _set(1),
            _set(2),
          ]),
        );
        results[model] = '${out.sets[1].weight.hintValue}'
            'x${out.sets[1].reps.hintValue}'
            '@${out.sets[1].rir.hintValue}';
      }
      final distinct = results.values.toSet();
      expect(distinct.length, 1,
          reason: 'Set 2 differed across models: $results');
    });

    test('TEST 26 — Add Reps produces Set 1, cascade consumes only its numbers',
        () {
      seedHistory();
      final s = _settings(progressionModel: 'Add Reps');
      // No Set 1 actuals — let the configured model generate the Set 1 hint.
      final out = _compute(
        s,
        _row([_set(0), _set(1), _set(2)]),
      );

      final s1w = out.sets[0].weight.hintValue!;
      final s1r = out.sets[0].reps.hintValue!;
      final s1rir = out.sets[0].rir.hintValue ?? 0.0;

      final best = _bestLegal(
        target: _targetFrom(prevWeightAbs: s1w, prevReps: s1r, prevRir: s1rir),
        prevDisplayWeight: s1w,
        prevActualRir: null, // hint only — heavier candidates stay locked
        preferredRep: 7,
        thisRir: 2.0,
      );
      expect(out.sets[1].weight.hintValue, best.weight);
      expect(out.sets[1].reps.hintValue, best.reps);
      expect(out.sets[1].weight.hintValue!, lessThanOrEqualTo(s1w));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 30 — bodyweight cascade.
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 30 — bodyweight cascade uses display-added units', () {
    test('candidates sit around the added load, not the absolute load', () {
      expect(
        PeriodizationModelUtils.isBodyweightExercise(id: _bwId, name: _bwName),
        isTrue,
        reason: '$_bwName must be a bodyweight exercise for this fixture',
      );
      final bw = PeriodizationModelUtils.bodyweightKgForDate(
          uid: _uid, asOf: _day);
      expect(bw, greaterThan(0));
      double toAbs(double added) => bw + added;

      final out = _compute(
        _settings(exerciseId: _bwId),
        _row(
          [_set(0, w: 20.0, r: 8, rir: 2.0), _set(1), _set(2)],
          exerciseId: _bwId,
          name: _bwName,
        ),
      );

      final s2w = out.sets[1].weight.hintValue!;
      final legal = Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: 20.0,
        previousActualRir: 2.0,
        grid: IncrementGrid(primary: 2.5),
        keepCandidate: (w) => toAbs(w) > 0,
      );
      // Bounded around +20 display-added, never around bodyweight + 20.
      expect(legal, <double>[15.0, 17.5, 20.0]);
      expect(legal, contains(s2w));
      expect(s2w, lessThanOrEqualTo(20.0));
      expect(s2w, lessThan(bw), reason: 'display-added, not absolute');

      // and the pairing is the minimum-error one once converted to absolute.
      final best = _bestLegal(
        target: _targetFrom(
            prevWeightAbs: toAbs(20.0), prevReps: 8, prevRir: 2.0),
        prevDisplayWeight: 20.0,
        prevActualRir: 2.0,
        preferredRep: 7,
        thisRir: 2.0,
        toAbs: toAbs,
      );
      expect(s2w, best.weight);
      expect(out.sets[1].reps.hintValue, best.reps);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 31 — extra added sets.
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 31 — extra added sets', () {
    test('inherit the previous RIR and still use the joint solver', () {
      // planCount is 3 ("7 x 3"), so index 3 is an extra added set.
      final out = _compute(
        _settings(),
        _row([
          _set(0, w: 37.5, r: 7, rir: 2.0),
          _set(1),
          _set(2),
          _set(3),
        ]),
      );

      final s3 = out.sets[2];
      final s4 = out.sets[3];

      // Extra-set RIR inheritance is unchanged: it takes Set 3's resolved RIR.
      final s3Rir = s3.rir.actualValue ?? s3.rir.hintValue!;
      expect(s4.rir.hintValue, s3Rir);
      expect(s4.rir.actualValue, isNull);

      // and its weight/reps come from the same bounded solver.
      final s3w = _resolvedW(s3);
      final s3r = _resolvedR(s3);
      final best = _bestLegal(
        target: _targetFrom(prevWeightAbs: s3w, prevReps: s3r, prevRir: s3Rir),
        prevDisplayWeight: s3w,
        prevActualRir: null,
        preferredRep: 7,
        thisRir: s4.rir.hintValue!,
      );
      expect(s4.weight.hintValue, best.weight);
      expect(s4.reps.hintValue, best.reps);
      expect(s4.weight.hintValue!, lessThanOrEqualTo(s3w));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // TEST 33 — the defensive cap survives as a backstop.
  // ───────────────────────────────────────────────────────────────────────────
  group('TEST 33 — defensive cap', () {
    final grid = <double>[32.5, 35.0, 37.5, 40.0, 42.5];

    test('previous actual RIR <= 2.5 caps an over-ceiling proposal', () {
      for (final rir in const [0.0, 1.0, 2.0, 2.5]) {
        final prev = _set(0, w: 37.5, rir: rir);
        expect(
          Wes2HintServiceImpl.debugCapWeightToPrevSet(
              proposed: 42.5, prevSet: prev, validWeights: grid),
          37.5,
          reason: 'RIR $rir must not permit an increase',
        );
      }
    });

    test('previous actual RIR > 2.5 still permits heavier values', () {
      final prev = _set(0, w: 37.5, rir: 3.0);
      expect(
        Wes2HintServiceImpl.debugCapWeightToPrevSet(
            proposed: 42.5, prevSet: prev, validWeights: grid),
        42.5,
      );
    });

    test('a hint-only RIR of 3.0 never bypasses the cap', () {
      final prev = _set(0, w: 37.5, rirHint: 3.0);
      expect(prev.rir.actualValue, isNull);
      expect(
        Wes2HintServiceImpl.debugCapWeightToPrevSet(
            proposed: 42.5, prevSet: prev, validWeights: grid),
        37.5,
      );
    });

    test('the solver never hands the cap an over-ceiling proposal', () {
      // End-to-end: whatever the cascade picks is already within the legal
      // space, so the cap is a no-op backstop rather than a load-bearing clamp.
      for (final prevRir in const [0.0, 1.0, 2.0, 2.5]) {
        final out = _compute(
          _settings(),
          _row([_set(0, w: 37.5, r: 7, rir: prevRir), _set(1), _set(2)]),
        );
        expect(out.sets[1].weight.hintValue!, lessThanOrEqualTo(37.5),
            reason: 'prev actual RIR $prevRir');
      }
    });

    test('previous actual RIR 3.0 lets the cascade choose heavier', () {
      final out = _compute(
        _settings(),
        _row([_set(0, w: 37.5, r: 7, rir: 3.0), _set(1), _set(2)]),
      );
      final legal = Wes2SetNSolver.weightCandidates(
        previousResolvedDisplayWeight: 37.5,
        previousActualRir: 3.0,
        grid: IncrementGrid(primary: 2.5),
      );
      expect(legal, contains(out.sets[1].weight.hintValue));
      expect(legal, contains(40.0));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Primary + secondary increments end to end.
  // ───────────────────────────────────────────────────────────────────────────
  test('TEST 14 (cascade) — secondary increment reaches the real cascade', () {
    final out = _compute(
      _settings(primary: 2.5, secondary: 1.25),
      _row([_set(0, w: 37.5, r: 7, rir: 2.0), _set(1), _set(2)]),
    );
    final g = IncrementGrid(primary: 2.5, secondary: 1.25);
    final legal = Wes2SetNSolver.weightCandidates(
      previousResolvedDisplayWeight: 37.5,
      previousActualRir: 2.0,
      grid: g,
    );
    expect(legal, <double>[35.0, 36.25, 37.5]);
    expect(legal, contains(out.sets[1].weight.hintValue));
    expect(g.contains(out.sets[1].weight.hintValue!), isTrue);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Timed exercises must not be routed through the solver.
  // ───────────────────────────────────────────────────────────────────────────
  test('timed exercises keep their existing seconds propagation', () {
    expect(
      PeriodizationModelUtils.isTimedExercise(id: _timedId, name: _timedName),
      isTrue,
      reason: 'fixture must use a genuinely timed exercise id',
    );
    final out = _compute(
      _settings(exerciseId: _timedId),
      _row(
        [_set(0), _set(1), _set(2)],
        exerciseId: _timedId,
        name: _timedName,
      ),
    );

    // Timed exercises return from _computeSetNHints before the Set 2+ candidate
    // solver is ever reached: seconds and load propagate forward verbatim
    // rather than being scored against a target E1RM.
    final seconds = out.sets[0].reps.hintValue;
    final load = out.sets[0].weight.hintValue;
    expect(seconds, isNotNull);
    expect(load, isNotNull);
    for (int i = 1; i < out.sets.length; i++) {
      expect(out.sets[i].reps.hintValue, seconds,
          reason: 'set ${i + 1} seconds must propagate unchanged');
      expect(out.sets[i].weight.hintValue, load,
          reason: 'set ${i + 1} load must propagate unchanged');
    }
  });
}
