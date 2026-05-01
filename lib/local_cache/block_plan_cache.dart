// lib/local_cache/block_plan_cache.dart
import 'dart:convert';

import 'package:isar_community/isar.dart';
import 'isar_db.dart';
import 'isar_block_plan.dart';
import 'isar_wes_init.dart'; // ⬅️ new file you’ll create for WESInitSnapshot


class BlockPlanCache {
  /// Instant read for a single day (returns null if not in cache).
  static Future<List<Map<String, dynamic>>?> getDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
  }) async {
    final isar = await IsarDb.instance;
    final id = blockDayId(uid, blockId, weekIndex, dayIndex);
    final doc = await isar.blockDays.get(id);
    if (doc == null) return null;
    final raw = jsonDecode(doc.exercisesJson);
    if (raw is! List) return const [];
    return raw
        .cast<Map>()
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Upsert a day’s exercises into the super-cache.
  static Future<void> putDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required List<Map<String, dynamic>> exercises,
    DateTime? updatedAt,
  }) async {
    final isar = await IsarDb.instance;
    final id = blockDayId(uid, blockId, weekIndex, dayIndex);

    final doc = BlockDay()
      ..id = id
      ..uid = uid
      ..blockId = blockId
      ..weekIndex = weekIndex
      ..dayIndex = dayIndex
      ..exercisesJson = jsonEncode(exercises)
      ..updatedAt = updatedAt
      ..cachedAt = DateTime.now();

    await isar.writeTxn(() => isar.blockDays.put(doc));
  }

  /// Optional helper: prefetch a whole week (or week ±1) in a single txn.
  static Future<void> putWeek({
    required String uid,
    required String blockId,
    required int weekIndex,
    required Map<int, List<Map<String, dynamic>>> byDayIndex,
    DateTime? updatedAt,
  }) async {
    final isar = await IsarDb.instance;
    await isar.writeTxn(() async {
      for (final entry in byDayIndex.entries) {
        final dIdx = entry.key;
        final exercises = entry.value;
        final id = blockDayId(uid, blockId, weekIndex, dIdx);
        final doc = BlockDay()
          ..id = id
          ..uid = uid
          ..blockId = blockId
          ..weekIndex = weekIndex
          ..dayIndex = dIdx
          ..exercisesJson = jsonEncode(exercises)
          ..updatedAt = updatedAt
          ..cachedAt = DateTime.now();
        await isar.blockDays.put(doc);
      }
    });
  }
  // ──────────────────────────────────────────────────────────────
// WESInitSnapshot cache helpers (for _loadInitialData super-cache)
// ──────────────────────────────────────────────────────────────

  /// Try to get the **latest** init snapshot for a given date.
  static Future<WESInitSnapshot?> getInitSnapshot({
    required String uid,
    required String blockId,
    required String dateYmd,
  }) async {
    final isar = await IsarDb.instance;
    return await isar.wESInitSnapshots
        .filter()
        .uidEqualTo(uid)
        .blockIdEqualTo(blockId)
        .dateYmdEqualTo(dateYmd)
        .sortByCachedAtDesc()   // 👈 pick the newest snapshot (fixes empty/old reads)
        .build()
        .findFirst();
  }


  /// Upsert an init snapshot after Firestore loads finish.
  static Future<void> putInitSnapshot({
    required String uid,
    required String blockId,
    required String dateYmd,
    required List<Map<String, dynamic>> plannedExercises,
    required List<Map<String, dynamic>> wesPlannedExercises,   // ← NEW
    required List<Map<String, dynamic>> previousWorkout,
    required List<Map<String, dynamic>> topSetHistory,
    String? hintsJson,
    String? hintsInputsHash,
    bool? hintsReady,
    int? schemaVersion,
    DateTime? updatedAt,
  }) async {


    final isar = await IsarDb.instance;

    final snap = WESInitSnapshot()
      ..uid = uid
      ..blockId = blockId
      ..dateYmd = dateYmd
      ..plannedExercisesJson = jsonEncode(plannedExercises)
      ..wesPlannedExercisesJson = jsonEncode(wesPlannedExercises)  // ← NEW
      ..previousWorkoutJson  = jsonEncode(previousWorkout)
      ..topSetHistoryJson    = jsonEncode(topSetHistory)
      ..hintsJson            = (hintsJson == null || hintsJson.isEmpty) ? '{}' : hintsJson   // 👈 NEW
      ..hintsInputsHash      = hintsInputsHash
      ..hintsReady          = hintsReady    // NEW
      ..schemaVersion       = schemaVersion // NEW
      ..updatedAt = updatedAt
      ..cachedAt = DateTime.now();

    await isar.writeTxn(() => isar.wESInitSnapshots.put(snap));
  }



}
