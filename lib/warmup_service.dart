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

  Future<void> warmWES(String uid, {String? activeBlockId, DateTime? selectedDate}) async {

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
      selectedDate: selectedDate,
      warmAthlete: !athFresh,
      warmExercises: !exFresh,
    ));

  }

  Future<void> doWarmWES(
      String uid, {
        String? activeBlockId,
        DateTime? selectedDate,
        bool warmAthlete = true,
        bool warmExercises = true,
      }) async {

    try {
      final fs = FirebaseFirestore.instance;
      Future<void> _warmWorkoutShapesForDate(DateTime d) async {
        String _ymd(DateTime dt) {
          final m = dt.month.toString().padLeft(2, '0');
          final day = dt.day.toString().padLeft(2, '0');
          return '${dt.year}-$m-$day';
        }

        final workouts = fs.collection('users').doc(uid).collection('workouts');
        final startOfDay = DateTime(d.year, d.month, d.day);
        final nextDay = startOfDay.add(const Duration(days: 1));
        final dateOnly = _ymd(d);
        final nextDateOnly = _ymd(nextDay);
        final isoLocal = startOfDay.toIso8601String(); // …T00:00:00.000
        final isoUtc   = DateTime.utc(startOfDay.year, startOfDay.month, startOfDay.day).toIso8601String(); // …Z

        // New-style doc by ID
        unawaited(workouts.doc(dateOnly).get(const GetOptions(source: Source.server)));

        // Legacy string equals (3 forms)
        unawaited(workouts.where('date', isEqualTo: isoLocal).get(const GetOptions(source: Source.server)));
        unawaited(workouts.where('date', isEqualTo: isoUtc).get(const GetOptions(source: Source.server)));
        unawaited(workouts.where('date', isEqualTo: dateOnly).get(const GetOptions(source: Source.server)));

        // Legacy string range (captures ISO strings with time-of-day)
        unawaited(workouts
            .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
            .where('date', isLessThan: '${nextDateOnly}T00:00:00')
            .get(const GetOptions(source: Source.server)));

        // Legacy timestamp day-range
        unawaited(workouts
            .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
            .where('date', isLessThan: Timestamp.fromDate(nextDay))
            .get(const GetOptions(source: Source.server)));
      }


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
          if (selectedDate != null) DateTime(selectedDate.year, selectedDate.month, selectedDate.day),
        ];

        // Warm yesterday/today/tomorrow (+ selectedDate if provided), across all legacy/new shapes
        for (final d in days) {
          _warmWorkoutShapesForDate(d);
        }

        // Warm recent workouts LIST (unchanged)


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
