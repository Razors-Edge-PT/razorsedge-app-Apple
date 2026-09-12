import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart';
import 'user_context.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart'; // for Timestamp & Firestore
import 'package:flutter/services.dart'; // for FilteringTextInputFormatter
import 'periodization_model_utils.dart';
import 'bodyweight_load.dart';
import 'exercise_catalog.dart';
import 'analytics_history_loader.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TrendRange { d14, m1, m6, y1, y2 }

/// The main-chart metric (section 3). E1RM is the default and the
/// frequently-used path; Velocity is opt-in and must never trigger its own
/// queries/aggregation until the user actually switches to it (section 6).
enum AnalyticsMetric { e1rm, velocity }

/// One entry in the Home exercise picker: an exercise this athlete has
/// recorded history for. ID-first — [id] is null only for legacy workout
/// entries recorded before exercise ids existed.
@immutable
class ExerciseHistoryOption {
  final String? id;
  final String name;
  const ExerciseHistoryOption({required this.id, required this.name});

  /// Stable dedup/lookup key: ID-first, falling back to a name key only when
  /// there truly is no id (see [exerciseEntryMatches] for why this must never
  /// let a name match override a conflicting id).
  String get key => (id != null && id!.isNotEmpty) ? 'id:$id' : 'name:${name.toLowerCase()}';

  @override
  bool operator ==(Object other) => other is ExerciseHistoryOption && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// One raw recorded set carrying an actual saved velocity, for the velocity
/// trend chart (section 4). Built straight from what was saved — never a
/// planned target, suggested value, or model hint.
@immutable
class VelocitySample {
  final DateTime date; // calendar day (local midnight) the set was performed
  final int reps;
  final double weight;
  final double velocity; // m/s, as saved on the set
  const VelocitySample({
    required this.date,
    required this.reps,
    required this.weight,
    required this.velocity,
  });
}

/// One plotted point on the velocity trend: the FASTEST recorded velocity
/// among every matching set completed that day (section 4) — across every
/// workout/entry that day, not just an E1RM-winning one.
@immutable
class VelocityPoint {
  final DateTime date;
  final double velocity;
  const VelocityPoint(this.date, this.velocity);

  @override
  bool operator ==(Object other) =>
      other is VelocityPoint && other.date == date && other.velocity == velocity;
  @override
  int get hashCode => Object.hash(date, velocity);
  @override
  String toString() => 'VelocityPoint($date, $velocity)';
}

/// Rounds a weight to the precision the app already stores/displays loads
/// at (0.01 kg) purely to absorb floating-point representation noise (e.g.
/// 82.5 vs 82.499999999998) when grouping/matching — NOT a "close enough"
/// tolerance and far finer than any plate increment, so genuinely distinct
/// loads are always preserved as distinct.
double normalizeLoadForGrouping(double weight) => (weight * 100).round() / 100;

/// Every recorded (reps, weight) combination for one exercise that has at
/// least one valid recorded velocity — i.e. "backed by actual recorded
/// velocity data" (section 4), never a planned/suggested value. Reps map to
/// the distinct weights recorded at that rep count, both sorted ascending.
class VelocityCombinations {
  final List<int> reps;
  final Map<int, List<double>> weightsByReps;
  const VelocityCombinations({required this.reps, required this.weightsByReps});

  static VelocityCombinations fromSamples(List<VelocitySample> samples) {
    final Map<int, Set<double>> byReps = {};
    for (final s in samples) {
      byReps.putIfAbsent(s.reps, () => <double>{}).add(s.weight);
    }
    final reps = byReps.keys.toList()..sort();
    final weightsByReps = <int, List<double>>{
      for (final r in reps) r: (byReps[r]!.toList()..sort()),
    };
    return VelocityCombinations(reps: reps, weightsByReps: weightsByReps);
  }

  bool isEligible(int reps, double weight) {
    final weights = weightsByReps[reps];
    if (weights == null) return false;
    final target = normalizeLoadForGrouping(weight);
    return weights.any((w) => normalizeLoadForGrouping(w) == target);
  }
}

/// For the exact (reps, weight) combination: one point per calendar day, the
/// FASTEST velocity among every matching recorded set that day (section 4).
/// Missing dates are simply absent — never synthesised as zero.
List<VelocityPoint> dailyMaxVelocity({
  required List<VelocitySample> samples,
  required int reps,
  required double weight,
}) {
  final target = normalizeLoadForGrouping(weight);
  final Map<DateTime, double> bestByDay = {};
  for (final s in samples) {
    if (s.reps != reps) continue;
    if (normalizeLoadForGrouping(s.weight) != target) continue;
    if (!s.velocity.isFinite || s.velocity <= 0) continue;
    final day = DateTime(s.date.year, s.date.month, s.date.day);
    final prev = bestByDay[day];
    if (prev == null || s.velocity > prev) bestByDay[day] = s.velocity;
  }
  final days = bestByDay.keys.toList()..sort();
  return [for (final d in days) VelocityPoint(d, bestByDay[d]!)];
}

/// Y-axis scale for the velocity chart. Deliberately separate from
/// [ChartAxisScale]: that scale's "nothing to draw" placeholder (0–20,
/// interval 5) and label formatting are tuned for kilogram-sized numbers, and
/// would render a velocity chart (values typically 0.1–3.0 m/s) as an
/// almost-flat line pinned to the bottom of a mostly-empty grid.
@immutable
class VelocityAxisScale {
  final double minY;
  final double maxY;
  final double interval;
  const VelocityAxisScale(
      {required this.minY, required this.maxY, required this.interval});

  /// Used when there is nothing to draw yet.
  static const VelocityAxisScale empty =
      VelocityAxisScale(minY: 0, maxY: 1.0, interval: 0.2);

  static const List<double> _steps = <double>[0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1.0];

  /// Always 3 decimals: recorded velocities are commonly saved to that
  /// precision, and the axis must be able to distinguish them.
  String format(double v) => v.toStringAsFixed(3);

