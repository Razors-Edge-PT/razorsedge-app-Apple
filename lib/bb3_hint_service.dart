import 'periodization_model_utils.dart';
import 'progression_engine.dart';
import 'bb3_planned_exercise_service.dart';

// ─── BB3HintService ──────────────────────────────────────────────────────────
//
// Produces hint display strings for BB3 using the same underlying logic as WES.
//
// Uses ProgressionEngine.engineProgressedValues() with synthetic inputs so the
// hint values match WES exactly.  WES hint functions are not changed.
//
// Override identity: exerciseId + setIndex (0-based). Never row-based.

class BB3SetHint {
  final String weightDisplay; // e.g. "97.5" or "95–100" or ""
  final String repsDisplay;   // e.g. "5" or ""
  final String rirDisplay;    // e.g. "2" or ""

  const BB3SetHint({
    this.weightDisplay = '',
    this.repsDisplay = '',
    this.rirDisplay = '',
  });

  bool get isEmpty =>
      weightDisplay.isEmpty && repsDisplay.isEmpty && rirDisplay.isEmpty;
}

class BB3HintService {
  BB3HintService._();

  // ── getHintsForSet ────────────────────────────────────────────────────────
  //
  // Returns display hint strings for one specific set.
  //
  // Process:
  //   1. Get target E1RM for the exercise via ProgressionEngine (same as WES).
  //   2. Get set-specific RIR from rirPlan (same formula as getRirFromPlanOrInput).
  //   3. Reverse-calculate weight hint at set-specific RIR.
  //   4. Rep target from repTargets.
  //
  // Returns empty strings when data is insufficient.

  static BB3SetHint getHintsForSet({
    required String exerciseId,
    required String exerciseName,
    required Map<String, dynamic> fullExerciseSettings,
    required int weekIndex,
    required int sessionIndex,
    required int setIndex,       // 0-based
    required DateTime blockStartDate,
    required DateTime? blockEndDate,
    required DateTime selectedDate,
    required String uid,
    int circuitIndex = 0,
    // Optional BB3 controller overrides for this set.
    // Non-null = the user has typed a value; the hint for that field is
    // suppressed and sibling-field hints recompute around it.
    double? userWeight,
    int? userReps,
    double? userRir,
  }) {
    // Settings for this specific exercise
    final exSettings = fullExerciseSettings[exerciseId] as Map<String, dynamic>?;

    // ── Get RIR for this set (1-based setNumber) ──
    final setRir = BB3PlannedExerciseService.getRirFromPlan(
      exSettings: exSettings,
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      setNumber: setIndex + 1,
    );

    // ── Get rep target for this set ──
    final repTarget = BB3PlannedExerciseService.getRepTargetForSet(
      exSettings: exSettings,
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      setIndex: setIndex,
    );

    // ── Build synthetic ProgressionEngineInputs for this exercise ──
    final syntheticEx = <String, dynamic>{
      'exerciseId': exerciseId,
      'name': exerciseName,
      'circuitIndex': circuitIndex,
      'id': exerciseId,
    };

    final engineCache = <String, Map<String, dynamic>>{};
    final rowKey = '$exerciseId|$circuitIndex';

    final inputs = ProgressionEngineInputs(
      blockStartDate: blockStartDate,
      blockEndDate: blockEndDate,
      selectedDate: selectedDate,
      cachedUid: uid,
      selectedExercisesWithCircuits: [syntheticEx],
      exerciseSettings: fullExerciseSettings,
      cachedProgressedValues: engineCache,
      seedHintsByKey: const {},
      resolvedBB2Values: const {},
      rowKeyBy: (_) => rowKey,
      rowCacheKey: (_) => rowKey,
      getApplicableWeekIndex: (_) => weekIndex,
      getRirFromPlanOrInput: (_, setNum) =>
          BB3PlannedExerciseService.getRirFromPlan(
        exSettings: exSettings,
        weekIndex: weekIndex,
        sessionIndex: sessionIndex,
        setNumber: setNum,
      ),
      weightTextAt: (_, __) => '',
      rirTextAt: (_, __) => '',
    );

    Map<String, dynamic> engineResult;
    try {
      engineResult = ProgressionEngine.engineProgressedValues(inputs, 0);
    } catch (_) {
      return const BB3SetHint();
    }

    // ── Derive target E1RM from engine result ──
    final baseWeight = (engineResult['weight'] as num?)?.toDouble() ?? 0.0;
    final baseReps = (engineResult['reps'] as num?)?.toDouble() ?? 0.0;
    final baseRir = (engineResult['rir'] as num?)?.toDouble() ?? 1.0;

    if (baseWeight <= 0 || baseReps <= 0) return const BB3SetHint();

    final targetE1rm = PeriodizationModelUtils.calculateE1RM(
      baseWeight,
      baseReps,
      baseRir,
    );

    if (targetE1rm <= 0) return const BB3SetHint();

    final isBw = PeriodizationModelUtils.isBodyweightExercise(
        id: exerciseId, name: exerciseName);

    // ── Shared helper: build the weight display string for a given reps/RIR ──
    String _wHint(int reps, double rir) {
      double abs = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: targetE1rm,
        reps: reps,
        rir: rir,
      );
      abs = PeriodizationModelUtils.roundToNearestValidIncrement(
        targetWeight: abs,
        exerciseName: exerciseName,
      );
      if (isBw) {
        final added = PeriodizationModelUtils.toDisplayAddedWeight(
          uid: uid,
          absoluteKg: abs,
          exerciseName: exerciseName,
          asOfDate: selectedDate,
        );
        final rounded = PeriodizationModelUtils.roundToNearestValidIncrement(
          targetWeight: added,
          exerciseName: exerciseName,
        );
        return _formatWeight(rounded);
      }
      return _formatWeight(abs);
    }

