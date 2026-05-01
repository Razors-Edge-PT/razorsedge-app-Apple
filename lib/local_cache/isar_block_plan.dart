import 'package:isar_community/isar.dart';

part 'isar_block_plan.g.dart';

@collection
class BlockDay {
  // 👇 natural key (useful for ad-hoc lookups and debugging)
  late String uid;
  late String blockId;
  late int weekIndex;
  late int dayIndex;

  // Isar id – we’ll derive a stable hash from the key for single-key access
  Id id = Isar.autoIncrement;

  // JSON blob of exercises as produced by Firestore (List<Map> encoded to String)
  late String exercisesJson;     // compact json string
  DateTime? updatedAt;           // server/source updatedAt if available
  DateTime cachedAt = DateTime.now();
}

// Helpers to build a stable Id from key parts (fast single read)
Id blockDayId(String uid, String blockId, int weekIndex, int dayIndex) {
  // deterministic 64-bit-ish hash (very simple; replace with something else if you prefer)
  final s = '$uid|$blockId|$weekIndex|$dayIndex';
  // FNV-1a style
  int hash = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    hash ^= c;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash;
}