  factory VelocityAxisScale.fromValues(Iterable<double> values) {
    double? lo, hi;
    for (final v in values) {
      if (!v.isFinite) continue;
      lo = (lo == null) ? v : math.min(lo, v);
      hi = (hi == null) ? v : math.max(hi, v);
    }
    if (lo == null || hi == null) return empty;

    final span = hi - lo;
    final pad = span <= 1e-9
        ? math.max(hi.abs() * 0.15, 0.02)
        : math.max(span * 0.15, 0.01);

    double axisMin = lo - pad;
    if (axisMin < 0) axisMin = 0; // velocity is never negative
    double axisMax = hi + pad;

    double interval = _steps.last;
    for (final s in _steps) {
      if ((axisMax - axisMin) / s <= 6) {
        interval = s;
        break;
      }
    }
    axisMin = (axisMin / interval).floorToDouble() * interval;
    axisMax = (axisMax / interval).ceilToDouble() * interval;
    if (axisMax - axisMin < interval) axisMax = axisMin + interval;
    return VelocityAxisScale(minY: axisMin, maxY: axisMax, interval: interval);
  }
}

/// ID-first exercise-entry matcher, shared by every history/top-sets lookup
/// in this screen. An entry that carries its own id must match it exactly
/// and can NEVER be matched by name instead — two different exercises can
/// share a display name (a rename, a reused label, a deleted-then-recreated
/// exercise), so a name match must never override a conflicting id. Only an
/// entry with no id at all (legacy data recorded before ids existed) falls
/// back to a name match.
bool exerciseEntryMatches(
  String? entryId,
  String? entryName, {
  required String? targetId,
  String? targetName,
}) {
  final id = (entryId ?? '').trim();
  if (id.isNotEmpty) {
    return targetId != null && targetId.isNotEmpty && id == targetId;
  }
  return targetName != null && (entryName ?? '') == targetName;
}

/// The E1RM/rep-target chart's [Workout] list for one exercise, derived
/// from shared raw docs (analytics_history_loader.dart) rather than a
/// per-exercise fetch — a top-level pure function so it's directly testable
/// without mounting the screen (see test/exercise_analytics_derivation_test.dart).
List<Workout> deriveWorkoutsForExercise({
  required List<RawWorkoutDoc> docs,
  required String? targetId,
  String? targetName,
}) {
  final out = <Workout>[];
  for (final raw in docs) {
    final matching = <Exercise>[];
    for (final e in raw.exercises) {
      final id = (e['id'] ?? e['exerciseId'])?.toString();
      final name = (e['name'])?.toString();
      if (exerciseEntryMatches(id, name, targetId: targetId, targetName: targetName)) {
        matching.add(Exercise.fromFirestore(e));
      }
    }
    if (matching.isEmpty) continue;
    out.add(Workout(name: 'Workout', date: raw.date, exercises: matching));
  }
  return out;
}

/// Every valid [VelocitySample] for one exercise, derived from shared raw
/// docs — scans EVERY matching entry per day (not just an E1RM winner), so
/// a fastest set outside the winning workout is never missed. A top-level
/// pure function for the same testability reason as [deriveWorkoutsForExercise].
List<VelocitySample> deriveVelocitySamplesForExercise({
  required List<RawWorkoutDoc> docs,
  required String? targetId,
  String? targetName,
}) {
  final out = <VelocitySample>[];
  for (final raw in docs) {
    for (final e in raw.exercises) {
      final rid = (e['id'] ?? e['exerciseId'])?.toString();
      final rname = (e['name'])?.toString();
      if (!exerciseEntryMatches(rid, rname, targetId: targetId, targetName: targetName)) {
        continue;
      }
      final sets = (e['sets'] as List?) ?? const [];
      for (final s in sets.cast<Map<String, dynamic>>()) {
        // Same parsing conventions as SetDetails.fromFirestore.
        final int? reps = (s['reps'] is int)
            ? s['reps'] as int
            : (s['reps'] is double)
                ? (s['reps'] as double).toInt()
                : int.tryParse(s['reps']?.toString() ?? '');
        final double? weight =
            (s['weight'] is num) ? (s['weight'] as num).toDouble() : null;
        final double? velocity = (s['velocity'] is num)
            ? (s['velocity'] as num).toDouble()
            : double.tryParse(s['velocity']?.toString() ?? '');

        if (reps == null || reps <= 0) continue;
        if (weight == null || weight <= 0) continue;
        // Valid, finite, positive only — absent/invalid values are
        // excluded outright, never coerced to zero (section 4).
        if (velocity == null || !velocity.isFinite || velocity <= 0) continue;
        out.add(VelocitySample(
          date: raw.date,
          reps: reps,
          weight: weight,
          velocity: velocity,
        ));
      }
    }
  }
  return out;
}

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

/// Shared analytics page for BB3, WES2, and Home. BB3/WES2/workout-history
/// entry points pass [exerciseId] and open with that exercise preselected;
/// Home opens with [exerciseId] null, showing the exercise picker (restoring
/// this athlete's last-selected exercise when one exists) — no active
/// training block or BB3/WES2 screen is required either way.
class ExerciseDetailsScreen extends StatefulWidget {
  final String? exerciseId;             // null → Home's "pick an exercise" entry
  final String? exerciseName;           // 👈 optional, only for display
  final List<Workout>? recentWorkouts;  // optional; if null, we fetch

  const ExerciseDetailsScreen({
    super.key,
    this.exerciseId,
    this.exerciseName,
    this.recentWorkouts,
  });

  @override
  State<ExerciseDetailsScreen> createState() => _ExerciseDetailsScreenState();
}

class _ExerciseDetailsScreenState extends State<ExerciseDetailsScreen> {
  /// Earliest date any picker/range in this screen will look back to —
  /// matches the bodyweight entry editor's boundary (body_weight_tracker.dart).
  static DateTime get _minSupportedDate => DateTime(2000, 1, 1);

