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

/// Phase 21D implementation: computes Set 1 model hints, then cascades
/// Set 2+ hints from the immediately prior resolved set using WES drop-off
/// group math.  Explicit BB3 hint values are never overwritten.
class Wes2HintServiceImpl implements Wes2HintService {
  final Map<String, dynamic> exerciseSettings;
  final Map<String, String> exerciseTypes;
  final DateTime blockStartDate;
  final DateTime? blockEndDate;
  final String uid;

  const Wes2HintServiceImpl({
    required this.exerciseSettings,
    required this.blockStartDate,
    required this.blockEndDate,
    required this.uid,
    this.exerciseTypes = const {},
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

    final newSets = List<Wes2SetState>.from(padded);
    newSets[0] = _computeSet1Hints(
      row: row,
      set: padded[0],
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      date: date,
      uid: uid,
    );

    // Phase 21D: cascade Set 2+ hints from the immediately prior resolved set.
    final exSettings = exerciseSettings[row.exerciseId] as Map<String, dynamic>?;
    for (int i = 1; i < effectiveCount; i++) {
      newSets[i] = _computeSetNHints(
        row: row,
        set: newSets[i],
        prevSet: newSets[i - 1],
        setIdx: i,
        exSettings: exSettings,
        weekIndex: weekIndex,
        sessionIndex: sessionIndex,
      );
    }

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

    // If BB3 explicitly supplies all three hints, their combined E1RM defines
    // the target for this set — stronger than history/model target.
    final bb3SetTarget = _bb3FullSetTargetE1rm(set);

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

    // Anchor reps only when the weight constraint is a BB3 explicit hint (no
    // user actual), or when RIR is constrained. User-typed weight allows reps
    // to adapt reactively to maintain the target E1RM.
    if (constrainedReps == null &&
        (constrainedRir != null ||
         (constrainedWeight != null && set.weight.actualValue == null))) {
      repsHint = set.reps.hintValue ?? (planReps > 0 ? planReps : repsHint);
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
      if (defW > 0) {
        // Issue 5: PMU _defaultWeightForExercise returns 5 for Machine; override to 6.
        final type = exerciseTypes[row.exerciseId];
        weightHint = (defW == 5.0 && type == 'Machine') ? 6.0 : defW;
      }
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

    Wes2SetState result = _applyModelHintToSet(
      existing: set,
      weightHint: weightHint,
      repsHint: repsHint,
      rirHint: rirHint,
    );

    // Phase 21F: when actual weight + actual reps are both present and RIR is
    // neither typed nor BB3-locked, solve the RIR hint that preserves the
    // progression target E1RM.  BB3-locked RIR is excluded here so its hint
    // value is preserved for the Phase 21C blue cue comparison below.
    // withHint() never touches actualValue, so typing actual RIR still wins.
    if (set.weight.actualValue != null &&
        set.reps.actualValue != null &&
        set.rir.actualValue == null &&
        !_isBb3Locked(set.rir)) {
      final targetE1rm = bb3SetTarget ?? _getTargetE1rm(
        row: row,
        weekIndex: weekIndex,
        sessionIndex: sessionIndex,
        date: date,
        uid: uid,
      );
      final solved = targetE1rm != null
          ? _solveRirForTargetE1rm(
              targetE1rm: targetE1rm,
              weight: set.weight.actualValue!,
              reps: set.reps.actualValue!,
            )
          : null;
      if (solved != null) {
        result = result.copyWith(
          rir: result.rir.withHint(solved, FieldOrigin.modelHint),
        );
      }
    }

    // Phase 21C: BB3-override locked-field cue flags (Set 1).
    // Each cue fires only when BOTH of the following hold:
    //   (a) the field has no WES2 actual and carries a BB3 explicit hint, AND
    //   (b) at least one relevant sibling field has a current WES2 actual that
    //       changes the solve context (so the conflict is user-driven, not just
    //       a static model-vs-BB3 difference).
    // Flags are display-only; no hint values or Firestore are affected.
    bool weightCue = false;
    bool repsCue = false;
    bool rirCue = false;

    final weightBb3Only =
        set.weight.actualValue == null && _isBb3Locked(set.weight);
    final repsBb3Only =
        set.reps.actualValue == null && _isBb3Locked(set.reps);
    final rirBb3Only =
        set.rir.actualValue == null && _isBb3Locked(set.rir);

    // Compute target E1RM once if any cue may fire.
    double? targetE1rmForCue;
    final needsE1rm =
        (weightBb3Only &&
            (set.reps.actualValue != null || set.rir.actualValue != null)) ||
        (repsBb3Only &&
            (set.weight.actualValue != null || set.rir.actualValue != null)) ||
        (rirBb3Only &&
            set.weight.actualValue != null &&
            set.reps.actualValue != null);
    if (needsE1rm) {
      targetE1rmForCue = bb3SetTarget;
      if (targetE1rmForCue == null &&
          PeriodizationModelUtils.savedWorkoutsList.isNotEmpty) {
        targetE1rmForCue = _getTargetE1rm(
          row: row,
          weekIndex: weekIndex,
          sessionIndex: sessionIndex,
          date: date,
          uid: uid,
        );
      }
    }

    // Weight cue: requires a sibling reps or RIR actual to change the solve.
    if (weightBb3Only &&
        (set.reps.actualValue != null || set.rir.actualValue != null) &&
        targetE1rmForCue != null) {
      final rawFreeW = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: targetE1rmForCue,
        reps: repsForWeight,
        rir: rirForWeight,
      );
      if (rawFreeW > 0) {
        final freeW = _closestE1rmWeight(
          targetE1rm: targetE1rmForCue,
          rawWeight: rawFreeW,
          reps: repsForWeight,
          rir: rirForWeight,
          exerciseName: row.name,
        );
        if (freeW != null && (freeW - set.weight.hintValue!).abs() >= 0.25) {
          weightCue = true;
        }
      }
    }

    // Reps cue: requires a sibling weight or RIR actual to change the solve.
    // constrainedWeight may be an actual or a BB3 hint; the gate above ensures
    // at least one sibling actual is present, so the context is user-driven.
    if (repsBb3Only &&
        (set.weight.actualValue != null || set.rir.actualValue != null) &&
        targetE1rmForCue != null &&
        constrainedWeight != null) {
      final freeD = PeriodizationModelUtils.reverseCalculateReps(
        targetE1RM: targetE1rmForCue,
        weight: constrainedWeight,
        baseWeight: constrainedWeight,
        rir: rirForWeight,
      ).clamp(1.0, 45.0);
      final freeR = freeD.round().clamp(1, 45);
      if ((freeR - set.reps.hintValue!).abs() >= 1) {
        repsCue = true;
      }
    }

    // RIR cue: requires both weight and reps actuals.
    // Uses free solved RIR (not planRir) — the difference must be caused by the
    // user's actual weight + reps, not by a static plan-vs-BB3 discrepancy.
    if (rirBb3Only &&
        set.weight.actualValue != null &&
        set.reps.actualValue != null &&
        targetE1rmForCue != null) {
      final freeSolvedRir = _solveRirForTargetE1rm(
        targetE1rm: targetE1rmForCue,
        weight: set.weight.actualValue!,
        reps: set.reps.actualValue!,
      );
      if (freeSolvedRir != null &&
          (freeSolvedRir - set.rir.hintValue!).abs() >= 0.5) {
        rirCue = true;
      }
    }

    result = result.copyWith(
      weightLockedByBb3OverrideCue: weightCue,
      repsLockedByBb3OverrideCue: repsCue,
      rirLockedByBb3OverrideCue: rirCue,
    );

    return result;
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

  /// Computes Set N (N ≥ 2, setIdx ≥ 1) hints using the WES drop-off cascade.
  ///
  /// Previous set resolved values drive the target E1RM:
  ///   targetE1RM = clamp(prevE1RM − gatedDrop, 1.0, 9999.0)
  ///
  /// RIR priority: actual > BB3 explicit hint > rirPlan set-specific > 0.0 fallback.
  /// Fields with BB3 locks or actuals are left untouched via _mergeDouble/_mergeInt.
  Wes2SetState _computeSetNHints({
    required Wes2ExerciseRow row,
    required Wes2SetState set,
    required Wes2SetState prevSet,
    required int setIdx,
    required Map<String, dynamic>? exSettings,
    required int weekIndex,
    required int sessionIndex,
  }) {
    final prevWeight = prevSet.weight.actualValue ?? prevSet.weight.hintValue;
    final prevReps   = prevSet.reps.actualValue   ?? prevSet.reps.hintValue;
    if (prevWeight == null || prevReps == null) return set;

    final prevRir   = prevSet.rir.actualValue ?? prevSet.rir.hintValue ?? 0.0;
    final prevE1rm  = PeriodizationModelUtils.calculateE1RM(
      prevWeight, prevReps.toDouble(), prevRir,
    );
    if (prevE1rm <= 0) return set;

    final group      = _dropGroup(row.name, exSettings);
    final rawDrop    = _rawDropFor(group, setIdx);
    final drop       = _gatedDrop(rawDrop, prevRir);
    final cascadeTarget = (prevE1rm - drop).clamp(1.0, 9999.0);
    final targetE1rm = _bb3FullSetTargetE1rm(set) ?? cascadeTarget;

    // RIR precedence: actual > BB3 explicit > rirPlan > 0.0 fallback.
    final constrainedRir = _constraintRir(set);
    final planRir = BB3PlannedExerciseService.getRirFromPlan(
      exSettings: exSettings,
      weekIndex: weekIndex,
      sessionIndex: sessionIndex,
      setNumber: setIdx + 1,
    );
    final thisRir = constrainedRir ?? (planRir > 0 ? planRir : 0.0);
    // Emit RIR hint only when neither actual nor BB3 holds the field.
    final rirHint = constrainedRir == null && planRir > 0 ? planRir : null;

    final cwt   = _constraintWeight(set);
    final creps = _constraintReps(set);

    double? weightHint;
    int?    repsHint;

    if (cwt != null && creps != null) {
      // Both locked — nothing to compute.
    } else if (creps != null) {
      // Reps locked → solve weight at locked reps.
      final raw = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: targetE1rm,
        reps: creps,
        rir: thisRir,
      );
      if (raw > 0) {
        weightHint = PeriodizationModelUtils.roundToNearestValidIncrement(
          targetWeight: raw,
          exerciseName: row.name,
        );
      }
    } else if (cwt != null) {
      // Weight constraint: solve reps unless locked by BB3 or user actual.
      // User-typed weight allows reps to adapt reactively to maintain target E1RM.
      if (!_isBb3Locked(set.reps) && set.reps.actualValue == null) {
        final midD = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: targetE1rm,
          weight: prevWeight,
          baseWeight: prevWeight,
          rir: thisRir,
        ).clamp(1.0, 45.0);
        repsHint = _closestRepsForWeight(
          targetE1rm: targetE1rm,
          weight: cwt,
          center: midD.round().clamp(1, 45),
          rir: thisRir,
          group: group,
        );
      }
    } else {
      // Neither locked.
      // Issue 1: if only RIR is typed, anchor reps at existing hint to update weight only.
      if (set.rir.actualValue != null && set.reps.hintValue != null) {
        final rawW = PeriodizationModelUtils.reverseCalculateWeight(
          targetE1RM: targetE1rm,
          reps: set.reps.hintValue!,
          rir: thisRir,
        );
        if (rawW > 0) {
          weightHint = PeriodizationModelUtils.roundToNearestValidIncrement(
            targetWeight: rawW,
            exerciseName: row.name,
          );
        }
        // repsHint stays null — existing hint preserved via _mergeInt.
      } else {
        // Compute both from center reps anchored at prevWeight.
        final midD = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: targetE1rm,
          weight: prevWeight,
          baseWeight: prevWeight,
          rir: thisRir,
        ).clamp(1.0, 45.0);
        final midRep = midD.round().clamp(1, 45);

        final rawW = PeriodizationModelUtils.reverseCalculateWeight(
          targetE1RM: targetE1rm,
          reps: midRep,
          rir: thisRir,
        );
        if (rawW > 0) {
          weightHint = PeriodizationModelUtils.roundToNearestValidIncrement(
            targetWeight: rawW,
            exerciseName: row.name,
          );
        }
        repsHint = midRep;
      }
    }

