// warmup_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'periodization_model_utils.dart';
import 'dart:convert'; // for jsonEncode / jsonDecode
import 'dart:async' show unawaited; // if you use unawaited() here
import 'package:intl/intl.dart';                 // for y-M-d convenience (optional)
import 'block_repository.dart';
import 'app_check_ready.dart';

import 'local_cache/block_plan_cache.dart'; // BlockPlanCache.getDay/putDay/putWeek

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

    print('🔥 [Warmup:ENTRY] selectedDate='
        '${DateFormat('yyyy-MM-dd').format(selectedDate ?? DateTime.now())} '
        '(activeBlockId=$activeBlockId)');

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

    // Fire-and-forget — sequence the Firestore-heavy warm behind App Check
    // activation (settles even on failure/timeout, so this never deadlocks).
    unawaited(appCheckReady.then((_) => doWarmWES(
          uid,
          activeBlockId: activeBlockId,
          selectedDate: selectedDate,
          warmAthlete: !athFresh,
          warmExercises: !exFresh,
        )));
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

      return (start, end);
    } catch (e) {

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
    print('🟡 [Step2] blockStartDate=$blockStartDate (${blockStartDate.weekday}) '
        'selectedDate=$selectedDate (${selectedDate.weekday})');
    // Normalize both to day ordinals (number of days since epoch, ignores TZ/DST)
    int _toOrdinal(DateTime d) =>
        DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/
            Duration.millisecondsPerDay;

    final selOrdinal  = _toOrdinal(selectedDate);
    final baseOrdinal = _toOrdinal(blockStartDate);
    final deltaDays   = selOrdinal - baseOrdinal;

    final weekIndex = (deltaDays ~/ 7).clamp(0, 9999);
    final dayIndex  = deltaDays % 7; // always 0..6, Mon=0, Tue=1, Thu=3 etc.

    print('🧮 [Warmup:2] indices → weekIndex=$weekIndex dayIndex=$dayIndex (delta=$deltaDays) '
        'blockStart=$blockStartDate selected=$selectedDate');

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
    required DateTime selectedDate, // ← pass _sel
  }) async {
    print('🗓️ [Warmup:3] selectedDate → $selectedDate');



    // Try super-cache first

    // ⛔ Sanity check: ensure cache corresponds to the selected calendar date.
// We verify against the Firestore day doc's `date`. If mismatch → ignore cache.
    bool _cacheMatchesSelectedDate = true;
    try {
      DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
      DateTime? _asDate(dynamic v) {
        if (v == null) return null;
        if (v is DateTime) return _dateOnly(v);
        if (v is Timestamp) return _dateOnly(v.toDate());
        if (v is String) {
          final d = DateTime.tryParse(v);
          return (d == null) ? null : _dateOnly(d);
        }
        return null;
      }

      final dSnap = await fs
          .collection('planned_blocks').doc(uid)
          .collection('blocks').doc(blockId)
          .collection('weeks').doc('week_$weekIndex')
          .collection('days').doc('day_$dayIndex')
          .get(const GetOptions(source: Source.server));

      final docDate = _asDate(dSnap.data()?['date']);
      final want    = _dateOnly(selectedDate);
      if (docDate == null || docDate != want) {
        _cacheMatchesSelectedDate = false;
        final gotStr  = (docDate == null) ? 'null' : '${docDate.toIso8601String().substring(0,10)}';
        final wantStr = '${want.toIso8601String().substring(0,10)}';
        print('🛑 [Warmup:3] cache rejected (day_$dayIndex date mismatch) → doc=$gotStr want=$wantStr');
      }
    } catch (e) {
      // If we can’t validate, be conservative and fall back to FS read.
      _cacheMatchesSelectedDate = false;
      print('🟧 [Warmup:3] cache date-check failed → $e (ignoring cache)');
    }

    final cached = await BlockPlanCache.getDay(
      uid: uid,
      blockId: blockId,
      weekIndex: weekIndex,
      dayIndex: dayIndex,
    );

    if (cached != null && _cacheMatchesSelectedDate) {


      // merge wesPlannedExercises + exercises for selectedDate into the cached list
      final merged = List<Map<String, dynamic>>.from(cached);

      String _ymd(DateTime d) {
        final m = d.month.toString().padLeft(2, '0');
        final da = d.day.toString().padLeft(2, '0');
        return '${d.year}-$m-$da';
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
      bool _alreadyHas(Map<String, dynamic> cand) {
        final cname = (cand['name'] ?? cand['exercise'] ?? '').toString();
        final cid   = (cand['exerciseId'] ?? cand['id'] ?? cand['exercise_id'] ?? '').toString();
        for (final p in merged) {
          final pname = (p['name'] ?? p['exercise'] ?? '').toString();
          final pid   = (p['exerciseId'] ?? p['id'] ?? p['exercise_id'] ?? '').toString();
          if (cid.isNotEmpty && pid.isNotEmpty && cid == pid) return true;
          if (cid.isEmpty && pid.isEmpty && _norm(cname) == _norm(pname)) return true;
        }
        return false;
      }

      try {
        final ymd = _ymd(selectedDate);
        final wesSnap = await fs
            .collection('users').doc(uid)
            .collection('workouts').doc(ymd)
            .get(const GetOptions(source: Source.server));

        int added = 0;
        if (wesSnap.exists) {
          final data = wesSnap.data() ?? const <String, dynamic>{};
          final lists = <List<dynamic>>[
            (data['wesPlannedExercises'] ?? []) as List<dynamic>,
            (data['exercises'] ?? []) as List<dynamic>,
          ];
          for (final src in lists) {
            for (final ex in src.whereType<Map>()) {
              final name = (ex['name'] ?? ex['exercise'] ?? '').toString();
              final id   = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString();
              if (name.isEmpty && id.isEmpty) continue;
              if (_alreadyHas(Map<String,dynamic>.from(ex))) continue;
              merged.add({'name': name, 'exerciseId': id, 'circuitIndex': (ex['circuitIndex'] is num) ? (ex['circuitIndex'] as num).toInt() : 0});
              added++;
            }
          }
        }

        if (added > 0) {
          // write back so next boot hits updated Isar
          await BlockPlanCache.putDay(
            uid: uid,
            blockId: blockId,
            weekIndex: weekIndex,
            dayIndex: dayIndex,
            exercises: merged,
            updatedAt: DateTime.now(),
          );
          print('➕ [Warmup:3] cache merged from WES (added=$added, total=${merged.length})');
        }
      } catch (e) {
        print('⚠️ [Warmup:3] cache-merge failed: $e');
      }

      return merged;
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

    DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
    DateTime? _asDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return _dateOnly(v);
      if (v is Timestamp) return _dateOnly(v.toDate());
      if (v is String) {
        final d = DateTime.tryParse(v);
        return (d == null) ? null : _dateOnly(d);
      }
      return null;
    }

    if (dayDoc.exists) {
      final data = dayDoc.data() ?? const <String, dynamic>{};
      final docDate = _asDate(data['date']);
      final want    = _dateOnly(selectedDate);

      if (docDate == null || docDate != want) {
        final gotStr  = (docDate == null) ? 'null' : '${docDate.toIso8601String().substring(0,10)}';
        final wantStr = '${want.toIso8601String().substring(0,10)}';
        print('🛑 [Warmup:3] Firestore day rejected (day_$dayIndex date mismatch) → doc=$gotStr want=$wantStr');
        // Leave `exercises` empty on purpose.
      } else {
        final raw = (data['exercises'] ?? data['planned'] ?? data['rows']);
        if (raw is List) {
          for (final e in raw) {
            if (e is Map) exercises.add(Map<String, dynamic>.from(e));
          }
        }
      }
    }


    // 🔹 Merge from /users/{uid}/workouts/{ymd}
    String _ymd(DateTime d) {
      final m = d.month.toString().padLeft(2, '0');
      final da = d.day.toString().padLeft(2, '0');
      return '${d.year}-$m-$da';
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

    bool _alreadyHas(Map<String, dynamic> cand) {
      final cname = (cand['name'] ?? cand['exercise'] ?? '').toString();
      final cid   = (cand['exerciseId'] ?? cand['id'] ?? cand['exercise_id'] ?? '').toString();
      for (final p in exercises) {
        final pname = (p['name'] ?? p['exercise'] ?? '').toString();
        final pid   = (p['exerciseId'] ?? p['id'] ?? p['exercise_id'] ?? '').toString();
        if (cid.isNotEmpty && pid.isNotEmpty && cid == pid) return true;
        if (cid.isEmpty && pid.isEmpty && _norm(cname) == _norm(pname)) return true;
      }
      return false;
    }

    try {
      final ymd = _ymd(selectedDate);
      final wesSnap = await fs
          .collection('users').doc(uid)
          .collection('workouts').doc(ymd)
          .get(const GetOptions(source: Source.server));

      if (wesSnap.exists) {
        final data = wesSnap.data() ?? const <String, dynamic>{};

        // pull both branches
        final fromPlanned = (data['wesPlannedExercises'] is List)
            ? (data['wesPlannedExercises'] as List)
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList()
            : const <Map<String, dynamic>>[];

        final fromCompleted = (data['exercises'] is List)
            ? (data['exercises'] as List)
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList()
            : const <Map<String, dynamic>>[];

        int added = 0;
        for (final src in [fromPlanned, fromCompleted]) {
          for (final ex in src) {
            // map to minimal shape Step 4 expects
            final name = (ex['name'] ?? ex['exercise'] ?? '').toString();
            final id   = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString();
            if (name.isEmpty && id.isEmpty) continue;
            if (_alreadyHas(ex)) continue;

            exercises.add({
              'name': name,
              'exerciseId': id,
              'circuitIndex': (ex['circuitIndex'] is num) ? (ex['circuitIndex'] as num).toInt() : 0,
            });
            added++;
          }
        }

        if (fromPlanned.isNotEmpty || fromCompleted.isNotEmpty) {
          final srcMsg = [
            if (fromPlanned.isNotEmpty) 'wesPlannedExercises=${fromPlanned.length}',
            if (fromCompleted.isNotEmpty) 'exercises=${fromCompleted.length}',
          ].join(', ');
          print('➕ [Warmup:3b] merged /users/$uid/workouts/$ymd ($srcMsg) '
              '(added=$added, total=${exercises.length})');
          print('   • names=${exercises.map((e) => (e['name'] ?? e['exercise'] ?? '').toString()).toList()}');
        }
      }
    } catch (e) {
      print('⚠️ [Warmup:3b] merge failed: $e');
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

  double? _rirFromPlan(String exerciseId, int weekIndex, int sessionIndex, int setNumber) {
    final plan = PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['rirPlan'] as Map?;
    if (plan == null) return null;
    final wkKey  = 'week${weekIndex + 1}';
    final sesKey = 'session${sessionIndex + 1}';
    final setKey = 'set$setNumber';
    final raw = (plan[wkKey]?[sesKey]?[setKey]?['rir'])?.toString();
    return (raw == null || raw.trim().isEmpty) ? null : double.tryParse(raw);
  }

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

    for (final row in planned) {
      final name = (row['name'] ?? row['exercise'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final id = (row['exerciseId'] ?? row['id'] ?? row['exercise_id'])?.toString()
          ?? (PeriodizationModelUtils.nameToId[name] ?? name).toString();
      final s = settings[id];
      if (s != null) {
        print('   • [$id] $name → ${jsonEncode(s)}');

        try {
          final incMap = PeriodizationModelUtils.incMapFromRaw(s['increments']);
          final expanded = PeriodizationModelUtils.expandIncrementOptions(incMap);

        } catch (e) {

        }

      } else {

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
    final weekDocs = <int, Map<String, dynamic>>{};
    for (int di = 0; di < 7; di++) {
      final snap = await daysCol.doc('day_$di').get(const GetOptions(source: Source.server));
      if (!snap.exists) {

        weekDocs[di] = {'id': 'day_$di', 'date': null, 'rows': const <Map<String, dynamic>>[]};
        continue;
      }
      final data = snap.data() ?? const <String, dynamic>{};
      final raw  = data['exercises'];
      final rows = (raw is List)
          ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : const <Map<String, dynamic>>[];
      final dateStr = _dateStr(data['date']);

      if (rows.isNotEmpty) {
        final first = rows.first;
        final name = (first['name'] ?? first['exercise'] ?? '').toString();
        final weight = first['weight'];
        final reps = first['reps'];

      }
      weekDocs[di] = {'id': snap.id, 'date': data['date'], 'rows': rows};
    }

    // 2) Pick the day that matches the selected calendar date; NO fallback
    int? matchDi;
    for (int di = 0; di < 7; di++) {
      final d = weekDocs[di];
      if (d == null) continue;
      if (_dateMatches(d['date'])) { matchDi = di; break; }
    }

    if (matchDi == null) {
      return <String, Map<String, dynamic>>{}; // empty overrides
    }

    final useDi = matchDi;
    final sel = weekDocs[useDi] ?? const <String, dynamic>{};
    final selDateStr = _dateStr(sel['date']);
    final selRows = (sel['rows'] is List) ? List<Map<String, dynamic>>.from(sel['rows'] as List) : const <Map<String, dynamic>>[];



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
// ──────────────────────────────────────────────────────────────
// STEP 6: Populate topSetsByExercise from savedWorkoutsList
// Collapse to ONE sample per (exercise, date): the set with the HIGHEST e1RM
// Dates are normalized to YYYY-MM-DD (strings)
  void _populateTopSetsFromSavedWorkouts() {
    final list = PeriodizationModelUtils.savedWorkoutsList;

    // exerciseName -> (ymd -> bestSampleForThatDay)
    final Map<String, Map<String, Map<String, dynamic>>> bestPerDay = {};

    String _ymd(DateTime d) {
      final m = d.month.toString().padLeft(2, '0');
      final da = d.day.toString().padLeft(2, '0');
      return '${d.year}-$m-$da';
    }

    DateTime? _parseAnyDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v);
      // If you have Firestore Timestamps around, add:
      // if (v is Timestamp) return v.toDate();
      return null;
    }

    for (final w in list) {
      final exs = w['exercises'];
      if (exs is! List) continue;

      final wDate = _parseAnyDate(w['date']);
      if (wDate == null) continue; // skip undated workouts
      final y = _ymd(DateTime(wDate.year, wDate.month, wDate.day));

      for (final ex in exs) {
        if (ex is! Map) continue;

        final exName = (ex['name'] ?? ex['exercise'] ?? '').toString().trim();
        if (exName.isEmpty) continue;

        final sets = (ex['sets'] is List)
            ? List<Map<String, dynamic>>.from(ex['sets'])
            : const <Map<String, dynamic>>[];

        for (final s in sets) {
          final weight = (s['actualWeight'] ?? s['weight']);
          final reps   = (s['actualReps'] ?? s['reps']);
          final rirRaw = (s['actualRir'] ?? s['rir']);

          if (weight is! num || reps is! num) continue;

          final double wKg  = (weight as num).toDouble();
          final int    rInt = (reps as num).toInt();
          final double rir  = (rirRaw is num)
              ? (rirRaw as num).toDouble()
              : (rirRaw is String ? (double.tryParse(rirRaw) ?? 0.0) : 0.0);

          // e1RM exactly like PMU
          final double e1 = PeriodizationModelUtils.calculateE1RM(
            wKg, rInt.toDouble(), rir,
          );

          final dayMap = bestPerDay.putIfAbsent(exName, () => <String, Map<String, dynamic>>{});
          final current = dayMap[y];

          if (current == null || ((current['__e1rm'] as double) < e1)) {
            dayMap[y] = {
              'date'  : y,     // <-- store normalized string (JSON-safe)
              'weight': wKg,
              'reps'  : rInt,
              'rir'   : rir,
              '__e1rm': e1,    // internal for sorting/print; stripped later
            };
          }
        }
      }
    }

    // Publish into PMU.topSetsByExercise (newest → oldest by ymd string)
    PeriodizationModelUtils.topSetsByExercise.clear();

    int exCount = 0;
    bestPerDay.forEach((exerciseName, dayMap) {
      final values = dayMap.values.toList()
        ..sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));

      final cleaned = values.map((m) {
        final out = Map<String, dynamic>.from(m)..remove('__e1rm');
        return out;
      }).toList();

      PeriodizationModelUtils.topSetsByExercise[exerciseName] = cleaned;
      exCount++;

      final dbg = values.take(6).map((v) {
        final ds = v['date'] as String; // already YYYY-MM-DD
        return '$ds ${v['weight']}×${v['reps']}@${v['rir']} (e1=${(v['__e1rm'] as double).toStringAsFixed(1)})';
      }).join(', ');
    });
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

    final _sel = (selectedDate != null)
        ? DateTime(selectedDate!.year, selectedDate!.month, selectedDate!.day)
        : DateTime.now();


    // ⛳ ANCHOR: WARM_ACTIVE_BLOCK_RESOLVE
    if (activeBlockId == null || activeBlockId.isEmpty) {
      try {
        final resolved = await BlockRepository().fetchActiveBlockId(uid);
        if (resolved == null || resolved.isEmpty) {
          print('🟥 [Warmup] abort: no active block for uid=$uid');
          return; // cannot compute WES hints without a block
        }
        activeBlockId = resolved;
        print('🎯 [Warmup] resolved activeBlockId=$activeBlockId for uid=$uid');
      } catch (e) {
        print('🟥 [Warmup] active block resolve failed: $e');
        return;
      }
    }


    try {
      final fs = FirebaseFirestore.instance;

      Future<void> _warmWorkoutShapesForDate(DateTime d) async {
        String _ymd(DateTime dt) {
          final m = dt.month.toString().padLeft(2, '0');
          final day = dt.day.toString().padLeft(2, '0');
          return '${dt.year}-$m-$day';
        }

        void _ff(Future<dynamic> fut, String tag) {
          unawaited(
            fut.catchError((e, st) {
              print('🧨 [Warmup] workout query failed ($tag): $e');
            }),
          );
        }

        final workouts = fs.collection('users').doc(uid).collection('workouts');
        final startOfDay = DateTime(d.year, d.month, d.day);
        final nextDay = startOfDay.add(const Duration(days: 1));
        final dateOnly = _ymd(d);
        final nextDateOnly = _ymd(nextDay);
        final isoLocal = startOfDay.toIso8601String();
        final isoUtc = DateTime.utc(startOfDay.year, startOfDay.month, startOfDay.day)
            .toIso8601String();

        // New-style doc by ID
        _ff(
          workouts.doc(dateOnly).get(const GetOptions(source: Source.server)),
          'docId=$dateOnly',
        );

        // Legacy string equals (3 forms)
        _ff(
          workouts
              .where('date', isEqualTo: isoLocal)
              .get(const GetOptions(source: Source.server)),
          "date == isoLocal ($isoLocal)",
        );
        _ff(
          workouts
              .where('date', isEqualTo: isoUtc)
              .get(const GetOptions(source: Source.server)),
          "date == isoUtc ($isoUtc)",
        );
        _ff(
          workouts
              .where('date', isEqualTo: dateOnly)
              .get(const GetOptions(source: Source.server)),
          "date == ymd ($dateOnly)",
        );

        // Legacy string range (captures ISO strings with time-of-day)
        _ff(
          workouts
              .where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
              .where('date', isLessThan: '${nextDateOnly}T00:00:00')
              .get(const GetOptions(source: Source.server)),
          "date string range [$dateOnly .. $nextDateOnly)",
        );

        // Legacy timestamp day-range
        _ff(
          workouts
              .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
              .where('date', isLessThan: Timestamp.fromDate(nextDay))
              .get(const GetOptions(source: Source.server)),
          'date timestamp range [$startOfDay .. $nextDay)',
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
              .limit(_workoutWarmLimit.clamp(1, 1000))
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
          selectedDate: _sel, // 🔹 added
        );

        // ── STEP 3c: detect completed rows for this date + prebuild final hints for them
        List<bool> _skipRow = List<bool>.filled(planned.length, false);
        final Map<String, Map<String, dynamic>> _completedHintsByKey = {};
        final List<int> _engineIdxForPlannedIdx = List<int>.filled(planned.length, -1);

// reuse your row-key helper from Step 8 to keep identity stable
        String _rowKeyBy(int idx) => 'wk${weekIndex}_d${dayIndex}_i$idx';

        String _ymd(DateTime d) {
          final m = d.month.toString().padLeft(2, '0');
          final da = d.day.toString().padLeft(2, '0');
          return '${d.year}-$m-$da';
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
          if (v is String) return double.tryParse(v);
          return null;
        }

        final ymd = _ymd(_sel);
        try {
          final wesSnap = await fs
              .collection('users').doc(uid)
              .collection('workouts').doc(ymd)
              .get(const GetOptions(source: Source.server));

          if (wesSnap.exists) {
            final data = wesSnap.data() ?? const <String, dynamic>{};
            final completed = (data['exercises'] is List)
                ? (data['exercises'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
                : const <Map<String, dynamic>>[];

            // Build a simple matcher: exerciseId (preferred) else normalized name; also match circuitIndex if present
            for (int i = 0; i < planned.length; i++) {
              final p = planned[i];
              final pName = (p['name'] ?? p['exercise'] ?? '').toString().trim();
              if (pName.isEmpty) continue;
              final pId = (p['exerciseId'] ?? p['id'] ?? p['exercise_id'])?.toString()
                  ?? (PeriodizationModelUtils.nameToId[pName] ?? pName).toString();
              final pNorm = _norm(pName);
              final pCi = (p['circuitIndex'] is num) ? (p['circuitIndex'] as num).toInt() : 0;

              Map<String, dynamic>? match;

              for (final ex in completed) {
                final exName = (ex['name'] ?? ex['exercise'] ?? '').toString().trim();
                if (exName.isEmpty) continue;
                final exId = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'])?.toString()
                    ?? (PeriodizationModelUtils.nameToId[exName] ?? exName).toString();
                final exNorm = _norm(exName);
                final exCi = (ex['circuitIndex'] is num) ? (ex['circuitIndex'] as num).toInt() : 0;

                final idMatch = exId.isNotEmpty && pId.isNotEmpty && exId == pId;
                final nameMatch = (exId.isEmpty || pId.isEmpty) && exNorm == pNorm;
                final ciMatch = exCi == pCi;

                if ((idMatch || nameMatch) && ciMatch) {
                  // Any set recorded counts as "completed" for skipping
                  final sets = (ex['sets'] is List)
                      ? (ex['sets'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
                      : const <Map<String, dynamic>>[];
                  if (sets.isNotEmpty) { match = ex; break; }
                }
              }

              if (match != null) {
                _skipRow[i] = true;

                // Build final hint entry for Step 9 (S1 only; optional RIR for S2..S8 if trivially present)
                // Also mark it as completed and include normalized completedSets for WES UI.
                final List<Map<String, dynamic>> sets =
                (match['sets'] as List)
                    .whereType<Map>()
                    .map((m) => Map<String, dynamic>.from(m))
                    .toList();

                // Guard: if somehow no sets, still build a minimal completed entry
                final Map<String, dynamic> s1 =
                sets.isNotEmpty ? sets.first : <String, dynamic>{};

                // Small inline parsers (no nested functions to keep things simple)
                double? _d(dynamic v) {
                  if (v == null) return null;
                  if (v is num) return v.toDouble();
                  if (v is String) return double.tryParse(v);
                  return null;
                }

                int? _i(dynamic v) {
                  if (v == null) return null;
                  if (v is num) return v.toInt();
                  if (v is String) {
                    final m = RegExp(r'(-?\d+)').firstMatch(v.trim());
                    if (m != null) return int.tryParse(m.group(1)!);
                    return int.tryParse(v);
                  }
                  return null;
                }

                final double? s1Weight = _d(s1['actualWeight'] ?? s1['weight']);
                final double? s1Added  = _d(s1['weightAdded'] ?? s1['addedWeight']);
                final double? s1Rir    = _d(s1['actualRir'] ?? s1['rir']);
                final int?    s1Reps   = _i(s1['actualReps'] ?? s1['reps']);

                final bool isBw = PeriodizationModelUtils.isBodyweightExercise(
                  id: pId, name: pName,
                );

                // Normalize all saved sets (S1..Sn) for UI if FastPaint wants to show them directly
                final List<Map<String, dynamic>> completedSets =
                sets.map<Map<String, dynamic>>((raw) {
                  final out = <String, dynamic>{};
                  final reps = _i(raw['actualReps'] ?? raw['reps']);
                  final wt   = _d(raw['actualWeight'] ?? raw['weight']);
                  final add  = _d(raw['weightAdded'] ?? raw['addedWeight']);
                  final rir  = _d(raw['actualRir'] ?? raw['rir']);
                  final vel  = _d(raw['velocity']);
                  final note = (raw['notes'] is String) ? (raw['notes'] as String).trim() : null;

                  if (reps != null) out['reps'] = reps;
                  if (wt   != null) out['weight'] = wt;
                  if (add  != null) out['addedWeight'] = add;
                  if (rir  != null) out['rir'] = rir;
                  if (vel  != null) out['velocity'] = vel;
                  if (note != null && note.isNotEmpty) out['notes'] = note;
                  return out;
                }).toList();

                // Base hint (what FastPaint uses today) + explicit completion flags
                final Map<String, dynamic> entry = <String, dynamic>{
                  'name'        : pName,
                  'circuitIndex': pCi,
                  if (!isBw && s1Weight != null) 's1_weight'       : s1Weight,
                  if (isBw  && s1Added  != null) 's1_weight_added' : s1Added,
                  if (s1Reps != null)            's1_reps'         : s1Reps,
                  if (s1Rir  != null)            's1_rir'          : s1Rir,

                  // ✅ new flags used by WES to render as completed on first paint
                  'completed'     : true,
                  'completedSets' : completedSets,
                };

                // Minimal, safe add: if later sets have explicit RIR, include them (cheap best-effort).
                // We DO NOT compute/guess anything if missing.
                for (int s = 2; s <= 8 && s <= sets.length; s++) {
                  final r = _d(sets[s - 1]['actualRir'] ?? sets[s - 1]['rir']);
                  if (r != null) entry['s${s}_rir'] = r;
                }

                _completedHintsByKey[_rowKeyBy(i)] = entry;
              }
            }
          }
        } catch (e) {
          print('🟧 [Warmup:3c] completed-scan failed: $e');
        }




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

      }
    } catch (_) {
      // best-effort
    }
  }
}
