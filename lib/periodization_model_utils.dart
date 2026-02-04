import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart'; // Import for date formatting
import 'package:localtest222/workout_model.dart';
import 'exercise_selection_screen.dart';
import 'template_model.dart';
import 'templates.dart';
import 'exercise_details_screen.dart'; // Import your exercise details screen
import 'top_sets_screen.dart';
import 'Block_Planner.dart';
import 'dart:convert';
import 'WorkoutSummaryScreen.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';



enum PeriodizationModelType {
  dailyUndulatingExposure, // <-- add this
  dupSignature,
  dailyUndulatingWeek,
  linearClassic,
  linearExposure,
}

enum RirModelType {
  linearTaper,
  waveUndulation,
  sessionBased,
  static,
}

enum ProgressionModelType {
  none,
  linearWeightIncrease,
  smartProgression,
  addRepsProgressionModel, // ✅ New
}




class PeriodizationModelUtils {
  static final Map<String, List<double>> exercisePreviousE1RMs = {};
  static final Map<String, List<int>> exercisePreviousTopSetReps = {};
  static final Map<String, List<Map<String, dynamic>>> topSetsByExercise = {};
  static Map<String, PeriodizationModelType> exercisePeriodizationModels = {};
  static Map<String, dynamic> plannedExerciseDetails = {}; // ✅ Add this line
  static Map<String, String> nameToId = {};

  static final Map<String, String> idToName = {};        // id → name ✅
  static final Map<String, String> exerciseTypeById = {}; // NEW: exerciseId → type
  static final List<int> linearClassicDefaults = [10, 8, 6];
  static final List<int> linearExposureDefaults = [12, 10, 8, 6, 4, 2];
  static final List<int> dupSignatureDefaults = [6, 10];
  static Map<String, Map<String, dynamic>> bb2DailyData = {};
  static List<Map<String, dynamic>> savedWorkoutsList = [];

  static Map<String, dynamic> get exerciseSettings => _exerciseSettings;



  static double calculateE1RM(double? weight, double? reps, double? rir) {
    double w = weight ?? 0.0;
    double r = reps ?? 0.0;
    double rValue = rir ?? 0.0;

    double totalReps = r + rValue;

    // Round to avoid floating point edge cases like 6.000000003
    totalReps = double.parse(totalReps.toStringAsFixed(4));

    if (totalReps <= 25.0) {
      // Brzycki
      return w * (36 / (37 - totalReps));
    } else {
      // Epley
      return w * (1 + 0.0333 * totalReps);
    }
  }


  static double reverseCalculateWeight({
    required double targetE1RM,
    required int reps,
    double rir = 0.0,
  }) {
    final double totalReps = reps + rir;

    if (totalReps <= 25) {
      // Invert: E1RM = W * (36 / (37 - reps))
      return targetE1RM * ((37 - totalReps) / 36);
    } else {
      // Invert: E1RM = W * (1 + 0.0333 * reps)
      return targetE1RM / (1 + 0.0333 * totalReps);
    }
  }

  static double reverseCalculateReps({
    required double targetE1RM,
    required double weight,
    required double baseWeight,
    double rir = 0.0,
    double? minReps,
  }) {
    if (weight <= 0) return 0;

    const double switchTotalReps = 25.0; // set this to your chosen cutoff
    final double ratio = targetE1RM / weight;

    // Brzycki implied total reps
    final double totalRepsBrzycki = 37.0 - (36.0 / ratio);

    double totalReps;
    if (totalRepsBrzycki.isFinite &&
        totalRepsBrzycki >= 1.0 &&
        totalRepsBrzycki <= switchTotalReps) {
      totalReps = totalRepsBrzycki;
    } else {
      // Epley implied total reps
      totalReps = (ratio - 1.0) / 0.0333;
    }

    double reps = totalReps - rir;

    if (minReps != null && weight < baseWeight && reps < minReps) {
      print(
        '⚠️ [BB2] Reps would drop below planned ($reps < $minReps) '
            'after weight decreased ($weight < $baseWeight). Locking to $minReps.',
      );
      reps = minReps;
    }

    return reps.clamp(1.0, 45.0);
  }




  static Map<String, dynamic> computeBaseE1RMFromHistory({
    required String exerciseName,
    required int repTarget,
    required double plannedRIR,
    List<Map<String, dynamic>>? topSetHistory,
    Map<String, dynamic>? maxWeightByReps,
    DateTime? now,
  }) {
    final DateTime _now = now ?? DateTime.now();
    final List<Map<String, dynamic>> raw =
        topSetHistory ?? topSetsByExercise[exerciseName] ?? const [];

    if (raw.isEmpty) {
      return {
        'baseE1RM': null,
        'baseSource': 'no_history',
        'nUsed': 0,
      };
    }

    // Build + sort newest → oldest
    final historyWithE1RM = raw.map((entry) {
      final double w   = (entry['weight'] as num?)?.toDouble() ?? 0.0;
      final double r   = (entry['reps']   as num?)?.toDouble() ?? 0.0;
      final double rir = (entry['rir']    as num?)?.toDouble() ?? 0.0;
      final DateTime? d = entry['date'] is DateTime
          ? entry['date'] as DateTime
          : DateTime.tryParse(entry['date']?.toString() ?? '');
      return {
        'weight': w,
        'reps': r,
        'rir': rir,
        'e1rm': calculateE1RM(w, r, rir),
        'effectiveReps': r + rir,
        'date': d,
      };
    }).toList()
      ..sort((a, b) {
        final ad = a['date'] as DateTime?;
        final bd = b['date'] as DateTime?;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad);
      });

    final double targetEff = repTarget + plannedRIR;

    Map<String, dynamic> result;

    // A) Recent match
    final recentMatch = historyWithE1RM.firstWhere(
          (e) {
        final DateTime? d = e['date'] as DateTime?;
        final double eff = e['effectiveReps'] as double;
        return d != null &&
            _now.difference(d).inDays <= 28 &&
            (eff - targetEff).abs() <= 0.5;
      },
      orElse: () => {},
    );
    if (recentMatch.isNotEmpty) {
      result = {
        'baseE1RM': recentMatch['e1rm'] as double,
        'baseSource': 'recent_match',
        'nUsed': 1,
        'usedSamples': [recentMatch],
      };
    } else {
      // B) 2-week average
      final recentTwoWeeks = historyWithE1RM.where((e) {
        final DateTime? d = e['date'] as DateTime?;
        return d != null && _now.difference(d).inDays <= 14;
      }).toList();
      if (recentTwoWeeks.isNotEmpty) {
        final sum = recentTwoWeeks.fold<double>(0.0, (acc, e) => acc + (e['e1rm'] as double));
        result = {
          'baseE1RM': sum / recentTwoWeeks.length,
          'baseSource': 'two_week_avg',
          'nUsed': recentTwoWeeks.length,
          'usedSamples': recentTwoWeeks,
        };
      }
      // C) Last-4 average
      else if (historyWithE1RM.length >= 4) {
        final last4 = historyWithE1RM.take(4).toList();
        final sum = last4.fold<double>(0.0, (acc, e) => acc + (e['e1rm'] as double));
        result = {
          'baseE1RM': sum / 4.0,
          'baseSource': 'last4_avg',
          'nUsed': 4,
          'usedSamples': last4,
        };
      }
      // D) 1–3 entries: average what we have
      else if (historyWithE1RM.isNotEmpty) {
        final n = historyWithE1RM.length;
        final takeN = historyWithE1RM.take(n).toList();
        final sum = takeN.fold<double>(0.0, (acc, e) => acc + (e['e1rm'] as double));
        result = {
          'baseE1RM': sum / n,
          'baseSource': 'recent_any_avg',
          'nUsed': n,
          'usedSamples': takeN,
        };
      }
      // E) Fallback
      else if (maxWeightByReps != null) {
        final double fallback = (maxWeightByReps['weight'] as num?)?.toDouble() ?? 0.0;
        result = {
          'baseE1RM': fallback > 0 ? fallback : null,
          'baseSource': fallback > 0 ? 'maxWeightByReps' : 'no_history',
          'nUsed': fallback > 0 ? 1 : 0,
          'usedSamples': [],
        };
      } else {
        result = {
          'baseE1RM': null,
          'baseSource': 'no_history',
          'nUsed': 0,
          'usedSamples': [],
        };
      }
    }

    // 🔍 Single final print
    print('🔍 [BaseE1RM] ex=$exerciseName '
        'targetEff=${targetEff.toStringAsFixed(1)} '
        'branch=${result['baseSource']} nUsed=${result['nUsed']} '
        'samples=${(result['usedSamples'] as List).map((e) => "${e['date']} ${e['weight']}×${e['reps']}@${e['rir']} e1rm=${(e['e1rm'] as double).toStringAsFixed(1)}").toList()} '
        '→ final=${(result['baseE1RM'] as double?)?.toStringAsFixed(1)}');

    return result;
  }


  static String resolveExerciseName(String key) {
    return idToName[key] ?? key;
  }

  // ✅ ID-based lookup (fastest and most reliable)
  static const Map<String, bool> _bwById = {
    // --- Core existing ---
    'XM9026peNIu0R8qh7UqY': true, // Chin-Up
    'RFyjAjezFs8Rf7CQoaXz': true, // Pull-Up
    'KPewxxYYrhsOp84lIQr5': true, // Suspended High Row

    // --- New additions ---
    'YrwqLg6c9CJLu7yfLYn0': true, // Alternating Plank
    'BpO7e9KsDJsvwhfo09uU': true, // Hanging Knee Raise (🔸 needs weighting factor)
    'P88Vj5pBydqmiEzFowag': true, // Hanging Straight Leg Raise (🔸 needs weighting factor)
    '8CIXN12uS2xwF4JzVLq3': true, // Long Lever Plank
    'xU7MNEvnaoSwz5jy3uHw': true, // Plank
    '63ryIPxgXVPX7jLtAecC': true, // Pull-Up, Wide Arm
    'jSC34DLH5C7t9jH0pWfo': true, // Push Up Off Bench
    'pJQaGJlTAOoyZ8TyEmrY': true, // Push Up, Banded
    '0P4ECDHtfF7oKExmNhbN': true, // Push Up, Decline
    'Da2xWZqbeCsbGCwdbwbs': true, // Push Up, Deficit
    'EFbQl9i9NdYi13F3DqHr': true, // Push Up, Suspended
    '0YNV3P4D7QaN6xLI9lo8': true, // Push Up, Weighted
    '0d1HmQpwesdOESqoQHBq': true, // Russian Twist
    'Ei4x9i5mirIUdMxWKZCk': true, // Side Plank
    'iPaRtXsLXcXHQg5vmVA0': true, // Suspended Fly
    'oiQ7EJsGLgJG3Sx9m2sB': true, // Suspended High Row, Unilateral
    'PXqhBA8ib7FWAcPjDlES': true, // Suspended Leg Curl
    '7gc2YEj9ZQe6A0kr5NcX': true, // Suspended Leg Curl, Unilateral
    'mJKwE9Fc2opMiiy7yUFt': true, // Suspended Reverse Fly
    '9Oovma2yszjmSm420awp': true, // Suspended Triceps Extension
    'jRDb5LbN9e7PyiQMQcPn': true, // Suspended Triceps Extension, Unilateral
    'FtayDmR5BVnGS1FXlXLL': true, // Triceps Dip
    'lGaQiv5BwE1H5eJSkesj': true, // Weighted Long Lever Plank
    'DTkkN5pi05RWQyNYhizQ': true, // Weighted Plank
    'wrCwLDvwMYAgQtoiaJTh': true, // Weighted Push Up, Deficit

  };


  static Future<void> loadPeriodizationModelsFromFirestore({String? uid}) async {
    final resolvedUid = uid ?? FirebaseAuth.instance.currentUser!.uid;
    print('📦 [PMU] Loading periodization models for UID: $resolvedUid');

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(resolvedUid)
        .collection('block_planner')
        .doc('current_block')
        .get();

    final data = snapshot.data();
    if (data == null || !data.containsKey('plannedExerciseDetails')) return;

    final Map<String, dynamic> details = Map<String, dynamic>.from(data['plannedExerciseDetails']);
    exercisePeriodizationModels.clear();

    details.forEach((id, entry) {
      final modelStr = entry['periodizationModel'] as String?;
      if (modelStr != null) {
        final model = _parseModelFromString(modelStr);
        exercisePeriodizationModels[id] = model;
      }
    });
  }

  static PeriodizationModelType _parseModelFromString(String model) {
    switch (model) {
      case 'DUP, Signature':
        return PeriodizationModelType.dupSignature;
      case 'DUP, By Week':
        return PeriodizationModelType.dailyUndulatingWeek;
      case 'Linear, Classic':
        return PeriodizationModelType.linearClassic;
      case 'Linear, by Exposure':
        return PeriodizationModelType.linearExposure;
      case 'DUP, By Exposure':
        return PeriodizationModelType.dailyUndulatingExposure;
      default:
        return PeriodizationModelType.dupSignature;
    }
  }


  static Future<int> getBlockLengthFromFirestore(String userId) async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('block_planner')
          .doc('current_block')
          .get();

      if (!snapshot.exists) return 12;

      final data = snapshot.data()!;
      final start = DateTime.tryParse(data['blockStartDate'] ?? '');
      final end = DateTime.tryParse(data['blockEndDate'] ?? '');

      if (start == null || end == null) return 12;

      final length = ((end.difference(start).inDays + 6) ~/ 7); // round up
      return length;
    } catch (e) {
      print('⚠️ Error getting block length: $e');
      return 12;
    }
  }

  static int getBlockLength({
    required DateTime? blockStartDate,
    required DateTime? blockEndDate,
  }) {
    if (blockStartDate == null || blockEndDate == null) return 12;
    return ((blockEndDate.difference(blockStartDate).inDays + 6) ~/ 7);
  }


  // BodyWeight Exercises Block begins...

// fallback by normalized name (lowercase, hyphens kept)
  // ✅ Name-based fallback (lowercased and trimmed)
  static const Map<String, bool> _bwByName = {
    // --- Core existing ---
    'chin-up': true,
    'pull-up': true,
    'suspended high row': true,

    // --- New additions ---
    'alternating plank': true,
    'hanging knee raise': true, // 🔸 needs weighting factor
    'hanging straight leg raise': true, // 🔸 needs weighting factor
    'long lever plank': true,
    'plank': true,
    'pull-up, wide arm': true,
    'push up off bench': true,
    'push up, banded': true,
    'push up, decline': true,
    'push up, deficit': true,
    'push up, suspended': true,
    'push up, weighted': true,
    'russian twist': true,
    'side plank': true,
    'suspended fly': true,
    'suspended high row, unilateral': true,
    'suspended leg curl': true,
    'suspended leg curl, unilateral': true,
    'suspended reverse fly': true,
    'suspended triceps extension': true,
    'suspended triceps extension, unilateral': true,
    'triceps dip': true,
    'weighted long lever plank': true,
    'weighted plank': true,
    'weighted push up, deficit': true,

  };

  static bool isBodyweightExercise({String? id, String? name}) {
    if (id != null && _bwById[id] == true) return true;
    if (name != null) {
      final n = name.trim().toLowerCase();
      if (_bwByName[n] == true) return true;
    }
    return false;
  }

  // 2) Latest BW cache (set once by WES/BB2 on load)
  static final Map<String, double> _latestBwByUid = {};
  static final Map<String, DateTime> _latestBwDateByUid = {};
