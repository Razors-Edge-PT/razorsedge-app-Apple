// The Set 2+ rep search centre.
//
// The centre used to be the set's OWN previous rep hint, then the planned rep
// target. The first fed a set's stale output back into its own search; the
// second centred the window on a number unrelated to the live target, so after
// a Set 1 of 20x20@0 (target 41.35) the best the window could reach was
// 20x15 = 36.0.
//
// The literal targets below are derived by hand from the unchanged formulas
// (t = reps + RIR; Brzycki w*36/(37-t) for t <= 25, else Epley w*(1+0.0333t)),
// with the group C drop of 1.0 gated to 0.8 when the previous RIR is 2.0.
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/increment_grid.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/wes2_setn_solver.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
final _blockStart = DateTime(2026, 1, 5);
final _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings() => <String, dynamic>{
      _exId: <String, dynamic>{
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': <String, dynamic>{'primary': 2.5},
        'repTargets': <String, dynamic>{
          'week1': <String, dynamic>{'instance1': '10 x 3'},
          'week2': <String, dynamic>{'instance1': '10 x 3'},
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

Wes2ExerciseRow _resolve(List<Wes2SetState> sets) => Wes2HintServiceImpl(
      exerciseSettings: _settings(),
      blockStartDate: _blockStart,
      blockEndDate: null,
      uid: _uid,
    ).resolveRow(
      row: Wes2ExerciseRow(
        exerciseId: _exId,
        name: _exName,
        circuitIndex: 0,
        orderIndex: 0,
        setCount: sets.length,
        source: Wes2RowSource.wes2Manual,
        sets: sets,
      ),
      prescriptions: Wes2Prescriptions.none,
      uid: _uid,
      date: _day,
    );

double _e1rm(double w, num r, double rir) =>
    PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), rir);

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  group('H-CENTRE-LITERAL — hand-derived targets and bounded results', () {
    test('40x10@2 -> target 56.8 -> Set 2 is 35x13@2', () {
      expect(_e1rm(40, 10, 2), closeTo(57.6, 1e-9));
      const double target = 57.6 - 0.8; // group C drop 1.0, gated x0.8
      expect(target, closeTo(56.8, 1e-9));

      final out = _resolve([_set(0, w: 40, r: 10, rir: 2), _set(1), _set(2)]);
      expect(out.sets[1].weight.hintValue, 35.0);
      expect(out.sets[1].reps.hintValue, 13);
      expect(_e1rm(35, 13, 2), closeTo(57.2727, 1e-4));
    });

    test('20x20@0 -> target 41.3529 -> Set 2 is 15x22@2 (was 20x15 = 36.0)',
        () {
      expect(_e1rm(20, 20, 0), closeTo(42.3529, 1e-4));
      const double target = 42.352941176470594 - 1.0; // prev RIR 0: full drop

      final out = _resolve([_set(0, w: 20, r: 20, rir: 0), _set(1), _set(2)]);
      expect(out.sets[1].weight.hintValue, 15.0);
      expect(out.sets[1].reps.hintValue, 22);
      final double got = _e1rm(15, 22, 2);
      expect(got, closeTo(41.5385, 1e-4));
      expect((got - target).abs(), lessThan((36.0 - target).abs()),
          reason: 'the new centre must beat the old plan-centred 20x15');
    });

    test('40x7@2 with an entered Set 2 weight of 20 -> 21 reps @2', () {
      expect(_e1rm(40, 7, 2), closeTo(51.4286, 1e-4));
      final out =
          _resolve([_set(0, w: 40, r: 7, rir: 2), _set(1, w: 20), _set(2)]);
      expect(out.sets[1].reps.hintValue, 21);
      expect(_e1rm(20, 21, 2), closeTo(51.4286, 1e-4));
    });

    test("a set's own stale rep hint has no effect on its new search", () {
      // The same inputs, but Set 2 arrives carrying a generated hint of 30
      // reps from an earlier pass. The builder strips it.
      final Wes2SetState stale = _set(1).copyWith(
        reps: const Wes2FieldState<int>(
          hintValue: 30,
          hintOrigin: FieldOrigin.modelHint,
          origin: FieldOrigin.modelHint,
        ),
      );
      final clean =
          _resolve([_set(0, w: 20, r: 20, rir: 0), _set(1), _set(2)]);
      final withStale =
          _resolve([_set(0, w: 20, r: 20, rir: 0), stale, _set(2)]);
      expect(withStale.sets[1].reps.hintValue, clean.sets[1].reps.hintValue);
      expect(
          withStale.sets[1].weight.hintValue, clean.sets[1].weight.hintValue);
    });
  });

  group('H-CENTRE-SOURCES — provenance and fallbacks', () {
    test('a reps constraint is the centre', () {
      final c = Wes2SetNSolver.centre(
          constrainedReps: 12,
          targetE1rm: 50,
          absoluteWeight: 40,
          thisRir: 2);
      expect(c.rep, 12);
      expect(c.source, Wes2CentreSource.constraint);
    });

    test('otherwise the inverse at the anchor weight', () {
      final c = Wes2SetNSolver.centre(
          targetE1rm: 56.8, absoluteWeight: 40, thisRir: 2, fallbackReps: 7);
      expect(c.source, Wes2CentreSource.inverse);
      expect(c.rep, 10);
    });

    test('non-finite and non-positive inputs fall back, never to 45', () {
      // reverseCalculateReps clamps to 1..45 and NaN.clamp(1, 45) returns 45,
      // so a NaN target used to look like a legitimate 45-rep centre.
      for (final double bad in <double>[double.nan, double.infinity, 0, -5]) {
        final c = Wes2SetNSolver.centre(
            targetE1rm: bad, absoluteWeight: 40, thisRir: 2, fallbackReps: 9);
        expect(c.source, Wes2CentreSource.fallback, reason: 'target $bad');
        expect(c.rep, 9);
      }
      for (final double? bad in <double?>[null, double.nan, 0, -2]) {
        final c = Wes2SetNSolver.centre(
            targetE1rm: 50, absoluteWeight: bad, thisRir: 2, fallbackReps: 9);
        expect(c.source, Wes2CentreSource.fallback, reason: 'weight $bad');
      }
    });

    test('with no usable previous reps the fallback is 8', () {
      final c = Wes2SetNSolver.centre(
          targetE1rm: double.nan, absoluteWeight: 40, thisRir: 2);
      expect(c.rep, 8);
      expect(c.source, Wes2CentreSource.fallback);
    });

    test('an unreachable target reports a clamp', () {
      // A target far below what one rep at this weight produces drives the
      // inverse to its lower bound.
      final c = Wes2SetNSolver.centre(
          targetE1rm: 1.0, absoluteWeight: 200, thisRir: 0, fallbackReps: 5);
      expect(c.source, Wes2CentreSource.clamp);
      expect(c.rep, 1);
    });
  });

  group('H-CENTRE-BOUNDS — the bounded search keeps its documented limits', () {
    test('the window stays +/-5 around the centre (no global optimum)', () {
      // target 31 at 15 kg, RIR 2: the inverse centre is 18 (E1RM 31.76),
      // while 30 reps would give 30.98. The bounded window excludes it, by
      // design: this is a documented limitation, not a regression.
      final c = Wes2SetNSolver.centre(
          targetE1rm: 31, absoluteWeight: 15, thisRir: 2, fallbackReps: 8);
      expect(c.rep, 18);
      final List<int> reps = Wes2SetNSolver.repCandidates(preferredRep: c.rep);
      expect(reps.first, 13);
      expect(reps.last, 23);
      expect(reps, isNot(contains(30)));
      expect((_e1rm(15, 18, 2) - 31).abs(), closeTo(0.7647, 1e-4));
      expect((_e1rm(15, 30, 2) - 31).abs(), closeTo(0.016, 1e-3));
    });

    test('weight candidates still respect the entered-RIR permission', () {
      final grid = IncrementGrid(primary: 2.5);
      expect(
        Wes2SetNSolver.weightCandidates(
            previousResolvedDisplayWeight: 40,
            previousActualRir: 2.5,
            grid: grid),
        <double>[35.0, 37.5, 40.0],
      );
      expect(
        Wes2SetNSolver.weightCandidates(
            previousResolvedDisplayWeight: 40,
            previousActualRir: 3.0,
            grid: grid),
        <double>[35.0, 37.5, 40.0, 42.5, 45.0],
      );
    });

    test('no hint is invented when nothing legal exists', () {
      // An empty grid yields no candidates at all.
      final choice = Wes2SetNSolver.choose(
        targetE1rm: 50,
        weightCandidates: const <double>[],
        repCandidates: const <int>[8],
        thisRir: 2,
        preferredRep: 8,
        previousResolvedDisplayWeight: 40,
      );
      expect(choice, isNull);
    });
  });
}
