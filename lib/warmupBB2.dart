import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';

import 'local_cache/isar_db.dart';
import 'local_cache/isar_bb2_merged_day.dart';
import 'local_cache/block_plan_cache.dart'; // for helpers if you want
import 'periodization_model_utils.dart'; // assumes this exports functions you call in BB2
import 'block_repository.dart';   // same repo you use in BB2

/// Public entrypoints:
///  - WarmupBB2.runForActiveBlock(uid)  → resolves active block, computes current week, warms it.
///  - WarmupBB2.run(uid:blockId:weekIndex) → warms a specific week.
///
/// All Firestore reads here are SERVER reads (authoritative) to avoid a “flash”
/// when BB2 opens. We persist controller-ready rows to Isar so BB2 can paint
/// the first frame with correct data.
class WarmupBB2 {
  /// Runs warmup on Home init: resolve active block, compute current week, warm.
  static Future<void> runForActiveBlock({
    required String uid,

  }) async {


    try {


      final activeId = await _resolveActiveBlockId(uid);
      if (activeId == null || activeId.isEmpty) return;

      final (_start, _end) = await _loadBlockDatesFromDoc(uid: uid, blockId: activeId);
      if (_start == null || _end == null) {
        if (kDebugMode) debugPrint('[WarmupBB2] block meta missing dates; abort.');
        return;
      }
      final DateTime startLocal = _asLocalDate(_start);
      final DateTime endLocal   = _asLocalDate(_end);


      final today = DateTime.now();
      final weekIndex = (today.difference(_displayStartFor(startLocal, endLocal).$1).inDays ~/ 7)
          .clamp(0, _totalWeeks(startLocal, endLocal) - 1);
      debugPrint('📅 [WarmupBB2:resolved] uid=$uid block=$activeId week=$weekIndex');

      await run(uid: uid, blockId: activeId, weekIndex: weekIndex, blockStartDate: startLocal, blockEndDate: endLocal);
    } catch (e, st) {
      if (kDebugMode) debugPrint('[WarmupBB2] runForActiveBlock failed: $e\n$st');
    }
  }

  static Future<(DateTime?, DateTime?)> _loadBlockDatesFromDoc({
    required String uid,
    required String blockId,
  }) async {
    final ref = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    final snap = await ref.get(const GetOptions(source: Source.server));
    final data = snap.data() ?? const <String, dynamic>{};

    DateTime? toDt(dynamic v) {
      if (v == null) return null;
      if (v is Timestamp) return v.toDate();
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString());
    }

