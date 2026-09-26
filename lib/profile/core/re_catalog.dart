/// The RE Points exercise catalogue: the five profile CATEGORIES, the approved
/// exercises inside each, their weighting factors, and the ONLY rules by which
/// a logged exercise row may claim one of them.
///
/// Pinned mirror of `functions/showcase/re_catalog.js`, which is what the
/// server projection (profileShowcaseV2) actually runs. Both suites assert
/// `functions/test/fixtures/re_catalog_parity.json`, so ids, category
/// membership, display names, bodyweight flags and factors cannot drift.
///
/// Matching follows [matchBigFive] exactly: a present catalogue id — compared
/// case-folded — always decides, even when it resolves to nothing; only a row
/// with NO id may use the closed, exact legacy alias list.
///
/// Every exercise has a stable [ReExercise.slot]: the key its showcase records
/// and proof fingerprints use. The five V1 Big Five lifts keep their V1 slot
/// keys, so their proofs keep standing. Persisted — never rename.
///
/// Stored loads are never doubled or rescaled ([ReLoadSemantics]); the factor
/// already accounts for a dumbbell being one of a pair.
library;

import 'big_five.dart';

/// What a stored set weight means for an exercise.
class ReLoadSemantics {
  /// The whole implement (barbell, machine stack).
  static const String total = 'total';

  /// ONE dumbbell.
  static const String perDumbbell = 'perDumbbell';

  /// Bodyweight-loaded: see bodyweight_load.dart.
  static const String bodyweightPlusAdded = 'bodyweightPlusAdded';
}

/// Semantic category keys, persisted in profileShowcaseV2.
class ReCategoryKey {
  static const String horizontalPress = 'horizontalPress';
  static const String verticalPull = 'verticalPull';
  static const String overheadPress = 'overheadPress';
  static const String hipHinge = 'hipHinge';
  static const String squatPattern = 'squatPattern';
}

/// One profile category.
class ReCategory {
  const ReCategory({required this.key, required this.displayName});

  final String key;
  final String displayName;
}

/// One approved exercise.
class ReExercise {
  const ReExercise({
    required this.slot,
    required this.category,
    required this.exerciseId,
    required this.displayName,
    required this.legacyNameAliases,
    required this.factor,
    this.bodyweightLoaded = false,
    this.loadSemantics = ReLoadSemantics.total,
  });

  /// Stable record/fingerprint key.
  final String slot;

  /// [ReCategoryKey] of the category it belongs to.
  final String category;

  /// Catalogue document id, in its canonical casing.
  final String exerciseId;

  /// Complete, unambiguous name shown on the profile.
  final String displayName;

  /// Exact names accepted for id-less legacy rows only.
  final List<String> legacyNameAliases;

  /// RE Points weighting factor.
  final double factor;

  /// True when the stored load includes the athlete's bodyweight.
  final bool bodyweightLoaded;

  /// [ReLoadSemantics] of the stored set weight.
  final String loadSemantics;

  String get foldedId => exerciseId.toLowerCase();
}

/// Categories in display order.
const List<ReCategory> kReCategories = <ReCategory>[
  ReCategory(
      key: ReCategoryKey.horizontalPress, displayName: 'Horizontal Press'),
  ReCategory(key: ReCategoryKey.verticalPull, displayName: 'Vertical Pull'),
  ReCategory(
      key: ReCategoryKey.overheadPress, displayName: 'Overhead Press / Dip'),
  ReCategory(key: ReCategoryKey.hipHinge, displayName: 'Hip Hinge'),
  ReCategory(key: ReCategoryKey.squatPattern, displayName: 'Squat Pattern'),
];

