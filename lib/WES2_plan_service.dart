import 'package:cloud_firestore/cloud_firestore.dart';
import 'WES2_models.dart';
import 'exercise_catalog.dart';
import 'local_cache/block_plan_cache.dart';
import 'block_exercise_defaults_repository.dart';
import 'settings_merge.dart';
import 'wes2_exercise_settings_patch.dart';

// Abstract interface — unchanged from Phase 1.
abstract class Wes2PlanService {
  /// Load BB3 planned day rows from:
  ///   /planned_blocks/{uid}/blocks/{blockId}/weeks/week_{weekIndex}/days/day_{dayIndex}
  Future<List<Wes2ExerciseRow>> loadPlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  });

  /// Load the block-level exerciseSettings map from:
  ///   /planned_blocks/{uid}/blocks/{blockId}.exerciseSettings
  Future<Map<String, dynamic>> loadExerciseSettings({
    required String uid,
    required String blockId,
  });

  /// Write back to the BB3 planned day after a structural WES2 change
  /// (delete / replace / reorder of a BB3-sourced exercise).
  Future<void> updatePlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required List<Wes2ExerciseRow> updatedRows,
  });

  /// Save exerciseSettings for one exercise from an explicit dirty-field
  /// [patch]. Transactionally re-reads the latest canonical
  /// `exerciseSettings[exerciseId]`, applies only the changed leaves with
  /// model-aware block-wide propagation, preserves every untouched/unknown key,
  /// writes only `exerciseSettings[exerciseId]`, and returns the canonical
  /// saved object. Requires internet; must not be queued offline.
  Future<Map<String, dynamic>> saveExerciseSettings({
    required String uid,
    required String blockId,
    required String exerciseId,
    required ExerciseSettingsPatch patch,
  });

  /// Detects and conservatively repairs sparse `weekN` shadows in the canonical
  /// `exerciseSettings[exerciseId]` (rirPlan / repTargets), writing back only
  /// when a genuine repair was made. Returns the (possibly repaired) settings
  /// object for that exercise, or null when the exercise has no settings.
  Future<Map<String, dynamic>?> repairExerciseShadows({
    required String uid,
    required String blockId,
    required String exerciseId,
  });

  /// Fetch the exercise type (e.g. "Barbell", "Machine", "Dumbbell") for each
  /// given exerciseId. Resolves global /exercises first, then the account's
  /// custom pool (/users/{uid}/customExercises) when [uid] is provided. Missing
  /// or blank types are excluded from the result.
  Future<Map<String, String>> loadExerciseTypes(List<String> exerciseIds,
      {String uid = ''});
}

/// Concrete Firestore implementation.
/// Phase 4: loadPlannedDay only — reads planned day directly from Firestore.
/// Does not import or reuse BB3PlannedExerciseService or bb3_models.dart.
/// Other methods throw UnimplementedError until later phases.
class FirestoreWes2PlanService implements Wes2PlanService {
  /// Injectable for tests; defaults to the app-wide Firestore instance.
  final FirebaseFirestore _db;

