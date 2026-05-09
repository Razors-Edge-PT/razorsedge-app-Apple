import 'WES2_models.dart';
import 'bb3_hint_service.dart';
import 'bb3_planned_exercise_service.dart';
import 'periodization_model_utils.dart';

abstract class Wes2HintService {
  /// Recompute hints for a single exercise row.
  /// Returns a new row with hintValue populated on each Wes2FieldState.
  /// Never overwrites actualValue.
  Wes2ExerciseRow computeRowHints({
    required Wes2ExerciseRow row,
    required String blockId,
    required String uid,
    required DateTime date,
  });

  /// Recompute hints for all rows in a day session.
  List<Wes2ExerciseRow> computeAllHints({
    required List<Wes2ExerciseRow> rows,
    required String blockId,
    required String uid,
    required DateTime date,
  });
}

/// Phase 21B/21C implementation: computes Set 1 model hints only.
/// Set 2+ is a no-op; BB3 hints are never overwritten.
class Wes2HintServiceImpl implements Wes2HintService {
  final Map<String, dynamic> exerciseSettings;
  final DateTime blockStartDate;
  final DateTime? blockEndDate;
  final String uid;

  const Wes2HintServiceImpl({
    required this.exerciseSettings,
    required this.blockStartDate,
    required this.blockEndDate,
    required this.uid,
  });

  @override
  Wes2ExerciseRow computeRowHints({
    required Wes2ExerciseRow row,
    required String blockId,
    required String uid,
    required DateTime date,
  }) {
    final base = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day);
    final sel = DateTime(date.year, date.month, date.day);
    final days = sel.difference(base).inDays;
    final weekIndex = days ~/ 7;
    final sessionIndex = days % 7;

