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


enum PeriodizationModelType {
  dailyUndulating, // <-- add this
  dupSignature,
  dupCustom,
  linearClassic,
  linearExposure,
}



class PeriodizationModelUtils {
  static final Map<String, List<double>> exercisePreviousE1RMs = {};
  static final Map<String, List<int>> exercisePreviousTopSetReps = {};
  static Map<String, PeriodizationModelType> exercisePeriodizationModels = {};

  static final List<int> linearClassicDefaults = [10, 8, 6];
  static final List<int> linearExposureDefaults = [12, 10, 8, 6, 4, 2];
  static final List<int> dupSignatureDefaults = [6, 10];

  static double calculateE1RM(double? weight, double? reps, double? rir) {
    double w = weight ?? 0.0;
    double r = reps ?? 0.0;
    double rValue = rir ?? 0.5;
    double totalReps = r + rValue;

    if (totalReps <= 6) {
      return w * (36 / (37 - totalReps));
    } else {
      return w * (1 + (0.0333 * totalReps));
    }
  }

  static Future<void> loadPeriodizationModelsFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
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
      case 'DUP, Custom':
        return PeriodizationModelType.dupCustom; // ✅ Check spelling
      case 'Linear, Classic':
        return PeriodizationModelType.linearClassic;
      case 'Linear, by Exposure':
        return PeriodizationModelType.linearExposure;
      case 'Daily Undulating Periodization':
        return PeriodizationModelType.dailyUndulating;
      default:
        return PeriodizationModelType.dupSignature;
    }
  }



  static List<String> getDefaultReps(PeriodizationModelType model, int frequency) {
    switch (model) {
      case PeriodizationModelType.dailyUndulating:
        const pattern = [10, 5, 8, 1, 12, 4, 6];
        final reps = List.generate(frequency, (i) => pattern[i % pattern.length]);
        return reps.map((r) => "$r x 3").toList();

      case PeriodizationModelType.linearClassic:
        return linearClassicDefaults.take(frequency).map((r) => '$r x 3').toList();

      case PeriodizationModelType.linearExposure:
        return linearExposureDefaults.take(frequency).map((r) => '$r x 3').toList();

      case PeriodizationModelType.dupSignature:
        final min = dupSignatureDefaults[0];
        final max = dupSignatureDefaults[1];
        return List.generate(frequency, (i) => '${min + i % (max - min + 1)} x 3');

      case PeriodizationModelType.dupCustom:
        return List.generate(frequency, (i) => '10 x 3'); // Placeholder if needed

      default:
        return List.generate(frequency, (i) => '10 x 3');
    }
  }

  static PeriodizationModelType stringToModel(String modelName) {
    switch (modelName) {
      case 'Linear Exposure':
      case 'Linear, by Exposure':
        return PeriodizationModelType.linearExposure;

      case 'Linear, Classic':
        return PeriodizationModelType.linearClassic;

      case 'DUP, Custom':
        return PeriodizationModelType.dupCustom;

      case 'DUP, Signature':
        return PeriodizationModelType.dupSignature;

      case 'Daily Undulating Periodization':
        return PeriodizationModelType.dailyUndulating;

      default:
        return PeriodizationModelType.dupSignature; // Fallback to most generic
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
    final rawWeekList = repsMap[weekKey];

    print('🧪 [LC] Raw weekList for $exerciseId → $rawWeekList');
    print('🧪 [LC] Type: ${rawWeekList.runtimeType}');

    if (rawWeekList == null) {
      print('⚠️ [LC] No data for $weekKey');
      return 10;
    }

    List<String> normalized = [];

    if (rawWeekList is List && rawWeekList.isNotEmpty) {
      final first = rawWeekList.first;
      if (first is String && first.contains(',')) {
        normalized = first.split(',').map((s) => s.trim()).toList();
        print('🛠️ [LC] Normalized from single string → $normalized');
      } else if (first is String) {
        normalized = List<String>.from(rawWeekList);
        print('📦 [LC] Already a clean list → $normalized');
      } else {
        print('❌ [LC] Unrecognized structure in rep targets');
        return 10;
      }
    } else {
      print('⚠️ [LC] Empty or invalid weekList');
      return 10;
    }

    final index = plannedIndex.clamp(0, normalized.length - 1);
    final raw = normalized[index];
    print('✅ [LC] Got rep target: $raw');

    final match = RegExp(r'^(\d+)').firstMatch(raw);
    return match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;

  }





  static int getLinearExposureRepTarget(String exerciseName, int exposureIndex) {
    return linearExposureDefaults[exposureIndex.clamp(0, linearExposureDefaults.length - 1)];
  }


  static int getSuggestedRepTargetByModel({
    required String exerciseName,
    required int plannedIndex,
    String? weightText,
    String? rirText,
    int? weekIndex,
    Map<String, dynamic>? repTargetsByExercise,
    Map<String, dynamic>? plannedExerciseDetails,
  }) {
    print('🧠 [BB2] Rep target requested for: $exerciseName');
    print('🧠 Model detected: ${exercisePeriodizationModels[exerciseName]}');

    final model = exercisePeriodizationModels[exerciseName] ?? PeriodizationModelType.dupSignature;
    print('🧠 getSuggestedRepTargetByModel → $exerciseName using model: $model (plannedIndex: $plannedIndex)');

    try {
      switch (model) {
        case PeriodizationModelType.dailyUndulating:
          final rawFreq = repTargetsByExercise?[exerciseName]?['weeklyFrequency'] ?? 3;
          final weeklyFrequency = rawFreq is int
              ? rawFreq
              : int.tryParse(rawFreq.toString()) ?? 3;

          final reps = getDailyUndulatingRepTarget(
            exerciseName: exerciseName,
            plannedIndex: plannedIndex,
            weeklyFrequency: weeklyFrequency,
          );
          print('🔁 DailyUndulating → $reps reps (weeklyFreq: $weeklyFrequency)');
          return reps;

        case PeriodizationModelType.dupSignature:
          final reps = getSuggestedRepTarget(
            exerciseName,
            weightText: weightText,
            rirText: rirText,
            plannedIndex: plannedIndex,
          );
          print('🔁 DUP Signature → $reps reps');
          return reps;

        case PeriodizationModelType.linearClassic:
        // 🔍 Confirm fallback loading from either source
          final repTargets = repTargetsByExercise?[exerciseName]?['repTargets'] ??
              plannedExerciseDetails?[exerciseName]?['repTargets'];

          print('🧾 [BB2] repTargets used for $exerciseName: ${jsonEncode(repTargets)}');

          final reps = getLinearClassicRepTarget(
            exerciseId: exerciseName,
            weekIndex: weekIndex ?? 0,
            plannedIndex: plannedIndex,
            repTargetsByExercise: {
              exerciseName: {'repTargets': repTargets},
            },
          );
          print('📈 LinearClassic → $reps reps (week: ${weekIndex ?? 0})');
          return reps;

        case PeriodizationModelType.linearExposure:
          final reps = getLinearExposureRepTarget(exerciseName, plannedIndex);
          print('📊 LinearExposure → $reps reps');
          return reps;

        case PeriodizationModelType.dupCustom:
          final reps = getDupCustomRepTargetFromPlanner(
            exerciseName: exerciseName,
            weekIndex: weekIndex ?? 0,
            plannedIndexForWeek: plannedIndex,
            repTargetsByExercise: repTargetsByExercise ?? {},
          );
          print('🧡 DUP Custom → $reps reps (week: ${weekIndex ?? 0})');
          return reps;
      }
    } catch (e) {
      print('⚠️ Error in getSuggestedRepTargetByModel for $exerciseName: $e');
      return 10;
    }
  }


  static int getDailyUndulatingRepTarget({
    required String exerciseName,
    required int plannedIndex,
    required int weeklyFrequency,
  }) {
    const pattern = [10, 5, 8, 1, 12, 4, 6]; // rotating pattern
    final repsList = List.generate(weeklyFrequency, (i) => pattern[i % pattern.length]);
    final reps = repsList[plannedIndex % repsList.length];
    print('🔄 getDailyUndulatingRepTarget → $reps reps for $exerciseName (index $plannedIndex of $weeklyFrequency freq)');
    return reps;
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
      case PeriodizationModelType.dailyUndulating:
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

      case PeriodizationModelType.dupCustom:
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
      case PeriodizationModelType.dailyUndulating:
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

      case PeriodizationModelType.dupCustom:
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
      case PeriodizationModelType.dailyUndulating:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);


      case PeriodizationModelType.dupSignature:
        return getDupSignatureSet1SuggestedWeight(
          exerciseName: exerciseName,
          reps: reps,
          rir: rir,
        );
      case PeriodizationModelType.linearClassic:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);

      case PeriodizationModelType.linearExposure:
        return getSuggestedWeightFromRep(exerciseName, reps.toInt(), rir);

      case PeriodizationModelType.dupCustom:
        return 45.0;
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
      case PeriodizationModelType.dailyUndulating:
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

      case PeriodizationModelType.dupCustom:
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
      case PeriodizationModelType.dailyUndulating:
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

      case PeriodizationModelType.dupCustom:
        return 45.0;
    }
  }



  static int getDupCustomRepTargetFromPlanner({
    required String exerciseName,
    required int weekIndex,
    required int plannedIndexForWeek,
    required Map<String, dynamic> repTargetsByExercise,
  }) {
    try {
      final allWeeks = repTargetsByExercise[exerciseName];
      if (allWeeks == null || allWeeks.isEmpty) return 6;

      final List weekData = allWeeks[weekIndex.clamp(0, allWeeks.length - 1)];
      if (plannedIndexForWeek >= weekData.length) {
        return int.tryParse(weekData.last.toString().split('x')[0].trim()) ?? 6;
      }

      final repString = weekData[plannedIndexForWeek].toString().toLowerCase();
      final repValue = repString.split('x')[0].trim();
      return int.tryParse(repValue) ?? 6;
    } catch (e) {
      print('[DUP CUSTOM] Failed to parse rep target for $exerciseName: $e');
      return 6;
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


  static Future<void> fetchLastWorkoutTopSetReps() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .orderBy('date', descending: true) // ✅ Fetch newest first
        .limit(12) // ✅ Get last 12 workouts
        .get();

    if (snapshot.docs.isNotEmpty) {
      // ✅ Clear ONLY if new data exists
      if (exercisePreviousTopSetReps.isNotEmpty || exercisePreviousE1RMs.isNotEmpty) {
        exercisePreviousTopSetReps.clear();
        exercisePreviousE1RMs.clear();
      }

      for (var doc in snapshot.docs) {
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

  static Future<int> getExposureCountForExercise({
    required String exerciseName,
    required DateTime blockStart,
    required DateTime blockEnd,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 0;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
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
    // Start with current rep history
    List<int> history = List.from(exercisePreviousTopSetReps[exerciseName] ?? []);

    List<int> result = [];

    for (int i = 0; i < count; i++) {
      // Define inner logic for forbidden reps, scoped to current history
      Set<int> forbidden = {};
      for (int j = 0; j < history.length && j < 4; j++) {
        int rep = history[j];
        if (j == 0) {
          forbidden.addAll([rep - 2, rep - 1, rep, rep + 1, rep + 2]);
        } else if (j == 1) {
          forbidden.addAll([rep - 1, rep, rep + 1]);
        } else if (j == 2 || j == 3) {
          forbidden.add(rep);
        }
      }

      // Cap rep range
      List<int> allReps = List.generate(12, (i) => i + 1);
      List<int> available = allReps.where((r) => !forbidden.contains(r)).toList();

      // Sort by least recent usage
      available.sort((a, b) {
        int aIndex = history.indexOf(a);
        int bIndex = history.indexOf(b);
        if (aIndex == -1 && bIndex == -1) return a.compareTo(b); // both unused
        if (aIndex == -1) return -1; // a is less used
        if (bIndex == -1) return 1; // b is less used
        return aIndex.compareTo(bIndex);
      });

      // Pick best candidate
      int next = available.isNotEmpty ? available.first : 6; // fallback to 6
      result.add(next);

      // Prepend to history to simulate it becoming the most recent
      history.insert(0, next);
    }

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


  static double getSuggestedWeightFromRep(String exerciseName, int reps, double rir) {
    final e1rms = exercisePreviousE1RMs[exerciseName];
    if (e1rms == null || e1rms.isEmpty) return 20.0;

    final recent = e1rms.take(4).toList();
    final avgE1RM = recent.reduce((a, b) => a + b) / recent.length;
    final effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      suggestedWeight = avgE1RM * (37 - effectiveReps) / 36;
    } else {
      suggestedWeight = avgE1RM / (1 + 0.0333 * effectiveReps);
    }

    return (suggestedWeight / 2.5).round() * 2.5; // round to nearest 2.5kg
  }



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
        getSuggestedRepTarget(
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