/// Every approved exercise. Within a category the order is the preference /
/// tie-break order, and the first entry is the category's primary exercise.
const List<ReExercise> kReExercises = <ReExercise>[
  // ── Horizontal Press ──
  ReExercise(
    slot: 'bench',
    category: ReCategoryKey.horizontalPress,
    exerciseId: 'AmfUWbF1DH3I7qPAdh5k',
    displayName: 'Bench Press, Barbell',
    legacyNameAliases: <String>['Bench Press, Barbell', 'Bench Press'],
    factor: 1.0,
  ),
  ReExercise(
    slot: 'dbBenchFlat',
    category: ReCategoryKey.horizontalPress,
    exerciseId: 'kTs5fLSTKjUkUZL10iii',
    displayName: 'Flat Bench Dumbbell Press',
    legacyNameAliases: <String>['Flat Bench Dumbbell Press'],
    factor: 2.11,
    loadSemantics: ReLoadSemantics.perDumbbell,
  ),
  // ── Vertical Pull ──
  ReExercise(
    slot: 'chinUp',
    category: ReCategoryKey.verticalPull,
    exerciseId: 'XM9026peNIu0R8qh7UqY',
    displayName: 'Chin-Up',
    // "Pull-Up" is a DIFFERENT catalogue exercise and is deliberately absent.
    legacyNameAliases: <String>['Chin-Up', 'Chin Up'],
    factor: 1.0,
    bodyweightLoaded: true,
    loadSemantics: ReLoadSemantics.bodyweightPlusAdded,
  ),
  ReExercise(
    slot: 'latPulldownSupinated',
    category: ReCategoryKey.verticalPull,
    exerciseId: '1XOIXxeLFhgmgjZS9Cyq',
    displayName: 'Lat Pull Down, Supinated',
    legacyNameAliases: <String>['Lat Pull Down, Supinated'],
    factor: 0.85,
  ),
  // ── Overhead Press / Dip ──
  ReExercise(
    slot: 'ohpUnilateral',
    category: ReCategoryKey.overheadPress,
    exerciseId: 'RdsGazgdH0xgpjek0n3u',
    displayName: 'Overhead Dumbbell Press, Unilateral',
    // Bare "Overhead Dumbbell Press" is the BILATERAL exercise.
    legacyNameAliases: <String>['Overhead Dumbbell Press, Unilateral'],
    factor: 2.61,
    loadSemantics: ReLoadSemantics.perDumbbell,
  ),
  ReExercise(
    slot: 'ohpBarbell',
    category: ReCategoryKey.overheadPress,
    exerciseId: 'lVDG90yN6Z8aPjRNV2wc',
    displayName: 'Overhead Barbell Press',
    legacyNameAliases: <String>['Overhead Barbell Press'],
    factor: 1.53,
  ),
  ReExercise(
    slot: 'tricepsDip',
    category: ReCategoryKey.overheadPress,
    exerciseId: 'FtayDmR5BVnGS1FXlXLL',
    displayName: 'Triceps Dip',
    // "Triceps Dip Machine" is a different exercise and is deliberately absent.
    legacyNameAliases: <String>['Triceps Dip'],
    factor: 0.63,
    bodyweightLoaded: true,
    loadSemantics: ReLoadSemantics.bodyweightPlusAdded,
  ),
  // ── Hip Hinge ──
  ReExercise(
    slot: 'deadlift',
    category: ReCategoryKey.hipHinge,
    exerciseId: 'MsGl7e9yanDeEnYX0e4X',
    displayName: 'Deadlift, Conventional',
    legacyNameAliases: <String>['Deadlift, Conventional', 'Deadlift'],
    factor: 0.74,
  ),
  ReExercise(
    slot: 'deadliftSumo',
    category: ReCategoryKey.hipHinge,
    exerciseId: '10pEctikt6PP8eAg9Eip',
    // Catalogue name "Sumo Deadlift"; the profile shows the unambiguous form.
    displayName: 'Deadlift, Sumo',
    legacyNameAliases: <String>['Sumo Deadlift', 'Deadlift, Sumo'],
    factor: 0.74,
  ),
  ReExercise(
    slot: 'hipThrustBarbell',
    category: ReCategoryKey.hipHinge,
    exerciseId: 'LGhFj8o0sG3X12296UAh',
    displayName: 'Hip Thrust, Barbell',
    legacyNameAliases: <String>['Hip Thrust, Barbell'],
    factor: 0.55,
  ),
  // ── Squat Pattern ──
  ReExercise(
    slot: 'squat',
    category: ReCategoryKey.squatPattern,
    exerciseId: 'heeBViVINHO6tUScSd6y',
    displayName: 'Back Squat, Barbell',
    legacyNameAliases: <String>['Back Squat, Barbell', 'Back Squat'],
    factor: 0.8,
  ),
  ReExercise(
    slot: 'bulgarianSplitSquatDumbbell',
    category: ReCategoryKey.squatPattern,
    exerciseId: 'ISXQqOEXLjMrPEs0xjgJ',
    // Catalogue name "Bulgarian Split Squat".
    displayName: 'Bulgarian Split Squat, Dumbbell',
    legacyNameAliases: <String>['Bulgarian Split Squat'],
    factor: 2.5,
    loadSemantics: ReLoadSemantics.perDumbbell,
  ),
  ReExercise(
    slot: 'bulgarianSplitSquatBarbell',
    category: ReCategoryKey.squatPattern,
    exerciseId: 'VUEvvjuo4cxBghNuux66',
    displayName: 'Bulgarian Split Squat, Barbell',
    legacyNameAliases: <String>['Bulgarian Split Squat, Barbell'],
    factor: 1.25,
  ),
];

