// lib/local_cache/autosave_queue_db.dart
import 'dart:convert';
import 'package:isar/isar.dart';
import 'isar_db.dart';

part 'autosave_queue_db.g.dart';

@collection
class AutosaveJob {
  Id id = Isar.autoIncrement;

  // Natural addressing for dedupe/metrics
  late String uid;       // selected/acting athlete uid
  late String dateKey;   // yyyy-MM-dd
  String? blockId;

  // Control flags
  late bool alsoPushToBB2;
  late bool markAllSaved;

  // Snapshot → everything worker needs; store as compact JSON
  late String snapshotJson;

  // Bookkeeping
  int attempts = 0;
  String status = 'pending'; // pending | running | done | failed
  String? lastError;
  DateTime createdAt = DateTime.now();
  DateTime? updatedAt;
}

@collection
class LastSaveHash {
  Id id = Isar.autoIncrement;

  late String uid;
  late String dateKey;       // yyyy-MM-dd
  late String lastHash;      // payload content hash
  DateTime updatedAt = DateTime.now();
}

class AutosaveQueueDb {
  static Future<Isar> _open() async => await IsarDb.instance;

  static Future<int> enqueue({
    required String uid,
    required String dateKey,
    String? blockId,
    required bool alsoPushToBB2,
    required bool markAllSaved,
    required Map<String, dynamic> snapshot,
  }) async {
    final isar = await _open();
    final job = AutosaveJob()
      ..uid = uid
      ..dateKey = dateKey
      ..blockId = blockId
      ..alsoPushToBB2 = alsoPushToBB2
      ..markAllSaved = markAllSaved
      ..snapshotJson = jsonEncode(snapshot)
      ..status = 'pending'
      ..attempts = 0
      ..createdAt = DateTime.now();

    int newId = 0;
    await isar.writeTxn(() async {
      newId = await isar.autosaveJobs.put(job);
    });
    return newId;
  }

  static Future<AutosaveJob?> takeNextPending() async {
    final isar = await _open();
    return await isar.autosaveJobs
        .filter()
        .statusEqualTo('pending')
        .sortByCreatedAt()      // FIFO
        .build()
        .findFirst();
  }

  static Future<void> markRunning(AutosaveJob j) async {
    final isar = await _open();
    j.status = 'running';
    j.attempts += 1;
    j.updatedAt = DateTime.now();
    await isar.writeTxn(() async => await isar.autosaveJobs.put(j));
  }

  static Future<void> markDone(AutosaveJob j) async {
    final isar = await _open();
    j.status = 'done';
    j.updatedAt = DateTime.now();
    await isar.writeTxn(() async => await isar.autosaveJobs.put(j));
  }

  static Future<void> markFailed(AutosaveJob j, String err) async {
    final isar = await _open();
    j.status = 'failed';
    j.lastError = err;
    j.updatedAt = DateTime.now();
    await isar.writeTxn(() async => await isar.autosaveJobs.put(j));
  }

  static Future<String?> getLastHash({required String uid, required String dateKey}) async {
    final isar = await _open();
    final rec = await isar.lastSaveHashs
        .filter()
        .uidEqualTo(uid)
        .and()
        .dateKeyEqualTo(dateKey)
        .findFirst();
    return rec?.lastHash;
  }

  static Future<void> putLastHash({
    required String uid,
    required String dateKey,
    required String lastHash,
  }) async {
    final isar = await _open();
    final rec = LastSaveHash()
      ..uid = uid
      ..dateKey = dateKey
      ..lastHash = lastHash
      ..updatedAt = DateTime.now();
    await isar.writeTxn(() async => await isar.lastSaveHashs.put(rec));
  }
}
