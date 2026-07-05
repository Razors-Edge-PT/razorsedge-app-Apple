import 'package:cloud_firestore/cloud_firestore.dart';

/// Shared catalog / repository layer for exercises.
///
/// There are two sources of exercises, and from the user's point of view there
/// is no difference between them:
///   * Global exercises: `/exercises/{exerciseId}` — available to all users.
///   * User custom exercises: `/users/{ownerUid}/customExercises/{exerciseId}`
///     — available only to that account (and, per Firestore rules, to that
///     account's assigned coach / super admin, matching `canAccessTraining`).
///
/// UID rules (see requirement notes):
///   * `actorUid`  — the authenticated user performing the action. Decides
///     whether the writer is Richard/admin (→ writes to the global pool).
///   * `ownerUid`  — whose custom pool receives the document. In coach mode
///     this is the SELECTED athlete UID (WES2 `actingUid` /
///     `UserContext.currentUid`), NOT `FirebaseAuth.currentUser.uid`.
///
/// Everything funnels through this layer so Firestore merge/normalisation logic
/// is not duplicated across the ~dozen exercise picker / list locations.
class ExerciseCatalog {
  ExerciseCatalog._();

  /// The single admin/developer UID allowed to write the GLOBAL `/exercises`
  /// pool through the normal add flow. This is Richard's UID and matches the
  /// existing `UserContext.isSuperAdmin` / `OnboardingCueService.richardUid`
  /// constants. Kept here so the catalog layer does not depend on UI state.
  ///
  /// TODO(Richard): confirm this is the correct production admin UID before
  /// release. It must NOT be Julien's or any athlete/testing UID.
  static const String adminExerciseWriterUid =
      'yoVAqScwLMQLAgNHh8v9IK49fBw2';

  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// True when [actorUid] is the admin/global writer.
  static bool isAdminWriter(String actorUid) =>
      actorUid == adminExerciseWriterUid;

  // ---------------------------------------------------------------------------
  // Loaders
  // ---------------------------------------------------------------------------

  /// Global exercises from `/exercises`.
  static Future<List<CatalogExercise>> loadGlobalExercises() async {
    final snap = await _db.collection('exercises').get();
    return snap.docs
        .map((d) => CatalogExercise.fromMap(d.id, d.data(),
            source: ExerciseSource.global))
        .toList();
  }

  /// Custom exercises for a specific account from
  /// `/users/{uid}/customExercises`.
  static Future<List<CatalogExercise>> loadCustomExercisesForUser(
      String uid) async {
    if (uid.isEmpty) return const [];
    final snap = await _db
        .collection('users')
        .doc(uid)
        .collection('customExercises')
        .get();
    return snap.docs
        .map((d) => CatalogExercise.fromMap(d.id, d.data(),
            source: ExerciseSource.custom, ownerUid: uid))
        .toList();
  }

  /// Combined global + that account's custom exercises, sorted by category then
  /// name. This is the list every "Add Exercise" / picker location should show
  /// for the relevant account ([uid] = selected/acting athlete UID).
  static Future<List<CatalogExercise>> loadCombinedExercisesForUser(
      String uid) async {
    final results = await Future.wait([
      loadGlobalExercises(),
      loadCustomExercisesForUser(uid),
    ]);
    final combined = <CatalogExercise>[...results[0], ...results[1]];
    combined.sort(_byCategoryThenName);
    return combined;
  }

