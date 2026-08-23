import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart';
import 'user_context.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // for Timestamp & Firestore
import 'package:flutter/services.dart'; // for FilteringTextInputFormatter
import 'periodization_model_utils.dart';

enum TrendRange { d14, m1, m6, y1, y2 }

/// Inclusive local-time window deciding WHICH observations a chart shows.
///
/// It never affects horizontal spacing: X positions stay index-based, so two
/// sessions a day apart sit exactly as far apart as two sessions a month apart.
@immutable
class ChartWindow {
  final DateTime start;
  final DateTime end;
  const ChartWindow(this.start, this.end);

  bool contains(DateTime d) => !d.isBefore(start) && !d.isAfter(end);
}

/// Shared Y-axis scaling for both analytics charts.
///
/// Scales to the VISIBLE data instead of forcing the old 100 kg floor, so a
/// real 54.0 → 55.0 progression uses the chart height instead of looking flat.
@immutable
class ChartAxisScale {
  final double minY;
  final double maxY;
  final double interval;

  /// Decimal places the labels need for this [interval] (0 for whole numbers,
  /// 1 for 0.5 steps, 2 for 0.25 steps).
  final int decimals;

  const ChartAxisScale({
    required this.minY,
    required this.maxY,
    required this.interval,
    required this.decimals,
  });

  /// Used when a chart has nothing to draw.
  static const ChartAxisScale empty =
      ChartAxisScale(minY: 0, maxY: 20, interval: 5, decimals: 0);

  /// "Nice" step ladder — keeps grid lines on values a lifter recognises.
  static const List<double> steps = <double>[
    0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10, 20, 25, 50, 100, 200, 250,
    500, 1000,
  ];

  /// Grid density band: the ladder is walked until the tick count fits.
  static const int _maxTicks = 7;

  /// Builds an axis around [values] (the currently visible points of EVERY
  /// series on the chart).
  factory ChartAxisScale.fromValues(Iterable<double> values,
      {int targetTicks = 5}) {
    double? lo, hi;
    for (final v in values) {
      if (!v.isFinite) continue;
      lo = (lo == null) ? v : math.min(lo, v);
      hi = (hi == null) ? v : math.max(hi, v);
    }
    if (lo == null || hi == null) return empty;

    final double span = hi - lo;
    final double pad;
    if (span <= 1e-9) {
      // One point, or several identical ones: invent a readable window so the
      // chart can never collapse to zero height.
      pad = hi.abs() > 0 ? (hi.abs() * 0.05).clamp(0.5, 5.0) : 1.0;
    } else {
      // Breathing room above and below, with a floor for sub-kilo spreads.
      pad = math.max(span * 0.12, 0.05);
    }

    double rawMin = lo - pad;
    final double rawMax = hi + pad;
    if (lo >= 0 && rawMin < 0) rawMin = 0; // E1RM never goes negative

    int stepIndex = _stepIndexFor((rawMax - rawMin) / targetTicks);
    double interval = steps[stepIndex];
    double axisMin = _snapDown(rawMin, interval);
    double axisMax = _snapUp(rawMax, interval);
    int ticks = ((axisMax - axisMin) / interval).round();

    // Too dense → coarser steps.
    while (ticks > _maxTicks && stepIndex < steps.length - 1) {
      stepIndex++;
      interval = steps[stepIndex];
      axisMin = _snapDown(rawMin, interval);
      axisMax = _snapUp(rawMax, interval);
      ticks = ((axisMax - axisMin) / interval).round();
    }

    // Then take the finest step that still fits: it tightens the window around
    // the data (so small trends fill the height) without crowding the grid.
    while (stepIndex > 0) {
      final double candidate = steps[stepIndex - 1];
      final double cMin = _snapDown(rawMin, candidate);
      final double cMax = _snapUp(rawMax, candidate);
      final int cTicks = ((cMax - cMin) / candidate).round();
      if (cTicks > _maxTicks) break;
      stepIndex--;
      interval = candidate;
      axisMin = cMin;
      axisMax = cMax;
      ticks = cTicks;
    }

    // minY == maxY would make fl_chart draw nothing.
    if (axisMax - axisMin < interval * 0.5) axisMax = axisMin + interval;

    return ChartAxisScale(
      minY: axisMin,
      maxY: axisMax,
      interval: interval,
      decimals: decimalsFor(interval),
    );
  }

  /// Label text: whole steps lose the ".0", finer steps keep their precision.
  String format(double value) {
    final double v = value.abs() < 1e-9 ? 0.0 : value;
    return v.toStringAsFixed(decimals);
  }

  static int _stepIndexFor(double raw) {
    if (!raw.isFinite || raw <= 0) return 0;
    for (int i = 0; i < steps.length; i++) {
      if (steps[i] >= raw) return i;
    }
    return steps.length - 1;
  }

  static int decimalsFor(double interval) {
    for (int d = 0; d <= 2; d++) {
      final double scaled = interval * math.pow(10, d);
      if ((scaled - scaled.roundToDouble()).abs() < 1e-9) return d;
    }
    return 2;
  }

  static double _snapDown(double v, double interval) =>
      _clean((v / interval).floorToDouble() * interval);

  static double _snapUp(double v, double interval) =>
      _clean((v / interval).ceilToDouble() * interval);

  /// Strips floating-point noise like 53.750000000000004.
  static double _clean(double v) => double.parse(v.toStringAsFixed(4));
}

// Simple date/value pair for the series
class E1RMPoint {
  final DateTime date;
  final double value;
  const E1RMPoint(this.date, this.value);
}

class DailyBestE1RM {
  final DateTime date;            // day (midnight) in local time
  final double withRIR;           // best E1RM using reps + rir
  final double withoutRIR;        // best E1RM using reps only

  DailyBestE1RM({
    required this.date,
    required this.withRIR,
    required this.withoutRIR,
  });


}

class _DailyAgg {
  final DateTime date;
  double bestWithRIR = double.negativeInfinity;
  double bestWithoutRIR = double.negativeInfinity;
  _DailyAgg(this.date);
}

// Tooltip helper: actual performed set values for a point
class _PointMeta {
  final double weight;
  final int reps;
  final double rir;
  const _PointMeta(this.weight, this.reps, this.rir);
}

/// Which X positions get a printed label. Positions themselves stay
/// index-based — this only thins the labels so they cannot overcrowd.
Set<int> computeXTickIndices(int n) {
  if (n <= 0) return <int>{};
  final last = n - 1;
  const maxLabels = 6;

  // Few observations → label them all.
  if (n <= maxLabels) return {for (int i = 0; i < n; i++) i};

  final ticks = <int>{0, last}; // always keep first/last date context
  final step = last / (maxLabels - 1);
  for (int k = 1; k < maxLabels - 1; k++) {
    ticks.add((k * step).round().clamp(0, last));
  }
  return ticks;
}

