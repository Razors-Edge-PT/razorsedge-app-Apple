import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'app_check_ready.dart';
import 'exercise_type.dart';
import 'periodization_model_utils.dart';

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
///
/// Data sources (spec section 8.6):
///   Planned:   users/{uid}/planned_blocks/{blockId}/weeks/week_N/days/day_N
///              → planned when exercises is a non-empty List
///   Also:      users/{uid}/workouts/{yyyy-MM-dd}.wesPlannedExercises
///              → planned when wesPlannedExercises is a non-empty List
///   Completed: users/{uid}/workouts/{yyyy-MM-dd}.exercises
///              → completed when any set has weight > 0 AND reps > 0
///
/// Week/day index:  0-based, sequential from blockStart.
///   weekIndex = (date − blockStart).inDays ~/ 7
///   dayIndex  = (date − blockStart).inDays %  7
class HomeV2CalendarService {
  // ── Public API ──────────────────────────────────────────────────────────────

  /// Returns a [HomeV2CalendarDayKind] map for all notable dates in [month].
  /// Block-planned and WES2-data fetches fail independently: a failure in one
  /// source does not discard results from the other.
  static Future<Map<DateTime, HomeV2CalendarDayKind>> fetchCalendarDayStatesForMonth({
    required String uid,
    required DateTime month,
  }) async {
    if (uid.isEmpty) return {};

    // Sequence behind App Check (settles even on failure/timeout).
    await appCheckReady;

    var blockPlanned = <DateTime>{};
    var wes2Planned  = <DateTime>{};
    var completed    = <DateTime>{};

    // Block day docs — fail independently from WES2
    try {
      blockPlanned = await _fetchBlockPlannedDays(uid, month);
    } catch (e) {
      debugPrint('📅 [CalSvc] block planned error: $e');
    }

    // WES2 workout docs — provides both WES2-planned and completed days
    try {
      final wes2 = await _fetchWes2Data(uid, month);
      wes2Planned = wes2.$1;
      completed   = wes2.$2;
    } catch (e) {
      debugPrint('📅 [CalSvc] WES2 error: $e');
    }

    final planned = {...blockPlanned, ...wes2Planned};
    final result  = <DateTime, HomeV2CalendarDayKind>{};

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
  }

  // ── Block planned days ──────────────────────────────────────────────────────

  /// Fetches users/{uid}/planned_blocks/{blockId}/weeks/week_N/days/day_N
  /// for every date in [month] that falls inside the active block's date range.
  /// A date is counted as planned only when the day doc's exercises list is
  /// non-empty.  All day-doc reads are issued in parallel.
  static Future<Set<DateTime>> _fetchBlockPlannedDays(
      String uid, DateTime month) async {
    // 1. Load active block metadata.
    final query = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('planned_blocks')
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();
    if (query.docs.isEmpty) return {};

    final blockDoc   = query.docs.first;
    final blockId    = blockDoc.id;
    final data       = blockDoc.data();
    final blockStart = _normalise((data['startDate'] as Timestamp).toDate());
    final blockEnd   = _normalise((data['endDate']   as Timestamp).toDate());

    // 2. Find date range: intersection of visible month and block range.
    final first = DateTime(month.year, month.month, 1);
    final last  = DateTime(month.year, month.month + 1, 0);
    final from  = first.isAfter(blockStart) ? first : blockStart;
    final to    = last.isBefore(blockEnd)   ? last  : blockEnd;
    if (from.isAfter(to)) return {};

    // 3. Build parallel fetches for all dates in the intersection.
    final dates   = <DateTime>[];
    final futures = <Future<DocumentSnapshot<Map<String, dynamic>>>>[];

    for (var d = from; !d.isAfter(to); d = d.add(const Duration(days: 1))) {
      final norm     = _normalise(d);
      final diffDays = norm.difference(blockStart).inDays;
      final wIdx     = diffDays ~/ 7;
      final dIdx     = diffDays % 7;

      dates.add(norm);
      futures.add(
        FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('planned_blocks')
            .doc(blockId)
            .collection('weeks')
            .doc('week_$wIdx')
            .collection('days')
            .doc('day_$dIdx')
            .get(),
      );
    }

    final snaps  = await Future.wait(futures);
    final result = <DateTime>{};

    for (var i = 0; i < snaps.length; i++) {
      final snap = snaps[i];
      if (!snap.exists) continue;
      final d = snap.data();
      if (d == null) continue;
      final exercises = d['exercises'];
      if (exercises is List && exercises.isNotEmpty) {
        result.add(dates[i]);
      }
    }
    return result;
  }

