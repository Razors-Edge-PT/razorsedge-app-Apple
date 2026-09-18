/// Canonical periodization / progression model identifiers.
///
/// These strings are PERSISTED in `exerciseSettings[exerciseId]` and consumed
/// by the planning engine, so the identifiers (including punctuation such as
/// `DUP, Signature`) must never be altered. The WES2 settings cog and Block
/// Planner 2 both read their dropdown options from here so there is exactly
/// one option list per model family.
library;

/// How a rep model lays out its targets.
enum RepTargetShape {
  /// `repTargets.week1.instanceN = 'R x S'` — one slot per weekly session.
  perSession,

  /// `repTargets.repRange.{min,max}` plus `defaultSets` — block scoped.
  repRange,
}

/// How an RIR model lays out its targets. Every current model is per-session /
/// per-set (`rirPlan.week1.sessionN.setM.rir`); the enum exists so a future
/// model (e.g. Static RIR Exposure) can declare a different shape without the
/// UI having to special-case identifiers.
enum RirTargetShape { perSessionPerSet }

class ExerciseModelRegistry {
  ExerciseModelRegistry._();

  // ── Rep (periodization) models ─────────────────────────────────────────────
  static const String dupByExposure = 'DUP, By Exposure';
  static const String dupSignature = 'DUP, Signature';
  static const String dupByWeek = 'DUP, By Week';
  static const String linearClassic = 'Linear, Classic';
  static const String linearByExposure = 'Linear, by Exposure';

  /// Display order used by every settings dropdown.
  static const List<String> repModels = [
    dupByExposure,
    dupSignature,
    dupByWeek,
    linearClassic,
    linearByExposure,
  ];

  // ── RIR models ─────────────────────────────────────────────────────────────
  static const String linearTaper = 'Linear-Taper';
  static const String waveRirUndulation = 'Wave RIR undulation';
  static const String sessionRirUndulation = 'Session RIR Undulation';
  static const String staticRir = 'Static RIR';

  static const List<String> rirModels = [
    linearTaper,
    waveRirUndulation,
    sessionRirUndulation,
    staticRir,
  ];

  // ── Progression models ─────────────────────────────────────────────────────
  static const String linearWeightIncrease = 'Linear Weight Increase';
  static const String addReps = 'Add Reps';
  static const String smartProgression = 'Smart Progression';
  static const String progressionNone = 'None';

  static const List<String> progressionModels = [
    linearWeightIncrease,
    addReps,
    smartProgression,
    progressionNone,
  ];

  // ── Velocity ───────────────────────────────────────────────────────────────

  /// Exercises whose `showVelocityField` defaults to true when the setting is
  /// absent from `exerciseSettings` (mirrors the WES2 settings cog).
  static const Set<String> defaultVelocityExerciseIds = {
    'heeBViVINHO6tUScSd6y',
    'AJIQi4kzUVb7IfOyxfZs',
    'm6zHYgovIiYPM7NgqoeR',
    'AmfUWbF1DH3I7qPAdh5k',
    'pU7wce56hFDsam53aKDr',
    'wtrVB88vFR0EDRc7Uli0',
    'IECRZ5GJrc78DRnyuhtQ',
    'ZH6VIWHexxxlpKRYgwil',
    'WH2qpYjDeb6M0j2FtlGs',
    'MsGl7e9yanDeEnYX0e4X',
    'EQL6s4QJnXApe8DdmJbX',
    'YvwK9kwc1hcA2omz1g4r',
    'lVDG90yN6Z8aPjRNV2wc',
    '10pEctikt6PP8eAg9Eip',
    'NkctO0XmQrUHfLCkpRXr',
  };

  static bool defaultShowVelocity(String exerciseId) =>
      defaultVelocityExerciseIds.contains(exerciseId);

  // ── Shapes ─────────────────────────────────────────────────────────────────

  static RepTargetShape repTargetShape(String? repModel) =>
      repModel == dupSignature
          ? RepTargetShape.repRange
          : RepTargetShape.perSession;

  static RirTargetShape rirTargetShape(String? rirModel) =>
      RirTargetShape.perSessionPerSet;

  /// Returns [value] when it is a known identifier of [options], otherwise
  /// null so a dropdown never crashes on an unknown persisted string.
  static String? knownOrNull(String? value, List<String> options) =>
      value != null && options.contains(value) ? value : null;
}