/// Labels for every observation, using the coarsest date format that still
/// keeps the *printed* ticks distinguishable (no three identical "May 26").
List<String> buildXAxisLabels(List<DateTime> dates, Set<int> tickIdx) {
  if (dates.isEmpty) return const <String>[];

  final spanDays = dates.last.difference(dates.first).inDays;
  final multiYear = dates.first.year != dates.last.year;

  final patterns = <String>[];
  if (spanDays > 400) {
    patterns.add('MMM yy');
  } else if (spanDays > 60) {
    patterns.add(multiYear ? 'MMM yy' : 'MMM');
  }
  patterns.add(multiYear ? 'd MMM yy' : 'd MMM');
  patterns.add('d MMM yy');

  final seen = <String>{};
  for (final pattern in patterns) {
    if (!seen.add(pattern)) continue;
    final fmt = DateFormat(pattern);
    final labels = [for (final d in dates) fmt.format(d)];
    final shown = [
      for (final i in tickIdx)
        if (i >= 0 && i < labels.length) labels[i]
    ];
    if (shown.toSet().length == shown.length) return labels;
  }

  final finest = DateFormat('d MMM yy');
  return [for (final d in dates) finest.format(d)];
}

class ExerciseDetailsScreen extends StatefulWidget {
  final String exerciseId;              // 👈 required for querying
  final String? exerciseName;           // 👈 optional, only for display
  final List<Workout>? recentWorkouts;  // optional; if null, we fetch

  const ExerciseDetailsScreen({
    super.key,
    required this.exerciseId,
    this.exerciseName,
    this.recentWorkouts,
  });

  @override
  State<ExerciseDetailsScreen> createState() => _ExerciseDetailsScreenState();
}

class _ExerciseDetailsScreenState extends State<ExerciseDetailsScreen> {
  /// History pulled when the screen opens. Custom ranges reaching further back
  /// top this up on demand (see [_ensureHistoryLoadedFrom]).
  static const int _defaultLookbackDays = 730;

  TrendRange _trend = TrendRange.d14; // 👈 our new toggle state

  // --- Custom date range state (independent per chart) ---
  DateTimeRange? _customTrend; // E1RM Trend chart
  DateTimeRange? _customTarget; // Rep Target chart

  /// Oldest date currently held in [_workouts].
  DateTime _loadedSince =
      DateTime.now().subtract(const Duration(days: _defaultLookbackDays));

  /// True while a deeper history fetch triggered by a custom range is running.
  bool _loadingMore = false;
  String get userId => UserContext.of(context, listen: false).currentUid;

  List<DailyBestE1RM> _dailyBests = [];
  bool _loadingDaily = true;

  bool _includeRIRForTrend = true;
  String _rirToggleTextTrend() =>
      _includeRIRForTrend ? 'Including RIR' : 'Excluding RIR';

  double calculateE1RM(double weight, double reps, double rir) {
    return PeriodizationModelUtils.calculateE1RM(weight, reps, rir);
  }



  List<Workout> _workouts = [];
  bool _loading = true;

  DateTime _cutoffFor(TrendRange t) {
    final now = DateTime.now();
    switch (t) {
      case TrendRange.d14: return now.subtract(const Duration(days: 14));
      case TrendRange.m1:  return now.subtract(const Duration(days: 30));
      case TrendRange.m6:  return now.subtract(const Duration(days: 182));
      case TrendRange.y1:  return now.subtract(const Duration(days: 365));
      case TrendRange.y2:  return now.subtract(const Duration(days: 730));
    }
  }

  /// Visible window for a chart: its custom range when one is active,
  /// otherwise the preset's existing "last N days → now" behaviour.
  ChartWindow _windowFor(TrendRange preset, DateTimeRange? custom) {
    if (custom != null) {
      final start =
          DateTime(custom.start.year, custom.start.month, custom.start.day);
      final end = DateTime(
          custom.end.year, custom.end.month, custom.end.day, 23, 59, 59, 999);
      return ChartWindow(start, end);
    }
    return ChartWindow(_cutoffFor(preset), DateTime(9999));
  }

  ChartWindow get _windowTrend => _windowFor(_trend, _customTrend);
  ChartWindow get _windowTarget => _windowFor(_trendTarget, _customTarget);

  /// Dense-view rule for dot/line styling, extended to custom ranges by span so
  /// presets keep exactly the look they had before.
  bool _isShortView(TrendRange preset, DateTimeRange? custom) {
    if (custom != null) {
      return custom.end.difference(custom.start).inDays <= 45;
    }
    return preset == TrendRange.d14 || preset == TrendRange.m1;
  }

