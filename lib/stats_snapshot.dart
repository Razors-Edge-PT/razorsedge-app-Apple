import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart'; // for debugPrint


// ----- Canonical lift keys (match your UI & formula keys)
class LiftKeys {
  static const squat   = 'Back Squat, Barbell';
  static const bench   = 'Bench Press, Barbell';
  static const dead    = 'Deadlift, Conventional';
  static const chin    = 'Chin-Up';
  static const ohpUni  = 'Overhead Dumbbell Press, Unilateral';

  static const all = <String>[squat, bench, dead, chin, ohpUni];
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
  final db = FirebaseFirestore.instance;
  final docRef = db.collection('users_public').doc(uid);

  await db.runTransaction((tx) async {
    final snap = await tx.get(docRef);
    var current = StatsSnapshot.fromMap(snap.data());

    // Parse this workout → candidates
    final exercises = (workout['exercises'] is List)
        ? List<Map<String, dynamic>>.from(workout['exercises'] as List)
        : const <Map<String, dynamic>>[];

    final singleCandidates = <String, List<double>>{ for (final k in LiftKeys.all) k: <double>[] };
    final e1rmCandidates   = <String, List<double>>{ for (final k in LiftKeys.all) k: <double>[] };

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
        e1rmCandidates[name]!.add(_e1rm(w, reps));
      }
    }

    // Merge candidates into top3 lists
    final top3Singles = Map<String, List<double>>.from(current.top3SinglesKg);
    final top3E1 = Map<String, List<double>>.from(current.top3E1rmKg);

    for (final k in LiftKeys.all) {
      top3Singles[k] = _mergeTop3(top3Singles[k] ?? <double>[], singleCandidates[k] ?? const []);
      top3E1[k]      = _mergeTop3(top3E1[k] ?? <double>[],      e1rmCandidates[k]   ?? const []);
    }

    // Derive best singles and totals
    final squatBest = _bestFromTop3(top3Singles[LiftKeys.squat] ?? const []);
    final benchBest = _bestFromTop3(top3Singles[LiftKeys.bench] ?? const []);
    final deadBest  = _bestFromTop3(top3Singles[LiftKeys.dead]  ?? const []);
    final threeLift = squatBest + benchBest + deadBest;
    final benchOnly = benchBest;

    // Optional: RE / Goodlift points — compute if you have cached BW+gender
    // For now we keep existing if present; you can recompute elsewhere on BW/gender changes.
    final updated = StatsSnapshot(
      top3SinglesKg: top3Singles,
      top3E1rmKg: top3E1,
      bestThreeLiftTotalKg: threeLift,
      benchOnlyKg: benchOnly,
      rePoints: current.rePoints,
      goodliftPoints: current.goodliftPoints,
    );

    tx.set(docRef, updated.toMap(), SetOptions(merge: true));
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
  final bestE1rmDetail = <String, Map<String, dynamic>>{};

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
        e1rmCand[name]!.add(_e1rm(w, reps));
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

  await db.collection('users_public').doc(uid).set(out.toMap(), SetOptions(merge: true));
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



