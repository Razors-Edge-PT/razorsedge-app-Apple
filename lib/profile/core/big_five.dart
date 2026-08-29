/// The five lifts the profile showcase celebrates, and the ONLY rules by which
/// a logged exercise row is allowed to claim one of those slots.
///
/// Matching is deliberately conservative, in this order:
///
///  1. STABLE ID. `exerciseId` (WES2) or legacy `id`, compared case-folded.
///     Production workout documents written between 2026-03-03 and 2026-05-07
///     persisted lowercased copies of catalog ids (see
///     functions/coach/pb_engine.js), so folding is required to reunite a
///     single lift's history.
///
///  2. EXPLICIT LEGACY NAME ALIAS. Only for rows that carry NO id at all.
///     The alias list is an exact, closed, case-insensitive set of canonical
///     names that were actually written by older builds. It is NOT a fuzzy or
///     prefix match: the catalogue contains "Larsen Bench Press",
///     "Bench Press, Larsen Press", "Bench Press, Narrow Grip",
///     "Back Squat, Low bar", "Sumo Deadlift", "Pull-Up" and
///     "Overhead Dumbbell Press" (bilateral), every one of which must stay OUT
///     of the showcase.
///
/// Ids verified 2026-08-29 against assets/exercise_dump_20251109_112626.json.
library;

/// Stable slot keys. Persisted in Firestore — never renumber or rename.
class BigFiveSlot {
  static const String bench = 'bench';
  static const String squat = 'squat';
  static const String deadlift = 'deadlift';
  static const String chinUp = 'chinUp';
  static const String ohpUnilateral = 'ohpUnilateral';

  /// Display order used by the showcase UI.
  static const List<String> ordered = <String>[
    bench,
    squat,
    deadlift,
    chinUp,
    ohpUnilateral,
  ];
}

/// One Big Five lift definition.
class BigFiveLift {
  const BigFiveLift({
    required this.slot,
    required this.exerciseId,
    required this.displayName,
    required this.legacyNameAliases,
  });

  /// Stable slot key (see [BigFiveSlot]).
  final String slot;

  /// Catalogue document id, in its canonical casing.
  final String exerciseId;

  /// Name shown in the showcase.
  final String displayName;

  /// Exact canonical names accepted for id-less legacy rows only.
  final List<String> legacyNameAliases;

  /// Case-folded catalogue id — the stream key used everywhere.
  String get foldedId => exerciseId.toLowerCase();
}

/// The five lifts, in display order.
const List<BigFiveLift> kBigFive = <BigFiveLift>[
  BigFiveLift(
    slot: BigFiveSlot.bench,
    exerciseId: 'AmfUWbF1DH3I7qPAdh5k',
    displayName: 'Bench Press, Barbell',
    // "Bench Press" was the pre-catalogue name written by the earliest builds.
    legacyNameAliases: <String>['Bench Press, Barbell', 'Bench Press'],
  ),
  BigFiveLift(
    slot: BigFiveSlot.squat,
    exerciseId: 'heeBViVINHO6tUScSd6y',
    displayName: 'Back Squat, Barbell',
    legacyNameAliases: <String>['Back Squat, Barbell', 'Back Squat'],
  ),
  BigFiveLift(
    slot: BigFiveSlot.deadlift,
    exerciseId: 'MsGl7e9yanDeEnYX0e4X',
    displayName: 'Deadlift, Conventional',
    legacyNameAliases: <String>['Deadlift, Conventional', 'Deadlift'],
  ),
  BigFiveLift(
    slot: BigFiveSlot.chinUp,
    exerciseId: 'XM9026peNIu0R8qh7UqY',
    displayName: 'Chin-Up',
    // "Pull-Up" is a DIFFERENT catalogue exercise (RFyjAjezFs8Rf7CQoaXz) and
    // is deliberately absent.
    legacyNameAliases: <String>['Chin-Up', 'Chin Up'],
  ),
  BigFiveLift(
    slot: BigFiveSlot.ohpUnilateral,
    exerciseId: 'RdsGazgdH0xgpjek0n3u',
    displayName: 'Overhead Dumbbell Press, Unilateral',
    // Bare "Overhead Dumbbell Press" is the BILATERAL exercise
    // (2yJSfLMfOnNDSeZ7DqZT) and must never fall into this slot.
    legacyNameAliases: <String>['Overhead Dumbbell Press, Unilateral'],
  ),
];

final Map<String, BigFiveLift> _bySlot = <String, BigFiveLift>{
  for (final BigFiveLift l in kBigFive) l.slot: l,
};

final Map<String, BigFiveLift> _byFoldedId = <String, BigFiveLift>{
  for (final BigFiveLift l in kBigFive) l.foldedId: l,
};

final Map<String, BigFiveLift> _byFoldedAlias = <String, BigFiveLift>{
  for (final BigFiveLift l in kBigFive)
    for (final String a in l.legacyNameAliases) a.trim().toLowerCase(): l,
};

/// The lift for a stable slot key, or null.
BigFiveLift? bigFiveBySlot(String slot) => _bySlot[slot];

/// Case-folds an exercise id the way every showcase stream key is folded.
/// Returns null for a blank / non-string id.
String? foldExerciseId(Object? rawId) {
  if (rawId is! String) return null;
  final String t = rawId.trim();
  if (t.isEmpty) return null;
  return t.toLowerCase();
}

/// Resolves a logged exercise row to a Big Five slot, or null when the row is
/// not one of the five.
///
/// [rawId] wins whenever it is present, even if it resolves to nothing: a row
/// that carries a real catalogue id for some other exercise must never be
/// rescued by its name. Only a completely id-less row falls through to the
/// closed alias list.
BigFiveLift? matchBigFive({Object? rawId, Object? rawName}) {
  final String? folded = foldExerciseId(rawId);
  if (folded != null) return _byFoldedId[folded];
  if (rawName is! String) return null;
  return _byFoldedAlias[rawName.trim().toLowerCase()];
}
