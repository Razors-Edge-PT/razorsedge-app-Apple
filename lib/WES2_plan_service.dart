import 'WES2_models.dart';

// Stub interface. No Firestore/BB3 imports in Phase 1.
// Phase 3 will provide a concrete implementation reading from the BB3
// planned day path and block-level exerciseSettings.
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
