import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // for debugPrint
import 'formula.dart' as formula;


// ----- Canonical lift keys (match your UI & formula keys)
class LiftKeys {
  static const squat   = 'Back Squat, Barbell';
  static const bench   = 'Bench Press, Barbell';
  static const dead    = 'Deadlift, Conventional';
  static const chin    = 'Chin-Up';
  static const ohpUni  = 'Overhead Dumbbell Press, Unilateral';

  static const all = <String>[squat, bench, dead, chin, ohpUni];
}

Timestamp _normalizeToTimestamp(dynamic raw) {
  if (raw == null) return Timestamp.now();

  if (raw is Timestamp) return raw;

  if (raw is DateTime) return Timestamp.fromDate(raw);

  if (raw is String) {
    try {
      final dt = DateTime.tryParse(raw);
      if (dt != null) return Timestamp.fromDate(dt);
    } catch (_) {}
  }

  if (raw is int) {
    try {
      return Timestamp.fromMillisecondsSinceEpoch(raw);
    } catch (_) {}
  }

  if (raw is Map<String, dynamic>) {
    final secs = raw['_seconds'];
    final nanos = raw['_nanoseconds'] ?? 0;
    if (secs is int) {
      return Timestamp(secs, nanos is int ? nanos : 0);
    }
  }

  return Timestamp.now();
}



// If your workout might store "Deadlift" etc.
String canonical(String name) {
  switch (name.trim()) {
    case 'Deadlift': return LiftKeys.dead;
    case 'Back Squat': return LiftKeys.squat;
    case 'Bench Press': return LiftKeys.bench;
    default: return name.trim();
  }
}

// ---- Small helpers
double _toD(num? v) => (v ?? 0).toDouble();

List<double> _mergeTop3(List<double> current, Iterable<double> candidates) {
  final list = <double>[...current, ...candidates].where((v) => v > 0).toList()
    ..sort((a,b) => b.compareTo(a)); // desc
  if (list.length > 3) list.length = 3;
  return list;
}

double _bestFromTop3(List<double> top3) => top3.isEmpty ? 0 : top3.reduce((a,b) => a > b ? a : b);

// ---- E1RM (use your PMU if available; RIR fixed at 0)
double _e1rm(double weight, int reps) {
  // If you have PeriodizationModelUtils.calculateE1RM, use it:
  // return PeriodizationModelUtils.calculateE1RM(weight, reps.toDouble(), 0.0);
  // Simple fallback (Epley):
  return weight * (1 + reps / 30.0);
}

/// Shape we store in users_public/{uid}
class StatsSnapshot {
  // top-3 singles (kg) for the 5 lifts
  final Map<String, List<double>> top3SinglesKg;
  // top-3 E1RMs (kg) for the 5 lifts (best-in-training estimate)
  final Map<String, List<double>> top3E1rmKg;

  // convenience derived values (single bests / totals / points)
  final double bestThreeLiftTotalKg;
  final double benchOnlyKg;
  final double? rePoints;        // optional
  final double? goodliftPoints;  // optional

  StatsSnapshot({
    required this.top3SinglesKg,
    required this.top3E1rmKg,
    required this.bestThreeLiftTotalKg,
    required this.benchOnlyKg,
    this.rePoints,
    this.goodliftPoints,
  });

  factory StatsSnapshot.empty() {
    return StatsSnapshot(
      top3SinglesKg: { for (final k in LiftKeys.all) k: <double>[] },
      top3E1rmKg:    { for (final k in LiftKeys.all) k: <double>[] },
      bestThreeLiftTotalKg: 0,
      benchOnlyKg: 0,
    );
  }

