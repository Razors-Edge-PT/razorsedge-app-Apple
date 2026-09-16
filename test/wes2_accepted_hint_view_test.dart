// Accepted-hint behaviour, through the production hint service and resolver.
//
// Typing the number a set is already suggesting must not change that set.
// Before the fix, accepting a hinted 10 reps at 40 kg re-solved the set and
// moved its RIR 2 -> 1.5, which moved every later set with it.
//
// The gate at the bottom runs the whole acceptance space across EVERY
// supported progression model, because the supporting invariant (I1 — with RIR
// unentered and not both weight and reps entered, the RIR hint does not depend
// on this set's weight/reps) is a property of Set 1's model path, not of the
// cascade.
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/wes2_cascade_resolver.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
final _blockStart = DateTime(2026, 1, 5);
final _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings({
  String repTarget = '10 x 3',
  List<String> rir = const <String>['2', '2', '2'],
  String? progressionModel,
  double primary = 2.5,
}) =>
    <String, dynamic>{
      _exId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        if (progressionModel != null) 'progressionModel': progressionModel,
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': primary},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': repTarget},
          'week2': <String, dynamic>{'instance1': repTarget},
        },
        'rirPlan': <String, dynamic>{
          for (final String wk in const <String>['week1', 'week2'])
            wk: <String, dynamic>{
              'session1': <String, dynamic>{
                for (int i = 0; i < rir.length; i++)
                  'set${i + 1}': <String, dynamic>{'rir': rir[i]},
              }
            }
        },
      }
    };

List<Map<String, dynamic>> _history(double w, int r, double rir) =>
    <Map<String, dynamic>>[
      <String, dynamic>{
        'date': DateTime(2026, 1, 5),
        'exercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': _exId,
            'name': _exName,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{'weight': w, 'reps': r, 'rir': rir}
            ],
          }
        ],
      }
    ];