  /// Every workout document for the current athlete, deduplicated by
  /// document id, with coalesced coverage requests and authoritative
  /// refreshes (analytics_history_loader.dart). ONE instance per athlete —
  /// exercise selection never resets it, since raw documents belong to the
  /// athlete, not to whichever exercise happened to trigger a fetch that
  /// read them (this is what makes switching exercises mid-fetch safe:
  /// there is no such thing as "the previous exercise's fetch", only "more
  /// of this athlete's history", merged in regardless of what's currently
  /// selected — see issue 1 in the review of commit 53df026f).
  AnalyticsHistoryLoader? _loader;

  void _onLoaderChanged() {
    if (mounted) setState(() {});
  }

  /// The currently displayed exercise. Starts as [ExerciseDetailsScreen]'s
  /// constructor values (BB3/WES2/workout-history preselect it); Home leaves
  /// both null and the picker below fills them in — restored from this
  /// athlete's last selection when one exists, or chosen from the dropdown.
  String? _activeExerciseId;
  String? _activeExerciseName;

  bool get _hasExercise => _activeExerciseId != null || _activeExerciseName != null;

  bool _restoringLastExercise = false;

  /// Extends [_loader]'s coverage all the way back once a user explicitly
  /// asks for older exercises in the picker (never automatic — see issue 3).
  bool _loadingOlderExercises = false;

  TrendRange _trend = TrendRange.d14; // 👈 our new toggle state

  // --- Custom date range state (independent per chart) ---
  DateTimeRange? _customTrend; // E1RM Trend chart
  DateTimeRange? _customTarget; // Rep Target chart

  String get userId => UserContext.of(context, listen: false).currentUid;

  bool _includeRIRForTrend = true;
  String _rirToggleTextTrend() =>
      _includeRIRForTrend ? 'Including RIR' : 'Excluding RIR';

  // --- E1RM / Velocity metric selection (section 3) ---
  AnalyticsMetric _metric = AnalyticsMetric.e1rm;

  // --- Velocity state: kept entirely separate from the E1RM trend state so
  // switching metrics restores each mode's own view (section 3/4). No
  // velocity fetch/processing happens until the user switches to this mode
  // (section 6) — see _onVelocitySelected. Samples themselves are derived
  // from _loader's shared raw docs, not fetched separately (issue 1/3).
  TrendRange _velocityTrend = TrendRange.d14;
  DateTimeRange? _customVelocityTrend;
  int? _selectedVelocityReps;
  double? _selectedVelocityWeight;

  /// Weigh-ins are athlete-scoped, not exercise-scoped, so this only ever
  /// needs to run once per athlete session (issue 6's "never fetch weigh-ins
  /// for a non-BW exercise" performance fix, made idempotent).
  bool _bwPrimed = false;

  /// The load a set is charted and ranked at. For a bodyweight exercise that
  /// is its TOTAL load at the bodyweight recorded on or before [date] —
  /// WES2 stores the added load, the legacy screen stored the total
  /// (bodyweight_load.dart) — or null when that total is unknown. Every other
  /// exercise: the stored weight, exactly as before.
  double? _chartWeight(SetDetails s, DateTime date) {
    final bool isBw = PeriodizationModelUtils.isBodyweightExercise(
      id: _activeExerciseId,
      name: _activeExerciseName,
    );
    if (!isBw) return s.weight ?? 0.0;
    return s
        .bodyweightLoad(PeriodizationModelUtils.recordedBodyweightKgOnOrBefore(
            uid: userId, asOf: date))
        .totalKg;
  }

  double calculateE1RM(double weight, double reps, double rir) {
    return PeriodizationModelUtils.calculateE1RM(weight, reps, rir);
  }



  /// The E1RM/rep-target chart data, freshly derived from [_loader]'s shared
  /// raw docs every time this is read — never cached per-exercise, so an
  /// in-flight fetch that resolves after the user switches exercises can
  /// only ever contribute more of the athlete's raw history, never
  /// "the previous exercise's data" (issue 1).
  List<Workout> _deriveWorkouts() {
    final loader = _loader;
    if (loader == null || !_hasExercise) return const [];
    return deriveWorkoutsForExercise(
      docs: loader.docs,
      targetId: _activeExerciseId,
      targetName: _activeExerciseName,
    );
  }

  /// The deepest coverage the E1RM trend and rep-target charts currently
  /// need — they share one fetch, so requesting coverage for one must
  /// account for the other's independently-selected range too (issue 2).
  DateTime _deepestE1rmCutoff() {
    final trendCutoff = _customTrend?.start ?? _cutoffFor(_trend);
    final targetCutoff = _customTarget?.start ?? _cutoffFor(_trendTarget);
    return trendCutoff.isBefore(targetCutoff) ? trendCutoff : targetCutoff;
  }

  /// True once the currently active E1RM/rep-target window is fully,
  /// authoritatively loaded — never true merely because SOME data has
  /// arrived (issue 2: a preview must stay visibly distinct from "finished
  /// loading the selected period").
  bool get _e1rmWindowReady =>
      _loader != null && _loader!.coversSince(_deepestE1rmCutoff());

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


  void _cycleTrend() {
    final values = TrendRange.values;
    final i = values.indexOf(_trend);
    setState(() {
      _trend = values[(i + 1) % values.length];
      _customTrend = null; // picking a preset leaves custom mode
    });
    // Longer presets may reach further back than what's loaded — extend the
    // window on demand instead of eagerly preloading years of history.
    // ignore: discarded_futures
    _loader?.requestCoverage(_deepestE1rmCutoff());
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
    final bool loading = _loader?.loading ?? false;

    return Tooltip(
      message: 'Custom date range',
      child: SizedBox(
        width: 34,
        height: 32,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: loading ? null : () => _pickCustomRange(forRepTarget: forRepTarget),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: accent),
              borderRadius: BorderRadius.circular(8),
              color: accent.withOpacity(active ? 0.28 : 0.08),
            ),
            child: loading
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
    if (picked == null || !mounted) return; // cancelling changes nothing

    setState(() {
      if (forRepTarget) {
        _customTarget = picked;
      } else {
        _customTrend = picked;
      }
    });

    // ignore: discarded_futures
    _loader?.requestCoverage(picked.start);
  }