// 2b) Full BW history cache (sorted descending by date)
  static final Map<String, List<Map<String, dynamic>>> _bwHistoryByUid = {};

  /// Call once whenever you (re)fetch the user's weights from Firestore.
  /// Expect entries like: {'date': DateTime, 'weight': double, 'unit': 'kg'}
  static void setBodyweightHistory({
    required String uid,
    required List<Map<String, dynamic>> entries,
  }) {
    // keep only kg for now
    final filtered = entries
        .where((e) => (e['weight'] != null) && (e['unit'] == 'kg'))
        .map((e) => {
      'date': (e['date'] as DateTime),
      'weight': (e['weight'] as num).toDouble(),
    })
        .toList();

    // sort DESC by date (newest first)
    filtered.sort((a, b) => (b['date'] as DateTime).compareTo(a['date'] as DateTime));
    _bwHistoryByUid[uid] = filtered;

    // keep the existing "latest" cache in sync (used when asOf is null)
    if (filtered.isNotEmpty) {
      _latestBwByUid[uid] = filtered.first['weight'] as double;
      _latestBwDateByUid[uid] = filtered.first['date'] as DateTime;
    }
  }
  /// WES/BB2 should call this once after they fetch the newest weigh-in.
  static void setLatestBodyweight({
    required String uid,
    required double weightKg,
    required DateTime asOf,
  }) {
    _latestBwByUid[uid] = weightKg;
    _latestBwDateByUid[uid] = asOf;
  }

  /// Gets the newest known BW for uid; falls back to 80 kg if unknown.
  static double latestBodyweightKg({required String uid}) {
    return _latestBwByUid[uid] ?? 80.0;
  }

  // 3) Conversions (display <-> absolute). Date not needed since we use "most recent".
  static double toAbsoluteWeight({
    required String uid,
    required double displayAddedKg,
    String? exerciseId,
    String? exerciseName,
    DateTime? asOfDate, // ⬅️ new
  }) {
    if (!isBodyweightExercise(id: exerciseId, name: exerciseName)) {
      return displayAddedKg;
    }
    final bw = bodyweightKgForDate(uid: uid, asOf: asOfDate);
    // "0" means BW only; no negatives allowed
    return (displayAddedKg <= 0) ? bw : (bw + displayAddedKg);
  }

  static double toDisplayAddedWeight({
    required String uid,
    required double absoluteKg,
    String? exerciseId,
    String? exerciseName,
    DateTime? asOfDate, // ⬅️ new
  }) {
    if (!isBodyweightExercise(id: exerciseId, name: exerciseName)) {
      return absoluteKg;
    }
    final bw = bodyweightKgForDate(uid: uid, asOf: asOfDate);

    final added = absoluteKg - bw;
    return (added < 0) ? 0.0 : added;
  }

  /// Normal E1RM for math. For UI: if BW exercise, show "how much I could add for 1 rep".
  static double e1rmForDisplay({
    required String uid,
    required double absoluteKg,
    required int reps,
    required double rir,
    String? exerciseId,
    String? exerciseName,
    DateTime? asOfDate, // ⬅️ new
  }) {
    final e = calculateE1RM(absoluteKg, reps.toDouble(), rir);
    if (!isBodyweightExercise(id: exerciseId, name: exerciseName)) return e;
    final bw = bodyweightKgForDate(uid: uid, asOf: asOfDate);
    final addOnly = e - bw;
    return (addOnly < 0) ? 0.0 : addOnly;
  }

  /// If asOf is provided, return BW valid for that date.
  /// Otherwise fallback to the latest known BW.
  /// If asOf is provided, return BW valid for that date (latest entry <= asOf end-of-day).
  /// Otherwise fallback to the latest known BW (or 80.0).
  static double bodyweightKgForDate({
    required String uid,
    DateTime? asOf,
  }) {
    final latest = _latestBwByUid[uid];
    if (asOf == null) {
      return latest ?? 80.0;
    }

    final history = _bwHistoryByUid[uid];
    if (history == null || history.isEmpty) {
      // no history loaded yet → behave like before
      final latestDate = _latestBwDateByUid[uid];
      if (latest != null && latestDate != null && !latestDate.isAfter(asOf)) {
        return latest;
      }
      return 80.0;
    }

    // end-of-day cutoff so a weigh-in on the same date counts
    final dayEnd = DateTime(asOf.year, asOf.month, asOf.day, 23, 59, 59);

    // history is newest-first; find first entry with date <= cutoff
    for (final e in history) {
      final d = e['date'] as DateTime;
      if (!d.isAfter(dayEnd)) {
        return (e['weight'] as num).toDouble();
      }
    }

    // all entries are after the cutoff → we had no earlier weigh-in
    return 80.0;
  }



  //...bodyweight exercise block ends

  static Map<String, Map<String, String>> getDefaultReps(
      PeriodizationModelType model, int frequency) {
    final Map<String, Map<String, String>> result = {};

    switch (model) {
      case PeriodizationModelType.dailyUndulatingExposure:
      // 🧠 New Daily Undulating – by *week* → repeats weekly
        const pattern = [10, 5, 8, 1, 12, 4, 6];
        final reps = List.generate(frequency, (i) => pattern[i % pattern.length]);
        result['week1'] = {
          for (int i = 0; i < reps.length; i++) 'instance${i + 1}': '${reps[i]} x 3'
        };
        break;

      case PeriodizationModelType.linearClassic:
      // 📉 Linear – by *week* → weekly drop in reps, set 1 week only, rest computed later
        final weekly = [12, 10, 8, 6, 4, 2]; // Can expand to 12 later
        result['week1'] = {
          for (int i = 0; i < frequency; i++)
            'instance${i + 1}': '${weekly[0]} x 3' // Week 1 reps only
        };
        break;

      case PeriodizationModelType.linearExposure:
      // 🪜 Linear – by *exposure* → full rep sequence worked through in order
        final reps = List.generate(
            frequency * 12, (i) => (12 - (i ~/ frequency)).clamp(4, 12));
        result['week1'] = {
          for (int i = 0; i < frequency; i++) 'instance${i + 1}': '${reps[i]} x 3'
        };
        break;

      case PeriodizationModelType.dupSignature:
      // 🧬 Signature → exposure-style, but with fixed range
        const min = 6;
        const max = 12;
        final reps = List.generate(frequency, (i) => min + i % (max - min + 1));
        result['week1'] = {
          for (int i = 0; i < reps.length; i++) 'instance${i + 1}': '${reps[i]} x 3'
        };
        break;

      case PeriodizationModelType.dailyUndulatingWeek:
      // 🧱 Default fallback – safe pattern
        result['week1'] = {
          for (int i = 0; i < frequency; i++) 'instance${i + 1}': '10 x 3'
        };
        break;
    }

    return result;
  }

