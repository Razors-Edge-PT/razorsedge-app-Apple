import 'WES2_models.dart';

// Stub interface. No Isar imports in Phase 1.
// Phase 5 will provide a concrete IsarWes2LocalStore.
// All cache keys include uid + date to prevent cross-user contamination.
abstract class Wes2LocalStore {
  /// Persist a day draft snapshot keyed by uid + date.
  Future<void> saveDraft({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  });

  /// Load the most recent local draft for uid + date, or null if none.
  Future<List<Wes2ExerciseRow>?> loadDraft({
    required String uid,
    required DateTime date,
  });

  /// Save per-device expanded/collapsed state keyed by uid + date.
  Future<void> saveExpandedState({
    required String uid,
    required DateTime date,
    required Map<String, bool> expandedByExerciseId,
  });

  /// Load per-device expanded/collapsed state.
  Future<Map<String, bool>> loadExpandedState({
    required String uid,
    required DateTime date,
  });

  /// Save the last locally edited exerciseId + setIndex for scroll restore.
  Future<void> saveScrollAnchor({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
  });

  /// Load the last locally edited scroll anchor, or null if none.
  Future<({String exerciseId, int setIndex})?> loadScrollAnchor({
    required String uid,
    required DateTime date,
  });

  /// Queue a workout save for deferred offline sync.
  Future<void> enqueueOfflineSave({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    required DateTime localEditedAt,
  });

  /// Remove a queued offline save after successful Firestore sync.
  Future<void> dequeueOfflineSave({
    required String uid,
    required DateTime date,
  });
}
