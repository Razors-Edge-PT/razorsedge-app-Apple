import 'dart:convert';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'isar_db.dart';

part 'workout_day_cache.g.dart';

@collection
class WorkoutDayCache {
  Id id = Isar.autoIncrement;

  @Index(composite: [CompositeIndex('dateKey')], unique: false, caseSensitive: true)
  late String uid;

  /// e.g. '2025-09-23'
  @Index()
  late String dateKey;

  /// JSON blobs to avoid schema churn
  late String exListJson;        // exercises[] (saved)
  late String wesPlannedJson;    // wesPlannedExercises[]

  DateTime? updatedAt;
}

class WorkoutCacheDb {
  static Isar? _isar;

  static Future<Isar> _open() async {
    if (_isar != null) return _isar!;
    _isar = await IsarDb.instance; // <-- reuse the unified singleton
    return _isar!;
  }


  static Future<Map<String, dynamic>?> getDay({
    required String uid,
    required String dateKey,
  }) async {
    final isar = await _open();
    final rec = await isar.workoutDayCaches
        .where()
        .filter()
        .uidEqualTo(uid)
        .and()
        .dateKeyEqualTo(dateKey)
        .findFirst();
    if (rec == null) return null;
    return {
      'exList': List<Map<String, dynamic>>.from(jsonDecode(rec.exListJson) as List),
      'wesPlanned': List<Map<String, dynamic>>.from(jsonDecode(rec.wesPlannedJson) as List),
      'updatedAt': rec.updatedAt,
    };
  }

  static Future<void> putDay({
    required String uid,
    required String dateKey,
    required List<Map<String, dynamic>> exList,
    required List<Map<String, dynamic>> wesPlanned,
    DateTime? updatedAt,
  }) async {
    final isar = await _open();
    final rec = WorkoutDayCache()
      ..uid = uid
      ..dateKey = dateKey
      ..exListJson = jsonEncode(exList)
      ..wesPlannedJson = jsonEncode(wesPlanned)
      ..updatedAt = updatedAt ?? DateTime.now();

    await isar.writeTxn(() => isar.workoutDayCaches.put(rec));
  }
}
