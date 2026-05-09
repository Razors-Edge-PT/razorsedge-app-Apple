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

/// Phase 21B implementation: computes Set 1 model hints only.
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
    if (row.sets.isEmpty) return row;

    final base = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day);
    final sel = DateTime(date.year, date.month, date.day);
    final days = sel.difference(base).inDays;
    final weekIndex = days ~/ 7;
    final sessionIndex = days % 7;

    // Only compute hints for Set 1 (index 0) in Phase 21B.
    final set0 = row.sets[0];

    final newSet0 = _computeSet1Hints(
      row: row,
      set: set0,
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      date: date,
      uid: uid,
    );

    if (newSet0 == null) return row;

    final newSets = List<Wes2SetState>.from(row.sets);
    newSets[0] = newSet0;
    return row.copyWith(sets: newSets);
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

    // History path: delegate to BB3HintService for full model hint.
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

  /// Applies model hints to a single set, preserving BB3 hints on any field
  /// that already carries a bb3Hint origin.
  static Wes2SetState _applyModelHintToSet({
    required Wes2SetState existing,
    required double? weightHint,
    required int? repsHint,
    required double? rirHint,
  }) {
    final newWeight =
        (existing.weight.origin == FieldOrigin.bb3Hint || weightHint == null)
            ? existing.weight
            : existing.weight.withHint(weightHint, FieldOrigin.modelHint);

    final newReps =
        (existing.reps.origin == FieldOrigin.bb3Hint || repsHint == null || repsHint <= 0)
            ? existing.reps
            : existing.reps.withHint(repsHint, FieldOrigin.modelHint);

    final newRir =
        (existing.rir.origin == FieldOrigin.bb3Hint || rirHint == null)
            ? existing.rir
            : existing.rir.withHint(rirHint, FieldOrigin.modelHint);

    if (newWeight == existing.weight &&
        newReps == existing.reps &&
        newRir == existing.rir) {
      return existing;
    }

    return existing.copyWith(
      weight: newWeight,
      reps: newReps,
      rir: newRir,
    );
  }
}
