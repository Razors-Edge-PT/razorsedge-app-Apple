import 'package:isar_community/isar.dart';

part 'isar_planner_cache.g.dart';

/// Generic athlete-scoped JSON cache record used by Block Planner 2.
///
/// One row per `(uid, key)`; the Isar id is a stable FNV-1a hash of that pair
/// so reads are single-key lookups. Everything the planner caches (catalogue
/// snapshots, block summaries, settings, durable drafts) is partitioned by the
/// selected-athlete UID through [uid].
@collection
class PlannerCacheRecord {
  Id id = Isar.autoIncrement;

  @Index()
  late String uid;

  late String key;

  late String json;

  DateTime cachedAt = DateTime.now();
}

Id plannerCacheRecordId(String uid, String key) {
  final s = '$uid|$key';
  int hash = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    hash ^= c;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash;
}
