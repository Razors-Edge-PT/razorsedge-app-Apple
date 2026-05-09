import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'bb3_models.dart';
import 'local_cache/block_plan_cache.dart';

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
    final weekData = (rirPlan[weekKey] as Map?)?.cast<String, dynamic>() ?? {};

    // Try the exact session; fall back to session1
    String sessionKey = 'session${sessionIndex + 1}';
    if (!weekData.containsKey(sessionKey)) sessionKey = 'session1';

    final setKey = 'set$setNumber';
    final planned = double.tryParse(
      rirPlan[weekKey]?[sessionKey]?[setKey]?['rir']?.toString() ?? '',
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

    final weekKey = 'week${weekIndex + 1}';
    final weekData = repTargets[weekKey];
    if (weekData is! Map) return 8;

    final instanceKey = 'instance${sessionIndex + 1}';
    final raw = (weekData[instanceKey] ?? weekData['instance1'])?.toString() ?? '';

    // Format: "N x M" → N reps. Also may be just "N".
    final match = RegExp(r'^(\d+)\s*[xX]').firstMatch(raw.trim());
    if (match != null) {
      return int.tryParse(match.group(1)!) ?? 8;
    }
    return int.tryParse(raw.trim()) ?? 8;
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
