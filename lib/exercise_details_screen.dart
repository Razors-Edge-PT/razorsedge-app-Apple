import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart';
import 'user_context.dart';
import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // for Timestamp & Firestore
import 'package:flutter/services.dart'; // for FilteringTextInputFormatter
import 'user_context.dart';

enum TrendRange { d14, m1, m6, y1, y2 }

// Simple date/value pair for the series
class E1RMPoint {
  final DateTime date;
  final double value;
  const E1RMPoint(this.date, this.value);
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
  TrendRange _trend = TrendRange.d14; // 👈 our new toggle state
  String get userId => UserContext.of(context, listen: false).currentUid;


  double calculateE1RM(double weight, double reps, double rir) {
    final totalReps = reps + rir;
    return (totalReps <= 6)
        ? (weight * (36 / (37 - totalReps)))
        : (weight * (1 + (0.0333 * totalReps)));
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

  String _labelForDate(DateTime d, TrendRange t) {
    switch (t) {
      case TrendRange.d14:
      case TrendRange.m1:
        return DateFormat('d MMM').format(d);
      case TrendRange.m6:
      case TrendRange.y1:
        return DateFormat('MMM yy').format(d);
      case TrendRange.y2:
        return DateFormat('yy-MM').format(d);
    }
  }

  int _tickStepForCount(int n) {
    if (n <= 14) return 1;
    if (n <= 30) return 2;
    if (n <= 90) return 5;
    if (n <= 180) return 10;
    if (n <= 365) return 20;
    return 30;
  }

  Future<List<Workout>> _fetchTwoYearHistoryForExercise({
    required String exerciseId,
    String? exerciseName,  // optional fallback
    String? uidOverride,
    int lookbackDays = 730,
    int batchSize = 50,
  }) async {

    String? userId = uidOverride;
    final user = FirebaseAuth.instance.currentUser;
    userId ??= FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return [];

    final cutoff = DateTime.now().subtract(Duration(days: lookbackDays));

    final out = <Workout>[];
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

        // Parse page
        for (final doc in snap.docs) {
          final data = doc.data();

          // Date may be Timestamp or ISO string
          final rawDate = data['date'];
          DateTime? workoutDate;
          if (rawDate is Timestamp) {
            workoutDate = rawDate.toDate();
          } else if (rawDate is String) {
            workoutDate = DateTime.tryParse(rawDate);
          }
          if (workoutDate == null) continue;

          // Stop early if this and all remaining will be older than cutoff
          if (workoutDate.isBefore(cutoff)) {
            // because we’re descending, once we see < cutoff, the rest of the page is also <= cutoff
            // but there might be newer ones in earlier pages; still safe to skip adding older and continue to next page
            continue;
          }

          // Raw exercises list to check ID/name before mapping
          final rawEx = data['exercises'];
          if (rawEx is! List) continue;

          // Match by id first; also allow 'exerciseId' key; fallback to name (if provided)
          bool anyMatch = rawEx.any((e) {
            final m = e as Map<String, dynamic>;
            final rid = (m['id'] ?? m['exerciseId'] ?? '').toString();
            if (rid.isNotEmpty && rid == exerciseId) return true;
            if (exerciseName != null && (m['name'] ?? '') == exerciseName) return true;
            return false;
          });
          if (!anyMatch) continue;

          // Now map to your model
          List<Exercise> exercises = [];
          try {
            exercises = rawEx
                .map((e) => Exercise.fromFirestore(e as Map<String, dynamic>))
                .toList();
          } catch (_) {}

          out.add(Workout(
            name: (data['name'] ?? 'Unnamed Workout') as String,
            date: workoutDate,
            exercises: exercises,
          ));
        }

        lastDoc = snap.docs.last;

        // Heuristic early break: if last doc on this page is older than cutoff,
        // and we got a full page, the next pages will also be older.
        final lastData = snap.docs.last.data();
        final lastRaw = lastData['date'];
        DateTime? lastDate;
        if (lastRaw is Timestamp) lastDate = lastRaw.toDate();
        if (lastRaw is String) lastDate = DateTime.tryParse(lastRaw);
        if (lastDate != null && lastDate.isBefore(cutoff)) break;

        if (snap.docs.length < batchSize) break; // no more pages
      }

      out.sort((a, b) => a.date.compareTo(b.date));
      print('🟦 [Details] Fetch done: kept ${out.length} workouts '
          '(pages=$page, id="$exerciseId", name="${exerciseName ?? "null"}")');
      if (out.isNotEmpty) {
        print('🟦 [Details] Range fetched: ${out.first.date.toIso8601String()} → ${out.last.date.toIso8601String()}');
      }
      return out;
    } catch (e) {
      print('❌ [Details] fetch error: $e');
      return [];
    }
  }


  void _cycleTrend() {
    final values = TrendRange.values;
    final i = values.indexOf(_trend);
    setState(() {
      _trend = values[(i + 1) % values.length];
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
    setState(() => _trendTarget = vals[(i + 1) % vals.length]);
  }

  String _repTargetLabel() {
    final r = _repTarget;
    if (r == null) return 'Rep Target * ${_rangeLabel(_trendTarget)}';
    final isInt = (r % 1).abs() < 1e-9;
    final repsText = isInt ? r.toInt().toString() : r.toStringAsFixed(1);
    return '$repsText Rep Target * ${_rangeLabel(_trendTarget)}';
  }

  String _rirToggleText() =>
      _includeRIRForTarget ? 'Including RIR' : 'Excluding RIR';



  Set<int> _computeXTicks(int n, TrendRange t) {
    if (n <= 0) return {};
    final last = n - 1;

    // target label counts per range
    final target = switch (t) {
      TrendRange.d14 => 4,
      TrendRange.m1  => 5,
      TrendRange.m6  => 6,
      TrendRange.y1  => 7,
      TrendRange.y2  => 7,
    };

    List<int> ticks;
    if (n <= target) {
      ticks = List<int>.generate(n, (i) => i); // small sets: show all
    } else {
      final raw = <int>[];
      final step = last / (target - 1);
      for (var k = 0; k < target; k++) {
        raw.add((k * step).round().clamp(0, last));
      }
      // de-dupe preserving order
      final seen = <int>{};
      ticks = [for (final i in raw) if (seen.add(i)) i];
    }

    // ✅ ALWAYS include the first and last
    if (!ticks.contains(0)) ticks.insert(0, 0);
    if (!ticks.contains(last)) ticks.add(last);

    return ticks.toSet();
  }


  @override
  void initState() {
    super.initState();
    print('🟦 [Details] init for id="${widget.exerciseId}", name="${widget.exerciseName}"');

    final selectedUid = UserContext.of(context, listen: false).currentUid;
    // …then fetch full 2y history and replace
    _fetchTwoYearHistoryForExercise(
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

      final e1 = calculateE1RM(top.weight ?? 0.0, (top.reps ?? 0).toDouble(), top.rir ?? 0.0);
      series.add(E1RMPoint(workout.date, e1));
    }

    print('📊 [Details] Workouts total=${_workouts.length}, matched=$matchedWorkouts, points=${series.length}');

    // ===== Rep-target series (second chart) =====
    final double? repTarget = _repTarget;
    final List<E1RMPoint> seriesTarget = [];

    if (repTarget != null) {
      for (final workout in sortedWorkouts) {
        // find the matching exercise in the workout (id first, fallback name)
        Exercise? ex = workout.exercises.firstWhere(
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

        // filter sets with reps == target (allow tiny tolerance)
        final tol = 1e-6;
        final matching = ex.sets.where((s) {
          final r = (s.reps ?? 0).toDouble();
          return (r - repTarget).abs() < tol;
        }).toList();
        if (matching.isEmpty) continue;

        // pick the strongest matching set (highest E1RM under chosen rule)
        double best = double.negativeInfinity;
        for (final s in matching) {
          final weight = (s.weight ?? 0.0);
          final reps   = (s.reps ?? 0).toDouble();
          final rir    = _includeRIRForTarget ? (s.rir ?? 0.0) : 0.0;
          final e1 = calculateE1RM(weight, reps, rir);
          if (e1 > best) best = e1;
        }
        if (best.isFinite) {
          seriesTarget.add(E1RMPoint(workout.date, best));
        }
      }
    }

// project to points/labels for the selected range
    final cutoff2 = _cutoffFor(_trendTarget);
    final filtered2 = seriesTarget.where((p) => !p.date.isBefore(cutoff2)).toList()
      ..sort((a,b) => a.date.compareTo(b.date));

    final spots2 = <FlSpot>[];
    final labels2 = <String>[];
    double maxY2 = 0;

    for (var i = 0; i < filtered2.length; i++) {
      spots2.add(FlSpot(i.toDouble(), filtered2[i].value));
      labels2.add(_labelForDate(filtered2[i].date, _trendTarget));
      if (filtered2[i].value > maxY2) maxY2 = filtered2[i].value;
    }

    final adjustedMaxY2 = spots2.isEmpty ? 100.0
        : (maxY2 * 1.018).clamp(100.0, double.infinity) as double;

    final xTickSet2 = _computeXTicks(labels2.length, _trendTarget);
    final bool short2 = _trendTarget == TrendRange.d14 || _trendTarget == TrendRange.m1;

// asym padding so first point is closer to Y axis but right edge has room
    final double leftPadX2  = short2 ? 0.10 : 0.20;
    final double rightPadX2 = short2 ? 0.20 : 0.15;


// Filter to selected window & project to chart data
    final cutoff = _cutoffFor(_trend);
    final filtered = series.where((p) => !p.date.isBefore(cutoff)).toList();

    final List<FlSpot> spots = [];
    final List<String> labels = [];
    double maxY = 0;

    for (var i = 0; i < filtered.length; i++) {
      spots.add(FlSpot(i.toDouble(), filtered[i].value));
      labels.add(_labelForDate(filtered[i].date, _trend));
      if (filtered[i].value > maxY) maxY = filtered[i].value;
    }

    final double adjustedMaxY = spots.isEmpty
        ? 100.0
        : (maxY * 1.018).clamp(100.0, double.infinity) as double;

    final int labelStep = _tickStepForCount(labels.length);

// Labels for chips
    final rangeLabel = {
      TrendRange.d14: '14d',
      TrendRange.m1:  '1m',
      TrendRange.m6:  '6m',
      TrendRange.y1:  '1y',
      TrendRange.y2:  '2y',
    };

    final xTickSet = _computeXTicks(labels.length, _trend);
    final bool shortRange = _trend == TrendRange.d14 || _trend == TrendRange.m1;
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
              mainAxisAlignment: MainAxisAlignment.center, // 👈 center contents
              children: [
                TextButton.icon(
                  onPressed: _cycleTrend,
                  label: Text(
                    'E1RM Trend • ${_rangeLabel(_trend)}',
                    style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),

                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    foregroundColor: Colors.cyanAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Colors.cyanAccent),
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
                  maxY: adjustedMaxY,

                  gridData: FlGridData(
                    show: true,
                    getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10),
                    getDrawingVerticalLine: (_) => FlLine(color: Colors.white10),
                  ),

                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 36,
                        getTitlesWidget: (value, meta) {
                          // Hide the very top label (use epsilon for float safety)
                          const eps = 1e-6;
                          if ((meta.max - value).abs() < eps) {
                            return const SizedBox.shrink();
                          }
                          return Text(
                            value.toInt().toString(),
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

                          final bool shortRange = _trend == TrendRange.d14 || _trend == TrendRange.m1;

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
                      color: Colors.cyanAccent,
                      // 👇 Hide circles for 6m+; show for 14d/1m
                      dotData: FlDotData(
                        show: _trend == TrendRange.d14 || _trend == TrendRange.m1,
                      ),
                      // (Optional) slightly thicker line on long ranges
                      barWidth: (_trend == TrendRange.m6 || _trend == TrendRange.y1 || _trend == TrendRange.y2) ? 2.0 : 1.0,
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.cyanAccent.withOpacity(0.1),
                      ),
                    ),
                  ],


                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      tooltipBgColor: Colors.grey[900]!,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((s) {
                          final idx = s.x.toInt();
                          final dateStr = (idx >= 0 && idx < filtered.length)
                              ? DateFormat('d MMM yyyy').format(filtered[idx].date)
                              : '';
                          final e1rm = s.y.toStringAsFixed(1);
                          return LineTooltipItem('E1RM: $e1rm kg\n$dateStr',
                              const TextStyle(color: Colors.white));
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
                      // ── Reps (left, compact)
                      SizedBox(
                        width: 36,
                        height: 32,
                        child: TextField(
                          controller: _repTargetCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$')),
                          ],
                          onChanged: (s) => setState(() => _repTarget = double.tryParse(s)),
                          cursorColor: Colors.cyanAccent,
                          style: const TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Reps',
                            hintStyle: const TextStyle(color: Colors.cyanAccent),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            filled: true,
                            fillColor: Colors.cyanAccent.withOpacity(0.08),
                            enabledBorder: OutlineInputBorder(
                              borderSide: const BorderSide(color: Colors.cyanAccent),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderSide: const BorderSide(color: Colors.cyanAccent, width: 1.3),
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
                                  side: const BorderSide(color: Colors.cyanAccent),
                                ),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _repTargetLabel(), // e.g. "5 Rep Target * 1 Month"
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.cyanAccent,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
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
                              border: Border.all(color: Colors.cyanAccent),
                              borderRadius: BorderRadius.circular(8),
                              color: Colors.cyanAccent.withOpacity(0.08),
                            ),
                            child: Text(
                              _rirToggleText(), // e.g. "Including RIR" / "Excluding RIR"
                              style: const TextStyle(
                                color: Colors.cyanAccent,
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
                  maxX: spots2.isEmpty ? rightPadX2 : (spots2.length - 1 + rightPadX2),
                  maxY: adjustedMaxY2,

                  gridData: FlGridData(
                    show: true,
                    getDrawingHorizontalLine: (_) => FlLine(color: Colors.white10),
                    getDrawingVerticalLine: (_) => FlLine(color: Colors.white10),
                  ),

                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 36,
                        getTitlesWidget: (value, meta) {
                          const eps = 1e-6;
                          if ((meta.max - value).abs() < eps) return const SizedBox.shrink();
                          return Text(
                            value.toInt().toString(),
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

                  lineBarsData: [
                    LineChartBarData(
                      spots: spots2,
                      isCurved: true,
                      color: Colors.cyanAccent,
                      dotData: FlDotData(
                        show: _trendTarget == TrendRange.d14 || _trendTarget == TrendRange.m1,
                      ),
                      barWidth: (_trendTarget == TrendRange.m6 ||
                          _trendTarget == TrendRange.y1 ||
                          _trendTarget == TrendRange.y2) ? 2.0 : 1.0,
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.cyanAccent.withOpacity(0.1),
                      ),
                    ),
                  ],

                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      tooltipBgColor: Colors.grey[900]!,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((s) {
                          final idx = s.x.toInt();
                          final dateStr = (idx >= 0 && idx < filtered2.length)
                              ? DateFormat('d MMM yyyy').format(filtered2[idx].date)
                              : '';
                          final e1rm = s.y.toStringAsFixed(1);
                          return LineTooltipItem(
                            'E1RM: $e1rm kg\n$dateStr',
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
          final workout = sortedWorkouts[index];
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

          final e1rm = calculateE1RM(topSet.weight ?? 0.0, (topSet.reps ?? 0).toDouble(), topSet.rir ?? 0.0);

          return ListTile(
            title: Text(
              DateFormat('dd-MM-yyyy').format(workout.date),
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
            subtitle: Text(
              '${topSet.weight} kg × ${topSet.reps}, RIR ${topSet.rir} → E1RM: ${e1rm.toStringAsFixed(1)} kg',
              style: const TextStyle(color: Colors.cyanAccent),
            ),
          );
        },
      )

    ],
      ),
    ));
  }
}
