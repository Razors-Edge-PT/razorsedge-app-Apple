import 'WES2_models.dart';

// Stub interface. No Firestore/listener imports in Phase 1.
// Phase 11 will provide a concrete implementation with field-level live
// updates and collaborator field-border indicators.
abstract class Wes2SyncService {
  /// Attach a Firestore listener for uid/date. [onUpdate] is called when
  /// another device saves user-entered values (not hint recalculations).
  void attachListener({
    required String uid,
    required DateTime date,
    required void Function(List<Wes2ExerciseRow> updatedRows) onUpdate,
  });

  /// Detach the active listener (call on page exit / date change).
  void detachListener();

  /// Report that this device is focusing a specific field for the
  /// collaborator border indicator. Writes lightweight presence metadata.
  Future<void> reportFieldFocus({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String fieldKey,
  });

  /// Clear field-focus presence on unfocus.
  Future<void> clearFieldFocus({
    required String uid,
    required DateTime date,
  });
}
