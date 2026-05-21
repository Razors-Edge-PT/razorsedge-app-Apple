import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'bb3_models.dart';
import 'local_cache/block_plan_cache.dart';
import 'periodization_model_utils.dart';

// ─── BB3PlannedExerciseService ────────────────────────────────────────────────
//
// All Firestore + Isar operations for BB3 planned day data.
// Written from scratch — no code shared with _mergeNewBB2ExercisesIntoDraft.
//
// Firestore paths:
//   Primary  : planned_blocks/{uid}/blocks/{blockId}/weeks/week_{n}/days/day_{n}
//   Fallback : planned_blocks/{uid}/blocks/{blockId}/block_data/{YYYY-MM-DD}
//
// Identity rule: exerciseId is the unique key per day.
// Override identity for WES hints: exerciseId + setIndex (never row-based).

class BB3PlannedExerciseService {
  BB3PlannedExerciseService._();

  static final _fs = FirebaseFirestore.instance;
  static final _dateFmt = DateFormat('yyyy-MM-dd');

  // ── Path helpers ─────────────────────────────────────────────────────────

  static DocumentReference _dayDocRef(
    String uid,
    String blockId,
    int weekIndex,
    int dayIndex,
  ) =>
      _fs
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId)
          .collection('weeks')
          .doc('week_$weekIndex')
          .collection('days')
          .doc('day_$dayIndex');

  static DocumentReference _fallbackDocRef(
    String uid,
    String blockId,
    DateTime date,
  ) =>
      _fs
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId)
          .collection('block_data')
          .doc(_dateFmt.format(date));

  // ── Week/day index from date ──────────────────────────────────────────────

  static ({int weekIndex, int dayIndex}) dateToWeekDay(
    DateTime blockStart,
    DateTime date,
  ) {
    final base = DateTime(blockStart.year, blockStart.month, blockStart.day);
    final sel = DateTime(date.year, date.month, date.day);
    final days = sel.difference(base).inDays;
    return (weekIndex: days ~/ 7, dayIndex: days % 7);
  }

  // ── Set count resolution ──────────────────────────────────────────────────
  //
  // Priority:
  //   1. repTargets for current week/session instance → parse "N x M" → M sets
  //   2. exerciseSettings.defaultSets
  //   3. fallback: 3

  static int resolveSetCount({
    required Map<String, dynamic>? exSettings,
    required int weekIndex,
    required int sessionIndex,
  }) {
    if (exSettings == null) return 3;

    // 1. Try repTargets for the current week instance
    final repTargets = exSettings['repTargets'];
    if (repTargets is Map) {
      final weekKey = 'week${weekIndex + 1}';
      final weekData = repTargets[weekKey];
      if (weekData is Map) {
        final instanceKey = 'instance${sessionIndex + 1}';
        // Try current session first, then fall back to instance1
        final raw = (weekData[instanceKey] ?? weekData['instance1'])?.toString();
        if (raw != null) {
          final parsed = _parseSetsFromRepTarget(raw);
          if (parsed > 0) return parsed;
        }
      }
    }

    // 2. defaultSets
    final defaultSets = (exSettings['defaultSets'] as num?)?.toInt();
    if (defaultSets != null && defaultSets > 0) return defaultSets;

    // 3. Fallback
    return 3;
  }

  // Parses "N x M" or "NxM" → returns M (set count). Returns 0 on failure.
  static int _parseSetsFromRepTarget(String raw) {
    final match = RegExp(r'[xX]\s*(\d+)').firstMatch(raw.trim());
    if (match == null) return 0;
    return int.tryParse(match.group(1)!) ?? 0;
  }

  // ── Read — triple-layer (Isar → Firestore cache → Firestore server) ───────
  //
  // Applies backward-compat rule at read time:
  //   • 'sets' array present  → per-set format (BB3)
  //   • flat weight/reps/rir  → legacy; values belong to set 1 only
  //   • nothing               → all sets empty (model hints apply)

  static Future<List<BB3Exercise>> getPlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required DateTime date,
    Map<String, dynamic>? exerciseSettings, // used for set count fallback
  }) async {
    // ── Layer 1: Isar super-cache ──
    try {
      final cached = await BlockPlanCache.getDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
      );
      if (cached != null && cached.isNotEmpty) {
        return _deserializeList(cached, exerciseSettings);
      }
    } catch (_) {}

    // ── Layer 2: Firestore local cache ──
    final dayRef = _dayDocRef(uid, blockId, weekIndex, dayIndex);
    try {
      final snap = await dayRef.get(const GetOptions(source: Source.cache));
      if (snap.exists) {
        final exercises = _extractExercises(snap.data() as Map<String, dynamic>?);
        if (exercises.isNotEmpty) {
          await _saveToIsar(uid, blockId, weekIndex, dayIndex, exercises);
          return _deserializeList(exercises, exerciseSettings);
        }
      }
    } catch (_) {}

    // ── Layer 3: Firestore server ──
    try {
      final snap = await dayRef.get(const GetOptions(source: Source.server));
      if (snap.exists) {
        final exercises = _extractExercises(snap.data() as Map<String, dynamic>?);
        await _saveToIsar(uid, blockId, weekIndex, dayIndex, exercises);
        return _deserializeList(exercises, exerciseSettings);
      }
    } catch (_) {}

    // ── Legacy fallback: block_data/{YYYY-MM-DD} ──
    try {
      final fbRef = _fallbackDocRef(uid, blockId, date);
      final snap = await fbRef.get(const GetOptions(source: Source.server));
      if (snap.exists) {
        final data = snap.data() as Map<String, dynamic>?;
        final rows = (data?['rows'] as List?)?.cast<Map<String, dynamic>>() ??
            (data?['exercises'] as List?)?.cast<Map<String, dynamic>>() ??
            [];
        if (rows.isNotEmpty) {
          await _saveToIsar(uid, blockId, weekIndex, dayIndex, rows);
          return _deserializeList(rows, exerciseSettings);
        }
      }
    } catch (_) {}

    return [];
  }

  // Reads exercises from Isar only — no network. Used by refresh staleness check.
  static Future<List<BB3Exercise>> getPlannedDayFromIsar({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    Map<String, dynamic>? exerciseSettings,
  }) async {
    try {
      final cached = await BlockPlanCache.getDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
      );
      if (cached != null) {
        return _deserializeList(cached, exerciseSettings);
      }
    } catch (_) {}
    return [];
  }

  static List<Map<String, dynamic>> _extractExercises(
      Map<String, dynamic>? data) {
    if (data == null) return [];
    final raw = data['exercises'];
    if (raw is List) {
      return raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    }
    return [];
  }

  static Future<void> _saveToIsar(
    String uid,
    String blockId,
    int weekIndex,
    int dayIndex,
    List<Map<String, dynamic>> exercises,
  ) async {
    try {
      await BlockPlanCache.putDay(
        uid: uid,
        blockId: blockId,
        weekIndex: weekIndex,
        dayIndex: dayIndex,
        exercises: exercises,
      );
    } catch (_) {}
  }

  static List<BB3Exercise> _deserializeList(
    List<Map<String, dynamic>> raw,
    Map<String, dynamic>? exerciseSettings,
  ) {
    return raw
        .where((m) => (m['exerciseId'] ?? m['id'] ?? m['name'] ?? '').toString().isNotEmpty)
        .map((m) {
          final exId = (m['exerciseId'] ?? m['id'] ?? '').toString().trim();
          final exSettings = exerciseSettings != null
              ? (exerciseSettings[exId] as Map<String, dynamic>?)
              : null;
          final defaultCount = (exSettings?['defaultSets'] as num?)?.toInt() ?? 3;
          return BB3Exercise.fromMap(m, fallbackSetCount: defaultCount);
        })
        .toList();
  }

  // ── Write — save on unfocus ───────────────────────────────────────────────
  //
  // Writes to Firestore (offline-persistent queue handles connectivity).
  // Then updates Isar for fast next-open.
  // No hints stored — only user-entered values in sets[].

  static Future<void> savePlannedDay({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required List<BB3Exercise> exercises,
  }) async {
    final exerciseMaps = exercises.map((e) => e.toMap()).toList();

    final dayRef = _dayDocRef(uid, blockId, weekIndex, dayIndex);
    await dayRef.set(
      {'exercises': exerciseMaps},
      SetOptions(merge: true),
    );

    await _saveToIsar(uid, blockId, weekIndex, dayIndex, exerciseMaps);
  }

  // ── Delete exercise ───────────────────────────────────────────────────────

  static Future<void> deleteExercise({
    required String uid,
    required String blockId,
    required int weekIndex,
    required int dayIndex,
    required String exerciseId,
    required List<BB3Exercise> currentExercises,
    required DateTime date,
  }) async {
    final updated = currentExercises
        .where((e) => e.exerciseId != exerciseId)
        .toList();
    await savePlannedDay(
      uid: uid,
      blockId: blockId,
      weekIndex: weekIndex,
      dayIndex: dayIndex,
      exercises: updated,
    );
    await removeExerciseFromWorkoutDoc(
      uid: uid,
      date: date,
      exerciseId: exerciseId,
    );
  }

  /// Removes [exerciseId] from both exercises[] and wesPlannedExercises[] in the
  /// workout document for [date].  No-op when the document does not exist or when
  /// [exerciseId] is absent from both arrays.  Never deletes the whole document.
  static Future<void> removeExerciseFromWorkoutDoc({
    required String uid,
    required DateTime date,
    required String exerciseId,
  }) async {
    final dateKey = _dateFmt.format(date);
    final workoutRef = _fs
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(dateKey);
    try {
      await _fs.runTransaction((tx) async {
        final snap = await tx.get(workoutRef);
        if (!snap.exists) return;

        final data = snap.data() as Map<String, dynamic>;

        final exercises = List<dynamic>.from(
          (data['exercises'] as List<dynamic>?) ?? const [],
        );
        final wesPlanned = List<dynamic>.from(
          (data['wesPlannedExercises'] as List<dynamic>?) ?? const [],
        );

        final filteredEx = exercises.where((m) {
          if (m is! Map) return true;
          final id = (m['exerciseId'] ?? m['id'] ?? '').toString();
          return id != exerciseId;
        }).toList();

        final filteredWes = wesPlanned.where((m) {
          if (m is! Map) return true;
          final id = (m['exerciseId'] ?? m['id'] ?? '').toString();
          return id != exerciseId;
        }).toList();

        final exChanged = filteredEx.length != exercises.length;
        final wesChanged = filteredWes.length != wesPlanned.length;
        if (!exChanged && !wesChanged) return;

        tx.set(
          workoutRef,
          {
            'exercises': filteredEx,
            'wesPlannedExercises': filteredWes,
            'lastEditedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      });
    } catch (_) {
      // Workout doc cleanup is best-effort; planned day deletion is unaffected.
    }
  }

  // ── Block settings ────────────────────────────────────────────────────────

  static Future<BB3BlockSettings> getBlockSettings(
    String uid,
    String blockId,
  ) async {
    try {
      final snap = await _fs
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId)
          .get();
      if (snap.exists && snap.data() != null) {
        return BB3BlockSettings.fromDoc(blockId, snap.data()!);
      }
    } catch (_) {}
    return BB3BlockSettings.empty.copyWith(blockId: blockId);
  }

  // ── List blocks for athlete ───────────────────────────────────────────────

  static Future<List<BB3BlockSettings>> listBlocks(String uid) async {
    try {
      final snaps = await _fs
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .get();
      return snaps.docs
          .map((d) => BB3BlockSettings.fromDoc(d.id, d.data()))
          .toList()
        ..sort((a, b) {
          final sa = a.startDate, sb = b.startDate;
          if (sa == null && sb == null) return 0;
          if (sa == null) return 1;
          if (sb == null) return -1;
          return sb.compareTo(sa); // Most recent first
        });
    } catch (_) {
      return [];
    }
  }

  // ── Completed exercises for a day ────────────────────────────────────────
  //
  // Source: users/{uid}/workouts/{YYYY-MM-DD} → exercises[]
  // These are completed/logged sets from WES.
  // Do NOT confuse with wesPlannedExercises (incomplete manual rows).

  static Future<List<Map<String, dynamic>>> getCompletedExercises(
    String uid,
    DateTime date,
  ) async {
    final dateKey = _dateFmt.format(date);
    try {
      final snap = await _fs
          .collection('users')
          .doc(uid)
          .collection('workouts')
          .doc(dateKey)
          .get();
      if (!snap.exists || snap.data() == null) return [];
      final raw = snap.data()!['exercises'];
      if (raw is List) {
        return raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
      }
    } catch (_) {}
    return [];
  }

  // ── RIR from plan (shared by BB3HintService) ──────────────────────────────
  //
  // Reads rirPlan[weekN][sessionN][setN].rir from exerciseSettings.
  // Matches WES logic in getRirFromPlanOrInput — same structure, explicit inputs.

  static double getRirFromPlan({
    required Map<String, dynamic>? exSettings,
    required int weekIndex,
    required int sessionIndex,
    required int setNumber, // 1-based
  }) {
    if (exSettings == null) return 1.0;

    final rirPlan = exSettings['rirPlan'];
    if (rirPlan == null) return 1.0;

    final weekKey = 'week${weekIndex + 1}';
    // week1 is the repeating microcycle template; fall back when literal week is absent.
    final effectiveWeekKey =
        rirPlan.containsKey(weekKey) ? weekKey : 'week1';
    final weekData =
        (rirPlan[effectiveWeekKey] as Map?)?.cast<String, dynamic>() ?? {};

    // Try the exact session; fall back to session1
    String sessionKey = 'session${sessionIndex + 1}';
    if (!weekData.containsKey(sessionKey)) sessionKey = 'session1';

    final setKey = 'set$setNumber';
    final planned = double.tryParse(
      rirPlan[effectiveWeekKey]?[sessionKey]?[setKey]?['rir']?.toString() ?? '',
    );

    return planned ?? 1.0;
  }

  // ── Rep target for a set (used for hint display) ───────────────────────────

  static int getRepTargetForSet({
    required Map<String, dynamic>? exSettings,
    required int weekIndex,
    required int sessionIndex,
    required int setIndex, // 0-based
  }) {
    if (exSettings == null) return 8;

    final repTargets = exSettings['repTargets'];
    if (repTargets is! Map) return 8;

    final model = (exSettings['periodizationModel'] as String?) ?? '';
    final isDupWeekOrExposure =
        model == 'DUP, By Week' || model == 'DUP, By Exposure';
    final weekKey = 'week${weekIndex + 1}';
    final weekData = isDupWeekOrExposure
        ? repTargets['week1']
        : (repTargets.containsKey(weekKey)
            ? repTargets[weekKey]
            : repTargets['week1']);
    if (weekData is! Map) return 8;

    final instanceKey = 'instance${sessionIndex + 1}';
    final raw = (weekData[instanceKey] ?? weekData['instance1'])?.toString() ?? '';

    // Format: "N x M" → N reps. Also may be just "N".
    final match = RegExp(r'^(\d+)\s*[xX]').firstMatch(raw.trim());
    final result = match != null
        ? (int.tryParse(match.group(1)!) ?? 8)
        : (int.tryParse(raw.trim()) ?? 8);
    return result;
  }

  // ── Per-exercise session index for BB3 planning surface ──────────────────
  //
  // Returns how many distinct days earlier in this week (0..currentDayIndex-1)
  // had this exercise either planned in BB3 or completed in WES.
  // A day that is both planned and completed counts once (Set union).
  // This is BB3-specific: unlike WES's getInstanceCountForExerciseInWeek,
  // it counts planned exposures that may not yet be logged.

  static int getPlannedSessionIndex({
    required List<List<BB3Exercise>> plannedByDay,
    required List<List<Map<String, dynamic>>> completedByDay,
    required int currentDayIndex,
    required String exerciseId,
    required String exerciseName,
  }) {
    final Set<int> daysWithExposure = {};
    final normName = exerciseName.trim().toLowerCase();

    for (int prev = 0; prev < currentDayIndex; prev++) {
      // Check planned first
      if (plannedByDay[prev].any((e) =>
          e.exerciseId == exerciseId ||
          e.name.trim().toLowerCase() == normName)) {
        daysWithExposure.add(prev);
        continue; // already counted this day
      }
      // Check completed (WES-logged) for days not already added via planned
      if (completedByDay[prev].any((ex) {
        final exId = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
        final exName = (ex['name'] ?? '').toString().trim().toLowerCase();
        return exId == exerciseId || exName == normName;
      })) {
        daysWithExposure.add(prev);
      }
    }

    return daysWithExposure.length;
  }

  // ── Exposure-style session index (DUP, By Exposure / DUP, Signature) ──────
  //
  // Level 1: synchronous best-effort for panel hint. Counts current-week days
  // before currentDayIndex where the exercise appears (union of planned and
  // completed, no double-count). Call for DUP, By Exposure and DUP, Signature
  // only — DUP, By Week and non-DUP use getPlannedSessionIndex.

  static int getExposureIndexSync({
    required List<List<BB3Exercise>> plannedByDay,
    required List<List<Map<String, dynamic>>> completedByDay,
    required int currentDayIndex,
    required String exerciseId,
    required String exerciseName,
  }) {
    final Set<int> daysWithExposure = {};
    final normName = exerciseName.trim().toLowerCase();

    for (int d = 0; d < currentDayIndex; d++) {
      if (plannedByDay[d].any((e) =>
          e.exerciseId == exerciseId ||
          e.name.trim().toLowerCase() == normName)) {
        daysWithExposure.add(d);
        continue;
      }
      if (completedByDay[d].any((ex) {
        final id = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
        final name = (ex['name'] ?? '').toString().trim().toLowerCase();
        return id == exerciseId || name == normName;
      })) {
        daysWithExposure.add(d);
      }
    }

    return daysWithExposure.length;
  }

  // ── Within-week instance count (synchronous) ─────────────────────────────
  //
  // Counts distinct days in [0, selectedDayIndex] where this exercise appears:
  //   • Past days (d < todayDayIndex): completed with valid weight+reps required.
  //   • Today and forward (d >= todayDayIndex): planned OR completed (union).
  // Returns the count, which equals the 1-based instance number for the
  // selected session when the selected day is included (planned or completed).

  static int getWeeklyInstanceCount({
    required List<List<BB3Exercise>> plannedByDay,
    required List<List<Map<String, dynamic>>> completedByDay,
    required int selectedDayIndex,
    required int todayDayIndex,
    required String exerciseId,
    required String exerciseName,
  }) {
    final normName = exerciseName.trim().toLowerCase();
    int count = 0;
    for (int d = 0; d <= selectedDayIndex && d < 7; d++) {
      if (d < todayDayIndex) {
        // Past: completed with valid sets required
        if (completedByDay.length > d) {
          if (completedByDay[d].any((ex) {
            final id = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
            final name = (ex['name'] ?? '').toString().trim().toLowerCase();
            if (id != exerciseId && name != normName) return false;
            final sets = (ex['sets'] as List?) ?? [];
            return sets.any((s) {
              if (s is! Map) return false;
              final w = s['weight'] ?? s['weightKg'] ?? 0;
              final r = s['reps'] ?? 0;
              return (w is num && w > 0) && (r is num && r > 0);
            });
          })) {
            count++;
          }
        }
      } else {
        // Today or future: planned OR completed (union, no double-count)
        bool found = false;
        if (plannedByDay.length > d) {
          found = plannedByDay[d].any((e) =>
              e.exerciseId == exerciseId ||
              e.name.trim().toLowerCase() == normName);
        }
        if (!found && completedByDay.length > d) {
          found = completedByDay[d].any((ex) {
            final id = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
            final name = (ex['name'] ?? '').toString().trim().toLowerCase();
            return id == exerciseId || name == normName;
          });
        }
        if (found) count++;
      }
    }
    return count;
  }

  // ── Repeating instance pattern count (for exposure/signature cache wrapping) ──
  //
  // Returns how many contiguous instanceN keys exist in repTargets.week1.
  // Used to wrap raw block-wide exposure counts to the repeating pattern slot:
  //   wrappedIndex = rawCount % patternCount
  // Returns 0 when repTargets is absent or has no instance1 (safe no-op for callers).

  static int getRepTargetPatternCount(Map<String, dynamic>? exSettings) {
    final repTargets = exSettings?['repTargets'];
    if (repTargets is! Map) return 0;
    final weekData = repTargets['week1'];
    if (weekData is! Map) return 0;
    int n = 0;
    while (weekData.containsKey('instance${n + 1}')) {
      n++;
    }
    return n;
  }

  // ── DUP Signature rep target for BB3 planned-row hints ──────────────────
  //
  // parseDupSignatureRangeBB3: 3-fallback parse of repTargets for min/max.
  // computeNextDupSigRep: thin wrapper around REsignatureRepTargets(count=1).
  // getDupSignatureRepForDate: simulates the DUP Signature rep sequence using
  //   completed history [blockStart, today] + prior planned instances
  //   [today, selectedDate−1], returning the next rep target for selectedDate.

  static Map<String, int>? parseDupSignatureRangeBB3(dynamic repTargetsRaw) {
    if (repTargetsRaw is! Map) return null;

    // 1. repRange.{min,max}
    final repRange = repTargetsRaw['repRange'];
    if (repRange is Map) {
      final mn = int.tryParse(repRange['min']?.toString() ?? '');
      final mx = int.tryParse(repRange['max']?.toString() ?? '');
      if (mn != null && mx != null && mn < mx) return {'min': mn, 'max': mx};
    }

    // 2. week1.{min,max}
    final week1 = repTargetsRaw['week1'];
    if (week1 is Map) {
      final mn = int.tryParse(week1['min']?.toString() ?? '');
      final mx = int.tryParse(week1['max']?.toString() ?? '');
      if (mn != null && mx != null && mn < mx) return {'min': mn, 'max': mx};

      // 3. week1.instance1 range string e.g. "6 – 12 reps"
      final raw = week1['instance1']?.toString();
      if (raw != null) {
        final m = RegExp(r'(\d+)\s*[–\-—]\s*(\d+)').firstMatch(raw);
        if (m != null) {
          final mn2 = int.tryParse(m.group(1)!);
          final mx2 = int.tryParse(m.group(2)!);
          if (mn2 != null && mx2 != null && mn2 < mx2) {
            return {'min': mn2, 'max': mx2};
          }
        }
      }
    }

    return null;
  }

  static int computeNextDupSigRep(List<int> history, int min, int max) {
    final result = PeriodizationModelUtils.REsignatureRepTargets(
      min: min,
      max: max,
      history: history,
      count: 1,
    );
    return result.isNotEmpty ? result.first : max;
  }

  static Future<int> getDupSignatureRepForDate({
    required String exerciseId,
    required String exerciseName,
    required Map<String, dynamic>? exSettings,
    required DateTime blockStartDate,
    required DateTime selectedDate,
    required String uid,
    required String blockId,
  }) async {
    final range = parseDupSignatureRangeBB3(exSettings?['repTargets']);
    if (range == null) return 8;
    final int min = range['min']!;
    final int max = range['max']!;

    final normName = exerciseName.trim().toLowerCase();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selNorm =
        DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    final blockStart =
        DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day);

    // Completed history filtered to [blockStartDate, today].
    final List<int> completedHistory = [];
    if (!blockStart.isAfter(today)) {
      try {
        final snaps = await _fs
            .collection('users')
            .doc(uid)
            .collection('workouts')
            .where(FieldPath.documentId,
                isGreaterThanOrEqualTo: _dateFmt.format(blockStart))
            .where(FieldPath.documentId,
                isLessThanOrEqualTo: _dateFmt.format(today))
            .get();
        final sortedDocs = List.of(snaps.docs)
          ..sort((a, b) => a.id.compareTo(b.id));
        for (final doc in sortedDocs) {
          final exercises = (doc.data()['exercises'] as List?) ?? [];
          double topE1rm = 0;
          int? topEffReps;
          for (final ex in exercises) {
            if (ex is! Map) continue;
            final id =
                (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
            final name =
                (ex['name'] ?? '').toString().trim().toLowerCase();
            if (id != exerciseId && name != normName) continue;
            final sets = (ex['sets'] as List?) ?? [];
            for (final s in sets) {
              if (s is! Map) continue;
              final w =
                  ((s['weight'] ?? s['weightKg'] ?? 0) as num).toDouble();
              final r = ((s['reps'] ?? 0) as num).toDouble();
              if (w <= 0 || r <= 0) continue;
              final rir = ((s['rir'] ?? 0) as num).toDouble();
              final total = r + rir;
              final e1rm = total <= 6
                  ? w * (36 / (37 - total))
                  : w * (1 + 0.0333 * total);
              if (e1rm > topE1rm) {
                topE1rm = e1rm;
                topEffReps = total.floor();
              }
            }
            break;
          }
          if (topEffReps != null &&
              topEffReps >= min - 4 &&
              topEffReps <= max + 4) {
            completedHistory.add(topEffReps);
          }
        }
      } catch (_) {}
    }

    final List<int> runningHistory = List.from(completedHistory);

    // Simulate prior planned instances from today through selectedDate-1.
    if (selNorm.isAfter(today)) {
      final planEnd = selNorm.subtract(const Duration(days: 1));
      DateTime cur = today;
      while (!cur.isAfter(planEnd)) {
        final (:weekIndex, :dayIndex) = dateToWeekDay(blockStart, cur);
        try {
          final planned = await getPlannedDay(
            uid: uid,
            blockId: blockId,
            weekIndex: weekIndex,
            dayIndex: dayIndex,
            date: cur,
          );
          BB3Exercise? exInPlan;
          for (final e in planned) {
            if (e.exerciseId == exerciseId ||
                e.name.trim().toLowerCase() == normName) {
              exInPlan = e;
              break;
            }
          }
          if (exInPlan != null) {
            final savedRep =
                exInPlan.sets.isNotEmpty ? exInPlan.sets[0].reps : null;
            if (savedRep != null && savedRep > 0) {
              runningHistory.add(savedRep);
            } else {
              runningHistory
                  .add(computeNextDupSigRep(runningHistory, min, max));
            }
          }
        } catch (_) {}
        cur = cur.add(const Duration(days: 1));
      }
    }

    return computeNextDupSigRep(runningHistory, min, max);
  }

  // ── Exposure hint index (BB3 row hints — async, cross-week) ─────────────
  //
  // Returns the 0-based sessionIndex to use for BB3 planned-row hints for
  // DUP, By Exposure and DUP, Signature models. Counts block-wide exposures
  // that occurred BEFORE selectedDate:
  //   • Completed valid instances in [blockStartDate, today] (inclusive).
  //   • Planned instances in [today, selectedDate − 1 day] when future.
  // Uses a date-string Set so today counts once even if both completed and
  // planned.

  static Future<int> getExposureHintIndex({
    required String exerciseId,
    required String exerciseName,
    required DateTime blockStartDate,
    required DateTime selectedDate,
    required String uid,
    required String blockId,
  }) async {
    final normName = exerciseName.trim().toLowerCase();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selNorm =
        DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    final blockStart = DateTime(
        blockStartDate.year, blockStartDate.month, blockStartDate.day);
    final Set<String> countedDates = {};

    // Completed valid instances [blockStart, today]
    if (!blockStart.isAfter(today)) {
      try {
        final snaps = await _fs
            .collection('users')
            .doc(uid)
            .collection('workouts')
            .where(FieldPath.documentId,
                isGreaterThanOrEqualTo: _dateFmt.format(blockStart))
            .where(FieldPath.documentId,
                isLessThanOrEqualTo: _dateFmt.format(today))
            .get();
        for (final doc in snaps.docs) {
          final exercises = (doc.data()['exercises'] as List?) ?? [];
          if (exercises.any((ex) {
            if (ex is! Map) return false;
            final id = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
            final name = (ex['name'] ?? '').toString().trim().toLowerCase();
            if (id != exerciseId && name != normName) return false;
            final sets = (ex['sets'] as List?) ?? [];
            return sets.any((s) {
              if (s is! Map) return false;
              final w = s['weight'] ?? s['weightKg'] ?? 0;
              final r = s['reps'] ?? 0;
              return (w is num && w > 0) && (r is num && r > 0);
            });
          })) {
            countedDates.add(doc.id);
          }
        }
      } catch (_) {}
    }

    // Planned instances [today, selNorm − 1 day] (future selected dates only)
    if (selNorm.isAfter(today)) {
      final planEnd = selNorm.subtract(const Duration(days: 1));
      DateTime cur = today;
      while (!cur.isAfter(planEnd)) {
        final (:weekIndex, :dayIndex) = dateToWeekDay(blockStart, cur);
        try {
          final planned = await getPlannedDay(
            uid: uid,
            blockId: blockId,
            weekIndex: weekIndex,
            dayIndex: dayIndex,
            date: cur,
          );
          if (planned.any((e) =>
              e.exerciseId == exerciseId ||
              e.name.trim().toLowerCase() == normName)) {
            countedDates.add(_dateFmt.format(cur));
          }
        } catch (_) {}
        cur = cur.add(const Duration(days: 1));
      }
    }

    return countedDates.length;
  }

  // ── Global block exposure count (Task B — dialog completedInstanceCount) ──
  //
  // Block-wide count of workout sessions containing this exercise:
  //   • [blockStartDate, min(selectedDate, today)]: completed with valid sets
  //   • if selectedDate >= today: add planned BB3 appearances from today
  //     through selectedDate (current-week days + future weeks), skipping
  //     any day already counted as completed above.

  static Future<int> getGlobalBlockExposureCount({
    required String exerciseId,
    required String exerciseName,
    required DateTime blockStartDate,
    required DateTime selectedDate,
    required String uid,
    required String blockId,
    required List<List<BB3Exercise>> currentWeekPlannedByDay,
    required List<List<Map<String, dynamic>>> currentWeekCompletedByDay,
    required DateTime currentWeekStart,
    required int currentDayIndexInWeek,
  }) =>
      _countBlockExposures(
        exerciseId: exerciseId,
        exerciseName: exerciseName,
        blockStartDate: blockStartDate,
        selectedDate: selectedDate,
        uid: uid,
        blockId: blockId,
        currentWeekPlannedByDay: currentWeekPlannedByDay,
        currentWeekCompletedByDay: currentWeekCompletedByDay,
        currentWeekStart: currentWeekStart,
        currentDayIndexInWeek: currentDayIndexInWeek,
      );

  // ── Model-specific active instance (Task C Level 2 — dialog DUP slot) ─────
  //
  // Returns null for DUP, By Week and non-DUP models (caller falls back to
  // getPlannedSessionIndex). Returns block-wide exposure count for
  // DUP, By Exposure and DUP, Signature.

  static Future<int?> resolveBb3ModelInstanceIndex({
    required String exerciseId,
    required String exerciseName,
    required String periodizationModel,
    required DateTime blockStartDate,
    required DateTime selectedDate,
    required String uid,
    required String blockId,
    required List<List<BB3Exercise>> currentWeekPlannedByDay,
    required List<List<Map<String, dynamic>>> currentWeekCompletedByDay,
    required DateTime currentWeekStart,
    required int currentDayIndexInWeek,
  }) async {
    if (periodizationModel != 'DUP, By Exposure' &&
        periodizationModel != 'DUP, Signature') {
      return null;
    }
    return _countBlockExposures(
      exerciseId: exerciseId,
      exerciseName: exerciseName,
      blockStartDate: blockStartDate,
      selectedDate: selectedDate,
      uid: uid,
      blockId: blockId,
      currentWeekPlannedByDay: currentWeekPlannedByDay,
      currentWeekCompletedByDay: currentWeekCompletedByDay,
      currentWeekStart: currentWeekStart,
      currentDayIndexInWeek: currentDayIndexInWeek,
    );
  }

  // ── Private: shared block exposure counting logic ──────────────────────────
  //
  // Step 1: Firestore doc-ID range query on users/{uid}/workouts/{YYYY-MM-DD}
  //   for [blockStart, min(selectedDate, today)] to count completed sessions.
  // Step 2: if selectedDate > today, count planned future appearances (remaining
  //   current-week days + future weeks up to selectedDate).

  static Future<int> _countBlockExposures({
    required String exerciseId,
    required String exerciseName,
    required DateTime blockStartDate,
    required DateTime selectedDate,
    required String uid,
    required String blockId,
    required List<List<BB3Exercise>> currentWeekPlannedByDay,
    required List<List<Map<String, dynamic>>> currentWeekCompletedByDay,
    required DateTime currentWeekStart,
    required int currentDayIndexInWeek,
  }) async {
    final normName = exerciseName.trim().toLowerCase();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selNorm = DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
    final blockStart = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day);
    final windowEnd = selNorm.isBefore(today) ? selNorm : today;

    int count = 0;

    // Step 1: completed workouts in [blockStart, windowEnd]
    if (!windowEnd.isBefore(blockStart)) {
      try {
        final snaps = await _fs
            .collection('users')
            .doc(uid)
            .collection('workouts')
            .where(FieldPath.documentId,
                isGreaterThanOrEqualTo: _dateFmt.format(blockStart))
            .where(FieldPath.documentId,
                isLessThanOrEqualTo: _dateFmt.format(windowEnd))
            .get();
        for (final doc in snaps.docs) {
          final exercises = (doc.data()['exercises'] as List?) ?? [];
          if (exercises.any((ex) {
            if (ex is! Map) return false;
            final id = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
            final name = (ex['name'] ?? '').toString().trim().toLowerCase();
            if (id != exerciseId && name != normName) return false;
            final sets = (ex['sets'] as List?) ?? [];
            return sets.any((s) {
              if (s is! Map) return false;
              final w = s['weight'] ?? s['weightKg'] ?? 0;
              final r = s['reps'] ?? 0;
              return (w is num && w > 0) && (r is num && r > 0);
            });
          })) {
            count++;
          }
        }
      } catch (_) {}
    }

    // Step 2: planned appearances from today through selectedDate (inclusive).
    // Activates for today and future panels; skips entirely for past panels.
    if (!selNorm.isBefore(today)) {
      final weekStartNorm = DateTime(
          currentWeekStart.year, currentWeekStart.month, currentWeekStart.day);
      final todayIndexInWeek =
          today.difference(weekStartNorm).inDays.clamp(0, 6);
      final selectedDayIndex = currentDayIndexInWeek;

      // Current week: scan [todayIndexInWeek, selectedDayIndex] inclusive.
      for (int d = todayIndexInWeek; d <= selectedDayIndex && d < 7; d++) {
        final dayNorm = weekStartNorm.add(Duration(days: d));
        if (dayNorm.isAfter(selNorm)) break;

        // Today only: skip if already counted as completed with valid sets.
        if (dayNorm == today) {
          final todayCmp = currentWeekCompletedByDay.length > d
              ? currentWeekCompletedByDay[d]
              : <Map<String, dynamic>>[];
          final alreadyCounted = todayCmp.any((ex) {
            final id = (ex['exerciseId'] ?? ex['id'] ?? '').toString().trim();
            final name = (ex['name'] ?? '').toString().trim().toLowerCase();
            if (id != exerciseId && name != normName) return false;
            final sets = (ex['sets'] as List?) ?? [];
            return sets.any((s) {
              if (s is! Map) return false;
              final w = s['weight'] ?? s['weightKg'] ?? 0;
              final r = s['reps'] ?? 0;
              return (w is num && w > 0) && (r is num && r > 0);
            });
          });
          if (alreadyCounted) continue;
        }

        if (currentWeekPlannedByDay.length > d &&
            currentWeekPlannedByDay[d].any((e) =>
                e.exerciseId == exerciseId ||
                e.name.trim().toLowerCase() == normName)) {
          count++;
        }
      }

      // Future weeks (weeks after the selected week): nextWeekStart … selNorm
      var weekStart = weekStartNorm.add(const Duration(days: 7));
      while (!weekStart.isAfter(selNorm)) {
        for (int d = 0; d < 7; d++) {
          final dayNorm = weekStart.add(Duration(days: d));
          if (dayNorm.isAfter(selNorm)) break;
          if (dayNorm.isBefore(today)) continue;
          final (:weekIndex, :dayIndex) = dateToWeekDay(blockStart, dayNorm);
          try {
            final planned = await getPlannedDay(
              uid: uid,
              blockId: blockId,
              weekIndex: weekIndex,
              dayIndex: dayIndex,
              date: dayNorm,
            );
            if (planned.any((e) =>
                e.exerciseId == exerciseId ||
                e.name.trim().toLowerCase() == normName)) {
              count++;
            }
          } catch (_) {}
        }
        weekStart = weekStart.add(const Duration(days: 7));
      }
    }

    return count;
  }
}

extension _BB3BlockSettingsExt on BB3BlockSettings {
  BB3BlockSettings copyWith({
    String? blockId,
    String? name,
    DateTime? startDate,
    DateTime? endDate,
    Map<String, dynamic>? exerciseSettings,
  }) {
    return BB3BlockSettings(
      blockId: blockId ?? this.blockId,
      name: name ?? this.name,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      exerciseSettings: exerciseSettings ?? this.exerciseSettings,
    );
  }
}
