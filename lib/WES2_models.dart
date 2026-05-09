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

/// Holds both the user-entered actual value and the computed hint for a
/// single field. Identity: date + exerciseId + setIndex + fieldKey.
class Wes2FieldState<T> {
  final T? actualValue;
  final T? hintValue;
  final FieldOrigin origin;
  final bool dirty;
  final DateTime? lastEditedAt;

  const Wes2FieldState({
    this.actualValue,
    this.hintValue,
    this.origin = FieldOrigin.empty,
    this.dirty = false,
    this.lastEditedAt,
  });

  bool get hasActual => actualValue != null;
  bool get hasHint => hintValue != null;

  Wes2FieldState<T> withActual(T? value) => Wes2FieldState<T>(
        actualValue: value,
        hintValue: hintValue,
        origin: value != null
            ? FieldOrigin.typed
            : (hintValue != null ? FieldOrigin.bb3Hint : FieldOrigin.empty),
        dirty: true,
        lastEditedAt: DateTime.now(),
      );

  Wes2FieldState<T> withHint(T? value, FieldOrigin hintOrigin) =>
      Wes2FieldState<T>(
        actualValue: actualValue,
        hintValue: value,
        origin: hasActual ? origin : hintOrigin,
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

/// One set within an exercise row.
/// Identity: date + exerciseId + setIndex.
class Wes2SetState {
  final int setIndex;
  final Wes2FieldState<double> weight;
  final Wes2FieldState<int> reps;
  final Wes2FieldState<double> rir;
  final Wes2FieldState<double> velocity;
  final String? executionNote;
  final String? planNote;

  const Wes2SetState({
    required this.setIndex,
    this.weight = const Wes2FieldState<double>(),
    this.reps = const Wes2FieldState<int>(),
    this.rir = const Wes2FieldState<double>(),
    this.velocity = const Wes2FieldState<double>(),
    this.executionNote,
    this.planNote,
  });

  bool get hasAnyActual =>
      weight.hasActual || reps.hasActual || rir.hasActual || velocity.hasActual;

  Wes2SetState copyWith({
    Wes2FieldState<double>? weight,
    Wes2FieldState<int>? reps,
    Wes2FieldState<double>? rir,
    Wes2FieldState<double>? velocity,
    String? executionNote,
    String? planNote,
  }) {
    return Wes2SetState(
      setIndex: setIndex,
      weight: weight ?? this.weight,
      reps: reps ?? this.reps,
      rir: rir ?? this.rir,
      velocity: velocity ?? this.velocity,
      executionNote: executionNote ?? this.executionNote,
      planNote: planNote ?? this.planNote,
    );
  }

  Map<String, dynamic> toJson() => {
        'setIndex': setIndex,
        'weight': weight.toJson(),
        'reps': reps.toJson(),
        'rir': rir.toJson(),
        'velocity': velocity.toJson(),
        if (executionNote != null) 'executionNote': executionNote,
        if (planNote != null) 'planNote': planNote,
      };

  static Wes2SetState fromJson(Map<String, dynamic> map) => Wes2SetState(
        setIndex: map['setIndex'] as int,
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
      sets: (map['sets'] as List<dynamic>)
          .map((s) => Wes2SetState.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}