// Rep Target Logic

  static PeriodizationModelType stringToModel(String modelName) {
    switch (modelName) {
      case 'Linear Exposure':
      case 'Linear, by Exposure':
        return PeriodizationModelType.linearExposure;

      case 'Linear, Classic':
        return PeriodizationModelType.linearClassic;

      case 'DUP, Custom':
      case 'DUP, By Week':
        return PeriodizationModelType.dailyUndulatingWeek;

      case 'DUP, Signature':
        return PeriodizationModelType.dupSignature;

      case 'Daily Undulating Periodization':
      case 'DUP, By Exposure':
        return PeriodizationModelType.dailyUndulatingExposure;

      default:
        return PeriodizationModelType.dupSignature;
    }
  }

  static int getLinearClassicRepTarget({
    required String exerciseId,
    required int weekIndex,
    required int plannedIndex,
    required Map<String, dynamic> repTargetsByExercise,
  }) {
    print('🧪 [LC] Target for $exerciseId @ week $weekIndex, index $plannedIndex');

    final repsMap = repTargetsByExercise[exerciseId]?['repTargets'];
    if (repsMap == null || repsMap is! Map<String, dynamic>) {
      print('⚠️ [LC] No repTargets map found for $exerciseId');
      return 10;
    }

    final weekKey = 'week${weekIndex + 1}';
    final weekData = repsMap[weekKey];

    if (weekData == null) {
      print('⚠️ [LC] No repTargets for $weekKey');
      return 10;
    }

    // New structure: Map<String, String> → { instance1: "10 x 3", instance2: "8 x 4", ... }
    if (weekData is Map<String, dynamic>) {
      final instanceKey = 'instance${plannedIndex + 1}';
      final raw = weekData[instanceKey];
      print('🧪 [LC] [Map Mode] week = $weekKey → $instanceKey = $raw');
      if (raw is String) {
        final match = RegExp(r'^(\d+)').firstMatch(raw);
        return match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;
      } else {
        print('❌ [LC] Missing or invalid string at $weekKey → $instanceKey');
        return 10;
      }
    }

    // Legacy fallback: weekData is a List<String>
    if (weekData is List) {
      List<String> normalized = [];

      if (weekData.length == 1 && weekData.first is String && weekData.first.contains(',')) {
        normalized = weekData.first.split(',').map((s) => s.trim()).toList();
        print('🛠️ [LC] Normalized from single comma string → $normalized');
      } else if (weekData.first is String) {
        normalized = List<String>.from(weekData);
        print('📦 [LC] Legacy list normalized → $normalized');
      } else {
        print('❌ [LC] Unexpected inner type in legacy list: ${weekData.first.runtimeType}');
        return 10;
      }

      if (plannedIndex >= normalized.length) {
        print('⚠️ [LC] Index $plannedIndex out of range for week $weekKey → returning default 10');
        return 10;
      }

      final raw = normalized[plannedIndex]; // safe now
      final match = RegExp(r'^(\d+)').firstMatch(raw);
      return match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;
    }

    print('❌ [LC] weekData not recognized → $weekData (${weekData.runtimeType})');
    return 10;
  }


  static int getLinearExposureRepTarget({
    required String exerciseId,
    required int exposureIndex,
    required Map<String, dynamic> repTargetsByExercise,
    required Map<String, dynamic> plannedExerciseDetails,
  }) {
    print('🧪 [Exposure] Looking up $exerciseId at instance $exposureIndex');

    final repsData = plannedExerciseDetails[exerciseId]?['repTargets'];

    if (repsData == null) {
      print('⚠️ [LE] No repTargets found for $exerciseId');
      return 10;
    }

    List<String> flatList = [];

    if (repsData is Map) {
      final sortedWeeks = repsData.keys.toList()..sort();
      for (final week in sortedWeeks) {
        final weekData = repsData[week];
        if (weekData is Map) {
          final sortedInstances = weekData.keys.toList()..sort();
          for (final instance in sortedInstances) {
            final value = weekData[instance];
            if (value is String) {
              flatList.add(value);
            } else if (value is List) {
              flatList.addAll(value.map((e) => e.toString()));
            }
          }
        } else if (weekData is List) {
          flatList.addAll(List<String>.from(weekData));
        }
      }
    }


    if (flatList.isEmpty) {
      print('⚠️ [LE] Rep target list empty for $exerciseId');
      return 10;
    }

    print('📈 LinearExposure → ${flatList.join(', ')}');

    final clampedIndex = exposureIndex.clamp(0, flatList.length - 1);
    final raw = flatList[clampedIndex]; // ✅ this now pulls a *single* string
    print('📊 LinearExposure [index $exposureIndex] → "$raw"');

    final match = RegExp(r'^(\d+)').firstMatch(raw);
    final parsed = match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;
    print('📊 LinearExposure → $parsed reps');
    return parsed;
  }



  static int getSuggestedRepTargetByModel({
    required String exerciseName,
    required int plannedIndex,
    String? weightText,
    String? rirText,
    int? weekIndex,
    DateTime? selectedDate,          // ⬅️ ADD THIS
    DateTime? blockStartDate,
    DateTime? blockEndDate,
    Map<String, dynamic>? repTargetsByExercise,
    Map<String, dynamic>? plannedExerciseDetails,
  }) {





    final model = exercisePeriodizationModels[exerciseName] ?? PeriodizationModelType.dupSignature;
    print('🧠 getSuggestedRepTargetByModel → $exerciseName using model: $model (plannedIndex: $plannedIndex)');

    try {
      switch (model) {
        case PeriodizationModelType.dailyUndulatingExposure:
          Map<String, dynamic>? exerciseEntry;
          if (repTargetsByExercise != null) {
            final entry = repTargetsByExercise[exerciseName];
            if (entry is Map<String, dynamic>) {
              exerciseEntry = entry;
            }
          }

          final repTargetsRaw = exerciseEntry; // 🔧 FIXED: no ['repTargets']
          final weekMap = repTargetsRaw is Map<String, dynamic>
              ? repTargetsRaw['week1'] as Map<String, dynamic>?
              : null;
          if (weekMap == null || weekMap.isEmpty) {
            return 10;
          }

          // Sort instance keys: instance1, instance2, ...
          final sortedInstances = weekMap.entries
              .where((e) => e.key.startsWith('instance'))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));

          final int frequency = sortedInstances.length;

          if (frequency == 0) {
            print('⚠️ [DUP By exposure] No instances found for $exerciseName');
            return 10;
          }

          // Loop through same week1 pattern each week based on plannedIndex
          final instanceIndex = plannedIndex % frequency;
          final instanceEntry = sortedInstances[instanceIndex];
          final raw = instanceEntry.value?.toString() ?? '';

          print('📦 [DUP By exposure] Using instance${instanceIndex + 1} = $raw');

          final match = RegExp(r'^(\d+)').firstMatch(raw);
          final parsed = match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;

          print('📈 [DUP By exposure] Parsed → $parsed reps (cycled instance ${instanceIndex + 1})');

          return parsed;


        case PeriodizationModelType.dupSignature:
        // ✅ Use REsignatureRepsByExercise with model-aware min/max range

          final range = getDupSignatureRepRange(exerciseName);
          final int min = range?['min'] ?? 2;
          final int max = range?['max'] ?? 10;

          final sequence = REsignatureRepsByExercise(
            exerciseName: exerciseName,
            min: min,
            max: max,
            count: 20,
          );

          final reps = sequence.length > plannedIndex ? sequence[plannedIndex] : min;
          print('🧪 Full sequence for $exerciseName → ${sequence.join(', ')}');

          print('🔮 DUP Signature (sequence-based) → $reps reps (index $plannedIndex)');
          return reps;



        case PeriodizationModelType.linearClassic:
          final repTargetsRaw =
          (repTargetsByExercise != null && repTargetsByExercise.containsKey(exerciseName))
              ? repTargetsByExercise[exerciseName]                          // ✅ use inner map
              : plannedExerciseDetails?[exerciseName]?['repTargets'];




          if (repTargetsRaw == null || repTargetsRaw is! Map<String, dynamic>) {
            print('⚠️ No rep targets found for $exerciseName');
            return 10;
          }

          final blockMeta = plannedExerciseDetails?['blockMeta'] as Map<String, dynamic>? ?? {};
          print('📎 blockMeta = ${jsonEncode(blockMeta)}');

          final start = DateTime.tryParse(blockMeta['blockStartDate'] ?? '');
          final end = DateTime.tryParse(blockMeta['blockEndDate'] ?? '');
          final blockLength = PeriodizationModelUtils.getBlockLength(
            blockStartDate: start,
            blockEndDate: end,
          );
          print('🧠 [LinearClassic] Calculated blockLength = $blockLength');

          final week1Raw = repTargetsRaw['week1'];
          final finalWeekRaw = repTargetsRaw['week$blockLength'];

          final week1 = week1Raw is Map ? Map<String, dynamic>.from(week1Raw) : {};
          final finalWeek = finalWeekRaw is Map ? Map<String, dynamic>.from(finalWeekRaw) : {};

          print('📆 week1 = ${jsonEncode(week1)}');
          print('📆 finalWeek = ${jsonEncode(finalWeek)}');

          final instanceKey = 'instance${plannedIndex + 1}';
          final week1Val = week1[instanceKey]?.toString();
          final finalVal = finalWeek[instanceKey]?.toString() ?? '1 x 3';

          print('🔑 Checking for key: $instanceKey');
          print('🧪 week1Val = $week1Val');
          print('🧪 finalVal = $finalVal');

          if (week1Val == null || finalVal == null) {
            print('❌ Missing instance data for $exerciseName → $instanceKey');
            return 10;
          }

          final matchStart = RegExp(r'^(\d+)').firstMatch(week1Val);
          final matchEnd = RegExp(r'^(\d+)').firstMatch(finalVal);

          final startReps = matchStart != null ? int.tryParse(matchStart.group(1)!) ?? 10 : 10;
          final endReps = matchEnd != null ? int.tryParse(matchEnd.group(1)!) ?? 1 : 1;

          final currentWeek = weekIndex ?? 0;
          final reps = (startReps + ((endReps - startReps) * (currentWeek / (blockLength - 1)))).round();

          print('📊 Interpolation context: start=$startReps, end=$endReps, blockLength=$blockLength, plannedIndex=$plannedIndex');
          print('🔍 Full interpolation map for $exerciseName ($instanceKey):');
          for (int i = 0; i < blockLength; i++) {
            final repsThisWeek = (startReps + ((endReps - startReps) * (i / (blockLength - 1)))).round();
            print('  Week ${i + 1}: $repsThisWeek reps');
          }

          print('📈 LinearClassic interpolated → $reps reps (week: $currentWeek, $instanceKey)');
          return reps;

        case PeriodizationModelType.linearExposure:
          final reps = getLinearExposureRepTarget(
            exerciseId: exerciseName,
            exposureIndex: plannedIndex,
            repTargetsByExercise: repTargetsByExercise ?? {},
            plannedExerciseDetails: plannedExerciseDetails ?? {},
          );
          print('📊 LinearExposure → $reps reps');
          return reps;

        case PeriodizationModelType.dailyUndulatingWeek: // Now used as DUP by Week
          final repTargetsRaw = repTargetsByExercise?[exerciseName]?['repTargets']
              ?? plannedExerciseDetails?[exerciseName]?['repTargets'];

          final weekKey = 'week1'; // ✅ Always use week1 for DUP by Week

          Map<String, dynamic>? weekMap;
          if (repTargetsRaw is Map<String, dynamic>) {
            weekMap = repTargetsRaw[weekKey] as Map<String, dynamic>?;
          }

          if (weekMap == null || weekMap.isEmpty) {
            print('⚠️ [DUP by Week] No usable data in $weekKey for $exerciseName');
            return 10;
          }

          final sortedInstances = weekMap.entries
              .where((e) => e.key.startsWith('instance'))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));

          final frequency = sortedInstances.length;
          if (frequency == 0) {
            print('⚠️ [DUP by Week] No instances found in $weekKey');
            return 10;
          }

          final indexInWeek = plannedIndex % frequency;
          final instanceEntry = sortedInstances[indexInWeek];
          final raw = instanceEntry.value?.toString() ?? '';

          print('📦 [DUP by Week] $weekKey → instance${indexInWeek + 1} = $raw');

          final match = RegExp(r'^(\d+)').firstMatch(raw);
          final parsed = match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;

          print('📈 [DUP by Week] Parsed → $parsed reps');
          return parsed;

      }
    } catch (e) {
      print('⚠️ Error in getSuggestedRepTargetByModel for $exerciseName: $e');
      return 10;
    }

    // 🛡️ Fallback to default
    return 10;
  }


  // RIR LOGIC

  static String? getSet1RirForExercise({
    required String exerciseId,
    required int weekNumber,
    required int sessionNumber,
  }) {
    final rirPlan = plannedExerciseDetails[exerciseId]?['rirPlan'];
    if (rirPlan == null) return null;

    final weekKey = 'week$weekNumber';
    final sessionKey = 'session$sessionNumber';
    final setKey = 'set1';

    return rirPlan[weekKey]?[sessionKey]?[setKey]?['rir'];
  }

  static String getSet1RirByModel({
    required String exerciseId,
    required int weekIndex,
    required int sessionIndex,
    required Map<String, dynamic> plannedExerciseDetails,
  }) {
    final rirPlan = plannedExerciseDetails[exerciseId]?['rirPlan'];
    if (rirPlan == null) return '0.5';

    final weekKey = 'week${weekIndex + 1}';
    final sessionKey = 'session${sessionIndex + 1}';
    final setKey = 'set1';

    final rir = rirPlan[weekKey]?[sessionKey]?[setKey]?['rir'];
    return rir?.toString() ?? '0.5';
  }

  // Weight Logic
  /// Default weight rules for when we have no usable history.
  /// - If type == "Barbell" AND name is Barbell Overhead Press → 10
  /// - Else if type == "Barbell" → 20
  /// - Else → 5
  static double _defaultWeightForExercise(String exerciseName) {
    {
      final type = _getExerciseTypeForName(exerciseName);
      final id = nameToId[exerciseName] ?? 'NO_ID';
      print('🔍 [PMU][TYPE CHECK] exercise="$exerciseName" | id="$id" | resolvedType="$type"');
    }

    final lowerName = exerciseName.toLowerCase().trim();
    final type = _getExerciseTypeForName(exerciseName);

    // 1️⃣ Most specific: Barbell Overhead Press → 10 kg
    if (type == 'Barbell' &&
        (lowerName == 'barbell overhead press' ||
            lowerName.contains('overhead press'))) {
      return 10.0;
    }

    // 2️⃣ Any other barbell exercise → 20 kg
    if (type == 'Barbell') {
      return 20.0;
    }

    // 3️⃣ Everything else → 5 kg
    return 5.0;
  }


  /// Lookup the exercise type (e.g. "Barbell") from our static maps.
  /// Falls back to name-based detection if we don't have a type yet.
  static String? _getExerciseTypeForName(String exerciseName) {
    final exerciseId = nameToId[exerciseName] ?? exerciseName;
    final type = exerciseTypeById[exerciseId];

    if (type != null && type.isNotEmpty) {
      return type;
    }

    // Fallback: infer from name if we have nothing stored
    final lower = exerciseName.toLowerCase();
    if (lower.contains('barbell')) return 'Barbell';

    return null;
  }


  static double getSuggestedWeightFromRep(String exerciseName, int reps, double rir) {
    // 1) Pull a unified base E1RM from history (no week-1 logic here)
    final info = computeBaseE1RMFromHistory(
      exerciseName: exerciseName,
      repTarget: reps,
      plannedRIR: rir,
    );
    final double? baseE1RM = info['baseE1RM'] as double?;

    if (baseE1RM == null || baseE1RM <= 0) {
      final fallback = _defaultWeightForExercise(exerciseName);
      print('🔻 [PMU] No history for "$exerciseName" '
          '— default weight = $fallback (type=${_getExerciseTypeForName(exerciseName)})');
      return fallback;
    }


    // 2) Convert E1RM → weight for the current plan
    final double suggestedWeight = reverseCalculateWeight(
      targetE1RM: baseE1RM,
      reps: reps,
      rir: rir,
    );

    // 3) Snap to valid increment for this exercise
    final double rounded = roundToNearestValidIncrement(
      targetWeight: suggestedWeight,
      exerciseName: exerciseName,
    );

    print('🧪 [BB2] Base E1RM for $exerciseName → ${baseE1RM.toStringAsFixed(2)} '
        '(source=${info['baseSource']})');
    print('🎯 [BB2] Rounded ${suggestedWeight.toStringAsFixed(2)} → '
        '${rounded.toStringAsFixed(1)} using custom increments');

    return rounded;
  }


  static void setExerciseSettings(Map<String, dynamic> settings) {

    _exerciseSettings = settings;
    print('✅ [PMU] setExerciseSettings called with keys: ${settings.keys}');
    final testId = 'AmfUWbF1DH3I7qPAdh5k';
    print('🔍 [PMU] Details for Bench ID ($testId): ${settings[testId]}');
  }

  static Map<String, dynamic> getExerciseSettings() => _exerciseSettings;

  static Map<String, dynamic> _exerciseSettings = {};

  static double roundToNearestValidIncrement({
    required double targetWeight,
    required String exerciseName,
  }) {

    dynamic incRaw = _exerciseSettings[exerciseName]?['increments'];
    final id = nameToId[exerciseName];

    print('🧾 [BB2] Details for ID $id → ${_exerciseSettings[id]}');

    // 👇 ADD THESE PRINTS (no logic change)

    if (_exerciseSettings[exerciseName]?['increments'] != null) {
      print('   ↳ byName increments: ${_exerciseSettings[exerciseName]?['increments']}');
    }
    if (id != null && _exerciseSettings.containsKey(id) && _exerciseSettings[id]?['increments'] != null) {
      print('   ↳ byId   increments: ${_exerciseSettings[id]?['increments']}');
    }

    if (incRaw == null && id != null && _exerciseSettings.containsKey(id)) {
      incRaw = _exerciseSettings[id]?['increments'];
    }

    if (incRaw == null) {
      // fallback to standard 2.5 if truly nothing saved
      return (targetWeight / 2.5).round() * 2.5;
    }

    Map<String, double> inc;
    if (incRaw is String) {
      // use the BP parser (already in Block_Planner)
      inc = Block_Planner.parseIncrements(incRaw);
    } else if (incRaw is Map) {
      final m = incRaw.map((k, v) => MapEntry(k.toString(), (v as num?)?.toDouble()));
      inc = {
        'primary': (m['primary'] ?? m['week'] ?? 2.5) ?? 2.5,
        'secondary': (m['secondary'] ?? m['block'] ?? 0.0) ?? 0.0,
        if (m['tertiary'] != null) 'tertiary': m['tertiary']!,
        if (m['quaternary'] != null) 'quaternary': m['quaternary']!,
      };
    } else {
      inc = {'primary': 2.5, 'secondary': 0.0};
    }

    final double primary = inc['primary']!;
    final double secondary = inc['secondary'] ?? 0.0;

    final Set<double> options = {};
    for (int i = 0; i < 100; i++) {
      options.add(i * primary); // ✅ Start from 0
    }
    bool useSecondary = secondary > 0 && secondary != primary;

    if (incRaw is Map) {
      final hasLegacy = incRaw.containsKey('week') || incRaw.containsKey('block');
      if ((hasLegacy && secondary == 1.0) || (secondary == 1.0 && primary != 2.5)) {
        useSecondary = false;

      } else if (useSecondary) {

      }
    }

    if (useSecondary) {
      for (final base in options.toList()) {
        options.add(base + secondary);
      }
    }



    final rounded = options.reduce((a, b) =>
    (a - targetWeight).abs() < (b - targetWeight).abs() ? a : b);



    return rounded;

  }

  static List<double> getIncrementsForExercise(String exerciseNameOrId) {
    dynamic incRaw = _exerciseSettings[exerciseNameOrId]?['increments'];


    final id = nameToId[exerciseNameOrId];
    if (incRaw == null && id != null && _exerciseSettings.containsKey(id)) {
      incRaw = _exerciseSettings[id]?['increments'];

    }

    if (incRaw == null) {
      return List.generate(100, (i) => 20 + i * 2.5); // fallback
    }

    Map<String, double> inc;
    if (incRaw is String) {
      inc = Block_Planner.parseIncrements(incRaw);
    } else if (incRaw is Map) {
      final m = incRaw.map((k, v) => MapEntry(k.toString(), (v as num?)?.toDouble()));
      inc = {
        'primary': (m['primary'] ?? m['week'] ?? 2.5) ?? 2.5,
        'secondary': (m['secondary'] ?? m['block'] ?? 0.0) ?? 0.0,
        if (m['tertiary'] != null) 'tertiary': m['tertiary']!,
        if (m['quaternary'] != null) 'quaternary': m['quaternary']!,
      };
    } else {
      inc = {'primary': 2.5, 'secondary': 0.0};
    }

    final double primary = inc['primary']!;
    final double secondary = inc['secondary'] ?? 0.0;


    final Set<double> weightOptions = {};
    for (int i = 0; i < 100; i++) {
      weightOptions.add(i * primary);
    }
    bool useSecondary = secondary > 0 && secondary != primary;

// Same guard against legacy/default-injected 1.0 with week/block keys
    // useSecondary was set above: secondary > 0 && secondary != primary
    if (incRaw is Map) {
      final hasLegacy = incRaw.containsKey('week') || incRaw.containsKey('block');
      final isDefaultGhost = (secondary == 1.0 && primary != 2.5);

      if ((hasLegacy && secondary == 1.0) || isDefaultGhost) {
        useSecondary = false;

      } else if (useSecondary) {

      }
    }

    if (useSecondary) {
      for (final base in weightOptions.toList()) {
        weightOptions.add(base + secondary);
      }
    }



    final list = weightOptions.toList()..sort();

    return list;

  }

  static List<double> roundToAllValidIncrements({
    required double baseWeight,
    required String exerciseName,
  }) {


    final increments = getIncrementsForExercise(exerciseName);


    final Set<double> options = {};

    for (int i = 0; i < 100; i++) {
      for (final inc in increments) {
        options.add(i * inc);
      }
    }

    final list = options.toList()..sort();

    // 🔎 ADD THIS: quick coverage + neighborhood check around baseWeight
    final min = list.isEmpty ? null : list.first;
    final max = list.isEmpty ? null : list.last;


    // nearest below / above to see rounding context
    final below = list.where((w) => w <= baseWeight).toList();
    final above = list.where((w) => w > baseWeight).toList();
    final nb = below.isNotEmpty ? below.last : null;
    final na = above.isNotEmpty ? above.first : null;


    return list;
  }

  static Map<String, double> incMapFromRaw(dynamic incRaw) {
    if (incRaw is String) {
      final parts = incRaw
          .split(',')
          .map((s) => double.tryParse(s.trim()))
          .whereType<double>()
          .toList();

      final m = <String, double>{};
      if (parts.isNotEmpty) m['primary'] = parts[0];
      if (parts.length > 1) m['secondary'] = parts[1];
      if (parts.length > 2) m['tertiary'] = parts[2];
      if (parts.length > 3) m['quaternary'] = parts[3];
      return m;
    }
    if (incRaw is Map) {
      final m = incRaw.map((k, v) => MapEntry(k.toString(), (v as num?)?.toDouble()));
      // prefer canonical keys; fall back to legacy week/block
      return <String, double>{
        if (m['primary'] != null) 'primary': m['primary']!,
        if (m['secondary'] != null) 'secondary': m['secondary']!,
        if (m['tertiary'] != null) 'tertiary': m['tertiary']!,
        if (m['quaternary'] != null) 'quaternary': m['quaternary']!,
        if (m['primary'] == null && m['week'] != null) 'primary': m['week']!,
        if (m['secondary'] == null && m['block'] != null) 'secondary': m['block']!,
      };
    }
    return {'primary': 2.5}; // absolute fallback
  }

  /// Expand a canonical increments map into a sorted list of valid weights.
  static List<double> expandIncrementOptions(Map<String, double> inc) {
    final primary = inc['primary'] ?? 2.5;
    final secondary = inc['secondary'] ?? 0.0;

    final opts = <double>{};
    for (int i = 0; i < 100; i++) opts.add(i * primary);
    if (secondary > 0 && secondary != primary) {
      for (final base in opts.toList()) opts.add(base + secondary);
    }
    final list = opts.toList()..sort();
    return list;
  }

  // ==== BEGIN: Shared plan inputs hash (Warmup + WES use the same) ====
  static String computePlanInputsHash({
    required List<Map<String, dynamic>> plannedExercises,           // WES rows to paint
    required Map<String, dynamic> plannedExerciseDetails,           // from Firestore (rirPlan, repTargets, increments, progressionModel, etc.)
    required DateTime? blockStartDate,
    required DateTime? blockEndDate,
    DateTime? selectedDate,
  }) {
    // Canonicalize minimal-but-sufficient inputs that affect hints.
    // IMPORTANT: Keep this exact field subset identical in Warmup & WES.

    String normName(String s) => s.trim().toLowerCase();

    final planLite = plannedExercises.map((e) {
      return {
        'name': normName((e['name'] ?? '').toString()),
        'circuitIndex': e['circuitIndex'] ?? 0,
      };
    }).toList();

    // Only serialize per-exercise bits Warmup uses for hinted values
    final detailsLite = <String, dynamic>{};
    plannedExerciseDetails.forEach((k, v) {
      if (k == 'blockMeta') return; // block meta is in its own fields below
      if (v is! Map) return;
      final m = v as Map;
      detailsLite[k] = {
        // These are the fields that affect reps/weight/RIR hints:
        if (m['progressionModel'] != null) 'progressionModel': m['progressionModel'],
        if (m['repTargets'] != null)       'repTargets': m['repTargets'],
        if (m['rirPlan'] != null)          'rirPlan': m['rirPlan'],
        if (m['increments'] != null)       'increments': m['increments'],
      };
    });

    final payload = {
      'plan': planLite,
      'details': detailsLite,
      'blockStartDate': blockStartDate?.toIso8601String(),
      'blockEndDate': blockEndDate?.toIso8601String(),
      // weekIndex matters whenever DUP by week or linear w/ week interpolation
      if (selectedDate != null && blockStartDate != null)
        'weekIndex': getWeekIndexForDate(selectedDate, blockStartDate),
    };

    final s = jsonEncode(payload);
    return sha1.convert(utf8.encode(s)).toString(); // import 'dart:convert' & 'package:crypto/crypto.dart'
  }
