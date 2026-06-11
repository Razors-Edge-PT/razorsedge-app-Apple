import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Calendar day state for the HomeScreen2 training calendar.
enum HomeV2CalendarDayKind {
  /// No training planned and no workout completed.
  none,
  /// Training is planned but no completed workout found.
  planned,
  /// A workout was completed but this was not a scheduled training day.
  completed,
  /// Training was planned AND a workout was completed on this day.
  mixed,
}

/// Fetches calendar day states for the HomeScreen2 training calendar.
/// Pure static helper — no state, no BuildContext.
class HomeV2CalendarService {
  static const Map<String, int> _dayMap = {
    'Mon': DateTime.monday,
    'Tue': DateTime.tuesday,
    'Wed': DateTime.wednesday,
    'Thu': DateTime.thursday,
    'Fri': DateTime.friday,
    'Sat': DateTime.saturday,
    'Sun': DateTime.sunday,
  };

  /// Returns a map of normalised training dates (midnight) to their
  /// [HomeV2CalendarDayKind] for the visible [month].
  ///
  /// Two queries run in sequence:
  ///   1. Active block doc → which weekdays are scheduled training days.
  ///   2. WES2 workout docs for the month → which days have completed sets.
  ///
  /// Returns an empty map on error or when no active block exists.
  static Future<Map<DateTime, HomeV2CalendarDayKind>> fetchCalendarDayStatesForMonth({
    required String uid,
    required DateTime month,
  }) async {
    if (uid.isEmpty) return {};
    try {
      final planned   = await _fetchPlannedDaysForMonth(uid, month);
      final completed = await _fetchCompletedDaysForMonth(uid, month);

      final result = <DateTime, HomeV2CalendarDayKind>{};
      for (final d in {...planned, ...completed}) {
        final p = planned.contains(d);
        final c = completed.contains(d);
        if (p && c) {
          result[d] = HomeV2CalendarDayKind.mixed;
        } else if (p) {
          result[d] = HomeV2CalendarDayKind.planned;
        } else {
          result[d] = HomeV2CalendarDayKind.completed;
        }
      }
      return result;
    } catch (e) {
      debugPrint('📅 [CalSvc] error: $e');
      return {};
    }
  }

  // ── Planned days ────────────────────────────────────────────────────────────

  static Future<Set<DateTime>> _fetchPlannedDaysForMonth(
      String uid, DateTime month) async {
    final query = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();
    if (query.docs.isEmpty) return {};

    final data       = query.docs.first.data();
    final blockStart = (data['startDate'] as Timestamp).toDate();
    final blockEnd   = (data['endDate']   as Timestamp).toDate();

    final List<dynamic> rawDays =
        data['selectedDays'] ?? data['daysOfWeek'] ?? [];
    final Set<int> weekdays = rawDays
        .map((d) => _dayMap[d.toString()])
        .whereType<int>()
        .toSet();
    if (weekdays.isEmpty) return {};

    final first = DateTime(month.year, month.month, 1);
    final last  = DateTime(month.year, month.month + 1, 0);
    final from  = first.isAfter(blockStart) ? first : blockStart;
    final to    = last.isBefore(blockEnd)   ? last  : blockEnd;
    if (from.isAfter(to)) return {};

    final result = <DateTime>{};
    for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1))) {
      if (weekdays.contains(d.weekday)) {
        result.add(DateTime(d.year, d.month, d.day));
      }
    }
    return result;
  }

  // ── Completed days ──────────────────────────────────────────────────────────

  /// Queries /users/{uid}/workouts for docs whose `date` field falls in [month]
  /// and contain at least one set with reps > 0 AND weight > 0.
  static Future<Set<DateTime>> _fetchCompletedDaysForMonth(
      String uid, DateTime month) async {
    final start = _dateKey(DateTime(month.year, month.month, 1));
    final end   = _dateKey(DateTime(month.year, month.month + 1, 0));

    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .where('date', isGreaterThanOrEqualTo: start)
        .where('date', isLessThanOrEqualTo: end)
        .get();

    final result = <DateTime>{};
    for (final doc in snap.docs) {
      if (!_hasCompletedSets(doc.data())) continue;
      final parts = doc.id.split('-');
      if (parts.length != 3) continue;
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      if (y != null && m != null && d != null) {
        result.add(DateTime(y, m, d));
      }
    }
    return result;
  }

  static bool _hasCompletedSets(Map<String, dynamic> data) {
    final exercises = data['exercises'];
    if (exercises is! List) return false;
    for (final ex in exercises) {
      if (ex is! Map) continue;
      final sets = ex['sets'];
      if (sets is! List) continue;
      for (final s in sets) {
        if (s is! Map) continue;
        if (_toNum(s['weight']) > 0 && _toNum(s['reps']) > 0) return true;
      }
    }
    return false;
  }

  static double _toNum(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  static String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