  Future<List<Workout>> _fetchHistoryForExercise({
    required String exerciseId,
    String? exerciseName,  // optional fallback
    String? uidOverride,
    int lookbackDays = _defaultLookbackDays,
    DateTime? since,
    int batchSize = 50,
  }) async {
    // Prefer selected user if provided; fallback to logged-in only if needed
    String? userId = uidOverride ?? FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return [];

    final cutoff =
        since ?? DateTime.now().subtract(Duration(days: lookbackDays));

    // Keep only ONE workout per local day: the one with the best top-set E1RM (incl RIR)
    final Map<String, double> bestScoreByDay = {};
    final Map<String, Workout> bestWorkoutByDay = {};

    DocumentSnapshot? lastDoc;
    int page = 0;

    try {
      while (true) {
        page++;
        Query<Map<String, dynamic>> q = FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('workouts')
            .orderBy('date', descending: true)
            .limit(batchSize);

        if (lastDoc != null) q = q.startAfterDocument(lastDoc);

        final snap = await q.get();
        if (snap.docs.isEmpty) break;

        for (final doc in snap.docs) {
          final data = doc.data();

          // Parse date (Timestamp or ISO string)
          final rawDate = data['date'];
          DateTime? workoutDate;
          if (rawDate is Timestamp) {
            workoutDate = rawDate.toDate();
          } else if (rawDate is String) {
            workoutDate = DateTime.tryParse(rawDate);
          }
          if (workoutDate == null || workoutDate.isBefore(cutoff)) continue;

          final rawEx = data['exercises'];
          if (rawEx is! List) continue;

          // Does this workout contain the exercise?
          final matches = rawEx.any((e) {
            final m = e as Map<String, dynamic>;
            final rid = (m['id'] ?? m['exerciseId'] ?? '').toString();
            if (rid.isNotEmpty && rid == exerciseId) return true;
            if (exerciseName != null && (m['name'] ?? '') == exerciseName) return true;
            return false;
          });
          if (!matches) continue;

          // Compute THIS WORKOUT'S top-set E1RM (including RIR) for the exercise
          double workoutBestE1 = double.negativeInfinity;
          for (final e in rawEx.cast<Map<String, dynamic>>()) {
            final rid = (e['id'] ?? e['exerciseId'] ?? '').toString();
            final rname = (e['name'] ?? '').toString();
            final isMatch = (rid.isNotEmpty && rid == exerciseId) ||
                (exerciseName != null && rname == exerciseName);
            if (!isMatch) continue;

            final sets = (e['sets'] as List?) ?? const [];
            for (final s in sets.cast<Map<String, dynamic>>()) {
              final weight = (s['weight'] as num?)?.toDouble() ?? 0.0;
              final reps   = (s['reps']   as num?)?.toDouble() ?? 0.0;
              final rir    = (s['rir']    as num?)?.toDouble() ?? 0.0;
              if (weight <= 0 || reps <= 0) continue;

              final e1 = calculateE1RM(weight, reps, rir); // ✅ include RIR
              if (e1 > workoutBestE1) workoutBestE1 = e1;
            }
          }
          if (!workoutBestE1.isFinite) continue;

          // Day key (local midnight)
          final day = DateTime(workoutDate.year, workoutDate.month, workoutDate.day);
          final key = '${day.year.toString().padLeft(4, '0')}-'
              '${day.month.toString().padLeft(2, '0')}-'
              '${day.day.toString().padLeft(2, '0')}';

          // If this workout beats the current day's best, keep this whole workout
          final prev = bestScoreByDay[key];
          if (prev == null || workoutBestE1 > prev) {
            // Map the workout doc to your model
            List<Exercise> exercises = [];
            try {
              exercises = (rawEx as List)
                  .map((e) => Exercise.fromFirestore(e as Map<String, dynamic>))
                  .toList();
            } catch (_) {}

            bestScoreByDay[key] = workoutBestE1;
            bestWorkoutByDay[key] = Workout(
              name: (data['name'] ?? 'Unnamed Workout') as String,
              date: workoutDate,
              exercises: exercises,
            );
          }
        }

        lastDoc = snap.docs.last;

        // Early exit if the last item on this page is older than cutoff
        final lastData = snap.docs.last.data();
        DateTime? lastDate;
        final lastRaw = lastData['date'];
        if (lastRaw is Timestamp) lastDate = lastRaw.toDate();
        if (lastRaw is String)    lastDate = DateTime.tryParse(lastRaw);
        if (lastDate != null && lastDate.isBefore(cutoff)) break;

        if (snap.docs.length < batchSize) break; // no more pages
      }

      // Build final list (one workout per day), ascending
      final out = bestWorkoutByDay.values.toList()
        ..sort((a, b) => a.date.compareTo(b.date));

      print('🟦 [Details] Daily top-set fetch: ${out.length} days '
          '(pages=$page, id="$exerciseId", name="${exerciseName ?? "null"}")');
      if (out.isNotEmpty) {
        print('🟦 [Details] Range: ${out.first.date.toIso8601String()} → ${out.last.date.toIso8601String()}');
      }
      return out;
    } catch (e) {
      print('❌ [Details] fetch error (daily top-set): $e');
      return [];
    }
  }


  /// Per-day best E1RM (with/without RIR) for the past [lookbackDays].
  /// - Matches exercise by `exerciseId` first (also accepts `exerciseId` key),
  ///   then falls back to `exerciseName` if provided.
  /// - Paginates in 50s by default; safe with mixed Timestamp/ISO dates.
  Future<List<DailyBestE1RM>> _fetchTwoYearDailyBestsForExercise({
    required String exerciseId,
    String? exerciseName,
    String? uidOverride,          // pass selected uid here (e.g., UserContext.currentUid)
    int lookbackDays = 730,
    int batchSize = 50,
  }) async {
    // Prefer the passed-in selected uid; fall back to logged-in only if needed
    String? userId = uidOverride ?? FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return [];

    final cutoff = DateTime.now().subtract(Duration(days: lookbackDays));

    // Aggregate per local day (midnight)
    final Map<String, _DailyAgg> byDay = {};
    DocumentSnapshot? lastDoc;
    int page = 0;

    try {
      while (true) {
        page++;
        Query<Map<String, dynamic>> q = FirebaseFirestore.instance
            .collection('users')
            .doc(userId)
            .collection('workouts')
            .orderBy('date', descending: true)
            .limit(batchSize);

        if (lastDoc != null) q = q.startAfterDocument(lastDoc);

        final snap = await q.get();
        if (snap.docs.isEmpty) break;

        for (final doc in snap.docs) {
          final data = doc.data();

          // Robust date parse (Timestamp or ISO string)
          final rawDate = data['date'];
          DateTime? workoutDate;
          if (rawDate is Timestamp) {
            workoutDate = rawDate.toDate();
          } else if (rawDate is String) {
            workoutDate = DateTime.tryParse(rawDate);
          }
          if (workoutDate == null || workoutDate.isBefore(cutoff)) continue;

          final rawEx = data['exercises'];
          if (rawEx is! List) continue;

          // Match by id first; fallback to name if provided
          final containsExercise = rawEx.any((e) {
            final m = e as Map<String, dynamic>;
            final rid = (m['id'] ?? m['exerciseId'] ?? '').toString();
            if (rid.isNotEmpty && rid == exerciseId) return true;
            if (exerciseName != null && (m['name'] ?? '') == exerciseName) return true;
            return false;
          });
          if (!containsExercise) continue;

          // Normalize to local midnight per-day key
          final day = DateTime(workoutDate.year, workoutDate.month, workoutDate.day);
          final key = '${day.year.toString().padLeft(4, '0')}-'
              '${day.month.toString().padLeft(2, '0')}-'
              '${day.day.toString().padLeft(2, '0')}';
          final agg = byDay.putIfAbsent(key, () => _DailyAgg(day));

          // Scan only the matching exercise(s) for this day
          for (final e in rawEx.cast<Map<String, dynamic>>()) {
            final rid = (e['id'] ?? e['exerciseId'] ?? '').toString();
            final rname = (e['name'] ?? '').toString();
            final isMatch = (rid.isNotEmpty && rid == exerciseId) ||
                (exerciseName != null && rname == exerciseName);
            if (!isMatch) continue;

            final sets = (e['sets'] as List?) ?? const [];
            for (final s in sets.cast<Map<String, dynamic>>()) {
              final weight = (s['weight'] as num?)?.toDouble() ?? 0.0;
              final reps   = (s['reps'] as num?)?.toDouble() ?? 0.0;
              final rir    = (s['rir'] as num?)?.toDouble() ?? 0.0;
              if (weight <= 0 || reps <= 0) continue;

              final inc  = calculateE1RM(weight, reps, rir);  // including RIR
              final excl = calculateE1RM(weight, reps, 0.0);  // excluding RIR

              if (inc  > agg.bestWithRIR)    agg.bestWithRIR = inc;
              if (excl > agg.bestWithoutRIR) agg.bestWithoutRIR = excl;
            }
          }
        }

        lastDoc = snap.docs.last;

        // Early break if we've crossed the cutoff
        final lastData = snap.docs.last.data();
        DateTime? lastDate;
        final lastRaw = lastData['date'];
        if (lastRaw is Timestamp) lastDate = lastRaw.toDate();
        if (lastRaw is String)    lastDate = DateTime.tryParse(lastRaw);
        if (lastDate != null && lastDate.isBefore(cutoff)) break;

        if (snap.docs.length < batchSize) break;
      }

      // Build output (ascending)
      final out = byDay.values
          .where((a) => a.bestWithRIR.isFinite || a.bestWithoutRIR.isFinite)
          .map((a) => DailyBestE1RM(
        date: a.date,
        withRIR: a.bestWithRIR.isFinite ? a.bestWithRIR : 0.0,
        withoutRIR: a.bestWithoutRIR.isFinite ? a.bestWithoutRIR : 0.0,
      ))
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));