Wes2HintServiceImpl _service(Map<String, dynamic> settings) =>
    Wes2HintServiceImpl(
      exerciseSettings: settings,
      blockStartDate: _blockStart,
      blockEndDate: null,
      uid: _uid,
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

Wes2ExerciseRow _row(List<Wes2SetState> sets) => Wes2ExerciseRow(
      exerciseId: _exId,
      name: _exName,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: sets.length,
      source: Wes2RowSource.wes2Manual,
      sets: sets,
    );

Wes2ExerciseRow _resolve(Wes2HintServiceImpl svc, List<Wes2SetState> sets) =>
    svc.resolveRow(
      row: _row(sets),
      prescriptions: Wes2Prescriptions.none,
      uid: _uid,
      date: _day,
    );

/// What the row shows for a field: the actual if present, else the hint.
String _shown(Wes2SetState s) {
  final ({double? weight, int? reps, double? rir}) v =
      Wes2CascadeResolver.resolvedValues(s);
  return '${v.weight}x${v.reps}@${v.rir}';
}

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });
  tearDown(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-VIEW-40x10 — the reported counterexample, in both entry orders.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-VIEW-40x10 — accepting the displayed hint leaves the set alone', () {
    final Wes2HintServiceImpl svc = _service(_settings());

    test('free Set 2 for a 40x10@2 predecessor is 35x13@2', () {
      final out = _resolve(svc, [_set(0, w: 40, r: 10, rir: 2), _set(1), _set(2)]);
      expect(out.sets[1].weight.hintValue, 35.0);
      expect(out.sets[1].reps.hintValue, 13);
      expect(out.sets[1].rir.hintValue, 2.0);
    });

    test('weight first, then the displayed reps: RIR stays 2', () {
      // Enter the weight the athlete actually used.
      final afterWeight =
          _resolve(svc, [_set(0, w: 40, r: 10, rir: 2), _set(1, w: 40), _set(2)]);
      expect(afterWeight.sets[1].reps.hintValue, 10,
          reason: 'at 40 kg the target implies 10 reps');
      expect(afterWeight.sets[1].rir.hintValue, 2.0);

      // Accept that displayed 10.
      final accepted = _resolve(
          svc, [_set(0, w: 40, r: 10, rir: 2), _set(1, w: 40, r: 10), _set(2)]);
      expect(accepted.sets[1].rir.hintValue, 2.0,
          reason: 'accepting a hint must not re-solve the set (was 1.5)');
      expect(accepted.sets[1].weight.actualValue, 40.0);
      expect(accepted.sets[1].reps.actualValue, 10);
    });

    test('reps first, then the displayed weight: same result', () {
      final afterReps =
          _resolve(svc, [_set(0, w: 40, r: 10, rir: 2), _set(1, r: 10), _set(2)]);
      expect(afterReps.sets[1].weight.hintValue, 40.0);

      final accepted = _resolve(
          svc, [_set(0, w: 40, r: 10, rir: 2), _set(1, w: 40, r: 10), _set(2)]);
      expect(accepted.sets[1].rir.hintValue, 2.0);
    });

    test('Set 3 consumes 40x10@2 and returns to 35x13@2', () {
      final accepted = _resolve(
          svc, [_set(0, w: 40, r: 10, rir: 2), _set(1, w: 40, r: 10), _set(2)]);
      expect(_shown(accepted.sets[1]), '40.0x10@2.0');
      expect(accepted.sets[2].weight.hintValue, 35.0);
      expect(accepted.sets[2].reps.hintValue, 13);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-VIEW-FORMAT — acceptance is decided with the row's own formatters.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-VIEW-FORMAT — matching follows the display, not a tolerance', () {
    test('0.15 renders as 0.1 and 2.55 as 2.5', () {
      expect(Wes2HintFormat.rir(0.15), '0.1');
      expect(Wes2HintFormat.rir(2.55), '2.5');
      expect(Wes2HintFormat.rir(1.25), '1.3');
      // A symmetric +/-0.05 tolerance would accept 0.2 for a hint of 0.15,
      // a value that was never on screen.
      expect(Wes2HintFormat.rirAccepts(0.2, 0.15), isFalse);
      expect(Wes2HintFormat.rirAccepts(0.1, 0.15), isTrue);
    });

    test('weight keeps three decimals and collapses float artefacts', () {
      expect(Wes2HintFormat.weight(16.25), '16.25');
      expect(Wes2HintFormat.weight(16.249999999999996), '16.25');
      expect(Wes2HintFormat.weightAccepts(16.25, 16.249999999999996), isTrue);
      expect(Wes2HintFormat.weightAccepts(16.3, 16.25), isFalse);
    });

    test('accepting a displayed 1.3 for an internal 1.25 is an acceptance', () {
      expect(Wes2HintFormat.rirAccepts(1.3, 1.25), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // H-VIEW-AUTHORITY — an accepted RIR is still an ENTERED RIR.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-VIEW-AUTHORITY — acceptance does not weaken provenance', () {
    test('entered RIR 3.0 permits a heavier next set; a hinted 3.0 does not',
        () {
      final hinted = _service(_settings(rir: const <String>['3', '3', '3']));
      PeriodizationModelUtils.savedWorkoutsList = _history(35, 8, 2);
      final hintOnly = _resolve(hinted, [_set(0), _set(1), _set(2)]);
      final double s1w = hintOnly.sets[0].weight.hintValue!;
      expect(hintOnly.sets[1].weight.hintValue!, lessThanOrEqualTo(s1w),
          reason: 'a hinted RIR of 3.0 never unlocks a heavier set');

      // The same 3.0, entered.
      final entered = _resolve(hinted, [
        _set(0, w: s1w, r: hintOnly.sets[0].reps.hintValue, rir: 3.0),
        _set(1),
        _set(2),
      ]);
      expect(entered.sets[1].weight.hintValue, isNotNull);
      expect(entered.sets[1].weight.hintValue!, greaterThanOrEqualTo(s1w),
          reason: 'an ENTERED RIR above 2.5 may unlock a heavier set');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // THE GATE — every supported progression model, whole acceptance space.
  // ───────────────────────────────────────────────────────────────────────────
  group('H-VIEW-GATE — acceptance across all supported models', () {
    const List<String?> models = <String?>[
      null, // no explicit progression model (plan/default path)
      'Smart Progression',
      'Linear Weight Increase',
      'Add Reps',
    ];

    for (final String? model in models) {
      final String label = model ?? 'default';

      for (final bool withHistory in const <bool>[true, false]) {
        test('$label (history: $withHistory) — accepting any displayed hint '
            'leaves the rest of that set unchanged', () {
          PeriodizationModelUtils.savedWorkoutsList =
              withHistory ? _history(35, 8, 2) : <Map<String, dynamic>>[];
          final svc = _service(_settings(progressionModel: model));

          for (int k = 0; k < 3; k++) {
            final List<Wes2SetState> base =
                List<Wes2SetState>.generate(3, (int i) => _set(i));
            final Wes2ExerciseRow free = _resolve(svc, base);
            final Wes2SetState freeSet = free.sets[k];

            // Accept each displayed hint on its own.
            for (final String field in const <String>['w', 'r', 'rir']) {
              final double? hw = freeSet.weight.hintValue;
              final int? hr = freeSet.reps.hintValue;
              final double? hrir = freeSet.rir.hintValue;
              if (field == 'w' && hw == null) continue;
              if (field == 'r' && hr == null) continue;
              if (field == 'rir' && hrir == null) continue;

              final List<Wes2SetState> entered =
                  List<Wes2SetState>.from(base);
              entered[k] = _set(k,
                  w: field == 'w' ? hw : null,
                  r: field == 'r' ? hr : null,
                  rir: field == 'rir' ? hrir : null);
              final Wes2ExerciseRow out = _resolve(svc, entered);
              final Wes2SetState got = out.sets[k];

              if (field != 'w') {
                expect(got.weight.hintValue, hw,
                    reason: '$label set $k: accepting $field moved the weight '
                        'hint');
              }
              if (field != 'r') {
                expect(got.reps.hintValue, hr,
                    reason: '$label set $k: accepting $field moved the reps '
                        'hint');
              }
              if (field != 'rir') {
                expect(got.rir.hintValue, hrir,
                    reason: '$label set $k: accepting $field moved the RIR '
                        'hint');
              }
              // Cue flags are part of what the set shows.
              expect(got.weightLockedByBb3OverrideCue,
                  freeSet.weightLockedByBb3OverrideCue);
              expect(got.repsLockedByBb3OverrideCue,
                  freeSet.repsLockedByBb3OverrideCue);
              expect(got.rirLockedByBb3OverrideCue,
                  freeSet.rirLockedByBb3OverrideCue);
            }

            // Accept two displayed hints, in both orders: the result must not
            // depend on which one was typed first.
            final double? hw = freeSet.weight.hintValue;
            final int? hr = freeSet.reps.hintValue;
            if (hw != null && hr != null) {
              final List<Wes2SetState> both = List<Wes2SetState>.from(base);
              both[k] = _set(k, w: hw, r: hr);
              final Wes2ExerciseRow out = _resolve(svc, both);
              expect(out.sets[k].rir.hintValue, freeSet.rir.hintValue,
                  reason: '$label set $k: accepting weight+reps re-solved RIR');
              if (k + 1 < 3) {
                expect(_shown(out.sets[k + 1]), _shown(free.sets[k + 1]),
                    reason: '$label set $k: the next set moved although the '
                        'accepted values equal what it already consumed');
              }
            }
          }
        });

        test('$label (history: $withHistory) — I1: the RIR hint ignores this '
            "set's weight/reps unless both are entered", () {
          PeriodizationModelUtils.savedWorkoutsList =
              withHistory ? _history(35, 8, 2) : <Map<String, dynamic>>[];
          final svc = _service(_settings(progressionModel: model));

          for (int k = 0; k < 3; k++) {
            final List<Wes2SetState> base =
                List<Wes2SetState>.generate(3, (int i) => _set(i));
            final Wes2ExerciseRow free = _resolve(svc, base);
            final double? freeRir = free.sets[k].rir.hintValue;

            for (final double w in const <double>[20, 32.5, 45]) {
              final List<Wes2SetState> wOnly = List<Wes2SetState>.from(base);
              wOnly[k] = _set(k, w: w);
              expect(_resolve(svc, wOnly).sets[k].rir.hintValue, freeRir,
                  reason: '$label set $k: a weight-only entry moved the RIR '
                      'hint');
            }
            for (final int r in const <int>[3, 9, 18]) {
              final List<Wes2SetState> rOnly = List<Wes2SetState>.from(base);
              rOnly[k] = _set(k, r: r);
              expect(_resolve(svc, rOnly).sets[k].rir.hintValue, freeRir,
                  reason: '$label set $k: a reps-only entry moved the RIR '
                      'hint');
            }
          }
        });
      }
    }
  });
}