  factory StatsSnapshot.fromMap(Map<String, dynamic>? m) {
    if (m == null) return StatsSnapshot.empty();
    List<double> asList(dynamic v) =>
        (v is List) ? v.map((e) => _toD(e as num?)).toList() : <double>[];

    final singles = <String, List<double>>{};
    final e1rms   = <String, List<double>>{};
    final srcSingles = Map<String, dynamic>.from(m['top3SinglesKg'] ?? {});
    final srcE1     = Map<String, dynamic>.from(m['top3E1rmKg'] ?? {});
    for (final k in LiftKeys.all) {
      singles[k] = asList(srcSingles[k]);
      e1rms[k]   = asList(srcE1[k]);
    }

    return StatsSnapshot(
      top3SinglesKg: singles,
      top3E1rmKg: e1rms,
      bestThreeLiftTotalKg: _toD(m['threeLiftTotalKg']),
      benchOnlyKg: _toD(m['benchOnlyKg']),
      rePoints: (m['rePoints'] as num?)?.toDouble(),
      goodliftPoints: (m['goodliftPoints'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toMap() => {
    'top3SinglesKg': top3SinglesKg,
    'top3E1rmKg': top3E1rmKg,
    'threeLiftTotalKg': bestThreeLiftTotalKg > 0 ? bestThreeLiftTotalKg : null,
    'benchOnlyKg': benchOnlyKg > 0 ? benchOnlyKg : null,
    if (rePoints != null) 'rePoints': rePoints,
    if (goodliftPoints != null) 'goodliftPoints': goodliftPoints,
    'updatedAt': FieldValue.serverTimestamp(),
    'version': 1,
  };
}

/// Call this right after WES writes/updates a workout.
/// `workout` is the exact payload you saved (must contain exercises -> sets).
Future<void> updateStatsFromWorkout({
  required String uid,
  required Map<String, dynamic> workout,
}) async {
  debugPrint('▶️ [updateStatsFromWorkout] called for uid=$uid, workoutId=${workout['id'] ?? 'unknown'}');

  final db = FirebaseFirestore.instance;
  final docRef = db.collection('users_public').doc(uid);
  await db.runTransaction((tx) async {
    final snap = await tx.get(docRef);
    final snapData = (snap.data() as Map<String, dynamic>?) ?? const {};
    var current = StatsSnapshot.fromMap(snapData);

    // Existing: parse this workout → candidates
    final exercises = (workout['exercises'] is List)
        ? List<Map<String, dynamic>>.from(workout['exercises'] as List)
        : const <Map<String, dynamic>>[];

    final singleCandidates = <String, List<double>>{
      for (final k in LiftKeys.all) k: <double>[]
    };
    final e1rmCandidates = <String, List<double>>{
      for (final k in LiftKeys.all) k: <double>[]
    };

    // Track per-workout best detail
    final bestDetailInThisWorkout = <String, Map<String, dynamic>>{};

    for (final ex in exercises) {
      final name = canonical((ex['name'] as String? ?? '').trim());
      if (!LiftKeys.all.contains(name)) continue;

      final sets = (ex['sets'] is List)
          ? List<Map<String, dynamic>>.from(ex['sets'] as List)
          : const <Map<String, dynamic>>[];

      for (final s in sets) {
        final w = _toD(s['weight'] as num?);
        final reps = (s['reps'] is num)
            ? (s['reps'] as num).toInt()
            : int.tryParse('${s['reps'] ?? 0}') ?? 0;
        if (w <= 0 || reps <= 0) continue;

        if (reps == 1) singleCandidates[name]!.add(w);

        final e1 = _e1rm(w, reps);
        e1rmCandidates[name]!.add(e1);

        final prev = bestDetailInThisWorkout[name];
        final prevE1 = (prev?['e1rm'] as num?)?.toDouble() ?? 0.0;
        if (prev == null || e1 > prevE1) {
          bestDetailInThisWorkout[name] = {
            'weight': w,
            'reps': reps,
            'e1rm': e1,
          };
        }
      }
    }

    // Merge candidates into top3 lists
    final top3Singles = Map<String, List<double>>.from(current.top3SinglesKg);
    final top3E1 = Map<String, List<double>>.from(current.top3E1rmKg);

    for (final k in LiftKeys.all) {
      top3Singles[k] =
          _mergeTop3(top3Singles[k] ?? <double>[], singleCandidates[k] ?? const []);
      top3E1[k] =
          _mergeTop3(top3E1[k] ?? <double>[], e1rmCandidates[k] ?? const []);
    }

    // Derive best singles and totals
    final squatBest = _bestFromTop3(top3Singles[LiftKeys.squat] ?? const []);
    final benchBest = _bestFromTop3(top3Singles[LiftKeys.bench] ?? const []);
    final deadBest = _bestFromTop3(top3Singles[LiftKeys.dead] ?? const []);
    final threeLift = squatBest + benchBest + deadBest;
    final benchOnly = benchBest;

    // --- Merge bestE1rmDetail (and stamp a robust Timestamp date from workout['date'])
    Timestamp _normTS(dynamic raw) {
      if (raw == null) return Timestamp.now();
      if (raw is Timestamp) return raw;
      if (raw is DateTime) return Timestamp.fromDate(raw);
      if (raw is String) {
        try {
          final dt = DateTime.tryParse(raw);
          if (dt != null) return Timestamp.fromDate(dt);
        } catch (_) {}
      }
      if (raw is int) {
        try {
          return Timestamp.fromMillisecondsSinceEpoch(raw);
        } catch (_) {}
      }
      if (raw is Map<String, dynamic>) {
        final secs = raw['_seconds'];
        final nanos = raw['_nanoseconds'] ?? 0;
        if (secs is int) return Timestamp(secs, (nanos is int) ? nanos : 0);
      }
      return Timestamp.now();
    }

    final existingDetail = Map<String, dynamic>.from(snapData['bestE1rmDetail'] ?? {});
    final mergedDetail   = Map<String, dynamic>.from(existingDetail);

// Normalize incoming workout date (string, ts, etc.) → Timestamp
    final tsWorkout = _normTS(workout['date']);
    debugPrint('📅 [updateStatsFromWorkout] workout.date raw=${workout['date']} '
        'type=${workout['date']?.runtimeType} → ts=$tsWorkout');

// One-time cleanup: ensure any existing stored dates are Timestamps too
    mergedDetail.updateAll((lift, m) {
      final map = Map<String, dynamic>.from(m ?? {});
      map['date'] = _normTS(map['date'] ?? tsWorkout);
      return map;
    });

// Merge the best-in-this-workout and stamp normalized date
    bestDetailInThisWorkout.forEach((lift, cand) {
      final prev   = existingDetail[lift];
      final prevE1 = (prev?['e1rm'] as num?)?.toDouble() ?? 0.0;
      final newE1  = (cand['e1rm'] as num?)?.toDouble() ?? 0.0;
      if (prev == null || newE1 > prevE1) {
        mergedDetail[lift] = {
          ...cand,
          'date': tsWorkout, // always a Firestore Timestamp now
        };
        debugPrint('📝 [updateStatsFromWorkout] set bestE1rmDetail[$lift] '
            'e1rm=$newE1 date=$tsWorkout');
      }
    });

// ── RE Points: reuse single source of truth
// Read user profile from /users/{uid}
    final userRef  = FirebaseFirestore.instance.collection('users').doc(uid);
    final userSnap = await tx.get(userRef);
    final userData = (userSnap.data() as Map<String, dynamic>?) ?? const {};

// Sex from users/{uid}.sex
    final sexCode = (userData['sex'] as String?) ?? 'M';
    final gender = (sexCode == 'F')
        ? formula.Gender.female
        : formula.Gender.male; // 'M' and 'N' → male


// Persist bestE1rmDetail with date if not already there
    bestDetailInThisWorkout.forEach((lift, cand) {
      final prev = existingDetail[lift];
      final prevE1 = (prev?['e1rm'] as num?)?.toDouble() ?? 0.0;
      final newE1 = (cand['e1rm'] as num?)?.toDouble() ?? 0.0;
      if (prev == null || newE1 > prevE1) {
        final rawDate = workout['date'];
        final ts = _normalizeToTimestamp(rawDate);
        debugPrint('📅 [updateStatsFromWorkout] lift=$lift rawDate=$rawDate type=${rawDate?.runtimeType} normalized=$ts');
        mergedDetail[lift] = {
          ...cand,
          'date': ts,
        };
      }
    });


// Compute per-lift + total
    final rePointsResult = await formula.Formula.computeRePointsPerLift(
      uid: uid,
      bestE1rmDetail: mergedDetail.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v))),
      gender: gender,
    );

// Build updated snapshot
    final updated = StatsSnapshot(
      top3SinglesKg: top3Singles,
      top3E1rmKg: top3E1,
      bestThreeLiftTotalKg: threeLift,
      benchOnlyKg: benchOnly,
      rePoints: rePointsResult.total,
      goodliftPoints: current.goodliftPoints,
    );

// Write snapshot + detail + per-lift points
    tx.set(docRef, {
      ...updated.toMap(),
      'rePoints': rePointsResult.total,
      'rePointsByLift': rePointsResult.byLift,
      'bestE1rmDetail': mergedDetail,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    debugPrint('🧮 [updateStatsFromWorkout] RE Points total=${rePointsResult.total} byLift=${rePointsResult.byLift}');

  });
}




/// Recompute points after the user changes gender/BW (self only).
Future<void> recomputePointsFromStoredBests({
  required String uid,
  required double bodyweightKg,
  required String gender, // 'male' | 'female'
  required double Function(Map<String,double> kgByLift, String gender, double bwKg) computeRePoints,
  double Function(Map<String,double> kgByLift, String gender, double bwKg)? computeGoodliftPoints,
}) async {
  final db = FirebaseFirestore.instance;
  final docRef = db.collection('users_public').doc(uid);
  final snap = await docRef.get();
  final m = snap.data() ?? {};
  final singles = Map<String, dynamic>.from(m['top3SinglesKg'] ?? {});
  double best(String k) {
    final list = (singles[k] is List) ? (singles[k] as List).map((e) => _toD(e as num?)).toList() : <double>[];
    return _bestFromTop3(list);
  }

  final kgByLift = <String,double>{
    LiftKeys.squat: best(LiftKeys.squat),
    LiftKeys.bench: best(LiftKeys.bench),
    LiftKeys.dead:  best(LiftKeys.dead),
    LiftKeys.chin:  best(LiftKeys.chin),   // for RE you might use E1RM map instead; up to you
    LiftKeys.ohpUni:best(LiftKeys.ohpUni),
  };

  final re = computeRePoints(kgByLift, gender, bodyweightKg);
  final gl = (computeGoodliftPoints != null) ? computeGoodliftPoints(kgByLift, gender, bodyweightKg) : null;

  await docRef.set({
    'rePoints': re,
    if (gl != null) 'goodliftPoints': gl,
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));




}


Future<void> backfillStatsForUser(String uid) async {
  final db = FirebaseFirestore.instance;
  final workoutsCol = db.collection('users').doc(uid).collection('workouts');
  final bestE1rmDetail = <String, Map<String, dynamic>>{}; // 👈 NEW

  // You can page if needed; single read is fine to start
  QuerySnapshot<Map<String, dynamic>> snaps;
  try {
    snaps = await workoutsCol.orderBy('date', descending: true).limit(2000).get();
  } catch (_) {
    snaps = await workoutsCol.limit(2000).get();
  }

  var snapshot = StatsSnapshot.empty();

  for (final doc in snaps.docs) {
    final w = doc.data();
    // Reuse the merge logic: parse → candidates → merge into snapshot locals
    final exercises = (w['exercises'] is List)
        ? List<Map<String, dynamic>>.from(w['exercises'] as List)
        : const <Map<String, dynamic>>[];

    final singleCand = <String, List<double>>{ for (final k in LiftKeys.all) k: <double>[] };
    final e1rmCand   = <String, List<double>>{ for (final k in LiftKeys.all) k: <double>[] };

    for (final ex in exercises) {
      final name = canonical((ex['name'] as String? ?? '').trim());
      if (!LiftKeys.all.contains(name)) continue;

      final sets = (ex['sets'] is List)
          ? List<Map<String, dynamic>>.from(ex['sets'] as List)
          : const <Map<String, dynamic>>[];

      for (final s in sets) {
        final w = _toD(s['weight'] as num?);
        final reps = (s['reps'] is num)
            ? (s['reps'] as num).toInt()
            : int.tryParse('${s['reps'] ?? 0}') ?? 0;
        if (w <= 0 || reps <= 0) continue;

        if (reps == 1) singleCand[name]!.add(w);

        final e1 = _e1rm(w, reps);          // 👈 compute once
        e1rmCand[name]!.add(e1);

        // 👇 NEW: remember best e1rm detail (weight + reps + e1rm) for this lift
        final prev = bestE1rmDetail[name];
        final prevE1 = (prev?['e1rm'] as num?)?.toDouble() ?? 0.0;
        if (prev == null || e1 > prevE1) {
          bestE1rmDetail[name] = {
            'weight': w,
            'reps': reps,
            'e1rm': e1,
          };
        }
      }
    }

    // merge into local snapshot
    for (final k in LiftKeys.all) {
      final curS = snapshot.top3SinglesKg[k] ?? <double>[];
      final curE = snapshot.top3E1rmKg[k] ?? <double>[];
      snapshot.top3SinglesKg[k] = _mergeTop3(curS, singleCand[k] ?? const []);
      snapshot.top3E1rmKg[k]    = _mergeTop3(curE, e1rmCand[k]   ?? const []);
    }
  }

  // derive totals
  final squatBest = _bestFromTop3(snapshot.top3SinglesKg[LiftKeys.squat] ?? const []);
  final benchBest = _bestFromTop3(snapshot.top3SinglesKg[LiftKeys.bench] ?? const []);
  final deadBest  = _bestFromTop3(snapshot.top3SinglesKg[LiftKeys.dead]  ?? const []);
  final threeLift = squatBest + benchBest + deadBest;
  final benchOnly = benchBest;

  final out = StatsSnapshot(
    top3SinglesKg: snapshot.top3SinglesKg,
    top3E1rmKg: snapshot.top3E1rmKg,
    bestThreeLiftTotalKg: threeLift,
    benchOnlyKg: benchOnly,
  );

  await db.collection('users_public').doc(uid).set({
    ...out.toMap(),
    'bestE1rmDetail': bestE1rmDetail, // 👈 NEW
  }, SetOptions(merge: true));

  debugPrint('✅ Backfilled stats for $uid');
}


Future<void> backfillAllUsers() async {
  final db = FirebaseFirestore.instance;
  final qs = await db.collection('users').get();

  int ok = 0, fail = 0;
  for (final d in qs.docs) {
    final uid = d.id;
    try {
      await backfillStatsForUser(uid);
      ok++;
    } catch (e) {
      debugPrint('❌ Failed backfill for $uid: $e');
      fail++;
    }
  }
  debugPrint('🏁 Backfill complete: $ok succeeded, $fail failed, total=${qs.size}');
}

/// Recompute RE Points over the **last 12 months (rolling 365 days)**.
/// - Scans workouts (client-side filter; your 'date' is ISO or mixed types).
/// - Finds the **best E1RM + date per lift** within that window.
/// - Uses **per-lift bodyweight** at/<= that date to compute points (via Formula.computeRePointsPerLift).
/// - Writes `rePointsByLift` and `rePoints` to users_public.
/// - Uses **current** users/{uid}.sex ('M'|'F'|'N' with 'N' → male).
Future<void> recomputeRePointsLast12Months(String uid) async {
  final db = FirebaseFirestore.instance;

  Timestamp _normTS(dynamic raw) {
    if (raw == null) return Timestamp.now();
    if (raw is Timestamp) return raw;
    if (raw is DateTime) return Timestamp.fromDate(raw);
    if (raw is String) {
      final dt = DateTime.tryParse(raw);
      if (dt != null) return Timestamp.fromDate(dt);
    }
    if (raw is int) {
      return Timestamp.fromMillisecondsSinceEpoch(raw);
    }
    if (raw is Map<String, dynamic>) {
      final secs = raw['_seconds'];
      final nanos = raw['_nanoseconds'] ?? 0;
      if (secs is int) return Timestamp(secs, (nanos is int) ? nanos : 0);
    }
    return Timestamp.now();
  }

  double _toD(num? v) => (v ?? 0).toDouble();

  // Window: rolling 365 days
  final nowTs = Timestamp.now();
  final now = nowTs.toDate();
  final since = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 365));
  final sinceTs = Timestamp.fromDate(since);

  // Pull up to 2000 workouts; filter client-side by normalized date.
  QuerySnapshot<Map<String, dynamic>> snaps;
  try {
    // Some docs may store 'date' as a string; we can't rely on Firestore range queries.
    snaps = await db.collection('users').doc(uid).collection('workouts')
        .orderBy('lastEditedAt', descending: true) // best-effort ordering
        .limit(2000)
        .get();
  } catch (_) {
    snaps = await db.collection('users').doc(uid).collection('workouts')
        .limit(2000)
        .get();
  }

  // Build best E1RM + date per lift within window
  final bestE1rmDetailWindow = <String, Map<String, dynamic>>{};
  for (final doc in snaps.docs) {
    final w = doc.data();
    final wTs = _normTS(w['date']);
    if (wTs.compareTo(sinceTs) < 0) {
      // older than window → skip
      continue;
    }

    final exercises = (w['exercises'] is List)
        ? List<Map<String, dynamic>>.from(w['exercises'] as List)
        : const <Map<String, dynamic>>[];

    for (final ex in exercises) {
      final name = canonical((ex['name'] as String? ?? '').trim());
      if (!LiftKeys.all.contains(name)) continue;

      final sets = (ex['sets'] is List)
          ? List<Map<String, dynamic>>.from(ex['sets'] as List)
          : const <Map<String, dynamic>>[];

      for (final s in sets) {
        final wkg  = _toD(s['weight'] as num?);
        final reps = (s['reps'] is num)
            ? (s['reps'] as num).toInt()
            : int.tryParse('${s['reps'] ?? 0}') ?? 0;
        if (wkg <= 0 || reps <= 0) continue;

        final e1 = _e1rm(wkg, reps); // ignore RIR as requested
        final prev = bestE1rmDetailWindow[name];
        final prevE1 = (prev?['e1rm'] as num?)?.toDouble() ?? 0.0;
        if (prev == null || e1 > prevE1) {
          bestE1rmDetailWindow[name] = {
            'weight': wkg,
            'reps': reps,
            'e1rm': e1,
            'date': wTs, // normalized Timestamp
          };
        }
      }
    }
  }

  // Resolve current sex -> gender
  final userSnap = await db.collection('users').doc(uid).get();
  final userData = userSnap.data() ?? const {};
  final sexCode  = (userData['sex'] as String?) ?? 'M';
  final gender   = (sexCode == 'F')
      ? formula.Gender.female
      : formula.Gender.male; // 'M' or 'N' => male

  // Compute per-lift + total using per-lift BW at/<= lift date
  final result = await formula.Formula.computeRePointsPerLift(
    uid: uid,
    bestE1rmDetail: bestE1rmDetailWindow,
    gender: gender,
  );


  // Persist only RE fields (don’t clobber top3* from WES incremental)
  await db.collection('users_public').doc(uid).set({
    'rePointsByLift': result.byLift,         // rounded to 4 dp inside compute
    'rePoints': result.total,                // rounded to 4 dp
    'rePointsWindowMonths': 12,
    'rePointsComputedAt': FieldValue.serverTimestamp(),
    'rePointsSource': 'recompute12m',
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  debugPrint('✅ [recompute12m] uid=$uid total=${result.total} byLift=${result.byLift}');
}




