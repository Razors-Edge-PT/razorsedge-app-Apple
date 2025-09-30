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

  static const _cooldown = Duration(milliseconds: 100); // ~0.1 seconds
  static const int _workoutWarmLimit = 15000;
  static const int _exerciseWarmLimit = 200000;


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
    final dayIndex  = ((deltaDays % 7) + 1).clamp(0, 6);
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
        'rirPlan': _pick<Map<String, dynamic>?>(
            (rowSettings?['rirPlan'] is Map)
                ? Map<String, dynamic>.from(rowSettings!['rirPlan'])
                : null,
            (rowMap['rirPlan'] is Map)
                ? Map<String, dynamic>.from(rowMap['rirPlan'])
                : null,
            (fromBlock?['rirPlan'] is Map)
                ? Map<String, dynamic>.from(fromBlock!['rirPlan'])
                : null),
      };

      settings[id] = resolved;
      final _peekRir = resolved['rirPlan']?['week1']?['session1']?['set1']?['rir'];
      if (_peekRir != null) {
        print('   • [$id] $name RIR peek set1=${_peekRir.toString()}');
      }
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
// STEP 5: Build BB2 overrides map (id + lowercased name keys)
// {weight?, addedWeight?, reps?, rir?}
// ──────────────────────────────────────────────────────────────
  // ──────────────────────────────────────────────────────────────
