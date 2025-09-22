// lib/local_cache/block_plan_cache.dart
import 'dart:convert';

import 'package:isar/isar.dart';
import 'isar_db.dart';
import 'isar_block_plan.dart';

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
}
