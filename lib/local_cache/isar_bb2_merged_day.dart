import 'dart:convert';
import 'package:isar_community/isar.dart';

part 'isar_bb2_merged_day.g.dart';

@collection
class BB2MergedDay {
  // Natural key parts for ad-hoc lookups and debugging
  late String uid;
  late String blockId;
  late int weekIndex;
  late int dayIndex;

  // Isar id — stable hash of the natural key
  Id id = Isar.autoIncrement;

  /// Controller-ready rows (merged: planned + WES overrides, BW handling applied),
  /// encoded as a compact JSON string (List<Map<String, dynamic>>).
  late String mergedExercisesJson;

  /// Circuit header indices for this day (sorted, e.g., [0, 3, 7]).
  /// Stored as JSON to keep schema minimal/flexible.
  late String circuitStartIndicesJson; // e.g. "[0,3,7]"

  /// Optional hints payload (precomputed, already ready for UI),
  /// or "{}" if none/empty.
  late String hintsJson;

  /// Staleness / provenance
  DateTime? plannerUpdatedAt;   // from parent block doc (updatedAt)
  DateTime? workoutsUpdatedAt;  // latest savedAt/update time found in range
  DateTime cachedAt = DateTime.now();

  /// Schema & inputs hash allow BB2 to trust this cache without recomputing.
  int schemaVersion = 1;
  late String inputsHash; // deterministic hash of inputs (uid, blockId, week window, meta/wes stamps)
}

/// Stable 64-bit-ish hash used as the collection Id (same pattern you already use)
Id bb2MergedDayId(String uid, String blockId, int weekIndex, int dayIndex) {
  final s = '$uid|$blockId|$weekIndex|$dayIndex|bb2Merged';
  int hash = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    hash ^= c;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash;
}

/// Tiny helper to (de)serialize lists to JSON.
String _toJson(dynamic v) => jsonEncode(v);
List<dynamic> _fromJsonList(String s) {
  final raw = jsonDecode(s);
  return raw is List ? raw : const [];
}
