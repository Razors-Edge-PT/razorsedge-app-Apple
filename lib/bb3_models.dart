import 'package:cloud_firestore/cloud_firestore.dart';

// ─── BB3Set ──────────────────────────────────────────────────────────────────
// Represents one planned set in BB3.
// Every field is nullable: null = no BB3 override for that field → model hint
// flows through in WES. Null is NEVER coerced to 0.

class BB3Set {
  final double? weight;
  final int? reps;
  final double? rir;
  final double? velocity;
  final String? notes;

  const BB3Set({
    this.weight,
    this.reps,
    this.rir,
    this.velocity,
    this.notes,
  });

  bool get isEmpty =>
      weight == null && reps == null && rir == null &&
      velocity == null && (notes == null || notes!.isEmpty);

  // Only writes non-null fields. Null fields are omitted from Firestore.
  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (weight != null) m['weight'] = weight;
    if (reps != null) m['reps'] = reps;
    if (rir != null) m['rir'] = rir;
    if (velocity != null) m['velocity'] = velocity;
    if (notes != null && notes!.isNotEmpty) m['notes'] = notes;
    return m;
  }

  static BB3Set fromMap(Map<String, dynamic>? map) {
    if (map == null) return const BB3Set();
    return BB3Set(
      weight: (map['weight'] as num?)?.toDouble(),
      reps: (map['reps'] as num?)?.toInt(),
      rir: (map['rir'] as num?)?.toDouble(),
      velocity: (map['velocity'] as num?)?.toDouble(),
      notes: map['notes'] as String?,
    );
  }

  BB3Set copyWith({
    double? weight,
    int? reps,
    double? rir,
    double? velocity,
    String? notes,
    bool clearWeight = false,
    bool clearReps = false,
    bool clearRir = false,
    bool clearVelocity = false,
    bool clearNotes = false,
  }) {
    return BB3Set(
      weight: clearWeight ? null : (weight ?? this.weight),
      reps: clearReps ? null : (reps ?? this.reps),
      rir: clearRir ? null : (rir ?? this.rir),
      velocity: clearVelocity ? null : (velocity ?? this.velocity),
      notes: clearNotes ? null : (notes ?? this.notes),
    );
  }

  @override
  String toString() =>
      'BB3Set(w=$weight, r=$reps, rir=$rir, vel=$velocity, notes=$notes)';
}

// ─── BB3Exercise ─────────────────────────────────────────────────────────────
// One exercise entry in a BB3 day plan.
// Identity per day: exerciseId (only one instance per day is allowed).
// circuitIndex is for grouping/ordering only — not part of duplicate identity.

class BB3Exercise {
  final String exerciseId;
  final String name;
  final int circuitIndex;
  final int orderIndex;
  final List<BB3Set> sets; // length = planned set count; each may be empty
  final String? perExerciseNote;

  const BB3Exercise({
    required this.exerciseId,
    required this.name,
    required this.circuitIndex,
    required this.orderIndex,
    required this.sets,
    this.perExerciseNote,
  });

  Map<String, dynamic> toMap() {
    return {
      'exerciseId': exerciseId,
      'name': name,
      'circuitIndex': circuitIndex,
      'orderIndex': orderIndex,
      'sets': sets.map((s) => s.toMap()).toList(),
      if (perExerciseNote != null && perExerciseNote!.isNotEmpty)
        'perExerciseNote': perExerciseNote,
    };
  }

  // Deserializes from Firestore map with full backward-compatibility:
  //
  // Case 1 — NEW format: 'sets' array present → read per-set.
  // Case 2 — LEGACY format: no 'sets' array, flat weight/reps/rir fields →
  //           treat as set 1 only. Sets 2+ have no overrides (empty BB3Set).
  // Case 3 — Nothing: all sets are empty BB3Set.
  //
  // Null is never coerced to 0.
  static BB3Exercise fromMap(
    Map<String, dynamic> map, {
    int fallbackSetCount = 3,
  }) {
    final exerciseId = (map['exerciseId'] ?? map['id'] ?? '').toString().trim();
    final name = (map['name'] ?? map['exercise'] ?? '').toString().trim();
    final circuitIndex = (map['circuitIndex'] as num?)?.toInt() ?? 0;
    final orderIndex = (map['orderIndex'] as num?)?.toInt() ?? 0;
    final perExerciseNote = map['perExerciseNote'] as String?;

    final rawSets = map['sets'];

    List<BB3Set> sets;

    if (rawSets is List && rawSets.isNotEmpty) {
      // ── Case 1: new per-set format ──
      sets = rawSets
          .map((s) => BB3Set.fromMap(s is Map<String, dynamic> ? s : {}))
          .toList();
    } else {
      // ── Case 2 / 3: legacy flat or empty ──
      // Legacy flat values apply to set 1 only.
      final legacyW = (map['weight'] as num?)?.toDouble();
      final legacyR = (map['reps'] as num?)?.toInt();
      final legacyRir = (map['rir'] as num?)?.toDouble();

      final set1 = BB3Set(weight: legacyW, reps: legacyR, rir: legacyRir);
      // Remaining sets have no overrides.
      sets = [
        set1,
        ...List.generate(
          (fallbackSetCount - 1).clamp(0, 99),
          (_) => const BB3Set(),
        ),
      ];
    }

    return BB3Exercise(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: circuitIndex,
      orderIndex: orderIndex,
      sets: sets,
      perExerciseNote: perExerciseNote,
    );
  }

