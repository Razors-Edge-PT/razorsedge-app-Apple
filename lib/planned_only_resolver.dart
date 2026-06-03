import 'package:cloud_firestore/cloud_firestore.dart';

/// Returns the planned-only exercise ID set for picker filtering.
///
/// Result = templateCandidateExerciseIds ∪ IDs used in any template tied to [blockId].
/// Fallback when candidateIds is empty: exerciseSettings.keys → plannedExercises (legacy).
/// Returns an empty set if [blockId] is null/empty or any read fails.
Future<Set<String>> resolvePlannedOnlyIds({
  required String uid,
  required String? blockId,
}) async {
  if (blockId == null || blockId.isEmpty) return const {};
  try {
    final blockDoc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId)
        .get();
    final data = blockDoc.data();

    final candidateIds = (data?['templateCandidateExerciseIds'] as List?)
            ?.map((e) => e.toString())
            .toSet() ??
        const <String>{};
    final settingsKeys =
        (data?['exerciseSettings'] as Map<String, dynamic>?)?.keys.toSet() ??
            const <String>{};
    final legacyPlanned = (data?['plannedExercises'] as List?)
            ?.map((e) => e.toString())
            .toSet() ??
        const <String>{};

    final baseIds = candidateIds.isNotEmpty
        ? candidateIds
        : settingsKeys.isNotEmpty
            ? settingsKeys
            : legacyPlanned;

    // Union: also include IDs actually used in templates for this block.
    final templateSnap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('templates')
        .where('blockId', isEqualTo: blockId)
        .get();

    final templateUsedIds = <String>{};
    for (final doc in templateSnap.docs) {
      for (final ex in (doc.data()['exercises'] as List? ?? [])) {
        if (ex is Map) {
          final exId = (ex['exerciseId'] ?? ex['id'])?.toString();
          if (exId != null && exId.isNotEmpty) templateUsedIds.add(exId);
        }
      }
    }

    return {...baseIds, ...templateUsedIds};
  } catch (_) {
    return const {};
  }
}
