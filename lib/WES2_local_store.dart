import 'dart:convert';
import 'package:isar_community/isar.dart';
import 'local_cache/isar_db.dart';
import 'local_cache/isar_claude_bullet_snapshot.dart';
import 'WES2_models.dart';

// Phase 1 stub interface.
// All cache keys include uid + date to prevent cross-user contamination.
abstract class Wes2LocalStore {
  /// Persist a day draft snapshot keyed by uid + date.
  Future<void> saveDraft({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  });

  /// Load the most recent local draft for uid + date, or null if none.
  Future<List<Wes2ExerciseRow>?> loadDraft({
    required String uid,
    required DateTime date,
  });

  /// Save per-device expanded/collapsed state keyed by uid + date.
  Future<void> saveExpandedState({
    required String uid,
    required DateTime date,
    required Map<String, bool> expandedByExerciseId,
  });

  /// Load per-device expanded/collapsed state.
  Future<Map<String, bool>> loadExpandedState({
    required String uid,
    required DateTime date,
  });

  /// Save the last locally edited exerciseId + setIndex for scroll restore.
  Future<void> saveScrollAnchor({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
  });

  /// Load the last locally edited scroll anchor, or null if none.
  Future<({String exerciseId, int setIndex})?> loadScrollAnchor({
    required String uid,
    required DateTime date,
  });

  /// Queue a workout save for deferred offline sync.
  Future<void> enqueueOfflineSave({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    required DateTime localEditedAt,
  });

  /// Remove a queued offline save after successful Firestore sync.
  Future<void> dequeueOfflineSave({
    required String uid,
    required DateTime date,
  });
}

/// Concrete implementation backed by the existing ClaudeBulletSnapshot Isar
/// collection. WES2 records are namespaced with the prefix "wes2_" so they
/// never conflict with WES1 ClaudeBulletSnapshot entries.
///
/// Key format: "wes2_${actingUid}_${yyyy-MM-dd}"
///
/// Only reads/writes records whose uidDateKey starts with "wes2_".
class IsarWes2LocalStore implements Wes2LocalStore {
  static const String _prefix = 'wes2_';

  static String _key(String uid, DateTime date) {
    final ymd = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return '$_prefix${uid}_$ymd';
  }

  @override
  Future<void> saveDraft({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  }) async {
    final key = _key(uid, date);
    // Guard: never write to a non-wes2_ key.
    assert(key.startsWith(_prefix), 'WES2 draft key must start with $_prefix');

    final ymd = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final payload = jsonEncode({
      'schemaVersion': 1,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'exercises': rows.map((r) => r.toJson()).toList(),
    });

    final isar = await IsarDb.instance;
    final snap = ClaudeBulletSnapshot()
      ..uidDateKey = key
      ..dateYmd = ymd
      ..snapshotJson = payload
      ..lastEditedAt = DateTime.now().millisecondsSinceEpoch;
    // ClaudeBulletSnapshot has @Index(unique: true, replace: true) on
    // uidDateKey, so put() upserts cleanly.
    await isar.writeTxn(() => isar.claudeBulletSnapshots.put(snap));
  }

  @override
  Future<List<Wes2ExerciseRow>?> loadDraft({
    required String uid,
    required DateTime date,
  }) async {
    final key = _key(uid, date);
    // Guard: only read wes2_ records.
    if (!key.startsWith(_prefix)) return null;

    final isar = await IsarDb.instance;
    final snap = await isar.claudeBulletSnapshots
        .filter()
        .uidDateKeyEqualTo(key)
        .findFirst();

    if (snap == null) return null;
    // Double-check the retrieved record is a WES2 record.
    if (!snap.uidDateKey.startsWith(_prefix)) return null;

    try {
      final decoded = jsonDecode(snap.snapshotJson) as Map<String, dynamic>;
      final exercises = decoded['exercises'] as List<dynamic>;
      return exercises
          .map((e) => Wes2ExerciseRow.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupt or incompatible snapshot — treat as absent.
      return null;
    }
  }

  // ── Stub implementations (not needed in Phase 7) ─────────────────────────

  @override
  Future<void> saveExpandedState({
    required String uid,
    required DateTime date,
    required Map<String, bool> expandedByExerciseId,
  }) async {}

  @override
  Future<Map<String, bool>> loadExpandedState({
    required String uid,
    required DateTime date,
  }) async =>
      const {};

  @override
  Future<void> saveScrollAnchor({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
  }) async {}

  @override
  Future<({String exerciseId, int setIndex})?> loadScrollAnchor({
    required String uid,
    required DateTime date,
  }) async =>
      null;

  @override
  Future<void> enqueueOfflineSave({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
    required DateTime localEditedAt,
  }) async {}

  @override
  Future<void> dequeueOfflineSave({
    required String uid,
    required DateTime date,
  }) async {}
}
