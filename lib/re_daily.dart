// lib/core/re_daily.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'formula.dart'; // exposes Gender, reCoefficient, ReExerciseKeys, ReWeights
import 'periodization_model_utils.dart'; // exposes nameToId, calculateE1RM(...)
import 'package:flutter/material.dart';

/// ------- Config -------
const int kRepPrMin = 1;
const int kRepPrMax = 60; // make it easy to change or expose in settings


//debugs
const bool kBadgeDebug = true;
void _bdbg(String msg) {
  if (kBadgeDebug) debugPrint('[BADGE] $msg');
}


/// Firestore paths helper
class RePaths {
  static String dailyDoc(String uid, String dayKey) =>
      'users/$uid/re_daily/$dayKey';
  static String monthlyDoc(String uid, String monthKey) =>
      'users/$uid/re_monthly/$monthKey';
  static String postDocId(String uid, String dayKey) =>
      '${uid}_${dayKey.replaceAll('-', '')}';
}

/// Small struct for a lift's day maxes
class LiftDayStat {
  final double maxE1rm; // RIR-excluded
  final int? repsAtMaxActual; // for rep PR calc (optional)
  final double? maxActualWeight; // heaviest real single-set weight of the day
  const LiftDayStat({
    required this.maxE1rm,
    this.repsAtMaxActual,
    this.maxActualWeight,
  });
}

/// Result of a full daily compute
class DailyReResult {
  final double dailyTotal;
  final Map<String, double> pointsByLift;
  final Map<String, dynamic> perLiftAudit; // e1rm, factor, coeff, etc
  final double? bodyweightUsedKg;
  final bool missingBw;
  final List<String> badges; // sorted by brilliance
  const DailyReResult({
    required this.dailyTotal,
    required this.pointsByLift,
    required this.perLiftAudit,
    required this.bodyweightUsedKg,
    required this.missingBw,
    required this.badges,
  });
}

/// Central calculator/writer
class DailyReCalculator {
  final FirebaseFirestore db;
  DailyReCalculator({FirebaseFirestore? firestore})
      : db = firestore ?? FirebaseFirestore.instance;

  /// Entry point: compute, write daily+monthly+post, and return result
  Future<DailyReResult> computeAndWrite({
    required String uid,
    required String dayKey, // "yyyy-MM-dd" (your existing calendar day)
    required Gender gender, // keep as-is for now; you’ll swap to Sex later
    ReExerciseKeys keys = ReExerciseKeys.defaults,
    ReWeights weights = ReWeights.defaults,
    bool write = true,
  }) async {
    debugPrint('[RE] compute ENTER uid=$uid day=$dayKey');

    final monthKey = dayKey.substring(0, 7); // yyyy-MM
    final endOfDayTs = _endOfDayFromDayKey(dayKey);

// 1) Get BW nearest prior to end-of-day (single BW used for all five lifts)
    final bw = await _fetchNearestPriorBodyweight(uid, endOfDayTs)
        .timeout(const Duration(seconds: 8), onTimeout: () {
      debugPrint('[RE] BW fetch TIMEOUT uid=$uid day=$dayKey');
      return null;
    });
    debugPrint('[RE] BW fetch OK uid=$uid day=$dayKey bw=${bw?.toStringAsFixed(1) ?? 'null'}');


    // 2) Gather best-of-day stats per target lift (RIR-excluded e1RM, etc.)
    final dayStats = await _fetchMaxE1rmByLiftForDay(
      uid: uid,
      dayKey: dayKey,
      keys: keys,
    ).timeout(const Duration(seconds: 8), onTimeout: () {
      debugPrint('[RE] dayStats fetch TIMEOUT uid=$uid day=$dayKey');
      return <String, LiftDayStat>{};
    });
    debugPrint('[RE] dayStats OK uid=$uid day=$dayKey lifts=${dayStats.length}');


    // 3) Points per lift, then sum
    final coeff = (bw != null && bw > 0)
        ? reCoefficient(gender: gender, bodyweightKg: bw)
        : null;

    final Map<String, double> pointsByLift = {};
    final Map<String, dynamic> audit = {};
    double total = 0.0;

    final liftList = <String>[
      keys.squat,
      keys.bench,
      keys.deadlift,
      keys.chinUp,
      keys.dbShoulder,
    ];

    for (final lift in liftList) {
      final stat = dayStats[lift];
      final e1rm = (stat?.maxE1rm ?? 0.0).toDouble();

      final factor = _weightFactorForLift(lift, keys, weights);
      double pts = 0.0;

      if (coeff != null && bw != null && bw > 0 && e1rm > 0) {
        // Per-lift then sum (locked)
        pts = e1rm * factor * coeff;
      }

      // round pts to 4 for storage parity with your other code
      final ptsRounded = double.parse(pts.toStringAsFixed(4));
      pointsByLift[lift] = ptsRounded;
      total += ptsRounded;

      audit[lift] = {
        'e1rm': e1rm,
        'factor': factor,
        'coeff': coeff,
      };
    }
    debugPrint('[RE] points loop DONE uid=$uid day=$dayKey total=${total.toStringAsFixed(2)}');

    final missingBw = (bw == null || bw <= 0);
    final baseResult = DailyReResult(
      dailyTotal: double.parse(total.toStringAsFixed(4)),
      pointsByLift: pointsByLift,
      perLiftAudit: audit..addAll({'sexOrGenderUsed': describeEnum(gender)}),
      bodyweightUsedKg: bw,
      missingBw: missingBw,
      badges: const [], // will fill below
    );

    _bdbg('ENTER uid=$uid day=$dayKey total=${baseResult.dailyTotal.toStringAsFixed(2)} '
        'e1rms=${dayStats.map((k,v)=>MapEntry(k,(v.maxE1rm).toStringAsFixed(1)))}');

    // 4) Compute badges (non-blocking; timeout + fallback)
    List<String> badges = const [];
    try {
      badges = await _computeBadges(
        uid: uid,
        dayKey: dayKey,
        monthKey: monthKey,
        keys: keys,
        dayStats: dayStats,
        dailyTotal: baseResult.dailyTotal,
      );
      _bdbg('[BADGES] $dayKey → ${badges.join(', ')}');
    } catch (e) {
      debugPrint('[RE] badges ERROR uid=$uid day=$dayKey: $e');
    }



    final withBadges = DailyReResult(
      dailyTotal: baseResult.dailyTotal,
      pointsByLift: baseResult.pointsByLift,
      perLiftAudit: baseResult.perLiftAudit,
      bodyweightUsedKg: baseResult.bodyweightUsedKg,
      missingBw: baseResult.missingBw,
      badges: badges,
    );
    debugPrint('[RE] compute DECIDE uid=$uid day=$dayKey total=${withBadges.dailyTotal} bw=${withBadges.bodyweightUsedKg} badges=${withBadges.badges.length}');


    if (!write) return withBadges;

    // Decide if we should publish a feed post
    final bool noPoints =
        withBadges.dailyTotal <= 0.0 ||
            withBadges.pointsByLift.values.every((v) => (v <= 0.0));

    // 5) Write /re_daily (keep for calendars/streaks even if no points)
    await _writeDaily(uid: uid, dayKey: dayKey, res: withBadges);

    // 6) Upsert monthly rollup (also preserved)
    await _updateMonthly(
      uid: uid,
      monthKey: monthKey,
      dayKey: dayKey,
      dayTotal: withBadges.dailyTotal,
    );

    // 7) Only create a feed post if points > 0
    if (!noPoints) {
      await _upsertDailyPost(
        uid: uid,
        dayKey: dayKey,
        monthKey: monthKey,
        dailyTotal: withBadges.dailyTotal,
        pointsByLift: withBadges.pointsByLift,
        bodyweightUsedKg: withBadges.bodyweightUsedKg,
        badges: withBadges.badges,
      );
      _bdbg('[POST] wrote id=${RePaths.postDocId(uid, dayKey)} badges=${withBadges.badges.join(', ')}');
    }

    _bdbg('final badges=${badges.join(',')}');

    return withBadges;

  }

