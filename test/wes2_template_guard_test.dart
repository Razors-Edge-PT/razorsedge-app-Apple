// Tests for workoutHasUserEnteredData and the template-replacement gate.
//
// The pure predicate is tested directly.
// The gate logic (cancel → 0 calls, confirm → 1 call, no data → 1 immediate
// call) is tested via a local _runGate helper that replicates the guard
// structure from _showTemplatePicker without Flutter widget infrastructure.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';

// ── Construction helpers ──────────────────────────────────────────────────────

Wes2SetState _emptySet(int index) => Wes2SetState(setIndex: index);

Wes2SetState _hintOnlySet({
  required int index,
  double? hintWeight,
  int? hintReps,
  double? hintRir,
  double? hintVelocity,
}) =>
    Wes2SetState(
      setIndex: index,
      weight: Wes2FieldState<double>(hintValue: hintWeight),
      reps: Wes2FieldState<int>(hintValue: hintReps),
      rir: Wes2FieldState<double>(hintValue: hintRir),
      velocity: Wes2FieldState<double>(hintValue: hintVelocity),
    );

Wes2SetState _actualSet({
  required int index,
  double? weight,
  int? reps,
  double? rir,
  double? velocity,
  String? executionNote,
}) =>
    Wes2SetState(
      setIndex: index,
      weight: Wes2FieldState<double>(
        actualValue: weight,
        origin: weight != null ? FieldOrigin.typed : FieldOrigin.empty,
      ),
      reps: Wes2FieldState<int>(
        actualValue: reps,
        origin: reps != null ? FieldOrigin.typed : FieldOrigin.empty,
      ),
      rir: Wes2FieldState<double>(
        actualValue: rir,
        origin: rir != null ? FieldOrigin.typed : FieldOrigin.empty,
      ),
      velocity: Wes2FieldState<double>(
        actualValue: velocity,
        origin: velocity != null ? FieldOrigin.typed : FieldOrigin.empty,
      ),
      executionNote: executionNote,
    );

Wes2ExerciseRow _row({
  String id = 'ex1',
  Wes2RowSource source = Wes2RowSource.bb3Planned,
  List<Wes2SetState>? sets,
  bool isMarkedDone = false,
  String? exerciseExecutionNote,
}) =>
    Wes2ExerciseRow(
      exerciseId: id,
      name: 'Exercise',
      circuitIndex: 0,
      orderIndex: 0,
      setCount: sets?.length ?? 1,
      source: source,
      sets: sets ?? [_emptySet(0)],
      isMarkedDone: isMarkedDone,
      exerciseExecutionNote: exerciseExecutionNote,
    );

// ── Gate helper (mirrors the guard in _showTemplatePicker) ────────────────────

