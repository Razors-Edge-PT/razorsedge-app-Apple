// lib/local_cache/isar_wes_init.dart
import 'package:isar/isar.dart';

part 'isar_wes_init.g.dart';

/// Compact snapshot to hydrate `_loadInitialData()` instantly on reopen.
/// Keep fields as JSON so we can evolve structure without schema churn.
@collection
class WESInitSnapshot {
  Id id = Isar.autoIncrement;

  // Natural key
  late String uid;           // athlete uid
  late String blockId;       // active block id
  late String dateYmd;       // e.g. "2025-09-23"

  // Highest-impact blobs (add more later if you want)
  late String plannedExercisesJson;   // from loadPlannedExercisesFromFirestore()
  late String previousWorkoutJson;    // from loadPreviousWorkoutData()
  late String topSetHistoryJson;      // from PeriodizationModelUtils.fetchFullTopSetHistory()
  // Pre-resolved S1 hints for instant first paint (JSON map: "name|ci" -> fields)
  // For non-BW: { "s1_weight": <kg>, "s1_reps": <int>, "s1_rir": <num>, "e1rm": <num> }
  // For BW:     { "s1_weight_added": <kg>, "s1_reps": <int>, "s1_rir": <num>, "e1rm": <num> }
  late String hintsJson;

  // Optional freshness fingerprint for recompute decisions (leave null if you don’t use it yet)
  String? hintsInputsHash;
  int? schemaVersion;   // NEW: snapshot contract version
  bool? hintsReady;     // NEW: signals hints are final for first paint


  // Optional freshness metadata
  DateTime? updatedAt;       // last time server data considered fresh
  DateTime cachedAt = DateTime.now();
}

/// Convenience helpers for single-key lookups & upserts.
/// (These live here so codegen can see the collection symbol names.)
extension WESInitSnapshotX on Isar {
  Future<WESInitSnapshot?> getWESInit({
    required String uid,
    required String blockId,
    required String dateYmd,
  }) async {
    return await wESInitSnapshots
        .filter()
        .uidEqualTo(uid)
        .and()
        .blockIdEqualTo(blockId)
        .and()
        .dateYmdEqualTo(dateYmd)
        .findFirst();
  }

  Future<void> putWESInit(WESInitSnapshot s) async {
    await writeTxn(() async {
      await wESInitSnapshots.put(s);
    });
  }
}
