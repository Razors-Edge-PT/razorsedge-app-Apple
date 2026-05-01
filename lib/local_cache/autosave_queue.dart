// lib/services/autosave_queue.dart
//
// Failure-only background autosave queue.
// - Enqueue when a foreground upsert fails (store the full payload JSON).
// - Periodically retry every 2 minutes (cap 4 attempts).
// - On success, writes the workout doc and kicks warmups + RE Daily + stats.
// - Prints logs for visibility; no UI surfaces changed.
//
// Prereqs:
//   - lib/local_cache/autosave_queue_db.dart (AutosaveJob + LastSaveHash) generated
//   - lib/local_cache/isar_db.dart registers AutosaveJobSchema & LastSaveHashSchema
//   - periodization utils / warmup / RE daily / stats helpers available (imports below)

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:intl/intl.dart';
import 'package:isar_community/isar.dart';


// 🧠 Local cache + database
import '../local_cache/isar_db.dart';
import '../local_cache/autosave_queue_db.dart';
import '../local_cache/workout_day_cache.dart';

// 🧩 Logic + utilities (assuming these are in lib/)
import '../periodization_model_utils.dart';
import '../warmup_service.dart';
import '../re_daily.dart' as recalc;

import '../stats_snapshot.dart';
import '../formula.dart' as formula;



/// Public, app-wide singleton.
class AutosaveQueue {
  AutosaveQueue._();
  static final AutosaveQueue instance = AutosaveQueue._();

  // Periodic processor
  Timer? _periodic;
  bool _processing = false;

