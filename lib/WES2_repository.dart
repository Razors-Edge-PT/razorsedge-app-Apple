import 'package:cloud_firestore/cloud_firestore.dart';
import 'WES2_models.dart';

// Abstract interface — Phase 3 adds FirestoreWes2Repository below.
abstract class Wes2Repository {
  /// Load completed exercises[] + wesPlannedExercises[] for uid/date.
  Future<List<Wes2ExerciseRow>> loadDay({
    required String uid,
    required DateTime date,
  });

  /// Persist exercises[] (rows that have any execution value).
  Future<void> saveCompletedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> completedRows,
  });

  /// Persist wesPlannedExercises[] (blank WES2-added rows with no values).
  Future<void> savePlannedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> plannedRows,
  });

  /// Granular field-level save on unfocus. Uses merge/transaction strategy
  /// so one device field edit does not wipe another device's unrelated field.
  Future<void> saveFieldPatch({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String fieldKey,
    required dynamic value,
  });

  /// Write isMarkedDone onto the exercises[] row.
  Future<void> setMarkedDone({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required bool isDone,
  });
}

/// Concrete Firestore implementation.
/// Phase 3: loadDay only. Write methods throw UnimplementedError until Phase 5.
class FirestoreWes2Repository implements Wes2Repository {
  @override
  Future<List<Wes2ExerciseRow>> loadDay({
    required String uid,
    required DateTime date,
  }) async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(_dateDocId(date))
        .get();

    if (!snap.exists) return const [];
    final data = snap.data();
    if (data == null) return const [];

    final exercises =
        (data['exercises'] as List<dynamic>?) ?? const [];
    final wesPlanned =
        (data['wesPlannedExercises'] as List<dynamic>?) ?? const [];

    // exercises[] is processed first: completedServer rows win deduplication.
    final Map<String, Wes2ExerciseRow> seen = {};

    for (int i = 0; i < exercises.length; i++) {
      final row = _parseRow(exercises[i], Wes2RowSource.completedServer, i);
      if (row == null) continue;
      seen.putIfAbsent(row.exerciseId, () => row);
    }

    // wesPlannedExercises[]: only inserted if exerciseId not already present.
    for (int i = 0; i < wesPlanned.length; i++) {
      final row = _parseRow(
        wesPlanned[i],
        Wes2RowSource.wes2Manual,
        exercises.length + i, // fallback order starts after all exercises[]
      );
      if (row == null) continue;
      seen.putIfAbsent(row.exerciseId, () => row);
    }

    return seen.values.toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  // ── Parse helpers ─────────────────────────────────────────────────────────

  static Wes2ExerciseRow? _parseRow(
    dynamic raw,
    Wes2RowSource source,
    int fallbackOrder,
  ) {
    if (raw is! Map<String, dynamic>) return null;

    final exerciseId = (raw['exerciseId'] as String?) ?? '';
    if (exerciseId.isEmpty) return null;

    final rawName = raw['name'] as String?;
    final name =
        (rawName != null && rawName.isNotEmpty) ? rawName : exerciseId;

    final circuitIndex = (raw['circuitIndex'] as num?)?.toInt() ?? 0;
    final orderIndex =
        (raw['orderIndex'] as num?)?.toInt() ?? fallbackOrder;
    final storedSetCount = (raw['setCount'] as num?)?.toInt() ?? 0;
    final isMarkedDone = (raw['isMarkedDone'] as bool?) ?? false;

    final rawSets = (raw['sets'] as List<dynamic>?) ?? const [];
    // setCount = max(stored, actual sets length) so we never lose data.
    final setCount =
        storedSetCount > rawSets.length ? storedSetCount : rawSets.length;

    return Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: circuitIndex,
      orderIndex: orderIndex,
      setCount: setCount,
      sets: _parseSets(rawSets, setCount),
      source: source,
      isMarkedDone: isMarkedDone,
    );
  }

  static List<Wes2SetState> _parseSets(List<dynamic> rawSets, int count) {
    return List.generate(count, (i) {
      if (i >= rawSets.length || rawSets[i] is! Map<String, dynamic>) {
        return Wes2SetState(setIndex: i);
      }
      final s = rawSets[i] as Map<String, dynamic>;
      return Wes2SetState(
        setIndex: i,
        weight: _parseDouble(s['weight']),
        reps: _parseInt(s['reps']),
        rir: _parseDouble(s['rir']),
        velocity: _parseDouble(s['velocity']),
      );
    });
  }

  static Wes2FieldState<double> _parseDouble(dynamic v) {
    if (v is! num) return const Wes2FieldState<double>();
    return Wes2FieldState<double>(
      actualValue: v.toDouble(),
      origin: FieldOrigin.completed,
    );
  }

  static Wes2FieldState<int> _parseInt(dynamic v) {
    if (v is! num) return const Wes2FieldState<int>();
    return Wes2FieldState<int>(
      actualValue: v.toInt(),
      origin: FieldOrigin.completed,
    );
  }

  static String _dateDocId(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // ── Write stubs (Phase 5+) ────────────────────────────────────────────────

  @override
  Future<void> saveCompletedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> completedRows,
  }) =>
      throw UnimplementedError('saveCompletedRows not implemented until Phase 5');

  @override
  Future<void> savePlannedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> plannedRows,
  }) =>
      throw UnimplementedError('savePlannedRows not implemented until Phase 5');

  @override
  Future<void> saveFieldPatch({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String fieldKey,
    required dynamic value,
  }) =>
      throw UnimplementedError('saveFieldPatch not implemented until Phase 5');

  @override
  Future<void> setMarkedDone({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required bool isDone,
  }) =>
      throw UnimplementedError('setMarkedDone not implemented until Phase 5');
}