  static int _byCategoryThenName(CatalogExercise a, CatalogExercise b) {
    final c = a.category.toLowerCase().compareTo(b.category.toLowerCase());
    if (c != 0) return c;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  // ---------------------------------------------------------------------------
  // Resolution by id (global first, then that account's custom pool)
  // ---------------------------------------------------------------------------

  /// Resolves a single exercise by [exerciseId]. Looks up the global pool
  /// first, then falls back to `/users/{uid}/customExercises/{exerciseId}` so
  /// custom exercise IDs resolve anywhere global IDs currently do.
  ///
  /// Returns null if neither exists.
  static Future<CatalogExercise?> resolveExercise({
    required String exerciseId,
    required String uid,
  }) async {
    if (exerciseId.isEmpty) return null;
    final globalDoc =
        await _db.collection('exercises').doc(exerciseId).get();
    if (globalDoc.exists && globalDoc.data() != null) {
      return CatalogExercise.fromMap(globalDoc.id, globalDoc.data()!,
          source: ExerciseSource.global);
    }
    if (uid.isEmpty) return null;
    final customDoc = await _db
        .collection('users')
        .doc(uid)
        .collection('customExercises')
        .doc(exerciseId)
        .get();
    if (customDoc.exists && customDoc.data() != null) {
      return CatalogExercise.fromMap(customDoc.id, customDoc.data()!,
          source: ExerciseSource.custom, ownerUid: uid);
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Adds an exercise.
  ///
  /// Routing:
  ///   * If [actorUid] is the admin writer (Richard) → writes GLOBAL
  ///     `/exercises` (preserving current behaviour), with `source: "global"`.
  ///   * Otherwise → writes `/users/{ownerUid}/customExercises`, with
  ///     `ownerUid`, `createdByUid` ([actorUid]), timestamps and
  ///     `source: "custom"`.
  ///
  /// Duplicate prevention (custom writes only): if an exact match on
  /// name + category + primary bodyPart (case-insensitive) already exists in
  /// the account's combined (global + custom) pool, the write is skipped and
  /// the existing/duplicate exercise's context is returned. Global/admin writes
  /// preserve the current no-dedupe behaviour.
  ///
  /// Returns an [AddExerciseResult] describing what happened.
  static Future<AddExerciseResult> addExercise({
    required String ownerUid,
    required String actorUid,
    required String name,
    required List<String> bodyParts,
    required String category,
    String? type,
  }) async {
    final trimmedName = name.trim();
    final orderedParts = bodyParts
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    final primaryBodyPart =
        orderedParts.isNotEmpty ? orderedParts.first : '';

    if (isAdminWriter(actorUid)) {
      // GLOBAL write — preserve existing behaviour (no dedupe).
      final data = <String, dynamic>{
        'name': trimmedName,
        'category': category,
        'bodyParts': orderedParts,
        if (orderedParts.isNotEmpty) 'bodyPart': primaryBodyPart,
        if (type != null && type.isNotEmpty) 'type': type,
        'source': 'global',
      };
      final ref = await _db.collection('exercises').add(data);
      return AddExerciseResult(
        outcome: AddExerciseOutcome.createdGlobal,
        exerciseId: ref.id,
        ownerUid: null,
      );
    }

    // CUSTOM write — dedupe against the account's combined pool.
    final combined = await loadCombinedExercisesForUser(ownerUid);
    final duplicate = combined.firstWhereOrNull((e) =>
        e.name.toLowerCase() == trimmedName.toLowerCase() &&
        e.category.toLowerCase() == category.toLowerCase() &&
        e.bodyPart.toLowerCase() == primaryBodyPart.toLowerCase());
    if (duplicate != null) {
      return AddExerciseResult(
        outcome: AddExerciseOutcome.duplicate,
        exerciseId: duplicate.id,
        ownerUid: duplicate.source == ExerciseSource.custom ? ownerUid : null,
      );
    }

    final now = FieldValue.serverTimestamp();
    final data = <String, dynamic>{
      'name': trimmedName,
      'category': category,
      'bodyParts': orderedParts,
      if (orderedParts.isNotEmpty) 'bodyPart': primaryBodyPart,
      if (type != null && type.isNotEmpty) 'type': type,
      'ownerUid': ownerUid,
      'createdByUid': actorUid,
      'createdAt': now,
      'updatedAt': now,
      'source': 'custom',
    };
    final ref = await _db
        .collection('users')
        .doc(ownerUid)
        .collection('customExercises')
        .add(data);
    return AddExerciseResult(
      outcome: AddExerciseOutcome.createdCustom,
      exerciseId: ref.id,
      ownerUid: ownerUid,
    );
  }
}

/// Where an exercise came from.
enum ExerciseSource { global, custom }

/// Normalised exercise model shared across all picker/list locations.
/// Handles both old global docs (where `bodyPart` may be a comma-separated
/// string and `bodyParts` may be absent) and new docs (ordered `bodyParts`
/// list with `bodyPart` = primary).
class CatalogExercise {
  /// Firestore document id — used everywhere exercise IDs are used.
  final String id;
  final String name;
  final String category;

  /// Full, ordered body parts (primary first).
  final List<String> bodyParts;

  /// Primary body part (legacy compatibility) — first of [bodyParts].
  final String bodyPart;

  /// Optional equipment type.
  final String? type;

  final ExerciseSource source;

  /// Owner UID for custom exercises; null for global.
  final String? ownerUid;

  const CatalogExercise({
    required this.id,
    required this.name,
    required this.category,
    required this.bodyParts,
    required this.bodyPart,
    required this.source,
    this.type,
    this.ownerUid,
  });

  /// Convenient joined display string, e.g. "Chest, Anterior Delts, Triceps".
  String get bodyPartsDisplay => bodyParts.join(', ');

  factory CatalogExercise.fromMap(
    String id,
    Map<String, dynamic> m, {
    required ExerciseSource source,
    String? ownerUid,
  }) {
    // Normalise body parts to an ordered List<String>, accepting either a list
    // (new canonical) or a comma-separated string (legacy).
    List<String> parts;
    final rawList = m['bodyParts'];
    final rawString = m['bodyPart'];
    if (rawList is List) {
      parts = rawList
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } else if (rawString is String) {
      parts = rawString
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else {
      parts = <String>[];
    }
    final primary = parts.isNotEmpty ? parts.first : '';

    final rawType = m['type'];
    final type = (rawType is String && rawType.trim().isNotEmpty)
        ? rawType.trim()
        : null;

    return CatalogExercise(
      id: id,
      name: (m['name'] ?? '').toString(),
      category: (m['category'] ?? '').toString(),
      bodyParts: parts,
      bodyPart: primary,
      type: type,
      source: source,
      ownerUid: ownerUid ?? (m['ownerUid'] as String?),
    );
  }

  /// Untyped map for legacy call sites that expect `Map<String, dynamic>`
  /// entries (e.g. the exercises library screen).
  Map<String, dynamic> toDisplayMap() => <String, dynamic>{
        'id': id,
        'name': name,
        'category': category,
        'bodyParts': bodyParts,
        'bodyPart': bodyPart,
        'bodyPartsDisplay': bodyPartsDisplay,
        if (type != null) 'type': type,
        'source': source == ExerciseSource.custom ? 'custom' : 'global',
      };
}

/// Outcome of an [ExerciseCatalog.addExercise] call.
enum AddExerciseOutcome { createdGlobal, createdCustom, duplicate }

class AddExerciseResult {
  final AddExerciseOutcome outcome;
  final String exerciseId;

  /// Owner UID for custom results; null for global.
  final String? ownerUid;

  const AddExerciseResult({
    required this.outcome,
    required this.exerciseId,
    this.ownerUid,
  });

  bool get isDuplicate => outcome == AddExerciseOutcome.duplicate;
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
