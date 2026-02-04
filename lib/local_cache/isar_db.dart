// lib/local_cache/isar_db.dart
import 'dart:io';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'isar_wes_init.dart';
import 'workout_day_cache.dart'; // <-- brings in WorkoutDayCacheSchema
import 'autosave_queue_db.dart'; // ← ADD
// ADD THIS IMPORT near your other local_cache imports
import 'isar_bb2_merged_day.dart';
import 'isar_claude_bullet_snapshot.dart';




import 'isar_block_plan.dart';

class IsarDb {
  static Isar? _isar;

  /// Get the singleton Isar instance (opens on first call).
  static Future<Isar> get instance async {
    if (_isar != null) return _isar!;
    final dir = Platform.isIOS || Platform.isAndroid
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();

    // If already open (hot reload), reuse
    final existing = Isar.getInstance();
    if (existing != null) {
      _isar = existing;
      return _isar!;
    }

    _isar = await Isar.open(
      [
        BlockDaySchema,
        WESInitSnapshotSchema,
        WorkoutDayCacheSchema,
        AutosaveJobSchema,
        LastSaveHashSchema,
        BB2MergedDaySchema, // ← ADD
        ClaudeBulletSnapshotSchema,
      ],

      directory: dir.path,
      inspector: false,      // set true if you want Isar Inspector in dev
      name: 'app_isar',      // optional DB name
    );
    return _isar!;

  }

  /// Optional: close on logout / app exit
  static Future<void> close() async {
    final isar = _isar ?? Isar.getInstance();
    if (isar != null) {
      await isar.close();
    }

    _isar = null;
  }
}
