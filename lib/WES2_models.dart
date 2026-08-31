// WES2 core data models.
// No external service dependencies — safe to import anywhere.

enum Wes2RowSource {
  bb3Planned,
  wes2Manual,
  templateLoaded,
  completedServer,
  localDraft,
}

enum FieldOrigin {
  empty,
  typed,
  completed,
  bb3Hint,
  modelHint,
  localDraft,
}

enum Wes2FieldKey { weight, reps, rir, velocity }

enum Wes2ExerciseEntryMode { normal, timedBodyweight, timedWeighted }

/// Holds both the user-entered actual value and the computed hint for a
/// single field. Identity: date + exerciseId + setIndex + fieldKey.
class Wes2FieldState<T> {
  final T? actualValue;
  final T? hintValue;
  final FieldOrigin origin;

  /// Tracks the provenance of [hintValue] independently of [origin].
  /// [origin] encodes how the actual/current display value was set;
  /// [hintOrigin] encodes where the hint came from (bb3Hint, modelHint, empty).
  /// Preserved across actual save/clear cycles so BB3 constraints are never lost.
  final FieldOrigin hintOrigin;
  final bool dirty;
  final DateTime? lastEditedAt;

  const Wes2FieldState({
    this.actualValue,
    this.hintValue,
    this.origin = FieldOrigin.empty,
    this.hintOrigin = FieldOrigin.empty,
    this.dirty = false,
    this.lastEditedAt,
  });

  bool get hasActual => actualValue != null;
  bool get hasHint => hintValue != null;

  Wes2FieldState<T> withActual(T? value) => Wes2FieldState<T>(
        actualValue: value,
        hintValue: hintValue,
        hintOrigin: hintOrigin,
        origin: value != null
            ? FieldOrigin.typed
            : (hintOrigin != FieldOrigin.empty
                ? hintOrigin
                : FieldOrigin.empty),
        dirty: true,
        lastEditedAt: DateTime.now(),
      );

  Wes2FieldState<T> withHint(T? value, FieldOrigin newHintOrigin) =>
      Wes2FieldState<T>(
        actualValue: actualValue,
        hintValue: value,
        hintOrigin: value != null ? newHintOrigin : FieldOrigin.empty,
        origin: hasActual
            ? origin
            : (value != null ? newHintOrigin : FieldOrigin.empty),
        dirty: dirty,
        lastEditedAt: lastEditedAt,
      );

  Map<String, dynamic> toJson() => {
        'actual': actualValue,
        'hint': hintValue,
      };

  static Wes2FieldState<double> doubleFromJson(Map<String, dynamic> map) =>
      Wes2FieldState<double>(
        actualValue: (map['actual'] as num?)?.toDouble(),
        hintValue: (map['hint'] as num?)?.toDouble(),
      );

  static Wes2FieldState<int> intFromJson(Map<String, dynamic> map) =>
      Wes2FieldState<int>(
        actualValue: (map['actual'] as num?)?.toInt(),
        hintValue: (map['hint'] as num?)?.toInt(),
      );
}

/// Reads a set's stable identity out of a decoded set map.
///
/// Precedence mirrors BOTH showcase reducers exactly
/// (`lib/profile/core/showcase_reducer.dart` and `functions/showcase/reducer.js`,
/// which each read `s.id ?? s.setId`). A document that already carries `id`
/// therefore keeps `id` as its identity, and no competing `setId` is ever
/// written for it — the reducers would ignore it, and disagreeing with them is
/// how a proof video ends up pointing at the wrong performance.
///
/// Returns null for a missing, non-string, or blank value.
String? readStableSetId(Map<String, dynamic> map) {
  for (final String key in const <String>['id', 'setId']) {
    final Object? raw = map[key];
    if (raw is String) {
      final String t = raw.trim();
      if (t.isNotEmpty) return t;
    }
  }
  return null;
}

/// One set within an exercise row.
/// Identity: date + exerciseId + setIndex.
class Wes2SetState {
  final int setIndex;

  /// Stable, collision-resistant identity for this set, independent of
  /// [setIndex]. Null for every set written before this field existed, and for
  /// placeholder sets, so it is ALWAYS optional.
  ///
  /// Why it is not generated in this constructor: `Wes2SetState(setIndex: i)`
  /// is used as padding by the hint and plan services on ordinary rebuilds. A
  /// constructor-generated id would mint a NEW identity every rebuild, which is
  /// the opposite of stable. Identity is therefore assigned only at deliberate
  /// creation points (a user adding a set) or lazily, immediately before a
  /// recording is attached to a historical set.
  ///
  /// The showcase reducers already prefer `s.id ?? s.setId` over the positional
  /// `s<n>` fallback on BOTH platforms, so emitting this is additive and needs
  /// no server change. It is also why it must never be back-filled in bulk: a
  /// set that GAINS an id changes its setKey, and therefore its record
  /// fingerprint, which would detach any proof video already attached to it.
  final String? setId;
  final Wes2FieldState<double> weight;
  final Wes2FieldState<int> reps;
  final Wes2FieldState<double> rir;
  final Wes2FieldState<double> velocity;
  final String? executionNote;
  final String? planNote;