      print('🟦 [Details] Daily bests: ${out.length} days '
          '(pages=$page, id="$exerciseId", name="${exerciseName ?? "null"}")');
      if (out.isNotEmpty) {
        print('🟦 [Details] Range: ${out.first.date.toIso8601String()} → ${out.last.date.toIso8601String()}');
      }
      return out;
    } catch (e) {
      print('❌ [Details] daily bests error: $e');
      return [];
    }
  }



  void _cycleTrend() {
    final values = TrendRange.values;
    final i = values.indexOf(_trend);
    setState(() {
      _trend = values[(i + 1) % values.length];
      _customTrend = null; // picking a preset leaves custom mode
    });
  }

  /// Compact custom-range label, e.g. "1 Mar – 21 Aug".
  String _customRangeLabel(DateTimeRange r) {
    final now = DateTime.now();
    final sameYearAsNow = r.start.year == now.year && r.end.year == now.year;
    final fmt = DateFormat(sameYearAsNow ? 'd MMM' : 'd MMM yy');
    return '${fmt.format(r.start)} – ${fmt.format(r.end)}';
  }

  String _rangeLabelFor(TrendRange preset, DateTimeRange? custom) =>
      custom != null ? _customRangeLabel(custom) : _rangeLabel(preset);

  /// Compact calendar button opening the native range picker for one chart.
  /// Highlighted while that chart is on a custom range; shows a spinner while
  /// older history is being fetched.
  Widget _rangePickerButton({required bool forRepTarget}) {
    final accent = Theme.of(context).colorScheme.tertiary;
    final bool active = (forRepTarget ? _customTarget : _customTrend) != null;

    return Tooltip(
      message: 'Custom date range',
      child: SizedBox(
        width: 34,
        height: 32,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _loadingMore
              ? null
              : () => _pickCustomRange(forRepTarget: forRepTarget),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: accent),
              borderRadius: BorderRadius.circular(8),
              color: accent.withOpacity(active ? 0.28 : 0.08),
            ),
            child: _loadingMore
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: accent,
                    ),
                  )
                : Icon(Icons.date_range, size: 16, color: accent),
          ),
        ),
      ),
    );
  }

  /// Native Material range picker, wired independently per chart.
  Future<void> _pickCustomRange({required bool forRepTarget}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstDate = DateTime(today.year - 10, 1, 1);

    final existing = forRepTarget ? _customTarget : _customTrend;
    final presetStart =
        _windowFor(forRepTarget ? _trendTarget : _trend, null).start;

    DateTime initStart = existing?.start ?? presetStart;
    if (initStart.isBefore(firstDate)) initStart = firstDate;
    if (initStart.isAfter(today)) initStart = today;
    DateTime initEnd = existing?.end ?? today;
    if (initEnd.isAfter(today)) initEnd = today;
    if (initEnd.isBefore(initStart)) initEnd = initStart;

    final picked = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: today,
      initialDateRange: DateTimeRange(start: initStart, end: initEnd),
      helpText: forRepTarget ? 'Rep target range' : 'E1RM trend range',
      saveText: 'Apply',
      builder: (ctx, child) {
        final accent = Theme.of(ctx).colorScheme.tertiary;
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: ColorScheme.dark(
              primary: accent,
              onPrimary: Colors.black,
              surface: Colors.grey.shade900,
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;

    setState(() {
      if (forRepTarget) {
        _customTarget = picked;
      } else {
        _customTrend = picked;
      }
    });

    await _ensureHistoryLoadedFrom(picked.start);
  }

  /// A custom range may reach past the history loaded on open. Fetch the extra
  /// span (once) rather than silently omitting those observations.
  Future<void> _ensureHistoryLoadedFrom(DateTime start) async {
    final needed = DateTime(start.year, start.month, start.day);
    if (_loadingMore || !needed.isBefore(_loadedSince)) return;

    final uid = UserContext.of(context, listen: false).currentUid;
    // Small buffer so a nearby second pick is served from what we already have.
    final since = needed.subtract(const Duration(days: 7));

    setState(() => _loadingMore = true);

    final list = await _fetchHistoryForExercise(
      exerciseId: widget.exerciseId,
      exerciseName: widget.exerciseName,
      uidOverride: uid,
      since: since,
    );
    if (!mounted) return;

    setState(() {
      // The deeper query is a superset of what we hold; only accept it as one.
      if (list.length >= _workouts.length) {
        _workouts = list..sort((a, b) => a.date.compareTo(b.date));
        _loadedSince = since;
      }
      _loadingMore = false;
    });
  }

  String _rangeLabel(TrendRange t) {
    switch (t) {
      case TrendRange.d14:
        return 'Two Weeks';
      case TrendRange.m1:
        return '1 Month';
      case TrendRange.m6:
        return '6 Months';
      case TrendRange.y1:
        return '1 Year';
      case TrendRange.y2:
        return '2 Years';
    }
  }


  // --- Rep-target chart state ---
  final TextEditingController _repTargetCtrl = TextEditingController(text: '5');
  double? _repTarget = 5;        // default visible trend for 5 reps
  bool _includeRIRForTarget = true;
  TrendRange _trendTarget = TrendRange.d14;

  void _cycleTrendTarget() {
    final vals = TrendRange.values;
    final i = vals.indexOf(_trendTarget);
    setState(() {
      _trendTarget = vals[(i + 1) % vals.length];
      _customTarget = null; // picking a preset leaves custom mode
    });
  }

  String _repTargetLabel() => _multiRepLabel();


  String _rirToggleText() =>
      _includeRIRForTarget ? 'Including RIR' : 'Excluding RIR';

// --- New: multi-target state ---
  List<Set<int>> _repGroups = [ {5} ];            // one series per comma token (ranges collapse into one set)
  List<String> _repGroupLabels = ['5 reps'];      // aligned with _repGroups

// Parse "4,6-8,10" → [{4}, {6,7,8}, {10}] and labels ["4 reps","Reps 6–8","10 reps"]
  void _onRepTargetChanged(String raw) {
    final txt = raw.trim();
    final groups = <Set<int>>[];
    final labels = <String>[];

    if (txt.isEmpty) {
      _repGroups = [];
      _repGroupLabels = [];
      _repTarget = null;
      return;
    }

    for (final token in txt.split(',')) {
      final t = token.trim();
      if (t.isEmpty) continue;

      if (t.contains('-')) {
        final parts = t.split('-').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
        if (parts.length == 2) {
          final a = int.tryParse(parts[0]);
          final b = int.tryParse(parts[1]);
          if (a != null && b != null) {
            final lo = a <= b ? a : b;
            final hi = a <= b ? b : a;
            final set = <int>{for (int r = lo; r <= hi; r++) r};
            groups.add(set);
            labels.add('Reps $lo–$hi');
          }
        }
      } else {
        final v = int.tryParse(t);
        if (v != null) {
          groups.add({v});
          labels.add('$v reps');
        }
      }
    }

    _repGroups = groups;
    _repGroupLabels = labels;

    // Back-compat: only one single value → keep _repTarget
    if (_repGroups.length == 1 && _repGroups.first.length == 1) {
      _repTarget = _repGroups.first.first.toDouble();
    } else {
      _repTarget = null;
    }
  }

// Friendly label for the title button
  String _multiRepLabel() {
    if (_repGroups.isEmpty) return 'Rep Target • ${_rangeLabelFor(_trendTarget, _customTarget)}';
    if (_repGroups.length == 1) {
      final g = _repGroups.first.toList()..sort();
      if (g.length == 1) return '${g.first} Rep Target • ${_rangeLabelFor(_trendTarget, _customTarget)}';
      final minR = g.first, maxR = g.last;
      final isRange = (maxR - minR + 1) == g.length;
      return isRange
          ? 'Reps $minR–$maxR • ${_rangeLabelFor(_trendTarget, _customTarget)}'
          : 'Reps ${g.join(",")} • ${_rangeLabelFor(_trendTarget, _customTarget)}';
    }
    // multiple groups → mirror the input shape: per-group labels joined by " | "
    return '${_repGroupLabels.join(" | ")} • ${_rangeLabelFor(_trendTarget, _customTarget)}';
  }

// Deterministic colors per group
  Color _colorForGroupIndex(int i) {
    const palette = <Color>[
      Colors.cyanAccent,
      Colors.amberAccent,
      Colors.pinkAccent,
      Colors.lightGreenAccent,
      Colors.orangeAccent,
      Colors.blueAccent,
      Colors.purpleAccent,
      Colors.redAccent,
    ];
    return palette[i % palette.length];
  }


  // Loads BW history into PMU so toDisplayAddedWeight/e1rmForDisplay use real data.
  // Mirrors the pattern in workout_entry_screen._primeBodyweightHistoryCache.
  Future<void> _primeBwHistory(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('weights')
          .orderBy('timestamp', descending: true)
          .limit(1000)
          .get();
      final entries = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final data = d.data();
        final double? bw = (data['weight'] as num?)?.toDouble();
        final DateTime ts =
            (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
        final String unit = (data['unit'] as String?) ?? 'kg';
        if (bw != null && bw > 0 && unit == 'kg') {
          entries.add({'date': ts, 'weight': bw, 'unit': 'kg'});
        }
      }
      if (entries.isNotEmpty) {
        PeriodizationModelUtils.setBodyweightHistory(uid: uid, entries: entries);
      }
    } catch (e) {
      debugPrint('⚠️ [ExerciseDetails] BW history load failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    print('🟦 [Details] init for id="${widget.exerciseId}", name="${widget.exerciseName}"');
    _onRepTargetChanged(_repTargetCtrl.text); // seed groups from "5"
    final selectedUid = UserContext.of(context, listen: false).currentUid;

    // Load BW history so Top Sets displays added weight for BW exercises.
    // Fires concurrently with the workout fetch; triggers a rebuild once done
    // if the workout list is already visible.
    _primeBwHistory(selectedUid).then((_) {
      if (mounted && _workouts.isNotEmpty) setState(() {});
    });

    // …then fetch the default history window and replace
    _fetchHistoryForExercise(
      exerciseId: widget.exerciseId,
      exerciseName: widget.exerciseName, // nullable ok
      uidOverride: selectedUid, // 👈 pass selected user id
    ).then((list) {
      if (!mounted) return;
      setState(() {
        _workouts = list..sort((a, b) => a.date.compareTo(b.date));
        _loading = false;
      });
      if (_workouts.isNotEmpty) {
        final first = _workouts.first.date;
        final last  = _workouts.last.date;
        print('🟦 [Details] Fetched FULL history: ${_workouts.length} '
            '(from ${first.toIso8601String()} to ${last.toIso8601String()})');
      } else {
        print('🟦 [Details] Fetched 0 workouts');
      }
    });

    _fetchTwoYearDailyBestsForExercise(
      exerciseId: widget.exerciseId,
      exerciseName: widget.exerciseName,
      uidOverride: selectedUid, // ✅ selected user
    ).then((list) {
      if (!mounted) return;
      setState(() {
        _dailyBests = list;
        _loadingDaily = false;
      });
    });
  }

  @override
  void dispose() {
    _repTargetCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Full history (used by the list below)
    final List<Workout> sortedWorkouts =
    [..._workouts]..sort((a, b) => a.date.compareTo(b.date));

    final List<E1RMPoint> series = [];
    final Map<DateTime, _PointMeta> _metaAllTop = {};

    int matchedWorkouts = 0;

    for (final workout in sortedWorkouts) {
      // pick the matching exercise (by id if present, else by name)
      Exercise? ex;
      // try id first (your Exercise now has optional id)
      ex = workout.exercises.firstWhere(
            (e) => (e.id != null && e.id == widget.exerciseId),
        orElse: () => Exercise(name: '', sets: const [], circuitIndex: 0),
      );
      if (ex.name.isEmpty && widget.exerciseName != null) {
        ex = workout.exercises.firstWhere(
              (e) => e.name == widget.exerciseName,
          orElse: () => Exercise(name: '', sets: const [], circuitIndex: 0),
        );
      }
      if (ex.name.isEmpty || ex.sets.isEmpty) continue;

      matchedWorkouts++;

      final top = ex.sets.reduce((a, b) {
        final aE1 = calculateE1RM(a.weight ?? 0.0, (a.reps ?? 0).toDouble(), a.rir ?? 0.0);
        final bE1 = calculateE1RM(b.weight ?? 0.0, (b.reps ?? 0).toDouble(), b.rir ?? 0.0);
        return aE1 > bE1 ? a : b;
      });

      final e1 = calculateE1RM(top.weight ?? 0.0, (top.reps ?? 0).toDouble(), _includeRIRForTrend ? (top.rir ?? 0.0) : 0.0);
      series.add(E1RMPoint(workout.date, e1));
      _metaAllTop[workout.date] = _PointMeta(
        (top.weight ?? 0.0),
        (top.reps ?? 0),
        (top.rir ?? 0.0),
      );

    }

    print('📊 [Details] Workouts total=${_workouts.length}, matched=$matchedWorkouts, points=${series.length}');

    // ===== Rep-target series (second chart) — Multi-line support =====
// One line per COMMA token; dash ranges collapse into a single line.
// Inclusion rule: include a day IFF that day's TOP SET (by E1RM WITH RIR) has reps ∈ group's set.
// Y value respects the Include RIR toggle.

// Parse the TextField on the fly (works even if you haven't added _repGroups yet)
    final rawTargets = _repTargetCtrl.text.trim();
    final List<Set<int>> parsedGroups = <Set<int>>[];
    final List<String> repGroupLabels2 = <String>[];

    if (rawTargets.isNotEmpty) {
      for (final token in rawTargets.split(',')) {
        final t = token.trim();
        if (t.isEmpty) continue;

        if (t.contains('-')) {
          final parts = t.split('-').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
          if (parts.length == 2) {
            final a = int.tryParse(parts[0]);
            final b = int.tryParse(parts[1]);
            if (a != null && b != null) {
              final lo = a <= b ? a : b;
              final hi = a <= b ? b : a;
              parsedGroups.add({for (int r = lo; r <= hi; r++) r});
              repGroupLabels2.add('Reps $lo–$hi');
            }
          }
        } else {
          final v = int.tryParse(t);
          if (v != null) {
            parsedGroups.add({v});
            repGroupLabels2.add('$v reps');
          }
        }
      }
    }

// Back-compat: if nothing parsed but a single _repTarget exists, use that as one group
    final List<Set<int>> effectiveGroups =
    parsedGroups.isNotEmpty ? parsedGroups : (_repTarget != null ? [ {_repTarget!.toInt()} ] : []);

    final ChartWindow window2 = _windowTarget;

// Build per-group points and collect all dates for a master x-axis
    final List<List<E1RMPoint>> groupPoints = [];
    final Set<DateTime> allDates = {};
    final List<Map<DateTime, _PointMeta>> metaByGroup = [];

    for (final group in effectiveGroups) {
      final pts = <E1RMPoint>[];
      final metaForGroup = <DateTime, _PointMeta>{};

      for (final workout in sortedWorkouts) {
        // find the matching exercise in the workout (id first, fallback name)
        Exercise? ex = workout.exercises.firstWhere(
              (e) => (e.id != null && e.id == widget.exerciseId),
          orElse: () => Exercise(name: '', sets: const [], circuitIndex: 0),
        );
        if ((ex.name.isEmpty || ex.sets.isEmpty) && widget.exerciseName != null) {
          ex = workout.exercises.firstWhere(
                (e) => e.name == widget.exerciseName,
            orElse: () => Exercise(name: '', sets: const [], circuitIndex: 0),
          );
        }
        if (ex.sets.isEmpty) continue;

        // choose THE day's top set USING RIR
        SetDetails? topSetInc;
        double bestInc = double.negativeInfinity;
        for (final s in ex.sets) {
          final w = s.weight ?? 0.0;
          final r = (s.reps ?? 0).toDouble();
          final rir = (s.rir ?? 0.0);
          if (w <= 0 || r <= 0) continue;

          final e1 = calculateE1RM(w, r, rir);
          if (e1 > bestInc) {
            bestInc = e1;
            topSetInc = s;
          }
        }
        if (topSetInc == null) continue;

        // include only if top set reps is in current group's set
        final topReps = (topSetInc!.reps ?? 0);
        if (!group.contains(topReps)) continue;

        // Y value depends on Include RIR toggle (same set selected above)
        final w = topSetInc!.weight ?? 0.0;
        final r = (topSetInc!.reps ?? 0).toDouble();
        final rirForY = _includeRIRForTarget ? (topSetInc!.rir ?? 0.0) : 0.0;
        final y = calculateE1RM(w, r, rirForY);

        if (window2.contains(workout.date)) {
          pts.add(E1RMPoint(workout.date, y));
          metaForGroup[workout.date] = _PointMeta(w, r.toInt(), (topSetInc!.rir ?? 0.0));
          allDates.add(workout.date);
        }
      }

      pts.sort((a, b) => a.date.compareTo(b.date));
      groupPoints.add(pts);
      metaByGroup.add(metaForGroup);
    }

// Master timeline (shared x-axis for all lines)
    final masterDates2 = allDates.toList()..sort();
    final Map<DateTime, double> dateToX2 = {
      for (int i = 0; i < masterDates2.length; i++) masterDates2[i]: i.toDouble()
    };

// Ticks first, then labels: the label format depends on which ticks print.
    final xTickSet2 = computeXTickIndices(masterDates2.length);
    final labels2 = buildXAxisLabels(masterDates2, xTickSet2);

// Build FlSpots per group. X stays the index on the shared master timeline,
// so observations remain equally spaced regardless of elapsed calendar time.
    final List<List<FlSpot>> spotsByGroup = [];

    for (final pts in groupPoints) {
      final spots = <FlSpot>[];
      for (final p in pts) {
        final x = dateToX2[p.date]!;
        spots.add(FlSpot(x, p.value));
      }
      spotsByGroup.add(spots);
    }

// Y axis spans EVERY visible series, not just the first line.
    final ChartAxisScale scaleY2 =
        ChartAxisScale.fromValues(spotsByGroup.expand((g) => g).map((s) => s.y));

// Back-compat placeholders so existing single-line code compiles until you switch to lineBarsData2:
// - filtered2 = the first group's raw points (or empty if multiple groups)
// - spots2    = the first group's spots (or empty if multiple groups)
    final List<E1RMPoint> filtered2 = groupPoints.length == 1 ? groupPoints.first : <E1RMPoint>[];
    final List<FlSpot> spots2 = spotsByGroup.length == 1 ? spotsByGroup.first : <FlSpot>[];

    final bool short2 = _isShortView(_trendTarget, _customTarget);
// asym padding so first point is closer to Y axis but right edge has room
    final double leftPadX2  = short2 ? 0.10 : 0.20;
    final double rightPadX2 = short2 ? 0.20 : 0.15;

// New multi-line dataset for the chart (use in your LineChart):
    final List<LineChartBarData> lineBarsData2 = (() {
      const palette = <Color>[
        Colors.cyanAccent,
        Colors.amberAccent,
        Colors.pinkAccent,
        Colors.lightGreenAccent,
        Colors.orangeAccent,
        Colors.blueAccent,
        Colors.purpleAccent,
        Colors.redAccent,
      ];
      final bars = <LineChartBarData>[];
      for (int gi = 0; gi < spotsByGroup.length; gi++) {
        final spots = spotsByGroup[gi];
        if (spots.isEmpty) continue;
        final color = palette[gi % palette.length];

        bars.add(
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: color,
            dotData: FlDotData(show: short2),
            barWidth: short2 ? 1.0 : 2.0,
            belowBarData: BarAreaData(
              show: true,
              color: color.withOpacity(0.10),
            ),
          ),
        );
      }
      return bars;
    })();



// Filter to the selected window (preset or custom) & project to chart data.
// X is the observation's INDEX, never elapsed time: equal spacing is intended.
    final ChartWindow window = _windowTrend;
    final filtered = series.where((p) => window.contains(p.date)).toList();

    final List<FlSpot> spots = [
      for (var i = 0; i < filtered.length; i++)
        FlSpot(i.toDouble(), filtered[i].value)
    ];

    final xTickSet = computeXTickIndices(filtered.length);
    final List<String> labels =
        buildXAxisLabels([for (final p in filtered) p.date], xTickSet);

// Y axis scaled to the points visible in this window.
    final ChartAxisScale scaleY =
        ChartAxisScale.fromValues(spots.map((s) => s.y));

    final bool shortRange = _isShortView(_trend, _customTrend);
    final double leftPadX  = shortRange ? 0.10 : 0.20;
    final double rightPadX = shortRange ? 0.10 : 0.15;
    final double controlHeight = 40;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true, // <- make sure this is here
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.exerciseName ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Text(
              'Analytics',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w400,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
    body: SingleChildScrollView(
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: EdgeInsets.only(
    bottom: MediaQuery.of(context).viewInsets.bottom + 8, // <- room for keyboard
    ),
    child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
          // Title + inline range toggle
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: TextButton.icon(
                    onPressed: _cycleTrend,
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'E1RM Trend • ${_rangeLabelFor(_trend, _customTrend)}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.tertiary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      foregroundColor: Theme.of(context).colorScheme.tertiary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(color: Theme.of(context).colorScheme.tertiary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _rangePickerButton(forRepTarget: false),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints.tightFor(height: 32),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _includeRIRForTrend = !_includeRIRForTrend),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).colorScheme.tertiary),
                        borderRadius: BorderRadius.circular(8),
                        color: Theme.of(context).colorScheme.tertiary.withOpacity(0.1),
                      ),
                      child: Text(
                        _rirToggleTextTrend(),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.tertiary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),


          // 🔥 Graph
          Padding(

            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: AspectRatio(


              aspectRatio: 1.7,
              child: LineChart(
                LineChartData(
                  minX: -leftPadX,
                  maxX: spots.isEmpty ? rightPadX : (spots.length - 1 + rightPadX),
                  minY: scaleY.minY,
                  maxY: scaleY.maxY,

                  gridData: FlGridData(
                    show: true,
                    horizontalInterval: scaleY.interval,
                    getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10),
                    getDrawingVerticalLine: (_) => FlLine(color: Colors.white10),
                  ),

                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: scaleY.interval,
                        reservedSize: scaleY.decimals > 0 ? 44 : 36,
                        getTitlesWidget: (value, meta) {
                          // Hide the very top label (use epsilon for float safety)
                          const eps = 1e-6;
                          if ((meta.max - value).abs() < eps) {
                            return const SizedBox.shrink();
                          }
                          return Text(
                            scaleY.format(value),
                            style: const TextStyle(color: Colors.white, fontSize: 10),
                          );
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 1,
                        getTitlesWidget: (value, meta) {
                          // 1) Only draw at integer ticks (skip fractional values)
                          final double v = value;
                          final double vr = v.roundToDouble();
                          if ((v - vr).abs() > 1e-6) return const SizedBox.shrink();

                          // 2) Skip the phantom -0.0 tick caused by a small negative minX
                          if (v == 0.0 && v.isNegative) return const SizedBox.shrink();

                          // 3) Now safe to index labels
                          final int i = vr.toInt();
                          if (i < 0 || i >= labels.length) return const SizedBox.shrink();

                          // 4) Respect your evenly-spaced tick set
                          if (!xTickSet.contains(i)) return const SizedBox.shrink();

                          return SideTitleWidget(
                            axisSide: meta.axisSide,
                            child: Transform.rotate(
                              angle: shortRange ? -0.4 : -0.5,
                              child: Text(
                                labels[i],
                                style: const TextStyle(color: Colors.white, fontSize: 10),
                              ),
                            ),
                          );
                        },

                      ),
                    ),

                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),


                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: Theme.of(context).colorScheme.tertiary,
                      // 👇 Hide circles on long/wide views; show on short ones
                      dotData: FlDotData(show: shortRange),
                      // (Optional) slightly thicker line on long ranges
                      barWidth: shortRange ? 1.0 : 2.0,
                      belowBarData: BarAreaData(
                        show: true,
                        color: Theme.of(context).colorScheme.tertiary.withOpacity(0.1),
                      ),
                    ),
                  ],


                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      tooltipBgColor: Colors.grey[900]!,
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          final idx   = spot.x.toInt();
                          final inRan = idx >= 0 && idx < filtered.length;
                          final date  = inRan ? filtered[idx].date : null;

                          final e1rm = spot.y.toStringAsFixed(1);

                          String weightRepsLine = '';
                          String rirLine = '';

                          if (date != null) {
                            final meta = _metaAllTop[date];
                            if (meta != null) {
                              weightRepsLine = '${meta.weight.toStringAsFixed(1)} kg × ${meta.reps}';
                              if (meta.rir.abs() > 1e-6) {
                                rirLine = 'RIR ${meta.rir.toStringAsFixed(1)}';
                              }
                            }
                          }

                          // e.g., "23 July"
                          final dateStr = (date != null) ? DateFormat('d MMMM').format(date) : '';

                          final text = [
                            'E1RM: $e1rm kg',
                            if (weightRepsLine.isNotEmpty) weightRepsLine,
                            if (rirLine.isNotEmpty) rirLine,
                            if (dateStr.isNotEmpty) dateStr,
                          ].join('\n');

                          return LineTooltipItem(
                            text,
                            const TextStyle(color: Colors.white),
                          );
                        }).toList();
                      },


                    ),
                  ),
                ),
              ),
            ),
          ),

          // ──────────────────────────────────────────────────────────────