// ==== END: Shared plan inputs hash ====


  // Progression model logic

  // Linear Weight Increase (wiring aligned; guarantees numeric return)
  // Linear Weight Increase (wiring aligned; guarantees numeric return)
  // Linear Weight Increase — wired like Smart/AddReps, same name & return type
  static double getProgressedWeight({
    required String exerciseName,
    required int repTarget,
    required double defaultWeight,
    double rirValue = 0, // optional with default
    required List<double> increments,
    Map<String, dynamic>? maxWeightByReps,
    List<Map<String, dynamic>>? topSetHistory, // optional
    int weekIndex = 0,
  }) {
    // tiny helper so we ALWAYS return a number even if history has strings
    double _asDouble(dynamic x, {double fallback = 0.0}) {
      if (x is num) return x.toDouble();
      if (x is String) {
        final d = double.tryParse(x);
        if (d != null) return d;
      }
      return fallback;
    }

    print('🧠 [LinearAdded] Entered for $exerciseName '
        '(week $weekIndex, repTarget=$repTarget, baseWt=$defaultWeight)');

    // Week 1 short-circuit (same as Smart/AddReps)
    if (weekIndex == 0) {
      print('🕓 [LinearAdded] Week 1 → using base weight: $defaultWeight');
      return defaultWeight;
    }

    // Unified history/E1RM context (athlete/block/date aware, like Smart/AddReps)
    final baseInfo = PeriodizationModelUtils.computeBaseE1RMFromHistory(
      exerciseName: exerciseName,
      repTarget: repTarget,
      plannedRIR: rirValue,
      topSetHistory: topSetHistory,     // prefer router-provided history
      maxWeightByReps: maxWeightByReps,
      now: DateTime.now(),
    );

    final double? baseE1RMNullable = baseInfo['baseE1RM'] as double?;
    final String baseSource = (baseInfo['baseSource'] as String?) ?? 'no_history';
    print('🧭 [LinearAdded] Base source=$baseSource '
        'E1RM=${baseE1RMNullable?.toStringAsFixed(2)}');

    if (baseE1RMNullable == null) {
      if (maxWeightByReps != null &&
          (maxWeightByReps['reps'] == repTarget ||
              maxWeightByReps['reps'].toString() == repTarget.toString())) {
        final fallbackWeight = _asDouble(maxWeightByReps['weight'], fallback: defaultWeight);
        print('🪂 [LinearAdded] Using maxWeightByReps fallback → $fallbackWeight');
        print('🏁 [LinearAdded] Final weight=$fallbackWeight');
        return fallbackWeight;
      }
      print('🚫 [LinearAdded] No historical E1RM → defaultWeight=$defaultWeight');
      print('🏁 [LinearAdded] Final weight=$defaultWeight');
      return defaultWeight;
    }

    final double baseE1RM = baseE1RMNullable;

    // Top-set history (prefer param; else cache); sort desc by date
    List<Map<String, dynamic>> recentSets =
    (topSetHistory != null && topSetHistory.isNotEmpty)
        ? List<Map<String, dynamic>>.from(topSetHistory)
        : (PeriodizationModelUtils.topSetsByExercise[exerciseName] ?? []);
    recentSets.sort((a, b) {
      final aDate = a['date'] is DateTime
          ? a['date'] as DateTime
          : DateTime.tryParse('${a['date']}') ?? DateTime(2000);
      final bDate = b['date'] is DateTime
          ? b['date'] as DateTime
          : DateTime.tryParse('${b['date']}') ?? DateTime(2000);
      return bDate.compareTo(aDate);
    });
    print('🧾 [LinearAdded] recentSets=${recentSets.length} repTarget=$repTarget');
    if (recentSets.isNotEmpty) {
      final s0 = recentSets.first;
      print('🧾 [LinearAdded] head → w=${s0['weight']} r=${s0['reps']} date=${s0['date']}');
    }

    if (recentSets.isEmpty) {
      print('🚫 [LinearAdded] No top-set history → defaultWeight=$defaultWeight');
      print('🏁 [LinearAdded] Final weight=$defaultWeight');
      return defaultWeight;
    }

    // Valid increment grid (same helper Smart/AddReps use)
    final validWeights = roundToAllValidIncrements(
      baseWeight: defaultWeight,
      exerciseName: exerciseName,
    )..sort();

    // Optional: used-combo guard (weight×repTarget×rir)
    final usedCombos =
    PeriodizationModelUtils.getUsedWeightRepsRirTripletsForExercise(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
    );

    // Last weight actually used at target reps (if any)
    double weightUsed = defaultWeight;
    final atTarget = recentSets.firstWhere(
          (e) => (e['reps'] as num?)?.toInt() == repTarget,
      orElse: () => const {},
    );
    // NEW: show whether we actually matched a set at this repTarget
    print('🔎 [LinearAdded] atTarget.isNotEmpty=${atTarget.isNotEmpty} payload=${atTarget.isNotEmpty ? atTarget : '(none)'}');
    if (atTarget.isNotEmpty && atTarget['weight'] != null) {
      weightUsed = _asDouble(atTarget['weight'], fallback: defaultWeight);
    }

    // Your summarized previous reps at target
    final previousReps = PeriodizationModelUtils.exercisePreviousTopSetReps[exerciseName];

// Try summary list first; if missing, fall back to the actual recent set we already found.
    int? matchedReps;
    if (previousReps != null && previousReps.isNotEmpty) {
      final idx = previousReps.indexWhere((r) => r == repTarget);
      if (idx >= 0) {
        matchedReps = previousReps[idx];
      }
    }

// Fallback: if summary list didn’t have the rep, but history does at this target, use it.
    if (matchedReps == null && atTarget.isNotEmpty) {
      matchedReps = (atTarget['reps'] as num?)?.toInt();
      print('🧷 [LinearAdded] Fallback matchedReps from history entry → $matchedReps');
    }

// If still nothing, keep legacy fallback behavior
    if (matchedReps == null) {
      if (maxWeightByReps != null &&
          (maxWeightByReps['reps'] == repTarget ||
              maxWeightByReps['reps'].toString() == repTarget.toString())) {
        final w = _asDouble(maxWeightByReps['weight'], fallback: defaultWeight);
        print('🪂 [LinearAdded] No match; using maxWeightByReps → $w');
        print('🏁 [LinearAdded] Final weight = $w');
        return w;
      }
      print('🚨 [LinearAdded] No match for $repTarget reps → defaultWeight = $defaultWeight');
      print('🏁 [LinearAdded] Final weight = $defaultWeight');
      return defaultWeight;
    }




    final _lastDate = atTarget.isNotEmpty ? (atTarget['date'] ?? 'unknown') : 'none';
    print('🧾 [LinearAdded] Last @repTarget=$repTarget → ${weightUsed.toStringAsFixed(1)} kg (date=$_lastDate)');


    if (matchedReps >= repTarget) {
      double nextHigher = weightUsed;
      for (final option in validWeights) {
        if (option > weightUsed) {
          nextHigher = option;
          break;
        }
      }

      if (nextHigher == weightUsed) {
        final finalE1RM = calculateE1RM(weightUsed, repTarget.toDouble(), rirValue);
        print('🚧 [LinearAdded] No higher increment → stay $weightUsed '
            '(E1RM=${finalE1RM.toStringAsFixed(2)}, base=${baseE1RM.toStringAsFixed(2)})');
        print('🏁 [LinearAdded] Final weight=$weightUsed');
        return weightUsed;
      }

      // used-combo guard at the promotion candidate
      final promoKey = '${nextHigher.toStringAsFixed(1)}_${repTarget}_${rirValue.toStringAsFixed(1)}';
      if (usedCombos.contains(promoKey)) {
        print('⛔ [LinearAdded] Skipping used combo $promoKey → keep $weightUsed');
        final finalE1RM = calculateE1RM(weightUsed, repTarget.toDouble(), rirValue);
        print('🏁 [LinearAdded] Final weight=$weightUsed '
            '(E1RM=${finalE1RM.toStringAsFixed(2)}, base=${baseE1RM.toStringAsFixed(2)})');
        return weightUsed;
      }

      // If athlete has attempts at higher weight, apply original guard
      final higherAttempts = recentSets.where((entry) {
        final wNum = _asDouble(entry['weight'], fallback: double.nan);
        return wNum == nextHigher;
      }).toList();

      if (higherAttempts.isNotEmpty) {
        final bestRepsAtHigher = higherAttempts
            .map((e) => (e['reps'] as num?)?.toInt() ?? 0)
            .fold<int>(0, (a, b) => a > b ? a : b);

        if (bestRepsAtHigher < repTarget) {
          print('🔁 [LinearAdded] Progress reps at $nextHigher: $bestRepsAtHigher → ${bestRepsAtHigher + 1}');
          print('🏁 [LinearAdded] Final weight=$nextHigher');
          return nextHigher;
        } else {
          final nextNextHigher = roundToNearestValidIncrement(
            targetWeight: nextHigher + 0.1,
            exerciseName: exerciseName,
          );
          final ret = _asDouble(nextNextHigher, fallback: nextHigher);
          print('⬆️ [LinearAdded] Met at $nextHigher → promote to $ret');
          print('🏁 [LinearAdded] Final weight=$ret');
          return ret;
        }
      }

      print('✅ [LinearAdded] Target met → progress to $nextHigher');
      print('🏁 [LinearAdded] Final weight=$nextHigher');
      return nextHigher;

    }

    // Target not met: keep weight (your original behavior)
    if ((repTarget - matchedReps) <= 1) {
      print('➕ [LinearAdded] Close miss ($matchedReps/$repTarget) → keep $weightUsed');
    } else {
      print('⚠️ [LinearAdded] Missed badly ($matchedReps/$repTarget) → keep $weightUsed');
    }
    print('🏁 [LinearAdded] Final weight=$weightUsed');
    return weightUsed;
  }



  static Map<String, dynamic> smartProgressionModel({
    required String exerciseName,
    required int repTarget,
    required double defaultWeight,
    double rirValue = 0,
    required List<double> increments,
    Map<String, dynamic>? maxWeightByReps,
    List<Map<String, dynamic>>? topSetHistory,
    int weekIndex = 0,
  }) {
    print('🧠 [SmartProgression] Entered smartProgressionModel for $exerciseName (week $weekIndex, repTarget: $repTarget)');

    if (weekIndex == 0) {
      print('🧭 [SmartProgression] Base source = week1_short_circuit');
      print('🕓 Week 1 detected → progression disabled, using base weight: $defaultWeight');
      return {
        'weight': defaultWeight,
        'reps': repTarget,
      };
    }// [ADD PRINT] —— target eff reps + router increments snapshot
    print('🔢 [SP] targetEffReps(planned) = ${repTarget + rirValue} '
        '(reps=$repTarget + rir=$rirValue) '
        'routerIncrements(len=${increments.length} head=${increments.take(6).toList()})');


// 🔎 Unified history-based E1RM (no week-1 logic here)
    final baseInfo = PeriodizationModelUtils.computeBaseE1RMFromHistory(
      exerciseName: exerciseName,
      repTarget: repTarget,
      plannedRIR: rirValue,
      topSetHistory: topSetHistory,          // use what was passed in
      maxWeightByReps: maxWeightByReps,      // preserve your fallback
      now: DateTime.now(),
    );

// 👇 Define once
    final double? baseE1RMNullable = baseInfo['baseE1RM'] as double?;
    final String baseSource = (baseInfo['baseSource'] as String?) ?? 'no_history';
    final List<Map<String, dynamic>>? baseSamples =
    (baseInfo['samples'] as List?)?.cast<Map<String, dynamic>>();

// 👇 Then print
    print('🧭 [SP Base] source=$baseSource baseE1RM=${baseE1RMNullable?.toStringAsFixed(2)} '
        'samples=${baseSamples?.length ?? 0}');
    if (baseSamples != null) {
      for (final s in baseSamples.take(6)) {
        print('  • sample ${s['date']} → ${s['weight']}×${s['reps']} @RIR ${s['rir']} '
            '→ E1RM=${(s['e1rm'] as num?)?.toStringAsFixed(2)}');
      }
    }

    if (baseE1RMNullable == null) {
      print('🧭 [SmartProgression] Base source = $baseSource');

      return {
        'weight': defaultWeight,
        'reps': repTarget,
      };
    }

    final double baseE1RM = baseE1RMNullable;

    print('🧭 [SmartProgression] Base source = $baseSource');
    print(
        '🧷 [SmartProgression] Base E1RM selected → ${baseE1RM.toStringAsFixed(2)} '
            '(exercise=$exerciseName, week=$weekIndex, '
            'targetEffReps=${(repTarget + rirValue).toStringAsFixed(1)}, '
            'plannedRIR=${rirValue.toStringAsFixed(1)})'
    );

    final validWeights = roundToAllValidIncrements(
      baseWeight: defaultWeight,
      exerciseName: exerciseName,
    );

    // [ADD PRINT] —— are SP’s internal candidates consistent with router-provided increments near default?
    final bool _gridsDifferNearDefault = (() {
      if (validWeights.isEmpty || increments.isEmpty) return true;
      double nearest(List<double> xs, double t) =>
          xs.reduce((a,b)=> (a - t).abs() < (b - t).abs() ? a : b);
      final vNear = nearest(validWeights, defaultWeight);
      final rNear = nearest(increments,   defaultWeight);
      return (vNear - rNear).abs() > 0.01;
    })();


// 🎯 Center trials on the weight implied by baseE1RM at (repTarget, RIR),
// then snap to the nearest valid increment.
    final double implied = PeriodizationModelUtils.reverseCalculateWeight(
      targetE1RM: baseE1RM,
      reps: repTarget,
      rir: rirValue,
    );

// snap to nearest allowed weight
    final double centerWeight = validWeights.reduce((a, b) =>
    ((a - implied).abs() < (b - implied).abs()) ? a : b
    );
    final belowCW = validWeights.where((w) => w <= centerWeight).toList();
    final aboveCW = validWeights.where((w) => w >  centerWeight).toList();
    final nbCW = belowCW.isNotEmpty ? belowCW.last : null;
    final naCW = aboveCW.isNotEmpty ? aboveCW.first : null;
    print('🎯 [SP] center=${centerWeight.toStringAsFixed(1)} '
        '(implied=${implied.toStringAsFixed(1)}) '
        'neigh: below=$nbCW above=$naCW');


    print('🎯 [SmartProgression] Centering trials on '
        '${centerWeight.toStringAsFixed(1)} kg '
        '(implied=${implied.toStringAsFixed(1)}, '
        'default=${defaultWeight.toStringAsFixed(1)})');




    final usedCombos = PeriodizationModelUtils.getUsedWeightRepsRirTripletsForExercise(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
    );

    double bestWeight = defaultWeight;
    int bestReps = repTarget;
    double bestE1RM = baseE1RM;
    double bestScore = double.infinity;

    final sortedWeights = validWeights
        .where((w) => (w - defaultWeight).abs() <= increments[0])
        .toList()
      ..sort((a, b) => (a - defaultWeight).abs().compareTo((b - defaultWeight).abs()));



    // Find the local spacing in validWeights around centerWeight (tolerant to float mismatch)
    int idx = validWeights.indexOf(centerWeight);
    if (idx < 0) {
      double minDiff = double.infinity;
      int nearestIdx = 0;
      for (int i = 0; i < validWeights.length; i++) {
        final d = (validWeights[i] - centerWeight).abs();
        if (d < minDiff) { minDiff = d; nearestIdx = i; }
      }
      idx = nearestIdx;
    }

    final int upIdx = (idx + 1 < validWeights.length) ? idx + 1 : idx;
    final int dnIdx = (idx - 1 >= 0) ? idx - 1 : idx;

    final double gapUp = validWeights[upIdx] - validWeights[idx];
    final double gapDn = validWeights[idx] - validWeights[dnIdx];

// Use the real local step (prefer upward gap if available)
    final double delta = (gapUp > 0) ? gapUp : (gapDn > 0 ? gapDn : 0);
    final double base = centerWeight;

    print('🧩 [SP] idx=$idx gapUp=${gapUp.toStringAsFixed(1)} gapDn=${gapDn.toStringAsFixed(1)} → delta=${delta.toStringAsFixed(1)}');


    final List<double> trialWeights = [
      base - delta,
      base,
      base + delta,
    ];




    final List<int> trialReps = [
      for (int d = -2; d <= 8; d++) (repTarget + d).clamp(1, 25),
    ];



    for (final w in trialWeights) {

      for (final r in trialReps) {
        final double trialE1RM = calculateE1RM(w, r.toDouble(), rirValue);
        final String comboKey = '${w.toStringAsFixed(1)}_${r}_${rirValue.toStringAsFixed(1)}';
        final double tryE1RM = calculateE1RM(w, r.toDouble(), rirValue);
        if (tryE1RM < baseE1RM) {
          continue;
        }
        final bool isUsed = usedCombos.contains(comboKey);
        final String tag = isUsed ? '⛔ used' : (trialE1RM < baseE1RM ? '⬇️ regressive' : '✅ valid');

      }
    }


    for (final w in trialWeights) {




      final Set<int> repTrials = {
        for (int d = -2; d <= 8; d++) (repTarget + d).clamp(1, 25),
      };

      for (final r in repTrials) {
        final comboKey = '${w.toStringAsFixed(1)}_${r}_${rirValue.toStringAsFixed(1)}';
        if (usedCombos.contains(comboKey)) {
          print('⛔ Skipping used combo: $comboKey');
          continue;
        }

        final double tryE1RM = calculateE1RM(w, r.toDouble(), rirValue);
        if (tryE1RM < baseE1RM) {

          continue;
        }

        final double e1rmIncrease = tryE1RM - baseE1RM;
        final double repDistance = (r - repTarget).abs().toDouble();
        final double weightDistance = (w - base).abs();


        // ✅ Hybrid scoring: prioritize smallest E1RM increase, but stay close to planned reps and weight
        final double score =
            (e1rmIncrease * 1.0) +       // primary: smallest valid increase
                (repDistance * 0.4) +        // valued: stay close to target reps
                (weightDistance * 0.05);     // slight preference for staying near defaultWeight




        if (score < bestScore) {
          bestScore = score;
          bestWeight = w;
          bestReps = r;
          bestE1RM = tryE1RM;
        }
      }
    }

    final comboKey = '${bestWeight.toStringAsFixed(1)}_${bestReps}_${rirValue.toStringAsFixed(1)}';
    print('🔍 Final comboKey = $comboKey');
    print('📘 Used combos: $usedCombos');

    print('🎯 Smart progression chosen: weight = $bestWeight, reps = $bestReps, RIR = $rirValue, projected E1RM = $bestE1RM (base = $baseE1RM)');
    print('🏁 Final decision: $bestWeight × $bestReps @ RIR $rirValue');
    print('📈 E1RM = ${bestE1RM.toStringAsFixed(2)} (Base = ${baseE1RM.toStringAsFixed(2)})');
    print('🧮 E1RM increase = ${(bestE1RM - baseE1RM).toStringAsFixed(2)}');

    print('🏁 ✅ [FINAL RETURN] Returning weight = $bestWeight × $bestReps');

    return {
      'weight': bestWeight,
      'reps': bestReps,
    };
  }



  static Map<String, dynamic> addRepsProgressionModel({
    required String exerciseName,
    required int repTarget,
    required double defaultWeight,
    double rirValue = 0,
    required List<double> increments,
    Map<String, dynamic>? maxWeightByReps,
    List<Map<String, dynamic>>? topSetHistory,
    int weekIndex = 0,
  }) {
    print('🧠 [AddRepsProgression] Entered for $exerciseName '
        '(week $weekIndex, repTarget=$repTarget, baseWt=$defaultWeight)');

    // 🕓 Week 1 short-circuit (base week)
    if (weekIndex == 0) {
      print('🕓 Week 1 detected → using base weight/reps');
      return {
        'weight': defaultWeight,
        'reps': repTarget,
      };
    }

    // 🧮 Unified E1RM context (same as Smart Progression)
    final baseInfo = PeriodizationModelUtils.computeBaseE1RMFromHistory(
      exerciseName: exerciseName,
      repTarget: repTarget,
      plannedRIR: rirValue,
      topSetHistory: topSetHistory,
      maxWeightByReps: maxWeightByReps,
      now: DateTime.now(),
    );

    final double? baseE1RMNullable = baseInfo['baseE1RM'] as double?;
    final String baseSource = (baseInfo['baseSource'] as String?) ?? 'no_history';

    print('🧭 [AddRepsProgression] Base source=$baseSource '
        'E1RM=${baseE1RMNullable?.toStringAsFixed(2)}');

    if (baseE1RMNullable == null) {
      print('🚫 No historical E1RM → fallback to base values');
      return {
        'weight': defaultWeight,
        'reps': repTarget,
      };
    }

    final double baseE1RM = baseE1RMNullable;

    // 🎯 Valid increment grid from planner context
    final validWeights = roundToAllValidIncrements(
      baseWeight: defaultWeight,
      exerciseName: exerciseName,
    )..sort();

    // 🔍 Avoid repeating identical combos
    final usedCombos =
    PeriodizationModelUtils.getUsedWeightRepsRirTripletsForExercise(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
    );

    // 🧾 Most recent performance
    final recentSets =
        PeriodizationModelUtils.topSetsByExercise[exerciseName] ?? [];
    if (recentSets.isEmpty) {
      print('🚫 No top-set history found → using default');
      return {'weight': defaultWeight, 'reps': repTarget};
    }

    recentSets.sort((a, b) {
      final aDate = a['date'] is DateTime
          ? a['date'] as DateTime
          : DateTime.tryParse(a['date']?.toString() ?? '') ?? DateTime(2000);
      final bDate = b['date'] is DateTime
          ? b['date'] as DateTime
          : DateTime.tryParse(b['date']?.toString() ?? '') ?? DateTime(2000);
      return bDate.compareTo(aDate);
    });

    final latest = recentSets.first;
    final double lastWeight =
        (latest['weight'] as num?)?.toDouble() ?? defaultWeight;
    final int lastReps = (latest['reps'] as num?)?.toInt() ?? repTarget;
    final double lastRIR =
        (latest['rir'] as num?)?.toDouble() ?? rirValue;

    print('📦 Last top set → $lastWeight kg × $lastReps @ RIR $lastRIR');

    final double currentE1RM =
    calculateE1RM(lastWeight, lastReps.toDouble(), lastRIR);
    print('📈 Current E1RM = ${currentE1RM.toStringAsFixed(2)} '
        '(base = ${baseE1RM.toStringAsFixed(2)})');

    // 🔍 Check if we’ve done target-rep work before
    final hasMatchingReps =
    recentSets.any((entry) => (entry['reps'] as num?)?.toInt() == repTarget);

    // === ORIGINAL Add-Reps logic from here on ===
    if (!hasMatchingReps) {
      final bool isNewTargetHigher = repTarget > lastReps;
      final double adjustedE1RM =
      isNewTargetHigher ? currentE1RM : currentE1RM * 0.96;

      final double estWeight = reverseCalculateWeight(
        targetE1RM: adjustedE1RM,
        reps: repTarget,
        rir: rirValue,
      );

      final valid = roundToAllValidIncrements(
        baseWeight: estWeight,
        exerciseName: exerciseName,
      )..sort();

      final below = valid.where((w) => w <= estWeight).toList();
      final above = valid.where((w) => w > estWeight).toList();

      double chosen = estWeight;
      if (above.isNotEmpty && (above.first - estWeight) < 0.3) {
        chosen = above.first;
      } else if (below.isNotEmpty) {
        chosen = below.last;
      }

      int adjustedReps = repTarget;
      double finalE1RM = calculateE1RM(chosen, adjustedReps.toDouble(), rirValue);
      while (finalE1RM < adjustedE1RM && adjustedReps < 20) {
        adjustedReps++;
        finalE1RM = calculateE1RM(chosen, adjustedReps.toDouble(), rirValue);
      }
      if (finalE1RM > adjustedE1RM && adjustedReps > 1) {
        adjustedReps--;
        finalE1RM = calculateE1RM(chosen, adjustedReps.toDouble(), rirValue);
      }

      final comboKey =
          '${chosen.toStringAsFixed(1)}_${adjustedReps}_${rirValue.toStringAsFixed(1)}';
      if (usedCombos.contains(comboKey)) {
        print('⛔ Combo already used → fallback to default');
        return {'weight': defaultWeight, 'reps': repTarget};
      }

      print('🎯 Final reverse-calc → $chosen kg × $adjustedReps '
          '(E1RM=${finalE1RM.toStringAsFixed(2)}, base=${baseE1RM.toStringAsFixed(2)})');
      return {'weight': chosen, 'reps': adjustedReps};
    }

    // Weight-increment progression path
    final int idx = validWeights.indexOf(lastWeight);
    final double? nextWeight =
    (idx >= 0 && idx + 1 < validWeights.length) ? validWeights[idx + 1] : null;

    if (nextWeight == null) {
      print('🚧 No higher weight → stay and +1 rep');
      return {'weight': lastWeight, 'reps': lastReps + 1};
    }

    final int repsAboveOG = lastReps - repTarget;
    List<int> allowed = [];
    if (repsAboveOG >= 2) allowed.add(repTarget);
    if (repsAboveOG >= 3) allowed.add(repTarget - 1);
    if (repsAboveOG >= 4) allowed.add(repTarget - 2);

    double? promotedW;
    int? promotedR;

    for (final reps in allowed) {
      if (reps < 1) continue;
      final double tryE1RM = calculateE1RM(nextWeight, reps.toDouble(), rirValue);
      final double threshold = tryE1RM * 1.040;
      if (currentE1RM >= threshold) {
        promotedW = nextWeight;
        promotedR = reps;
        break;
      }
    }

    if (promotedW != null && promotedR != null) {
      final comboKey =
          '${promotedW.toStringAsFixed(1)}_${promotedR}_${rirValue.toStringAsFixed(1)}';
      if (usedCombos.contains(comboKey)) {
        print('⛔ Duplicate combo detected, skipping promotion');
        return {'weight': lastWeight, 'reps': lastReps + 1};
      }

      print('✅ Promote → $promotedW kg × $promotedR '
          '(E1RM=${calculateE1RM(promotedW, promotedR.toDouble(), rirValue).toStringAsFixed(2)} '
          'vs base ${baseE1RM.toStringAsFixed(2)})');
      return {'weight': promotedW, 'reps': promotedR};
    }

    print('➕ Stay → $lastWeight kg × ${lastReps + 1}');
    return {'weight': lastWeight, 'reps': lastReps + 1};
  }


  static final Set<String> _velocityTrackedExercises = {
    // Bench press variants
    'bench press, barbell',
    'bench press, narrow grip',
    'bench press, larsen press',
    'bench press, long pause',
    'bench press, banded',
    'bench press, pin press',
    'bench press, touch n go',
    'incline press, barbell',

    // Deadlift variants
    'deadlift, conventional',
    'deadlift, sumo',

    // Squat variants
    'back squat, barbell',
    'back squat, low bar',
    'back squat, pin squat',
    'back squat, paused squat',
    'back squat, banded',
  };

  static bool isVelocityTracked(String exerciseName) {
    return _velocityTrackedExercises.contains(exerciseName.trim().toLowerCase());
  }


  static Map<String, dynamic> getWeightByProgressionModel({
    required ProgressionModelType model,
    required String exerciseName,
    required int repTarget,
    required double defaultWeight,
    required List<double> increments,
    Map<String, dynamic>? maxWeightByReps,
    List<Map<String, dynamic>>? topSetHistory,
    int weekIndex = 0,
    // 👇 You need to add this:
    double rirValue = 0,
    String debugOrigin = 'unknown', // 👈 add thi
  })
  {
// 🔎 Input snapshot (common to WES + Engine)
    final int _tsLen = topSetHistory?.length ?? 0;
    String _tsHead;
    if (_tsLen == 0) {
      _tsHead = '∅';
    } else {
      try {
        _tsHead = topSetHistory!
            .take(3)
            .map((s) => '${s['weight']}×${s['reps']}@${s['rir']}'
            '(${(s['date'] ?? '').toString().substring(0, 10)})')
            .join(', ');
      } catch (_) {
        _tsHead = '…';
      }
    }

// (Optional) add an origin tag; see step 2 below
    final _origin = (const bool.hasEnvironment('pmu_origin')) ? const String.fromEnvironment('pmu_origin') : 'unknown';

    print('🧪 [PMU Router/in] origin=$_origin '
        'ex="$exerciseName" wk=$weekIndex '
        'repTarget=$repTarget rir=$rirValue '
        'default=${defaultWeight.toStringAsFixed(2)} '
        'incs=${increments.length} head=${increments.take(6).toList()} '
        'topSets=$_tsLen [$_tsHead]');


    print('🧪 [PMU Router] model=$model repTarget=$repTarget '
        'defaultWeight=${defaultWeight.toStringAsFixed(2)} '
        'rirValue=$rirValue '
        'incLen=${increments.length} incHead=${increments.take(6).toList()} '
        'incIsSparse=${increments.length < 3}');

    switch (model) {
      case ProgressionModelType.linearWeightIncrease: {
        final result = <String, dynamic>{
          'weight': getProgressedWeight(
            exerciseName: exerciseName,
            repTarget: repTarget,
            defaultWeight: defaultWeight,
            increments: increments,
            maxWeightByReps: maxWeightByReps,
            topSetHistory: topSetHistory,
            weekIndex: weekIndex,
          ),
          'reps': repTarget, // preserve original repTarget for now
        };

        print('📦 [PMU Router] pre-overlay (linear) ${result['weight']} × ${result['reps']}');

        final target = (result['weight'] as num).toDouble();
        final snapped = (increments.isNotEmpty ? increments : [2.5]).reduce(
              (a, b) => (a - target).abs() < (b - target).abs() ? a : b,
        );


        print('🧲 [Overlay] (linear) ${result['weight']} → $snapped');

        result['weight'] = snapped;
        return result;
      }


      case ProgressionModelType.smartProgression: {
        final Map<String, dynamic> result = smartProgressionModel(
          exerciseName: exerciseName,
          repTarget: repTarget,
          defaultWeight: defaultWeight,
          increments: increments,
          maxWeightByReps: maxWeightByReps,
          topSetHistory: topSetHistory,
          weekIndex: weekIndex,
          rirValue: rirValue,
        );

        print('📦 [PMU Router] pre-overlay (smart) ${result['weight']} × ${result['reps']}');

        final target = (result['weight'] as num).toDouble();
        final snapped = (increments.isNotEmpty ? increments : [2.5]).reduce(
              (a, b) => (a - target).abs() < (b - target).abs() ? a : b,
        );


        print('🧲 [Overlay] (smart) ${result['weight']} → $snapped');

        result['weight'] = snapped;
        return result;
      }

      case ProgressionModelType.addRepsProgressionModel: {
        final Map<String, dynamic> result = addRepsProgressionModel(
          exerciseName: exerciseName,
          repTarget: repTarget,
          defaultWeight: defaultWeight,
          increments: increments,
          maxWeightByReps: maxWeightByReps,
          topSetHistory: topSetHistory,
          weekIndex: weekIndex,
          rirValue: rirValue,
        );

        print('📦 [PMU Router] pre-overlay (addReps) ${result['weight']} × ${result['reps']}');

        final target = (result['weight'] as num).toDouble();
        final snapped = (increments.isNotEmpty ? increments : [2.5]).reduce(
              (a, b) => (a - target).abs() < (b - target).abs() ? a : b,
        );


        print('🧲 [Overlay] (addReps) ${result['weight']} → $snapped');

        result['weight'] = snapped;
        return result;
      }


      case ProgressionModelType.none:
        return {
          'weight': defaultWeight,
          'reps': repTarget,
        };
    }
  }

  static ProgressionModelType parseProgressionModel(String? value) {
    switch (value?.trim()) {
      case 'Linear Weight Increase':
        return ProgressionModelType.linearWeightIncrease;
      case 'Smart Progression':
        return ProgressionModelType.smartProgression;
      case 'Add Reps': // ✅ Add label here
        return ProgressionModelType.addRepsProgressionModel;
      case 'None':
      default:
        return ProgressionModelType.none;
    }
  }




  static Map<String, Map<String, String>> expandDupDailyWeek1(
      Map<String, String> week1Map,
      int totalWeeks,
      ) {
    return {
      for (int w = 0; w < totalWeeks; w++)
        'week${w + 1}': Map<String, String>.from(week1Map)
    };
  }


  static double getDupSignatureSet2SuggestedReps({
    required double set2E1RM,
    required double? set1Reps,
    required String weightText,
    required String rirText,
  }) {
    final hasWeight = weightText.isNotEmpty;
    final weight = double.tryParse(weightText) ?? 0.0;
    final rir = double.tryParse(rirText) ?? 1.5; // Default for Set 2

    if (!hasWeight) {
      return ((set1Reps ?? 6) - 1).clamp(1, 200).toDouble(); // fallback
    }

    if (weight <= 0 || set2E1RM <= weight) {
      return 1.0;
    }

    final rawReps = (weight / set2E1RM < 0.85)
        ? ((set2E1RM / weight) - 1) / 0.0333
        : (37 - ((weight * 36) / set2E1RM));

    double finalReps = rawReps - rir;
    final decimalPart = finalReps - finalReps.floor();

    finalReps = (decimalPart >= 0.652)
        ? finalReps.ceil().toDouble()
        : finalReps.floor().toDouble();

    return finalReps.clamp(1.0, 200.0);
  }

  static double getSuggestedSet2RepsByModel({
    required String exerciseName,
    required double set2E1RM,
    required double? set1Reps,
    required String weightText,
    required String rirText,
  }) {
    final model = exercisePeriodizationModels[exerciseName] ?? PeriodizationModelType.dupSignature;

    switch (model) {
      case PeriodizationModelType.dailyUndulatingExposure:
        return 6.0;

      case PeriodizationModelType.dupSignature:
        return getDupSignatureSet2SuggestedReps(
          set2E1RM: set2E1RM,
          set1Reps: set1Reps,
          weightText: weightText,
          rirText: rirText,
        );
      case PeriodizationModelType.linearClassic:
        return 8.0; // or use a logic function like getLinearClassicRepTarget()
      case PeriodizationModelType.linearExposure:
        return 6.0; // or use a logic function like getLinearExposureRepTarget()

      case PeriodizationModelType.dailyUndulatingWeek:
        return 6.0;
    }
  }

  static double getDupSignatureSet3SuggestedReps({
    required double set3E1RM,
    required double? set2Reps,
    required String weightText,
    required String rirText,
  }) {
    final hasWeight = weightText.isNotEmpty;
    final weight = double.tryParse(weightText) ?? 0.0;
    final rir = double.tryParse(rirText) ?? 2.5; // Default for Set 3

    if (!hasWeight) {
      return ((set2Reps ?? 6) - 1).clamp(1, 200).toDouble(); // fallback
    }

    if (weight <= 0 || set3E1RM <= weight) {
      return 1.0;
    }

    final rawReps = (weight / set3E1RM < 0.85)
        ? ((set3E1RM / weight) - 1) / 0.0333
        : (37 - ((weight * 36) / set3E1RM));

    double finalReps = rawReps - rir;
    final decimalPart = finalReps - finalReps.floor();

    finalReps = (decimalPart >= 0.652)
        ? finalReps.ceil().toDouble()
        : finalReps.floor().toDouble();

    return finalReps.clamp(1.0, 200.0);
  }

  static double getSuggestedSet3RepsByModel({
    required String exerciseName,
    required double set3E1RM,
    required double? set2Reps,
    required String weightText,
    required String rirText,
  }) {
    final model = exercisePeriodizationModels[exerciseName] ?? PeriodizationModelType.dupSignature;

    switch (model) {
      case PeriodizationModelType.dailyUndulatingExposure:
        return 6.0;

      case PeriodizationModelType.dupSignature:
        return getDupSignatureSet3SuggestedReps(
          set3E1RM: set3E1RM,
          set2Reps: set2Reps,
          weightText: weightText,
          rirText: rirText,
        );
      case PeriodizationModelType.linearClassic:
        return 8.0; // or use a logic function like getLinearClassicRepTarget()
      case PeriodizationModelType.linearExposure:
        return 6.0; // or use a logic function like getLinearExposureRepTarget()

      case PeriodizationModelType.dailyUndulatingWeek:
        return 5.0;
    }
  }

  static double getDupSignatureSet1SuggestedWeight({
    required String exerciseName,
    required double reps,
    required double rir,
  }) {
    final e1rms = exercisePreviousE1RMs[exerciseName];
    if (e1rms == null || e1rms.isEmpty) return 20.0;

    final avgE1RM = getAverageE1RM(exerciseName);
    final effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      suggestedWeight = avgE1RM * (37 - effectiveReps) / 36;
    } else {
      suggestedWeight = avgE1RM / (1 + 0.0333 * effectiveReps);
    }

    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);
    return (suggestedWeight / 2.5).round() * 2.5;
  }


  static double getSuggestedSet1WeightByModel({
    required String exerciseName,
    required double reps,
    required double rir,
  }) {
    final model = exercisePeriodizationModels[exerciseName] ?? PeriodizationModelType.dupSignature;

    switch (model) {
      case PeriodizationModelType.dailyUndulatingExposure:
      case PeriodizationModelType.linearClassic:
      case PeriodizationModelType.linearExposure:
      case PeriodizationModelType.dupSignature:
      case PeriodizationModelType.dailyUndulatingWeek:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);
    }
  }



  static double getDupSignatureSet2SuggestedWeight({
    required double set2E1RM,
    required double reps,
    required double rir,
  }) {
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      suggestedWeight = set2E1RM * (37 - effectiveReps) / 36;
    } else {
      suggestedWeight = set2E1RM / (1 + (0.0333 * effectiveReps));
    }

    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);
    return (suggestedWeight / 2.5).round() * 2.5;
  }


  static double getSuggestedSet2WeightByModel({
    required String exerciseName,
    required double set2E1RM,
    required double reps,
    required double rir,
  }) {
    final model = exercisePeriodizationModels[exerciseName] ?? PeriodizationModelType.dupSignature;

    switch (model) {
      case PeriodizationModelType.dailyUndulatingExposure:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);


      case PeriodizationModelType.dupSignature:
        return getDupSignatureSet2SuggestedWeight(
          set2E1RM: set2E1RM,
          reps: reps,
          rir: rir,
        );
      case PeriodizationModelType.linearClassic:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);

      case PeriodizationModelType.linearExposure:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);

      case PeriodizationModelType.dailyUndulatingWeek:
        return 42.5;
    }
  }


  static double getDupSignatureSet3SuggestedWeight({
    required double set3E1RM,
    required double reps,
    required double rir,
  }) {
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      // ✅ Brzycki formula
      suggestedWeight = set3E1RM * (37 - effectiveReps) / 36;
    } else {
      // ✅ Epley formula
      suggestedWeight = set3E1RM / (1 + (0.0333 * effectiveReps));
    }

    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);
    return (suggestedWeight / 2.5).round() * 2.5;
  }

  static double getSuggestedSet3WeightByModel({
    required String exerciseName,
    required double set3E1RM,
    required double reps,
    required double rir,
  }) {
    final model = exercisePeriodizationModels[exerciseName] ?? PeriodizationModelType.dupSignature;

    switch (model) {
      case PeriodizationModelType.dailyUndulatingExposure:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);


      case PeriodizationModelType.dupSignature:
        return getDupSignatureSet3SuggestedWeight(
          set3E1RM: set3E1RM,
          reps: reps,
          rir: rir,
        );
      case PeriodizationModelType.linearClassic:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);

      case PeriodizationModelType.linearExposure:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);

      case PeriodizationModelType.dailyUndulatingWeek:
        return 45.0;
    }
  }


  static double getAverageE1RM(String exerciseName) {
    if (!exercisePreviousE1RMs.containsKey(exerciseName) || exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      return 0.0; // ✅ Default if no history
    }

    List<double> recentE1RMs = exercisePreviousE1RMs[exerciseName]!.take(4).toList();
    return recentE1RMs.reduce((a, b) => a + b) / recentE1RMs.length;
  }

  //Last two E1RM's combined
  static double getCombinedE1RM(String exerciseName) {
    if (!exercisePreviousE1RMs.containsKey(exerciseName) || exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      return 0.0; // ✅ Default if no history
    }

    // ✅ Get the last 2 E1RMs (or fewer if there aren't 2)
    List<double> recentE1RMs = exercisePreviousE1RMs[exerciseName]!.take(2).toList();

    // ✅ Sum them together
    return recentE1RMs.reduce((a, b) => a + b);
  }

  static int getThirdMostRecentTopSetReps(String exerciseName) {
    if (!exercisePreviousTopSetReps.containsKey(exerciseName) ||
        exercisePreviousTopSetReps[exerciseName]!.length < 6) {
      return 0; // ✅ Default to 0 if there aren’t enough past workouts
    }

    return exercisePreviousTopSetReps[exerciseName]![5]; // ✅ Index 2 = 3rd most recent
  }


  //Last set top set reps
  static int getLastTopSetReps(String exerciseName) {
    if (!exercisePreviousTopSetReps.containsKey(exerciseName) || exercisePreviousTopSetReps[exerciseName]!.isEmpty) {
      return 0; // ✅ Default to 0 if no history
    }

    // ✅ Get the last top set reps (most recent)
    return exercisePreviousTopSetReps[exerciseName]!.first;
  }

  static List<int> getAllStoredTopSetReps(String exerciseName) {
    if (!exercisePreviousTopSetReps.containsKey(exerciseName) ||
        exercisePreviousTopSetReps[exerciseName]!.isEmpty) {
      return []; // ✅ Return empty list if no data
    }

    return exercisePreviousTopSetReps[exerciseName]!; // ✅ Return full list of stored reps
  }

  // PeriodizationModelUtils.dart (or wherever it currently lives)
  static Future<void> fetchFullTopSetHistory({String? uid}) async {
    final resolvedUid = uid ?? FirebaseAuth.instance.currentUser!.uid;
    print('🧠 [SmartProgression] Fetching full top set history for $resolvedUid...');

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(resolvedUid)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(20)
        .get();



    topSetsByExercise.clear();

    for (var doc in snapshot.docs) {
      final workout = Workout.fromFirestore(doc);

      // pick ONE best set per exercise for this workout
      final Map<String, Map<String, dynamic>> bestByExercise = {};

      for (var ex in workout.exercises) {
        final String name = ex.name;

        for (var set in ex.sets) {
          final double weight = _parseToDouble(set.weight);
          final double reps   = _parseToDouble(set.reps);
          final double rir    = _parseToDouble(set.rir);
          if (weight <= 0 || reps <= 0) continue;

          final double e1rm = calculateE1RM(weight, reps, rir);
          final currentBest = bestByExercise[name];
          if (currentBest == null || e1rm > (currentBest['e1rm'] as double)) {
            bestByExercise[name] = {
              'weight': weight,
              'reps'  : reps,
              'rir'   : rir,
              'date'  : workout.date,
              'e1rm'  : e1rm,
            };
          }
        }
      }

      // append one top set per exercise for this workout
      for (final entry in bestByExercise.entries) {
        topSetsByExercise.putIfAbsent(entry.key, () => []);
        topSetsByExercise[entry.key]!.add({
          'weight': entry.value['weight'],
          'reps'  : entry.value['reps'],
          'rir'   : entry.value['rir'],
          'date'  : entry.value['date'],
        });
      }
    }

    // ensure newest → oldest
    for (final list in topSetsByExercise.values) {
      list.sort((a, b) {
        final ad = a['date'] as DateTime?;
        final bd = b['date'] as DateTime?;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad);
      });
    }

    print('✅ [SmartProgression] Loaded top sets for: ${topSetsByExercise.keys}');
  }


  //Warm Up Service Function for speed
  static void _applyTopSetsFromSnapshot(QuerySnapshot<Map<String, dynamic>> snapshot) {
    if (snapshot.docs.isEmpty) return;

    // ✅ Clear ONLY if new data exists
    if (exercisePreviousTopSetReps.isNotEmpty || exercisePreviousE1RMs.isNotEmpty) {
      exercisePreviousTopSetReps.clear();
      exercisePreviousE1RMs.clear();
    }

    for (var doc in snapshot.docs) {
      final data = doc.data();
      // print('🧪 [PMU] Processing workout → date: ${data['date']}, exercises: ${data['exercises']}');

      final workout = Workout.fromFirestore(doc);

      for (var exercise in workout.exercises) {
        String exerciseName = exercise.name;

        SetDetails? topSet;
        double highestE1RM = 0.0;

        for (var set in exercise.sets) {
          double weight = _parseToDouble(set.weight);
          double reps = _parseToDouble(set.reps);
          double rir = _parseToDouble(set.rir);
          double totalReps = reps + rir;

          double e1rm = (totalReps <= 6)
              ? (weight * (36 / (37 - totalReps))) // Brzycki
              : (weight * (1 + (0.0333 * totalReps))); // Epley

          if (topSet == null || e1rm > highestE1RM) {
            highestE1RM = e1rm;
            topSet = set;
          }
        }

        if (topSet != null) {
          int effectiveReps = (_parseToDouble(topSet.reps) + _parseToDouble(topSet.rir)).floor();

          exercisePreviousE1RMs.putIfAbsent(exerciseName, () => []);
          exercisePreviousE1RMs[exerciseName]!.add(highestE1RM);

          exercisePreviousTopSetReps.putIfAbsent(exerciseName, () => []);
          exercisePreviousTopSetReps[exerciseName]!.add(effectiveReps);

          // keep only last N
          if (exercisePreviousTopSetReps[exerciseName]!.length > 12) {
            exercisePreviousTopSetReps[exerciseName] =
                exercisePreviousTopSetReps[exerciseName]!.take(12).toList();
          }
          if (exercisePreviousE1RMs[exerciseName]!.length > 4) {
            exercisePreviousE1RMs[exerciseName] =
                exercisePreviousE1RMs[exerciseName]!.take(4).toList();
          }
        }
      }
    }

    // Optional debug
    // print('🧪 [PMU] Top set history fully loaded. Keys: ${exercisePreviousTopSetReps.keys.toList()}');
  }

  static Future<void> fetchLastWorkoutTopSetRepsCacheFirst({required String uid}) async {
    print('🧪 [PMU] (cache-first) Fetching top sets for: $uid');

    final query = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(12);

    // 1) Try cache (fast if warmed)
    try {
      final cacheSnap = await query.get(const GetOptions(source: Source.cache));
      if (cacheSnap.docs.isNotEmpty) {
        _applyTopSetsFromSnapshot(cacheSnap);

        // 2) Reconcile with server in background (non-blocking)
        unawaited(() async {
          try {
            try {
              final serverSnap = await query.get(const GetOptions(source: Source.server));
              _applyTopSetsFromSnapshot(serverSnap);
            } catch (e) {

            }

          } catch (_) {}
        }());
        return;
      }
    } catch (_) {
      // cache disabled/cold — fall through to server
    }

    // 3) Cold path: server
    final serverSnap = await query.get(const GetOptions(source: Source.server));
    _applyTopSetsFromSnapshot(serverSnap);
  }


  //Warm up Service functions end

  static Future<void> fetchLastWorkoutTopSetReps({String? uid}) async {
    final resolvedUid = uid ?? FirebaseAuth.instance.currentUser!.uid;
    print('🧪 [PMU] Fetching top sets for: $resolvedUid');

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(resolvedUid)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(12)
        .get();

    print('🧪 [PMU] Found ${snapshot.docs.length} workouts in Firestore.');

    if (snapshot.docs.isNotEmpty) {
      // ✅ Clear ONLY if new data exists
      if (exercisePreviousTopSetReps.isNotEmpty || exercisePreviousE1RMs.isNotEmpty) {
        exercisePreviousTopSetReps.clear();
        exercisePreviousE1RMs.clear();
      }


      for (var doc in snapshot.docs) {
        final data = doc.data();
        print('🧪 [PMU] Processing workout → date: ${data['date']}, exercises: ${data['exercises']}');

        final workout = Workout.fromFirestore(doc);

        for (var exercise in workout.exercises) {
          String exerciseName = exercise.name;

          SetDetails? topSet;
          double highestE1RM = 0.0;

          for (var set in exercise.sets) {
            double weight = _parseToDouble(set.weight);
            double reps = _parseToDouble(set.reps);
            double rir = _parseToDouble(set.rir);
            double totalReps = reps + rir;

            double e1rm = (totalReps <= 6)
                ? (weight * (36 / (37 - totalReps))) // Brzycki
                : (weight * (1 + (0.0333 * totalReps))); // Epley

            if (topSet == null || e1rm > highestE1RM) {
              highestE1RM = e1rm;
              topSet = set;
            }
          }

          if (topSet != null) {
            int effectiveReps = (_parseToDouble(topSet.reps) + _parseToDouble(topSet.rir)).floor();

            exercisePreviousE1RMs.putIfAbsent(exerciseName, () => []);
            exercisePreviousE1RMs[exerciseName]!.add(highestE1RM);

            // ✅ Always store the top set reps (no condition)
            exercisePreviousTopSetReps.putIfAbsent(exerciseName, () => []);
            exercisePreviousTopSetReps[exerciseName]!.add(effectiveReps);

// ✅ Ensure only last 12 are stored
            if (exercisePreviousTopSetReps[exerciseName]!.length > 12) {
              exercisePreviousTopSetReps[exerciseName] =
                  exercisePreviousTopSetReps[exerciseName]!.take(12).toList();
            }

// ✅ Then, limit E1RM storage separately (if needed)
            if (exercisePreviousE1RMs[exerciseName]!.length > 4) {
              exercisePreviousE1RMs[exerciseName] =
                  exercisePreviousE1RMs[exerciseName]!.take(4).toList();
            }

          }
        }
      }
      // ✅ ADD THIS HERE (inside the if, after all loops)
      print('🧪 [PMU] Top set history fully loaded. Keys: ${exercisePreviousTopSetReps.keys.toList()}');
    }
  }


  static List<int> getForbiddenRepTargets(String exerciseName) {
    List<int>? pastReps = exercisePreviousTopSetReps[exerciseName];
    if (pastReps == null) return []; // ✅ Handle missing data

    Set<int> forbiddenReps = {};

    for (int i = 0; i < pastReps.length; i++) {
      int effectiveRep = pastReps[i]; // ✅ Now includes RIR (already adjusted)

      if (i == 0) {
        forbiddenReps.addAll([
          effectiveRep,
          effectiveRep - 2,
          effectiveRep - 1,
          effectiveRep + 1,
          effectiveRep + 2
        ]);
      } else if (i == 1) {
        forbiddenReps.addAll([effectiveRep - 1, effectiveRep, effectiveRep + 1]);
      } else if (i == 2 || i == 3) {
        forbiddenReps.add(effectiveRep);
      }
    }

    return forbiddenReps.where((rep) => rep >= 1).toList(); // ✅ Remove upper limit (previously 12)
  }

  static List<int> getAvailableRepTargets(String exerciseName, {int? setIndex}) {

    List<int> allReps = List.generate(12, (index) => index + 1);
    List<int> forbiddenReps = getForbiddenRepTargets(exerciseName);

    // ✅ Get available reps by filtering out forbidden ones
    List<int> availableReps = allReps.where((rep) => !forbiddenReps.contains(rep)).toList();

    // ✅ Sort available reps so the most distant target is first
    List<int>? pastReps = exercisePreviousTopSetReps[exerciseName];

    if (pastReps != null) {
      availableReps.sort((a, b) => pastReps.contains(a) ? 1 : -1);
    }

    return availableReps;
  }

  //BB2 Function
  static int getExercisePlannedCountInWeek({
    required String exerciseName,
    required int week,
    required int day,
    required int row,
    required List<List<List<Map<String, dynamic>>>> exerciseGrid,
  }) {
    int count = 0;

    for (int d = 0; d <= day; d++) {
      final rows = exerciseGrid[week][d];
      final lastRow = (d == day) ? row + 1 : rows.length; // ✅ include current row only to that point

      for (int r = 0; r < lastRow; r++) {
        final thisName = (rows[r]['exercise'] ?? '').toString().trim();
        if (thisName == exerciseName.trim()) {
          count++;
          print('🔎 Match: "$thisName" == "$exerciseName" (week $week, day $d, row $r)');
        }
      }
    }

    final result = count - 1; // ✅ zero-based index
    print('📊 getExercisePlannedCountInWeek → "$exerciseName" → index $result');
    return result;
  }


  //WES Function
  static int getInstanceCountForExerciseInBlock({
    required String exerciseName,
    required List<Map<String, dynamic>> savedWorkouts,
    required DateTime blockStartDate,
    required DateTime blockEndDate,
  }) {
    final usedDates = <String>{};

    for (final workout in savedWorkouts) {
      final dateStr = workout['date'] ?? '';
      final date = DateTime.tryParse(dateStr);
      if (date == null || date.isBefore(blockStartDate) || date.isAfter(blockEndDate)) continue;

      final exercises = workout['exercises'];
      if (exercises is! List) continue;

      final hasExercise = exercises.any((ex) {
        final exName = ex['name']?.toString().trim();
        return exName == exerciseName;
      });

      if (hasExercise) {
        usedDates.add(dateStr); // Count once per day
      }
    }

    final count = usedDates.length;
    print('📊 [Instance Count] "$exerciseName" used on $count unique training day(s) in this block.');
    return count;
  }

  //WES Function
  static int getInstanceCountForExerciseInWeek({
    required String exerciseName,
    required List<Map<String, dynamic>> savedWorkouts,
    required DateTime blockStartDate,
    int? weekIndex,
    DateTime? selectedDate,
  }) {
    // 🔍 ENTRY PRINT


    final base = DateTime(blockStartDate.year, blockStartDate.month, blockStartDate.day);
    final idx = weekIndex ??
        (selectedDate != null
            ? (DateTime(selectedDate.year, selectedDate.month, selectedDate.day)
            .difference(base)
            .inDays ~/
            7)
            : 0);
    final int safeWeekIndex = idx < 0 ? 0 : idx;

    final weekStart = base.add(Duration(days: safeWeekIndex * 7));
    final weekEnd = weekStart.add(const Duration(days: 7));

    final usedDates = <String>{};

    // Allow matching by id OR by name (case/whitespace-insensitive)
    final targetName = exerciseName.trim().toLowerCase();
    final targetId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;

    for (final workout in savedWorkouts) {
      final dateStr = (workout['date'] ?? '').toString();
      final date = DateTime.tryParse(dateStr);


      if (date == null) continue;
      if (date.isBefore(weekStart) || !date.isBefore(weekEnd)) {

        continue;
      }

      final exercises = workout['exercises'];


      final matched = exercises.any((ex) {
        final exId = ex['exerciseId']?.toString();
        final exName = (ex['name'] ?? '').toString().trim().toLowerCase();
        final sets = (ex['sets'] is List)
            ? List<Map<String, dynamic>>.from(ex['sets'])
            : const <Map<String, dynamic>>[];

        final idMatch = (exId != null && exId == targetId);
        final nameMatch = exName == targetName;


        return (idMatch || nameMatch) && sets.isNotEmpty;
      });

      if (matched) {
        usedDates.add(dateStr.length >= 10 ? dateStr.substring(0, 10) : dateStr);
      } else {
      }
    }

    final count = usedDates.length;
    // 🔍 FINAL PRINT


    return count;
  }


  //WES Function
  static int getWeekIndexForDate(DateTime date, DateTime blockStartDate) {
    final daysSinceStart = date.difference(blockStartDate).inDays;
    final weekIndex = (daysSinceStart / 7).floor();
    return weekIndex.clamp(0, 11); // assuming max 12 weeks

  }

  // WES and bb2 function

  static Set<String> getUsedWeightRepsRirTripletsForExercise({
    required String exerciseName,
    required List<Map<String, dynamic>> savedWorkouts,
  }) {
    final Set<String> used = {};

    for (final workout in savedWorkouts) {
      final List<dynamic>? exercises = workout['exercises'];
      if (exercises == null) {
        print('❌ No exercises found in workout');
        continue;
      }

      for (final ex in exercises) {
        if (ex['name'] != exerciseName) continue;

        final sets = ex['sets'] as List<dynamic>? ?? [];
        if (sets.isEmpty) {
          print('⚠️ No sets in ${ex['name']}');
          continue;
        }

        // Take the best set (assume first = top set)
        final top = sets.first;

        final double? w = top['weight']?.toDouble();
        final int? r = top['reps'];
        final double? rir = top['rir']?.toDouble();

        if (w != null && r != null && rir != null) {
          final key = '${w.toStringAsFixed(1)}_${r}_${rir.toStringAsFixed(1)}';

          used.add(key);
        }
      }
    }

    return used;
  }





  static Future<int> getExposureCountForExercise({
    required String exerciseName,
    required DateTime blockStart,
    required DateTime blockEnd,
    String? uid, // ✅ optional uid
  }) async {
    final resolvedUid = uid ?? FirebaseAuth.instance.currentUser!.uid;
    print('🔁 [PMU] Fetching exposure count for "$exerciseName" for user: $resolvedUid');

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(resolvedUid)
        .collection('workouts')
        .where('date', isGreaterThanOrEqualTo: blockStart.toIso8601String())
        .where('date', isLessThanOrEqualTo: blockEnd.toIso8601String())
        .get();

    int count = 0;

    for (final doc in snapshot.docs) {
      final data = doc.data();
      final exercises = List<Map<String, dynamic>>.from(data['exercises'] ?? []);

      for (final ex in exercises) {
        if (ex['name'] == exerciseName) {
          count++;
          break; // Only count once per workout
        }
      }
    }

    return count;
  }


  static int getDupSignatureRepTarget( //DUP signature
      String exerciseName, {
        String? weightText,
        String? rirText,
        required int plannedIndex,
      })
  {
    // ✅ If weight is entered, use `updateRepTarget()` to calculate reps based on weight.
    if (weightText != null && weightText.isNotEmpty) {
      return updateRepTarget(exerciseName, weightText, rirText ?? "0.5",  plannedIndex,
      );
    }

    // ✅ Step 1: Get Available Rep Targets (which removes forbidden reps)
    List<int> availableReps = getAvailableRepTargets(exerciseName);
    if (availableReps.isEmpty) return 6; // ✅ Default to 6 if all reps are blocked

    // ✅ Step 2: Get Past Top Set Reps (last 12 workouts)
    List<int>? pastReps = exercisePreviousTopSetReps[exerciseName];
    if (pastReps == null || pastReps.isEmpty) return availableReps.first; // ✅ If no history, return first available

    // ✅ Step 3: Define Rep Groups
    List<List<int>> repGroups = [
      [1, 2],
      [3, 4],
      [5, 6, 7],
      [8, 9, 10],
      [11, 12],
      [13, 14, 15, 16, 17],
      [18, 19, 20, 21, 22],
      [23, 24, 25, 26, 27, 28],
      [29, 30, 31, 32, 33, 34, 35]
    ];

    // ✅ Step 4: Identify Used Groups in History
    Set<int> usedGroups = {};
    for (int rep in pastReps) {
      for (int i = 0; i < repGroups.length; i++) {
        if (repGroups[i].contains(rep)) {
          usedGroups.add(i); // ✅ Track used group indices
          break;
        }
      }
    }

    // ✅ Step 5: Find the Least Used Group (Only Considering Available Reps)
    int? bestGroupIndex;
    for (int i = 0; i < repGroups.length; i++) {
      if (!usedGroups.contains(i) && repGroups[i].any((rep) => availableReps.contains(rep))) {
        bestGroupIndex = i; // ✅ Found an unused group with available reps
        break;
      }
    }

    // ✅ Step 6: If All Groups Have Been Used, Pick the Least Recently Used Group
    if (bestGroupIndex == null) {
      Map<int, int> groupUsage = {}; // Group Index → Last Used Position
      for (int i = 0; i < pastReps.length; i++) {
        for (int j = 0; j < repGroups.length; j++) {
          if (repGroups[j].contains(pastReps[i])) {
            groupUsage[j] = i;
            break;
          }
        }
      }

      // ✅ Find the least recently used group
      bestGroupIndex = groupUsage.entries
          .toList()
          .reduce((a, b) => a.value > b.value ? a : b) // ✅ Find least recently used group
          .key;
    }

    // ✅ Step 7: Pick the Least Recently Used Rep Within That Group (Only from Available Reps)
    List<int> candidates = repGroups[bestGroupIndex!].where((rep) => availableReps.contains(rep)).toList();
    candidates.sort((a, b) => pastReps.contains(a) ? 1 : -1); // ✅ Prioritize least recently used

    // ✅ Ensure there's at least one candidate before calling `.first`
    if (candidates.isEmpty) {
      return availableReps.first; // ✅ Fall back to first available rep if no candidates exist
    }

    return candidates.first; // ✅ Return the best available rep
  }


  //Old Model - back up fro WES
  static int getSuggestedRepTarget( //DUP signature
      String exerciseName, {
        String? weightText,
        String? rirText,
        required int plannedIndex,
      })
  {
    // ✅ If weight is entered, use `updateRepTarget()` to calculate reps based on weight.
    if (weightText != null && weightText.isNotEmpty) {
      return updateRepTarget(exerciseName, weightText, rirText ?? "0.5",  plannedIndex,
      );
    }

    // ✅ Step 1: Get Available Rep Targets (which removes forbidden reps)
    List<int> availableReps = getAvailableRepTargets(exerciseName);
    if (availableReps.isEmpty) return 6; // ✅ Default to 6 if all reps are blocked

    // ✅ Step 2: Get Past Top Set Reps (last 12 workouts)
    List<int>? pastReps = exercisePreviousTopSetReps[exerciseName];
    if (pastReps == null || pastReps.isEmpty) return availableReps.first; // ✅ If no history, return first available

    // ✅ Step 3: Define Rep Groups
    List<List<int>> repGroups = [
      [1, 2],
      [3, 4],
      [5, 6, 7],
      [8, 9, 10],
      [11, 12],
      [13, 14, 15, 16, 17],
      [18, 19, 20, 21, 22],
      [23, 24, 25, 26, 27, 28],
      [29, 30, 31, 32, 33, 34, 35]
    ];

    // ✅ Step 4: Identify Used Groups in History
    Set<int> usedGroups = {};
    for (int rep in pastReps) {
      for (int i = 0; i < repGroups.length; i++) {
        if (repGroups[i].contains(rep)) {
          usedGroups.add(i); // ✅ Track used group indices
          break;
        }
      }
    }

    // ✅ Step 5: Find the Least Used Group (Only Considering Available Reps)
    int? bestGroupIndex;
    for (int i = 0; i < repGroups.length; i++) {
      if (!usedGroups.contains(i) && repGroups[i].any((rep) => availableReps.contains(rep))) {
        bestGroupIndex = i; // ✅ Found an unused group with available reps
        break;
      }
    }

    // ✅ Step 6: If All Groups Have Been Used, Pick the Least Recently Used Group
    if (bestGroupIndex == null) {
      Map<int, int> groupUsage = {}; // Group Index → Last Used Position
      for (int i = 0; i < pastReps.length; i++) {
        for (int j = 0; j < repGroups.length; j++) {
          if (repGroups[j].contains(pastReps[i])) {
            groupUsage[j] = i;
            break;
          }
        }
      }

      // ✅ Find the least recently used group
      bestGroupIndex = groupUsage.entries
          .toList()
          .reduce((a, b) => a.value > b.value ? a : b) // ✅ Find least recently used group
          .key;
    }

    // ✅ Step 7: Pick the Least Recently Used Rep Within That Group (Only from Available Reps)
    List<int> candidates = repGroups[bestGroupIndex!].where((rep) => availableReps.contains(rep)).toList();
    candidates.sort((a, b) => pastReps.contains(a) ? 1 : -1); // ✅ Prioritize least recently used

    // ✅ Ensure there's at least one candidate before calling `.first`
    if (candidates.isEmpty) {
      return availableReps.first; // ✅ Fall back to first available rep if no candidates exist
    }

    return candidates.first; // ✅ Return the best available rep
  }

  static int getPlannedCountBefore(
      List<String?> plannedExercises,
      String exerciseName,
      int currentIndex,
      ) {
    int count = 0;
    for (int i = 0; i < currentIndex; i++) {
      if (plannedExercises[i] == exerciseName) {
        count++;
      }
    }
    return count;
  }


  static List<int> upcomingRepTargetSequence(String exerciseName, int count) {

    print('📘 nameToId keys: ${PeriodizationModelUtils.nameToId.keys.toList()}');
    print('📘 Looking up ID for "$exerciseName"');

    // 🔍 Convert exercise name → ID
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName] ??
        (() {
          print('❌ No match found for "$exerciseName". Available keys: ${PeriodizationModelUtils.nameToId.keys}');
          return null;
        })();

    final details = PeriodizationModelUtils.plannedExerciseDetails[exerciseId];
    if (details == null) {
      print("❌ [upcomingRepTargetSequence] No details found for ID=$exerciseId at this time.");
    } else {
      print("✅ [upcomingRepTargetSequence] Found details for $exerciseName (ID=$exerciseId)");

      final repTargetsMap = details['repTargets'] as Map<String, dynamic>?;
      final week1 = repTargetsMap?['week1'] as Map<String, dynamic>?;
      final rawInstance1 = week1?['instance1'];

      print('🧪 [DUP Signature] Raw week1.instance1 value for $exerciseName → $rawInstance1');
    }

    print('✅ [upcomingRepTargetSequence] Found details for $exerciseName (ID=$exerciseId)');
    print('🧪 [DUP Signature] Raw week1.instance1 value for $exerciseName → ${PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['repTargets']?['week1']?['instance1']}');
    final rawInstance1 = PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['repTargets']?['week1']?['instance1']?.toString();
    print('🧪 [DUP Signature] Raw week1.instance1 value for $exerciseName → $rawInstance1');

    final parsedMin = rawInstance1 != null && rawInstance1.contains('–')
        ? int.tryParse(rawInstance1.split('–').first.trim())
        : null;

    print('🔍 [DUP Signature] Parsed min rep value → $parsedMin');


    final parsedMax = rawInstance1 != null && rawInstance1.contains('–')
        ? int.tryParse(
      rawInstance1
          .split('–')
          .last
          .replaceAll(RegExp(r'[^0-9]'), '') // removes " reps" or other non-digit chars
          .trim(),
    )
        : null;

    print('🔍 [DUP Signature] Parsed max rep value → $parsedMax');


