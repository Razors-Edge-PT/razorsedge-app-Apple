import 'WES2_models.dart';

// Stub interface. No Firestore imports in Phase 1.
// Phase 2 will provide a concrete FirestoreWes2Repository implementation.
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