final Map<String, ReExercise> _bySlot = <String, ReExercise>{
  for (final ReExercise e in kReExercises) e.slot: e,
};

final Map<String, ReExercise> _byFoldedId = <String, ReExercise>{
  for (final ReExercise e in kReExercises) e.foldedId: e,
};

final Map<String, ReExercise> _byFoldedAlias = <String, ReExercise>{
  for (final ReExercise e in kReExercises)
    for (final String a in e.legacyNameAliases) a.trim().toLowerCase(): e,
};

final Map<String, ReCategory> _categoryByKey = <String, ReCategory>{
  for (final ReCategory c in kReCategories) c.key: c,
};

/// The exercise for a stable slot key, or null.
ReExercise? reExerciseBySlot(String slot) => _bySlot[slot];

/// The exercise for a catalogue id (any casing), or null.
ReExercise? reExerciseById(Object? rawId) {
  final String? folded = foldExerciseId(rawId);
  return folded == null ? null : _byFoldedId[folded];
}

/// The category for a key, or null.
ReCategory? reCategoryByKey(String key) => _categoryByKey[key];

/// A category's exercises, in preference order.
List<ReExercise> reExercisesOfCategory(String categoryKey) => kReExercises
    .where((ReExercise e) => e.category == categoryKey)
    .toList(growable: false);

/// True for a slot whose stored loads include the athlete's bodyweight.
bool isReBodyweightLoadedSlot(String slot) =>
    _bySlot[slot]?.bodyweightLoaded ?? false;

/// Resolves a logged exercise row to an RE exercise, or null. A present id
/// always decides; only an id-less row may use the alias list.
ReExercise? matchReExercise({Object? rawId, Object? rawName}) {
  final String? folded = foldExerciseId(rawId);
  if (folded != null) return _byFoldedId[folded];
  if (rawName is! String) return null;
  return _byFoldedAlias[rawName.trim().toLowerCase()];
}

/// The exercise a category shows by default — identical rules to the server's
/// `selectDefaultExerciseId` (functions/showcase/reducer_v2.js):
///
///  1. the highest valid RE Points among exercises with a record;
///  2. an equal score never displaces an earlier exercise (catalogue order);
///  3. with no valid points, the first exercise (catalogue order) that has a
///     record;
///  4. otherwise the category's primary exercise.
///
/// [hasRecord] and [pointsOf] describe each exercise by id; points are null
/// when unavailable.
String? selectDefaultExerciseId(
  String categoryKey, {
  required bool Function(String exerciseId) hasRecord,
  required double? Function(String exerciseId) pointsOf,
}) {
  final List<ReExercise> defs = reExercisesOfCategory(categoryKey);
  if (defs.isEmpty) return null;
  ReExercise? best;
  double? bestPoints;
  for (final ReExercise def in defs) {
    if (!hasRecord(def.exerciseId)) continue;
    final double? p = pointsOf(def.exerciseId);
    if (p == null || !p.isFinite) continue;
    if (best == null || _greater(p, bestPoints!)) {
      best = def;
      bestPoints = p;
    }
  }
  if (best != null) return best.exerciseId;
  for (final ReExercise def in defs) {
    if (hasRecord(def.exerciseId)) return def.exerciseId;
  }
  return defs.first.exerciseId;
}

/// `a > b` ignoring float noise — the same epsilon as the server reducer.
bool _greater(double a, double b) {
  final double scale = a.abs() > b.abs() ? a.abs() : b.abs();
  return (a - b) > 1e-9 * (scale < 1.0 ? 1.0 : scale);
}