// 🔢 Use hardcoded min/max values
    final int minReps = parsedMin ?? 4;
    final int maxReps = parsedMax ?? 18;
    print('📏 [Rep Range] min=$minReps, max=$maxReps for ID=$exerciseId');


    // 🧠 Step 1: Load history in chronological order (oldest → newest)
    List<int> rawHistory = List.from(exercisePreviousTopSetReps[exerciseName] ?? []);
    List<int> history = List.from(rawHistory);

    // 🧪 Step 2: Setup rep groups
    List<List<int>> repGroups = [
      [1, 2],
      [3, 4],
      [5, 6, 7],
      [8, 9, 10],
      [11, 12],
      [13, 14, 15, 16, 17],
      [18, 19, 20, 21, 22],
      [23, 24, 25, 26, 27, 28],
      [29, 30, 31, 32, 33, 34, 35]
    ];

    List<int> result = [];

    for (int i = 0; i < count; i++) {
      // 🔍 Filter available reps to fit within min/max range
      List<int> availableReps = getAvailableRepTargetsFromSimulatedHistory(
        exerciseName,
        history,
        minReps: minReps,
        maxReps: maxReps,
      );
      print('🔎 [DUP Signature] Available reps after filtering → $availableReps');
      print('🧠 [DUP Signature] Simulated history so far → $history');


      if (availableReps.isEmpty) {
        result.add(minReps); // fallback
        history.add(minReps);
        continue;
      }

      // 🔁 Hybrid logic: fallback to distance-based if tight range
      if ((maxReps - minReps) <= 2) {
        print('🧪 [Tight Range] Entering fallback logic... Range = ${maxReps - minReps + 1}');

        List<int> tightRange = List.generate(maxReps - minReps + 1, (i) => minReps + i);

        // Map each rep to its most recent index in history (or -1 if unused)
        Map<int, int> recencyMap = {
          for (var rep in tightRange) rep: history.lastIndexOf(rep)
        };

        // Sort by least recently used (lowest index or -1)
        tightRange.sort((a, b) =>
            (recencyMap[a] ?? -1).compareTo(recencyMap[b] ?? -1));


        int selected = tightRange.first;
        print('✅ [Tight Range] Selected least recent rep: $selected');

        result.add(selected);
        history.add(selected);
        continue;
      }

      else {
        // 🧠 Step 1: Build recency map for rep groups
        Map<int, int> groupUsage = {};
        for (int j = 0; j < history.length; j++) {
          int rep = history[history.length - 1 - j]; // Most recent first
          for (int g = 0; g < repGroups.length; g++) {
            if (repGroups[g].contains(rep) && !groupUsage.containsKey(g)) {
              groupUsage[g] = j; // record earliest appearance
              break;
            }
          }
        }

        // 🔍 Step 2: Find the group with the least recent or unused appearance
        int? bestGroupIndex;
        int bestScore = -1;
        for (int g = 0; g < repGroups.length; g++) {
          if (repGroups[g].any((r) => availableReps.contains(r))) {
            int score = groupUsage.containsKey(g) ? groupUsage[g]! : 9999;
            if (score > bestScore) {
              bestScore = score;
              bestGroupIndex = g;
            }
          }
        }

        // ✅ Step 3: Choose the least used rep within the best group
        List<int> candidates = repGroups[bestGroupIndex!]
            .where((r) => availableReps.contains(r))
            .toList();

        candidates.sort((a, b) =>
            history.where((x) => x == a).length.compareTo(history.where((x) => x == b).length));

        int selected = candidates.isNotEmpty ? candidates.first : availableReps.first;
        result.add(selected);
        history.add(selected);
      }
    }


    print('✅ [upcomingRepTargetSequence] Final rep sequence for "$exerciseName": $result');
    return result;
  }


  static List<int> getAvailableRepTargetsFromSimulatedHistory(
      String exerciseName,
      List<int> history, {
        int minReps = 1,
        int maxReps = 35,
      }) {
    List<int> allReps = List.generate(35, (index) => index + 1);

    // ✅ NEW: Skip filtering for tight ranges
    if ((maxReps - minReps) <= 2) {
      final tightRange = allReps.where((r) => r >= minReps && r <= maxReps).toList();
      print('⚠️ [SimulatedHistory] Skipping filtering due to tight range → $tightRange');
      return tightRange;
    }

    Set<int> forbiddenReps = {};
    final recent = history.length >= 4
        ? history.sublist(history.length - 4)
        : history;

    for (int i = 0; i < recent.length; i++) {
      int rep = recent[recent.length - 1 - i]; // Newest → Oldest
      if (i == 0) {
        forbiddenReps.addAll([rep - 2, rep - 1, rep, rep + 1, rep + 2]);
      } else if (i == 1) {
        forbiddenReps.addAll([rep - 1, rep, rep + 1]);
      } else if (i == 2 || i == 3) {
        forbiddenReps.add(rep);
      }
    }

    final filtered = allReps
        .where((r) => !forbiddenReps.contains(r) && r >= minReps && r <= maxReps)
        .toList();

    print('🔎 [DUP Signature] Available reps after filtering → $filtered');
    return filtered;
  }

  static List<int> parseHistoryInput(String input) {
    return input
        .split(',')
        .map((s) => s.replaceAll(RegExp(r'[^0-9]'), '')) // remove non-numeric
        .map((s) => int.tryParse(s))
        .whereType<int>() // remove nulls
        .toList();
  }

  static Map<String, int>? getDupSignatureRepRange(String exerciseKey) {
    // Step 1: Try direct lookup (assume key is an ID)
    var details = plannedExerciseDetails[exerciseKey];

    // Step 2: If null, try converting from name → ID
    if (details == null && nameToId.containsKey(exerciseKey)) {
      final id = nameToId[exerciseKey];
      if (id != null) {
        details = plannedExerciseDetails[id];
        print('🔁 [getDupSignatureRepRange] Used name to find ID "$id"');
      }
    }

    if (details == null) {
      print('❌ [getDupSignatureRepRange] No details found for "$exerciseKey"');
      return null;
    }

    final rawInstance1 = details['repTargets']?['week1']?['instance1']?.toString();

    final parsedMin = rawInstance1?.contains('–') == true
        ? int.tryParse(rawInstance1!.split('–').first.trim())
        : null;

    final parsedMax = rawInstance1?.contains('–') == true
        ? int.tryParse(rawInstance1!.split('–').last.replaceAll(RegExp(r'[^0-9]'), '').trim())
        : null;

    print('📏 [getDupSignatureRepRange] Parsed range → min=$parsedMin, max=$parsedMax for key "$exerciseKey"');

    return {
      'min': parsedMin ?? 2,
      'max': parsedMax ?? 10,
    };
  }



  static List<int> REsignatureRepTargets({
    required int min,
    required int max,
    required List<int> history,
    int count = 20,
  }) {
    final allReps = List.generate(max - min + 1, (i) => min + i);
    final result = <int>[];
    final usedInCycle = <int>{}; // Tracks current cycle usage
    final recentHistory = List<int>.from(history.where((r) => r >= min - 4 && r <= max + 4));

    // Seed: if no history, start with something near the top
    if (recentHistory.isEmpty && result.isEmpty) {
      result.add(max);
      usedInCycle.add(max);
    }

    while (result.length < count) {
      final currentHistory = [...recentHistory, ...result];
      final recent = currentHistory.reversed.toList();
      final lastUsed = result.isNotEmpty ? result.last : null;

      // Step 1: Start with full range
      final candidates = List<int>.from(allReps);

      // Step 2: Apply recency constraints
      final Set<int> forbidden = {};

      if (recent.length >= 1) {
        final r = recent[0];
        forbidden.addAll([r - 2, r - 1, r, r + 1, r + 2]);
      }
      if (recent.length >= 2) {
        final r = recent[1];
        forbidden.addAll([r - 1, r, r + 1]);
      }
      if (recent.length >= 3) forbidden.add(recent[2]);
      if (recent.length >= 4) forbidden.add(recent[3]);

      List<int> valid = candidates
          .where((rep) =>
      !forbidden.contains(rep) &&
          (lastUsed == null || rep != lastUsed)) // never repeat immediately
          .toList();

      // Step 3: Prioritize unused reps in current cycle
      final unused = valid.where((rep) => !usedInCycle.contains(rep)).toList();

      int? chosen;
      if (unused.isNotEmpty) {
        chosen = _repWithMaxDistance(unused, recent);
      } else if (valid.isNotEmpty) {
        chosen = _repWithMaxDistance(valid, recent);
      } else {
        // 🔁 Relax constraints step-by-step
        valid = candidates.where((rep) => rep != lastUsed).toList();
        chosen = _repWithMaxDistance(valid, recent);
      }

      if (chosen != null) {
        result.add(chosen);
        usedInCycle.add(chosen);
      }

      // Reset cycle if all reps used once
      if (usedInCycle.length == allReps.length) {
        usedInCycle.clear();
      }
    }

    return result;
  }

  static int _repWithMaxDistance(List<int> options, List<int> recent) {
    int maxDistance = -1;
    int best = options.first;

    for (var rep in options) {
      int dist = 0;
      for (int i = 0; i < recent.length && i < 4; i++) {
        dist += (rep - recent[i]).abs();
      }
      if (dist > maxDistance) {
        maxDistance = dist;
        best = rep;
      }
    }
    return best;
  }

  static List<int> REsignatureRepsByExercise({
    required String exerciseName, // May be name or ID
    required int min,
    required int max,
    int count = 20,
  }) {
    // ✅ Resolve name if ID is passed
    final resolvedName = PeriodizationModelUtils.idToName[exerciseName] ?? exerciseName;

    // ✅ Use name to fetch top set history
    final history = (exercisePreviousTopSetReps[resolvedName] ?? []).reversed.toList();

    print('🧠 [REsignature] History key used: "$resolvedName"');
    print('🧠 [REsignature] History values: ${exercisePreviousTopSetReps[resolvedName]}');



    final allReps = List.generate(max - min + 1, (i) => min + i);
    final result = <int>[];
    final usedInCycle = <int>{};
    final recentHistory = List<int>.from(history.where((r) => r >= min - 4 && r <= max + 4));

    if (recentHistory.isEmpty && result.isEmpty) {
      result.add(max);
      usedInCycle.add(max);
    }

    while (result.length < count) {
      final currentHistory = [...recentHistory, ...result];
      final recent = currentHistory.reversed.toList();
      final lastUsed = result.isNotEmpty ? result.last : null;

      final candidates = List<int>.from(allReps);
      final Set<int> forbidden = {};

      if (recent.length >= 1) {
        final r = recent[0];
        forbidden.addAll([r - 2, r - 1, r, r + 1, r + 2]);
      }
      if (recent.length >= 2) {
        final r = recent[1];
        forbidden.addAll([r - 1, r, r + 1]);
      }
      if (recent.length >= 3) forbidden.add(recent[2]);
      if (recent.length >= 4) forbidden.add(recent[3]);

      List<int> valid = candidates
          .where((rep) =>
      !forbidden.contains(rep) &&
          (lastUsed == null || rep != lastUsed))
          .toList();

      final unused = valid.where((rep) => !usedInCycle.contains(rep)).toList();

      int? chosen;
      if (unused.isNotEmpty) {
        chosen = _repWithMaxDistance(unused, recent);
      } else if (valid.isNotEmpty) {
        chosen = _repWithMaxDistance(valid, recent);
      } else {
        valid = candidates.where((rep) => rep != lastUsed).toList();
        chosen = _repWithMaxDistance(valid, recent);
      }

      if (chosen != null) {
        result.add(chosen);
        usedInCycle.add(chosen);
      }

      if (usedInCycle.length == allReps.length) {
        usedInCycle.clear();
      }
    }
    print('🧠 [REsignature] History key used: "$exerciseName"');
    print('🧠 [REsignature] History values: ${exercisePreviousTopSetReps[exerciseName]}');


    return result;
  }


  static int updateRepTarget(String exerciseName, String weightText, String rirText, int plannedIndex)
  {
    if (exerciseName.isEmpty) return 6; // ✅ Default to 6 if no exercise is selected

    // ✅ Check if the user has entered a weight
    bool hasUserWeightInput = weightText.isNotEmpty;

    if (hasUserWeightInput) {
      double avgE1RM = getAverageE1RM(exerciseName); // ✅ Get avg E1RM
      double weight = double.tryParse(weightText) ?? 0.0;

      if (weight <= 0 || avgE1RM <= weight) {
        return 1; // ✅ If weight is too high, set to 1 rep
      }

      // ✅ Reverse Brzycki/Epley formula to calculate reps
      double rawReps = (weight / avgE1RM < 0.85)
          ? ((avgE1RM / weight) - 1) / 0.0333  // ✅ Epley formula for higher reps
          : (37 - ((weight * 36) / avgE1RM));  // ✅ Brzycki formula for lower reps

      // ✅ Get the current RIR (user input or default)
      double rir = double.tryParse(rirText) ?? 0.5;

      // ✅ Subtract RIR from calculated reps
      double finalReps = (rawReps - rir).clamp(1.0, 200.0);

      // ✅ Round reps intelligently
      finalReps = (finalReps - finalReps.floor() >= 0.652)
          ? finalReps.ceil().toDouble()
          : finalReps.floor().toDouble();

      return finalReps.toInt(); // ✅ Return final calculated reps as an integer
    }

    // ✅ If no weight entered, return default suggested rep target
    return upcomingRepTargetSequence(exerciseName, plannedIndex + 1).last;

  }


  static double getSuggestedWeight(
      String exerciseName,
      TextEditingController repsController,
      TextEditingController rirController,
      int plannedIndex,
      Map<String, List<Map<String, dynamic>>>? topSetsByExercise, // ✅ new optional param
      ) {
    if (!exercisePreviousE1RMs.containsKey(exerciseName) || exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      return 20.0;
    }

    double avgE1RM = getAverageE1RM(exerciseName);

    // ✅ Use upcoming rep target based on the planned index
    int reps = int.tryParse(repsController.text) ??
        upcomingRepTargetSequence(exerciseName, plannedIndex + 1).last;
    double rir = double.tryParse(rirController.text) ?? 0.5;
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      suggestedWeight = avgE1RM * (37 - effectiveReps) / 36;
    } else {
      suggestedWeight = avgE1RM / (1 + (0.0333 * effectiveReps));
    }

    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);
    return (suggestedWeight / 2.5).round() * 2.5;
  }