  /// ---------------- Internals ----------------

  Future<double?> _fetchNearestPriorBodyweight(
      String uid, Timestamp endOfDay) async {
    final snap = await db
        .collection('users')
        .doc(uid)
        .collection('weights')
        .where('timestamp', isLessThanOrEqualTo: endOfDay)
        .orderBy('timestamp', descending: true)
        .limit(1)
        .get();

    if (snap.docs.isEmpty) return null;
    return (snap.docs.first.data()['weight'] as num?)?.toDouble();
  }

  /// Reads the user's workout doc for the given dayKey ("yyyy-MM-dd"),
  /// scans completed sets, and returns the best-of-day stats per the 5 target lifts.
  ///
  /// - Uses exerciseId if present in exercises[i]['exerciseId'].
  /// - Else falls back to name -> PeriodizationModelUtils.nameToId[name] -> compare.
  /// - Finally falls back to exact name comparison with your canonical strings.
  /// - e1RM is computed **without RIR** (rir = 0.0).
  /// - For BW lifts, s['weight'] is already ABSOLUTE (BW+added) from your upsert.
  ///
  /// Returns a map for exactly these keys: [keys.squat, keys.bench, keys.deadlift, keys.chinUp, keys.dbShoulder].
  Future<Map<String, LiftDayStat>> _fetchMaxE1rmByLiftForDay({
    required String uid,
    required String dayKey,
    required ReExerciseKeys keys,
  }) async {
    final docRef =
    db.collection('users').doc(uid).collection('workouts').doc(dayKey);
    final snap = await docRef.get();

    // Initialize all 5 with zeros so callers can trust presence.
    final Map<String, LiftDayStat> out = {
      keys.squat: const LiftDayStat(maxE1rm: 0),
      keys.bench: const LiftDayStat(maxE1rm: 0),
      keys.deadlift: const LiftDayStat(maxE1rm: 0),
      keys.chinUp: const LiftDayStat(maxE1rm: 0),
      keys.dbShoulder: const LiftDayStat(maxE1rm: 0),
    };
    if (!snap.exists) return out;

    final data = snap.data() as Map<String, dynamic>? ?? const {};
    final exercises = (data['exercises'] is List)
        ? List<Map<String, dynamic>>.from(data['exercises'] as List)
        : const <Map<String, dynamic>>[];

    // Build a set of target names to iterate
    final targetNames = <String>{
      keys.squat,
      keys.bench,
      keys.deadlift,
      keys.chinUp,
      keys.dbShoulder,
    };

    bool _isTargetByIdOrName({
      String? exId,
      required String? exName,
      required String targetName,
    }) {
      // Prefer ID if available
      if (exId != null && exId.isNotEmpty) {
        final canonicalTargetId =
            PeriodizationModelUtils.nameToId[targetName] ?? targetName;
        return exId == canonicalTargetId;
      }

      // Fallback: name -> id compare
      final name = (exName ?? '').trim();
      if (name.isEmpty) return false;

      final incomingId = PeriodizationModelUtils.nameToId[name] ?? name;
      final canonicalTargetId =
          PeriodizationModelUtils.nameToId[targetName] ?? targetName;
      if (incomingId == canonicalTargetId) return true;

      // Final fallback: exact name equality with canonical strings
      return name == targetName;
    }

    // Local accumulator to capture best-of-day e1rm and best actual
    final Map<String, double> bestE1rm = {
      keys.squat: 0,
      keys.bench: 0,
      keys.deadlift: 0,
      keys.chinUp: 0,
      keys.dbShoulder: 0,
    };
    final Map<String, double> bestActual = {
      keys.squat: 0,
      keys.bench: 0,
      keys.deadlift: 0,
      keys.chinUp: 0,
      keys.dbShoulder: 0,
    };
    final Map<String, int> repsAtBestActual = {};

    for (final ex in exercises) {
      final rawName = (ex['name'] as String?)?.trim() ?? '';
      final rawId = (ex['exerciseId'] as String?)?.trim(); // may be absent
      if (rawName.isEmpty && (rawId == null || rawId.isEmpty)) continue;

      // Determine which target (if any) this exercise maps to.
      String? target;
      for (final tName in targetNames) {
        if (_isTargetByIdOrName(
            exId: rawId, exName: rawName, targetName: tName)) {
          target = tName;
          break;
        }
      }
      if (target == null) continue; // not one of the 5 RE lifts

      final sets = (ex['sets'] is List)
          ? List<Map<String, dynamic>>.from(ex['sets'] as List)
          : const <Map<String, dynamic>>[];

      for (final s in sets) {
        final w = (s['weight'] is num) ? (s['weight'] as num).toDouble() : 0.0;
        final r = (s['reps'] is num) ? (s['reps'] as num).toInt() : 0;
        if (w <= 0 || r <= 0) continue;

        // e1RM **without RIR** per your spec:
        final e1 = PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), 0.0);

        if (e1 > (bestE1rm[target] ?? 0)) {
          bestE1rm[target] = e1;
        }
        // Track heaviest actual weight (for NEW_1RM badge) and its reps
        if (w > (bestActual[target] ?? 0)) {
          bestActual[target] = w;
          repsAtBestActual[target] = r;
        }
      }
    }

    // Pack results
    for (final t in targetNames) {
      out[t] = LiftDayStat(
        maxE1rm: (bestE1rm[t] ?? 0).toDouble(),
        repsAtMaxActual: repsAtBestActual[t],
        maxActualWeight: (bestActual[t] ?? 0).toDouble(),
      );
    }

    return out;
  }

  double _weightFactorForLift(
      String lift, ReExerciseKeys keys, ReWeights weights) {
    if (lift == keys.bench) return weights.bench;
    if (lift == keys.squat) return weights.squat;
    if (lift == keys.deadlift) return weights.deadlift;
    if (lift == keys.chinUp) return weights.chinUp;
    if (lift == keys.dbShoulder) return weights.dbShoulder;
    return 1.0;
  }

  Timestamp _endOfDayFromDayKey(String dayKey) {
    // dayKey is "yyyy-MM-dd"
    final parts = dayKey.split('-');
    final y = int.parse(parts[0]), m = int.parse(parts[1]), d = int.parse(parts[2]);
    // 23:59:59.999 local date; Firestore stores as UTC under the hood.
    final dt = DateTime(y, m, d, 23, 59, 59, 999);
    return Timestamp.fromDate(dt);
  }

  Future<void> _writeDaily({
    required String uid,
    required String dayKey,
    required DailyReResult res,
  }) async {
    final docRef = db.doc(RePaths.dailyDoc(uid, dayKey));
    final data = {
      'timezone': 'AppDayKey', // we’re using your app day key, not tz math
      'bodyweightUsedKg': res.bodyweightUsedKg,
      'missingBw': res.missingBw,
      'totalPoints': res.dailyTotal,
      'lifts': res.pointsByLift.map((k, v) => MapEntry(k, {
        'pts': v,
        'e1rm': res.perLiftAudit[k]?['e1rm'],
        'factor': res.perLiftAudit[k]?['factor'],
      })),
      'badges': res.badges,
      'computedAt': FieldValue.serverTimestamp(),
    };
    await docRef.set(data, SetOptions(merge: true));
  }

  Future<void> _updateMonthly({
    required String uid,
    required String monthKey,
    required String dayKey,
    required double dayTotal,
  }) async {
    final docRef = db.doc(RePaths.monthlyDoc(uid, monthKey));
    await db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      final cur = snap.exists ? snap.data() as Map<String, dynamic> : {};
      final days = (cur['days'] as Map<String, dynamic>? ?? {});
      days[dayKey] = dayTotal;
      final total = days.values
          .map((e) => (e as num).toDouble())
          .fold<double>(0.0, (a, b) => a + b);

      tx.set(
          docRef,
          {
            'days': days,
            'totalPoints': double.parse(total.toStringAsFixed(4)),
            'recomputedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true));
    });
  }

  Future<void> _upsertDailyPost({
    required String uid,
    required String dayKey,
    required String monthKey,
    required double dailyTotal,
    required Map<String, double> pointsByLift,
    required double? bodyweightUsedKg,
    required List<String> badges,
  }) async {
    debugPrint('[RE] upsert post ENTER uid=$uid day=$dayKey total=$dailyTotal');

    // 1) Always write to the canonical id for that day
    final postId = RePaths.postDocId(uid, dayKey); // e.g. uid_20250928
    final ref = db.collection('posts').doc(postId);
    final now = FieldValue.serverTimestamp();

    await db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final exists = snap.exists;

      final base = <String, dynamic>{
        'type': 're_daily',
        'ownerUid': uid,
        'dayKey': dayKey,
        'monthKey': monthKey,
        'dailyTotal': dailyTotal,
        'perLift': pointsByLift.map((k, v) => MapEntry(k, <String, dynamic>{'pts': v})),
        'bodyweightUsedKg': bodyweightUsedKg,
        'visibility': 'friends',
        'badges': badges,
      };

      tx.set(
        ref,
        {
          ...base,
          if (!exists) 'createdAt': now,
          'updatedAt': now,
        },
        SetOptions(merge: true),
      );
    });
    debugPrint('[RE] upsert post OK id=${ref.id} day=$dayKey total=$dailyTotal badges=${badges.length}');


    // 2) Cleanup: delete any other re_daily posts for (uid, dayKey) with a different id
    try {
      final dupes = await db
          .collection('posts')
          .where('ownerUid', isEqualTo: uid)
          .where('type', isEqualTo: 're_daily')
          .where('dayKey', isEqualTo: dayKey)
          .limit(20)
          .get();

      final keepId = ref.id;
      int deletes = 0;
      final batch = db.batch();
      for (final d in dupes.docs) {
        if (d.id != keepId) {
          batch.delete(d.reference);
          deletes++;
        }
      }
      if (deletes > 0) {
        await batch.commit();
        debugPrint('[RE] cleanup kept=${ref.id} deleted=$deletes for $dayKey');

      }
    } catch (e) {
      // best-effort (e.g., composite index missing) — do not block the main write
      debugPrint('⚠️ [RE Daily] dupe cleanup skipped: $e');
    }
  }


  // ---------- Light cache helpers ----------

  DocumentReference<Map<String, dynamic>> _cacheDoc(String uid, String docId) {
    return db.collection('users').doc(uid).collection('re_cache').doc(docId);
  }

  Future<Map<String, dynamic>> _getCacheMap({
    required String uid,
    required String docId,
  }) async {
    final snap = await db
        .collection('users')
        .doc(uid)
        .collection('re_cache')
        .doc(docId)
        .get();

    final data = snap.data();
    // Ensure we always return a MUTABLE map
    return (data == null) ? <String, dynamic>{} : Map<String, dynamic>.from(data);
  }


  Future<void> _setCache(String uid, String docId, Map<String, dynamic> data) async {
    await _cacheDoc(uid, docId).set(data, SetOptions(merge: true));
  }

  bool _isStrictBetter(double a, double b) => a > b + _eps;      // use for NEW e1RM, NEW 1RM
  bool _isEqualOrBetter(double a, double b) => a >= b - _eps;    // use for Rep PR (ties win)

  String _shortLift(String lift, ReExerciseKeys keys) => _short(lift, keys);