// STEP 5 (no helper): scan the whole week, print it, then return
// overrides for the selected day. Return shape unchanged:
// Map<String, Map<String, dynamic>> keyed by exerciseId and
// normalized name with {weight?, addedWeight?, reps?, rir?}.
// ──────────────────────────────────────────────────────────────
  Future<Map<String, Map<String, dynamic>>> _buildResolvedBB2Overrides({
    required FirebaseFirestore fs,
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,           // preferred microcycle index
    required DateTime selectedDate,  // normalized (date-only)
    required List<Map<String, dynamic>> planned,
  }) async {
    // normalize selected date to yyyy-mm-dd
    final dsel = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    final ymdSel = '${dsel.year.toString().padLeft(4, '0')}-'
        '${dsel.month.toString().padLeft(2, '0')}-'
        '${dsel.day.toString().padLeft(2, '0')}';

    String _dateStr(dynamic v) {
      if (v == null) return '—';
      if (v is Timestamp) {
        final dt = v.toDate();
        return '${dt.year.toString().padLeft(4, '0')}-'
            '${dt.month.toString().padLeft(2, '0')}-'
            '${dt.day.toString().padLeft(2, '0')}';
      }
      if (v is String && v.length >= 10) return v.substring(0, 10);
      return v.toString();
    }

    bool _dateMatches(dynamic v) {
      if (v == null) return false;
      if (v is Timestamp) return _dateStr(v) == ymdSel;
      if (v is String)   return (v.length >= 10 ? v.substring(0, 10) : v) == ymdSel;
      return false;
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

    final daysCol = fs
        .collection('planned_blocks').doc(uid)
        .collection('blocks').doc(blockId)
        .collection('weeks').doc('week_$weekIndex')
        .collection('days');

    // 1) Load & print the entire week (day_0..day_6)
    print('📅 [Warmup:5] week_$weekIndex plan snapshot:');
    final weekDocs = <int, Map<String, dynamic>>{};
    for (int di = 0; di < 7; di++) {
      final snap = await daysCol.doc('day_$di').get(const GetOptions(source: Source.server));
      if (!snap.exists) {
        print('   • day_$di: (missing)');
        weekDocs[di] = {'id': 'day_$di', 'date': null, 'rows': const <Map<String, dynamic>>[]};
        continue;
      }
      final data = snap.data() ?? const <String, dynamic>{};
      final raw  = data['exercises'];
      final rows = (raw is List)
          ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : const <Map<String, dynamic>>[];
      final dateStr = _dateStr(data['date']);
      print('   • day_$di: id=${snap.id} date=$dateStr rows=${rows.length}');
      if (rows.isNotEmpty) {
        final first = rows.first;
        final name = (first['name'] ?? first['exercise'] ?? '').toString();
        final weight = first['weight'];
        final reps = first['reps'];
        print('     ↳ first: name="$name" weight=$weight reps=$reps');
      }
      weekDocs[di] = {'id': snap.id, 'date': data['date'], 'rows': rows};
    }

    // 2) Pick the day that matches the selected calendar date; fallback to dayIndex
    int? matchDi;
    for (int di = 0; di < 7; di++) {
      final d = weekDocs[di];
      if (d == null) continue;
      if (_dateMatches(d['date'])) { matchDi = di; break; }
    }
    final useDi = matchDi ?? dayIndex;

    final sel = weekDocs[useDi] ?? const <String, dynamic>{};
    final selDateStr = _dateStr(sel['date']);
    final selRows = (sel['rows'] is List) ? List<Map<String, dynamic>>.from(sel['rows'] as List) : const <Map<String, dynamic>>[];
    print('🎯 [Warmup:5] selected → day_$useDi (wanted=$dayIndex date=$selDateStr) rows=${selRows.length}');

    // 3) Build overrides for the selected day aligned to `planned` by index
    final byIndex = <int, Map<String, dynamic>>{};
    for (int i = 0; i < selRows.length && i < planned.length; i++) {
      final row = Map<String, dynamic>.from(selRows[i]);

      final weight = _num(row['weight']);
      final reps   = _num(row['reps']);
      final rir    = _num(row['rir']);
      final added  = _num(row['addedWeight']);

      // Only keep if at least one override present
      if ([weight, reps, rir, added].every((e) => e == null)) continue;

      final plannedRow = planned[i];
      final pName = (plannedRow['name'] ?? plannedRow['exercise'] ?? '').toString();
      final pId = (plannedRow['exerciseId'] ?? plannedRow['id'] ?? plannedRow['exercise_id'])?.toString()
          ?? (PeriodizationModelUtils.nameToId[pName] ?? pName).toString();

      byIndex[i] = {
        'weight': weight,
        'addedWeight': added,
        'reps': reps,
        'rir': rir,
        // debug context (not returned to engine)
        '_plannedName': pName,
        '_plannedId': pId,
      };

      print('   [Warmup:5] row#$i override → wt=$weight add=$added reps=$reps rir=$rir '
          '(planned="$pName" id=$pId)');
    }

    // 4) Lift to engine keys (exerciseId + normalized name)
    final out = <String, Map<String, dynamic>>{};
    for (int i = 0; i < planned.length; i++) {
      final o = byIndex[i];
      if (o == null) continue;

      final p = planned[i];
      final pName = (p['name'] ?? p['exercise'] ?? '').toString();
      if (pName.isEmpty) continue;

      final pId = (p['exerciseId'] ?? p['id'] ?? p['exercise_id'])?.toString()
          ?? (PeriodizationModelUtils.nameToId[pName] ?? pName).toString();

      out[pId] = {
        'weight': o['weight'],
        'addedWeight': o['addedWeight'],
        'reps': o['reps'],
        'rir': o['rir'],
      };
      out[_norm(pName)] = out[pId]!;
    }

    print('[Warmup:5] overrides for selected day_$useDi → $out');
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
  // STEP 7: bodyweight prefetch (print 4 most recent)
  Future<void> _prefetchBodyweight({
    required FirebaseFirestore fs,
    required String uid,
  }) async {
    try {
      final q = await fs
          .collection('users')
          .doc(uid)
          .collection('weights')
          .orderBy('timestamp', descending: true)
          .limit(90)
          .get(const GetOptions(source: Source.server));

      // Normalize & convert
      final samples = <Map<String, dynamic>>[];
      for (final d in q.docs) {
        final data = d.data();
        final ts = data['timestamp'];
        final unit = (data['unit'] ?? 'kg').toString().toLowerCase();
        final wRaw = data['weight'];

        DateTime? dt;
        if (ts is Timestamp) dt = ts.toDate();
        if (ts is String) dt = DateTime.tryParse(ts);
        if (dt == null) continue;

        double? w;
        if (wRaw is num) w = wRaw.toDouble();
        if (wRaw is String) w = double.tryParse(wRaw);
        if (w == null) continue;

        final kg = (unit == 'lb' || unit == 'lbs') ? (w * 0.45359237) : w;
        samples.add({
          'ts': dt,
          'weightKg': kg,
          'unit': unit,
        });
      }

      String _ymd(DateTime d) {
        final m = d.month.toString().padLeft(2, '0');
        final da = d.day.toString().padLeft(2, '0');
        return '${d.year}-$m-$da';
      }

      // Print summary + 4 most recent

      final show = samples.take(4).toList();
      for (final s in show) {
        final dt = s['ts'] as DateTime;
        final kg = (s['weightKg'] as double);
      }

      // If later you want the engine to use these without read-through,
      // you could stash them in a PMU static here (optional).
      // PeriodizationModelUtils.bodyweights = samples;  // <-- if you add such a field
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

        // ── STEP 8: precompute WES hints with the progression engine (first-paint ready)
            {
          // Local engine caches/aliases
          final Map<String, Map<String, dynamic>> _cache = <String, Map<String, dynamic>>{};
          final Map<String, dynamic> _seedHintsByKey = <String, dynamic>{}; // optional seeding for instant paint

          // Minimal adapters the engine expects
          String _rowKeyBy(int idx) => 'wk${weekIndex}_d${dayIndex}_i${idx}';
          String _rowCacheKey(int idx) => _rowKeyBy(idx);
          int? _getApplicableWeekIndex(String exerciseId) => weekIndex;
          double _getRirFromPlanOrInput(int exerciseIndex, int setNumber) {
            // Warmup has no text controllers; fall back to static plan (RIR models are static for first set)
            return 1.0; // safe default; engine may override per model
          }
          String _weightTextAt(int exIdx, int setIdx) => '';
          String _rirTextAt(int exIdx, int setIdx) => '';

          final List<Map<String, dynamic>> wesPlanned = <Map<String, dynamic>>[];

          // ——— instance counting helpers (saved-workouts based) ———
          String _normName(String s) {
            var t = s.toLowerCase().trim();
            t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
            t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
            t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
            t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
            t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
            return t;
          }

          DateTime? _parseAnyDate(dynamic v) {
            if (v == null) return null;
            if (v is Timestamp) return v.toDate();
            if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
            if (v is String) return DateTime.tryParse(v);
            return null;
          }

// Count how many times this exercise appears in SAVED workouts for THIS WEEK up to selected date (inclusive)
          int _priorSavedInstancesThisWeekFor(int rowIdx) {
            final row = planned[rowIdx];
            final name = (row['name'] ?? row['exercise'] ?? '').toString();
            final norm = _normName(name);

            final startOfBlock = DateTime(blockStart.year, blockStart.month, blockStart.day);
            final weekStart = startOfBlock.add(Duration(days: weekIndex * 7));
            final weekEndInclusive = DateTime(_sel.year, _sel.month, _sel.day);

            int count = 0;
            for (final w in PeriodizationModelUtils.savedWorkoutsList) {
              final d = _parseAnyDate(w['date']);
              if (d == null) continue;
              final dt = DateTime(d.year, d.month, d.day);
              if (dt.isBefore(weekStart) || dt.isAfter(weekEndInclusive)) continue;

              final exs = w['exercises'];
              if (exs is! List) continue;
              for (final ex in exs) {
                if (ex is! Map) continue;
                final n = (ex['name'] ?? ex['exercise'] ?? '').toString();
                if (n.isEmpty) continue;
                if (_normName(n) == norm) count++; // count every occurrence recorded that day
              }
            }
            return count;
          }

// Count today's *planned* occurrence index (1-based) up to this row
          int _todayPlannedIndexFor(int rowIdx) {
            final targetId = (planned[rowIdx]['exerciseId'] ??
                planned[rowIdx]['id'] ??
                planned[rowIdx]['exercise_id'])?.toString()
                ?? (PeriodizationModelUtils.nameToId[
                (planned[rowIdx]['name'] ?? planned[rowIdx]['exercise'] ?? '').toString()
                ] ??
                    (planned[rowIdx]['name'] ?? planned[rowIdx]['exercise'] ?? '').toString()).toString();
            int seen = 0;
            for (int i = 0; i <= rowIdx && i < planned.length; i++) {
              final pid = (planned[i]['exerciseId'] ?? planned[i]['id'] ?? planned[i]['exercise_id'])?.toString()
                  ?? (PeriodizationModelUtils.nameToId[
                  (planned[i]['name'] ?? planned[i]['exercise'] ?? '').toString()
                  ] ??
                      (planned[i]['name'] ?? planned[i]['exercise'] ?? '').toString()).toString();
              if (pid == targetId) seen++;
            }
            return seen; // 1,2,3...
          }

          for (int iRow = 0; iRow < planned.length; iRow++) {
            final res = ProgressionEngine.engineProgressedValues(
              ProgressionEngineInputs(
                blockStartDate: blockStart,
                blockEndDate: blockEnd,
                selectedDate: _sel,
                cachedUid: uid,
                selectedExercisesWithCircuits: planned,
                exerciseSettings: exerciseSettings,
                cachedProgressedValues: _cache,
                seedHintsByKey: _seedHintsByKey,
                rowKeyBy: _rowKeyBy,
                rowCacheKey: _rowCacheKey,
                getApplicableWeekIndex: _getApplicableWeekIndex,
                getRirFromPlanOrInput: _getRirFromPlanOrInput,
                weightTextAt: _weightTextAt,
                rirTextAt: _rirTextAt,
                debugPrintBlockDates: () {},
                // ✅ make sure your ProgressionEngineInputs includes this field:
                resolvedBB2Values: resolvedBB2Values,
              ),
              iRow,
            );
            wesPlanned.add(res);
            print('   • #$iRow ${res['exerciseName']} → ${res['weight']}kg @ ${res['reps']} (rir=${res['rir']}) id=${res['exerciseId']}');

            // 👇 add instance context print here
            final priorSaved = _priorSavedInstancesThisWeekFor(iRow);
            final todayIdx   = _todayPlannedIndexFor(iRow);
            final instance   = priorSaved + todayIdx;
            print('   • [INST] wk=$weekIndex day=$dayIndex date=${_sel.toIso8601String().substring(0,10)} priorSaved=$priorSaved todayIdx=$todayIdx instance=$instance');

          }

          // DEVBIG: verify we have everything and results look correct
          print('🧪 [Warmup:8] engine results → ${wesPlanned.length} rows '
              '(wk=$weekIndex day=$dayIndex date=${_sel.toIso8601String().substring(0,10)})');
          for (int i = 0; i < wesPlanned.length && i < 4; i++) {
            final r = wesPlanned[i];
            print('   • #$i ${r['exerciseName']} → ${r['weight']}kg @ ${r['reps']} (rir=${r['rir']}) '
                'id=${r['exerciseId']}');
            print('   • [CTX] wk=$weekIndex day=$dayIndex date=${_sel.toIso8601String().substring(0,10)}');


          }

          // Keep in scope for Step 9 (persist to Isar)
          // ⛳ anchor: Step 8 outputs
          final _wesPlannedForPersist = wesPlanned;
        }

        // (You said "no clamping" and we’ll run it in the next step when you’re ready.)
      }

    } catch (_) {
      // best-effort
    }
  }
}