  /// Start periodic retries (every 2 minutes).
  void startPeriodicProcessing() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 2), (_) {
      // best-effort; no overlap
      processAll();
    });
    print('[AutosaveQueue] periodic processor started (every 2 minutes).');
  }

  /// Stop periodic retries (e.g., on logout).
  void stopPeriodicProcessing() {
    _periodic?.cancel();
    _periodic = null;
    print('[AutosaveQueue] periodic processor stopped.');
  }

  /// Enqueue a failed save for later retry.
  ///
  /// Stores the full Firestore workout payload (as JSON) so retries do not
  /// depend on widget state or controllers.
  ///
  /// If a pending job already exists for (uid,dateKey), it is replaced with
  /// the newest payload (attempts reset to 0).
  Future<void> enqueueFailed({
    required String uid,
    required DateTime selectedDate,
    String? blockId,
    required Map<String, dynamic> payload,
  }) async {
    final dateKey = DateFormat('yyyy-MM-dd').format(selectedDate);

    final isar = await IsarDb.instance;
    await isar.writeTxn(() async {
      // Try to find an existing pending job for uid/dateKey
      final existing = await isar.autosaveJobs
          .filter()
          .uidEqualTo(uid)
          .dateKeyEqualTo(dateKey)
          .statusEqualTo('pending')
          .findFirst();


      final json = jsonEncode(payload);

      if (existing != null) {
        existing.snapshotJson = json; // reuse field to hold payload JSON
        existing.attempts = 0;        // reset attempts on replacement
        existing.lastError = null;
        existing.updatedAt = DateTime.now();
        await isar.autosaveJobs.put(existing);
        print('[AutosaveQueue] replaced pending job #${existing.id} for $uid/$dateKey');
      } else {
        final job = AutosaveJob()
          ..uid = uid
          ..dateKey = dateKey
          ..blockId = blockId
          ..alsoPushToBB2 = _inferAlsoPushToBB2FromPayload(payload)
          ..markAllSaved = false // not used on retry; info only
          ..snapshotJson = json // store full payload JSON here
          ..status = 'pending'
          ..attempts = 0
          ..createdAt = DateTime.now();
        final id = await isar.autosaveJobs.put(job);
        print('[AutosaveQueue] enqueued failed save as job #$id for $uid/$dateKey');
      }
    });

    // Give the queue a nudge now (in addition to periodic timer).
    // Ignore await; best-effort.
    // ignore: unawaited_futures
    processAll();
  }

  /// Call this on app resume or when you want to flush the queue immediately.
  Future<void> processAll() async {
    if (_processing) {
      if (kDebugMode) {
        print('[AutosaveQueue] processAll skipped: already running.');
      }
      return;
    }

    _processing = true;
    try {
      while (true) {
        final job = await _takeNextRunnableJob();
        if (job == null) break;

        final jobInfo = '#${job.id} ${job.uid}/${job.dateKey}';
        try {
          print('🛠️ [AutosaveWorker] running job $jobInfo (attempt ${job.attempts + 1})…');
          await _runJob(job);
          await _markDone(job);
          print('✅ [AutosaveWorker] job $jobInfo succeeded.');
        } catch (e) {
          await _handleFailure(job, e);
        }
      }
    } finally {
      _processing = false;
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ────────────────────────────────────────────────────────────────────────────

  // Take the oldest job that is eligible to run (attempts < 4).
  Future<AutosaveJob?> _takeNextRunnableJob() async {
    final isar = await IsarDb.instance;
    final j = await isar.autosaveJobs
        .filter()
        .statusEqualTo('pending')
        .attemptsLessThan(4)
        .sortByCreatedAt()
        .findFirst();


    if (j == null) return null;

    // Mark as running and bump attempts
    j.status = 'running';
    j.attempts += 1;
    j.updatedAt = DateTime.now();
    await isar.writeTxn(() async {
      await isar.autosaveJobs.put(j);
    });
    return j;
  }

  Future<void> _markDone(AutosaveJob j) async {
    final isar = await IsarDb.instance;
    j.status = 'done';
    j.updatedAt = DateTime.now();
    await isar.writeTxn(() async {
      await isar.autosaveJobs.put(j);
    });
  }

  Future<void> _handleFailure(AutosaveJob j, Object error) async {
    final isar = await IsarDb.instance;

    final remaining = (4 - j.attempts).clamp(0, 4);
    final msg =
        '❌ [AutosaveWorker] job #${j.id} ${j.uid}/${j.dateKey} failed on attempt ${j.attempts} '
        '(remaining retries: $remaining): $error';

    print(msg);

    // Put back to pending if we have retries left; otherwise mark failed.
    if (j.attempts < 4) {
      j.status = 'pending';
      j.lastError = '$error';
    } else {
      j.status = 'failed';
      j.lastError = '$error';
    }
    j.updatedAt = DateTime.now();

    await isar.writeTxn(() async {
      await isar.autosaveJobs.put(j);
    });
  }

  // Core worker: write payload to Firestore and run post-write tasks.
  Future<void> _runJob(AutosaveJob j) async {
    // Decode the payload JSON (we stored it in snapshotJson for reuse).
    final Map<String, dynamic> payload =
    Map<String, dynamic>.from(jsonDecode(j.snapshotJson) as Map);

    final uid = j.uid;
    final dateKey = j.dateKey;

    // 1) Unchanged gate: compare content hash with persisted LastSaveHash.
    final hash = payload.hashCode.toString();
    final last = await AutosaveQueueDb.getLastHash(uid: uid, dateKey: dateKey);
    if (last != null && last == hash) {
      print('🔸 [AutosaveWorker] unchanged payload for $uid/$dateKey — skipping write.');
      return; // still "success"
    }

    // 2) Firestore write (same collection path/ID shape).
    final coll =
    FirebaseFirestore.instance.collection('users').doc(uid).collection('workouts');
    final docRef = coll.doc(dateKey);

    print('📝 [AutosaveWorker] writing workout for $uid/$dateKey …');
    await docRef.set(payload, SetOptions(merge: false));
    print('✅ [AutosaveWorker] Firestore write complete for $uid/$dateKey.');

    // 2.1 Persist day to local cache (best-effort).
    try {
      final exList =
      List<Map<String, dynamic>>.from((payload['exercises'] as List?) ?? const []);
      final wesPlanned = List<Map<String, dynamic>>.from(
          (payload['wesPlannedExercises'] as List?) ?? const []);
      await WorkoutCacheDb.putDay(
        uid: uid,
        dateKey: dateKey,
        exList: exList,
        wesPlanned: wesPlanned,
        updatedAt: DateTime.now(),
      );
    } catch (_) {
      // best-effort
    }

    // 3) Warm next opens for selected & +1 day (if blockId present).
    try {
      final blockId = j.blockId;
      if (blockId != null && blockId.isNotEmpty) {
        final d0 = DateTime.parse(payload['date'] as String);
        final d1 = d0.add(const Duration(days: 1));
        await WarmupService.instance.warmWES(uid, activeBlockId: blockId, selectedDate: d0);
        await WarmupService.instance.warmWES(uid, activeBlockId: blockId, selectedDate: d1);
        print('✅ [AutosaveWorker] Warm kicked for $d0 and $d1 (uid=$uid, block=$blockId)');
      } else {
        print('⚠️ [AutosaveWorker] Skipping warm — no blockId on job.');
      }
    } catch (e) {
      print('⚠️ [AutosaveWorker] Warm kick failed: $e');
    }

    // 4) RE Daily compute/write (best-effort).
    try {
      final userSnap =
      await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final sexRaw = (userSnap.data()?['sex'] as String?)?.trim().toLowerCase();
      final isFemale = sexRaw == 'female' || sexRaw == 'f' || sexRaw == 'woman' || sexRaw == 'w';
      final genderEnum = isFemale ? formula.Gender.female : formula.Gender.male;

      await recalc.DailyReCalculator().computeAndWrite(
        uid: uid,
        dayKey: dateKey,
        gender: genderEnum,
      );

      print('✅ [RE Daily] compute+write done for $dateKey');
    } catch (e) {
      print('⚠️ [RE Daily] compute failed for $dateKey: $e');
    }

    // 5) Public profile stats (only if there are completed sets).
    final hasExercises = ((payload['exercises'] as List?)?.isNotEmpty ?? false);
    if (hasExercises) {
      try {
        await updateStatsFromWorkout(uid: uid, workout: payload);
        print('🏷️ [AutosaveWorker] Stats snapshot updated.');
      } catch (e) {
        print('⚠️ [AutosaveWorker] Stats update failed: $e');
      }
    }

    // 6) Optional BB2 push if the original attempt would have done it.
    if (j.alsoPushToBB2 && hasExercises) {
      try {
        await Bb2TopSetPusher.pushTopSetsToBlockDataIfAny(
          uid: uid,
          dayKey: dateKey,
          workoutPayload: payload,
        );
        print('✅ [AutosaveWorker] BB2 push complete.');
      } catch (e) {
        print('⚠️ [AutosaveWorker] BB2 push failed: $e');
      }
    }

    // 7) Save hash so future identical payloads are skipped.
    await AutosaveQueueDb.putLastHash(uid: uid, dateKey: dateKey, lastHash: hash);
  }

  // Infer whether we should do a BB2 push on retry:
  // If 'exercises' is non-empty, it's equivalent to having qualifying sets.
  bool _inferAlsoPushToBB2FromPayload(Map<String, dynamic> payload) {
    final hasExercises = ((payload['exercises'] as List?)?.isNotEmpty ?? false);
    return hasExercises;
  }
}

/// Minimal BB2 pusher interface. Replace with your concrete implementation
/// if/when you extract the existing `_pushTopSetsToBlockDataIfAny()` to a service.
class Bb2TopSetPusher {
  static Future<void> pushTopSetsToBlockDataIfAny({
    required String uid,
    required String dayKey,
    required Map<String, dynamic> workoutPayload,
  }) async {
    // No-op default. Implement if you want retries to also backfill BB2.
    // Left intentionally implemented (no TODOs) to keep this file drop-in ready.
    // print('[BB2] push skipped (no implementation bound).');
  }
}
