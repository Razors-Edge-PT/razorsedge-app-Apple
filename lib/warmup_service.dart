// warmup_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'periodization_model_utils.dart';
import 'dart:convert';   // for jsonEncode / jsonDecode
import 'dart:async' show unawaited; // if you use unawaited() here


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
    final athFresh = lastAth != null && (now - lastAth) < _cooldown.inMilliseconds;
    if (!athFresh) await prefs.setInt(keyAth, now);

    // Global cooldown for static exercises
    final keyEx = 'wes_warm_exercises_last';
    final lastEx = prefs.getInt(keyEx);
    final exFresh = lastEx != null && (now - lastEx) < _cooldown.inMilliseconds;
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

  Future<void> doWarmWES(
      String uid, {
        String? activeBlockId,
        DateTime? selectedDate,
        bool warmAthlete = true,
        bool warmExercises = true,
      }) async {
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
        final isoUtc = DateTime.utc(startOfDay.year, startOfDay.month, startOfDay.day).toIso8601String();

        // New-style doc by ID
        unawaited(workouts.doc(dateOnly).get(const GetOptions(source: Source.server)));

        // Legacy string equals (3 forms)
        unawaited(workouts.where('date', isEqualTo: isoLocal).get(const GetOptions(source: Source.server)));
        unawaited(workouts.where('date', isEqualTo: isoUtc).get(const GetOptions(source: Source.server)));
        unawaited(workouts.where('date', isEqualTo: dateOnly).get(const GetOptions(source: Source.server)));

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
          if (selectedDate != null) DateTime(selectedDate.year, selectedDate.month, selectedDate.day),
        ];

        // Warm yesterday/today/tomorrow (+ selectedDate if provided), across legacy/new shapes
        for (final d in days) {
          _warmWorkoutShapesForDate(d);
        }

        // Warm recent workouts LIST
        unawaited(
          fs
              .collection('users').doc(uid)
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
          } catch (_) { /* cache miss is fine */ }

          // 2) If cache empty, hit server
          if (workouts.isEmpty) {
            final server = await col.get(); // server
            workouts = server.docs.map((d) => d.data()).toList();
          }

          // 3) Assign to PMU so rep indexing & progression models see history now
          PeriodizationModelUtils.savedWorkoutsList =
          List<Map<String, dynamic>>.from(workouts);
          print('📦 [Warmup→PMU] seeded savedWorkoutsList count=${workouts.length}');
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
      final blocksCol = fs.collection('planned_blocks').doc(uid).collection('blocks');
      final blocksSnap = await blocksCol.limit(5).get(const GetOptions(source: Source.server));
      for (final b in blocksSnap.docs) {
        unawaited(blocksCol.doc(b.id).get(const GetOptions(source: Source.server)));
      }

      // ✅ Explicitly warm the active block doc used by WES
      if (activeBlockId != null && activeBlockId.isNotEmpty) {
        unawaited(blocksCol.doc(activeBlockId).get(const GetOptions(source: Source.server)));
      }

      if (activeBlockId != null && activeBlockId.isNotEmpty) {
        // If caller didn't pass a date, default to "today" (date-only)
        final d = (selectedDate != null)
            ? DateTime(selectedDate.year, selectedDate.month, selectedDate.day)
            : DateTime.now();

      }

      // ─────────────────────────────────────────────────────────────
      // SNAPSHOT ASSEMBLY: planned ∪ wesPlanned ∪ previous + hints
      // ─────────────────────────────────────────────────────────────
      try {
        if (activeBlockId == null || activeBlockId.isEmpty) return;
        final DateTime d0 = (selectedDate != null)
            ? DateTime(selectedDate.year, selectedDate.month, selectedDate.day)
            : DateTime.now();

        String _ymd(DateTime dt) =>
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        final dateYmd = _ymd(d0);

        // 1) Resolve week/day for the active block (best-effort)
        DateTime? blockStart;
        try {
          final bDoc = await FirebaseFirestore.instance
              .collection('planned_blocks').doc(uid)
              .collection('blocks').doc(activeBlockId)
              .get(const GetOptions(source: Source.server));
          final s = (bDoc.data()?['startDate'] ?? bDoc.data()?['blockStartDate'])?.toString();
          if (s != null) {
            final dt = DateTime.tryParse(s);
            if (dt != null) {
              blockStart = DateTime(dt.year, dt.month, dt.day);
            }
          }
        } catch (_) {/* best-effort */}

        int? weekIndex;
        int? dayIndex;
        if (blockStart != null) {
          final days = d0.difference(blockStart).inDays;
          if (days >= 0) {
            weekIndex = (days / 7).floor();
            dayIndex  = days % 7;
          }
        }

        // 2) Planned BB2 exercises (ISAR → cache → server; fallback block_data)
        List<Map<String, dynamic>> planned = const [];
        if (weekIndex != null && dayIndex != null) {
          try {
            final isarDay = await BlockPlanCache.getDay(
              uid: uid,
              blockId: activeBlockId,
              weekIndex: weekIndex,
              dayIndex: dayIndex,
            );
            if (isarDay != null && isarDay.isNotEmpty) {
              planned = isarDay.map((e) => {
                'name': (e['name'] ?? '').toString().trim(),
                'circuitIndex': (e['circuitIndex'] ?? 0) as int,
              }).where((m) => (m['name'] as String).isNotEmpty).toList();
            }
          } catch (_) {}
        }

        // Firestore cache/server day doc
        if (planned.isEmpty && weekIndex != null && dayIndex != null) {
          final dayDocRef = FirebaseFirestore.instance
              .collection('planned_blocks').doc(uid)
              .collection('blocks').doc(activeBlockId)
              .collection('weeks').doc('week_$weekIndex')
              .collection('days').doc('day_$dayIndex');

          try {
            final c = await dayDocRef.get(const GetOptions(source: Source.cache));
            if (c.exists && (c.data()?['exercises'] is List)) {
              final L = List<Map<String, dynamic>>.from(c.data()!['exercises']);
              planned = L.map((e) => {
                'name': (e['name'] ?? '').toString().trim(),
                'circuitIndex': (e['circuitIndex'] ?? 0) as int,
              }).where((m) => (m['name'] as String).isNotEmpty).toList();
            }
          } catch (_) {}
          if (planned.isEmpty) {
            try {
              final s = await dayDocRef.get(const GetOptions(source: Source.server));
              if (s.exists && (s.data()?['exercises'] is List)) {
                final L = List<Map<String, dynamic>>.from(s.data()!['exercises']);
                planned = L.map((e) => {
                  'name': (e['name'] ?? '').toString().trim(),
                  'circuitIndex': (e['circuitIndex'] ?? 0) as int,
                }).where((m) => (m['name'] as String).isNotEmpty).toList();
                // refresh ISAR day for next time
                unawaited(BlockPlanCache.putDay(
                  uid: uid, blockId: activeBlockId,
                  weekIndex: weekIndex!, dayIndex: dayIndex!, exercises: L,
                ));
              }
            } catch (_) {}
          }
        }

        // Fallback: block_data/{yyyy-MM-dd}
        if (planned.isEmpty) {
          try {
            final ref = FirebaseFirestore.instance
                .collection('planned_blocks').doc(uid)
                .collection('blocks').doc(activeBlockId)
                .collection('block_data').doc(dateYmd);

            final c = await ref.get(const GetOptions(source: Source.cache));
            if (c.exists && (c.data()?['rows'] is List)) {
              final L = List<Map<String, dynamic>>.from(c.data()!['rows']);
              planned = L.map((e) => {
                'name': (e['name'] ?? '').toString().trim(),
                'circuitIndex': (e['circuitIndex'] ?? 0) as int,
              }).where((m) => (m['name'] as String).isNotEmpty).toList();
            }
            if (planned.isEmpty) {
              final s = await ref.get(const GetOptions(source: Source.server));
              if (s.exists && (s.data()?['rows'] is List)) {
                final L = List<Map<String, dynamic>>.from(s.data()!['rows']);
                planned = L.map((e) => {
                  'name': (e['name'] ?? '').toString().trim(),
                  'circuitIndex': (e['circuitIndex'] ?? 0) as int,
                }).where((m) => (m['name'] as String).isNotEmpty).toList();
              }
            }
          } catch (_) {}
        }

        // 3) wesPlanned (placeholders saved by WES)
        List<Map<String, dynamic>> wesPlanned = const [];
        try {
          final wdoc = await FirebaseFirestore.instance
              .collection('users').doc(uid)
              .collection('workouts').doc(dateYmd)
              .get(const GetOptions(source: Source.cache));
          if (wdoc.exists && (wdoc.data()?['wesPlannedExercises'] is List)) {
            wesPlanned = List<Map<String, dynamic>>.from(wdoc.data()!['wesPlannedExercises']);
          }
        } catch (_) {}
        if (wesPlanned.isEmpty) {
          try {
            final wdoc = await FirebaseFirestore.instance
                .collection('users').doc(uid)
                .collection('workouts').doc(dateYmd)
                .get(const GetOptions(source: Source.server));
            if (wdoc.exists && (wdoc.data()?['wesPlannedExercises'] is List)) {
              wesPlanned = List<Map<String, dynamic>>.from(wdoc.data()!['wesPlannedExercises']);
            }
          } catch (_) {}
        }

        // 4) previousWorkout union for this date (new-style + legacy)
        List<Map<String, dynamic>> previous = const [];
        try {
          final col = FirebaseFirestore.instance
              .collection('users').doc(uid).collection('workouts');
          final startOfDay = DateTime(d0.year, d0.month, d0.day);
          final nextDay = startOfDay.add(const Duration(days: 1));
          final isoLocal = startOfDay.toIso8601String();
          final isoUtc = DateTime.utc(startOfDay.year, startOfDay.month, startOfDay.day).toIso8601String();
          final dateOnly = dateYmd;
          final nextDateOnly = _ymd(nextDay);

          List<Map<String, dynamic>> _exFrom(DocumentSnapshot<Map<String, dynamic>>? d) {
            if (d == null || !d.exists) return const [];
            final raw = (d.data()?['exercises'] as List?) ?? const [];
            return raw.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
          }

          DocumentSnapshot<Map<String, dynamic>>? ndCache;
          try { ndCache = await col.doc(dateYmd).get(const GetOptions(source: Source.cache)); } catch(_) {}
          final candidates = <Map<String, dynamic>>[];
          if (ndCache != null) candidates.addAll(_exFrom(ndCache));
          // legacy cache
          try {
            final snaps = await Future.wait([
              col.where('date', isEqualTo: isoLocal).get(const GetOptions(source: Source.cache)),
              col.where('date', isEqualTo: isoUtc).get(const GetOptions(source: Source.cache)),
              col.where('date', isEqualTo: dateOnly).get(const GetOptions(source: Source.cache)),
              col.where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
                  .where('date', isLessThan: '${nextDateOnly}T00:00:00')
                  .get(const GetOptions(source: Source.cache)),
              col.where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                  .where('date', isLessThan: Timestamp.fromDate(nextDay))
                  .get(const GetOptions(source: Source.cache)),
            ]);
            for (final s in snaps) {
              for (final d in s.docs) {
                candidates.addAll(_exFrom(d));
              }
            }
          } catch (_) {}
          if (candidates.isEmpty) {
            // server union (best-effort)
            try {
              final nd = await col.doc(dateYmd).get(const GetOptions(source: Source.server));
              candidates.addAll(_exFrom(nd));
              final snaps = await Future.wait([
                col.where('date', isEqualTo: isoLocal).get(const GetOptions(source: Source.server)),
                col.where('date', isEqualTo: isoUtc).get(const GetOptions(source: Source.server)),
                col.where('date', isEqualTo: dateOnly).get(const GetOptions(source: Source.server)),
                col.where('date', isGreaterThanOrEqualTo: '${dateOnly}T00:00:00')
                    .where('date', isLessThan: '${nextDateOnly}T00:00:00')
                    .get(const GetOptions(source: Source.server)),
                col.where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                    .where('date', isLessThan: Timestamp.fromDate(nextDay))
                    .get(const GetOptions(source: Source.server)),
              ]);
              for (final s in snaps) {
                for (final d in s.docs) {
                  candidates.addAll(_exFrom(d));
                }
              }
            } catch (_) {}
          }
          previous = candidates;
        } catch (_) {}

        // 5) Top-set history seed (last 30 days) for hint calc
        try {
          if (PeriodizationModelUtils.topSetsByExercise.isEmpty) {
            await PeriodizationModelUtils.fetchFullTopSetHistory(uid: uid);
          }
        } catch (_) {}

        // 6) Build unified rows (wesPlanned ∪ planned), dedup by name|ci
        String _k(String n, int ci) => '${n.trim().toLowerCase()}|$ci';
        final Map<String, Map<String, dynamic>> rowsByKey = {};
        for (final p in planned) {
          final n = (p['name'] ?? '').toString().trim();
          if (n.isEmpty) continue;
          final ci = (p['circuitIndex'] ?? 0) as int;
          rowsByKey[_k(n, ci)] = {'name': n, 'circuitIndex': ci};
        }
        for (final w in wesPlanned) {
          final n = (w['name'] ?? '').toString().trim();
          if (n.isEmpty) continue;
          final ci = (w['circuitIndex'] is int)
              ? w['circuitIndex'] as int
              : int.tryParse('${w['circuitIndex'] ?? 0}') ?? 0;
          rowsByKey.putIfAbsent(_k(n, ci), () => {'name': n, 'circuitIndex': ci});
        }
        final rows = rowsByKey.values.toList();

        // 7) Compute S1 hints (final targets) using PMU + BW converters.
        //    We keep it minimal: produce reps/rir/weight (display) and absWeight.
        List<Map<String, dynamic>> hintList = [];
        for (final r in rows) {
          final name = (r['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          final ci   = (r['circuitIndex'] ?? 0) as int;
          final exId = PeriodizationModelUtils.nameToId[name] ?? name;
          final isBw = PeriodizationModelUtils.isBodyweightExercise(id: exId, name: name);

          // Rep target (simple PMU rule; your WES does more—we can expand later if needed)
          final weekIdx = (blockStart == null) ? 0
              : PeriodizationModelUtils.getWeekIndexForDate(d0, blockStart);
          final rir1 = 1.0; // conservative default; WES UI will show hint text, user can override
          final repTarget = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exId,
            plannedIndex: 0,
            weightText: '',
            rirText: '',
            weekIndex: weekIdx,
          ).toDouble();

          // Default weight guess from reps (progression model helpers)
          final defW = PeriodizationModelUtils.getSuggestedWeightFromRep(name, repTarget.toInt(), rir1);

          // Snap to increments if available
          final incMap = PeriodizationModelUtils.incMapFromRaw(
              PeriodizationModelUtils.plannedExerciseDetails[exId]?['increments'] ??
                  PeriodizationModelUtils.plannedExerciseDetails[name]?['increments']);
          final incs = PeriodizationModelUtils.expandIncrementOptions(incMap) ?? <double>[2.5];

          double absWeight = defW;
          if (incs.isNotEmpty) {
            absWeight = incs.reduce((a,b) => (a - defW).abs() < (b - defW).abs() ? a : b);
          }

          double? displayWeight;
          if (isBw) {
            displayWeight = PeriodizationModelUtils.toDisplayAddedWeight(
              uid: uid,
              absoluteKg: absWeight,
              exerciseId: exId,
              exerciseName: name,
              asOfDate: d0,
            );
            if (displayWeight != null && displayWeight < 0) displayWeight = 0;
          } else {
            displayWeight = absWeight;
          }

          hintList.add({
            'name': name,
            'circuitIndex': ci,
            'reps': repTarget,
            'rir': rir1,
            'weight': displayWeight,   // display domain (added for BW)
            'absWeight': absWeight,    // absolute
          });
        }

        // 8) Hash the inputs that influence S1 (simple, stable)
        String _hash() {
          final bodyweight = PeriodizationModelUtils.bodyweightKgForDate(uid: uid, asOf: d0);
          final exKeys = rows.map((e) => '${(PeriodizationModelUtils.nameToId[(e['name'] ?? '').toString()] ?? (e['name'] ?? '')).toString()}|${e['circuitIndex'] ?? 0}').toList()..sort();
          final version = 1; // bump if hint logic changes
          final payload = {
            'uid': uid,
            'blockId': activeBlockId,
            'date': dateYmd,
            'weekIdx': weekIndex ?? 0,
            'exKeys': exKeys,
            'bw': bodyweight.round(),
            'v': version,
          };
          return payload.toString().hashCode.toString();
        }

        final hintsJson = jsonEncode(hintList);
        final hintsHash = _hash();
        const schemaVersion = 2; // ← bump since we added wesPlannedExercisesJson

        await BlockPlanCache.putInitSnapshot(
          uid: uid,
          blockId: activeBlockId,
          dateYmd: dateYmd,
          plannedExercises: planned,
          wesPlannedExercises: wesPlanned,           // ← NEW
          previousWorkout: previous,
          topSetHistory: const <Map<String, dynamic>>[], // optional: include if you want
          hintsJson: hintsJson,
          hintsInputsHash: hintsHash,
          hintsReady: true,
          schemaVersion: schemaVersion,
          updatedAt: DateTime.now(),
        );

        print('🟩 [Warmup] snapshot PUT uid=$uid block=$activeBlockId date=$dateYmd '
            'planned=${planned.length} wesPlanned=${wesPlanned.length} prev=${previous.length} '
            'hints=${hintList.length} hash=$hintsHash');
      } catch (e) {
        print('🟥 [Warmup] snapshot assembly failed: $e');
      }

    } catch (_) {
      // best-effort
    }
  }

}