    final rirDisplay = setRir > 0
        ? (setRir == setRir.truncate()
            ? setRir.toInt().toString()
            : setRir.toStringAsFixed(1))
        : '';

    // ── Override-aware hint recomputation ──────────────────────────────────
    // When the user has typed a value in one field, suppress that field's hint
    // and recompute the sibling fields around the override so they stay aligned
    // with the same target E1RM.
    if (userWeight != null || userReps != null || userRir != null) {
      final effectiveRir = userRir ?? setRir;
      final rirHintStr = userRir != null ? '' : rirDisplay;

      if (userWeight != null && userReps != null) {
        // Both weight and reps entered — no hints needed for either field.
        return BB3SetHint(
            weightDisplay: '', repsDisplay: '', rirDisplay: rirHintStr);
      }

      if (userWeight != null) {
        // Weight override: recompute reps hint to stay at targetE1rm.
        final impliedReps = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: targetE1rm,
          weight: userWeight,
          baseWeight: userWeight,
          rir: effectiveRir,
        ).round().clamp(1, 45);
        return BB3SetHint(
          weightDisplay: '',
          repsDisplay: impliedReps.toString(),
          rirDisplay: rirHintStr,
        );
      }

      if (userReps != null) {
        // Reps override: recompute weight hint to stay at targetE1rm.
        return BB3SetHint(
          weightDisplay: _wHint(userReps, effectiveRir),
          repsDisplay: '',
          rirDisplay: rirHintStr,
        );
      }

      // Only RIR overridden: recompute weight hint at the new intensity.
      final effectiveRepsRirOnly = repTarget > 0
          ? repTarget
          : (baseReps > 0 && baseReps <= 45 ? baseReps.round() : 8);
      return BB3SetHint(
        weightDisplay: _wHint(effectiveRepsRirOnly, userRir!),
        repsDisplay: effectiveRepsRirOnly > 0 ? effectiveRepsRirOnly.toString() : '',
        rirDisplay: '',
      );
    }

    // ── Baseline hints (no overrides) ──────────────────────────────────────
    // Prefer the BB3-planned repTarget (session-aware) over the engine's baseReps
    // which is computed from the exercise's first session and ignores BB3 sessionIndex.
    final effectiveReps = repTarget > 0
        ? repTarget
        : (baseReps > 0 && baseReps <= 45 ? baseReps.round() : 8);
    return BB3SetHint(
      weightDisplay: _wHint(effectiveReps, setRir),
      repsDisplay: effectiveReps > 0 ? effectiveReps.toString() : '',
      rirDisplay: rirDisplay,
    );
  }

  // ── getTopSet ─────────────────────────────────────────────────────────────
  //
  // Finds the set with the highest E1RM among completed sets for an exercise
  // on a given day.  Used for the collapsed view of a completed/in-progress row.
  //
  // completedExercisesForDay: the exercises[] list from users/{uid}/workouts/{date}
  // Returns null when no completed sets are found for that exerciseId.

  static Map<String, dynamic>? getTopSet({
    required String exerciseId,
    required List<Map<String, dynamic>> completedExercisesForDay,
  }) {
    Map<String, dynamic>? topSet;
    double topE1rm = -1;

    for (final ex in completedExercisesForDay) {
      final exId = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
      if (exId != exerciseId) continue;

      final sets = ex['sets'];
      if (sets is! List) continue;

      for (final s in sets) {
        if (s is! Map) continue;
        final w = (s['weight'] as num?)?.toDouble();
        final r = (s['reps'] as num?)?.toDouble();
        if (w == null || r == null || w <= 0 || r <= 0) continue;

        final rir = (s['rir'] as num?)?.toDouble() ?? 0.0;
        final e1rm = PeriodizationModelUtils.calculateE1RM(w, r, rir);
        if (e1rm > topE1rm) {
          topE1rm = e1rm;
          topSet = {
            'weight': w,
            'reps': r.toInt(),
            'rir': rir,
            'e1rm': e1rm,
          };
        }
      }
    }

    return topSet;
  }

  // ── isExerciseLocked ──────────────────────────────────────────────────────
  //
  // An exercise is locked when any completed set for that exerciseId on that
  // day has both weight and reps entered (non-null, non-zero).

  static bool isExerciseLocked({
    required String exerciseId,
    required List<Map<String, dynamic>> completedExercisesForDay,
  }) {
    for (final ex in completedExercisesForDay) {
      final exId = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
      if (exId != exerciseId) continue;

      final sets = ex['sets'];
      if (sets is! List) continue;

      for (final s in sets) {
        if (s is! Map) continue;
        final w = (s['weight'] as num?)?.toDouble();
        final r = (s['reps'] as num?)?.toDouble();
        if (w != null && w > 0 && r != null && r > 0) return true;
      }
    }
    return false;
  }

  // ── Format helpers ────────────────────────────────────────────────────────
  // Matches WES formatWeight() exactly.

  static String _formatWeight(double v) {
    final s2 = v.toStringAsFixed(2);
    if (s2.endsWith('25') || s2.endsWith('75')) return s2;
    if (s2.endsWith('0')) {
      final s1 = v.toStringAsFixed(1);
      if (s1.endsWith('.0')) return s1.substring(0, s1.length - 2);
      return s1;
    }
    return s2;
  }

  // Formats a completed set for display in the locked/collapsed view.
  static String formatCompletedSet(Map<String, dynamic> set) {
    final w = (set['weight'] as num?)?.toDouble();
    final r = (set['reps'] as num?)?.toInt();
    if (w == null && r == null) return '';
    if (w == null) return '${r}r';
    if (r == null) return _formatWeight(w);
    return '${_formatWeight(w)} × $r';
  }
}
