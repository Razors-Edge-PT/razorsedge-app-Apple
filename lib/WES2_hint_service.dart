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
/// Set 2+ is a no-op; explicit BB3 hint values are never overwritten.
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

    // Only compute hints for Set 1 (index 0) in Phase 21B/21C.
    final newSets = List<Wes2SetState>.from(padded);
    newSets[0] = _computeSet1Hints(
      row: row,
      set: padded[0],
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      date: date,
      uid: uid,
    );
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
        .map((r) => computeRowHints(row: r, blockId: blockId, uid: uid, date: date))
        .toList();
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Computes Set 1 hints with full priority chain:
  ///   1. Resolve actual/BB3 constraints for each field.
  ///   2. Try BB3HintService (history path) — solves sibling hints around
  ///      constraints while preserving the day's progression target E1RM.
  ///   3. Closest-E1RM candidate selection when weight was re-derived under a
  ///      reps or RIR constraint (prevents nearest-increment bias).
  ///   4. Fill any fields still missing after step 2/3 from plan/default values.
  ///
  /// BB3 fields with an explicit non-null hintValue are treated as constraints.
  /// BB3 fields with origin=bb3Hint but hintValue=null (BB3 had no planned value)
  /// are NOT locked — model hints may still fill them.
  ///
  /// Always returns a set; never returns null.
  Wes2SetState _computeSet1Hints({
    required Wes2ExerciseRow row,
    required Wes2SetState set,
    required int weekIndex,
    required int sessionIndex,
    required DateTime date,
    required String uid,
  }) {
    final exSettings = exerciseSettings[row.exerciseId] as Map<String, dynamic>?;

    // Per-field constraints: user actual > BB3 explicit hint (non-null) > null.
    final constrainedWeight = _constraintWeight(set);
    final constrainedReps   = _constraintReps(set);
    final constrainedRir    = _constraintRir(set);

    // Plan-level values used as fallback when neither BB3 nor model fills a field.
    final planReps = BB3PlannedExerciseService.getRepTargetForSet(
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

    // Effective reps/RIR used to compute a default weight hint.
    // Constraint wins over plan, plan wins over hard fallback.
    final repsForWeight = constrainedReps ?? (planReps > 0 ? planReps : 8);
    final rirForWeight  = constrainedRir  ?? (planRir  > 0 ? planRir  : 2.0);

    double? weightHint;
    int?    repsHint;
    double? rirHint;

    // ── History path ──────────────────────────────────────────────────────────
    // BB3HintService wraps ProgressionEngine and solves all three fields around
    // the provided constraints, preserving the day's target E1RM.
    // When hint.isEmpty (engine failed), fall through to plan-based defaults.
    if (PeriodizationModelUtils.savedWorkoutsList.isNotEmpty) {
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
        userWeight: constrainedWeight,
        userReps:   constrainedReps,
        userRir:    constrainedRir,
      );

      bool weightFromHistory = false;
      if (!hint.isEmpty) {
        if (hint.weightDisplay.isNotEmpty) {
          // Weight display may be a range like "95–100"; take the lower bound.
          final clean = hint.weightDisplay.split('–').first.split('-').first.trim();
          final parsed = double.tryParse(clean);
          if (parsed != null) {
            weightHint = parsed;
            weightFromHistory = true;
          }
        }
        if (hint.repsDisplay.isNotEmpty) {
          repsHint = int.tryParse(hint.repsDisplay);
        }
        if (hint.rirDisplay.isNotEmpty) {
          rirHint = double.tryParse(hint.rirDisplay);
        }
      }
      // hint.isEmpty means BB3HintService could not compute; fall through below.

      // ── Closest-E1RM weight candidate selection ───────────────────────────
      // When weight was re-derived under a reps or RIR constraint,
      // rounding to the nearest increment (by weight distance) does not
      // guarantee the resulting E1RM is closest to the day's progression target.
      // Get the unconstrained target E1RM, then generate floor/nearest/ceiling
      // candidates and pick the one whose E1RM is closest to the target.
      if (weightFromHistory && (constrainedReps != null || constrainedRir != null)) {
        final targetE1rm = _getTargetE1rm(
          row: row,
          weekIndex: weekIndex,
          sessionIndex: sessionIndex,
          date: date,
          uid: uid,
        );
        if (targetE1rm != null) {
          final rawWeight = PeriodizationModelUtils.reverseCalculateWeight(
            targetE1RM: targetE1rm,
            reps: repsForWeight,
            rir: rirForWeight,
          );
          final best = _closestE1rmWeight(
            targetE1rm: targetE1rm,
            rawWeight: rawWeight,
            reps: repsForWeight,
            rir: rirForWeight,
            exerciseName: row.name,
          );
          if (best != null) weightHint = best;
        }
      }
    }

    // ── Plan/default fallback ─────────────────────────────────────────────────
    // Fill any field that was not resolved by BB3HintService and is not locked
    // by an explicit BB3 hint value.  Fields with origin=bb3Hint but
    // hintValue=null are not locked — BB3 had no planned value for them.

    if (weightHint == null &&
        set.weight.actualValue == null &&
        !_isBb3Locked(set.weight)) {
      final defW = PeriodizationModelUtils.getSuggestedWeightFromRep(
        row.name,
        repsForWeight,
        rirForWeight,
      );
      if (defW > 0) weightHint = defW;
    }

    if (repsHint == null &&
        set.reps.actualValue == null &&
        !_isBb3Locked(set.reps) &&
        planReps > 0) {
      repsHint = planReps;
    }

    if (rirHint == null &&
        set.rir.actualValue == null &&
        !_isBb3Locked(set.rir) &&
        planRir > 0) {
      rirHint = planRir;
    }

    return _applyModelHintToSet(
      existing: set,
      weightHint: weightHint,
      repsHint: repsHint,
      rirHint: rirHint,
    );
  }

  /// Gets the unconstrained progression target E1RM for the day.
  /// Calls BB3HintService with no user overrides to obtain the baseline hints,
  /// then derives E1RM from them.  Returns null when history is absent or the
  /// engine cannot produce a valid result.
  double? _getTargetE1rm({
    required Wes2ExerciseRow row,
    required int weekIndex,
    required int sessionIndex,
    required DateTime date,
    required String uid,
  }) {
    if (PeriodizationModelUtils.savedWorkoutsList.isEmpty) return null;
    final baseline = BB3HintService.getHintsForSet(
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
      // No constraints — pure baseline to extract the day's target E1RM.
    );
    if (baseline.isEmpty) return null;
    final cleanW = baseline.weightDisplay.split('–').first.split('-').first.trim();
    final w = double.tryParse(cleanW);
    final r = double.tryParse(baseline.repsDisplay);
    final rir = double.tryParse(baseline.rirDisplay) ?? 0.0;
    if (w == null || r == null || w <= 0 || r <= 0) return null;
    return PeriodizationModelUtils.calculateE1RM(w, r, rir);
  }

  /// Picks the valid-increment weight whose E1RM is closest to [targetE1rm].
  /// Evaluates the nearest rounded increment plus one step below and one above,
  /// returning the candidate with the smallest absolute E1RM difference.
  static double? _closestE1rmWeight({
    required double targetE1rm,
    required double rawWeight,
    required int reps,
    required double rir,
    required String exerciseName,
  }) {
    if (targetE1rm <= 0 || rawWeight <= 0) return null;

    final nearest = PeriodizationModelUtils.roundToNearestValidIncrement(
      targetWeight: rawWeight,
      exerciseName: exerciseName,
    );

    // Find the step size by rounding the next value just above nearest.
    final nextUp = PeriodizationModelUtils.roundToNearestValidIncrement(
      targetWeight: nearest + 0.01,
      exerciseName: exerciseName,
    );
    final step = nextUp - nearest;
    if (step <= 0) return nearest;

    final candidates = <double>[
      if (nearest - step > 0) nearest - step,
      nearest,
      nearest + step,
    ];

    double bestW = nearest;
    double bestDiff = double.infinity;
    for (final w in candidates) {
      final e1rm = PeriodizationModelUtils.calculateE1RM(w, reps.toDouble(), rir);
      final diff = (e1rm - targetE1rm).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestW = w;
      }
    }
    return bestW;
  }

  /// Applies model hints to a single set.
  /// Priority: explicit BB3 hint (non-null hintValue) > model hint > empty.
  /// Stale model hints are cleared when recompute returns no hint.
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

  /// True only when a BB3 hint explicitly provides a non-null value for this field.
  /// Uses [hintOrigin] (not [origin]) so the lock survives actual save/clear cycles —
  /// [origin] reflects how the actual was set, not where the hint came from.
  static bool _isBb3Locked<T extends Object>(Wes2FieldState<T> f) =>
      f.hintOrigin == FieldOrigin.bb3Hint && f.hintValue != null;

  /// Merges a model-derived [hint] into a double field.
  /// Explicit BB3 hint (non-null hintValue): unchanged.
  /// New hint: apply as modelHint. Stale modelHint with null recompute: clear.
  static Wes2FieldState<double> _mergeDouble(
      Wes2FieldState<double> field, double? hint) {
    if (_isBb3Locked(field)) return field;
    if (hint != null) return field.withHint(hint, FieldOrigin.modelHint);
    if (field.origin == FieldOrigin.modelHint) {
      return field.withHint(null, FieldOrigin.empty);
    }
    return field;
  }

  /// Merges a model-derived [hint] into an int field.
  static Wes2FieldState<int> _mergeInt(
      Wes2FieldState<int> field, int? hint) {
    if (_isBb3Locked(field)) return field;
    if (hint != null && hint > 0) return field.withHint(hint, FieldOrigin.modelHint);
    if (field.origin == FieldOrigin.modelHint) {
      return field.withHint(null, FieldOrigin.empty);
    }
    return field;
  }

  // ── Constraint helpers ─────────────────────────────────────────────────────
  // Priority: user actual > BB3 explicit hint (non-null hintValue) > null.
  // These are passed to BB3HintService so sibling fields are solved around the
  // same progression target E1RM with the constrained fields held fixed.

  static double? _constraintWeight(Wes2SetState s) =>
      s.weight.actualValue ??
      (s.weight.hintOrigin == FieldOrigin.bb3Hint ? s.weight.hintValue : null);

  static int? _constraintReps(Wes2SetState s) =>
      s.reps.actualValue ??
      (s.reps.hintOrigin == FieldOrigin.bb3Hint ? s.reps.hintValue : null);

  static double? _constraintRir(Wes2SetState s) =>
      s.rir.actualValue ??
      (s.rir.hintOrigin == FieldOrigin.bb3Hint ? s.rir.hintValue : null);
}