/// Runs the confirmation-gate logic in isolation.
/// [rows] is the current workout state.
/// [dialogResult] is what the user "clicks" (true = Replace, false = Cancel).
/// Returns the number of times the replacement function was invoked (0 or 1).
Future<int> _runGate(
  List<Wes2ExerciseRow> rows, {
  bool dialogResult = true,
}) async {
  int calls = 0;
  if (workoutHasUserEnteredData(rows)) {
    if (!dialogResult) return calls; // user cancelled
  }
  calls++; // replacement would run here
  return calls;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── workoutHasUserEnteredData predicate ──────────────────────────────────────

  group('workoutHasUserEnteredData', () {
    test('empty list → false', () {
      expect(workoutHasUserEnteredData([]), isFalse);
    });

    test('untouched planned row with empty sets → false', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_emptySet(0), _emptySet(1), _emptySet(2)]),
        ]),
        isFalse,
      );
    });

    test('hint-only weight → false', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_hintOnlySet(index: 0, hintWeight: 100)]),
        ]),
        isFalse,
      );
    });

    test('hint-only reps → false', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_hintOnlySet(index: 0, hintReps: 8)]),
        ]),
        isFalse,
      );
    });

    test('hint-only RIR → false', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_hintOnlySet(index: 0, hintRir: 2.0)]),
        ]),
        isFalse,
      );
    });

    test('hint-only velocity → false', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_hintOnlySet(index: 0, hintVelocity: 0.5)]),
        ]),
        isFalse,
      );
    });

    test('BB3-locked hint-only (bb3Hint origin) → false', () {
      final rows = [
        Wes2ExerciseRow(
          exerciseId: 'ex1',
          name: 'Squat',
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 1,
          source: Wes2RowSource.bb3Planned,
          sets: [
            Wes2SetState(
              setIndex: 0,
              weight: const Wes2FieldState<double>(
                hintValue: 100,
                origin: FieldOrigin.bb3Hint,
              ),
              reps: const Wes2FieldState<int>(
                hintValue: 5,
                origin: FieldOrigin.bb3Hint,
              ),
            ),
          ],
        ),
      ];
      expect(workoutHasUserEnteredData(rows), isFalse);
    });

    test('actual weight → true', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_actualSet(index: 0, weight: 100)]),
        ]),
        isTrue,
      );
    });

    test('actual reps (no weight) → true', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_actualSet(index: 0, reps: 8)]),
        ]),
        isTrue,
      );
    });

    test('actual RIR → true', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_actualSet(index: 0, rir: 2.0)]),
        ]),
        isTrue,
      );
    });

    test('actual velocity → true', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [_actualSet(index: 0, velocity: 0.5)]),
        ]),
        isTrue,
      );
    });

    test('set execution note → true', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [
            Wes2SetState(setIndex: 0, executionNote: 'felt heavy'),
          ]),
        ]),
        isTrue,
      );
    });

    test('whitespace-only set execution note → false', () {
      expect(
        workoutHasUserEnteredData([
          _row(sets: [
            Wes2SetState(setIndex: 0, executionNote: '   '),
          ]),
        ]),
        isFalse,
      );
    });

    test('exercise execution note → true', () {
      expect(
        workoutHasUserEnteredData([
          _row(exerciseExecutionNote: 'Good session'),
        ]),
        isTrue,
      );
    });

    test('whitespace-only exercise execution note → false', () {
      expect(
        workoutHasUserEnteredData([
          _row(exerciseExecutionNote: '  '),
        ]),
        isFalse,
      );
    });

    test('isMarkedDone → true', () {
      expect(
        workoutHasUserEnteredData([
          _row(isMarkedDone: true),
        ]),
        isTrue,
      );
    });

    test('data in the last set of the last exercise → true', () {
      expect(
        workoutHasUserEnteredData([
          _row(
            id: 'ex1',
            sets: [_emptySet(0), _emptySet(1)],
          ),
          _row(
            id: 'ex2',
            sets: [
              _emptySet(0),
              _emptySet(1),
              _actualSet(index: 2, weight: 80),
            ],
          ),
        ]),
        isTrue,
      );
    });

    test('hint-only in the last set of the last exercise → false', () {
      expect(
        workoutHasUserEnteredData([
          _row(
            id: 'ex1',
            sets: [_hintOnlySet(index: 0, hintWeight: 100, hintReps: 8)],
          ),
          _row(
            id: 'ex2',
            sets: [_hintOnlySet(index: 0, hintWeight: 60, hintReps: 10)],
          ),
        ]),
        isFalse,
      );
    });

    test('cleared actual (null actualValue after edit) → false', () {
      // Represents a field that was once typed but later cleared to null.
      expect(
        workoutHasUserEnteredData([
          _row(sets: [
            Wes2SetState(
              setIndex: 0,
              weight: const Wes2FieldState<double>(
                actualValue: null,
                hintValue: 100,
                origin: FieldOrigin.empty,
              ),
            ),
          ]),
        ]),
        isFalse,
      );
    });

    test('planNote alone (BB3 note, not execution note) → false', () {
      // planNote is BB3-prescribed and must not trigger the guard.
      expect(
        workoutHasUserEnteredData([
          _row(sets: [
            Wes2SetState(setIndex: 0, planNote: 'Keep elbows in'),
          ]),
        ]),
        isFalse,
      );
    });

    test('exercisePlanNote alone (BB3 exercise note) → false', () {
      expect(
        workoutHasUserEnteredData([
          Wes2ExerciseRow(
            exerciseId: 'ex1',
            name: 'Bench',
            circuitIndex: 0,
            orderIndex: 0,
            setCount: 1,
            source: Wes2RowSource.bb3Planned,
            sets: [_emptySet(0)],
            exercisePlanNote: 'Control the descent',
          ),
        ]),
        isFalse,
      );
    });
  });

  // ── Confirmation gate ─────────────────────────────────────────────────────────

  group('template-load gate', () {
    test('no user data → replacement called immediately (1 call, no dialog)',
        () async {
      final calls = await _runGate([
        _row(sets: [_hintOnlySet(index: 0, hintWeight: 100)]),
      ]);
      expect(calls, 1);
    });

    test('empty workout → replacement called immediately (1 call)', () async {
      final calls = await _runGate([]);
      expect(calls, 1);
    });

    test('user data + confirm → replacement called once', () async {
      final calls = await _runGate(
        [
          _row(sets: [_actualSet(index: 0, weight: 100)])
        ],
        dialogResult: true,
      );
      expect(calls, 1);
    });

    test('user data + cancel → replacement not called (0 calls)', () async {
      final calls = await _runGate(
        [
          _row(sets: [_actualSet(index: 0, weight: 100)])
        ],
        dialogResult: false,
      );
      expect(calls, 0);
    });

    test('cancel with set note → 0 calls', () async {
      final calls = await _runGate(
        [
          _row(sets: [Wes2SetState(setIndex: 0, executionNote: 'nice')])
        ],
        dialogResult: false,
      );
      expect(calls, 0);
    });

    test('cancel with exercise note → 0 calls', () async {
      final calls = await _runGate(
        [_row(exerciseExecutionNote: 'great lift')],
        dialogResult: false,
      );
      expect(calls, 0);
    });

    test('repeated true confirmations still produce 1 call per invocation',
        () async {
      // Each _runGate call is independent. The real guard (_isLoadingTemplate)
      // prevents concurrent calls; here we verify a single invocation = 1 call.
      final callsA = await _runGate(
        [
          _row(sets: [_actualSet(index: 0, weight: 100)])
        ],
        dialogResult: true,
      );
      final callsB = await _runGate(
        [
          _row(sets: [_actualSet(index: 0, weight: 100)])
        ],
        dialogResult: true,
      );
      expect(callsA, 1);
      expect(callsB, 1);
    });
  });
}