// ⬇️ Retrieves reps and RIR for progression logic
  static Map<String, double> getActualRepsAndRir({
    required TextEditingController repsController,
    required TextEditingController rirController,
    required String? plannedRep,
    required String? plannedRir,
  }) {
    final repsText = repsController.text.trim();
    final rirText = rirController.text.trim();

    final reps = double.tryParse(repsText.isNotEmpty
        ? repsText
        : RegExp(r'^\d+').firstMatch(plannedRep ?? '')?.group(0) ?? '') ?? 0.0;

    final rir = double.tryParse(rirText.isNotEmpty
        ? rirText
        : plannedRir?.trim() ?? '') ?? 0.5;

    return {
      'reps': reps,
      'rir': rir,
    };
  }


//updated this function to use newer signaturerep model for default
  static void updateWeight(
      String exerciseName,
      TextEditingController weightController,
      TextEditingController repsController,
      TextEditingController rirController,
      int plannedIndex,
      )
  {

    if (!exercisePreviousE1RMs.containsKey(exerciseName) ||
        exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      weightController.text = '20.0'; // ✅ Default weight if no history
      return;
    }

    // ✅ Get the average of the last 4 E1RMs (or fewer if not available)
    double avgE1RM = getAverageE1RM(exerciseName);

    // ✅ Get reps and RIR from UI (or use defaults)
    int reps = int.tryParse(repsController.text) ??
        getDupSignatureRepTarget(
          exerciseName,
          plannedIndex: plannedIndex,
        );
    double rir = double.tryParse(rirController.text) ?? 0.5; // Default RIR if none entered
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      // ✅ Use Brzycki formula for lower rep ranges
      suggestedWeight = avgE1RM * (37 - effectiveReps) / 36;
    } else {
      // ✅ Use Epley formula for higher rep ranges
      suggestedWeight = avgE1RM / (1 + (0.0333 * effectiveReps));
    }

    // ✅ Prevent negative or unrealistic weight
    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);

    // ✅ Round to the nearest 2.5kg increment
    suggestedWeight = (suggestedWeight / 2.5).round() * 2.5;

    // ✅ Update the weight text field dynamically
    weightController.text = suggestedWeight.toString();
  }



  /// ✅ Helper Function to Parse Any Firestore Value to a Double
  static double _parseToDouble(dynamic value) {
    if (value is double) return value; // ✅ Already a double, return it
    if (value is int) return value.toDouble(); // ✅ Convert int to double
    if (value is String) return double.tryParse(value) ?? 0; // ✅ Convert String to double
    return 0; // ✅ Default case
  }
}

