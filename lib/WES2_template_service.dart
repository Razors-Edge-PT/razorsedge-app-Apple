import 'WES2_models.dart';

// Stub interface. No Firestore/template imports in Phase 1.
// Phase 8 will provide a concrete implementation.
abstract class Wes2TemplateService {
  /// Load a template's exercise rows by templateId, preserving circuit
  /// structure and orderIndex.
  Future<List<Wes2ExerciseRow>> loadTemplate({
    required String uid,
    required String templateId,
  });

  /// Save the current day's manually-built workout as a new reusable template.
  /// Called only when every exercise is completed/marked Done and the day was
  /// not originally loaded from a template.
  Future<void> saveWorkoutAsTemplate({
    required String uid,
    required String blockId,
    required String templateName,
    required List<Wes2ExerciseRow> rows,
  });
}
