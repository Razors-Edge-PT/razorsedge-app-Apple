import 'exercise_type.dart';
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
  /// The snapped weight hint as a NUMBER (kg; display-added for bodyweight
  /// exercises), or null when no weight is hinted. Consumers read this, never
  /// a re-parse of [weightDisplay]: a 2-decimal kg string cannot represent a
  /// pound-grid weight (285 lb = 129.27382545 kg), and parsing it back showed
  /// artefacts such as 239.995 lb.
  final double? weightKg;

  /// The RIR hint as a NUMBER, or null when no RIR is hinted. [rirDisplay]
  /// is rounded to one decimal (1.25 → "1.3"); BB3 surfaces and BB3-prescribed
  /// WES2 sets read this exact value instead.
  final double? rirValue;

  const BB3SetHint({
    this.weightDisplay = '',
    this.repsDisplay = '',
    this.rirDisplay = '',
    this.weightKg,
    this.rirValue,
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
    /// The exercise's CATALOGUE `type`, when the caller knows it. Passed
    /// straight through to the bodyweight classifier and the display↔absolute
    /// conversions, so a `Body Weight` exercise hints in ADDED load even
    /// before the type registry has been filled.
    String? exerciseType,
    required Map<String, dynamic> fullExerciseSettings,
    required int weekIndex,
    /// Rep-target instance index (0-based). For exposure models this is the
    /// canonical ActiveInstance.repInstanceIndex.
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
    // DUP Signature pre-computed rep target (overrides repTarget + baseReps).
    int? dupSigRep,
    /// RIR session index (0-based) — resolved separately from the rep
    /// instance (ActiveInstance.rirSessionIndex). Defaults to [sessionIndex]
    /// for callers whose model uses one index for both.
    int? rirSessionIndex,
    /// Canonical exposure position (ActiveInstance.exposurePosition). When
    /// given, the engine selects the DUP, By Exposure rep target from it.
    int? exposurePosition,
  }) {
    final int rirIdx = rirSessionIndex ?? sessionIndex;
    // Settings for this specific exercise
    final exSettings = fullExerciseSettings[exerciseId] as Map<String, dynamic>?;

    // ── Get RIR for this set (1-based setNumber) ──
    final setRir = BB3PlannedExerciseService.getRirFromPlan(
      exSettings: exSettings,
      weekIndex: weekIndex,
      sessionIndex: rirIdx,
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
      if (exerciseType != null && exerciseType.trim().isNotEmpty)
        'type': exerciseType.trim(),
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
        sessionIndex: rirIdx,
        setNumber: setNum,
      ),
      weightTextAt: (_, __) => '',
      rirTextAt: (_, __) => '',
      exposurePosition: exposurePosition,
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
        id: exerciseId, name: exerciseName, type: exerciseType);

    // ── Local increment grid from this exercise's own settings (exerciseId-keyed).
    // The Engine already used this same grid; we must snap the same way here so
    // the reverse-calculated weight is not re-rounded through a name-based lookup
    // that can miss the settings and fall back to the wrong step size.
    final _localGrid =
        PeriodizationModelUtils.gridFromRaw(exSettings?['increments']);

    // Snaps [target] to the nearest weight on the local lattice.
    // Falls back to the global 2.5-step grid when no settings are present,
    // matching the Engine's own gridFromRaw(null) default. The lattice is
    // unbounded, so a heavy lift is not clamped to a generated list's last
    // entry (247.5 kg with a 2.5 kg primary).
    double _snapToGrid(double target) => _localGrid.snap(target);

    // ── Shared helper: the snapped weight hint (kg, display-added for BW) ──
    double wKgHint(int reps, double rir) {
      final double abs = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: targetE1rm,
        reps: reps,
        rir: rir,
      );
      if (isBw) {
        // For BW exercises the increment grid is defined for the display-added
        // load (weight above bodyweight), not the absolute load.  Convert to
        // display weight first, then snap — snapping abs first would introduce
        // a rounding error whenever bodyweight is not a multiple of the step.
        // Identity must match the `isBw` test above: passing the name alone
        // left the conversion a no-op for a bodyweight exercise recognised by
        // its id or its catalogue type, so the hint showed the TOTAL load
        // where the athlete types the ADDED load.
        final added = PeriodizationModelUtils.toDisplayAddedWeight(
          uid: uid,
          absoluteKg: abs,
          exerciseId: exerciseId,
          exerciseName: exerciseName,
          exerciseType: exerciseType,
          asOfDate: selectedDate,
        );
        return _snapToGrid(added);
      }
      return _snapToGrid(abs);
    }

    // Baseline reps for this day: DUP Signature supplies a pre-computed rep
    // target; otherwise the BB3-planned repTarget, unless a progression model
    // (Smart Progression, Add Reps) deliberately chose different reps for E1RM
    // progression — then the Engine's reps. Engine baseReps are the last
    // resort.
    final int baseRepsRounded =
        (baseReps > 0 && baseReps <= 45) ? baseReps.round() : 0;
    final bool modelAdjustedReps =
        baseRepsRounded > 0 && repTarget > 0 && baseRepsRounded != repTarget;
    final int effectiveReps = dupSigRep ??
        (modelAdjustedReps
            ? baseRepsRounded
            : (repTarget > 0
                ? repTarget
                : (baseRepsRounded > 0 ? baseRepsRounded : 8)));

    final double? setRirValue = setRir > 0 ? setRir : null;
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
            weightDisplay: '',
            repsDisplay: '',
            rirDisplay: rirHintStr,
            rirValue: userRir != null ? null : setRirValue);
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
          rirValue: userRir != null ? null : setRirValue,
        );
      }

      if (userReps != null) {
        // Reps override: recompute weight hint to stay at targetE1rm.
        final double w = wKgHint(userReps, effectiveRir);
        return BB3SetHint(
          weightDisplay: _formatWeight(w),
          weightKg: w,
          repsDisplay: '',
          rirDisplay: rirHintStr,
          rirValue: userRir != null ? null : setRirValue,
        );
      }

      // Only RIR overridden: recompute weight hint at the new intensity.
      final effectiveRepsRirOnly = dupSigRep ??
          (repTarget > 0
              ? repTarget
              : (baseReps > 0 && baseReps <= 45 ? baseReps.round() : 8));
      final double w = wKgHint(effectiveRepsRirOnly, userRir!);
      return BB3SetHint(
        weightDisplay: _formatWeight(w),
        weightKg: w,
        repsDisplay:
            effectiveRepsRirOnly > 0 ? effectiveRepsRirOnly.toString() : '',
        rirDisplay: '',
      );
    }

    // ── Baseline hints (no overrides) ──────────────────────────────────────
    final double w = wKgHint(effectiveReps, setRir);
    return BB3SetHint(
      weightDisplay: _formatWeight(w),
      weightKg: w,
      repsDisplay: effectiveReps > 0 ? effectiveReps.toString() : '',
      rirDisplay: rirDisplay,
      rirValue: setRirValue,
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

      final bool isBw = PeriodizationModelUtils.isBodyweightExercise(
        id: exId,
        name: (ex['name'] ?? '').toString(),
        type: (ex['type'] ?? '').toString(),
      );
      for (final s in sets) {
        if (s is! Map) continue;
        // Shared raw-set rule: a stored 0 is "0 kg added" on a bodyweight
        // exercise and nothing at all on any other one.
        if (isRawSetPerformed(
            weightKg: s['weight'] as num?,
            reps: s['reps'] as num?,
            isBodyweight: isBw)) {
          return true;
        }
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
