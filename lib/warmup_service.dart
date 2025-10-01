// warmup_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'periodization_model_utils.dart';
import 'dart:convert'; // for jsonEncode / jsonDecode
import 'dart:async' show unawaited; // if you use unawaited() here
import 'progression_engine.dart';                // engine + inputs
import 'package:intl/intl.dart';                 // for y-M-d convenience (optional)
import 'package:crypto/crypto.dart';   // for sha1
import 'dart:math' as math;

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
    final dayIndex  = ((deltaDays % 7) + 7) % 7; // 0..6, handles negatives too
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
    required DateTime selectedDate, // ← pass _sel
  }) async {
    print('🗓️ [Warmup:3] selectedDate → $selectedDate');



    // Try super-cache first
    final cached = await BlockPlanCache.getDay(
      uid: uid,
      blockId: blockId,
      weekIndex: weekIndex,
      dayIndex: dayIndex,
    );

    if (cached != null) {
      print('🗂️ [Warmup:3] cache HIT → ${cached.length} exercises');

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
    if (dayDoc.exists) {
      final data = dayDoc.data()!;
      final raw = (data['exercises'] ?? data['planned'] ?? data['rows']);
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) exercises.add(Map<String, dynamic>.from(e));
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
// ──────────────────────────────────────────────────────────────
// STEP 6: Populate topSetsByExercise from savedWorkoutsList
// Collapse to ONE sample per (exercise, date): the set with the HIGHEST e1RM
// ──────────────────────────────────────────────────────────────
  void _populateTopSetsFromSavedWorkouts() {
    final list = PeriodizationModelUtils.savedWorkoutsList;

    // exerciseName -> (ymd -> bestSampleForThatDay)
    final Map<String, Map<String, Map<String, dynamic>>> bestPerDay = {};

    String norm(String s) {
      var t = s.toLowerCase().trim();
      t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
      t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
      t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
      t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
      return t;
    }

    String ymd(DateTime d) {
      final m = d.month.toString().padLeft(2, '0');
      final da = d.day.toString().padLeft(2, '0');
      return '${d.year}-$m-$da';
    }

    DateTime? parseAnyDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    // Walk all saved workouts
    for (final w in list) {
      final exs = w['exercises'];
      if (exs is! List) continue;

      final wDate = parseAnyDate(w['date']);
      if (wDate == null) continue; // skip undated workouts

      final y = ymd(DateTime(wDate.year, wDate.month, wDate.day));

      for (final ex in exs) {
        if (ex is! Map) continue;

        final exName = (ex['name'] ?? ex['exercise'] ?? '').toString().trim();
        if (exName.isEmpty) continue;

        // Only numeric-looking sets count
        final sets = (ex['sets'] is List)
            ? List<Map<String, dynamic>>.from(ex['sets'])
            : const <Map<String, dynamic>>[];

        for (final s in sets) {
          final weight = (s['actualWeight'] ?? s['weight']);
          final reps   = (s['actualReps'] ?? s['reps']);
          final rirRaw = (s['actualRir'] ?? s['rir']);

          if (weight is! num || reps is! num) continue;

          final double wKg   = (weight as num).toDouble();
          final int    rInt  = (reps as num).toInt();
          final double rir   = (rirRaw is num) ? (rirRaw as num).toDouble()
              : (rirRaw is String) ? (double.tryParse(rirRaw) ?? 0.0)
              : 0.0;

          // Compute e1RM exactly like PMU would
          final double e1 = PeriodizationModelUtils.calculateE1RM(
            wKg, rInt.toDouble(), rir,
          );

          // Keep the BEST (highest e1RM) for this (exercise, date)
          final dayMap = bestPerDay.putIfAbsent(exName, () => <String, Map<String, dynamic>>{});
          final current = dayMap[y];

          if (current == null || ((current['__e1rm'] as double) < e1)) {
            dayMap[y] = {
              'date'  : wDate,     // keep DateTime if we have it
              'weight': wKg,
              'reps'  : rInt,
              'rir'   : rir,
              '__e1rm': e1,        // internal debug field; we’ll strip before publishing
            };
          }
        }
      }
    }

    // Publish into PMU.topSetsByExercise with debug print
    PeriodizationModelUtils.topSetsByExercise.clear();

    int exCount = 0;
    bestPerDay.forEach((exerciseName, dayMap) {
      // newest → oldest by date
      final values = dayMap.values.toList()
        ..sort((a, b) {
          final ad = a['date'] as DateTime?;
          final bd = b['date'] as DateTime?;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return bd.compareTo(ad);
        });

      // strip __e1rm debug field when storing
      final cleaned = values.map((m) {
        final out = Map<String, dynamic>.from(m)..remove('__e1rm');
        return out;
      }).toList();

      PeriodizationModelUtils.topSetsByExercise[exerciseName] = cleaned;
      exCount++;

      // concise per-exercise debug line (date weight×reps@rir | …)
      final dbg = values.take(6).map((v) {
        final d = v['date'] as DateTime?;
        final ds = (d == null)
            ? '—'
            : '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
        return '$ds ${v['weight']}×${v['reps']}@${v['rir']} (e1=${(v['__e1rm'] as double).toStringAsFixed(1)})';
      }).join(', ');
      print('🔍 [Step6/topSets] $exerciseName → [$dbg]');
    });

    print('📈 [Warmup:6] topSetsByExercise (best-per-day) → $exCount exercises');
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
          selectedDate: _sel, // 🔹 added
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
            // — resolve id/name like Step 4 —
            final row  = planned[exerciseIndex];
            final name = (row['name'] ?? row['exercise'] ?? '').toString();
            final exId = (row['exerciseId'] ?? row['id'] ?? row['exercise_id'])?.toString()
                ?? (PeriodizationModelUtils.nameToId[name] ?? name).toString();

            String _norm(String s) {
              var t = s.toLowerCase().trim();
              t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
              t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
              t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
              t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
              t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
              return t;
            }

            // — locate the Step-4 plan node (id → name → normName) —
            Map<String, dynamic>? _planNode() {
              final byId  = exerciseSettings[exId];
              if (byId is Map<String, dynamic>) return byId;
              final byNm  = exerciseSettings[name];
              if (byNm is Map<String, dynamic>) return byNm;
              final byNNm = exerciseSettings[_norm(name)];
              if (byNNm is Map<String, dynamic>) return byNNm;
              return null;
            }

            final planNode = _planNode();
            final rirPlan  = (planNode?['rirPlan'] is Map) ? Map<String, dynamic>.from(planNode!['rirPlan']) : null;

            // If no plan at all, return default
            if (rirPlan == null || rirPlan.isEmpty) {
              final val = 1.0;
              print('   • [RIR] wk=${weekIndex + 1} day=$dayIndex sess=? set=$setNumber id=$exId "$name" → $val (default:no-plan)');
              return val;
            }

            // — pick week key (prefer exact, then first available) —
            String? weekKey;
            final candidateWeeks = [
              'week_${weekIndex + 1}',
              'week${weekIndex + 1}', // legacy tolerance
            ];
            for (final k in candidateWeeks) {
              if (rirPlan.containsKey(k)) { weekKey = k; break; }
            }
            weekKey ??= (rirPlan.keys.firstWhere(
                  (k) => k.toString().toLowerCase().startsWith('week'),
              orElse: () => rirPlan.keys.first,
            )).toString();

            final weekMap = (rirPlan[weekKey] is Map) ? Map<String, dynamic>.from(rirPlan[weekKey]) : const <String, dynamic>{};
            if (weekMap.isEmpty) {
              final val = 1.0;
              print('   • [RIR] wk=${weekIndex + 1} day=$dayIndex sess=? set=$setNumber id=$exId "$name" → $val (default:empty-week)');
              return val;
            }

            // — choose session key robustly —
            // try exact sessionX, then instanceX, then fallback to session1/instance1, then first session-like key
            int sessIdx = 1; // by design: Step 4’s structure is 1-based; keep it simple & safe
            String? sessionKey;
            final sessCandidates = <String>[
              'session$sessIdx',
              'instance$sessIdx',
              'session1',
              'instance1',
            ];
            for (final k in sessCandidates) {
              if (weekMap.containsKey(k)) { sessionKey = k; break; }
            }
            sessionKey ??= (weekMap.keys.firstWhere(
                  (k) {
                final s = k.toString().toLowerCase();
                return s.startsWith('session') || s.startsWith('instance');
              },
              orElse: () => weekMap.keys.first,
            )).toString();

            final sessMap = (weekMap[sessionKey] is Map) ? Map<String, dynamic>.from(weekMap[sessionKey]) : const <String, dynamic>{};
            if (sessMap.isEmpty) {
              final val = 1.0;
              print('   • [RIR] wk=${weekIndex + 1} day=$dayIndex sess=$sessIdx set=$setNumber id=$exId "$name" → $val (default:empty-session)');
              return val;
            }

            // — choose set key robustly —
            String? setKey;
            final setCandidates = <String>['set$setNumber', 'set1'];
            for (final k in setCandidates) {
              if (sessMap.containsKey(k)) { setKey = k; break; }
            }
            setKey ??= (sessMap.keys.firstWhere(
                  (k) => k.toString().toLowerCase().startsWith('set'),
              orElse: () => sessMap.keys.first,
            )).toString();

            final setNode = sessMap[setKey];

            // — read RIR value with tolerant shapes —
            double? out;
            if (setNode is Map) {
              final raw = setNode['rir'] ?? setNode['RIR'];
              if (raw is num) out = raw.toDouble();
              if (raw is String) out = double.tryParse(raw);
            } else if (setNode is num) {
              out = setNode.toDouble(); // tolerate compact shape: set1: 2.0
            } else if (setNode is String) {
              out = double.tryParse(setNode);
            }

            final val = out ?? 1.0;
            print('   • [RIR] wk=${weekIndex + 1} day=$dayIndex sess=$sessIdx set=$setNumber id=$exId "$name" → $val (plan)');
            return val;
          }

          String _weightTextAt(int exIdx, int setIdx) => '';
          String _rirTextAt(int exIdx, int setIdx) => '';

          final List<Map<String, dynamic>> wesPlanned = <Map<String, dynamic>>[];
          // capture exactly what the engine used so we don't re-derive later
          final List<double?> _rirUsedByRow = <double?>[];
          final List<double?> _planRepsByRow = <double?>[];
          final List<bool>    _isBwByRow     = <bool>[];


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

          double _getRepsFromPlan(int exerciseIndex, int setNumber) {
            // resolve id/name exactly like Step 4
            final row  = planned[exerciseIndex];
            final name = (row['name'] ?? row['exercise'] ?? '').toString();
            final exId = (row['exerciseId'] ?? row['id'] ?? row['exercise_id'])?.toString()
                ?? (PeriodizationModelUtils.nameToId[name] ?? name).toString();

            // small locals
            String _norm(String s) {
              var t = s.toLowerCase().trim();
              t = t.replaceAll(RegExp(r'\([^)]*\)'), '');
              t = t.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
              t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
              t = t.replaceAll(RegExp(r'\bdb\b'), 'dumbbell');
              t = t.replaceAll(RegExp(r'\bbb\b'), 'barbell');
              return t;
            }
            DateTime _dOnly(DateTime d) => DateTime(d.year, d.month, d.day);
            DateTime? _parseAnyDate(dynamic v) {
              if (v == null) return null;
              if (v is Timestamp) return v.toDate();
              if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
              if (v is String) return DateTime.tryParse(v);
              return null;
            }
            bool _hasValidSet(dynamic setsRaw) {
              final sets = (setsRaw is List) ? setsRaw.cast<Map>() : const <Map>[];
              return sets.any((s) {
                final w = (s['actualWeight'] ?? s['weight'] ?? '').toString().trim();
                final r = (s['actualReps'] ?? s['reps'] ?? '').toString().trim();
                return double.tryParse(w) != null && int.tryParse(r) != null;
              });
            }
            int _safeParseInt(dynamic v, {int fallback = 10}) {
              if (v is num) return v.toInt();
              if (v is String) {
                final m = RegExp(r'(-?\d+)').firstMatch(v.trim());
                if (m != null) return int.tryParse(m.group(1)!) ?? fallback;
              }
              return fallback;
            }

            // get Step-4 exercise settings node (id → name → normName)
            Map<String, dynamic>? _planNode() {
              final byId  = exerciseSettings[exId];
              if (byId is Map<String, dynamic>) return byId;
              final byNm  = exerciseSettings[name];
              if (byNm is Map<String, dynamic>) return byNm;
              final byNNm = exerciseSettings[_norm(name)];
              if (byNNm is Map<String, dynamic>) return byNNm;
              return null;
            }

            // helper: today's planned index for this exercise (1-based up to this row)
            int _todayPlannedIndex() {
              int seen = 0;
              for (int i = 0; i <= exerciseIndex && i < planned.length; i++) {
                final pid = (planned[i]['exerciseId'] ?? planned[i]['id'] ?? planned[i]['exercise_id'])?.toString()
                    ?? (PeriodizationModelUtils.nameToId[
                    (planned[i]['name'] ?? planned[i]['exercise'] ?? '').toString()
                    ] ??
                        (planned[i]['name'] ?? planned[i]['exercise'] ?? '').toString()).toString();
                if (pid == exId) seen++;
              }
              return seen;
            }

            // helper: completed instances across the block strictly before today (unique days with valid sets)
            int _completedBeforeTodayInBlock() {
              if (blockStart == null || _sel == null) return 0;
              final base       = _dOnly(blockStart);
              final todayStart = _dOnly(_sel);
              final targetNameNorm = _norm(name);

              final matchedDays = <String>{};
              for (final w in PeriodizationModelUtils.savedWorkoutsList) {
                final dt = _parseAnyDate(w['date']);
                if (dt == null) continue;
                final dayOnly = _dOnly(dt);
                if (dayOnly.isBefore(base) || !dayOnly.isBefore(todayStart)) continue; // [base, today)

                final exs = w['exercises'];
                if (exs is! List) continue;

                final matched = exs.any((ex) {
                  if (!_hasValidSet(ex['sets'])) return false;

                  // Prefer id match; fallback to name→id mapping or normalized name
                  final rowId = (ex['exerciseId'] ?? ex['id'] ?? ex['exercise_id'] ?? '').toString().trim();
                  if (rowId.isNotEmpty && rowId == exId) return true;

                  final exName = (ex['name'] ?? ex['exercise'] ?? ex['title'] ?? '').toString().trim();
                  if (exName.isEmpty) return false;

                  final mapped = (PeriodizationModelUtils.nameToId[exName] ?? '').toString().trim();
                  if (mapped == exId) return true;

                  return _norm(exName) == targetNameNorm;
                });

                if (matched) {
                  final key = '${dayOnly.year}-${dayOnly.month.toString().padLeft(2, '0')}-${dayOnly.day.toString().padLeft(2, '0')}';
                  matchedDays.add(key);
                }
              }
              return matchedDays.length;
            }

            // pull node + model name from Step 4
            final plan = _planNode();
            if (plan == null) return 10.0;

            final periodization = (plan['periodizationModel'] ?? '').toString().toLowerCase();

            // === CASE 1: DUP, By Exposure → global across the block ===
            if (periodization.contains('exposure')) {
              // instance list lives under repTargets.week1.instance{n}
              final repTargets = (plan['repTargets'] is Map)
                  ? Map<String, dynamic>.from(plan['repTargets'])
                  : null;
              if (repTargets == null || repTargets.isEmpty) return 10.0;

              // pick week1 (or the first week-like map as a fallback)
              String? weekKey;
              for (final k in ['week1', 'week_1']) {
                if (repTargets.containsKey(k)) { weekKey = k; break; }
              }
              weekKey ??= repTargets.keys.firstWhere(
                    (k) => k.toString().toLowerCase().startsWith('week'),
                orElse: () => repTargets.keys.first,
              ).toString();

              final wk = repTargets[weekKey];
              if (wk is! Map) return 10.0;

              // collect & sort instance keys
              final instanceEntries = wk.entries
                  .where((e) => e.key.toString().toLowerCase().startsWith('instance'))
                  .toList()
                ..sort((a, b) => a.key.compareTo(b.key));

              if (instanceEntries.isEmpty) return 10.0;

              final completedBefore = _completedBeforeTodayInBlock();
              final todayIdx        = _todayPlannedIndex(); // 1-based
              final globalIndex0    = (completedBefore + todayIdx - 1) % instanceEntries.length;

              final raw = instanceEntries[globalIndex0].value?.toString() ?? '';
              // formats like "9 x 3" → take the first integer as reps
              final m = RegExp(r'^\s*(\d+)').firstMatch(raw);
              return (m != null ? int.tryParse(m.group(1)!) ?? 10 : 10).toDouble();
            }

            // === CASE 2+: other models → keep your existing tolerant behavior ===
            // 2a) try reps in rirPlan[week][session][set].reps (matches how you read RIR)
            final rirPlan = (plan['rirPlan'] is Map)
                ? Map<String, dynamic>.from(plan['rirPlan'])
                : null;
            if (rirPlan != null && rirPlan.isNotEmpty) {
              // choose week key
              String? wKey;
              for (final k in ['week_${weekIndex + 1}', 'week${weekIndex + 1}', 'week1']) {
                if (rirPlan.containsKey(k)) { wKey = k; break; }
              }
              wKey ??= rirPlan.keys.firstWhere(
                    (k) => k.toString().toLowerCase().startsWith('week'),
                orElse: () => rirPlan.keys.first,
              ).toString();

              final weekMap = (rirPlan[wKey] is Map)
                  ? Map<String, dynamic>.from(rirPlan[wKey])
                  : const <String, dynamic>{};

              // prefer session1/instance1 and setN/set1 (same robust selection you used for RIR)
              String? sessKey;
              for (final k in ['session1','instance1']) {
                if (weekMap.containsKey(k)) { sessKey = k; break; }
              }
              sessKey ??= weekMap.keys.firstWhere(
                    (k) {
                  final s = k.toString().toLowerCase();
                  return s.startsWith('session') || s.startsWith('instance');
                },
                orElse: () => weekMap.keys.first,
              ).toString();

              final sessMap = (weekMap[sessKey] is Map)
                  ? Map<String, dynamic>.from(weekMap[sessKey])
                  : const <String, dynamic>{};

              String? setKey;
              for (final k in ['set$setNumber', 'set1']) {
                if (sessMap.containsKey(k)) { setKey = k; break; }
              }
              setKey ??= sessMap.keys.firstWhere(
                    (k) => k.toString().toLowerCase().startsWith('set'),
                orElse: () => (sessMap.isNotEmpty ? sessMap.keys.first : 'set1'),
              ).toString();

              final node = sessMap[setKey];
              if (node is Map) return _safeParseInt(node['reps']).toDouble();
              if (node is num || node is String) return _safeParseInt(node).toDouble();
            }

            // 2b) fallback to repTargets[week].instanceX first number
            final repTargets = (plan['repTargets'] is Map)
                ? Map<String, dynamic>.from(plan['repTargets'])
                : null;
            if (repTargets != null && repTargets.isNotEmpty) {
              String? weekKey;
              for (final k in ['week_${weekIndex + 1}', 'week1', 'week${weekIndex + 1}']) {
                if (repTargets.containsKey(k)) { weekKey = k; break; }
              }
              weekKey ??= repTargets.keys.firstWhere(
                    (k) => k.toString().toLowerCase().startsWith('week'),
                orElse: () => repTargets.keys.first,
              ).toString();

              final wk = repTargets[weekKey];
              if (wk is Map) {
                // prefer instance1; else first instance-like; else first
                String? instKey;
                for (final k in ['instance1']) {
                  if (wk.containsKey(k)) { instKey = k; break; }
                }
                instKey ??= wk.keys.firstWhere(
                      (k) => k.toString().toLowerCase().startsWith('instance'),
                  orElse: () => wk.keys.first,
                ).toString();

                final raw = wk[instKey]?.toString() ?? '';
                final m = RegExp(r'^\s*(\d+)').firstMatch(raw);
                if (m != null) return (int.tryParse(m.group(1)!) ?? 10).toDouble();
              }
            }

            // final fallback
            return 10.0;
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

            // capture the exact plan inputs the engine used for its calc
            final usedRir  = _getRirFromPlanOrInput(iRow, 1);
            final planReps = _getRepsFromPlan(iRow, 1);

// record them in order, aligned to iRow
            _rirUsedByRow.add(usedRir);
            _planRepsByRow.add(planReps);

// also record BW vs non-BW for the row (to control s1_weight_added output)
            final exName = (res['exerciseName'] ?? '').toString();
            final exId   = (res['exerciseId'] ?? PeriodizationModelUtils.nameToId[exName] ?? exName).toString();
            final isBw   = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: exName);
            _isBwByRow.add(isBw);

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
            final usedRir  = _getRirFromPlanOrInput(i, 1);     // RIR used for calc
            final planReps = _getRepsFromPlan(i, 1);           // Reps from Step-4 plan
            final overlayRir = (r['rir'] as num?)?.toDouble(); // BB2 override after calc (if any)
            final rirInfo = (overlayRir == null || overlayRir == usedRir)
                ? 'rir=$usedRir'
                : 'rirUsed=$usedRir override=$overlayRir';

            print('   • #$i ${r['exerciseName']} → ${r['weight']}kg @ $planReps ($rirInfo) '
                'id=${r['exerciseId']}');
            print('   • [CTX] wk=$weekIndex day=$dayIndex date=${_sel.toIso8601String().substring(0,10)}');






        }

          // Build final hints directly from ENGINE outputs (post-progression)
          final Map<String, Map<String, dynamic>> hints = <String, Map<String, dynamic>>{};
          for (int i = 0; i < wesPlanned.length; i++) {
            final res  = wesPlanned[i];  // progressed row from the engine
            final name = (res['exerciseName'] ?? '').toString();
            final ci   = (planned[i]['circuitIndex'] is num) ? (planned[i]['circuitIndex'] as num).toInt() : 0;

            // absolute weight from engine
            final double? wAbs   = (res['weight'] as num?)?.toDouble();
            // display-added only exists (and only makes sense) on BW rows
            final double? wAdded = (res['weightDisplayAdded'] as num?)?.toDouble();

            // reps from engine (includes DUPE/linear resolution)
            final double? reps   = (res['reps'] as num?)?.toDouble();

            // RIR: prefer an explicit override in engine output when it’s intentional;
            // otherwise fall back to plan-based RIR used by calc
            final double? rirOverlay = (res['rir'] as num?)?.toDouble();
            final double planRir = _getRirFromPlanOrInput(i, 1);

            bool _isMeaningfulOverride(num? v) => v != null && v != 0; // 0 is valid but must be intentional upstream
            final double? rirFinal = _isMeaningfulOverride(rirOverlay) ? rirOverlay : planRir;

            final key = _rowKeyBy(i);
            final entry = <String, dynamic>{
              'name'        : name,
              'circuitIndex': ci,
              if (wAbs   != null) 's1_weight'       : wAbs,
              if (wAdded != null) 's1_weight_added' : wAdded, // only present for BW
              if (reps   != null) 's1_reps'         : reps,
              if (rirFinal != null) 's1_rir'        : rirFinal,
            };

            hints[key] = entry;
          }

// quick sanity peek
          hints.entries.take(2).forEach((e) {
            print('🟣 [Warmup:8→9] hint ${e.key} → ${e.value}');
          });

// JSON for Step 9 snapshot


/// Build final hints directly from ENGINE outputs (post-progression) + the exact plan RIR it used
          hints.clear(); // ← reuse the existing map instead of redeclaring

          for (int i = 0; i < wesPlanned.length; i++) {
            final res  = wesPlanned[i];  // progressed row from the engine
            final name = (res['exerciseName'] ?? '').toString();
            final ci   = (planned[i]['circuitIndex'] is num)
                ? (planned[i]['circuitIndex'] as num).toInt()
                : 0;

            // absolute weight from engine
            final double? wAbs   = (res['weight'] as num?)?.toDouble();
            // display-added only makes sense on BW rows → computed by engine as 'weightDisplayAdded'
            final double? wAdded = (res['weightDisplayAdded'] as num?)?.toDouble();

            // the reps the engine settled on for set 1 (already model-aware)
            final double? reps   = (res['reps'] as num?)?.toDouble() ?? _planRepsByRow[i];

            // RIR: prefer explicit overlay if non-null; else use the exact plan RIR the engine used
            final double? rirOverlay = (res['rir'] as num?)?.toDouble(); // may be null
            final double? planRir    = _rirUsedByRow[i];                 // captured earlier
            final bool hasIntentionalOverride = (rirOverlay != null);    // 0.0 is valid override
            final double? rirFinal = hasIntentionalOverride ? rirOverlay : planRir;

            // BW/non-BW check we captured during the engine pass
            final bool isBw = _isBwByRow[i];

            final key = _rowKeyBy(i);
            final entry = <String, dynamic>{
              'name'        : name,
              'circuitIndex': ci,
              if (wAbs   != null) 's1_weight'       : wAbs,
              if (isBw && wAdded != null) 's1_weight_added' : wAdded, // only for BW
              if (reps   != null) 's1_reps'         : reps,
              if (rirFinal != null) 's1_rir'        : rirFinal,
            };

            hints[key] = entry;
          }

// (Optional) peek a couple for sanity
          hints.entries.take(2).forEach((e) {
            print('🟣 [Warmup:8→9] hint ${e.key} → ${e.value}');
          });

// JSON for Step 9 snapshot — compute AFTER filling `hints`
          final String hintsJson = jsonEncode(hints);

// Keep in scope for Step 9 (persist to Isar)
// ⛳ anchor: Step 8 outputs
          final _wesPlannedForPersist = wesPlanned;


          // ──────────────────────────────────────────────────────────────
// STEP 9: Persist full first-paint snapshot to Isar (no compromises)
// ──────────────────────────────────────────────────────────────
          try {
            // Helpers
            String _ymd(DateTime d) {
              final m = d.month.toString().padLeft(2, '0');
              final da = d.day.toString().padLeft(2, '0');
              return '${d.year}-$m-$da';
            }

            // 9.1 Build hintsJson (Map keyed by rowKey: wk{w}_d{d}_i{idx})
            final Map<String, Map<String, dynamic>> hints = <String, Map<String, dynamic>>{};
            for (int i = 0; i < _wesPlannedForPersist.length && i < planned.length; i++) {
              final rowKey = 'wk${weekIndex}_d${dayIndex}_i$i';
              final res    = _wesPlannedForPersist[i];

              final name = (planned[i]['name'] ?? planned[i]['exercise'] ?? '').toString().trim();
              final ci   = (planned[i]['circuitIndex'] is num)
                  ? (planned[i]['circuitIndex'] as num).toInt()
                  : 0;

              // absolute weight from engine result
              final double? absW = (res['weight'] as num?)?.toDouble();

              // compute the SAME inputs the engine used
              final double usedRir  = _getRirFromPlanOrInput(i, 1);
              final double planReps = _getRepsFromPlan(i, 1);

              // include display-added ONLY for BW
              final String exId = (planned[i]['exerciseId'] ?? planned[i]['id'] ?? planned[i]['exercise_id'])?.toString()
                  ?? (PeriodizationModelUtils.nameToId[name] ?? name).toString();
              final bool isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: name);
              final double? addW = isBw
                  ? (res['weightDisplayAdded'] as num?)?.toDouble()
                  : null;

              final double? e1rm = (res['e1rm'] as num?)?.toDouble();

              hints[rowKey] = <String, dynamic>{
                'name': name,
                'circuitIndex': ci,
                's1_weight': absW,
                if (addW != null) 's1_weight_added': addW, // BW only
                's1_reps': planReps,
                's1_rir': usedRir,
                if (e1rm != null) 'e1rm': e1rm,
              };
            }
            final String hintsJson = jsonEncode(hints);


            // 9.2 Compute inputs hash to match WES _computeNowInputsHash()
            //     (Use PMU getters, not Step-4 map, to guarantee byte-for-byte intent)
            int _getWeek(DateTime d, DateTime blockStart) =>
                PeriodizationModelUtils.getWeekIndexForDate(d, blockStart);

            // plannedExercises: [{id, circuitIndex}]
            final List<Map<String, dynamic>> plannedForHash = planned.map<Map<String, dynamic>>((e) {
              final name = (e['name'] ?? e['exercise'] ?? '').toString();
              final id   = (PeriodizationModelUtils.nameToId[name] ??
                  e['id'] ?? e['exerciseId'] ?? e['exercise_id'] ??
                  name).toString();
              final ci   = (e['circuitIndex'] is num) ? (e['circuitIndex'] as num).toInt() : 0;
              return {'id': id, 'circuitIndex': ci};
            }).toList();

            // plannedExerciseDetails + exerciseSettings come from PMU
            final Map<String, dynamic> plannedExerciseDetails =
            Map<String, dynamic>.from(PeriodizationModelUtils.plannedExerciseDetails);
            final Map<String, dynamic> exerciseSettingsPMU =
            Map<String, dynamic>.from(PeriodizationModelUtils.getExerciseSettings());

            // bodyweight, lastWorkoutDate, lastTopSetDate
            String? _maxWorkoutDateYmd(List<Map<String, dynamic>> workouts) {
              DateTime? maxD;
              for (final w in workouts) {
                final v = w['date'];
                DateTime? dt;
                if (v is Timestamp) dt = v.toDate();
                if (dt == null && v is String) dt = DateTime.tryParse(v);
                if (dt == null) continue;
                final dOnly = DateTime(dt.year, dt.month, dt.day);
                if (maxD == null || dOnly.isAfter(maxD)) maxD = dOnly;
              }
              return (maxD == null) ? null : _ymd(maxD);
            }

            String? _maxTopSetDateYmd(Map<String, List<Map<String, dynamic>>> topSets) {
              DateTime? maxD;
              for (final list in topSets.values) {
                for (final s in list) {
                  final v = s['date'];
                  DateTime? dt;
                  if (v is Timestamp) dt = v.toDate();
                  if (dt == null && v is DateTime) dt = v;
                  if (dt == null && v is String) dt = DateTime.tryParse(v);
                  if (dt == null) continue;
                  final dOnly = DateTime(dt.year, dt.month, dt.day);
                  if (maxD == null || dOnly.isAfter(maxD)) maxD = dOnly;
                }
              }
              return (maxD == null) ? null : _ymd(maxD);
            }

            final String uidForHash = uid;
            final String blockForHash = activeBlockId;
            final String dateYmd = _ymd(_sel);
            final int weekIdx = _getWeek(_sel, blockStart);

            final double? bodyweightAsOfDay = PeriodizationModelUtils.bodyweightKgForDate(
              uid: uidForHash,
              asOf: _sel,
            );

            final String? lastWorkoutDate = _maxWorkoutDateYmd(
                List<Map<String, dynamic>>.from(PeriodizationModelUtils.savedWorkoutsList));

            final String? lastTopSetDate = _maxTopSetDateYmd(
                Map<String, List<Map<String, dynamic>>>.from(PeriodizationModelUtils.topSetsByExercise));

            // Build payload in stable key order
            final Map<String, dynamic> _payload = <String, dynamic>{
              'uid': uidForHash,
              'blockId': blockForHash,
              'dateYmd': dateYmd,
              'weekIndex': weekIdx,
              'plannedExercises': plannedForHash,
              'plannedExerciseDetails': plannedExerciseDetails,
              'exerciseSettings': exerciseSettingsPMU,
              'bodyweightAsOfDay': bodyweightAsOfDay,
              'lastWorkoutDate': lastWorkoutDate,
              'lastTopSetDate': lastTopSetDate,
            };
            // SHA1 of JSON string (stable order implied by insertion order)
            final String hintsInputsHash = sha1.convert(utf8.encode(jsonEncode(_payload))).toString();

            // 9.3 previousWorkoutJson (latest strictly BEFORE _sel)
            Map<String, dynamic>? _pickPrevWorkout() {
              DateTime? bestDate;
              Map<String, dynamic>? best;
              for (final w in PeriodizationModelUtils.savedWorkoutsList) {
                final v = w['date'];
                DateTime? dt;
                if (v is Timestamp) dt = v.toDate();
                if (dt == null && v is String) dt = DateTime.tryParse(v);
                if (dt == null) continue;
                final dOnly = DateTime(dt.year, dt.month, dt.day);
                if (!dOnly.isBefore(DateTime(_sel.year, _sel.month, _sel.day))) continue; // strictly before selected day
                if (bestDate == null || dOnly.isAfter(bestDate)) {
                  bestDate = dOnly;
                  best = w;
                }
              }
              return best;
            }

            List<Map<String, dynamic>> _normalizePrevWorkoutSets(dynamic setsRaw) {
              final out = <Map<String, dynamic>>[];
              final sets = (setsRaw is List) ? setsRaw.whereType<Map>().map((m)=>Map<String,dynamic>.from(m)).toList() : const <Map<String,dynamic>>[];
              for (final s in sets) {
                final reps = (s['actualReps'] ?? s['reps']);
                final weight = (s['actualWeight'] ?? s['weight']);
                final added  = (s['weightAdded'] ?? s['addedWeight']);
                final rir    = (s['actualRir'] ?? s['rir']);
                final vel    = (s['velocity']);
                final notes  = (s['notes']);
                out.add({
                  if (reps is num) 'reps': reps.toInt(),
                  if (weight is num) 'weight': (weight as num).toDouble(),
                  if (added is num) 'addedWeight': (added as num).toDouble(),
                  if (rir is num) 'rir': (rir as num).toDouble(),
                  if (vel is num) 'velocity': (vel as num).toDouble(),
                  if (notes is String && notes.trim().isNotEmpty) 'notes': notes.trim(),
                });
              }
              return out;
            }

            List<Map<String, dynamic>> _buildPreviousWorkoutJson() {
              final prev = _pickPrevWorkout();
              if (prev == null) return const <Map<String, dynamic>>[];
              final exs = (prev['exercises'] is List)
                  ? (prev['exercises'] as List).whereType<Map>().map((m)=>Map<String,dynamic>.from(m)).toList()
                  : const <Map<String, dynamic>>[];
              final out = <Map<String, dynamic>>[];
              for (final e in exs) {
                final name = (e['name'] ?? e['exercise'] ?? '').toString().trim();
                if (name.isEmpty) continue;
                final ci = (e['circuitIndex'] is num) ? (e['circuitIndex'] as num).toInt() : 0;
                out.add({
                  'name': name,
                  'circuitIndex': ci,
                  'sets': _normalizePrevWorkoutSets(e['sets']),
                });
              }
              return out;
            }

            final String topSetHistoryJson = jsonEncode(
              PeriodizationModelUtils.topSetsByExercise, // exact map from Step 6 (already reduced per PMU policy)
            );

            final List<Map<String, dynamic>> previousWorkout = _buildPreviousWorkoutJson();

            // 9.4 Skip/Overwrite policy
            final existing = await BlockPlanCache.getInitSnapshot(
              uid: uid,
              blockId: activeBlockId,
              dateYmd: dateYmd,
            );

// Always show the hash we computed
            print('[Warmup:9] computed hash for $dateYmd → $hintsInputsHash');

            if (existing != null && existing.hintsInputsHash == hintsInputsHash) {
              // SKIPPED: hash unchanged — dump what's already stored so you can inspect it
              final plannedLen = () {
                try { final d = jsonDecode(existing.plannedExercisesJson); return d is List ? d.length : 0; } catch (_) { return 0; }
              }();
              final wesLen = () {
                try { final d = jsonDecode(existing.wesPlannedExercisesJson); return d is List ? d.length : 0; } catch (_) { return 0; }
              }();
              final prevLen = () {
                try { final d = jsonDecode(existing.previousWorkoutJson); return d is List ? d.length : 0; } catch (_) { return 0; }
              }();
              final hintsLen = (existing.hintsJson?.length ?? 0);
              final hintsPreview = (existing.hintsJson?.isNotEmpty ?? false)
                  ? existing.hintsJson!.substring(0, (existing.hintsJson!.length).clamp(0, 400))
                  : '{}';

              print('[Warmup:9] skipped (hash unchanged) for $dateYmd '
                  '→ planned=$plannedLen wes=$wesLen prev=$prevLen '
                  'hintsLen=$hintsLen hintsReady=${existing.hintsReady} ver=${existing.schemaVersion}');
              print('[Warmup:9] existing hintsJson preview → $hintsPreview');

            } else {
              print('[Warmup:9] about to put snapshot → hash=$hintsInputsHash hintsJsonLen=${hintsJson.length}');

              await BlockPlanCache.putInitSnapshot(
                uid: uid,
                blockId: activeBlockId,
                dateYmd: dateYmd,
                plannedExercises: planned,
                wesPlannedExercises: _wesPlannedForPersist,
                previousWorkout: previousWorkout,
                topSetHistory: PeriodizationModelUtils.topSetsByExercise.entries
                    .map((e) => <String, dynamic>{'exercise': e.key, 'sets': e.value})
                    .toList(),
                hintsJson: hintsJson,
                hintsInputsHash: hintsInputsHash,
                hintsReady: true,
                schemaVersion: 1,
                updatedAt: DateTime.now(),
              );

              // Post-write summary + safe preview (save branch)
              final preview = (hintsJson.isNotEmpty)
                  ? hintsJson.substring(0, hintsJson.length.clamp(0, 400))
                  : '{}';
              print('[Warmup:9] snapshot values → '
                  'planned=${planned.length} '
                  'wes=${_wesPlannedForPersist.length} '
                  'prev=${previousWorkout.length} '
                  'topSets=${PeriodizationModelUtils.topSetsByExercise.keys.length} '
                  'hints=${hints.length}');
              print('[Warmup:9] hintsJson → $preview');
              print('[Warmup:9] snapshot saved for $dateYmd (hash: $hintsInputsHash, rows: ${planned.length})');
            }

// 🔎 ALWAYS re-read from Isar to verify current stored row (skip or save)
            try {
              final snapCheck = await BlockPlanCache.getInitSnapshot(
                uid: uid,
                blockId: activeBlockId,
                dateYmd: dateYmd,
              );

              if (snapCheck == null) {
                print('🟥 [Warmup:9][Isar] re-read FAILED for $dateYmd (no row found)');
              } else {
                String _cut(String s, int n) => s.substring(0, s.length.clamp(0, n));

                final plannedLen2 = (() {
                  try { final d = jsonDecode(snapCheck.plannedExercisesJson); return d is List ? d.length : 0; } catch (_) { return 0; }
                })();
                final wesLen2 = (() {
                  try { final d = jsonDecode(snapCheck.wesPlannedExercisesJson); return d is List ? d.length : 0; } catch (_) { return 0; }
                })();
                final prevLen2 = (() {
                  try { final d = jsonDecode(snapCheck.previousWorkoutJson); return d is List ? d.length : 0; } catch (_) { return 0; }
                })();

                print('[Warmup:9][Isar] re-read ok → '
                    'uid=${snapCheck.uid} bid=${snapCheck.blockId} ymd=${snapCheck.dateYmd} '
                    'hash=${snapCheck.hintsInputsHash} '
                    'hintsReady=${snapCheck.hintsReady} ver=${snapCheck.schemaVersion} '
                    'planned=$plannedLen2 wes=$wesLen2 prev=$prevLen2 '
                    'updatedAt=${snapCheck.updatedAt} cachedAt=${snapCheck.cachedAt}');
                final hintsPreview2 = (snapCheck.hintsJson?.isNotEmpty ?? false)
                    ? _cut(snapCheck.hintsJson!, 200)
                    : '{}';
                print('[Warmup:9][Isar] hintsJson preview → $hintsPreview2');
              }
            } catch (e) {
              print('🟧 [Warmup:9][Isar] re-read threw: $e');
            }
          } catch (e, st) {
            print('🟥 [Warmup:9] snapshot failed: $e');
            // best-effort only
          }
        }
      }
    } catch (_) {
      // best-effort
    }
  }
}
