import 'package:cloud_firestore/cloud_firestore.dart';
import 'WES2_models.dart';
import 'periodization_model_utils.dart';

abstract class Wes2TemplateService {
  /// Load template rows by templateId. Only rows with a non-empty exerciseId
  /// are returned; array position becomes orderIndex.
  Future<List<Wes2ExerciseRow>> loadTemplate({
    required String uid,
    required String templateId,
  });

  /// Save a manually-built completed day as a new template.
  /// [blockId] is null when no block is active.
  Future<void> saveWorkoutAsTemplate({
    required String uid,
    required String? blockId,
    required String templateName,
    required List<Wes2ExerciseRow> rows,
  });
}

class FirestoreWes2TemplateService implements Wes2TemplateService {
  static const int _defaultSetCount = 3;

  @override
  Future<List<Wes2ExerciseRow>> loadTemplate({
    required String uid,
    required String templateId,
  }) async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('templates')
        .doc(templateId)
        .get();

    if (!snap.exists) return const [];
    final data = snap.data();
    if (data == null) return const [];

    final rawExercises = (data['exercises'] as List<dynamic>?) ?? const [];
    final result = <Wes2ExerciseRow>[];
    final seen = <String>{};

    for (int i = 0; i < rawExercises.length; i++) {
      final raw = rawExercises[i];
      if (raw is! Map<String, dynamic>) continue;

      final rawName =
          ((raw['name'] ?? raw['exercise']) as String? ?? '').trim();
      final rawId =
          ((raw['exerciseId'] ?? raw['id']) as String? ?? '').trim();
      final exerciseId = await _resolveCanonicalExerciseId(rawId, rawName);
      if (exerciseId.isEmpty) continue;
      if (rawId != exerciseId) {
        print('[WES2Template] resolved "$rawName": "$rawId" → "$exerciseId"');
      }
      if (seen.contains(exerciseId)) continue;
      seen.add(exerciseId);

      final name = rawName.isNotEmpty ? rawName : exerciseId;
      final circuitIndex = (raw['circuitIndex'] as num?)?.toInt() ?? 0;
      final setCount =
          (raw['setCount'] as num?)?.toInt() ?? _defaultSetCount;

      result.add(Wes2ExerciseRow(
        exerciseId: exerciseId,
        name: name,
        circuitIndex: circuitIndex,
        orderIndex: i,
        setCount: setCount,
        sets: List.generate(setCount, (j) => Wes2SetState(setIndex: j)),
        source: Wes2RowSource.templateLoaded,
      ));
    }

    result.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    // Re-normalise orderIndex to 0-based contiguous after sort+dedup.
    return List.generate(
      result.length,
      (i) => result[i].copyWith(orderIndex: i),
    );
  }

  /// Returns the canonical Firestore exercises doc ID for a template row.
  ///
  /// Resolution order:
  ///   1. rawExerciseId is non-empty and != rawName → already a doc ID, return as-is.
  ///   2. PeriodizationModelUtils.nameToId (in-memory; populated when Camp_BB2 /
  ///      Block Planner has been visited this session) → fast, no Firestore read.
  ///   3. Firestore exercises collection, exact name match → one query per
  ///      unresolved name; result is cached in nameToId for the rest of the session.
  ///   4. Return rawExerciseId (or rawName if rawExerciseId is also empty).
  static Future<String> _resolveCanonicalExerciseId(
    String rawExerciseId,
    String rawName,
  ) async {
    // Step 1: looks like a real doc ID already.
    if (rawExerciseId.isNotEmpty && rawExerciseId != rawName) {
      return rawExerciseId;
    }

    final nameKey = rawName.trim();
    if (nameKey.isEmpty) return rawExerciseId;

    // Step 2: fast in-memory lookup.
    final fromMemory = PeriodizationModelUtils.nameToId[nameKey];
    if (fromMemory != null && fromMemory.isNotEmpty) return fromMemory;

    // Step 3: Firestore fallback — one query per unresolved name.
    try {
      final snap = await FirebaseFirestore.instance
          .collection('exercises')
          .where('name', isEqualTo: nameKey)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty) {
        final docId = snap.docs.first.id;
        PeriodizationModelUtils.nameToId[nameKey] = docId; // cache for session
        return docId;
      }
    } catch (_) {
      // Non-critical — fall through to best-effort return.
    }

    // Step 4: best-effort fallback.
    return rawExerciseId.isNotEmpty ? rawExerciseId : rawName;
  }

  @override
  Future<void> saveWorkoutAsTemplate({
    required String uid,
    required String? blockId,
    required String templateName,
    required List<Wes2ExerciseRow> rows,
  }) async {
    // Structure only: exerciseId, name, circuitIndex.
    // Never write actual logged values (weight/reps/RIR/velocity/notes).
    final exercises = rows
        .map((r) => <String, dynamic>{
              'exerciseId': r.exerciseId,
              'name': r.name,
              'circuitIndex': r.circuitIndex,
            })
        .toList();

    final payload = <String, dynamic>{
      'name': templateName,
      'exercises': exercises,
      if (blockId != null && blockId.isNotEmpty) 'blockId': blockId,
      'createdAt': FieldValue.serverTimestamp(),
      'isKept': true,
    };

    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('templates')
        .add(payload);
  }
}