// E1RM @ Rep Target — Controls
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title button centered
                const SizedBox(height: 4),

                // Controls below, wrapping when needed
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // ── Reps (left, accepts lists/ranges: "4,6-8,10")
                      SizedBox(
                        width: 110, // more room; TextField will also auto-scroll horizontally
                        height: 32,
                        child: TextField(
                          controller: _repTargetCtrl,
                          keyboardType: TextInputType.text, // allow commas/dashes
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9,\-\s]*')), // digits, commas, dash, spaces
                          ],
                          onChanged: (s) => setState(() { _onRepTargetChanged(s); }),
                          cursorColor: Theme.of(context).colorScheme.tertiary,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.tertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Reps',
                            hintStyle: TextStyle(color: Theme.of(context).colorScheme.tertiary),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.tertiary.withOpacity(0.08),
                            enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Theme.of(context).colorScheme.tertiary),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Theme.of(context).colorScheme.tertiary, width: 1.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(width: 4),

                      // ── Title toggle (center)
                      Expanded(
                        child: Center(
                          child: SizedBox(
                            height: 36,
                            child: TextButton(
                              onPressed: _cycleTrendTarget,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal:6, vertical: 4),
                                minimumSize: const Size(0, 32),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  side: BorderSide(color: Theme.of(context).colorScheme.tertiary),
                                ),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _multiRepLabel(),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.tertiary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      _rangePickerButton(forRepTarget: true),
                      const SizedBox(width: 4),
                      // ── Include RIR (right, compact)
                      ConstrainedBox(
                        constraints: const BoxConstraints.tightFor(height: 32),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => setState(() => _includeRIRForTarget = !_includeRIRForTarget),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              border: Border.all(color: Theme.of(context).colorScheme.tertiary),
                              borderRadius: BorderRadius.circular(8),
                              color: Theme.of(context).colorScheme.tertiary.withOpacity(0.08),
                            ),
                            child: Text(
                              _rirToggleText(), // e.g. "Including RIR" / "Excluding RIR"
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.tertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      )

                    ],
                  ),
                )


              ],
            ),
          ),


