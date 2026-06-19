/// Explicit dirty-field patch produced by the WES2 settings cog.
///
/// The dialog NEVER submits a reconstructed full `rirPlan`, `repTargets`, or
/// exercise-settings object. It submits only the leaves the user actually
/// changed, so the save service can deep-merge them onto the latest canonical
/// `exerciseSettings[exerciseId]` without ever replacing a complete nested map
/// with a partial one.
library;

/// A single changed rep-target leaf.
///
/// For instance-based models [key] is e.g. `instance1`.
/// For DUP Signature [key] is `min` or `max` (written into `repRange`).
/// [value] == null or empty means the user cleared the field.
class RepTargetChange {
  final String key;
  final String? value;
  const RepTargetChange(this.key, this.value);
}

/// A single changed RIR leaf at `rirPlan.<week>.<session>.<set>.rir`.
/// [rir] == null means the user deliberately cleared the field — only the
/// `rir` leaf is removed, sibling keys (e.g. `reps`) are preserved.
class RirChange {
  final String session; // e.g. 'session2'
  final String set; // e.g. 'set1'
  final String? rir; // null = clear leaf
  const RirChange({required this.session, required this.set, required this.rir});
}

class ExerciseSettingsPatch {
  /// Changed exercise-level scalars (periodizationModel, rirModel,
  /// progressionModel, weeklyFrequency, defaultSets, showVelocityField).
  final Map<String, dynamic> scalarChanges;

  /// Scalars the user explicitly emptied (removed from the object).
  final Set<String> clearedScalars;

  /// Changed increment sub-keys only (e.g. {'primary': 2.5}). Merged onto the
  /// existing `increments` map; absent sub-keys are preserved.
  final Map<String, dynamic> incrementChanges;

  final List<RepTargetChange> repTargetChanges;
  final List<RirChange> rirChanges;

  /// Total number of weeks in the block — needed for per-week propagation.
  final int totalBlockWeeks;

  const ExerciseSettingsPatch({
    this.scalarChanges = const {},
    this.clearedScalars = const {},
    this.incrementChanges = const {},
    this.repTargetChanges = const [],
    this.rirChanges = const [],
    required this.totalBlockWeeks,
  });

  bool get isEmpty =>
      scalarChanges.isEmpty &&
      clearedScalars.isEmpty &&
      incrementChanges.isEmpty &&
      repTargetChanges.isEmpty &&
      rirChanges.isEmpty;
}
