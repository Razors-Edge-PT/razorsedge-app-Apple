import 'WES2_models.dart';

// Stub interface. No PMU/ProgressionEngine imports in Phase 1.
// Phase 6 will provide a concrete implementation wrapping PMU and
// ProgressionEngine with BB3 planned override priority.
abstract class Wes2HintService {
  /// Recompute hints for a single exercise row.
  /// Returns a new row with hintValue populated on each Wes2FieldState.
  /// Never overwrites actualValue.
  Wes2ExerciseRow computeRowHints({
    required Wes2ExerciseRow row,
    required String blockId,
    required String uid,
    required DateTime date,
  });

  /// Recompute hints for all rows in a day session.
  List<Wes2ExerciseRow> computeAllHints({
    required List<Wes2ExerciseRow> rows,
    required String blockId,
    required String uid,
    required DateTime date,
  });
}
