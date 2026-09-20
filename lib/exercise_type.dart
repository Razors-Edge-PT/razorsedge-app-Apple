/// The ONE place the app decides what an exercise's catalogue `type` means,
/// and the ONE place a raw stored set is judged "performed".
///
/// Deliberately import-free: every layer (the pure calculation engines, the
/// Firestore catalogue, WES2, the analytics screens) depends on this file, so
/// it may depend on nothing.
///
/// ── Bodyweight classification ───────────────────────────────────────────────
/// An exercise is lifted as the athlete's bodyweight plus whatever hangs from
/// the belt when EITHER
///   * its id or display name is in the hard-coded catalogue
///     (PeriodizationModelUtils._bwById / _bwByName, mirrored by
///     functions/coach/bodyweight_exercises.js), or
///   * its catalogue `type` is [kBodyweightExerciseType].
///
/// The type is the canonical, data-driven rule: an exercise added through the
/// Exercises page with the "Body Weight" equipment type is treated as one
/// without anybody editing a hard-coded list. The lists remain as
/// backward-compatible fallbacks for the exercises that predate the field.
///
/// Classification is NEVER inferred from an exercise's name, category or body
/// parts — only from the two sources above.
library;

/// The canonical catalogue value, exactly as `add_exercise_dialog.dart` offers
/// it and `ExerciseCatalog.addExercise` stores it in `type`.
const String kBodyweightExerciseType = 'Body Weight';

final String _kBodyweightTypeFolded = kBodyweightExerciseType.toLowerCase();

/// True when [type] is the bodyweight catalogue type.
///
/// Tolerant of leading/trailing whitespace and of case, because the field is
/// free-form text in Firestore and `CatalogExercise.fromMap` only trims it.
/// Nothing else about the exercise is consulted.
bool isBodyweightExerciseType(String? type) {
  if (type == null) return false;
  final String t = type.trim();
  if (t.isEmpty) return false;
  return t.toLowerCase() == _kBodyweightTypeFolded;
}

/// exerciseId → catalogue `type`, for the code that classifies an exercise it
/// only knows by id.
///
/// This is a CACHE of the canonical catalogue (`/exercises/{id}` and
/// `/users/{uid}/customExercises/{id}`), never a second source of truth. It is
/// filled at the bounded I/O boundaries that already read the catalogue —
/// [ExerciseCatalog]'s loaders/resolvers and WES2's `loadExerciseTypes` — and
/// read by the pure classifiers, which perform no I/O of their own.
///
/// A missing entry simply means "not known here", which falls back to the
/// hard-coded id/name catalogue. Nothing ever guesses.
class ExerciseTypeRegistry {
  ExerciseTypeRegistry._();

  static final Map<String, String> _byId = <String, String>{};

  /// The live map. Exposed so long-standing callers that read
  /// `PeriodizationModelUtils.exerciseTypeById` keep working unchanged.
  static Map<String, String> get types => _byId;

  /// The cached catalogue type of [exerciseId], or null.
  static String? typeOf(String? exerciseId) {
    if (exerciseId == null) return null;
    final String id = exerciseId.trim();
    if (id.isEmpty) return null;
    final String? t = _byId[id];
    return (t != null && t.isNotEmpty) ? t : null;
  }

  /// Caches [type] for [exerciseId]. A null/blank type REMOVES the entry
  /// rather than storing a blank, so "unknown" and "known to be blank" cannot
  /// be confused.
  static void register(String? exerciseId, String? type) {
    if (exerciseId == null) return;
    final String id = exerciseId.trim();
    if (id.isEmpty) return;
    final String t = (type ?? '').trim();
    if (t.isEmpty) {
      _byId.remove(id);
      return;
    }
    _byId[id] = t;
  }

  /// Caches every entry of [entries] through [register].
  static void registerAll(Map<String, String?> entries) {
    entries.forEach(register);
  }

  /// Which of [exerciseIds] have no cached type — what a bounded catalogue
  /// fetch needs to ask for.
  static List<String> missingFrom(Iterable<String> exerciseIds) {
    final Set<String> out = <String>{};
    for (final String raw in exerciseIds) {
      final String id = raw.trim();
      if (id.isEmpty) continue;
      if (typeOf(id) == null) out.add(id);
    }
    return out.toList();
  }

  /// Drops everything (athlete switch / sign-out / tests).
  static void clear() => _byId.clear();
}

// ── Raw stored-set validity ─────────────────────────────────────────────────

/// Whether a set's RAW STORED `weight` represents a performed load.
///
/// Zero is the whole point of this predicate: WES2 stores exactly what the
/// athlete typed, so on a bodyweight exercise a stored `0` means "0 kg ADDED"
/// — a real set at the athlete's own bodyweight — while on every other
/// exercise it still means "nothing logged". A NEGATIVE weight is invalid
/// everywhere, and so is a non-finite one.
///
/// This is about the RAW stored field only. A normalised TOTAL load keeps its
/// existing positive requirement (a total of zero is not a lift).
bool isStoredWeightPerformed(num? weightKg, {required bool isBodyweight}) {
  if (weightKg == null) return false;
  final double w = weightKg.toDouble();
  if (!w.isFinite) return false;
  if (w < 0) return false;
  return isBodyweight || w > 0;
}

/// Whether one raw stored set counts as PERFORMED: a valid stored weight (see
/// [isStoredWeightPerformed]) and strictly positive reps.
///
/// The single rule behind the training calendar, coach adherence, the BB3
/// session counts, WES2's qualifying-day counting and progression exposure, so
/// those four can never drift apart again.
bool isRawSetPerformed({
  num? weightKg,
  num? reps,
  required bool isBodyweight,
}) {
  if (!isStoredWeightPerformed(weightKg, isBodyweight: isBodyweight)) {
    return false;
  }
  if (reps == null) return false;
  final double r = reps.toDouble();
  return r.isFinite && r > 0;
}