  BB3Exercise copyWith({
    String? exerciseId,
    String? name,
    int? circuitIndex,
    int? orderIndex,
    List<BB3Set>? sets,
    String? perExerciseNote,
    bool clearNote = false,
  }) {
    return BB3Exercise(
      exerciseId: exerciseId ?? this.exerciseId,
      name: name ?? this.name,
      circuitIndex: circuitIndex ?? this.circuitIndex,
      orderIndex: orderIndex ?? this.orderIndex,
      sets: sets ?? this.sets,
      perExerciseNote:
          clearNote ? null : (perExerciseNote ?? this.perExerciseNote),
    );
  }

  // Returns a copy with the set at [setIndex] replaced.
  BB3Exercise withSetUpdated(int setIndex, BB3Set newSet) {
    if (setIndex < 0 || setIndex >= sets.length) return this;
    final updated = List<BB3Set>.from(sets);
    updated[setIndex] = newSet;
    return copyWith(sets: updated);
  }

  // Returns a copy with the sets list grown/shrunk to [count].
  BB3Exercise withSetCount(int count) {
    if (count <= 0) return this;
    final current = sets;
    if (current.length == count) return this;
    final resized = List<BB3Set>.generate(
      count,
      (i) => i < current.length ? current[i] : const BB3Set(),
    );
    return copyWith(sets: resized);
  }

  @override
  String toString() =>
      'BB3Exercise($exerciseId, ci=$circuitIndex, oi=$orderIndex, sets=${sets.length})';
}

// ─── BB3BlockSettings ─────────────────────────────────────────────────────────
// Block-level settings read from users/{uid}/planned_blocks/{blockId}.

class BB3BlockSettings {
  final String blockId;
  final String? name;
  final DateTime? startDate;
  final DateTime? endDate;
  // Full exerciseSettings map: exerciseId → config (defaultSets, repTargets,
  // rirPlan, periodizationModel, progressionModel, increments, etc.)
  final Map<String, dynamic> exerciseSettings;

  const BB3BlockSettings({
    required this.blockId,
    this.name,
    this.startDate,
    this.endDate,
    required this.exerciseSettings,
  });

  bool get hasDateRange => startDate != null && endDate != null;

  bool isDateInRange(DateTime date) {
    if (!hasDateRange) return false;
    final d = DateTime(date.year, date.month, date.day);
    final s = DateTime(startDate!.year, startDate!.month, startDate!.day);
    final e = DateTime(endDate!.year, endDate!.month, endDate!.day);
    return !d.isBefore(s) && !d.isAfter(e);
  }

  // Settings for a specific exercise, or empty map if not found.
  Map<String, dynamic> settingsFor(String exerciseId) {
    final v = exerciseSettings[exerciseId];
    if (v is Map<String, dynamic>) return v;
    return const {};
  }

  static DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is Timestamp) return raw.toDate();
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  static BB3BlockSettings fromDoc(String blockId, Map<String, dynamic> data) {
    final rawSettings = data['exerciseSettings'];
    final exerciseSettings = rawSettings is Map<String, dynamic>
        ? Map<String, dynamic>.from(rawSettings)
        : <String, dynamic>{};

    return BB3BlockSettings(
      blockId: blockId,
      name: data['name'] as String?,
      startDate: _parseDate(data['startDate']),
      endDate: _parseDate(data['endDate']),
      exerciseSettings: exerciseSettings,
    );
  }

  static const BB3BlockSettings empty = BB3BlockSettings(
    blockId: '',
    exerciseSettings: {},
  );
}
