// warmup_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'periodization_model_utils.dart';
import 'dart:convert'; // for jsonEncode / jsonDecode
import 'dart:async' show unawaited; // if you use unawaited() here
import 'progression_engine.dart';                // engine + inputs
import 'package:intl/intl.dart';                 // for y-M-d convenience (optional)


import 'local_cache/block_plan_cache.dart'; // BlockPlanCache.putInitSnapshot()

class WarmupService {
  WarmupService._();
  static final instance = WarmupService._();

  static const _cooldown = Duration(hours: 3);
  static const int _workoutWarmLimit = 150;
  static const int _exerciseWarmLimit = 2000;

  Future<void> warmWES(
      String uid, {
        String? activeBlockId,
        DateTime? selectedDate,
      }) async {
    if (uid.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Per-athlete cooldown
    final keyAth = 'wes_warm_last:$uid';
    final lastAth = prefs.getInt(keyAth);
    final athFresh =
        lastAth != null && (now - lastAth) < _cooldown.inMilliseconds;
    if (!athFresh) await prefs.setInt(keyAth, now);

    // Global cooldown for static exercises
    final keyEx = 'wes_warm_exercises_last';
    final lastEx = prefs.getInt(keyEx);
    final exFresh =
        lastEx != null && (now - lastEx) < _cooldown.inMilliseconds;
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

  // ──────────────────────────────────────────────────────────────
// STEP 1: Load block meta (start/end) from the active block doc
// ──────────────────────────────────────────────────────────────
  Future<(DateTime?, DateTime?)> _loadBlockMeta({
    required FirebaseFirestore fs,
    required String uid,
    required String activeBlockId,
  }) async {
    try {
      final doc = await fs
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(activeBlockId)
          .get(const GetOptions(source: Source.server));
      if (!doc.exists) return (null, null);

      DateTime? parseDate(dynamic v) {
        if (v == null) return null;
        if (v is Timestamp) return v.toDate();
        if (v is String) {
          // allow 'yyyy-MM-dd' or ISO
          final s = v.trim();
          final d = DateTime.tryParse(s);
          if (d != null) return DateTime(d.year, d.month, d.day);
        }
        return null;
      }

      final data = doc.data()!;
      final start = parseDate(data['startDate']) ?? parseDate(data['blockStart']) ?? parseDate(data['start']);
      final end   = parseDate(data['endDate'])   ?? parseDate(data['blockEnd'])   ?? parseDate(data['end']);
      print('🧩 [Warmup:1] block meta → start=$start end=$end');
      return (start, end);
    } catch (e) {
      print('🧩 [Warmup:1] block meta load failed: $e');
      return (null, null);
    }
  }

// ──────────────────────────────────────────────────────────────
// STEP 2: Compute (weekIndex, dayIndex) for a selected date
// ──────────────────────────────────────────────────────────────
  Map<String, int> _computeWeekDayIndex({
    required DateTime selectedDate,
    required DateTime blockStartDate,
  }) {
    final d = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    final base = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day);
    final deltaDays = d.difference(base).inDays;
    final weekIndex = (deltaDays ~/ 7).clamp(0, 9999);
    final dayIndex  = (deltaDays % 7).clamp(0, 6);
    print('🧮 [Warmup:2] indices → weekIndex=$weekIndex dayIndex=$dayIndex (delta=$deltaDays)');
    return {'weekIndex': weekIndex, 'dayIndex': dayIndex};
  }


// ──────────────────────────────────────────────────────────────
// STEP 3: Load planned day (from Isar if present; else Firestore)
// returns the list WES paints: selectedExercisesWithCircuits
// ──────────────────────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _loadPlannedDay({
  required FirebaseFirestore fs,
  required String uid,
  required String blockId,
  required int weekIndex,
  required int dayIndex,
  }) async {
  // Try super-cache first
  final cached = await BlockPlanCache.getDay(
  uid: uid,
  blockId: blockId,
  weekIndex: weekIndex,
  dayIndex: dayIndex,
  );
  if (cached != null) {
  print('🗂️ [Warmup:3] planned day (Isar) → ${cached.length} exercises');
  return cached;
  }

  // Fallback to Firestore day doc
  final dayDoc = await fs
      .collection('planned_blocks')
      .doc(uid)
      .collection('blocks')
      .doc(blockId)
      .collection('weeks')
      .doc('week_$weekIndex')
      .collection('days')
      .doc('day_$dayIndex')
      .get(const GetOptions(source: Source.server));

  final exercises = <Map<String, dynamic>>[];
  if (dayDoc.exists) {
  final data = dayDoc.data()!;
  final raw = (data['exercises'] ?? data['planned'] ?? data['rows']);
  if (raw is List) {
  for (final e in raw) {
  if (e is Map) exercises.add(Map<String, dynamic>.from(e));
  }
  }
  }

  // Cache for next boot
  await BlockPlanCache.putDay(
  uid: uid,
  blockId: blockId,
  weekIndex: weekIndex,
  dayIndex: dayIndex,
  exercises: exercises,
  updatedAt: DateTime.now(),
  );

  print('🗂️ [Warmup:3] planned day (FS) → ${exercises.length} exercises');
  return exercises;
  }

