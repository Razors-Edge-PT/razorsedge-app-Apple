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

      // ───────────────────────────────────────────────────────────────
      // NEW: Precompute & persist a WESInitSnapshot in Isar so WES
      // first-frame paint can use it even on cold boot/offline.
      // ───────────────────────────────────────────────────────────────
      if (activeBlockId != null && activeBlockId.isNotEmpty) {
        // If caller didn't pass a date, default to "today" (date-only)
        final d = (selectedDate != null)
            ? DateTime(selectedDate.year, selectedDate.month, selectedDate.day)
            : DateTime.now();
        unawaited(_precomputeWesInitSnapshotIfPossible(uid: uid, blockId: activeBlockId, date: d));
      }
    } catch (_) {
      // best-effort
    }
  }




  // ───────────────────────────────────────────────────────────────
// ───────────────────────────────────────────────────────────────
// Helper: build and persist a minimal WESInitSnapshot
//  • plannedExercisesJson: name + circuitIndex (from BB2 plan or fallbacks)
//  • previousWorkoutJson : rows with sets (from workout doc fallbacks)
// ───────────────────────────────────────────────────────────────
  Future<void> _precomputeWesInitSnapshotIfPossible({
    required String uid,
    required String blockId,
    required DateTime date,
  }) async {
    try {
      final fs = FirebaseFirestore.instance;

      // Date keys
      final d = DateTime(date.year, date.month, date.day);
      String ymd(DateTime dt) {
        final m = dt.month.toString().padLeft(2, '0');
        final dd = dt.day.toString().padLeft(2, '0');
        return '${dt.year}-$m-$dd';
      }
      final dateKey = ymd(d);
      final nextDateKey = ymd(d.add(const Duration(days: 1)));

      // 0) If a non-empty snapshot already exists, do not clobber it.
      try {
        final existing = await BlockPlanCache.getInitSnapshot(
          uid: uid, blockId: blockId, dateYmd: dateKey,
        );
        if (existing != null &&
            existing.plannedExercisesJson.isNotEmpty &&
            existing.plannedExercisesJson != '[]') {
          // We already have planned rows; keep as-is. (We could merge prev later if needed.)
          print('🟢 [Warmup] Snapshot exists for $dateKey (uid=$uid, block=$blockId) — skip recompute');

          return;
        }
      } catch (_) {/* ignore */}

      // Accumulators
      List<Map<String, dynamic>> plannedCompact = [];
      List<Map<String, dynamic>> previousOverlay = [];

      // 1) Read block start date to compute week/day
      DateTime? blockStart;
      try {
        final blk = await fs
            .collection('planned_blocks').doc(uid)
            .collection('blocks').doc(blockId)
            .get(const GetOptions(source: Source.server));
        final data = blk.data() ?? const {};
        final tsStart = data['startDate'] as Timestamp?;
        blockStart = tsStart?.toDate();
      } catch (_) {/* ignore */}

      if (blockStart != null) {
        final startOnly = DateTime(blockStart.year, blockStart.month, blockStart.day);
        final daysSince = d.difference(startOnly).inDays;
        if (daysSince >= 0) {
          final wi = daysSince ~/ 7;
          final di = daysSince % 7;

          // 2) Primary planned: weeks/week_{wi}/days/day_{di}.exercises
          try {
            final dayRef = fs
                .collection('planned_blocks').doc(uid)
                .collection('blocks').doc(blockId)
                .collection('weeks').doc('week_$wi')
                .collection('days').doc('day_$di');

            DocumentSnapshot<Map<String, dynamic>> dayDoc;
            try {
              dayDoc = await dayRef.get(const GetOptions(source: Source.server));
            } catch (_) {
              dayDoc = await dayRef.get();
            }

            final rows = (dayDoc.data()?['exercises'] as List?) ?? const [];
            plannedCompact.addAll(rows.whereType<Map>().map((m0) {
              final m = Map<String, dynamic>.from(m0);
              final name = (m['name'] ?? '').toString().trim();
              final ci = (m['circuitIndex'] is int)
                  ? m['circuitIndex'] as int
                  : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;
              return name.isEmpty ? null : {'name': name, 'circuitIndex': ci};
            }).whereType<Map<String, dynamic>>());
          } catch (_) {/* ignore */}

          // 3) Fallback planned: block_data/{yyyy-mm-dd}.rows
          if (plannedCompact.isEmpty) {
            try {
              final fb = await fs
                  .collection('planned_blocks').doc(uid)
                  .collection('blocks').doc(blockId)
                  .collection('block_data').doc(dateKey)
                  .get(const GetOptions(source: Source.server));
              final rows = (fb.data()?['rows'] as List?) ?? const [];
              plannedCompact.addAll(rows.whereType<Map>().map((m0) {
                final m = Map<String, dynamic>.from(m0);
                final name = (m['name'] ?? '').toString().trim();
                final ci = (m['circuitIndex'] is int)
                    ? m['circuitIndex'] as int
                    : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;
                return name.isEmpty ? null : {'name': name, 'circuitIndex': ci};
              }).whereType<Map<String, dynamic>>());
            } catch (_) {/* ignore */}
          }
        }
      }

      // 4) Workout doc fallbacks (populate both planned & previous)
      //    Order: wesPlannedExercises[] (planned) → exercises[] (previous)
      try {
        final workoutDoc = await fs
            .collection('users').doc(uid)
            .collection('workouts').doc(dateKey)
            .get(const GetOptions(source: Source.server));

        final data = workoutDoc.data();
        if (data != null) {
          // a) planned from wesPlannedExercises if still empty
          if (plannedCompact.isEmpty) {
            final wesPlanned = (data['wesPlannedExercises'] as List?) ?? const [];
            if (wesPlanned.isNotEmpty) {
              plannedCompact.addAll(wesPlanned.whereType<Map>().map((m0) {
                final m = Map<String, dynamic>.from(m0);
                final name = (m['name'] ?? '').toString().trim();
                final ci = (m['circuitIndex'] is int)
                    ? m['circuitIndex'] as int
                    : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;
                return name.isEmpty ? null : {'name': name, 'circuitIndex': ci};
              }).whereType<Map<String, dynamic>>());
            }
          }

          // b) previous overlay from exercises[]
          final exList = (data['exercises'] as List?) ?? const [];
          if (exList.isNotEmpty) {
            previousOverlay.addAll(exList.whereType<Map>().map((m0) {
              final m = Map<String, dynamic>.from(m0);
              final name = (m['name'] ?? '').toString().trim();
              final ci = (m['circuitIndex'] is int)
                  ? m['circuitIndex'] as int
                  : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;

              // Normalize sets
              final setsRaw = (m['sets'] as List?) ?? const [];
              final sets = setsRaw.whereType<Map>().map((s0) {
                final s = Map<String, dynamic>.from(s0);
                Map<String, dynamic> out = {};
                if (s['reps'] != null) out['reps'] = s['reps'];
                if (s['weight'] != null) out['weight'] = s['weight'];
                if (s['addedWeight'] != null) out['addedWeight'] = s['addedWeight'];
                if (s['weightAdded'] != null) out['weightAdded'] = s['weightAdded']; // legacy
                if (s['rir'] != null) out['rir'] = s['rir'];
                if (s['velocity'] != null) out['velocity'] = s['velocity'];
                if ((s['notes'] ?? '').toString().trim().isNotEmpty) out['notes'] = s['notes'];
                return out;
              }).toList();

              return name.isEmpty
                  ? null
                  : {
                'name': name,
                'circuitIndex': ci,
                'sets': sets,
              };
            }).whereType<Map<String, dynamic>>());
          }
        }
      } catch (_) {/* ignore */}

      // 5) Legacy workout queries → previous only (don’t invent planned)
      if (previousOverlay.isEmpty) {
        try {
          final workouts = fs.collection('users').doc(uid).collection('workouts');
          final startOfDay = DateTime(d.year, d.month, d.day);
          final nextDay = startOfDay.add(const Duration(days: 1));
          final isoLocal = startOfDay.toIso8601String();
          final isoUtc = DateTime.utc(startOfDay.year, startOfDay.month, startOfDay.day).toIso8601String();

          Future<QuerySnapshot<Map<String, dynamic>>> qEq(String v) =>
              workouts.where('date', isEqualTo: v).get(const GetOptions(source: Source.server));
          final snaps = await Future.wait([
            qEq(isoLocal),
            qEq(isoUtc),
            qEq(dateKey),
            // FIXED: upper bound should be next day 00:00:00, not T24:00:00
            workouts
                .where('date', isGreaterThanOrEqualTo: '${dateKey}T00:00:00')
                .where('date', isLessThan: '${nextDateKey}T00:00:00')
                .get(const GetOptions(source: Source.server)),
            workouts
                .where('date', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay))
                .where('date', isLessThan: Timestamp.fromDate(nextDay))
                .get(const GetOptions(source: Source.server)),
          ]);

          final Map<String, DocumentSnapshot<Map<String, dynamic>>> byId = {};
          for (final s in snaps) {
            for (final dd in s.docs) byId[dd.id] = dd;
          }
          for (final dd in byId.values) {
            final data = dd.data();
            if (data == null) continue;
            final exList = (data['exercises'] as List?) ?? const [];
            previousOverlay.addAll(exList.whereType<Map>().map((m0) {
              final m = Map<String, dynamic>.from(m0);
              final name = (m['name'] ?? '').toString().trim();
              final ci = (m['circuitIndex'] is int)
                  ? m['circuitIndex'] as int
                  : int.tryParse('${m['circuitIndex'] ?? 0}') ?? 0;
              final setsRaw = (m['sets'] as List?) ?? const [];
              final sets = setsRaw.whereType<Map>().map((s0) {
                final s = Map<String, dynamic>.from(s0);
                Map<String, dynamic> out = {};
                if (s['reps'] != null) out['reps'] = s['reps'];
                if (s['weight'] != null) out['weight'] = s['weight'];
                if (s['addedWeight'] != null) out['addedWeight'] = s['addedWeight'];
                if (s['weightAdded'] != null) out['weightAdded'] = s['weightAdded'];
                if (s['rir'] != null) out['rir'] = s['rir'];
                if (s['velocity'] != null) out['velocity'] = s['velocity'];
                if ((s['notes'] ?? '').toString().trim().isNotEmpty) out['notes'] = s['notes'];
                return out;
              }).toList();

              return name.isEmpty
                  ? null
                  : {
                'name': name,
                'circuitIndex': ci,
                'sets': sets,
              };
            }).whereType<Map<String, dynamic>>());
          }
        } catch (_) {/* ignore */}
      }

      // 6) Build planned from previous if still empty (names only)
      if (plannedCompact.isEmpty && previousOverlay.isNotEmpty) {
        final seen = <String>{};
        plannedCompact = [
          for (final r in previousOverlay)
            if (seen.add('${(r['name'] ?? '').toString().trim().toLowerCase()}|${r['circuitIndex'] ?? 0}'))
              {'name': (r['name'] ?? '').toString().trim(), 'circuitIndex': (r['circuitIndex'] ?? 0)}
        ];
      }

      // 7) Dedup planned & previous by name|ci
      if (plannedCompact.isNotEmpty) {
        final seen = <String>{};
        plannedCompact = [
          for (final m in plannedCompact)
            if (seen.add('${(m['name'] ?? '').toString().trim().toLowerCase()}|${m['circuitIndex'] ?? 0}')) m,
        ];
      }
      if (previousOverlay.isNotEmpty) {
        final seen = <String>{};
        previousOverlay = [
          for (final m in previousOverlay)
            if (seen.add('${(m['name'] ?? '').toString().trim().toLowerCase()}|${m['circuitIndex'] ?? 0}')) m,
        ];
      }

      // 8) Build hintsJson (final-quality targets) before writing snapshot.
//    Only if we have planned rows; otherwise leave it empty.
      String hintsJson = '[]';
      try {
        if (plannedCompact.isNotEmpty) {
          // Safely compute week index (fallback to 0 if blockStart is null)
          final int wi = (blockStart != null)
              ? PeriodizationModelUtils.getWeekIndexForDate(
            d,
            DateTime(blockStart!.year, blockStart!.month, blockStart!.day),
          )
              : 0;

          final List<Map<String, dynamic>> hints = [];
          for (final row in plannedCompact) {
            final name = (row['name'] ?? '').toString().trim();
            final ci   = (row['circuitIndex'] ?? 0) as int;
            if (name.isEmpty) continue;

            // Ask PMU for this exercise's rep target for the week.
            // NOTE: Signature expects exerciseName + weekIndex.
            int? repTarget;
            try {
              final rt = PeriodizationModelUtils.getSuggestedRepTargetByModel(
                exerciseName: name,
                plannedIndex: 0,      // 👈 required
                weekIndex: wi,        // 👈 optional but you already have it
                blockStartDate: blockStart,
                selectedDate: d,
                plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
              );

              repTarget = rt; // already an int
            } catch (_) {
              // best-effort
            }


            hints.add({
              'name': name,
              'circuitIndex': ci,
              if (repTarget != null) 'reps': repTarget,
              // leave weight/absWeight/rir empty; WES will compute/overlay on boot
            });
          }

          hintsJson = jsonEncode(hints);
        }
      } catch (_) {
        // best-effort
        hintsJson = '[]';
      }

// 9) Write snapshot only if we have *something*
      if (plannedCompact.isEmpty && previousOverlay.isEmpty) {
        return; // Don't write "[]"
      }

      await BlockPlanCache.putInitSnapshot(
        uid: uid,
        blockId: blockId,
        dateYmd: dateKey,
        plannedExercises: plannedCompact,
        previousWorkout: previousOverlay,
        topSetHistory: const <Map<String, dynamic>>[],
        hintsJson: hintsJson, // 👈 make sure your putInitSnapshot accepts this
        updatedAt: DateTime.now(),
      );
      print('🟢 [Warmup] Snapshot PUT $dateKey planned=${plannedCompact.length} prev=${previousOverlay.length} hintsLen=${hintsJson.length}');



      // (Optional) debug:
      // print('🟢 [Warmup] Snapshot PUT $dateKey planned=${plannedCompact.length} prev=${previousOverlay.length}');
    } catch (_) {
      // best-effort
    }
  }



}