  /// Display-only cue flags: true when a BB3 explicit override hint is locked
  /// and the free model calculation would have placed the field at a meaningfully
  /// different value. Never persisted to Firestore. Always false until the hint
  /// service computes them; reset to false if actualValue is present.
  final bool weightLockedByBb3OverrideCue;
  final bool repsLockedByBb3OverrideCue;
  final bool rirLockedByBb3OverrideCue;

  const Wes2SetState({
    required this.setIndex,
    this.setId,
    this.weight = const Wes2FieldState<double>(),
    this.reps = const Wes2FieldState<int>(),
    this.rir = const Wes2FieldState<double>(),
    this.velocity = const Wes2FieldState<double>(),
    this.executionNote,
    this.planNote,
    this.weightLockedByBb3OverrideCue = false,
    this.repsLockedByBb3OverrideCue = false,
    this.rirLockedByBb3OverrideCue = false,
  });

  bool get hasAnyActual =>
      weight.hasActual || reps.hasActual || rir.hasActual || velocity.hasActual;

  Wes2SetState copyWith({
    String? setId,
    Wes2FieldState<double>? weight,
    Wes2FieldState<int>? reps,
    Wes2FieldState<double>? rir,
    Wes2FieldState<double>? velocity,
    String? executionNote,
    String? planNote,
    bool? weightLockedByBb3OverrideCue,
    bool? repsLockedByBb3OverrideCue,
    bool? rirLockedByBb3OverrideCue,
  }) {
    return Wes2SetState(
      setIndex: setIndex,
      setId: setId ?? this.setId,
      weight: weight ?? this.weight,
      reps: reps ?? this.reps,
      rir: rir ?? this.rir,
      velocity: velocity ?? this.velocity,
      executionNote: executionNote ?? this.executionNote,
      planNote: planNote ?? this.planNote,
      weightLockedByBb3OverrideCue:
          weightLockedByBb3OverrideCue ?? this.weightLockedByBb3OverrideCue,
      repsLockedByBb3OverrideCue:
          repsLockedByBb3OverrideCue ?? this.repsLockedByBb3OverrideCue,
      rirLockedByBb3OverrideCue:
          rirLockedByBb3OverrideCue ?? this.rirLockedByBb3OverrideCue,
    );
  }

  Map<String, dynamic> toJson() => {
        'setIndex': setIndex,
        // Emitted only when present, so a set that never carried an id keeps
        // producing byte-identical JSON and no existing draft or workout
        // document changes shape.
        if (setId != null) 'setId': setId,
        'weight': weight.toJson(),
        'reps': reps.toJson(),
        'rir': rir.toJson(),
        'velocity': velocity.toJson(),
        if (executionNote != null) 'executionNote': executionNote,
        if (planNote != null) 'planNote': planNote,
      };

  static Wes2SetState fromJson(Map<String, dynamic> map) => Wes2SetState(
        setIndex: map['setIndex'] as int,
        setId: readStableSetId(map),
        weight: Wes2FieldState.doubleFromJson(
          map['weight'] as Map<String, dynamic>,
        ),
        reps: Wes2FieldState.intFromJson(
          map['reps'] as Map<String, dynamic>,
        ),
        rir: Wes2FieldState.doubleFromJson(
          map['rir'] as Map<String, dynamic>,
        ),
        velocity: Wes2FieldState.doubleFromJson(
          map['velocity'] as Map<String, dynamic>,
        ),
        executionNote: map['executionNote'] as String?,
        planNote: map['planNote'] as String?,
      );
}

/// One exercise row for a given day.
/// Identity: date + exerciseId (never keyed by row/list index).
class Wes2ExerciseRow {
  final String exerciseId;
  final String name;
  final int circuitIndex;
  final int orderIndex; // global day order, not local-within-circuit
  final int setCount;
  final List<Wes2SetState> sets;
  final Wes2RowSource source;
  final bool isMarkedDone;
  final bool isExpanded;

  /// BB3 exercise-level plan note. Display-only; never written to WES2 execution data.
  final String? exercisePlanNote;

  /// WES2 exercise-level execution note. Stored in exercises[].exerciseExecutionNote.
  /// Never overwrites exercisePlanNote or BB3 perExerciseNote.
  final String? exerciseExecutionNote;

