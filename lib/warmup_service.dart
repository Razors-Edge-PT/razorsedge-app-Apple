// warmup_service.dart (or bottom of HomeScreen file)
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WarmupService {
  WarmupService._();
  static final instance = WarmupService._();

  // Cooldown (per-athlete) so we don’t spam reads
  static const _cooldown = Duration(hours: 3);

  Future<void> warmWES(String uid) async {
    if (uid.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final key = 'wes_warm_last:$uid';
    final lastMs = prefs.getInt(key);
    final now = DateTime.now().millisecondsSinceEpoch;

    if (lastMs != null && (now - lastMs) < _cooldown.inMilliseconds) {
      // Recently warmed; skip
      return;
    }
    // Stamp *before* starting so concurrent calls don’t pile up
    await prefs.setInt(key, now);

    // Fire-and-forget the actual warmup so Home doesn’t block
    unawaited(doWarmWES(uid));
  }

  Future<void> doWarmWES(String uid) async {
    try {
      final fs = FirebaseFirestore.instance;

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

      // Seed cache for yesterday/today/tomorrow workout docs
      for (final d in days) {
        final ref = fs.collection('users').doc(uid)
            .collection('workouts').doc(_ymd(d));
        unawaited(ref.get(const GetOptions(source: Source.server)));
      }

      // If you have lightweight lookups WES depends on, pre-warm them too:
      // e.g., planned exercises list:
      // unawaited(fs.collection('planned_blocks').doc(uid)
      //     .collection('blocks').get(const GetOptions(source: Source.server)));

    } catch (_) {
      // Silent fail; this is best-effort
    }
  }
}
