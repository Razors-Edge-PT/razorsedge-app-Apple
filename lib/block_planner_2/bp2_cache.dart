/// Athlete-partitioned key/value cache used by Block Planner 2.
///
/// The store is a tiny abstraction over Isar so the sync layer and controller
/// can be unit tested against [Bp2MemoryCacheStore] without a native Isar
/// binary. Production uses [Bp2IsarCacheStore], which reuses the app's single
/// Isar instance (`IsarDb`).
library;

import '../local_cache/isar_db.dart';
import '../local_cache/isar_planner_cache.dart';

abstract class Bp2CacheStore {
  Future<String?> read(String uid, String key);
  Future<void> write(String uid, String key, String json);
  Future<void> delete(String uid, String key);
}

/// In-memory store for tests and as a safe fallback when Isar cannot open.
class Bp2MemoryCacheStore implements Bp2CacheStore {
  final Map<String, String> _data = {};

  /// Number of writes performed (tests assert "no write when unchanged").
  int writes = 0;

  String _k(String uid, String key) => '$uid|$key';

  @override
  Future<String?> read(String uid, String key) async => _data[_k(uid, key)];

  @override
  Future<void> write(String uid, String key, String json) async {
    writes++;
    _data[_k(uid, key)] = json;
  }

  @override
  Future<void> delete(String uid, String key) async {
    _data.remove(_k(uid, key));
  }

  Iterable<String> keysFor(String uid) => _data.keys
      .where((k) => k.startsWith('$uid|'))
      .map((k) => k.substring(uid.length + 1));
}

class Bp2IsarCacheStore implements Bp2CacheStore {
  @override
  Future<String?> read(String uid, String key) async {
    final isar = await IsarDb.instance;
    final rec =
        await isar.plannerCacheRecords.get(plannerCacheRecordId(uid, key));
    if (rec == null || rec.uid != uid || rec.key != key) return null;
    return rec.json;
  }

  @override
  Future<void> write(String uid, String key, String json) async {
    final isar = await IsarDb.instance;
    final rec = PlannerCacheRecord()
      ..id = plannerCacheRecordId(uid, key)
      ..uid = uid
      ..key = key
      ..json = json
      ..cachedAt = DateTime.now();
    await isar.writeTxn(() => isar.plannerCacheRecords.put(rec));
  }

  @override
  Future<void> delete(String uid, String key) async {
    final isar = await IsarDb.instance;
    await isar.writeTxn(
        () => isar.plannerCacheRecords.delete(plannerCacheRecordId(uid, key)));
  }
}