  // ───────────────────────── Velocity (section 4) ─────────────────────────
  //
  // Deliberately no separate fetch: velocity is derived from the SAME
  // shared raw docs E1RM uses (_deriveVelocitySamples), just scanning every
  // matching entry per day instead of collapsing to one winner — so it
  // needs zero Firestore work of its own once the athlete's raw history
  // already covers the relevant window (section 6/issue 3). What it DOES
  // need is coverage older than E1RM's window typically requests, to find
  // combinations that haven't been used recently (issue 4) —
  // _discoverVelocityHistoryProgressively extends the SAME loader for that,
  // but only ever starting once the user actually selects Velocity mode.

  bool _velocityDiscoveryInFlight = false;

  /// True once we've CONFIRMED there's nothing older left to find — never
  /// true merely because the current chart window happens to be loaded
  /// (issue 4: "no history" must never be claimed before discovery
  /// completes).
  bool get _velocityDiscoveryComplete =>
      _loader?.coversSince(_minSupportedDate) ?? false;

  /// Every recorded set for the active exercise carrying a valid velocity,
  /// scanning every matching entry per day (not just that day's E1RM
  /// winner) so a fastest set outside the winning workout is never missed.
  /// Derived fresh from [_loader]'s shared raw docs — never fetched
  /// separately, and never affected by which exercise happened to be
  /// selected when any given raw document was originally read (issue 1).
  List<VelocitySample> _deriveVelocitySamples() {
    final loader = _loader;
    if (loader == null || !_hasExercise) return const [];
    return deriveVelocitySamplesForExercise(
      docs: loader.docs,
      targetId: _activeExerciseId,
      targetName: _activeExerciseName,
    );
  }

  /// Progressively extends [_loader]'s coverage back to [_minSupportedDate]
  /// so older velocity combinations become discoverable (issue 4), in
  /// stages so the UI updates as each one lands rather than blocking on the
  /// whole history at once. Only ever started from [_setMetric] switching
  /// INTO Velocity mode — never automatically (issue 3/6).
  Future<void> _discoverVelocityHistoryProgressively() async {
    if (_velocityDiscoveryInFlight || _velocityDiscoveryComplete) return;
    final loader = _loader;
    if (loader == null) return;
    _velocityDiscoveryInFlight = true;
    try {
      final now = DateTime.now();
      final stages = <DateTime>[
        now.subtract(const Duration(days: 365)),
        now.subtract(const Duration(days: 365 * 3)),
        _minSupportedDate,
      ];
      for (final stageTarget in stages) {
        final target =
            stageTarget.isBefore(_minSupportedDate) ? _minSupportedDate : stageTarget;
        try {
          await loader.requestCoverage(target);
        } catch (_) {
          break; // the loader's own error state already surfaces this
        }
        if (!mounted || loader != _loader) return;
        if (!target.isAfter(_minSupportedDate)) break;
      }
    } finally {
      _velocityDiscoveryInFlight = false;
    }
  }

  void _setMetric(AnalyticsMetric metric) {
    if (_metric == metric) return;
    setState(() => _metric = metric);
    if (metric == AnalyticsMetric.velocity) {
      // First switch into Velocity mode for this exercise — the only place
      // any velocity-specific work is triggered (section 6).
      // ignore: discarded_futures
      _discoverVelocityHistoryProgressively();
    }
  }

  void _cycleVelocityTrend() {
    final values = TrendRange.values;
    final i = values.indexOf(_velocityTrend);
    setState(() {
      _velocityTrend = values[(i + 1) % values.length];
      _customVelocityTrend = null;
    });
    // Date changes must never reset the selected reps/load combination.
    // ignore: discarded_futures
    _loader?.requestCoverage(_cutoffFor(_velocityTrend));
  }

  /// Native Material range picker for the velocity chart — mirrors
  /// _pickCustomRange's interaction/styling, kept separate so the existing
  /// E1RM/rep-target pickers are never touched by this feature.
  Future<void> _pickCustomVelocityRange() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstDate = _minSupportedDate;

    final existing = _customVelocityTrend;
    final presetStart = _cutoffFor(_velocityTrend);

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
      helpText: 'Velocity range',
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
    if (picked == null || !mounted) return; // cancelling changes nothing

    setState(() => _customVelocityTrend = picked);
    // The selected combination is deliberately left untouched here.
    // ignore: discarded_futures
    _loader?.requestCoverage(picked.start);
  }

  // ─────────────────── Exercise identity / picker (section 2) ───────────────────

  static String _lastExercisePrefsKey(String uid) =>
      'analytics_last_exercise:$uid';