// ──────────────────────────────────────────────────────────────
// STEP 4: Build exerciseSettings map used by the engine
// sources: row.settings OR /exercises/{id}
// ──────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> _loadExerciseSettingsForPlanned({
    required FirebaseFirestore fs,
    required String uid,
    required String blockId,
    required List<Map<String, dynamic>> planned,
  }) async {
    final settings = <String, dynamic>{};

    // --- Fetch block doc (server, then fall back to cache) ---
    DocumentSnapshot<Map<String, dynamic>>? cacheSnap;
    try {
      cacheSnap = await fs
          .collection('planned_blocks').doc(uid)
          .collection('blocks').doc(blockId)
          .get(const GetOptions(source: Source.cache));
    } catch (_) {
      cacheSnap = null;
    }
    final serverSnap = await fs
        .collection('planned_blocks').doc(uid)
        .collection('blocks').doc(blockId)
        .get(const GetOptions(source: Source.server));

    final blockSnap = (serverSnap.exists) ? serverSnap : cacheSnap;
    final blockData = blockSnap?.data() ?? const <String, dynamic>{};
    final rawExerciseSettings = (blockData['exerciseSettings'] is Map)
        ? Map<String, dynamic>.from(blockData['exerciseSettings'] as Map)
        : const <String, dynamic>{};

    // Helper: id -> settings map from block doc
    Map<String, dynamic>? _fromBlockById(String id) {
      final m = rawExerciseSettings[id];
      return (m is Map) ? Map<String, dynamic>.from(m as Map) : null;
    }

    // Helper: sometimes block keys might be names (rare)
    Map<String, dynamic>? _fromBlockByName(String name) {
      final hit = rawExerciseSettings[name];
      return (hit is Map) ? Map<String, dynamic>.from(hit as Map) : null;
    }

    // Helper: prefer a, then b, then c
    T? _pick<T>(T? a, T? b, T? c) => a ?? b ?? c;

    // Build resolved settings for each planned row (overlay row overrides > block doc)
    for (final row in planned) {
      final rowMap = Map<String, dynamic>.from(row);
      final name = (rowMap['name'] ?? rowMap['exercise'] ?? '').toString().trim();
      if (name.isEmpty) continue;

      final id = (rowMap['exerciseId'] ?? rowMap['id'] ?? rowMap['exercise_id'])
          ?.toString() ??
          (PeriodizationModelUtils.nameToId[name] ?? name).toString();

      final rowSettings =
      (rowMap['settings'] is Map) ? Map<String, dynamic>.from(rowMap['settings']) : null;

      // pull from block doc by id first, then by name (fallback)
      final fromBlock = _fromBlockById(id) ?? _fromBlockByName(name);

      // Compose the exact keys the engine expects
      final resolved = <String, dynamic>{
        'progressionModel': _pick<String?>(
            rowSettings?['progressionModel'] as String?,
            rowMap['progressionModel'] as String?,
            fromBlock?['progressionModel'] as String?),
        'periodizationModel': _pick<String?>(
            rowSettings?['periodizationModel'] as String?,
            rowMap['periodizationModel'] as String?,
            fromBlock?['periodizationModel'] as String?),
        'repTargets': _pick<Map<String, dynamic>?>(
            (rowSettings?['repTargets'] is Map)
                ? Map<String, dynamic>.from(rowSettings!['repTargets'])
                : null,
            (rowMap['repTargets'] is Map)
                ? Map<String, dynamic>.from(rowMap['repTargets'])
                : null,
            (fromBlock?['repTargets'] is Map)
                ? Map<String, dynamic>.from(fromBlock!['repTargets'])
                : null),
        'increments': _pick<Map<String, dynamic>?>(
            (rowSettings?['increments'] is Map)
                ? Map<String, dynamic>.from(rowSettings!['increments'])
                : null,
            (rowMap['increments'] is Map)
                ? Map<String, dynamic>.from(rowMap['increments'])
                : null,
            (fromBlock?['increments'] is Map)
                ? Map<String, dynamic>.from(fromBlock!['increments'])
                : null),
        'maxWeightByReps': _pick<Map<String, dynamic>?>(
            (rowSettings?['maxWeightByReps'] is Map)
                ? Map<String, dynamic>.from(rowSettings!['maxWeightByReps'])
                : null,
            (rowMap['maxWeightByReps'] is Map)
                ? Map<String, dynamic>.from(rowMap['maxWeightByReps'])
                : null,
            (fromBlock?['maxWeightByReps'] is Map)
                ? Map<String, dynamic>.from(fromBlock!['maxWeightByReps'])
                : null),
      };

      settings[id] = resolved;
    }

    // Summary + detailed per-row print
    print('🧰 [Warmup:4] exerciseSettings → ${settings.length} entries');
    for (final row in planned) {
      final name = (row['name'] ?? row['exercise'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final id = (row['exerciseId'] ?? row['id'] ?? row['exercise_id'])?.toString()
          ?? (PeriodizationModelUtils.nameToId[name] ?? name).toString();
      final s = settings[id];
      if (s != null) {
        print('   • [$id] $name → ${jsonEncode(s)}');
      } else {
        print('   • [$id] $name → (no settings found)');
      }
    }

    return settings;
  }


// ──────────────────────────────────────────────────────────────
// ──────────────────────────────────────────────────────────────
// STEP 5 (date-string only): Build BB2 overrides map (id + name keys)
// Looks up the day by 'yyyy-MM-dd' string; if not found, falls back to day_$dayIndex.
// ──────────────────────────────────────────────────────────────
  Future<Map<String, Map<String, dynamic>>> _buildResolvedBB2Overrides({
    required FirebaseFirestore fs,
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,          // kept for fallback
    required DateTime selectedDate, // normalized date-only
    required List<Map<String, dynamic>> planned,
  }) async {
    // 0) Build the exact y-m-d key we store and use in queries
    final d   = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    final ymd = '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    print('[Warmup:5] resolve by date (string only) → $ymd (week_$weekIndex)');

    final daysCol = fs
        .collection('planned_blocks').doc(uid)
        .collection('blocks').doc(blockId)
        .collection('weeks').doc('week_$weekIndex')
        .collection('days');

    DocumentSnapshot<Map<String, dynamic>>? snap;

    // 1) Primary: exact string match on 'date' == 'yyyy-MM-dd'
    try {
      final q = await daysCol
          .where('date', isEqualTo: ymd)
          .limit(1)
          .get(const GetOptions(source: Source.server));
      if (q.docs.isNotEmpty) snap = q.docs.first;
    } catch (_) {}

    // 2) Fallback: direct doc by day_$dayIndex
    if (snap == null) {
      try {
        final direct = await daysCol.doc('day_$dayIndex').get(const GetOptions(source: Source.server));
        if (direct.exists) snap = direct;
      } catch (_) {}
    }

    if (snap == null || !snap.exists) {
      print('[Warmup:5] no day doc found for date=$ymd in week_$weekIndex → {}');
      return const <String, Map<String, dynamic>>{};
    }

    final data = snap.data() ?? const <String, dynamic>{};
    final raw  = data['exercises'];
    final rows = (raw is List) ? raw : const <dynamic>[];
    print('[Warmup:5] ✅ hit doc=${snap.id} date=${data['date']} rows=${rows.length}');
    if (rows.isNotEmpty && rows.first is Map) {
      print('[Warmup:5] sample row → ${jsonEncode(rows.first)}');
    }

    String _norm(String s) {
      var t = s.toLowerCase().trim();
      t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
      t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
      t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
      t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
      return t;
    }
    double? _num(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      if (v is String) {
        final m = RegExp(r'(-?\d+(\.\d+)?)').firstMatch(v.trim());
        if (m != null) return double.tryParse(m.group(1)!);
        return double.tryParse(v);
      }
      return null;
    }

    // Row-by-row, aligned with planned
    final byIndex = <int, Map<String, dynamic>>{};
    for (int i = 0; i < rows.length && i < planned.length; i++) {
      final r = rows[i];
      if (r is! Map) continue;
      final row = Map<String, dynamic>.from(r);

      final weight = _num(row['weight']);
      final reps   = _num(row['reps']);
      final rir    = _num(row['rir']);
      final added  = _num(row['addedWeight']);

      if ([weight, reps, rir, added].every((e) => e == null)) continue;

      final rowId   = (row['exerciseId'] ?? row['id'] ?? row['exercise_id'])?.toString();
      final rowName = (row['name'] ?? row['exercise'] ?? '').toString();

      final plannedRow = planned[i];
      final pName = (plannedRow['name'] ?? plannedRow['exercise'] ?? '').toString();
      final pId   = (plannedRow['exerciseId'] ?? plannedRow['id'] ?? plannedRow['exercise_id'])?.toString()
          ?? (PeriodizationModelUtils.nameToId[pName] ?? pName).toString();

      final idMatches   = (rowId != null && rowId == pId);
      final nameMatches = rowName.isNotEmpty && _norm(rowName) == _norm(pName);
      if (!(idMatches || nameMatches || (rowId == null && rowName.isEmpty))) {
        print('   [Warmup:5] row#$i skipped (mismatch) planned="$pName"($pId) vs row="$rowName"($rowId)');
        continue;
      }

      byIndex[i] = {
        'weight':      weight,
        'addedWeight': added,
        'reps':        reps,
        'rir':         rir,
      };

      print('   [Warmup:5] row#$i → overrides weight=$weight added=$added reps=$reps rir=$rir '
          '(planned="$pName" id=$pId; bb2="$rowName" id=$rowId)');
    }

    // Lift to keys the engine probes
    final out = <String, Map<String, dynamic>>{};
    for (int i = 0; i < planned.length; i++) {
      final o = byIndex[i];
      if (o == null) continue;

      final p = planned[i];
      final pName = (p['name'] ?? p['exercise'] ?? '').toString();
      if (pName.isEmpty) continue;

      final pId = (p['exerciseId'] ?? p['id'] ?? p['exercise_id'])?.toString()
          ?? (PeriodizationModelUtils.nameToId[pName] ?? pName).toString();

      out[pId] = o;
      out[_norm(pName)] = o;
    }

    print('[Warmup:5] BB2 overrides (by date $ymd) → $out');
    return out;
  }



// ──────────────────────────────────────────────────────────────
// STEP 6: Populate topSetsByExercise from savedWorkoutsList
// (minimal derivation so engine has history context)
// ──────────────────────────────────────────────────────────────
  void _populateTopSetsFromSavedWorkouts() {
    final list = PeriodizationModelUtils.savedWorkoutsList;
    final byName = <String, List<Map<String, dynamic>>>{};

    String norm(String s) {
      var t = s.toLowerCase().trim();
      t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
      t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
      t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
      t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
      return t;
    }

    for (final w in list) {
      final exs = w['exercises'];
      if (exs is! List) continue;
      for (final ex in exs) {
        if (ex is! Map) continue;
        final name = (ex['name'] ?? ex['exercise'] ?? '').toString();
        if (name.isEmpty) continue;
        final sets = (ex['sets'] is List) ? List<Map<String, dynamic>>.from(ex['sets']) : const <Map<String, dynamic>>[];
        for (final s in sets) {
          final weight = (s['actualWeight'] ?? s['weight']);
          final reps   = (s['actualReps'] ?? s['reps']);
          if (weight is num && reps is num) {
            byName.putIfAbsent(name, () => <Map<String, dynamic>>[]).add({
              'date'  : w['date'],
              'weight': weight.toDouble(),
              'reps'  : reps.toInt(),
              'rir'   : (s['actualRir'] ?? s['rir']),
            });
          }
        }
      }
    }

    // Instead of assigning, mutate the existing final map
    PeriodizationModelUtils.topSetsByExercise.clear();
    PeriodizationModelUtils.topSetsByExercise.addAll(byName);

    print('📈 [Warmup:6] topSetsByExercise → ${byName.length} exercises');
  }


// ──────────────────────────────────────────────────────────────
// STEP 7: Prefetch bodyweight history (warm cache layer)
// ──────────────────────────────────────────────────────────────
  Future<void> _prefetchBodyweight({
  required FirebaseFirestore fs,
  required String uid,
  }) async {
  try {
  final snap = await fs
      .collection('users')
      .doc(uid)
      .collection('bodyweight')
      .orderBy('date', descending: true)
      .limit(90)
      .get(const GetOptions(source: Source.server));

  final count = snap.docs.length;
  // If PMU has setters, wire here; else read-through is fine for engine
  print('⚖️ [Warmup:7] bodyweight samples (≤90d) → $count');
  } catch (e) {
  print('⚖️ [Warmup:7] bodyweight prefetch failed: $e');
  }
  }


  Future<void> doWarmWES(
      String uid, {
        String? activeBlockId,
        DateTime? selectedDate,
        bool warmAthlete = true,
        bool warmExercises = true,
      }) async {

    // ⛳ anchor: start of doWarmWES
    print('[Warmup:0] incoming selectedDate=${selectedDate?.toIso8601String()}');
    final _sel = (selectedDate != null)
        ? DateTime(selectedDate!.year, selectedDate!.month, selectedDate!.day)
        : DateTime.now();
    print('[Warmup:0] normalized selectedDate=${_sel.toIso8601String().substring(0,10)}');

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
        final isoLocal = startOfDay.toIso8601String();
        final isoUtc = DateTime.utc(
            startOfDay.year, startOfDay.month, startOfDay.day)
            .toIso8601String();

        // New-style doc by ID
        unawaited(workouts
            .doc(dateOnly)
            .get(const GetOptions(source: Source.server)));

        // Legacy string equals (3 forms)
        unawaited(workouts
            .where('date', isEqualTo: isoLocal)
            .get(const GetOptions(source: Source.server)));
        unawaited(workouts
            .where('date', isEqualTo: isoUtc)
            .get(const GetOptions(source: Source.server)));
        unawaited(workouts
            .where('date', isEqualTo: dateOnly)
            .get(const GetOptions(source: Source.server)));

        // Legacy string range (captures ISO strings with time-of-day)
        unawaited(
          workouts
              .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
              .where('date', isLessThan: '${nextDateOnly}T00:00:00')
              .get(const GetOptions(source: Source.server)),
        );

        // Legacy timestamp day-range
        unawaited(
          workouts
              .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
              .where('date', isLessThan: Timestamp.fromDate(nextDay))
              .get(const GetOptions(source: Source.server)),
        );
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
          if (selectedDate != null)
            DateTime(selectedDate.year, selectedDate.month, selectedDate.day),
        ];

        // Warm yesterday/today/tomorrow (+ selectedDate if provided), across legacy/new shapes
        for (final d in days) {
          _warmWorkoutShapesForDate(d);
        }

        // Warm recent workouts LIST
        unawaited(
          fs
              .collection('users')
              .doc(uid)
              .collection('workouts')
              .orderBy('date', descending: true)
              .limit(_workoutWarmLimit)
              .get(const GetOptions(source: Source.server)),
        );

        // ✅ Also materialize savedWorkoutsList for PMU (matches WES loadSavedWorkoutsForInstanceCount)
        try {
          final col = fs.collection('users').doc(uid).collection('workouts');

          // 1) Try cache first
          List<Map<String, dynamic>> workouts = const <Map<String, dynamic>>[];
          try {
            final cached = await col.get(const GetOptions(source: Source.cache));
            workouts = cached.docs.map((d) => d.data()).toList();
          } catch (_) {
            /* cache miss is fine */
          }

          // 2) If cache empty, hit server
          if (workouts.isEmpty) {
            final server = await col.get(); // server
            workouts = server.docs.map((d) => d.data()).toList();
          }

          // 3) Assign to PMU so rep indexing & progression models see history now
          PeriodizationModelUtils.savedWorkoutsList =
          List<Map<String, dynamic>>.from(workouts);
          print(
              '📦 [Warmup→PMU] seeded savedWorkoutsList count=${workouts.length}');
        } catch (e) {
          print('⚠️ [Warmup→PMU] failed to seed savedWorkoutsList: $e');
        }
      }

      if (warmExercises) {
        // Warm global exercises list
        unawaited(
          fs
              .collection('exercises')
              .orderBy('name')
              .limit(_exerciseWarmLimit)
              .get(const GetOptions(source: Source.server)),
        );
      }

      // Warm planned blocks surface (small list)
      final blocksCol =
      fs.collection('planned_blocks').doc(uid).collection('blocks');
      final blocksSnap =
      await blocksCol.limit(5).get(const GetOptions(source: Source.server));
      for (final b in blocksSnap.docs) {
        unawaited(
            blocksCol.doc(b.id).get(const GetOptions(source: Source.server)));
      }

      // ✅ Explicitly warm the active block doc used by WES
      if (activeBlockId != null && activeBlockId.isNotEmpty) {
        unawaited(blocksCol
            .doc(activeBlockId)
            .get(const GetOptions(source: Source.server)));
      }

      if (activeBlockId != null && activeBlockId.isNotEmpty) {
        // If caller didn't pass a date, default to "today" (date-only)
        final d = (selectedDate != null)
            ? DateTime(selectedDate.year, selectedDate.month, selectedDate.day)
            : DateTime.now();

        // ── STEP 1: block meta
        final (blockStart, blockEnd) = await _loadBlockMeta(
          fs: fs,
          uid: uid,
          activeBlockId: activeBlockId,
        );
        if (blockStart == null || blockEnd == null) {
          print('🟥 [Warmup] abort: missing block meta');
          return;
        }

        // ── STEP 2: indices
        // ⛳ anchor: Step 2 inside doWarmWES
        final idx = _computeWeekDayIndex(
          selectedDate: _sel,          // ← use the normalized one we printed in step 0
          blockStartDate: blockStart,
        );
        final weekIndex = idx['weekIndex']!;
        final dayIndex  = idx['dayIndex']!;


        // ── STEP 3: planned day rows for WES paint
        final planned = await _loadPlannedDay(
          fs: fs,
          uid: uid,
          blockId: activeBlockId,
          weekIndex: weekIndex,
          dayIndex: dayIndex,
        );

        // ── STEP 4: exercise settings (progressionModel/repTargets/increments/caps)
        final exerciseSettings = await _loadExerciseSettingsForPlanned(
          fs: fs,
          uid: uid,
          blockId: activeBlockId!, // ensured non-null earlier
          planned: planned,
        );

        // ── STEP 5: BB2 overrides for the day (id + name keys)
        final resolvedBB2Values = await _buildResolvedBB2Overrides(
          fs: fs,
          uid: uid,
          blockId: activeBlockId,
          weekIndex: weekIndex,
          dayIndex: dayIndex,     // still passed for signature, though unused inside
          selectedDate: _sel,     // 👈 add this
          planned: planned,
        );


        // ── STEP 6: top sets (derived from already-seeded savedWorkoutsList)
        _populateTopSetsFromSavedWorkouts();

        // ── STEP 7: bodyweight prefetch (engine BW conversions may read-through)
        await _prefetchBodyweight(fs: fs, uid: uid);

        // NOTE: Steps 1–7 prepared all inputs. At this point, the engine can run.
        // (You said "no clamping" and we’ll run it in the next step when you’re ready.)
      }

    } catch (_) {
      // best-effort
    }
  }
}
