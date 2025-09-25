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

  // ───────────────────────────────────────────────────────────────
  // Helper: ensure PeriodizationModelUtils.nameToId has an entry for `name`.
  // Returns the resolved exerciseId (or `name` as a last-resort fallback).
  // ───────────────────────────────────────────────────────────────
  Future<String> _ensureNameToIdFor(
      FirebaseFirestore fs, {
        required String name,
      }) async {
    final n = name.trim();
    if (n.isEmpty) return n;

    // Fast path: already known
    final hit = PeriodizationModelUtils.nameToId[n];
    if (hit != null && hit.isNotEmpty) return hit;

    // 1) Try exact match (server)
    try {
      final q = await fs
          .collection('exercises')
          .where('name', isEqualTo: n)
          .limit(1)
          .get(const GetOptions(source: Source.server));
      if (q.docs.isNotEmpty) {
        final id = q.docs.first.id;
        PeriodizationModelUtils.nameToId[n] = id;
        // diag
        print('🧭 [Warmup NameToId] mapped "$n" → $id (exact)');
        return id;
      }
    } catch (_) {}

    // 2) If the global map is still cold, hydrate a small page to fill it
    //    This also helps future lookups in the same warmup pass.
    try {
      final snap = await fs
          .collection('exercises')
          .orderBy('name')
          .limit(250)
          .get(const GetOptions(source: Source.server));
      for (final d in snap.docs) {
        final dn = (d.data()['name'] ?? '').toString().trim();
        if (dn.isNotEmpty) {
          PeriodizationModelUtils.nameToId[dn] = d.id;
        }
      }
      final id2 = PeriodizationModelUtils.nameToId[n];
      if (id2 != null && id2.isNotEmpty) {
        print('🧭 [Warmup NameToId] mapped "$n" → $id2 (paged warm)');
        return id2;
      }
    } catch (_) {}

    // 3) Last resort: fallback to using the name itself as ID (keeps flow alive)
    print('⚪ [Warmup NameToId] fallback for "$n" → "$n" (no match)');
    return n;
  }

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

      try {
        final existing = await BlockPlanCache.getInitSnapshot(
          uid: uid, blockId: blockId, dateYmd: dateKey,
        );

        // Build current hash for freshness
        final wk = (/* if you have blockStart here, compute week; else */ 0);
        final bw = PeriodizationModelUtils.bodyweightKgForDate(uid: uid, asOf: d);
        final lastW = wesMaxWorkoutDate(PeriodizationModelUtils.savedWorkoutsList);
        final lastT = wesMaxTopSetDate(PeriodizationModelUtils.topSetsByExercise);

        final plannedForHash = <Map<String,dynamic>>[]; // (optional) fill if easy

        final nowHash = WesHintInputsPayload(
          uid: uid,
          blockId: blockId,
          dateYmd: dateKey,
          weekIndex: wk,
          plannedExercises: plannedForHash,
          plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
          exerciseSettings: PeriodizationModelUtils.getExerciseSettings(),
          bodyweightAsOfDay: bw,
          lastWorkoutDate: lastW,
          lastTopSetDate: lastT,
        ).hash();

        final canSkip = (existing != null)
            && (existing.schemaVersion != null && existing.schemaVersion! >= kWesSnapshotSchema)
            && (existing.hintsReady == true)
            && (existing.hintsInputsHash == nowHash)
            && (existing.hintsJson.isNotEmpty && existing.hintsJson != '{}');

        if (canSkip) {
          print('🟢 [Warmup] Skip recompute → ready hints (sv=${existing!.schemaVersion}) hash=match');
          return;
        } else if (existing != null) {
          print('🟠 [Warmup] Recompute (sv=${existing.schemaVersion}, ready=${existing.hintsReady}, '
              'snapHash=${existing.hintsInputsHash}, nowHash=$nowHash)');
        }
      } catch (_) {/* ignore */}


      // Accumulators
      List<Map<String, dynamic>> plannedCompact = [];
      List<Map<String, dynamic>> previousOverlay = [];

      // 1) Read block start/end date to compute week/day
      DateTime? blockStart;
      DateTime? blockEnd;
      Map<String, dynamic> blockData = const {};   // 👈 hoisted so available later
      try {
        final blk = await fs
            .collection('planned_blocks').doc(uid)
            .collection('blocks').doc(blockId)
            .get(const GetOptions(source: Source.server));
        blockData = blk.data() ?? const {};

        // ── STEP 1: Prime PMU with exercise details ────────────────
        final rawDetails = (blockData['plannedExerciseDetails'] as Map?) ?? const {};
        final rawSettings = (blockData['exerciseSettings'] as Map?) ?? const {};

// Normalize to <String, Map<String,dynamic>>
        final details = <String, Map<String, dynamic>>{
          for (final e in rawDetails.entries)
            e.key.toString(): Map<String, dynamic>.from(e.value as Map),
        };

        final settings = <String, Map<String, dynamic>>{
          for (final e in rawSettings.entries)
            e.key.toString(): Map<String, dynamic>.from(e.value as Map),
        };

// Overlay increments (source of truth = exerciseSettings)
        final merged = <String, Map<String, dynamic>>{
          for (final e in details.entries) e.key: Map<String, dynamic>.from(e.value),
        };
        settings.forEach((exId, s) {
          final inc = s['increments'];
          if (inc != null) {
            merged[exId] = Map<String, dynamic>.from(merged[exId] ?? {});
            merged[exId]!['increments'] = inc;
          }
        });

// Publish into PMU
        PeriodizationModelUtils.setExerciseSettings(merged);
        PeriodizationModelUtils.plannedExerciseDetails
          ..clear()
          ..addAll(details);

// Reset periodization model map
        PeriodizationModelUtils.exercisePeriodizationModels.clear();


        // ── STEP 2: Mirror details/settings by NAME for first paint ───────────────
        for (final row in plannedCompact) {
          final name = (row['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;

          // Resolve a stable id if possible, else fallback to name
          final exId = PeriodizationModelUtils.nameToId[name] ??
              row['id']?.toString() ??
              name;

          final detail = PeriodizationModelUtils.plannedExerciseDetails[exId];
          if (detail != null) {
            // Mirror into plannedExerciseDetails under display name
            PeriodizationModelUtils.plannedExerciseDetails[name] =
            Map<String, dynamic>.from(detail);

            // Mirror increments into exerciseSettings (already merged inside PMU)
            final mergedDetail = PeriodizationModelUtils.getExerciseSettings()[exId];
            if (mergedDetail != null) {
              final clone = Map<String, dynamic>.from(mergedDetail);
              PeriodizationModelUtils.getExerciseSettings()[name] = clone;
            }

            // Mirror periodization model
            final modelEnum =
            PeriodizationModelUtils.exercisePeriodizationModels[exId];
            if (modelEnum != null) {
              PeriodizationModelUtils.exercisePeriodizationModels[name] = modelEnum;
            }

            // 🔎 Debug mirror
            print('🪞 Mirror exId="$exId" → name="$name" keys=${detail.keys.toList()}');
          }
        }



        print('🟣 [Warmup] block doc fetched uid=$uid blockId=$blockId → $blockData');

        final tsStart = blockData['startDate'] as Timestamp?;
        blockStart = tsStart?.toDate();
        final tsEnd = blockData['endDate'] as Timestamp?;
        blockEnd = tsEnd?.toDate();
      } catch (_) {/* ignore */}

// ── PMU PRIMING: inject plannedExerciseDetails + increments + model map ─────────
      try {
        // 1) Pull details & exerciseSettings as saved by Block Planner (BP)
        final detailsRaw = (blockData['plannedExerciseDetails'] as Map?) ?? const {};
        final exSettingsRaw = (blockData['exerciseSettings'] as Map?) ?? const {};

        // 2) Normalize to Map<String, Map<String,dynamic>>
        final Map<String, Map<String, dynamic>> details = {
          for (final e in detailsRaw.entries)
            e.key.toString(): Map<String, dynamic>.from(e.value as Map),
        };

        final Map<String, Map<String, dynamic>> exerciseSettings = {
          for (final e in exSettingsRaw.entries)
            e.key.toString(): Map<String, dynamic>.from(e.value as Map),
        };

        // 3) Override/overlay increments like WES does (source of truth = exerciseSettings)
        final Map<String, Map<String, dynamic>> mergedForPMU = {
          for (final e in details.entries) e.key: Map<String, dynamic>.from(e.value),
        };
        exerciseSettings.forEach((exId, v) {
          final inc = v['increments'];
          if (inc != null) {
            mergedForPMU[exId] = Map<String, dynamic>.from(mergedForPMU[exId] ?? {});
            mergedForPMU[exId]!['increments'] = inc;
          }
        });

        // 4) Publish into PMU
        PeriodizationModelUtils.setExerciseSettings(mergedForPMU);

        // 5) Publish the raw details
        PeriodizationModelUtils.plannedExerciseDetails
          ..clear()
          ..addAll(details);
        // Mirror details by display name so name lookups also work during warmup
        for (final entry in details.entries) {
          final exId = entry.key;
          final v    = entry.value;
          final display = (v['displayName'] ?? v['name'] ?? '').toString().trim();
          if (display.isNotEmpty) {
            PeriodizationModelUtils.plannedExerciseDetails[display] = v;
          }
        }


        // 6) Build the periodization model map
        PeriodizationModelUtils.exercisePeriodizationModels.clear();

        details.forEach((exId, entry) {
          final modelName = entry['periodizationModel'] as String?;
          final modelEnum = (modelName != null)
              ? PeriodizationModelUtils.stringToModel(modelName)
              : null;
          if (modelEnum != null) {
            // by ID
            PeriodizationModelUtils.exercisePeriodizationModels[exId] = modelEnum;

            // also by NAME if we can resolve
            final maybeName = PeriodizationModelUtils.nameToId.entries
                .firstWhere(
                  (kv) => kv.value == exId,
              orElse: () => const MapEntry<String, String>('', ''),
            )
                .key;
            if (maybeName.trim().isNotEmpty) {
              PeriodizationModelUtils.exercisePeriodizationModels[maybeName] =
                  modelEnum;
            }
          }
        });

        // Finally, bind names from planned rows to the same model
        for (final row in plannedCompact) {
          final n = (row['name'] ?? '').toString().trim();
          if (n.isEmpty) continue;
          final exId = PeriodizationModelUtils.nameToId[n] ?? '';
          final model = (exId.isNotEmpty)
              ? PeriodizationModelUtils.exercisePeriodizationModels[exId]
              : null;
          if (model != null) {
            PeriodizationModelUtils.exercisePeriodizationModels[n] = model;
          }
        }
      } catch (_) {
        // best-effort; don’t crash warmup if anything goes sideways
      }

// ─────────────────────────────────────────────────────────────────────────────


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
      print('🟠 [Warmup PlanProbe] plannedCompact=${plannedCompact.length} '
          'first=${plannedCompact.isNotEmpty ? plannedCompact.first : '<none>'} '
          'previousOverlay=${previousOverlay.length} '
          'blockStart=$blockStart blockEnd=$blockEnd date=$d');

      // ───────────────────────────────────────────────────────────────
      // NEW: Build final-target hints for first paint (set 1 per row)
      //  • weights are DISPLAY domain (added kg for BW; absolute for others)
      //  • absWeight also included for audit (absolute kg for all)
      //  • reps/rir are the planned targets for set 1
      // ───────────────────────────────────────────────────────────────
      final List<Map<String, dynamic>> hintsList = [];
      try {
        // We'll need week/day index if available
        int? wiForPlan;
        if (blockStart != null) {
          final startOnly = DateTime(blockStart.year, blockStart.month, blockStart.day);
          final daysSince = d.difference(startOnly).inDays;
          if (daysSince >= 0) {
            wiForPlan = daysSince ~/ 7;
          }
        }

        // Helper: planned set-1 RIR from BB2 plan (falls back to 2.0)
        double _plannedRirForSet1(String exerciseName) {
          final exId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
          final plan = PeriodizationModelUtils.plannedExerciseDetails[exId]?['rirPlan'];
          if (plan == null || blockStart == null || wiForPlan == null) return 2.0;

          final int wk = wiForPlan!;
          final int instanceIndex = PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
            exerciseName: exerciseName,
            savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
            blockStartDate: DateTime(blockStart!.year, blockStart!.month, blockStart!.day),
            weekIndex: wk,
            selectedDate: d,
          );

          final String weekKey = 'week${wk + 1}';
          final Map? weekData = plan[weekKey] as Map?;
          final int maxSessions = weekData?.keys
              .where((k) => k.toString().startsWith('session'))
              .length ?? 0;
          final int safeSession = (maxSessions > 0)
              ? instanceIndex.clamp(0, maxSessions - 1)
              : 0;

          final String sessionKey = 'session${safeSession + 1}';
          final String setKey = 'set1';
          final String? raw = plan[weekKey]?[sessionKey]?[setKey]?['rir']?.toString();
          return double.tryParse(raw ?? '') ?? 2.0;
        }

        for (int idx = 0; idx < plannedCompact.length; idx++) {
          final name = (plannedCompact[idx]['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          final int ci = (plannedCompact[idx]['circuitIndex'] is int)
              ? plannedCompact[idx]['circuitIndex'] as int
              : int.tryParse('${plannedCompact[idx]['circuitIndex'] ?? 0}') ?? 0;
          print('🔎 [Warmup Loop] building hint for "$name" ci=$ci wi=$wiForPlan');

          // 🔑 Resolve canonical exId, even if we only got a display name
          String exId = PeriodizationModelUtils.nameToId[name] ?? name;

// If details were mirrored by display name, try to recover a canonical id
          final detByName = PeriodizationModelUtils.plannedExerciseDetails[name] as Map<String, dynamic>?;
          final canonicalId = (detByName?['id'] ?? detByName?['exerciseId'])?.toString();
          if (canonicalId != null && canonicalId.isNotEmpty) {
            exId = canonicalId;
          }

          final bool isBw = PeriodizationModelUtils.isBodyweightExercise(
            id: exId,
            name: name,
          );


// (insert this print BEFORE calling getSuggestedRepTargetByModel)
          final exIdForDbg = PeriodizationModelUtils.nameToId[name] ?? name;
          print('🧩 [Warmup RepTargetCtx] name="$name" '
              'exId=$exIdForDbg '
              'weekIndex=$wiForPlan '
              'selectedDate=$d '
              'blockStart=$blockStart '
              'blockEnd=$blockEnd '
              'repTargets?=${PeriodizationModelUtils.plannedExerciseDetails[exIdForDbg]?['repTargets'] != null} '
              'rirPlan?=${PeriodizationModelUtils.plannedExerciseDetails[exIdForDbg]?['rirPlan'] != null} '
              'detailsKeys=${PeriodizationModelUtils.plannedExerciseDetails.keys.take(3).toList()}…');

          // 🔍 EXTRA DIAG: what PMU will actually look at for this exercise
          final modelEnumById   = PeriodizationModelUtils.exercisePeriodizationModels[exIdForDbg];
          final modelEnumByName = PeriodizationModelUtils.exercisePeriodizationModels[name];
          final detailsEntry    = PeriodizationModelUtils.plannedExerciseDetails[exIdForDbg] ?? const {};
          final weeklyFreq      = detailsEntry['weeklyFrequency'];
          final repTargetsAny   = detailsEntry['repTargets'];
          final repTargetsJson  = (repTargetsAny != null) ? jsonEncode(repTargetsAny) : 'null';

          String whichModelKey;
          if (modelEnumById != null) {
            whichModelKey = 'byId';
          } else if (modelEnumByName != null) {
            whichModelKey = 'byName';
          } else {
            whichModelKey = 'none';
          }

          print('🧭 [Warmup RepTargetSrc] modelKey=$whichModelKey '
              'model=${modelEnumById ?? modelEnumByName} '
              'weeklyFrequency=$weeklyFreq '
              'repTargetsKeys='
              '${(repTargetsAny is Map) ? repTargetsAny.keys.take(4).toList() : repTargetsAny.runtimeType}');

          if (repTargetsAny is Map) {
            final wkKey = 'week${(wiForPlan ?? 0) + 1}';
            final wk = repTargetsAny[wkKey];
            print('📚 [Warmup RepTargetsPeek] weekKey=$wkKey '
                'type=${wk.runtimeType} '
                'peek='
                '${(wk is Map) ? wk.keys.take(6).toList() : wk}');
          }

          // Planned rep target for set1
          // Planned rep target for set1 (DUP Exposure/Signature keep week1 across all weeks)
          int repTarget;

// 1) Try to read from plannedExerciseDetails.repTargets
          final Map<String, dynamic>? details =
          PeriodizationModelUtils.plannedExerciseDetails[exId] as Map<String, dynamic>?;
          final Map<String, dynamic>? repTargets =
          (details?['repTargets'] as Map?)?.cast<String, dynamic>();

          int? _dupRepFromWeek1() {
            if (repTargets == null || repTargets.isEmpty) return null;

            // choose week bucket: for DUP there may only be week1
            final String wkKey =
            repTargets.containsKey('week1') ? 'week1' : 'week${(wiForPlan ?? 0) + 1}';
            final Map<String, dynamic>? wk =
                (repTargets[wkKey] as Map?)?.cast<String, dynamic>() ??
                    (repTargets['week1'] as Map?)?.cast<String, dynamic>();
            if (wk == null || wk.isEmpty) return null;

            // which instance (session) of this exercise this week?
            final int instIdx = PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
              exerciseName: name,
              savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
              blockStartDate: (blockStart == null)
                  ? DateTime(d.year, d.month, d.day) // harmless fallback
                  : DateTime(blockStart!.year, blockStart!.month, blockStart!.day),
              weekIndex: wiForPlan ?? 0,
              selectedDate: d,
            );

            // clamp 1..N. Most plans have up to 4 instances.
            final String instKey = 'instance${(instIdx + 1).clamp(1, 4)}';
            final String raw = (wk[instKey] ?? wk['instance1'] ?? '').toString().trim();

            // parse "6 x 3" → 6
            final match = RegExp(r'^(\d+)\s*x').firstMatch(raw);
            return int.tryParse(match?.group(1) ?? '');
          }

// prefer DUP-style direct read when available
          final int? dupRep = _dupRepFromWeek1();
          if (dupRep != null) {
            repTarget = dupRep;
          } else {
            // 2) Fall back to PMU (covers Linear etc.)
            try {
              repTarget = PeriodizationModelUtils.getSuggestedRepTargetByModel(
                exerciseName: name,
                plannedIndex: 0, // set 1
                weekIndex: wiForPlan,
                selectedDate: d,
                blockStartDate: blockStart,
                blockEndDate: blockEnd,
                repTargetsByExercise: null,
                plannedExerciseDetails: null,
              );
            } catch (_) {
              repTarget = 10; // final fallback default
            }
          }

// (optional) quick diag
          print('🎯 [Warmup RepTarget] "$name" → $repTarget (dup? ${dupRep != null})');



          // Planned RIR for set1
          final double rir1 = _plannedRirForSet1(name);

          // Progressed absolute weight via your PMU
          // (We use the same path WES uses so math matches UI later)
          final List<double> incs = PeriodizationModelUtils.getIncrementsForExercise(exId);

// 👇 ADD THIS LINE
          final rawProg = PeriodizationModelUtils.plannedExerciseDetails[exId]?['progressionModel'] as String?;
          final pm = PeriodizationModelUtils.parseProgressionModel(rawProg);

// 👉 ONE DIAG PRINT:
          print('🧪 [Warmup Inputs] name="$name" exId=$exId wi=$wiForPlan repTarget=$repTarget rir=$rir1 '
              'prog="$rawProg"→$pm incsLen=${incs.length} details?=${PeriodizationModelUtils.plannedExerciseDetails.containsKey(exId)} '
              'rirPlan?=${PeriodizationModelUtils.plannedExerciseDetails[exId]?['rirPlan'] != null}');

          final progressed = PeriodizationModelUtils.getWeightByProgressionModel(
            model: PeriodizationModelUtils.parseProgressionModel(rawProg),
            exerciseName: name,
            repTarget: repTarget,
            defaultWeight: 20.0,
            rirValue: rir1,
            increments: incs.isEmpty ? [2.5] : incs,
            maxWeightByReps: PeriodizationModelUtils
                .plannedExerciseDetails[exId]?['maxWeightByReps'],
            topSetHistory: PeriodizationModelUtils.topSetsByExercise[name],
            weekIndex: wiForPlan ?? -1,
          );


          // Absolute (storage/math)
          final double absWeight = (progressed['weight'] is num)
              ? (progressed['weight'] as num).toDouble()
              : 20.0;

          // Display domain for fast paint field
          double displayWeight;
          if (isBw) {
            displayWeight = PeriodizationModelUtils.toDisplayAddedWeight(
              uid: uid,
              absoluteKg: absWeight,
              exerciseId: exId,
              exerciseName: name,
              asOfDate: d,
            );
          } else {
            displayWeight = absWeight;
          }

          hintsList.add({
            'name': name,
            'circuitIndex': ci,
            'reps': repTarget,
            'rir': rir1,
            'weight': displayWeight, // what the field should show on first frame
            'absWeight': absWeight,  // audit/consistency
          });
          // 👇 ADD THIS ONE PRINT
          if (repTarget == null || absWeight == 20.0) {
            print('❌ [Warmup Hints] Missing proper hint for "$name" '
                'repTarget=$repTarget absWeight=$absWeight '
                'blockStart=$blockStart blockEnd=$blockEnd '
                'details?=${PeriodizationModelUtils.plannedExerciseDetails[exId] != null}');
          } else {
            print('✅ [Warmup Hints] OK "$name" → ${absWeight}kg × $repTarget');
          }
        }
      } catch (_) {
        // best-effort; leave hintsList empty if anything goes wrong
      }


      // 8) Build hintsJson using the rich hintsList from step 7
      String hintsJson = '[]';
      try {
        if (hintsList.isNotEmpty) {
          hintsJson = jsonEncode(hintsList);
        }
      } catch (_) {
        hintsJson = '[]';
      }
      // 👇 ADD THIS PRINT
      print('🟣 [Warmup Hints] Final hintsJson=$hintsJson');

// 9) Write snapshot only if we have *something*
      if (plannedCompact.isEmpty && previousOverlay.isEmpty) {
        return; // Don't write "[]"
      }

      // decide readiness: ready only if we have planned rows + non-empty hints
      final bool ready = plannedCompact.isNotEmpty && hintsJson.isNotEmpty && hintsJson != '[]';

// recompute hash with the exact inputs we used (match section 9.1)
      final nowHash = PeriodizationModelUtils.computePlanInputsHash(
        plannedExercises: plannedCompact,
        plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
        blockStartDate: blockStart,   // ✅ use actual block start
        blockEndDate: blockEnd,   // ✅ now use the real end date
        selectedDate: d,
      );

      print('📦 [Warmup Persist] '
          'ready=$ready '
          'hintsLen=${hintsList.length} '
          'hintsReady=$ready '
          'hash=$nowHash '
          'hintsJsonPreview=${hintsJson.substring(0, hintsJson.length.clamp(0, 80))}...');



      await BlockPlanCache.putInitSnapshot(
        uid: uid,
        blockId: blockId,
        dateYmd: dateKey,
        plannedExercises: plannedCompact,
        previousWorkout: previousOverlay,
        topSetHistory: const <Map<String, dynamic>>[],
        hintsJson: hintsJson,
        hintsInputsHash: nowHash,
        hintsReady: ready,
        schemaVersion: kWesSnapshotSchema,
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