// E1RM @ Rep Target — Chart
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: AspectRatio(
              aspectRatio: 1.7,
              child: LineChart(
                LineChartData(
                  minX: -leftPadX2,
                  maxX: masterDates2.isEmpty ? rightPadX2 : (masterDates2.length - 1 + rightPadX2),
                  minY: scaleY2.minY,
                  maxY: scaleY2.maxY,

                  gridData: FlGridData(
                    show: true,
                    horizontalInterval: scaleY2.interval,
                    getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10),
                    getDrawingVerticalLine: (_) => FlLine(color: Colors.white10),
                  ),

                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: scaleY2.interval,
                        reservedSize: scaleY2.decimals > 0 ? 44 : 36,
                        getTitlesWidget: (value, meta) {
                          const eps = 1e-6;
                          if ((meta.max - value).abs() < eps) return const SizedBox.shrink();
                          return Text(
                            scaleY2.format(value),
                            style: const TextStyle(color: Colors.white, fontSize: 10),
                          );
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 1,
                        getTitlesWidget: (value, meta) {
                          // fix duplicate '-0.0' tick
                          final double v = value;
                          final double vr = v.roundToDouble();
                          if ((v - vr).abs() > 1e-6) return const SizedBox.shrink();
                          if (v == 0.0 && v.isNegative) return const SizedBox.shrink();

                          final int i = vr.toInt();
                          if (i < 0 || i >= labels2.length) return const SizedBox.shrink();
                          if (!xTickSet2.contains(i)) return const SizedBox.shrink();

                          return SideTitleWidget(
                            axisSide: meta.axisSide,
                            child: Transform.rotate(
                              angle: short2 ? -0.4 : -0.5,
                              child: Text(
                                labels2[i],
                                style: const TextStyle(color: Colors.white, fontSize: 10),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),

                  lineBarsData: lineBarsData2,

                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      tooltipBgColor: Colors.grey[900]!,
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          final gi = spot.barIndex;              // which series
                          final xi = spot.x.toInt();             // index on shared axis
                          final date = (xi >= 0 && xi < masterDates2.length) ? masterDates2[xi] : null;
                          final e1rm = spot.y.toStringAsFixed(1);

                          // Look up actual performed set values captured earlier
                          String weightRepsLine = '';
                          String rirLine = '';
                          if (date != null && gi >= 0 && gi < metaByGroup.length) {
                            final meta = metaByGroup[gi][date];
                            if (meta != null) {
                              weightRepsLine = '${meta.weight.toStringAsFixed(1)} kg × ${meta.reps}';
                              if (meta.rir.abs() > 1e-6) {
                                rirLine = 'RIR ${meta.rir.toStringAsFixed(1)}';
                              }
                            }
                          }

                          // Full month name like "23 July"
                          final dateStr = (date != null) ? DateFormat('d MMMM').format(date) : '';

                          final text = [
                            'E1RM: $e1rm kg',
                            if (weightRepsLine.isNotEmpty) weightRepsLine,
                            if (rirLine.isNotEmpty) rirLine,
                            if (dateStr.isNotEmpty) dateStr,
                          ].join('\n');

                          return LineTooltipItem(
                            text,
                            const TextStyle(color: Colors.white),
                          );
                        }).toList();
                      },

                    ),
                  ),
                ),
              ),
            ),
          ),



          const Divider(color: Colors.white24),

          // 📋 Top Sets List
          const Padding(
            padding: EdgeInsets.only(left: 16, top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Top Sets:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 8),
      ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(), // parent scrolls everything
        itemCount: sortedWorkouts.length,
        itemBuilder: (context, index) {
          final revIndex = sortedWorkouts.length - 1 - index;
          final workout = sortedWorkouts[revIndex];
          final exercise = workout.exercises.firstWhere(
                (ex) => ex.name == widget.exerciseName,
            orElse: () => Exercise(name: '', sets: []),
          );

          if (exercise.sets.isEmpty) return const SizedBox.shrink();

          final topSet = exercise.sets.reduce((a, b) {
            final aE1 = calculateE1RM(a.weight ?? 0.0, (a.reps ?? 0).toDouble(), a.rir ?? 0.0);
            final bE1 = calculateE1RM(b.weight ?? 0.0, (b.reps ?? 0).toDouble(), b.rir ?? 0.0);
            return aE1 > bE1 ? a : b;
          });

          final bool isBw = PeriodizationModelUtils.isBodyweightExercise(
            id: widget.exerciseId,
            name: widget.exerciseName,
          );

          final double displayWeight = isBw
              ? PeriodizationModelUtils.toDisplayAddedWeight(
                  uid: userId,
                  absoluteKg: topSet.weight ?? 0.0,
                  exerciseId: widget.exerciseId,
                  exerciseName: widget.exerciseName,
                  asOfDate: workout.date,
                )
              : (topSet.weight ?? 0.0);

          final double e1rm = isBw
              ? PeriodizationModelUtils.e1rmForDisplay(
                  uid: userId,
                  absoluteKg: topSet.weight ?? 0.0,
                  reps: topSet.reps ?? 0,
                  rir: topSet.rir ?? 0.0,
                  exerciseId: widget.exerciseId,
                  exerciseName: widget.exerciseName,
                  asOfDate: workout.date,
                )
              : calculateE1RM(topSet.weight ?? 0.0, (topSet.reps ?? 0).toDouble(), topSet.rir ?? 0.0);

          final String weightLabel = isBw
              ? '+${displayWeight.toStringAsFixed(1)} kg'
              : '${displayWeight.toStringAsFixed(1)} kg';
          final String e1rmLabel = isBw
              ? '+${e1rm.toStringAsFixed(1)} kg'
              : '${e1rm.toStringAsFixed(1)} kg';

          return ListTile(
            title: Text(
              DateFormat('dd-MM-yyyy').format(workout.date),
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
            subtitle: Text(
              '$weightLabel × ${topSet.reps}, RIR ${topSet.rir} → E1RM: $e1rmLabel',
              style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
            ),
          );
        },
      )

    ],
      ),
    ));
  }
}