    Wes2SetState result = _applyModelHintToSet(
      existing: set,
      weightHint: weightHint,
      repsHint: repsHint,
      rirHint: rirHint,
    );

    // Phase 21F: same logic as Set 1 — solve RIR when both actuals present and
    // RIR is not BB3-locked. BB3-locked RIR is preserved for the 21C cue below.
    if (set.weight.actualValue != null &&
        set.reps.actualValue != null &&
        set.rir.actualValue == null &&
        !_isBb3Locked(set.rir)) {
      final solved = _solveRirForTargetE1rm(
        targetE1rm: targetE1rm,
        weight: set.weight.actualValue!,
        reps: set.reps.actualValue!,
      );
      if (solved != null) {
        result = result.copyWith(
          rir: result.rir.withHint(solved, FieldOrigin.modelHint),
        );
      }
    }

    // Phase 21C: BB3-override locked-field cue flags (Set N).
    // Same "offending actual" gate as Set 1 — cue fires only when a current
    // WES2 actual in a relevant sibling is causing the conflict.
    bool weightCue = false;
    bool repsCue = false;
    bool rirCue = false;

    final weightBb3OnlyN =
        set.weight.actualValue == null && _isBb3Locked(set.weight);
    final repsBb3OnlyN =
        set.reps.actualValue == null && _isBb3Locked(set.reps);
    final rirBb3OnlyN =
        set.rir.actualValue == null && _isBb3Locked(set.rir);

