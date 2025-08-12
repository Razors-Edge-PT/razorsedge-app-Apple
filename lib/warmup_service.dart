// warmup_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WarmupService {
  WarmupService._();
  static final instance = WarmupService._();

  static const _cooldown = Duration(hours: 3);
  static const int _workoutWarmLimit = 150;
  static const int _exerciseWarmLimit = 2000;

  Future<void> warmWES(String uid, {String? activeBlockId}) async {
    if (uid.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Per-athlete cooldown
    final keyAth = 'wes_warm_last:$uid';
    final lastAth = prefs.getInt(keyAth);
    final athFresh = lastAth != null && (now - lastAth) < _cooldown.inMilliseconds;
    if (!athFresh) await prefs.setInt(keyAth, now);

    // Global cooldown for static exercises
    final keyEx = 'wes_warm_exercises_last';
    final lastEx = prefs.getInt(keyEx);
    final exFresh = lastEx != null && (now - lastEx) < _cooldown.inMilliseconds;
    if (!exFresh) await prefs.setInt(keyEx, now);

    // Fire-and-forget
    unawaited(doWarmWES(
      uid,
      activeBlockId: activeBlockId,
      warmAthlete: !athFresh,
      warmExercises: !exFresh,
    ));
  }

  Future<void> doWarmWES(
      String uid, {
        String? activeBlockId,
        bool warmAthlete = true,
        bool warmExercises = true,
      }) async {
    try {
      final fs = FirebaseFirestore.instance;

      if (warmAthlete) {
        String _ymd(DateTime d) {
          final m = d.month.toString().padLeft(2, '0');
          final day = d.day.toString().padLeft(2, '0');
          return '${d.year}-$m-$day';
        }

        final today = DateTime.now();
        final days = <DateTime>[
          today.add(const Duration(days: -1)),
          today,
          today.add(const Duration(days: 1)),
        ];

        // Warm yesterday/today/tomorrow workout docs
        for (final d in days) {
          unawaited(fs
              .collection('users').doc(uid)
              .collection('workouts').doc(_ymd(d))
              .get(const GetOptions(source: Source.server)));
        }

        // Warm recent workouts LIST
        unawaited(fs
            .collection('users').doc(uid)
            .collection('workouts')
            .orderBy('date', descending: true)
            .limit(_workoutWarmLimit)
            .get(const GetOptions(source: Source.server)));
      }

      if (warmExercises) {
        // Warm global exercises list
        unawaited(fs
            .collection('exercises')
            .orderBy('name')
            .limit(_exerciseWarmLimit)
            .get(const GetOptions(source: Source.server)));
      }

      // Warm planned blocks surface (small list)
      final blocksCol = fs.collection('planned_blocks').doc(uid).collection('blocks');
      final blocksSnap = await blocksCol
          .limit(5)
          .get(const GetOptions(source: Source.server));
      for (final b in blocksSnap.docs) {
        unawaited(blocksCol.doc(b.id).get(const GetOptions(source: Source.server)));
      }

      // ✅ NEW: explicitly warm the active block doc used by WES
      if (activeBlockId != null && activeBlockId.isNotEmpty) {
        unawaited(blocksCol
            .doc(activeBlockId)
            .get(const GetOptions(source: Source.server)));
      }
    } catch (_) {
      // best-effort
    }
  }
}