  const Wes2ExerciseRow({
    required this.exerciseId,
    required this.name,
    required this.circuitIndex,
    required this.orderIndex,
    required this.setCount,
    this.sets = const [],
    required this.source,
    this.isMarkedDone = false,
    this.isExpanded = true,
    this.exercisePlanNote,
    this.exerciseExecutionNote,
  });

  /// BB3 completion rule: at least one set has weight AND reps.
  bool get isBb3Completed =>
      sets.any((s) => s.weight.hasActual && s.reps.hasActual);

  /// WES2 "Completed?" pill eligibility: weight + reps + RIR in at least one set.
  bool get isCompletedPillEligible => sets
      .any((s) => s.weight.hasActual && s.reps.hasActual && s.rir.hasActual);

  /// True if any set carries a user-entered value (exercises[] rather than
  /// wesPlannedExercises[]).
  bool get hasAnyExecutionValue => sets.any((s) => s.hasAnyActual);

  Wes2ExerciseRow copyWith({
    String? exerciseId,
    String? name,
    int? circuitIndex,
    int? orderIndex,
    int? setCount,
    List<Wes2SetState>? sets,
    Wes2RowSource? source,
    bool? isMarkedDone,
    bool? isExpanded,
    String? exercisePlanNote,
    String? exerciseExecutionNote,
    bool clearExerciseExecutionNote = false,
  }) {
    return Wes2ExerciseRow(
      exerciseId: exerciseId ?? this.exerciseId,
      name: name ?? this.name,
      circuitIndex: circuitIndex ?? this.circuitIndex,
      orderIndex: orderIndex ?? this.orderIndex,
      setCount: setCount ?? this.setCount,
      sets: sets ?? this.sets,
      source: source ?? this.source,
      isMarkedDone: isMarkedDone ?? this.isMarkedDone,
      isExpanded: isExpanded ?? this.isExpanded,
      exercisePlanNote: exercisePlanNote ?? this.exercisePlanNote,
      exerciseExecutionNote: clearExerciseExecutionNote
          ? null
          : (exerciseExecutionNote ?? this.exerciseExecutionNote),
    );
  }

  Map<String, dynamic> toJson() => {
        'exerciseId': exerciseId,
        'name': name,
        'circuitIndex': circuitIndex,
        'orderIndex': orderIndex,
        'setCount': setCount,
        'source': source.name,
        'isMarkedDone': isMarkedDone,
        'sets': sets.map((s) => s.toJson()).toList(),
        if (exercisePlanNote != null) 'exercisePlanNote': exercisePlanNote,
        if (exerciseExecutionNote != null)
          'exerciseExecutionNote': exerciseExecutionNote,
      };

  static Wes2ExerciseRow fromJson(Map<String, dynamic> map) {
    final sourceStr = map['source'] as String? ?? 'localDraft';
    final src = Wes2RowSource.values.firstWhere(
      (e) => e.name == sourceStr,
      orElse: () => Wes2RowSource.localDraft,
    );
    return Wes2ExerciseRow(
      exerciseId: map['exerciseId'] as String,
      name: map['name'] as String,
      circuitIndex: map['circuitIndex'] as int,
      orderIndex: map['orderIndex'] as int,
      setCount: map['setCount'] as int,
      source: src,
      isMarkedDone: map['isMarkedDone'] as bool? ?? false,
      exercisePlanNote: map['exercisePlanNote'] as String?,
      exerciseExecutionNote: map['exerciseExecutionNote'] as String?,
      sets: (map['sets'] as List<dynamic>)
          .map((s) => Wes2SetState.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}

// ── Workout user-data predicate ───────────────────────────────────────────────

/// Returns true when [rows] contain any value deliberately entered or edited
/// by the user. Specifically checks:
///   • any set's actualValue for weight, reps, RIR, or velocity
///   • any per-set execution note (non-empty after trim)
///   • any exercise-level execution note (non-empty after trim)
///   • any exercise marked as done by the user
///
/// Returns false for rows that carry only hint values (model-generated or
/// BB3-prescribed), plan notes from BB3, template-prescribed planned values
/// that have not been edited, or default/placeholder state.
bool workoutHasUserEnteredData(List<Wes2ExerciseRow> rows) {
  for (final row in rows) {
    if (row.isMarkedDone) return true;
    if (row.exerciseExecutionNote?.trim().isNotEmpty == true) return true;
    for (final s in row.sets) {
      if (s.weight.hasActual) return true;
      if (s.reps.hasActual) return true;
      if (s.rir.hasActual) return true;
      if (s.velocity.hasActual) return true;
      if (s.executionNote?.trim().isNotEmpty == true) return true;
    }
  }
  return false;
}