// For REP PRs we need today’s heaviest ACTUAL weight at each rep count.
// We compute it on the fly from the workout doc for dayKey.
// (Keeps _fetchMaxE1rmByLiftForDay lean; avoids schema changes.)
  Future<Map<String, Map<int, double>>> _heaviestActualByRepForDay({
    required String uid,
    required String dayKey,
    required ReExerciseKeys keys,
  }) async {
    final docRef = db.collection('users').doc(uid).collection('workouts').doc(dayKey);
    final snap = await docRef.get();
    final data = (snap.data() as Map<String, dynamic>?) ?? const {};

    final exercises = (data['exercises'] is List)
        ? List<Map<String, dynamic>>.from(data['exercises'] as List)
        : const <Map<String, dynamic>>[];

    final targetNames = <String>{keys.squat, keys.bench, keys.deadlift, keys.chinUp, keys.dbShoulder};

    bool _isTargetByIdOrName({String? exId, required String? exName, required String targetName}) {
      if (exId != null && exId.isNotEmpty) {
        final canonicalTargetId = PeriodizationModelUtils.nameToId[targetName] ?? targetName;
        return exId == canonicalTargetId;
      }
      final name = (exName ?? '').trim();
      if (name.isEmpty) return false;
      final incomingId = PeriodizationModelUtils.nameToId[name] ?? name;
      final canonicalTargetId = PeriodizationModelUtils.nameToId[targetName] ?? targetName;
      if (incomingId == canonicalTargetId) return true;
      return name == targetName;
    }

    final Map<String, Map<int, double>> out = {
      keys.squat: <int, double>{},
      keys.bench: <int, double>{},
      keys.deadlift: <int, double>{},
      keys.chinUp: <int, double>{},
      keys.dbShoulder: <int, double>{},
    };

    for (final ex in exercises) {
      final rawName = (ex['name'] as String?)?.trim() ?? '';
      final rawId = (ex['exerciseId'] as String?)?.trim();
      if (rawName.isEmpty && (rawId == null || rawId.isEmpty)) continue;

      String? target;
      for (final t in targetNames) {
        if (_isTargetByIdOrName(exId: rawId, exName: rawName, targetName: t)) {
          target = t; break;
        }
      }
      if (target == null) continue;

      final sets = (ex['sets'] is List)
          ? List<Map<String, dynamic>>.from(ex['sets'] as List)
          : const <Map<String, dynamic>>[];

      for (final s in sets) {
        final w = (s['weight'] is num) ? (s['weight'] as num).toDouble() : 0.0;
        final r = (s['reps'] is num) ? (s['reps'] as num).toInt() : 0;
        if (w <= 0 || r <= 0) continue;
        final cur = out[target]![r] ?? 0.0;
        if (w > cur) out[target]![r] = w;
      }
    }

    return out;
  }


  /// ------- Badges (ranking already encoded by order below) -------
  Future<List<String>> _computeBadges({
    required String uid,
    required String dayKey,
    required String monthKey,
    required ReExerciseKeys keys,
    required Map<String, LiftDayStat> dayStats,
    required double dailyTotal,
  }) async {
    final badges = <String>[];

    // 1) New 1RM (heaviest actual weight, not estimate), per lift
    final new1rmLifts = await _detectNewAbsolute1Rm(uid, keys, dayStats);
    badges.addAll(new1rmLifts.map((l) => 'NEW_1RM_${_short(l, keys)}'));

    // 2) New e1RM (RIR-excluded), per lift
    final newE1rmLifts = await _detectNewE1rm(uid, keys, dayStats);
    badges.addAll(newE1rmLifts.map((l) => 'NEW_E1RM_${_short(l, keys)}'));

    // 3) New Rep PRs (heaviest actual at rX, X in [1..60])
    final repPrBadges = await _detectRepPrs(uid, dayKey, keys, dayStats);

    badges.addAll(repPrBadges);

    // 4) Daily best all-time (retarget with oldest-day tie policy)
    final bestAll = await _recomputeDailyBestAllTime(uid: uid);
    if (bestAll['dayKey'] != null) {
      final bestDay = bestAll['dayKey'] as String;
      if (dayKey == bestDay) {
        badges.add('DAILY_BEST_ALLTIME');
      }
      if (dayKey == bestDay) {
        await _retargetBadge(
          uid: uid,
          newDayKey: dayKey,
          oldDayKey: (dayKey == bestDay) ? null : bestDay,
          badge: 'DAILY_BEST_ALLTIME',
        );
      }
    }

// 5) Daily best this month (retarget with oldest-day tie policy)
    final bestMonth = await _recomputeDailyBestThisMonth(uid: uid, monthKey: monthKey);
    if (bestMonth['dayKey'] != null) {
      final bestDay = bestMonth['dayKey'] as String;
      if (dayKey == bestDay) {
        badges.add('DAILY_BEST_MONTH');
      }
      if (dayKey == bestDay) {
        await _retargetBadge(
          uid: uid,
          newDayKey: dayKey,
          oldDayKey: (dayKey == bestDay) ? null : bestDay,
          badge: 'DAILY_BEST_MONTH',
        );
      }
    }


    // 6) Streaks (Iron Calendar > others)
    final streak = await _currentStreak(uid);
    if (streak >= _daysInMonth(dayKey)) badges.add('IRON_CALENDAR');
    if (streak >= 20) badges.add('STREAK_20');
    if (streak >= 10) badges.add('STREAK_10');
    if (streak >= 5) badges.add('STREAK_5');

    // 7) % of all-time best is display-only (computed in UI layer if desired)

    return badges;
  }

  // ---------- Badge helpers: stubs now, wire to your store when ready ----------

  Future<List<String>> _detectNewAbsolute1Rm(
      String uid,
      ReExerciseKeys keys,
      Map<String, LiftDayStat> dayStats,
      ) async {
    _bdbg('1RM check ENTER');

    final raw = await _getCacheMap(uid: uid, docId: 'max_actual'); // Map<String, dynamic> (mutable)
    final Map<String, double> cache = {
      for (final e in raw.entries) e.key.toString(): (e.value as num).toDouble()
    };
    final winners = <String>[];
    _bdbg('1RM cache keys=${cache.keys.join(',')}');


    for (final entry in dayStats.entries) {
      final lift = entry.key;
      final short = _shortLift(lift, keys);
      final today = (entry.value.maxActualWeight ?? 0.0).toDouble();
      if (today <= 0) continue;

      final prev = (cache[short] as num?)?.toDouble() ?? 0.0;
      if (_isStrictBetter(today, prev)) {
        winners.add(lift);
        cache[short] = today;
      }
    }

    if (winners.isNotEmpty) {
      await _setCache(uid, 'max_actual', cache);
    }
    return winners;
  }


  Future<List<String>> _detectNewE1rm(
      String uid,
      ReExerciseKeys keys,
      Map<String, LiftDayStat> dayStats,
      ) async {
    _bdbg('e1RM ENTER');

    final raw = await _getCacheMap(uid: uid, docId: 'max_e1rm'); // Map<String, dynamic>
    final Map<String, double> cache = {
      for (final e in raw.entries) e.key.toString(): (e.value as num).toDouble()
    };

    final winners = <String>[];
    bool cacheMutated = false; // ← track any change (up or down)

    for (final entry in dayStats.entries) {
      final lift  = entry.key;              // canonical name, e.g. "Bench Press, Barbell"
      final short = _shortLift(lift, keys); // e.g. "BENCH"
      final today = (entry.value.maxE1rm).toDouble();
      if (today <= 0) continue;

      final prev = (cache[short] as double?) ?? 0.0;

      // ↓ Reconcile downward if cache is clearly higher than reality
      if (today < prev - _eps) {
        final fixed = await _recomputeMaxE1rmFromHistory(uid: uid, liftKey: lift);
        if ((fixed - prev).abs() > _eps) {
          cache[short] = fixed;
          cacheMutated = true;
          // optional, quiet log:
          // _bdbg('reconcile e1RM $short cache ${prev.toStringAsFixed(1)} → ${fixed.toStringAsFixed(1)}');
        }
      }

      // Award on true improvement
      if (_isStrictBetter(today, prev)) {
        winners.add(lift);
        cache[short] = today;
        cacheMutated = true;
        _bdbg('e1RM $short today=${today.toStringAsFixed(1)} prev=${prev.toStringAsFixed(1)} → WIN');
      }
    }

    // Persist if we changed anything (either reconciliation or a win)
    if (cacheMutated) {
      await _setCache(uid, 'max_e1rm', Map<String, dynamic>.from(cache));
    }

    _bdbg('e1RM winners=${winners.map((l) => _shortLift(l, keys)).join(',')}');
    return winners;
  }




  Future<List<String>> _detectRepPrs(
      String uid,
      String dayKey,
      ReExerciseKeys keys,
      Map<String, LiftDayStat> dayStats,
      ) async {
    final badges = <String>[];

    // Build today’s heaviest actual-by-rep map per lift
    final todayMap = await _heaviestActualByRepForDay(uid: uid, dayKey: dayKey, keys: keys);

    Future<void> handleLift(String lift) async {
      final short = _shortLift(lift, keys);        // e.g., "BENCH"
      final repDocId = 'rep_pr_$short';            // e.g., rep_pr_BENCH

      // Load mutable cache
      final raw = await _getCacheMap(uid: uid, docId: repDocId); // Map<String, dynamic>
      final Map<String, double> cache = {
        for (final e in raw.entries) e.key.toString(): (e.value as num).toDouble()
      };

      bool cacheMutated = false;

      // today's reps map: int -> double
      final Map<int, double> todayByRep = (todayMap[lift] == null)
          ? <int, double>{}
          : Map<int, double>.from(
        (todayMap[lift] as Map).map((k, v) => MapEntry(k as int, (v as num).toDouble())),
      );

      // Window
      for (int r = kRepPrMin; r <= kRepPrMax; r++) {
        final today = (todayByRep[r] ?? 0.0).toDouble();
        if (today <= 0) continue;

        final keyR = 'r$r';
        final prev = (cache[keyR] as num?)?.toDouble();

        // ↓ Reconcile downward if cache is clearly higher than reality
        if (prev != null && today < prev - _eps) {
          final fixed = await _recomputeRepPrFromHistory(uid: uid, liftKey: lift, reps: r);
          if (prev - fixed > _eps) {
            cache[keyR] = fixed; // shrink inflated cache
            cacheMutated = true;
            // _bdbg('reconcile RepPR $short r=$r cache ${prev.toStringAsFixed(1)} → ${fixed.toStringAsFixed(1)}');
          }
        }

        // Award on equal-or-better (within epsilon) so the PR-holding day keeps its badge on re-save
        final basePrev = (prev ?? 0.0);
        if (_isEqualOrBetter(today, basePrev)) {
          badges.add('REP_PR_${_shortLift(lift, keys)}_r$r');
          cache[keyR] = today;
          cacheMutated = true;
        }
      }

      // Persist only if something actually changed
      if (cacheMutated) {
        await _setCache(uid, repDocId, Map<String, dynamic>.from(cache));
      }
    }

    // Iterate tracked lifts
    for (final lift in <String>[keys.squat, keys.bench, keys.deadlift, keys.chinUp, keys.dbShoulder]) {
      await handleLift(lift);
    }

    return badges;
  }



  Future<bool> _isDailyBestAllTime(String uid, double today) async {
    // Try cache first
    final cache = await _getCacheMap(uid: uid, docId: 'daily_best'); // { maxDailyTotal, maxDayKey? }
    final prev = (cache['maxDailyTotal'] as num?)?.toDouble();

    if (prev == null) {
      // No cache → compute once from history and seed
      double maxTotal = 0.0;
      String? maxDay;
      final qs = await db.collection('users').doc(uid).collection('re_daily').get();
      for (final d in qs.docs) {
        final tot = (d.data()['totalPoints'] as num?)?.toDouble() ?? 0.0;
        if (tot > maxTotal) {
          maxTotal = tot;
          maxDay = d.id; // "yyyy-MM-dd"
        }
      }
      await _setCache(uid, 'daily_best', {
        'maxDailyTotal': maxTotal,
        'maxDayKey': maxDay,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      // Count tie as best
      return _isEqualOrBetter(today, maxTotal);
    }

    // Strictly better → update cache and award
    if (_isStrictBetter(today, prev)) {
      await _setCache(uid, 'daily_best', {
        'maxDailyTotal': today,
        // optionally include the day key if you thread it in
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    }

    // Tie (within epsilon) also counts as best
    return _isEqualOrBetter(today, prev);
  }



  Future<bool> _isDailyBestThisMonth(String uid, String monthKey, double today) async {
    if (today <= 0) return false;

    // Use the monthly rollup you already maintain
    final snap = await db.doc(RePaths.monthlyDoc(uid, monthKey)).get();
    final m = (snap.data() ?? const <String, dynamic>{});
    final days = (m['days'] as Map<String, dynamic>? ?? const {});
    double maxSoFar = 0.0;
    for (final v in days.values) {
      final d = (v as num?)?.toDouble() ?? 0.0;
      if (d > maxSoFar) maxSoFar = d;
    }
    return _isStrictBetter(today, maxSoFar);
  }


  Future<int> _currentStreak(String uid) async {
    // Walk backward from the most recent available day in /re_daily with totalPoints > 0
    // We’ll cap at ~400 iterations to avoid pathological scans.
    int streak = 0;

    // Find most recent day doc (in case user is computing an older day)
    final newest = await db
        .collection('users').doc(uid)
        .collection('re_daily')
        .orderBy('computedAt', descending: true)
        .limit(1)
        .get();

    String startDayKey;
    if (newest.docs.isNotEmpty) {
      startDayKey = (newest.docs.first.id); // id == "yyyy-MM-dd"
    } else {
      return 0;
    }

    DateTime cur = DateTime.parse(startDayKey); // local date per your scheme

    for (int i = 0; i < 400; i++) {
      final key = '${cur.year.toString().padLeft(4, '0')}-${cur.month.toString().padLeft(2, '0')}-${cur.day.toString().padLeft(2, '0')}';
      final snap = await db.doc(RePaths.dailyDoc(uid, key)).get();
      final total = (snap.data()?['totalPoints'] as num?)?.toDouble() ?? 0.0;
      if (total <= 0) break;
      streak += 1;
      cur = cur.subtract(const Duration(days: 1));
    }

    return streak;
  }


  int _daysInMonth(String dayKey) {
    final y = int.parse(dayKey.substring(0, 4));
    final m = int.parse(dayKey.substring(5, 7));
    final firstNext = (m == 12) ? DateTime(y + 1, 1, 1) : DateTime(y, m + 1, 1);
    final lastThis = firstNext.subtract(const Duration(days: 1));
    return lastThis.day;
  }

  Future<void> _retargetBadge({
    required String uid,
    required String newDayKey,
    required String? oldDayKey,
    required String badge,
  }) async {
    final postsCol = db.collection('posts');

    // Add badge to new holder
    final newId = RePaths.postDocId(uid, newDayKey);
    final newRef = postsCol.doc(newId);
    await newRef.set({
      'badges': FieldValue.arrayUnion([badge])
    }, SetOptions(merge: true));

    // Remove badge from old holder (if any)
    if (oldDayKey != null && oldDayKey.isNotEmpty) {
      final oldId = RePaths.postDocId(uid, oldDayKey);
      final oldRef = postsCol.doc(oldId);
      await oldRef.set({
        'badges': FieldValue.arrayRemove([badge])
      }, SetOptions(merge: true));
    }
  }


  String _short(String lift, ReExerciseKeys keys) {
    if (lift == keys.squat) return 'SQUAT';
    if (lift == keys.bench) return 'BENCH';
    if (lift == keys.deadlift) return 'DEADLIFT';
    if (lift == keys.chinUp) return 'CHIN';
    if (lift == keys.dbShoulder) return 'DB_OHP';
    return lift.toUpperCase();
  }

  static const double _eps = 0.05; // 50 g tolerance


// Full rescan for a single lift's e1RM across all days
  Future<double> _recomputeMaxE1rmFromHistory({
    required String uid,
    required String liftKey, // e.g. "Bench Press, Barbell"
  }) async {
    double maxVal = 0.0;
    final col = db.collection('users').doc(uid).collection('re_daily');
    // Scan all days client-side; if large history, paginate later
    final qs = await col.get();
    for (final d in qs.docs) {
      final m = d.data();
      final lifts = (m['lifts'] as Map<String, dynamic>?) ?? const {};
      final liftMap = (lifts[liftKey] as Map<String, dynamic>?) ?? const {};
      final e1 = (liftMap['e1rm'] as num?)?.toDouble() ?? 0.0;
      if (e1 > maxVal) maxVal = e1;
    }
    return maxVal;
  }

// Full rescan for a single lift+rep PR (heaviest actual at r)
  Future<double> _recomputeRepPrFromHistory({
    required String uid,
    required String liftKey,
    required int reps, // r in [1..60]
  }) async {
    // We don’t store per-rep in re_daily, so approximate by using best actual at EXACT reps that day.
    // If you saved that elsewhere, swap this logic to read it.
    double bestAtR = 0.0;
    final col = db.collection('users').doc(uid).collection('workouts');
    final qs = await col.get();
    for (final d in qs.docs) {
      final m = d.data();
      final exs = (m['exercises'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      for (final ex in exs) {
        final name = (ex['name'] as String?)?.trim() ?? '';
        if (name != liftKey) continue;
        final sets = (ex['sets'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
        for (final s in sets) {
          final r = (s['reps'] as num?)?.toInt() ?? 0;
          final w = (s['weight'] as num?)?.toDouble() ?? 0.0; // absolute
          if (r == reps && w > bestAtR) bestAtR = w;
        }
      }
    }
    return bestAtR;
  }

  // Full rescan for daily best (all-time)
  Future<Map<String, dynamic>> _recomputeDailyBestAllTime({
    required String uid,
  }) async {
    double maxVal = 0.0;
    String? bestDay;
    final col = db.collection('users').doc(uid).collection('re_daily');
    final qs = await col.get();
    for (final d in qs.docs) {
      final m = d.data();
      final val = (m['totalPoints'] as num?)?.toDouble() ?? 0.0;
      if (val > maxVal || (val == maxVal && (bestDay == null || d.id.compareTo(bestDay) < 0))) {
        // oldest day wins tie
        maxVal = val;
        bestDay = d.id;
      }
    }
    return {
      'dayKey': bestDay,
      'total': maxVal,
    };
  }

// Full rescan for daily best (this month only)
  Future<Map<String, dynamic>> _recomputeDailyBestThisMonth({
    required String uid,
    required String monthKey,
  }) async {
    double maxVal = 0.0;
    String? bestDay;
    final col = db.collection('users').doc(uid).collection('re_daily');
    final qs = await col.where('dayKey', isGreaterThanOrEqualTo: '$monthKey-01')
        .where('dayKey', isLessThanOrEqualTo: '$monthKey-31')
        .get();
    for (final d in qs.docs) {
      final m = d.data();
      final val = (m['totalPoints'] as num?)?.toDouble() ?? 0.0;
      if (val > maxVal || (val == maxVal && (bestDay == null || d.id.compareTo(bestDay) < 0))) {
        maxVal = val;
        bestDay = d.id;
      }
    }
    return {
      'dayKey': bestDay,
      'total': maxVal,
    };
  }


}




class ReDailyPostCard extends StatelessWidget {
  final String dayKey;                          // e.g. "2025-09-28"
  final double dailyTotal;                      // e.g. 554.36
  final double? bodyweightKg;                   // may be null
  final Map<String, dynamic> perLift;           // {"Back Squat, Barbell": {"pts": 123.45, "e1rm": 210.0}, ...}
  final List<String> badges;                    // ["NEW_1RM_BENCH", "STREAK_10", ...]
  final String? caption;                        // optional subtitle/caption

  const ReDailyPostCard({
    super.key,
    required this.dayKey,
    required this.dailyTotal,
    required this.perLift,
    this.bodyweightKg,
    this.badges = const [],
    this.caption,
  });

  // ---- Pretty helpers ----
  static const _liftOrder = [
    'Back Squat, Barbell',
    'Bench Press, Barbell',
    'Deadlift, Conventional',
    'Chin-Up',
    'Overhead Dumbbell Press, Unilateral',
  ];

  static String _shortLabel(String k) {
    if (k.contains('Back Squat')) return 'Squat';
    if (k.contains('Bench Press')) return 'Bench';
    if (k.contains('Deadlift')) return 'Deadlift';
    if (k.contains('Chin-Up')) return 'Chin-Up';
    if (k.contains('Overhead Dumbbell')) return 'DB OHP';
    return k;
  }

  static String _prettyBadge(String code) {
    if (code.startsWith('NEW_1RM_')) return 'New 1RM';
    if (code.startsWith('NEW_E1RM_')) return 'New e1RM';
    if (code.startsWith('REP_PR_')) {
      final rx = code.contains('_r') ? code.split('_r').last : '';
      return 'Rep PR (x$rx)';
    }
    if (code == 'DAILY_BEST_ALLTIME') return 'Best Daily (All-Time)';
    if (code == 'DAILY_BEST_MONTH') return 'Best Daily (Month)';
    if (code == 'IRON_CALENDAR') return 'Iron Calendar';
    if (code == 'STREAK_20') return '20-Day Streak';
    if (code == 'STREAK_10') return '10-Day Streak';
    if (code == 'STREAK_5')  return '5-Day Streak';
    return code.replaceAll('_', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Build full candidate list using canonical order, then any extras
    final allKeys = <String>[
      ..._liftOrder.where((k) => perLift.containsKey(k)),
      ...perLift.keys.where((k) => !_liftOrder.contains(k)),
    ];

    double _ptsFor(String k) {
      final v = perLift[k];
      if (v is Map<String, dynamic>) {
        return (v['pts'] is num) ? (v['pts'] as num).toDouble() : 0.0;
      }
      return (v is num) ? v.toDouble() : 0.0;
    }

    // Only include lifts that contributed points (> 0)
    // (If user only did Bench + Chin-Up, only those appear.)
    final lifts = allKeys.where((k) => _ptsFor(k) > 0.0).toList();

    // Max over included lifts only; if none, 0 (per-lift section will be empty)
    final maxPts = lifts.isEmpty
        ? 0.0
        : lifts.map(_ptsFor).reduce((a, b) => a > b ? a : b);

    final hasBadges = badges.isNotEmpty;


    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F1113), Color(0xFF161A1D)],
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 8)),
        ],
        border: Border.all(color: Colors.white10, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header line
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.fitness_center, size: 18, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Text(
                  'Daily RE Points',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                Text(
                  dayKey,
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.white60),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Big total row
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  dailyTotal.toStringAsFixed(2),
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'pts',
                    style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70),
                  ),
                ),
                const Spacer(),
                if (bodyweightKg != null && bodyweightKg! > 0)
                  Row(
                    children: [
                      const Icon(Icons.monitor_weight, size: 16, color: Colors.white70),
                      const SizedBox(width: 6),
                      Text(
                        '${bodyweightKg!.toStringAsFixed(1)} kg',
                        style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                      ),
                    ],
                  ),
              ],
            ),

            if ((caption ?? '').isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                caption!,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
            ],

            const SizedBox(height: 14),
            Divider(color: Colors.white10, thickness: 1, height: 1),

            // Per-lift bars
            ...lifts.map((k) {
              final raw = perLift[k];
              final map = (raw is Map<String, dynamic>) ? raw : <String, dynamic>{'pts': raw};
              final pts = (map['pts'] is num) ? (map['pts'] as num).toDouble() : 0.0;
              final e1 = (map['e1rm'] is num) ? (map['e1rm'] as num).toDouble() : null;
              final pct = (maxPts > 0) ? (pts / maxPts).clamp(0.0, 1.0) : 0.0;

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 74,
                      child: Text(
                        _shortLabel(k),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          height: 10,
                          child: Stack(
                            children: [
                              Container(color: Colors.white10),
                              FractionallySizedBox(
                                widthFactor: pct,
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Color(0xFF36D1DC), Color(0xFF5B86E5)],
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${pts.toStringAsFixed(2)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (e1 != null && e1 > 0)
                          Text(
                            '${e1.toStringAsFixed(1)} e1RM',
                            style: theme.textTheme.labelSmall?.copyWith(color: Colors.white60),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            }),

            if (hasBadges) ...[
              const SizedBox(height: 4),
              Divider(color: Colors.white10, thickness: 1, height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: badges.map((b) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.emoji_events, size: 14, color: Colors.amber),
                        const SizedBox(width: 6),
                        Text(
                          _prettyBadge(b),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .2,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