    // Adjust field names here if your doc uses different keys
    final start = toDt(data['startDate']);
    final end   = toDt(data['endDate']);
    return (start, end);
  }


  /// Warm up a specific week of a block for a uid.
  static Future<void> run({
    required String uid,
    required String blockId,
    required int weekIndex,
    required DateTime blockStartDate,
    required DateTime blockEndDate,
  }) async {
    try {
      debugPrint('🧊 [WarmupBB2:start] uid=$uid block=$blockId week=$weekIndex');

      // 1) Read authoritative meta and week/day docs (SERVER)
      final blocksCol = FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks');
      final blockDocRef = blocksCol.doc(blockId);
      final weekDocRef  = blockDocRef.collection('weeks').doc('week_$weekIndex');

      final metaSnap    = await blockDocRef.get(const GetOptions(source: Source.server));
      final weekSnap    = await weekDocRef.get(const GetOptions(source: Source.server));
      final daysSnap    = await weekDocRef.collection('days').get(const GetOptions(source: Source.server));

      if (!weekSnap.exists) {
        if (kDebugMode) debugPrint('[WarmupBB2] week_$weekIndex missing; abort warmup.');
        return;
      }

      final blockData = metaSnap.data() ?? const <String, dynamic>{};
      final plannerUpdatedAt = _coerceTimestamp(blockData['updatedAt']);

      // 2) Pull WES docs for the week window (SERVER)
      final weekStart = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day)
          .add(Duration(days: weekIndex * 7));
      final weekEnd = weekStart.add(const Duration(days: 7));

      String _isoDay(DateTime d) =>
          '${DateTime(d.year, d.month, d.day).toIso8601String().split(".").first}.000';

      final workoutsCol = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('workouts');

      final wesServerSnap = await workoutsCol
          .where('date', isGreaterThanOrEqualTo: _isoDay(weekStart))
          .where('date', isLessThan: _isoDay(weekEnd))
          .get(const GetOptions(source: Source.server));

      // 3) Build controller-ready rows exactly like BB2 would after loadBlockDataForWeek
      final parsedByDayIndex = <int, List<Map<String, dynamic>>>{};
      final circuitStartsByDay = <int, List<int>>{};

      // 3a) index WES legacy auto-ID docs by yyyy-MM-dd
      Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>> legacyByDate = {};
      for (final d in wesServerSnap.docs) {
        final raw = d.data()['date'];
        final dt = (raw is Timestamp) ? raw.toDate() : DateTime.tryParse(raw?.toString() ?? '');
        if (dt == null) continue;
        final key = _ymd(DateTime(dt.year, dt.month, dt.day));
        (legacyByDate[key] ??= []).add(d);
      }

      // 3b) parent settings & PMU details (we’ll inject to PMU only when needed)
      final plannedDetails = Map<String, Map<String, dynamic>>.from(
        ((blockData['plannedExerciseDetails'] ?? const {}) as Map).map(
              (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)),
        ),
      );
      final exerciseSettings = Map<String, Map<String, dynamic>>.from(
        ((blockData['exerciseSettings'] ?? const {}) as Map).map(
              (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)),
        ),
      );

      // 3c) Parse planned rows, apply WES overrides, BW behavior, and suppression/prune
      for (final d in daysSnap.docs) {
        final dayIndex = int.tryParse(d.id.replaceFirst('day_', '')) ?? 0;
        final data = d.data();
        final planned = List<Map<String, dynamic>>.from(data['exercises'] ?? const []);
        final savedCircuitIndices = List<int>.from(data['circuitStartIndices'] ?? [0]);

        // Build planned rows (controller-ready maps; no TextEditingController in warmup)
        final rows = <Map<String, dynamic>>[];
        for (var i = 0; i < planned.length; i++) {
          final ex = Map<String, dynamic>.from(planned[i]);
          final name = (ex['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;

          // Determine circuit index (existing or derived)
          final circuitIndex = ex.containsKey('circuitIndex')
              ? (ex['circuitIndex'] ?? 0) as int
              : _getCircuitIndexForRow(i, savedCircuitIndices);

          // Seed a controller-ready row (string fields like UI would display)
          rows.add({
            'exercise': name,
            'circuitIndex': circuitIndex,
            'weight': _restorePlannedWeightDisplay(
              ex: ex,
              exerciseSettings: exerciseSettings,
              plannedDetails: plannedDetails,
              uid: uid,
              name: name,
              asOf: blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex)),
            ),
            'reps': _asNonZeroString(ex['reps']),
            'rir': _asNonZeroString(ex['rir']),
            'velocity': _asNonEmptyString(ex['velocity']),
            'notes': _asNonEmptyString(ex['notes']),
          });
        }

        // recompute circuit starts
        final starts = <int>[];
        int? lastCircuit;
        for (int i = 0; i < rows.length; i++) {
          final c = (rows[i]['circuitIndex'] ?? 0) as int;
          if (i == 0 || c != lastCircuit) {
            starts.add(i);
            lastCircuit = c;
          }
        }

        // Merge WES saved values (doc-id + legacy) for this date
        final date = blockStartDate.add(Duration(days: weekIndex * 7 + dayIndex));
        final dateKey = _ymd(date);

        final mergedSaved = <Map<String, dynamic>>[];
        // doc-id
        final docIdSnap = await workoutsCol.doc(dateKey).get(const GetOptions(source: Source.server));
        if (docIdSnap.exists) {
          mergedSaved.addAll(List<Map<String, dynamic>>.from(docIdSnap.data()?['exercises'] ?? const []));
        }
        // legacy
        final legacy = legacyByDate[dateKey] ?? const [];
        for (final old in legacy) {
          mergedSaved.addAll(List<Map<String, dynamic>>.from(old.data()['exercises'] ?? const []));
        }

        // Apply WES overrides into matching planned rows, BW guard included
        if (mergedSaved.isNotEmpty) {
          for (final ex in mergedSaved) {
            final name = (ex['name'] ?? '').toString();
            final circuit = ex['circuitIndex'] ?? 0;
            final sets = List<Map<String, dynamic>>.from(ex['sets'] ?? const []);
            if (name.trim().isEmpty || sets.isEmpty) continue;

            final idx = rows.indexWhere((r) => r['exercise'] == name && (r['circuitIndex'] ?? 0) == circuit);
            if (idx < 0) continue;

            final r = rows[idx];

            final bool isBw = PeriodizationModelUtils.isBodyweightExercise(name: name);
            final bool isCompleted = (ex['savedAt'] != null) || (ex['status'] == 'completed');

            String v(dynamic s) => s?.toString() ?? '';
            final w = v(sets[0]['weight']);
            final rp = v(sets[0]['reps']);
            final rr = v(sets[0]['rir']);
            final ve = v(sets[0]['velocity']);
            final no = v(sets[0]['notes']);

            // BW-only guard: planned BW should be blank; completed BW shows weight
            r['weight']   = (isBw && !isCompleted) ? '' : w;
            r['reps']     = rp;
            r['rir']      = rr;
            r['velocity'] = ve;
            r['notes']    = no;
          }
        }

        // Prune duplicates where saved exists (same key)
        if (mergedSaved.isNotEmpty) {
          final completedKeys = <String>{};
          for (final ex in mergedSaved) {
            final name = (ex['name'] ?? '').toString();
            final circuit = ex['circuitIndex'] ?? 0;
            if (name.trim().isEmpty) continue;
            completedKeys.add('$name::$circuit');
          }
          // remove planned duplicates
          rows.removeWhere((r) => completedKeys.contains('${r['exercise']}::${r['circuitIndex']}'));
          // recalc circuit headers
          final newStarts = <int>[];
          int? lastC;
          for (int i = 0; i < rows.length; i++) {
            final c = (rows[i]['circuitIndex'] ?? 0) as int;
            if (i == 0 || c != lastC) {
              newStarts.add(i);
              lastC = c;
            }
          }
          circuitStartsByDay[dayIndex] = newStarts;
        } else {
          circuitStartsByDay[dayIndex] = starts;
        }

        parsedByDayIndex[dayIndex] = rows;
      }

      // 4) Compute hints (optional but requested “ready on paint”)
      final hints = <String, dynamic>{
        'ready': true,
        // Keep this open-ended; BB2 can read fields it cares about.
        // You can enrich later without a schema change.
      };

      // 5) Persist the merged day outputs to Isar in a single txn
      final isar = await IsarDb.instance;

      // latest workoutsUpdatedAt for this week (best effort)
      DateTime? workoutsUpdatedAt;
      for (final d in wesServerSnap.docs) {
        final savedAt = _coerceTimestamp(d.data()['savedAt']);
        final updated = d.metadata.isFromCache ? null : DateTime.now(); // fallback
        workoutsUpdatedAt = _maxDt(workoutsUpdatedAt, savedAt ?? updated);
      }

      final inputsHash = _hashInputs(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        blockStartDate: blockStartDate,
        blockEndDate: blockEndDate,
        plannerUpdatedAt: plannerUpdatedAt,
        workoutsUpdatedAt: workoutsUpdatedAt,
      );

      await isar.writeTxn(() async {
        for (final e in parsedByDayIndex.entries) {
          final dayIdx = e.key;
          final rows = e.value;
          final circ = circuitStartsByDay[dayIdx] ?? const [0];

          final doc = BB2MergedDay()
            ..uid = uid
            ..blockId = blockId
            ..weekIndex = weekIndex
            ..dayIndex = dayIdx
            ..id = bb2MergedDayId(uid, blockId, weekIndex, dayIdx)
            ..mergedExercisesJson = jsonEncode(rows)
            ..circuitStartIndicesJson = jsonEncode(circ)
            ..hintsJson = jsonEncode(hints)
            ..plannerUpdatedAt = plannerUpdatedAt
            ..workoutsUpdatedAt = workoutsUpdatedAt
            ..schemaVersion = 1
            ..inputsHash = inputsHash
            ..cachedAt = DateTime.now();

          await isar.bB2MergedDays.put(doc);
        }
      });
      debugPrint('💾 [WarmupBB2:cache-write] week=$weekIndex uid=$uid block=$blockId');


      if (kDebugMode) {
        debugPrint('[WarmupBB2] week_$weekIndex cached for uid=$uid block=$blockId '
            '(plannerUpdatedAt=$plannerUpdatedAt workoutsUpdatedAt=$workoutsUpdatedAt)');
      }
      debugPrint('✅ [WarmupBB2:done] week=$weekIndex uid=$uid block=$blockId');

    } catch (e, st) {
      if (kDebugMode) debugPrint('[WarmupBB2] run failed: $e\n$st');
    }
  }

  // ───────────────────────────────── helpers ─────────────────────────────────

  static Future<String?> _resolveActiveBlockId(String uid) async {
    try {
      final id = await BlockRepository().fetchActiveBlockId(uid);
      if (id != null && id.isNotEmpty) return id;
    } catch (_) {}
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid)
          .collection('block_planner')
          .doc('current_block')
          .get(const GetOptions(source: Source.server));
      return snap.data()?['blockId'] as String?;
    } catch (_) {}
    return null;
  }

  static DateTime _asLocalDate(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  /// Computes display start (first Monday/Sunday depending on your existing logic)
  /// and total weeks. To match BB2 precisely, call the same calculations you use there.
  static (DateTime, DateTime) _displayStartFor(DateTime start, DateTime end) {
    // If BB2 aligns to blockStart exactly, keep it:
    // (If you shift to a specific weekday, mirror that here.)
    return (start, end);
  }

  static int _totalWeeks(DateTime start, DateTime end) {
    final days = end.difference(start).inDays + 1;
    return (days / 7).ceil().clamp(1, 200);
  }

  static int _getCircuitIndexForRow(int rowIdx, List<int> circuitStarts) {
    int current = 0;
    for (final s in circuitStarts) {
      if (rowIdx >= s) current++;
    }
    return (current == 0) ? 0 : current - 1;
  }

  static String _ymd(DateTime d) {
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  static DateTime? _coerceTimestamp(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    final p = DateTime.tryParse(v.toString());
    return p;
  }

  static DateTime? _maxDt(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  static String _asNonZeroString(dynamic v) {
    if (v == null) return '';
    final s = v.toString().trim();
    if (s.isEmpty) return '';
    if (s == '0' || s == '0.0') return '';
    return s;
  }

  static String _asNonEmptyString(dynamic v) {
    if (v == null) return '';
    final s = v.toString().trim();
    return s;
  }

  /// Planned weight “display value” for BB2:
  ///  - For BW exercises: show ADDED weight (computed from absolute if needed), otherwise blank if 0/null.
  ///  - For non-BW: show absolute numeric if nonzero.
  static String _restorePlannedWeightDisplay({
    required Map<String, dynamic> ex,
    required Map<String, Map<String, dynamic>> exerciseSettings,
    required Map<String, Map<String, dynamic>> plannedDetails,
    required String uid,
    required String name,
    required DateTime asOf,
  }) {
    final rawWeight = ex['weight'];
    final weightVal = rawWeight != null ? double.tryParse(rawWeight.toString()) : null;

    final exId = PeriodizationModelUtils.nameToId[name] ?? name;
    final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: name);

    if (isBw) {
      final num? awRaw = (ex['addedWeight'] as num?) ?? (ex['weightAdded'] as num?);
      double? displayAdded;
      if (awRaw != null) {
        displayAdded = awRaw.toDouble();
      } else if (weightVal != null && weightVal != 0.0) {
        displayAdded = PeriodizationModelUtils.toDisplayAddedWeight(
          uid: uid,
          absoluteKg: weightVal,
          exerciseId: exId,
          exerciseName: name,
          asOfDate: asOf,
        );
      }
      return (displayAdded == null) ? '' : displayAdded.toString();
    } else {
      if (weightVal != null && weightVal != 0.0) return '$weightVal';
      return '';
    }
  }

  static String _hashInputs({
    required String uid,
    required String blockId,
    required int weekIndex,
    required DateTime blockStartDate,
    required DateTime blockEndDate,
    required DateTime? plannerUpdatedAt,
    required DateTime? workoutsUpdatedAt,
  }) {
    final s = [
      uid, blockId, weekIndex,
      blockStartDate.millisecondsSinceEpoch,
      blockEndDate.millisecondsSinceEpoch,
      plannerUpdatedAt?.millisecondsSinceEpoch ?? 0,
      workoutsUpdatedAt?.millisecondsSinceEpoch ?? 0,
      1, // schemaVersion
    ].join('|');

    int hash = 0xcbf29ce484222325;
    for (final c in s.codeUnits) {
      hash ^= c;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return '$hash';
  }
}
