// lib/core/re_formula.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'package:flutter/foundation.dart'; // for debugPrint




enum Gender { male, female }

class RePointsResult {
  final double total;
  final Map<String, double> byLift;
  final Map<String, Map<String, dynamic>>? auditByLift; // optional: e.g. {'bwKgAtDate': 92.5}

  RePointsResult({
    required this.total,
    required this.byLift,
    this.auditByLift,
  });
}


class Formula {
  static Future<RePointsResult> computeRePointsPerLift({
    required String uid,
    required Map<String, Map<String, dynamic>> bestE1rmDetail,
    required Gender gender,
  }) async {
    final db = FirebaseFirestore.instance;
    final Map<String, double> byLift = {};
    final Map<String, Map<String, dynamic>> audit = {}; // 👈 collect per-lift audit
    double total = 0.0;

    for (final entry in bestE1rmDetail.entries) {
      final lift = entry.key;
      final detail = entry.value;
      final e1rm = (detail['e1rm'] as num?)?.toDouble() ?? 0.0;
      final ts = detail['date'];
      debugPrint('🔎 [REPoints] lift=$lift e1rm=$e1rm ts=$ts');

      if (e1rm <= 0 || ts == null) {
        byLift[lift] = 0.0;
        // audit: explicitly note missing BW
        detail['bwKgAtDate'] = null;
        audit[lift] = {'bwKgAtDate': null};
        continue;
      }

      // Find most recent weigh-in at/before this lift
      final bwSnap = await db
          .collection('users')
          .doc(uid)
          .collection('weights')
          .where('timestamp', isLessThanOrEqualTo: ts)
          .orderBy('timestamp', descending: true)
          .limit(1)
          .get();
      debugPrint('📂 [REPoints] lift=$lift bwDocs=${bwSnap.docs.length}');

      if (bwSnap.docs.isEmpty) {
        byLift[lift] = 0.0;
        detail['bwKgAtDate'] = null;
        audit[lift] = {'bwKgAtDate': null};
        continue;
      }

      final bw = (bwSnap.docs.first.data()['weight'] as num?)?.toDouble() ?? 0.0;
      debugPrint('⚖️ [REPoints] lift=$lift ts=$ts bw=$bw');

      if (bw <= 0) {
        detail['bwKgAtDate'] = null;
        byLift[lift] = 0.0;
        audit[lift] = {'bwKgAtDate': null};
        continue;
      }

      // ✅ audit: record the BW actually used for this lift's scoring
      detail['bwKgAtDate'] = bw;
      audit[lift] = {'bwKgAtDate': bw};

      // Correct RE points using coefficient + per-lift factor
      final pts = _calcRePoints(lift: lift, e1rm: e1rm, bwKg: bw, gender: gender);

      final ptsRounded = double.parse(pts.toStringAsFixed(4));
      debugPrint('🏋️ [REPoints] lift=$lift e1rm=$e1rm bw=$bw → pts=$ptsRounded');

      byLift[lift] = ptsRounded;
      total += ptsRounded;
    }

    return RePointsResult(
      total: double.parse(total.toStringAsFixed(4)),
      byLift: byLift,
      auditByLift: audit, // 👈 hand back bwKgAtDate per lift
    );
  }


  static double _weightFactorForLift(String lift) {
    // Match your canonical keys (same strings you use elsewhere)
    const keys = ReExerciseKeys.defaults;
    if (lift == keys.bench)     return ReWeights.defaults.bench;      // 1.0
    if (lift == keys.squat)     return ReWeights.defaults.squat;      // 0.8
    if (lift == keys.deadlift)  return ReWeights.defaults.deadlift;   // 0.74
    if (lift == keys.chinUp)    return ReWeights.defaults.chinUp;     // 1.0
    if (lift == keys.dbShoulder)return ReWeights.defaults.dbShoulder; // 3.0
    // Unknown lift: no weighting (treat as 1.0)
    return 1.0;
  }

  static double _calcRePoints({
    required String lift,
    required double e1rm,
    required double bwKg,
    required Gender gender,
  }) {
    final coeff  = reCoefficient(gender: gender, bodyweightKg: bwKg);
    final factor = _weightFactorForLift(lift);
    final pts    = e1rm * factor * coeff;

    // helpful trace (remove later if noisy)
    debugPrint('🧪[REPoints] lift=$lift e1rm=$e1rm bw=$bwKg coeff=$coeff factor=$factor → rawPts=$pts');

    return pts;
  }

}


/// Default weighting factors (tuned so each lift contributes fairly).
class ReWeights {
  final double bench;      // 1.0
  final double squat;      // 0.8
  final double deadlift;   // 0.74
  final double chinUp;     // 1.0
  final double dbShoulder; // 3.0 (unilateral)
  const ReWeights({
    this.bench = 1.0,
    this.squat = 0.8,
    this.deadlift = 0.74,
    this.chinUp = 1.0,
    this.dbShoulder = 3.0,
  });
  static const defaults = ReWeights();
}

/// Optional per-lift include flags.
class ReIncludes {
  final bool bench, squat, deadlift, chinUp, dbShoulder;
  const ReIncludes({
    this.bench = true,
    this.squat = true,
    this.deadlift = true,
    this.chinUp = true,
    this.dbShoulder = true,
  });
  static const all = ReIncludes();
}

/// Paste your app's exact names/IDs here if you want a map-based entry point.
/// (You can ignore this entirely if you prefer the positional API.)
class ReExerciseKeys {
  final String bench;
  final String squat;
  final String deadlift;
  final String chinUp;
  final String dbShoulder; // unilateral
  const ReExerciseKeys({
    required this.bench,
    required this.squat,
    required this.deadlift,
    required this.chinUp,
    required this.dbShoulder,
  });