    // Build a padded sets list that covers at least setCount slots.
    // WES2-manual rows are created with setCount > 0 but sets: const [],
    // so we must not bail out on sets.isEmpty.
    final effectiveCount = row.setCount > 0 ? row.setCount : 3;
    final padded = List<Wes2SetState>.generate(effectiveCount, (i) {
      return i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i);
    });

    // Only compute hints for Set 1 (index 0) in Phase 21B.
    final newSet0 = _computeSet1Hints(
      row: row,
      set: padded[0],
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      date: date,
      uid: uid,
    );

    if (newSet0 == null && padded.length == row.sets.length) return row;

    final newSets = List<Wes2SetState>.from(padded);
    if (newSet0 != null) newSets[0] = newSet0;
    return row.copyWith(sets: newSets, setCount: effectiveCount);
  }

  @override
  List<Wes2ExerciseRow> computeAllHints({
    required List<Wes2ExerciseRow> rows,
    required String blockId,
    required String uid,
    required DateTime date,
  }) {
    return rows
        .map((r) => computeRowHints(
              row: r,
              blockId: blockId,
              uid: uid,
              date: date,
            ))
        .toList();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Returns a replacement for [set] (setIndex 0) with model hints applied,
  /// or null when no model hint could be derived.
  /// BB3 hints already on any field are preserved.
  Wes2SetState? _computeSet1Hints({
    required Wes2ExerciseRow row,
    required Wes2SetState set,
    required int weekIndex,
    required int sessionIndex,
    required DateTime date,
    required String uid,
  }) {
    final exSettings = exerciseSettings[row.exerciseId] as Map<String, dynamic>?;

    // No-history path: savedWorkoutsList.isEmpty → use default weight + plan RIR/reps.
    if (PeriodizationModelUtils.savedWorkoutsList.isEmpty) {
      return _applyNoHistoryHints(
        row: row,
        set: set,
        exSettings: exSettings,
        weekIndex: weekIndex,
        sessionIndex: sessionIndex,
      );
    }

    // History path: delegate to BB3HintService with BB3/actual constraints so
    // sibling hints are solved around the same progression target E1RM.
    final hint = BB3HintService.getHintsForSet(
      exerciseId: row.exerciseId,
      exerciseName: row.name,
      fullExerciseSettings: exerciseSettings,
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      setIndex: 0,
      blockStartDate: blockStartDate,
      blockEndDate: blockEndDate,
      selectedDate: date,
      uid: uid,
      userWeight: _constraintWeight(set),
      userReps: _constraintReps(set),
      userRir: _constraintRir(set),
    );

    if (hint.isEmpty) return null;

    return _applyHintStrings(
      set: set,
      weightStr: hint.weightDisplay,
      repsStr: hint.repsDisplay,
      rirStr: hint.rirDisplay,
    );
  }

  /// No-history fallback: use getSuggestedWeightFromRep for weight, plan for
  /// reps/RIR. Avoids the rir=17.9 sentinel that BB3HintService would produce.
  Wes2SetState _applyNoHistoryHints({
    required Wes2ExerciseRow row,
    required Wes2SetState set,
    required Map<String, dynamic>? exSettings,
    required int weekIndex,
    required int sessionIndex,
  }) {
    final repTarget = BB3PlannedExerciseService.getRepTargetForSet(
      exSettings: exSettings,
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      setIndex: 0,
    );

    final planRir = BB3PlannedExerciseService.getRirFromPlan(
      exSettings: exSettings,
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      setNumber: 1,
    );

    final defaultWeight = PeriodizationModelUtils.getSuggestedWeightFromRep(
      row.name,
      repTarget,
      planRir > 0 ? planRir : 2.0,
    );

    return _applyModelHintToSet(
      existing: set,
      weightHint: defaultWeight > 0 ? defaultWeight : null,
      repsHint: repTarget > 0 ? repTarget : null,
      rirHint: planRir > 0 ? planRir : null,
    );
  }

  /// Parses BB3HintService display strings into numeric hints and applies them.
  Wes2SetState _applyHintStrings({
    required Wes2SetState set,
    required String weightStr,
    required String repsStr,
    required String rirStr,
  }) {
    double? weightHint;
    int? repsHint;
    double? rirHint;

    if (weightStr.isNotEmpty) {
      // Weight display may be a range like "95–100"; take the lower bound.
      final clean = weightStr.split('–').first.split('-').first.trim();
      weightHint = double.tryParse(clean);
    }
    if (repsStr.isNotEmpty) {
      repsHint = int.tryParse(repsStr);
    }
    if (rirStr.isNotEmpty) {
      rirHint = double.tryParse(rirStr);
    }

    return _applyModelHintToSet(
      existing: set,
      weightHint: weightHint,
      repsHint: repsHint,
      rirHint: rirHint,
    );
  }

  /// Applies model hints to a single set.
  /// Priority: BB3 hint > model hint > empty.
  /// Stale model hints are cleared when the recompute returns no hint.
  static Wes2SetState _applyModelHintToSet({
    required Wes2SetState existing,
    required double? weightHint,
    required int? repsHint,
    required double? rirHint,
  }) {
    return existing.copyWith(
      weight: _mergeDouble(existing.weight, weightHint),
      reps: _mergeInt(existing.reps, repsHint),
      rir: _mergeDouble(existing.rir, rirHint),
    );
  }

  /// Merges a model-derived [hint] into a double field.
  /// BB3 hint: unchanged. New hint: apply as modelHint.
  /// Null hint on a stale modelHint field: clear to empty.
  static Wes2FieldState<double> _mergeDouble(
      Wes2FieldState<double> field, double? hint) {
    if (field.origin == FieldOrigin.bb3Hint) return field;
    if (hint != null) return field.withHint(hint, FieldOrigin.modelHint);
    if (field.origin == FieldOrigin.modelHint) {
      return field.withHint(null, FieldOrigin.empty);
    }
    return field;
  }

  /// Merges a model-derived [hint] into an int field.
  static Wes2FieldState<int> _mergeInt(
      Wes2FieldState<int> field, int? hint) {
    if (field.origin == FieldOrigin.bb3Hint) return field;
    if (hint != null && hint > 0) return field.withHint(hint, FieldOrigin.modelHint);
    if (field.origin == FieldOrigin.modelHint) {
      return field.withHint(null, FieldOrigin.empty);
    }
    return field;
  }

  // ── Constraint helpers ─────────────────────────────────────────────────────
  // Priority: user actual > BB3 explicit hint > null (no constraint).
  // These are passed to BB3HintService so sibling fields are solved around the
  // same progression target E1RM with the constrained fields held fixed.

  static double? _constraintWeight(Wes2SetState s) =>
      s.weight.actualValue ??
      (s.weight.origin == FieldOrigin.bb3Hint ? s.weight.hintValue : null);

  static int? _constraintReps(Wes2SetState s) =>
      s.reps.actualValue ??
      (s.reps.origin == FieldOrigin.bb3Hint ? s.reps.hintValue : null);

  static double? _constraintRir(Wes2SetState s) =>
      s.rir.actualValue ??
      (s.rir.origin == FieldOrigin.bb3Hint ? s.rir.hintValue : null);
}