    // Weight/reps cues share the unconstrained (free) computation.
    final needsFreeN =
        (weightBb3OnlyN &&
            (set.reps.actualValue != null || set.rir.actualValue != null)) ||
        (repsBb3OnlyN &&
            (set.weight.actualValue != null || set.rir.actualValue != null));
    if (needsFreeN) {
      // Weight cue: free reps at prevWeight → free weight at targetE1rm.
      if (weightBb3OnlyN &&
          (set.reps.actualValue != null || set.rir.actualValue != null)) {
        final freeD = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: targetE1rm,
          weight: prevWeight,
          baseWeight: prevWeight,
          rir: thisRir,
        ).clamp(1.0, 45.0);
        final freeRepInt = freeD.round().clamp(1, 45);
        final rawFreeW = PeriodizationModelUtils.reverseCalculateWeight(
          targetE1RM: targetE1rm,
          reps: freeRepInt,
          rir: thisRir,
        );
        if (rawFreeW > 0) {
          final freeW = PeriodizationModelUtils.roundToNearestValidIncrement(
            targetWeight: rawFreeW,
            exerciseName: row.name,
          );
          if ((freeW - set.weight.hintValue!).abs() >= 0.25) {
            weightCue = true;
          }
        }
      }

      // Reps cue: anchored at actual weight when present — the cue must reflect
      // what the model suggests at the weight the user actually entered, not prevWeight.
      if (repsBb3OnlyN &&
          (set.weight.actualValue != null || set.rir.actualValue != null)) {
        final anchorW = set.weight.actualValue ?? prevWeight;
        final freeRepForCue = PeriodizationModelUtils.reverseCalculateReps(
          targetE1RM: targetE1rm,
          weight: anchorW,
          baseWeight: anchorW,
          rir: thisRir,
        ).clamp(1.0, 45.0).round().clamp(1, 45);
        if ((freeRepForCue - set.reps.hintValue!).abs() >= 1) {
          repsCue = true;
        }
      }
    }

    // RIR cue: requires both actuals; uses free solved RIR, not planRir.
    if (rirBb3OnlyN &&
        set.weight.actualValue != null &&
        set.reps.actualValue != null) {
      final freeSolvedRir = _solveRirForTargetE1rm(
        targetE1rm: targetE1rm,
        weight: set.weight.actualValue!,
        reps: set.reps.actualValue!,
      );
      if (freeSolvedRir != null &&
          (freeSolvedRir - set.rir.hintValue!).abs() >= 0.5) {
        rirCue = true;
      }
    }

    result = result.copyWith(
      weightLockedByBb3OverrideCue: weightCue,
      repsLockedByBb3OverrideCue: repsCue,
      rirLockedByBb3OverrideCue: rirCue,
    );

    return result;
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

  /// Returns the E1RM implied by BB3's explicit hints when all three fields
  /// carry a BB3 lock.  Used as the priority target E1RM when the coach has
  /// prescribed a complete set (weight + reps + RIR), overriding history/model.
  /// Returns null when any field lacks a BB3 lock or the result is ≤ 0.
  static double? _bb3FullSetTargetE1rm(Wes2SetState set) {
    if (!_isBb3Locked(set.weight)) return null;
    if (!_isBb3Locked(set.reps)) return null;
    if (!_isBb3Locked(set.rir)) return null;
    final e = PeriodizationModelUtils.calculateE1RM(
      set.weight.hintValue!,
      set.reps.hintValue!.toDouble(),
      set.rir.hintValue!,
    );
    return e > 0 ? e : null;
  }

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

  // ── Phase 21F: RIR solver ─────────────────────────────────────────────────

  /// Searches RIR candidates [0.0, 0.5, …, 10.0] and returns the one whose
  /// calculateE1RM(weight, reps, candidate) is closest to [targetE1rm].
  /// Candidates are at 0.5 increments, so the result is already rounded to 0.5.
  /// Returns null when any input is invalid (≤ 0).
  static double? _solveRirForTargetE1rm({
    required double targetE1rm,
    required double weight,
    required int reps,
  }) {
    if (targetE1rm <= 0 || weight <= 0 || reps <= 0) return null;
    double? bestRir;
    double bestDiff = double.infinity;
    for (int i = 0; i <= 20; i++) {
      final candidate = i * 0.5;
      final e1rm = PeriodizationModelUtils.calculateE1RM(
        weight, reps.toDouble(), candidate,
      );
      final diff = (e1rm - targetE1rm).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestRir  = candidate;
      }
    }
    return bestRir;
  }

  // ── Drop-off helpers (Phase 21D) ──────────────────────────────────────────

  /// WES drop-off group for an exercise.
  /// Mirrors workout_entry_screen.dart _groupFor exactly:
  /// named overrides first (A, B), then category from exerciseSettings, else C.
  static String _dropGroup(String exerciseName, Map<String, dynamic>? exSettings) {
    final n = exerciseName.trim().toLowerCase();
    const groupA = {
      'chin-up',
      'bench press, barbell',
      'bench press, narrow grip',
      'bench press, larsen press',
      'bench press, long pause',
      'back squat, barbell',
      'back squat, low bar',
      'back squat, paused squat',
      'back squat, pin squat',
      'deadlift, conventional',
      'deadlift, deficit',
      'deadlift, sumo',
      'deadlift, sumo, deficit',
      'romanian deadlift',
    };
    if (groupA.contains(n)) return 'A';

    const groupB = {
      'overhead dumbbell press, unilateral',
      'overhead barbell press',
    };
    if (groupB.contains(n)) return 'B';

    final cat = (exSettings?['category'] as String?)?.toLowerCase().trim() ?? '';
    const groupC = {
      'horizontal press',
      'horizontal pull',
      'vertical press',
      'vertical pull',
      'squat pattern',
      'hip hinge',
    };
    const groupD = {
      'lateral raise',
      'arm extension',
      'arm curl',
      'leg extension',
      'leg curl',
      'hip abduction/adduction',
      'calf raise',
      'core',
    };
    if (groupC.contains(cat)) return 'C';
    if (groupD.contains(cat)) return 'D';
    return 'C';
  }

  /// Raw E1RM drop (kg) per set by group.  setIdx is 0-based (1 = Set 2, 2 = Set 3).
  static double _rawDropFor(String group, int setIdx) {
    switch (group) {
      case 'A':
        return 5.5;
      case 'B':
        if (setIdx == 1) return 1.5;
        if (setIdx == 2) return 4.3;
        return 1.5;
      case 'C':
        return 1.0;
      case 'D':
        return 0.3;
      default:
        return 1.0;
    }
  }

  /// Applies RIR gating: high-RIR previous set → reduced or zero drop.
  static double _gatedDrop(double drop, double prevRir) {
    if (prevRir > 2.0) return 0.0;
    if (prevRir >= 1.8 && prevRir <= 2.0) return drop * 0.8;
    return drop;
  }

  /// Picks the reps from {center−1, center, center+1} whose E1RM at [weight]
  /// is closest to [targetE1rm], with WES tolerance rules (D: 0.3 kg, else 0.7 kg).
  static int _closestRepsForWeight({
    required double targetE1rm,
    required double weight,
    required int center,
    required double rir,
    required String group,
  }) {
    final tol = group == 'D' ? 0.3 : 0.7;
    final candidates = <int>{
      (center - 1).clamp(1, 45),
      center,
      (center + 1).clamp(1, 45),
    }.toList()..sort();

    int best = center;
    double bestErr = double.infinity;
    for (final r in candidates) {
      final e   = PeriodizationModelUtils.calculateE1RM(weight, r.toDouble(), rir);
      final err = (e - targetE1rm).abs();
      final withinTolBest = bestErr <= tol + 1e-6;
      final withinTolCur  = err   <= tol + 1e-6;
      final take =
          (withinTolCur && !withinTolBest) ||
          (withinTolCur  && withinTolBest  && (err < bestErr - 1e-9 || ((err - bestErr).abs() <= 1e-9 && r < best))) ||
          (!withinTolCur && !withinTolBest && (err < bestErr - 1e-9 || ((err - bestErr).abs() <= 1e-9 && r < best)));
      if (take) {
        bestErr = err;
        best    = r;
      }
    }
    return best;
  }
}