  static const defaults = ReExerciseKeys(
    squat:    'Back Squat, Barbell',
    bench:    'Bench Press, Barbell',
    deadlift: 'Deadlift, Conventional',
    chinUp:   'Chin-Up',
    dbShoulder: 'Overhead Dumbbell Press, Unilateral',
  );
}

/// A small, fast Horner evaluation: a0 + a1*x + ... + an*x^n
double _horner(List<double> coeffs, double x) {
  double acc = 0.0;
  for (int i = coeffs.length - 1; i >= 0; i--) {
    acc = acc * x + coeffs[i];
  }
  return acc;
}

/// Goodlift-style coefficient (your constants), by gender & bodyweight (kg).
double reCoefficient({required Gender gender, required double bodyweightKg}) {
  if (bodyweightKg <= 0) {
    throw ArgumentError.value(bodyweightKg, 'bodyweightKg', 'Must be > 0');
  }

  if (gender == Gender.male) {
    const menDen = <double>[
      -216.0475144,
      16.2606339,
      -0.002388645,
      -0.00113732,
      0.00000701863,
      -0.00000001291,
    ];
    final denom = _horner(menDen, bodyweightKg);
    if (denom == 0) throw StateError('Coefficient denominator is zero (male).');
    return (500.0 * 0.9725) / denom;
  } else {
    const womenDen = <double>[
      594.31747775582,
      -27.23842536447,
      0.82112226871,
      -0.00930733913,
      0.00004731582,
      -0.00000009054,
    ];
    final denom = _horner(womenDen, bodyweightKg);
    if (denom == 0) throw StateError('Coefficient denominator is zero (female).');
    return (500.0 * 0.9454) / denom;
  }
}

/// Core calculator (expects Chin-up as a **combined total** you already store).
double computeRePoints({
  required Gender gender,
  required double bodyweightKg,

  required double benchKg,
  required double squatKg,
  required double deadliftKg,
  required double chinUpCombinedKg,          // today’s approach
  required double dbShoulderUnilateralKg,

  ReWeights weights = ReWeights.defaults,
  ReIncludes includes = ReIncludes.all,

  /// Returned value is rounded to this many decimals (default 2).
  int roundDecimals = 2,
}) {
  final sum =
      (includes.bench      ? benchKg                 * weights.bench      : 0.0) +
          (includes.squat      ? squatKg                 * weights.squat      : 0.0) +
          (includes.deadlift   ? deadliftKg              * weights.deadlift   : 0.0) +
          (includes.chinUp     ? chinUpCombinedKg        * weights.chinUp     : 0.0) +
          (includes.dbShoulder ? dbShoulderUnilateralKg  * weights.dbShoulder : 0.0);

  final coeff = reCoefficient(gender: gender, bodyweightKg: bodyweightKg);
  final raw = sum * coeff;
  return _round(raw, roundDecimals);
}

/// Future-proof helper for when you switch to **BW + added** for Chin-up.
double computeRePointsWithSplitChinUp({
  required Gender gender,
  required double bodyweightKg,

  required double benchKg,
  required double squatKg,
  required double deadliftKg,
  required double chinUpBodyweightKg,        // pulled from BW page
  required double chinUpAddedLoadKg,         // plate/belt
  required double dbShoulderUnilateralKg,

  ReWeights weights = ReWeights.defaults,
  ReIncludes includes = ReIncludes.all,
  int roundDecimals = 2,
}) {
  final chinCombined = chinUpBodyweightKg + chinUpAddedLoadKg;
  return computeRePoints(
    gender: gender,
    bodyweightKg: bodyweightKg,
    benchKg: benchKg,
    squatKg: squatKg,
    deadliftKg: deadliftKg,
    chinUpCombinedKg: chinCombined,
    dbShoulderUnilateralKg: dbShoulderUnilateralKg,
    weights: weights,
    includes: includes,
    roundDecimals: roundDecimals,
  );
}

/// Map-based entry point (if you prefer to pass a {exerciseKey: kg} map).
double computeRePointsFromMap({
  required Gender gender,
  required double bodyweightKg,
  required Map<String, double> kgByExerciseKey,
  ReExerciseKeys keys = ReExerciseKeys.defaults,
  ReWeights weights = ReWeights.defaults,
  ReIncludes includes = ReIncludes.all,
  int roundDecimals = 2,
}) {
  double read(String k) => kgByExerciseKey[k] ?? 0.0;

  return computeRePoints(
    gender: gender,
    bodyweightKg: bodyweightKg,
    benchKg: read(keys.bench),
    squatKg: read(keys.squat),
    deadliftKg: read(keys.deadlift),
    chinUpCombinedKg: read(keys.chinUp),
    dbShoulderUnilateralKg: read(keys.dbShoulder),
    weights: weights,
    includes: includes,
    roundDecimals: roundDecimals,
  );
}

double _round(double v, int decimals) {
  if (decimals <= 0) return v.roundToDouble();
  final m = MathPow.ten(decimals);
  return (v * m).roundToDouble() / m;
}

/// Tiny pow(10, n) helper without importing dart:math every call site.
class MathPow {
  static double ten(int n) {
    // fast small-n table (0..10), falls back to loop if needed
    const table = <double>[1,10,100,1e3,1e4,1e5,1e6,1e7,1e8,1e9,1e10];
    if (n >= 0 && n < table.length) return table[n];
    double v = 1;
    for (int i = 0; i < n; i++) v *= 10;
    return v;
  }
}
//