  Future<ExerciseHistoryOption?> _readLastSelectedExercise(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastExercisePrefsKey(uid));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final name = (decoded['name'] as String?) ?? '';
        final id = decoded['id'] as String?;
        if (name.isEmpty && (id == null || id.isEmpty)) return null;
        return ExerciseHistoryOption(id: id, name: name);
      }
    } catch (_) {/* treat as "nothing saved yet" */}
    return null;
  }

  Future<void> _persistLastSelectedExercise(
      String uid, ExerciseHistoryOption option) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _lastExercisePrefsKey(uid),
        jsonEncode({'id': option.id, 'name': option.name}),
      );
    } catch (_) {/* best-effort only */}
  }

  /// Best-effort catalogue name lookup, loaded once per athlete session —
  /// used only to prefer a current/renamed display name over whatever a
  /// workout document happened to store; a failure just falls back to the
  /// stored name, which is exactly right for a historical/deleted exercise.
  Map<String, String>? _catalogNameById;

  Future<void> _loadCatalogNames(String uid) async {
    try {
      final catalog = await ExerciseCatalog.loadCombinedExercisesForUser(uid);
      if (!mounted) return;
      setState(() {
        _catalogNameById = {for (final c in catalog) c.id: c.name};
      });
    } catch (_) {
      /* keep falling back to stored names */
    }
  }

  /// Every exercise this athlete has recorded history for WITHIN whatever
  /// [_loader] currently covers — derived synchronously from the same raw
  /// docs E1RM/velocity already use (issue 3: reuse raw documents already
  /// read; avoid a duplicate discovery fetch). Grows automatically as
  /// coverage deepens (an explicit "load older" tap, or velocity's
  /// progressive discovery), and always includes the active exercise even
  /// if it falls outside the currently-loaded window.
  List<ExerciseHistoryOption> _deriveExerciseOptions() {
    final loader = _loader;
    final catalogNameById = _catalogNameById;
    final seen = <String, ExerciseHistoryOption>{};
    if (loader != null) {
      for (final raw in loader.docs) {
        for (final e in raw.exercises) {
          final id = (e['id'] ?? e['exerciseId'])?.toString();
          final rawName = (e['name'] ?? '').toString();
          final validId = (id != null && id.isNotEmpty) ? id : null;
          if (rawName.isEmpty && validId == null) continue;
          final displayName =
              (validId != null && catalogNameById != null && catalogNameById.containsKey(validId))
                  ? catalogNameById[validId]!
                  : rawName;
          final option = ExerciseHistoryOption(
            id: validId,
            name: displayName.isEmpty ? 'Unnamed exercise' : displayName,
          );
          seen.putIfAbsent(option.key, () => option);
        }
      }
    }
    if (_hasExercise) {
      final active = ExerciseHistoryOption(
          id: _activeExerciseId, name: _activeExerciseName ?? '(unnamed)');
      seen.putIfAbsent(active.key, () => active);
    }
    final list = seen.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Extends coverage all the way back so older exercises become
  /// discoverable — only ever run from an explicit picker interaction
  /// (issue 3), never automatically.
  Future<void> _loadOlderExercises() async {
    if (_loadingOlderExercises) return;
    setState(() => _loadingOlderExercises = true);
    try {
      await _loader?.requestCoverage(_minSupportedDate);
    } catch (_) {
      /* the loader's own error state already surfaces this */
    } finally {
      if (mounted) setState(() => _loadingOlderExercises = false);
    }
  }

  void _maybePrimeBodyweight(String uid) {
    if (_bwPrimed) return; // athlete-scoped: needed at most once (section 6)
    final isBw = PeriodizationModelUtils.isBodyweightExercise(
      id: _activeExerciseId,
      name: _activeExerciseName,
    );
    if (!isBw) return; // never fetch weigh-ins for a non-BW exercise
    _bwPrimed = true;
    _primeBwHistory(uid).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Switches the active exercise (Home's picker). Deliberately lightweight:
  /// raw history is athlete-scoped, not exercise-scoped, so switching
  /// exercises needs no new fetch and cannot be corrupted by one already in
  /// flight (issue 1) — only the exercise-specific selection resets.
  /// [persist] is true only for an explicit user pick, not the initial
  /// restore, so opening with a restored exercise doesn't rewrite the same
  /// value right back.
  void _selectExercise(ExerciseHistoryOption option, {bool persist = false}) {
    final uid = UserContext.of(context, listen: false).currentUid;
    setState(() {
      _activeExerciseId = option.id;
      _activeExerciseName = option.name;
      _selectedVelocityReps = null;
      _selectedVelocityWeight = null;
    });
    if (persist) {
      // ignore: discarded_futures
      _persistLastSelectedExercise(uid, option);
    }
    _maybePrimeBodyweight(uid);
    // Defensive: coverage is athlete-wide, so this is normally already
    // satisfied, but an exercise switch must never leave the retained
    // visible window under-covered (issue 2) regardless of ordering.
    // ignore: discarded_futures
    _loader?.requestCoverage(_deepestE1rmCutoff());
    if (_metric == AnalyticsMetric.velocity) {
      // ignore: discarded_futures
      _discoverVelocityHistoryProgressively();
    }
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

  // ─────────────────────── Exercise picker UI (section 2) ───────────────────

  Widget _buildExercisePicker(BuildContext context) {
    final accent = Theme.of(context).colorScheme.tertiary;
    final activeOption = _hasExercise
        ? ExerciseHistoryOption(
            id: _activeExerciseId, name: _activeExerciseName ?? '(unnamed)')
        : null;

    final items = _deriveExerciseOptions();
    // Distinct from "nothing found in what's loaded so far" (issue 3) —
    // only true once discovery has actually reached the supported minimum.
    final bool fullyDiscovered =
        _loader?.coversSince(_minSupportedDate) ?? false;

    Widget loadOlderButton() => Align(
          alignment: Alignment.center,
          child: TextButton(
            onPressed: _loadingOlderExercises ? null : _loadOlderExercises,
            child: _loadingOlderExercises
                ? SizedBox(
                    height: 14,
                    width: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                  )
                : Text('Load older exercises',
                    style: TextStyle(color: accent, fontSize: 12)),
          ),
        );

    if (items.isEmpty) {
      if (_restoringLastExercise || (_loader?.loading ?? false)) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Center(
            child: SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Text(
              fullyDiscovered
                  ? 'No exercises with recorded history yet.'
                  : 'No exercises found in the loaded range yet.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (!fullyDiscovered) ...[
              const SizedBox(height: 4),
              loadOlderButton(),
            ],
          ],
        ),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: accent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<ExerciseHistoryOption>(
              isExpanded: true,
              value: activeOption,
              hint: const Text('Select an exercise',
                  style: TextStyle(color: Colors.white70)),
              dropdownColor: Colors.grey[900],
              icon: Icon(Icons.arrow_drop_down, color: accent),
              items: [
                for (final o in items)
                  DropdownMenuItem(
                    value: o,
                    child: Text(o.name,
                        style: const TextStyle(color: Colors.white),
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (picked) {
                if (picked == null || picked == activeOption) return;
                _selectExercise(picked, persist: true);
              },
            ),
          ),
        ),
        if (!fullyDiscovered) ...[
          const SizedBox(height: 2),
          loadOlderButton(),
        ],
      ],
    );
  }

  Widget _buildNoExerciseSelectedState(BuildContext context) {
    final bool fullyDiscovered =
        _loader?.coversSince(_minSupportedDate) ?? false;
    final message = (fullyDiscovered && _deriveExerciseOptions().isEmpty)
        ? 'No exercises with recorded history yet.'
        : 'Pick an exercise above to see its analytics.';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 15),
        ),
      ),
    );
  }

  // ─────────────────────── Metric selector UI (section 3) ───────────────────

  Widget _buildMetricSelector(BuildContext context) {
    final accent = Theme.of(context).colorScheme.tertiary;
    Widget seg(String label, AnalyticsMetric value) {
      final active = _metric == value;
      return Expanded(
        child: InkWell(
          onTap: () => _setMetric(value),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? accent.withOpacity(0.25) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accent),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: accent,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        seg('E1RM', AnalyticsMetric.e1rm),
        const SizedBox(width: 8),
        seg('Velocity', AnalyticsMetric.velocity),
      ],
    );
  }

  // ─────────────────────── Velocity chart UI (section 4) ─────────────────────

  Widget _velocityRangePickerButton() {
    final accent = Theme.of(context).colorScheme.tertiary;
    final bool active = _customVelocityTrend != null;
    final bool loading = _loader?.loading ?? false;
    return Tooltip(
      message: 'Custom date range',
      child: SizedBox(
        width: 34,
        height: 32,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: loading ? null : _pickCustomVelocityRange,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: accent),
              borderRadius: BorderRadius.circular(8),
              color: accent.withOpacity(active ? 0.28 : 0.08),
            ),
            child: loading
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: accent),
                  )
                : Icon(Icons.date_range, size: 16, color: accent),
          ),
        ),
      ),
    );
  }

  Widget _velocityDropdown<T>({
    required String label,
    required T? value,
    required List<T> items,
    required String Function(T) display,
    required ValueChanged<T?>? onChanged,
  }) {
    final accent = Theme.of(context).colorScheme.tertiary;
    final enabled = onChanged != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: enabled ? accent : Colors.white24),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          value: value,
          hint: Text(label, style: const TextStyle(color: Colors.white70)),
          dropdownColor: Colors.grey[900],
          icon: Icon(Icons.arrow_drop_down,
              color: enabled ? accent : Colors.white24),
          items: [
            for (final it in items)
              DropdownMenuItem(
                value: it,
                child: Text(display(it),
                    style: const TextStyle(color: Colors.white)),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  String _formatKg(double w) =>
      '${w.toStringAsFixed(w == w.truncateToDouble() ? 0 : 1)} kg';

  /// Builds the velocity title row, dropdowns, and chart (or its loading /
  /// empty / one-point / error states). Returns a flat widget list so the
  /// caller can splice it directly into the existing body Column.
  List<Widget> _buildVelocitySection(BuildContext context) {
    final accent = Theme.of(context).colorScheme.tertiary;

    final titleRow = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: TextButton.icon(
              onPressed: _cycleVelocityTrend,
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  'Velocity • ${_rangeLabelFor(_velocityTrend, _customVelocityTrend)}',
                  style: TextStyle(color: accent, fontWeight: FontWeight.w600),
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                foregroundColor: accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: accent),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _velocityRangePickerButton(),
        ],
      ),
    );

    Widget message(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
          ),
        );

    final velocitySamples = _deriveVelocitySamples();
    final loader = _loader;
    final bool discoveryComplete = _velocityDiscoveryComplete;
    final String? loaderError = loader?.error;
    final bool discovering = (loader?.loading ?? false) || _velocityDiscoveryInFlight;

    Widget discoveringNote() => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                  height: 12, width: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: accent)),
              const SizedBox(width: 6),
              Text('Looking for older recorded data…',
                  style: TextStyle(color: accent.withValues(alpha: 0.8), fontSize: 11)),
            ],
          ),
        );

    if (velocitySamples.isEmpty) {
      if (loaderError != null) {
        return [
          titleRow,
          message('Could not load velocity data. Tap to retry.'),
          Center(
            child: TextButton(
              onPressed: () {
                // ignore: discarded_futures
                _discoverVelocityHistoryProgressively();
              },
              child: Text('Retry', style: TextStyle(color: accent)),
            ),
          ),
        ];
      }
      if (!discoveryComplete) {
        // Discovery hasn't finished — this must never be reported as "no
        // history" (issue 4), whether or not a fetch happens to be running
        // right this instant.
        return [
          titleRow,
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
          discoveringNote(),
        ];
      }
      return [
        titleRow,
        message('No recorded velocity data for this exercise yet.'),
      ];
    }

    final combos = VelocityCombinations.fromSamples(velocitySamples);

    // Keep a valid selection; drop it only if it no longer exists at all
    // (date-window changes must never clear a still-valid combination).
    final int? reps =
        (_selectedVelocityReps != null && combos.reps.contains(_selectedVelocityReps))
            ? _selectedVelocityReps
            : null;
    final weightsForReps = reps != null ? combos.weightsByReps[reps]! : const <double>[];
    final double? weight = (reps != null &&
            _selectedVelocityWeight != null &&
            weightsForReps.any((w) =>
                normalizeLoadForGrouping(w) ==
                normalizeLoadForGrouping(_selectedVelocityWeight!)))
        ? _selectedVelocityWeight
        : null;

    final dropdownsRow = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _velocityDropdown<int>(
                  label: 'Reps',
                  value: reps,
                  items: combos.reps,
                  display: (r) => '$r reps',
                  onChanged: (v) => setState(() {
                    _selectedVelocityReps = v;
                    _selectedVelocityWeight = null; // weight is dependent on reps
                  }),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _velocityDropdown<double>(
                  label: 'Load',
                  value: weight,
                  items: weightsForReps,
                  display: _formatKg,
                  onChanged: reps == null
                      ? null
                      : (v) => setState(() => _selectedVelocityWeight = v),
                ),
              ),
            ],
          ),
          if (!discoveryComplete && discovering) discoveringNote(),
        ],
      ),
    );

    if (reps == null || weight == null) {
      return [
        titleRow,
        dropdownsRow,
        message('Select reps and load to see the trend.'),
      ];
    }

    final window = _windowFor(_velocityTrend, _customVelocityTrend);
    final points = dailyMaxVelocity(
      samples: velocitySamples,
      reps: reps,
      weight: weight,
    ).where((p) => window.contains(p.date)).toList();

    if (points.isEmpty) {
      return [titleRow, dropdownsRow, message('No data for this range')];
    }

    final dates = [for (final p in points) p.date];
    final xTicks = computeXTickIndices(dates.length);
    final labels = buildXAxisLabels(dates, xTicks);
    final spots = [
      for (int i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].velocity)
    ];
    final scaleY = VelocityAxisScale.fromValues(points.map((p) => p.velocity));
    final bool shortRange = points.length <= 20;
    final double leftPadX = shortRange ? 0.10 : 0.20;
    final double rightPadX = shortRange ? 0.10 : 0.15;

    final chart = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: AspectRatio(
        aspectRatio: 1.7,
        child: LineChart(
          LineChartData(
            minX: -leftPadX,
            maxX: spots.length - 1 + rightPadX,
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
                  reservedSize: 52,
                  getTitlesWidget: (value, meta) {
                    const eps = 1e-9;
                    if ((meta.max - value).abs() < eps) {
                      return const SizedBox.shrink();
                    }
                    return Text('${scaleY.format(value)} m/s',
                        style: const TextStyle(color: Colors.white, fontSize: 9));
                  },
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  interval: 1,
                  getTitlesWidget: (value, meta) {
                    final vr = value.roundToDouble();
                    if ((value - vr).abs() > 1e-6) return const SizedBox.shrink();
                    if (vr == 0.0 && value.isNegative) return const SizedBox.shrink();
                    final i = vr.toInt();
                    if (i < 0 || i >= labels.length || !xTicks.contains(i)) {
                      return const SizedBox.shrink();
                    }
                    return SideTitleWidget(
                      axisSide: meta.axisSide,
                      child: Transform.rotate(
                        angle: -0.5,
                        child: Text(labels[i],
                            style: const TextStyle(color: Colors.white, fontSize: 10)),
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
                isCurved: false,
                color: accent,
                dotData: FlDotData(show: true),
                barWidth: 2.0,
              ),
            ],
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                tooltipBgColor: Colors.grey[900]!,
                fitInsideHorizontally: true,
                fitInsideVertically: true,
                getTooltipItems: (touchedSpots) {
                  return touchedSpots.map((spot) {
                    final idx = spot.x.toInt();
                    if (idx < 0 || idx >= points.length) return null;
                    final p = points[idx];
                    final dateStr = DateFormat('d MMMM').format(p.date);
                    final text = [
                      _activeExerciseName ?? 'Exercise',
                      '$reps reps × ${_formatKg(weight)}',
                      '${p.velocity.toStringAsFixed(3)} m/s',
                      dateStr,
                    ].join('\n');
                    return LineTooltipItem(text, const TextStyle(color: Colors.white));
                  }).whereType<LineTooltipItem>().toList();
                },
              ),
            ),
          ),
        ),
      ),
    );

    return [titleRow, dropdownsRow, chart];
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
    // ignore: discarded_futures
    _loader?.requestCoverage(_deepestE1rmCutoff());
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
          entries.add({
            'date': ts,
            'weight': bw,
            'unit': 'kg',
            'tod': data['tod'],
            'id': d.id,
          });
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
    _onRepTargetChanged(_repTargetCtrl.text); // seed groups from "5"
    final selectedUid = UserContext.of(context, listen: false).currentUid;

    _activeExerciseId = widget.exerciseId;
    _activeExerciseName = widget.exerciseName;

    final loader = AnalyticsHistoryLoader(
      uid: selectedUid,
      fetcher: ({required since}) =>
          fetchRawWorkoutDocsFromFirestore(uid: selectedUid, since: since),
    );
    loader.addListener(_onLoaderChanged);
    _loader = loader;

    // Best-effort catalogue names for the picker (a rename, or a nicer
    // label than a raw stored one) — never blocks anything.
    // ignore: discarded_futures
    _loadCatalogNames(selectedUid);

    if (_hasExercise) {
      // BB3/WES2/workout-history entry: preselected, render immediately —
      // only the active window's coverage is requested (section 6), never
      // a full-history scan.
      // ignore: discarded_futures
      loader.requestCoverage(_deepestE1rmCutoff());
      _maybePrimeBodyweight(selectedUid);
    } else {
      // Home entry with nothing preselected: request enough recent history
      // for the picker to be usable immediately (issue 3 — bounded, not a
      // full scan), and separately restore this athlete's last valid
      // selection without waiting for that fetch to finish.
      // ignore: discarded_futures
      loader.requestCoverage(DateTime.now().subtract(const Duration(days: 90)));

      setState(() => _restoringLastExercise = true);
      _readLastSelectedExercise(selectedUid).then((restored) {
        if (!mounted) return;
        setState(() => _restoringLastExercise = false);
        if (restored != null) {
          _selectExercise(restored); // not persisted again — already stored
          // The restored exercise renders immediately from whatever's
          // already loaded/loading; ensure its own default window too.
          // ignore: discarded_futures
          loader.requestCoverage(_cutoffFor(TrendRange.d14));
        }
      });
    }
  }

  @override
  void dispose() {
    _repTargetCtrl.dispose();
    _loader?.removeListener(_onLoaderChanged);
    _loader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Full history (used by the list below), freshly derived from the
    // shared raw-doc cache every build — never stale per-exercise (issue 1).
    final List<Workout> sortedWorkouts = _deriveWorkouts()
      ..sort((a, b) => a.date.compareTo(b.date));

    final List<E1RMPoint> series = [];
    final Map<DateTime, _PointMeta> _metaAllTop = {};

    int matchedWorkouts = 0;

    for (final workout in sortedWorkouts) {
      // ID-first: an entry with its own id must match it exactly and can
      // never be matched by name instead (exerciseEntryMatches).
      final ex = workout.exercises.firstWhere(
        (e) => exerciseEntryMatches(e.id, e.name,
            targetId: _activeExerciseId, targetName: _activeExerciseName),
        orElse: () => Exercise(name: '', sets: const [], circuitIndex: 0),
      );
      if (ex.name.isEmpty || ex.sets.isEmpty) continue;

      matchedWorkouts++;

      final top = ex.sets.reduce((a, b) {
        final aE1 = calculateE1RM(_chartWeight(a, workout.date) ?? 0.0, (a.reps ?? 0).toDouble(), a.rir ?? 0.0);
        final bE1 = calculateE1RM(_chartWeight(b, workout.date) ?? 0.0, (b.reps ?? 0).toDouble(), b.rir ?? 0.0);
        return aE1 > bE1 ? a : b;
      });

      final double? topW = _chartWeight(top, workout.date);
      if (topW == null) continue;
      final e1 = calculateE1RM(topW, (top.reps ?? 0).toDouble(), _includeRIRForTrend ? (top.rir ?? 0.0) : 0.0);
      series.add(E1RMPoint(workout.date, e1));
      _metaAllTop[workout.date] = _PointMeta(
        topW,
        (top.reps ?? 0),
        (top.rir ?? 0.0),
      );

    }

    print('📊 [Details] Workouts total=${sortedWorkouts.length}, matched=$matchedWorkouts, points=${series.length}');

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
        // ID-first (exerciseEntryMatches): an entry's own id, when present,
        // can never be overridden by a coincidental name match.
        final ex = workout.exercises.firstWhere(
          (e) => exerciseEntryMatches(e.id, e.name,
              targetId: _activeExerciseId, targetName: _activeExerciseName),
          orElse: () => Exercise(name: '', sets: const [], circuitIndex: 0),
        );
        if (ex.sets.isEmpty) continue;

        // choose THE day's top set USING RIR
        SetDetails? topSetInc;
        double bestInc = double.negativeInfinity;
        for (final s in ex.sets) {
          final w = _chartWeight(s, workout.date) ?? 0.0;
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
        final w = _chartWeight(topSetInc!, workout.date) ?? 0.0;
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
              _activeExerciseName ?? 'Analytics',
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
          // Exercise picker (Home's entry point; BB3/WES2 arrive preselected
          // but can still switch here — "one shared Analytics page").
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _buildExercisePicker(context),
          ),

          if (_hasExercise) ...[
            // Compact E1RM / Velocity selector (section 3). Default: E1RM.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: _buildMetricSelector(context),
            ),

          if (_metric == AnalyticsMetric.e1rm) ...[
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

          // A preview must stay visibly distinct from "finished loading the
          // selected period" (issue 2) — shown additively, without touching
          // the title row/controls above.
          if (!_e1rmWindowReady && (_loader?.loading ?? false))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 12,
                    width: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Loading the full selected period…',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.8),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            )
          else if (!_e1rmWindowReady && _loader?.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Center(
                child: TextButton(
                  onPressed: () {
                    // ignore: discarded_futures
                    _loader?.requestCoverage(_deepestE1rmCutoff());
                  },
                  child: Text('Could not load the full period. Tap to retry.',
                      style: TextStyle(color: Theme.of(context).colorScheme.tertiary)),
                ),
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
          ] else
            ..._buildVelocitySection(context),
          ], // if (_hasExercise)
          if (!_hasExercise) _buildNoExerciseSelectedState(context),

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
          // ID-first (exerciseEntryMatches) — this list used to match by
          // name alone, so a same-named but different-id entry could show
          // the wrong exercise's top sets.
          final exercise = workout.exercises.firstWhere(
            (ex) => exerciseEntryMatches(ex.id, ex.name,
                targetId: _activeExerciseId, targetName: _activeExerciseName),
            orElse: () => Exercise(name: '', sets: []),
          );

          if (exercise.sets.isEmpty) return const SizedBox.shrink();

          final bool isBw = PeriodizationModelUtils.isBodyweightExercise(
            id: _activeExerciseId,
            name: _activeExerciseName,
          );
          // Bodyweight exercises: WES2 stores the added load, the legacy
          // screen stored the total (bodyweight_load.dart). Each set is read
          // at the bodyweight recorded on or before this day and ranked on its
          // TOTAL load.
          final double? dayBw = isBw
              ? PeriodizationModelUtils.recordedBodyweightKgOnOrBefore(
                  uid: userId, asOf: workout.date)
              : null;
          double rankWeight(SetDetails s) => isBw
              ? (s.bodyweightLoad(dayBw).totalKg ?? 0.0)
              : (s.weight ?? 0.0);

          final topSet = exercise.sets.reduce((a, b) {
            final aE1 = calculateE1RM(rankWeight(a), (a.reps ?? 0).toDouble(), a.rir ?? 0.0);
            final bE1 = calculateE1RM(rankWeight(b), (b.reps ?? 0).toDouble(), b.rir ?? 0.0);
            return aE1 > bE1 ? a : b;
          });

          final String weightLabel;
          final String e1rmLabel;
          if (isBw) {
            final NormalizedLoad load = topSet.bodyweightLoad(dayBw);
            final double? added = load.addedKg;
            final double? total = load.totalKg;
            weightLabel = added != null
                ? '+${(added < 0 ? 0.0 : added).toStringAsFixed(1)} kg'
                : '${(total ?? 0.0).toStringAsFixed(1)} kg total';
            if (total != null && dayBw != null) {
              final double e = calculateE1RM(
                      total, (topSet.reps ?? 0).toDouble(), topSet.rir ?? 0.0) -
                  dayBw;
              e1rmLabel = '+${(e < 0 ? 0.0 : e).toStringAsFixed(1)} kg';
            } else {
              e1rmLabel = '— (BW not recorded)';
            }
          } else {
            final double e1rm = calculateE1RM(topSet.weight ?? 0.0,
                (topSet.reps ?? 0).toDouble(), topSet.rir ?? 0.0);
            weightLabel = '${(topSet.weight ?? 0.0).toStringAsFixed(1)} kg';
            e1rmLabel = '${e1rm.toStringAsFixed(1)} kg';
          }

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