// ───────────────────────────────────────────────────────────────
// WES hint-inputs fingerprint helpers (snapshot freshness)
// ───────────────────────────────────────────────────────────────
const int kWesSnapshotSchema = 2; // bump when snapshot structure changes

class WesHintInputsPayload {
  final String uid;
  final String blockId;
  final String dateYmd;
  final int weekIndex;

  final List<Map<String, dynamic>> plannedExercises;
  final Map<String, dynamic> plannedExerciseDetails;
  final Map<String, dynamic> exerciseSettings;

  final double bodyweightAsOfDay;
  final String lastWorkoutDate; // yyyy-MM-dd or ''
  final String lastTopSetDate;  // yyyy-MM-dd or ''

  WesHintInputsPayload({
    required this.uid,
    required this.blockId,
    required this.dateYmd,
    required this.weekIndex,
    required this.plannedExercises,
    required this.plannedExerciseDetails,
    required this.exerciseSettings,
    required this.bodyweightAsOfDay,
    required this.lastWorkoutDate,
    required this.lastTopSetDate,
  });

  String hash() {
    final payload = {
      'v'   : kWesSnapshotSchema,
      'uid' : uid,
      'bid' : blockId,
      'd'   : dateYmd,
      'wk'  : weekIndex,
      'bw'  : double.parse(bodyweightAsOfDay.toStringAsFixed(3)),
      'lw'  : lastWorkoutDate,
      'lt'  : lastTopSetDate,
      'planned': plannedExercises.map((e) => {
        'id': (e['id'] ?? e['exerciseId'] ?? e['name'] ?? '').toString(),
        'c' : (e['circuitIndex'] ?? 0),
      }).toList(),
      'details': plannedExerciseDetails.map((k, v) {
        final m = (v is Map) ? v : const {};
        return MapEntry(k.toString(), {
          'periodizationModel': m['periodizationModel'],
          'progressionModel'  : m['progressionModel'],
          'repTargets'        : m['repTargets'],
          'rirPlan'           : m['rirPlan'],
          'increments'        : m['increments'],
        });
      }),
      'settings': exerciseSettings.map((k, v) {
        final m = (v is Map) ? v : const {};
        return MapEntry(k.toString(), {
          if (m['increments'] != null) 'increments': m['increments'],
        });
      }),
    };

    final jsonStr = jsonEncode(payload);
    return sha1.convert(utf8.encode(jsonStr)).toString();
  }
}

String wesMaxWorkoutDate(List<Map<String,dynamic>> saved) {
  String best = '';
  for (final w in saved) {
    final d = (w['date'] ?? '').toString();
    if (d.length >= 10) {
      final ymd = d.substring(0,10);
      if (ymd.compareTo(best) > 0) best = ymd;
    }
  }
  return best;
}

String wesMaxTopSetDate(Map<String, List<Map<String,dynamic>>> topSets) {
  String best = '';
  for (final list in topSets.values) {
    for (final s in list) {
      final v = s['date'];
      final iso = (v is DateTime) ? v.toIso8601String() : (v?.toString() ?? '');
      if (iso.length >= 10) {
        final ymd = iso.substring(0,10);
        if (ymd.compareTo(best) > 0) best = ymd;
      }
    }
  }
  return best;
}



