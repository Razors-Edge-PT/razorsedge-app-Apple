import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

// Focused, Firestore-free tests for the two hint-engine changes:
//   Change 3 — later-set weight cap by the previous set's ACTUAL RIR.
//   Change 4 — extra added set inherits the most recent set's RIR.
//
// Change 3 is tested directly through the @visibleForTesting cap helper so the
// 2.5 boundary and floor-snap behaviour are deterministic. Change 4 is tested
// through the public computeRowHints() cascade with savedWorkoutsList empty.

Wes2SetState _set({
  required int index,
  double? actualWeight,
  double? hintWeight,
  int? actualReps,
  double? actualRir,
  double? hintRir,
}) {
  return Wes2SetState(
    setIndex: index,
    weight: Wes2FieldState<double>(
      actualValue: actualWeight,
      hintValue: hintWeight,
      origin: actualWeight != null ? FieldOrigin.typed : FieldOrigin.empty,
    ),
    reps: Wes2FieldState<int>(
      actualValue: actualReps,
      origin: actualReps != null ? FieldOrigin.typed : FieldOrigin.empty,
    ),
    rir: Wes2FieldState<double>(
      actualValue: actualRir,
      hintValue: hintRir,
      origin: actualRir != null ? FieldOrigin.typed : FieldOrigin.empty,
    ),
  );
}

void main() {
  const grid = <double>[95.0, 97.5, 100.0, 102.5, 105.0];

  group('Change 3 — weight cap by previous ACTUAL RIR', () {
    test('actual RIR exactly 2.5 prevents an increase (capped to prev)', () {
      final prev = _set(index: 0, actualWeight: 100, actualRir: 2.5);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 105, prevSet: prev, validWeights: grid);
      expect(r, 100);
    });

    test('actual RIR below 2.5 prevents an increase', () {
      final prev = _set(index: 0, actualWeight: 100, actualRir: 2.0);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 105, prevSet: prev, validWeights: grid);
      expect(r, 100);
    });

    test('actual RIR above 2.5 permits an increase (proposed kept)', () {
      final prev = _set(index: 0, actualWeight: 100, actualRir: 3.0);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 105, prevSet: prev, validWeights: grid);
      expect(r, 105);
    });

    test('hint-only RIR does not permit an increase', () {
      final prev = _set(index: 0, actualWeight: 100, hintRir: 3.0);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 105, prevSet: prev, validWeights: grid);
      expect(r, 100);
    });

    test('missing RIR does not permit an increase', () {
      final prev = _set(index: 0, actualWeight: 100);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 105, prevSet: prev, validWeights: grid);
      expect(r, 100);
    });

    test('downward suggestion is preserved', () {
      final prev = _set(index: 0, actualWeight: 100, actualRir: 1.0);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 95, prevSet: prev, validWeights: grid);
      expect(r, 95);
    });

    test('off-grid previous actual floor-snaps to highest valid increment', () {
      // prev actual 101.3 (off-grid), no RIR → cap, floor-snap to 100 (<=101.3).
      final prev = _set(index: 0, actualWeight: 101.3);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 105, prevSet: prev, validWeights: grid);
      expect(r, 100);
    });

    test('on-grid previous hint is used directly', () {
      final prev = _set(index: 0, hintWeight: 100);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 105, prevSet: prev, validWeights: grid);
      expect(r, 100);
    });

    test('null proposed stays null', () {
      final prev = _set(index: 0, actualWeight: 100, actualRir: 1.0);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: null, prevSet: prev, validWeights: grid);
      expect(r, isNull);
    });

    test('no previous resolved weight leaves proposed unchanged', () {
      final prev = _set(index: 0, actualRir: 1.0);
      final r = Wes2HintServiceImpl.debugCapWeightToPrevSet(
        proposed: 105, prevSet: prev, validWeights: grid);
      expect(r, 105);
    });
  });

  group('Change 4 — extra added set inherits most recent RIR', () {
    setUp(() => PeriodizationModelUtils.savedWorkoutsList = []);
    tearDown(() => PeriodizationModelUtils.savedWorkoutsList = []);

    Wes2HintServiceImpl service() => Wes2HintServiceImpl(
          exerciseSettings: {
            'EX': {
              'periodizationModel': 'Linear, Classic',
              'weeklyFrequency': 3,
              'increments': {'primary': 2.5},
              // "reps x sets" → 5 reps, 3 planned sets.
              'repTargets': {
                'week1': {'instance1': '5 x 3'}
              },
              'rirPlan': {
                'week1': {
                  'session1': {
                    'set1': {'rir': '2'},
                    'set2': {'rir': '2'},
                    'set3': {'rir': '3'},
                  }
                }
              },
            }
          },
          blockStartDate: DateTime(2026, 1, 1),
          blockEndDate: DateTime(2026, 4, 1),
          uid: 'u',
        );

    // 4 sets where planCount = 3, so set index 3 is the extra added set.
    Wes2ExerciseRow rowWith(Wes2SetState set2) => Wes2ExerciseRow(
          exerciseId: 'EX',
          name: 'Test Lift',
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 4,
          source: Wes2RowSource.wes2Manual,
          sets: [
            _set(index: 0, actualWeight: 100, actualReps: 5),
            _set(index: 1),
            set2,
            _set(index: 3),
          ],
        );

    test('extra set inherits previous RIR hint; planned set keeps plan RIR', () {
      final out = service().computeRowHints(
        row: rowWith(_set(index: 2)),
        blockId: 'b',
        uid: 'u',
        date: DateTime(2026, 1, 1),
      );
      // Planned set 3 (index 2) keeps its plan RIR of 3.0.
      expect(out.sets[2].rir.hintValue, 3.0);
      // Extra set 4 (index 3) inherits the previous set's resolved RIR (3.0),
      // NOT the getRirFromPlan default of 1.0 it would otherwise receive.
      expect(out.sets[3].rir.hintValue, 3.0);
      // Inherited value is a hint only — never an actual / typed value.
      expect(out.sets[3].rir.actualValue, isNull);
    });

    test('extra set inherits previous ACTUAL RIR as a hint', () {
      final out = service().computeRowHints(
        // Previous set carries a typed actual RIR of 4.0.
        row: rowWith(_set(index: 2, actualRir: 4.0)),
        blockId: 'b',
        uid: 'u',
        date: DateTime(2026, 1, 1),
      );
      expect(out.sets[3].rir.hintValue, 4.0);
      expect(out.sets[3].rir.actualValue, isNull);
    });
  });
}
