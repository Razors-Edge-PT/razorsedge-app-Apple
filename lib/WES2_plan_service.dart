import 'package:cloud_firestore/cloud_firestore.dart';
import 'WES2_models.dart';

// Abstract interface — unchanged from Phase 1.
abstract class Wes2PlanService {
  /// Load BB3 planned day rows from:
  ///   /planned_blocks/{uid}/blocks/{blockId}/weeks/week_{weekIndex}/days/day_{dayIndex}
  Future<List<Wes2ExerciseRow>> loadPlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  });

  /// Load the block-level exerciseSettings map from:
  ///   /planned_blocks/{uid}/blocks/{blockId}.exerciseSettings
  Future<Map<String, dynamic>> loadExerciseSettings({
    required String uid,
    required String blockId,
  });

  /// Write back to the BB3 planned day after a structural WES2 change
  /// (delete / replace / reorder of a BB3-sourced exercise).
  Future<void> updatePlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required List<Wes2ExerciseRow> updatedRows,
  });

  /// Save exerciseSettings for one exercise. Requires internet; must not be
  /// queued offline.
  Future<void> saveExerciseSettings({
    required String uid,
    required String blockId,
    required String exerciseId,
    required Map<String, dynamic> settings,
  });
}

/// Concrete Firestore implementation.
/// Phase 4: loadPlannedDay only — reads planned day directly from Firestore.
/// Does not import or reuse BB3PlannedExerciseService or bb3_models.dart.
/// Other methods throw UnimplementedError until later phases.
class FirestoreWes2PlanService implements Wes2PlanService {
  @override
  Future<List<Wes2ExerciseRow>> loadPlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  }) async {
    final snap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId)
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex')
        .get();

    if (!snap.exists) return const [];
    final data = snap.data();
    if (data == null) return const [];

    final exercises = (data['exercises'] as List<dynamic>?) ?? const [];
    final result = <Wes2ExerciseRow>[];

    for (int i = 0; i < exercises.length; i++) {
      final row = _parseRow(exercises[i], i);
      if (row != null) result.add(row);
    }

    result.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return result;
  }

  // ── Parse helpers ─────────────────────────────────────────────────────────

  static Wes2ExerciseRow? _parseRow(dynamic raw, int fallbackOrder) {
    if (raw is! Map<String, dynamic>) return null;

    final exerciseId =
        ((raw['exerciseId'] ?? raw['id']) as String? ?? '').trim();
    if (exerciseId.isEmpty) return null;

    final rawName =
        ((raw['name'] ?? raw['exercise']) as String? ?? '').trim();
    final name = rawName.isNotEmpty ? rawName : exerciseId;

    final circuitIndex = (raw['circuitIndex'] as num?)?.toInt() ?? 0;
    final orderIndex = (raw['orderIndex'] as num?)?.toInt() ?? fallbackOrder;

    final rawSets = raw['sets'];
    final List<Wes2SetState> sets;

    if (rawSets is List && rawSets.isNotEmpty) {
      // New per-set format: each element may carry per-set planned overrides.
      sets = List.generate(rawSets.length, (i) {
        final s = rawSets[i] is Map<String, dynamic>
            ? rawSets[i] as Map<String, dynamic>
            : const <String, dynamic>{};
        return _parsePerSetHints(s, i);
      });
    } else {
      // Legacy flat format: weight/reps/rir are on the exercise map itself.
      // Values apply to set 1 only; sets 2 and 3 have no overrides.
      sets = [
        _parseLegacySetHints(raw, 0),
        Wes2SetState(setIndex: 1),
        Wes2SetState(setIndex: 2),
      ];
    }

    return Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: circuitIndex,
      orderIndex: orderIndex,
      setCount: sets.length,
      sets: sets,
      source: Wes2RowSource.bb3Planned,
    );
  }

  static Wes2SetState _parsePerSetHints(Map<String, dynamic> s, int i) {
    return Wes2SetState(
      setIndex: i,
      weight: _toDoubleHint(s['weight']),
      reps: _toIntHint(s['reps']),
      rir: _toDoubleHint(s['rir']),
      velocity: _toDoubleHint(s['velocity']),
    );
  }

  static Wes2SetState _parseLegacySetHints(Map<String, dynamic> raw, int i) {
    return Wes2SetState(
      setIndex: i,
      weight: _toDoubleHint(raw['weight']),
      reps: _toIntHint(raw['reps']),
      rir: _toDoubleHint(raw['rir']),
    );
  }

  /// BB3 planned values go into hintValue only — actualValue is never set.
  static Wes2FieldState<double> _toDoubleHint(dynamic v) {
    if (v is! num) return const Wes2FieldState<double>();
    return Wes2FieldState<double>(
      hintValue: v.toDouble(),
      origin: FieldOrigin.bb3Hint,
    );
  }

  static Wes2FieldState<int> _toIntHint(dynamic v) {
    if (v is! num) return const Wes2FieldState<int>();
    return Wes2FieldState<int>(
      hintValue: v.toInt(),
      origin: FieldOrigin.bb3Hint,
    );
  }

  // ── Write stubs (Phase 7+) ────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> loadExerciseSettings({
    required String uid,
    required String blockId,
  }) =>
      throw UnimplementedError('loadExerciseSettings not implemented until Phase 9');

  @override
  Future<void> updatePlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required List<Wes2ExerciseRow> updatedRows,
  }) =>
      throw UnimplementedError('updatePlannedDay not implemented until Phase 7');

  @override
  Future<void> saveExerciseSettings({
    required String uid,
    required String blockId,
    required String exerciseId,
    required Map<String, dynamic> settings,
  }) =>
      throw UnimplementedError('saveExerciseSettings not implemented until Phase 9');
}