  // ── WES2 workout docs ───────────────────────────────────────────────────────

  /// Direct-gets each yyyy-MM-dd workout doc for the visible month.
  /// Returns (wesPlannedDays, completedDays).
  ///
  /// Doc IDs are the authoritative source (not the `date` field) to avoid
  /// relying on string-field consistency across older documents.
  static Future<(Set<DateTime>, Set<DateTime>)> _fetchWes2Data(
      String uid, DateTime month) async {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;

    final dates   = <DateTime>[];
    final futures = <Future<DocumentSnapshot<Map<String, dynamic>>>>[];

    for (var day = 1; day <= daysInMonth; day++) {
      final norm = DateTime(month.year, month.month, day);
      dates.add(norm);
      futures.add(
        FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('workouts')
            .doc(_dateKey(norm))
            .get(),
      );
    }

    final snaps      = await Future.wait(futures);
    final wes2Planned = <DateTime>{};
    final completed   = <DateTime>{};

    for (var i = 0; i < snaps.length; i++) {
      final snap = snaps[i];
      if (!snap.exists) continue;
      final data = snap.data();
      if (data == null) continue;

      // wesPlannedExercises → planned state
      final wesPlanned = data['wesPlannedExercises'];
      if (wesPlanned is List && wesPlanned.isNotEmpty) {
        wes2Planned.add(dates[i]);
      }

      // exercises with qualifying sets → completed state
      if (_hasCompletedSets(data)) {
        completed.add(dates[i]);
      }
    }

    return (wes2Planned, completed);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// A set is considered completed when its stored weight is valid and its
  /// reps are positive. Checks both current (`weight`/`reps`) and legacy
  /// (`actualWeight`/`actualReps`) field names to handle older workout
  /// documents.
  ///
  /// "Valid" is the shared raw-set rule ([isRawSetPerformed]): a stored 0 is
  /// "0 kg ADDED" on a bodyweight exercise — a real set at the athlete's own
  /// bodyweight — and nothing logged on every other exercise. Negative is
  /// never valid. The row's own `type` snapshot classifies it offline; rows
  /// written before that snapshot existed fall back to the type registry and
  /// the hard-coded id/name catalogue.
  /// [_hasCompletedSets], exposed for the tests that pin the shared raw-set
  /// rule across calendar, adherence and progression.
  @visibleForTesting
  static bool debugHasCompletedSets(Map<String, dynamic> data) =>
      _hasCompletedSets(data);

  static bool _hasCompletedSets(Map<String, dynamic> data) {
    final exercises = data['exercises'];
    if (exercises is! List) return false;
    for (final ex in exercises) {
      if (ex is! Map) continue;
      final sets = ex['sets'];
      if (sets is! List) continue;
      final bool isBw = PeriodizationModelUtils.isBodyweightExercise(
        id: (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim(),
        name: (ex['name'] ?? '').toString(),
        type: (ex['type'] ?? '').toString(),
      );
      for (final s in sets) {
        if (s is! Map) continue;
        final Object? w = s['weight'] ?? s['actualWeight'];
        final Object? r = s['reps'] ?? s['actualReps'];
        if (isRawSetPerformed(
            weightKg: _toNumOrNull(w),
            reps: _toNumOrNull(r),
            isBodyweight: isBw)) {
          return true;
        }
      }
    }
    return false;
  }

  static DateTime _normalise(DateTime d) => DateTime(d.year, d.month, d.day);

  /// [v] as a number, or null when ABSENT/unparseable. A bodyweight set's
  /// stored `0` must be distinguishable from a missing weight.
  static double? _toNumOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.isFinite ? v.toDouble() : null;
    return double.tryParse(v.toString().trim());
  }

  static String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
