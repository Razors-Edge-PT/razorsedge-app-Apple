/// Non-destructive write guard for planned-block documents
/// (`users/{uid}/planned_blocks/{blockId}`).
///
/// Every legacy Block Planner save of block membership or per-exercise
/// settings goes through [BlockSaveGuard.commit], which re-reads the SERVER
/// document inside a transaction and applies only narrow updates:
///
///  * one `exerciseSettings.{exerciseId}` entry per changed exercise, merged
///    over the server's entry so unknown / unrendered keys survive;
///  * `FieldValue.delete()` only for exercise ids the user explicitly removed
///    after a successful load;
///  * `exercises` / `plannedExercises` / `excludedExerciseIds` only when the
///    user changed membership, and never as an empty list over a populated
///    remote list (or an exclusion list with nothing left visible).
///
/// The whole `exerciseSettings` map is never written, so an empty or
/// incomplete local model can never replace populated remote settings.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

class BlockSaveRequest {
  /// exerciseId → the full local entry for an exercise the user changed.
  final Map<String, Map<String, dynamic>> changedEntries;

  /// Exercise ids the user explicitly removed after a successful load.
  final Set<String> removedIds;

  /// New `exercises` / `plannedExercises` list (array-membership blocks),
  /// or null when membership did not change.
  final List<String>? membership;

  /// New `excludedExerciseIds` (allExercisesAvailable blocks), or null when
  /// membership did not change.
  final List<String>? excludedExerciseIds;

  /// How many exercises remain visible with [excludedExerciseIds] applied.
  final int visibleExerciseCount;

  /// Plain top-level fields (name, dates, …). Settings and membership fields
  /// are refused here; they have their own guarded channels above.
  final Map<String, dynamic> metadata;

  const BlockSaveRequest({
    this.changedEntries = const {},
    this.removedIds = const {},
    this.membership,
    this.excludedExerciseIds,
    this.visibleExerciseCount = 0,
    this.metadata = const {},
  });
}

class BlockSavePlan {
  /// Keys are `String` or [FieldPath]; ready for `update()`.
  final Map<Object, Object?> updates;

  /// Human-readable reasons for every part of the request that was refused.
  final List<String> refused;

  const BlockSavePlan(this.updates, this.refused);

  bool get isEmpty => updates.isEmpty;
}

class BlockSaveGuard {
  BlockSaveGuard._();

  static const String settingsField = 'exerciseSettings';
  static const Set<String> protectedFields = {
    settingsField,
    'exercises',
    'plannedExercises',
    'excludedExerciseIds',
  };

  static bool _nonEmptyList(dynamic v) => v is List && v.isNotEmpty;

  /// Pure: the narrow update for [request] against the server's [remote].
  static BlockSavePlan plan({
    required Map<String, dynamic> remote,
    required BlockSaveRequest request,
  }) {
    final updates = <Object, Object?>{};
    final refused = <String>[];
    final rawSettings = remote[settingsField];
    final remoteSettings =
        rawSettings is Map ? rawSettings : const <String, dynamic>{};

    request.metadata.forEach((key, value) {
      if (protectedFields.contains(key) || key.startsWith('$settingsField.')) {
        refused.add('metadata may not write "$key"');
      } else {
        updates[key] = value;
      }
    });

    request.changedEntries.forEach((id, entry) {
      if (id.isEmpty) {
        refused.add('empty exercise id');
        return;
      }
      if (entry.isEmpty) {
        refused.add('empty settings for $id');
        return;
      }
      final base = remoteSettings[id];
      final merged = <String, dynamic>{
        if (base is Map) ...Map<String, dynamic>.from(base),
        ...entry,
      }..remove('explicitRepTargets');
      updates[FieldPath([settingsField, id])] = merged;
    });

    for (final id in request.removedIds) {
      if (request.changedEntries.containsKey(id)) continue;
      if (remoteSettings.containsKey(id)) {
        updates[FieldPath([settingsField, id])] = FieldValue.delete();
      }
    }

    final membership = request.membership;
    if (membership != null) {
      if (membership.isEmpty &&
          (_nonEmptyList(remote['exercises']) ||
              _nonEmptyList(remote['plannedExercises']))) {
        refused.add('empty exercise list over a populated block');
      } else {
        updates['exercises'] = membership;
        updates['plannedExercises'] = membership;
      }
    }

    final excluded = request.excludedExerciseIds;
    if (excluded != null) {
      if (request.visibleExerciseCount <= 0) {
        refused.add('exclusions would hide every exercise');
      } else {
        updates['excludedExerciseIds'] = excluded;
      }
    }

    return BlockSavePlan(updates, refused);
  }

  /// Re-reads [ref] on the server and applies [plan]'s updates in one
  /// transaction. A missing document is never created here.
  static Future<BlockSavePlan> commit({
    required FirebaseFirestore db,
    required DocumentReference<Map<String, dynamic>> ref,
    required BlockSaveRequest request,
  }) {
    return db.runTransaction<BlockSavePlan>((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) {
        return const BlockSavePlan({}, ['block document does not exist']);
      }
      final result = plan(remote: snap.data() ?? const {}, request: request);
      if (!result.isEmpty) txn.update(ref, result.updates);
      return result;
    });
  }
}