  FirestoreWes2PlanService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  @override
  Future<List<Wes2ExerciseRow>> loadPlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  }) async {
    final snap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId)
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex')
        .get();

    if (!snap.exists) return const [];
    final data = snap.data();
    if (data == null) return const [];

    final exercises = (data['exercises'] as List<dynamic>?) ?? const [];
    final result = <Wes2ExerciseRow>[];

    for (int i = 0; i < exercises.length; i++) {
      final row = _parseRow(exercises[i], i);
      if (row != null) result.add(row);
    }

    result.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return result;
  }

  // ── Parse helpers ─────────────────────────────────────────────────────────

  static Wes2ExerciseRow? _parseRow(dynamic raw, int fallbackOrder) {
    if (raw is! Map<String, dynamic>) return null;

    final exerciseId =
        ((raw['exerciseId'] ?? raw['id']) as String? ?? '').trim();
    if (exerciseId.isEmpty) return null;

    final rawName =
        ((raw['name'] ?? raw['exercise']) as String? ?? '').trim();
    final name = rawName.isNotEmpty ? rawName : exerciseId;

    final circuitIndex = (raw['circuitIndex'] as num?)?.toInt() ?? 0;
    final orderIndex = (raw['orderIndex'] as num?)?.toInt() ?? fallbackOrder;

    final rawSets = raw['sets'];
    final List<Wes2SetState> sets;

    if (rawSets is List && rawSets.isNotEmpty) {
      // New per-set format: each element may carry per-set planned overrides.
      sets = List.generate(rawSets.length, (i) {
        final s = rawSets[i] is Map<String, dynamic>
            ? rawSets[i] as Map<String, dynamic>
            : const <String, dynamic>{};
        return _parsePerSetHints(s, i);
      });
    } else {
      // Legacy flat format: weight/reps/rir are on the exercise map itself.
      // Values apply to set 1 only; sets 2 and 3 have no overrides.
      sets = [
        _parseLegacySetHints(raw, 0),
        Wes2SetState(setIndex: 1),
        Wes2SetState(setIndex: 2),
      ];
    }

    final exercisePlanNote = ((raw['perExerciseNote'] ??
            raw['exerciseNote']) as String?)
        ?.trim();

    return Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: circuitIndex,
      orderIndex: orderIndex,
      setCount: sets.length,
      sets: sets,
      source: Wes2RowSource.bb3Planned,
      exercisePlanNote: exercisePlanNote?.isNotEmpty == true ? exercisePlanNote : null,
    );
  }

  static Wes2SetState _parsePerSetHints(Map<String, dynamic> s, int i) {
    return Wes2SetState(
      setIndex: i,
      weight: _toDoubleHint(s['weight']),
      reps: _toIntHint(s['reps']),
      rir: _toDoubleHint(s['rir']),
      velocity: _toDoubleHint(s['velocity']),
      planNote: (s['notes'] as String?) ??
          (s['note'] as String?) ??
          (s['planNote'] as String?),
    );
  }

  static Wes2SetState _parseLegacySetHints(Map<String, dynamic> raw, int i) {
    return Wes2SetState(
      setIndex: i,
      weight: _toDoubleHint(raw['weight']),
      reps: _toIntHint(raw['reps']),
      rir: _toDoubleHint(raw['rir']),
      // Legacy flat format: exercise-level note applies to set 0 only.
      planNote: i == 0
          ? (raw['note'] as String?) ?? (raw['planNote'] as String?)
          : null,
    );
  }

  /// BB3 planned values go into hintValue only — actualValue is never set.
  static Wes2FieldState<double> _toDoubleHint(dynamic v) {
    if (v is! num) return const Wes2FieldState<double>();
    return Wes2FieldState<double>(
      hintValue: v.toDouble(),
      origin: FieldOrigin.bb3Hint,
      hintOrigin: FieldOrigin.bb3Hint,
    );
  }

  static Wes2FieldState<int> _toIntHint(dynamic v) {
    if (v is! num) return const Wes2FieldState<int>();
    return Wes2FieldState<int>(
      hintValue: v.toInt(),
      origin: FieldOrigin.bb3Hint,
      hintOrigin: FieldOrigin.bb3Hint,
    );
  }

  // ── Write stubs (Phase 7+) ────────────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> loadExerciseSettings({
    required String uid,
    required String blockId,
  }) async {
    final docRef = _db
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    final snap = await docRef.get();
    if (!snap.exists) return const {};
    final data = snap.data();
    if (data == null) return const {};
    final settingsRaw = data['exerciseSettings'];
    if (settingsRaw is! Map) return const {};

    final rawMap = Map<String, dynamic>.from(settingsRaw);
    final healedMap = <String, dynamic>{};
    final updates = <String, dynamic>{};

    for (final entry in rawMap.entries) {
      final exerciseId = entry.key;
      final settingsVal = entry.value;
      if (settingsVal is! Map) {
        healedMap[exerciseId] = settingsVal;
        continue;
      }
      final settings = Map<String, dynamic>.from(settingsVal);
      final healedRirPlan =
          BlockExerciseDefaultsRepository.healWeek1RirPlan(settings);
      if (healedRirPlan != null) {
        settings['rirPlan'] = healedRirPlan;
        updates['exerciseSettings.$exerciseId.rirPlan'] = healedRirPlan;
      }
      healedMap[exerciseId] = settings;
    }

    if (updates.isNotEmpty) {
      try {
        await docRef.update(updates);
        print('[WES2PlanService] healed and wrote rirPlan for ${updates.length} exercise(s) in block=$blockId');
      } catch (e) {
        print('[WES2PlanService] rirPlan heal write failed for block=$blockId error=$e');
      }
    }

    return healedMap;
  }

  @override
  Future<void> updatePlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required List<Wes2ExerciseRow> updatedRows,
  }) async {
    final dayRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId)
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex');

    final exercises = updatedRows.map(_buildPlannedRowMap).toList();

    await dayRef.set(
      {'exercises': exercises},
      SetOptions(merge: true),
    );

    // Mirror to BB3 Isar cache so BB3 doesn't rehydrate stale planned rows.
    try {
      await BlockPlanCache.putDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
        exercises: exercises,
      );
    } catch (_) {
      // Cache miss is recoverable; Firestore is source of truth.
    }
  }

  static Map<String, dynamic> _buildPlannedRowMap(Wes2ExerciseRow row) {
    final sets = List<Map<String, dynamic>>.generate(row.setCount, (i) {
      final s = i < row.sets.length ? row.sets[i] : Wes2SetState(setIndex: i);
      return _buildPlannedSetMap(s);
    });
    return {
      'exerciseId': row.exerciseId,
      'name': row.name,
      'circuitIndex': row.circuitIndex,
      'orderIndex': row.orderIndex,
      'sets': sets,
    };
  }

  static Map<String, dynamic> _buildPlannedSetMap(Wes2SetState s) {
    final map = <String, dynamic>{};
    final w = s.weight.hintValue;
    final r = s.reps.hintValue;
    final rir = s.rir.hintValue;
    final v = s.velocity.hintValue;
    if (w != null) map['weight'] = w;
    if (r != null) map['reps'] = r;
    if (rir != null) map['rir'] = rir;
    if (v != null) map['velocity'] = v;
    if (s.planNote != null && s.planNote!.isNotEmpty) {
      map['note'] = s.planNote;
    }
    return map;
  }

  @override
  Future<Map<String, dynamic>> saveExerciseSettings({
    required String uid,
    required String blockId,
    required String exerciseId,
    required ExerciseSettingsPatch patch,
  }) async {
    final docRef = _db
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    return _db.runTransaction<Map<String, dynamic>>((txn) async {
      final snap = await txn.get(docRef);
      final data = snap.exists
          ? (snap.data() ?? <String, dynamic>{})
          : <String, dynamic>{};

      // Full latest exerciseSettings map + this exercise's COMPLETE object.
      final allSettings =
          SettingsMerge.asMap(data['exerciseSettings']) ?? <String, dynamic>{};
      final latest =
          SettingsMerge.asMap(allSettings[exerciseId]) ?? <String, dynamic>{};

      // Apply only the changed leaves; preserves every untouched/unknown key
      // and never replaces a complete nested map with a partial one.
      final merged = SettingsMerge.applyPatch(latest, patch);
      allSettings[exerciseId] = merged;

      _writeExerciseSettings(txn, docRef, allSettings);
      return merged;
    });
  }

  /// Writes the whole `exerciseSettings` field with REPLACE semantics via
  /// `mergeFields`, so deliberately cleared leaves and pruned maps actually
  /// disappear, while every OTHER top-level block field (including any
  /// deprecated structures) is left completely untouched. [allSettings] must be
  /// the complete map of all exercises carried through from the transactional
  /// read with only the edited exercise replaced.
  void _writeExerciseSettings(
    Transaction txn,
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> allSettings,
  ) {
    txn.set(
      docRef,
      {'exerciseSettings': allSettings},
      SetOptions(mergeFields: ['exerciseSettings']),
    );
  }

  @override
  Future<Map<String, dynamic>?> repairExerciseShadows({
    required String uid,
    required String blockId,
    required String exerciseId,
  }) async {
    final docRef = _db
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    return _db.runTransaction<Map<String, dynamic>?>((txn) async {
      final snap = await txn.get(docRef);
      if (!snap.exists) return null;
      final data = snap.data() ?? <String, dynamic>{};

      final allSettings =
          SettingsMerge.asMap(data['exerciseSettings']) ?? <String, dynamic>{};
      final latest = SettingsMerge.asMap(allSettings[exerciseId]);
      if (latest == null) return null;

      final (repaired, changed) = SettingsMerge.repairShadows(latest);
      if (!changed) return latest;
      allSettings[exerciseId] = repaired;

      // True-replace so removed sparse weekN shadows actually disappear, while
      // all other top-level block fields stay untouched.
      _writeExerciseSettings(txn, docRef, allSettings);

      print(
          '🩹 [WES2PlanService] repaired sparse weekN shadow(s) for $exerciseId in block=$blockId');
      return repaired;
    });
  }

  @override
  Future<Map<String, String>> loadExerciseTypes(List<String> exerciseIds,
      {String uid = ''}) async {
    if (exerciseIds.isEmpty) return const {};
    final futures = exerciseIds.map((id) async {
      try {
        // Global first, then this account's custom pool.
        final ex =
            await ExerciseCatalog.resolveExercise(exerciseId: id, uid: uid);
        return MapEntry(id, ex?.type ?? '');
      } catch (_) {
        return MapEntry(id, '');
      }
    });
    final entries = await Future.wait(futures);
    return Map.fromEntries(entries.where((e) => e.value.isNotEmpty));
  }
}
