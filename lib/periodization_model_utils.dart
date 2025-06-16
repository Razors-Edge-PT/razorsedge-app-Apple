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
  static final List<int> linearClassicDefaults = [10, 8, 6];
  static final List<int> linearExposureDefaults = [12, 10, 8, 6, 4, 2];
  static final List<int> dupSignatureDefaults = [6, 10];
  static Map<String, Map<String, dynamic>> bb2DailyData = {};
  static List<Map<String, dynamic>> savedWorkoutsList = [];

  static Map<String, dynamic> get exerciseSettings => _exerciseSettings;


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
  static String resolveExerciseName(String key) {
    return idToName[key] ?? key;
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
        return PeriodizationModelType.dailyUndulatingWeek; // ✅ Check spelling
      case 'Linear, Classic':
        return PeriodizationModelType.linearClassic;
      case 'Linear, by Exposure':
        return PeriodizationModelType.linearExposure;
      case 'Daily Undulating Periodization':
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
        return PeriodizationModelType.dailyUndulatingWeek;

      case 'DUP, Signature':
        return PeriodizationModelType.dupSignature;

      case 'Daily Undulating Periodization':
        return PeriodizationModelType.dailyUndulatingExposure;

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
    Map<String, dynamic>? repTargetsByExercise,
    Map<String, dynamic>? plannedExerciseDetails,
    DateTime? blockStartDate,   // ✅ NEW
    DateTime? blockEndDate,     // ✅ NEW
  }) {
    print('🧠 [BB2] Rep target requested for: $exerciseName');
    print('🧠 Model detected: ${exercisePeriodizationModels[exerciseName]}');

    final model = exercisePeriodizationModels[exerciseName] ?? PeriodizationModelType.dupSignature;
    print('🧠 getSuggestedRepTargetByModel → $exerciseName using model: $model (plannedIndex: $plannedIndex)');

    try {
      switch (model) {
        case PeriodizationModelType.dailyUndulatingExposure:
          final repTargetsRaw = plannedExerciseDetails?[exerciseName]?['repTargets'];
          final weekMap = repTargetsRaw is Map<String, dynamic>
              ? repTargetsRaw['week1'] as Map<String, dynamic>?
              : null;

          if (weekMap == null || weekMap.isEmpty) {
            print('⚠️ [DUP By Week] No usable data in week1 for $exerciseName');
            return 10;
          }

          // Sort instance keys: instance1, instance2, ...
          final sortedInstances = weekMap.entries
              .where((e) => e.key.startsWith('instance'))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));

          final int frequency = sortedInstances.length;

          if (frequency == 0) {
            print('⚠️ [DUP By Week] No instances found for $exerciseName');
            return 10;
          }

          // Loop through same week1 pattern each week based on plannedIndex
          final instanceIndex = plannedIndex % frequency;
          final instanceEntry = sortedInstances[instanceIndex];
          final raw = instanceEntry.value?.toString() ?? '';

          print('📦 [DUP By Week] Using instance${instanceIndex + 1} = $raw');

          final match = RegExp(r'^(\d+)').firstMatch(raw);
          final parsed = match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;

          print('📈 [DUP By Week] Parsed → $parsed reps (cycled instance ${instanceIndex + 1})');
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
          final repTargetsRaw = repTargetsByExercise?[exerciseName]?['repTargets'] ??
              plannedExerciseDetails?[exerciseName]?['repTargets'];

          print('📦 repTargetsRaw for $exerciseName: ${jsonEncode(repTargetsRaw)}');

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
          final repTargetsRaw = plannedExerciseDetails?[exerciseName]?['repTargets'];
          final weekKey = 'week${(weekIndex ?? 0) + 1}';

          final weekMap = repTargetsRaw is Map<String, dynamic>
              ? (repTargetsRaw[weekKey] ?? repTargetsRaw['week1']) as Map<String, dynamic>?
              : null;

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

    final rounded = roundToNearestValidIncrement(
      targetWeight: suggestedWeight,
      exerciseName: exerciseName,
    );


    print('🧪 [BB2] Top set E1RM history for $exerciseName → $e1rms');
    print('🎯 [BB2] Rounded $suggestedWeight → $rounded using custom increments');
    print('🧩 [BB2] Increments for $exerciseName: ${_exerciseSettings[exerciseName]?['increments']}');


    return rounded;
  }

  static void setExerciseSettings(Map<String, dynamic> settings) {
    _exerciseSettings = settings;
    print('✅ [PMU] setExerciseSettings called with keys: ${settings.keys}');
    final testId = 'AmfUWbF1DH3I7qPAdh5k';
    print('🔍 [PMU] Details for Bench ID ($testId): ${settings[testId]}');

  }

  static Map<String, dynamic> _exerciseSettings = {};

  static double roundToNearestValidIncrement({
    required double targetWeight,
    required String exerciseName,
  }) {
    // Try name first, then fallback to ID
    final byName = _exerciseSettings[exerciseName]?['increments'];
    final id = nameToId[exerciseName];

    print('🧠 [BB2] nameToId lookup for "$exerciseName" → $id');
    print('🧾 [BB2] Details for ID $id → ${_exerciseSettings[id]}');

    Map<String, dynamic>? byId;
    if (id != null && _exerciseSettings.containsKey(id)) {
      byId = _exerciseSettings[id]?['increments'];
    }

    final increments = byName ?? byId;

    if (increments == null) {
      print('❌ [BB2] No increments found for $exerciseName by name or ID');
      return (targetWeight / 2.5).round() * 2.5;
    }

    final double primary = increments['primary']?.toDouble() ?? 2.5;
    final double secondary = increments['secondary']?.toDouble() ?? 0.0;

    final Set<double> options = {};

    for (int i = 0; i < 100; i++) {
      options.add(i * primary); // ✅ Start from 0
    }


    if (secondary > 0) {
      for (final base in options.toList()) {
        options.add(base + secondary);
      }
    }

    final rounded = options.reduce((a, b) =>
    (a - targetWeight).abs() < (b - targetWeight).abs() ? a : b);

    print('📏 [BB2] Valid options for $exerciseName: ${options.toList()..toSet().toList()..sort()}');
    print('🎯 [BB2] Chose: $rounded from target: $targetWeight');

    return rounded;
  }

  static List<double> getIncrementsForExercise(String exerciseNameOrId) {
    final byName = _exerciseSettings[exerciseNameOrId]?['increments'];

    Map<String, dynamic>? byId;
    final id = nameToId[exerciseNameOrId];
    if (id != null && _exerciseSettings.containsKey(id)) {
      byId = _exerciseSettings[id]?['increments'];
    }

    final increments = byName ?? byId;

    if (increments == null) {
      print('❌ [PMU] No increments found for $exerciseNameOrId by name or ID');
      return List.generate(100, (i) => 20 + i * 2.5); // fallback: standard 2.5kg plates
    }

    final double primary = (increments['primary'] as num?)?.toDouble() ?? 2.5;
    final double secondary = (increments['secondary'] as num?)?.toDouble() ?? 0.0;

    final Set<double> weightOptions = {};

    for (int i = 0; i < 100; i++) {
      weightOptions.add(i * primary);
    }

    if (secondary > 0 && secondary != primary) {
      for (final base in weightOptions.toList()) {
        weightOptions.add(base + secondary);
      }
    }

    final list = weightOptions.toList()..sort();
    print('✅ [PMU] getIncrementsForExercise($exerciseNameOrId) → $list');
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
        options.add(20 + i * inc);
      }
    }

    return options.toList()..sort();
  }



  // Progression model logic

  //LinearWeightAdded Model
  static double getProgressedWeight({
    required String exerciseName,
    required int repTarget,
    required double defaultWeight,
    double rirValue = 0, // ✅ optional with default
    required List<double> increments,
    Map<String, dynamic>? maxWeightByReps,
    List<Map<String, dynamic>>? topSetHistory, // optional
    int weekIndex = 0,
  }) {
    if (weekIndex == 0) {
      print('🕓 Week 1 detected → progression disabled, using base weight: $defaultWeight');
      return defaultWeight;
    }

    final previousReps = PeriodizationModelUtils.exercisePreviousTopSetReps[exerciseName];
    if (previousReps == null || previousReps.isEmpty) {
      print('🚫 No top set rep history found for $exerciseName');
      return defaultWeight;
    }

    print('📦 [Progression] Stored top set reps for $exerciseName: $previousReps');
    print('🔍 Looking for a match on repTarget = $repTarget');

    final matchIndex = previousReps.indexWhere((r) => r == repTarget);

    // 🧠 Extract increment properly like in roundToNearestValidIncrement
    final incrementMap = _exerciseSettings[exerciseName]?['increments'] ??
        _exerciseSettings[nameToId[exerciseName]]?['increments'];

    final double increment = (incrementMap?['primary'] as num?)?.toDouble() ?? 2.5;

    if (matchIndex == -1) {
      print('🚫 No matching rep target found in history.');
    } else {
      final matchedReps = previousReps[matchIndex];
      double weightUsed = defaultWeight;

      if (topSetHistory != null && topSetHistory.isNotEmpty) {
        final matchEntry = topSetHistory.firstWhere(
              (entry) => entry['reps'] == repTarget,
          orElse: () => {},
        );
        if (matchEntry.isNotEmpty && matchEntry['weight'] != null) {
          weightUsed = (matchEntry['weight'] as num).toDouble();
          print('📊 [Progression] Using actual weight from history: $weightUsed');
        }
      }

      if (matchedReps >= repTarget) {
        // ✅ Use roundToNearestValidIncrement to determine next progression step
        // Rebuild the same options used inside roundToNearestValidIncrement
        final id = nameToId[exerciseName];
        final increments = _exerciseSettings[exerciseName]?['increments'] ??
            _exerciseSettings[id]?['increments'];

        final double primary = (increments?['primary'] as num?)?.toDouble() ?? 2.5;
        final double secondary = (increments?['secondary'] as num?)?.toDouble() ?? 0.0;

        final Set<double> options = {};

// Build legal weight options
        for (int i = 0; i < 150; i++) {
          final base = 20 + i * primary;
          options.add(double.parse(base.toStringAsFixed(1)));
          if (secondary > 0 && secondary != primary) {
            options.add(double.parse((base + secondary).toStringAsFixed(1)));
          }
        }

        final sorted = options.toList()..sort();

// Find the next higher weight from weightUsed
        double nextHigher = weightUsed;
        for (final option in sorted) {
          if (option > weightUsed) {
            nextHigher = option;
            break;
          }
        }

        print('🎯 [Progression] From $weightUsed → next available: $nextHigher');


        if (topSetHistory != null) {
          final higherAttempts = topSetHistory
              .where((entry) =>
          (entry['weight'] as num).toDouble() == nextHigher)
              .toList();

          if (higherAttempts.isNotEmpty) {
            final bestRepsAtHigher = higherAttempts
                .map((e) => (e['reps'] as num?)?.toInt() ?? 0)
                .reduce((a, b) => a > b ? a : b);

            if (bestRepsAtHigher < repTarget) {
              final newReps = bestRepsAtHigher + 1;
              print('🔁 Progressing reps at $nextHigher: $bestRepsAtHigher → $newReps');
              return nextHigher;
            } else {
              final nextNextHigher = roundToNearestValidIncrement(
                targetWeight: nextHigher + 0.1,
                exerciseName: exerciseName,
              );
              print('⬆️ Target met at $nextHigher → progressing to $nextNextHigher');
              return nextNextHigher;
            }
          }
        }

        print('✅ Rep target $repTarget met. Progressing from $weightUsed → next valid increment: $nextHigher');
        return nextHigher;

      } else if ((repTarget - matchedReps) <= 1) {
        print('➕ Close miss ($matchedReps/$repTarget), keep weight $weightUsed');
        return weightUsed;
      } else {
        print('⚠️ Missed badly ($matchedReps/$repTarget), retry at same weight $weightUsed');
        return weightUsed;
      }

    }


    if (maxWeightByReps != null &&
        (maxWeightByReps['reps'] == repTarget || maxWeightByReps['reps'].toString() == repTarget.toString())) {
      final fallbackWeight = (maxWeightByReps['weight'] as num?)?.toDouble() ?? defaultWeight;
      print('🪂 Using maxWeightByReps fallback → $fallbackWeight');
      return fallbackWeight;
    }

    print('🚨 No match found for $repTarget reps, using defaultWeight → $defaultWeight');
    return defaultWeight;
  }



  static Map<String, dynamic> smartProgressionModel({
    required String exerciseName,
    required int repTarget,
    required double defaultWeight,
    double rirValue = 0, // ✅ optional with default fallback
    required List<double> increments,
    Map<String, dynamic>? maxWeightByReps,
    List<Map<String, dynamic>>? topSetHistory, // optional
    int weekIndex = 0,
  }) {
    print('🧠 [SmartProgression] Entered smartProgressionModel for $exerciseName (week $weekIndex, repTarget: $repTarget)');

    if (weekIndex == 0) {
      print('🕓 Week 1 detected → progression disabled, using base weight: $defaultWeight');
      return {
        'weight': defaultWeight,
        'reps': repTarget,
      };
    }

    if (topSetHistory == null || topSetHistory.isEmpty) {
      print('🚫 No top set history available.');
      return {
        'weight': defaultWeight,
        'reps': repTarget,
      };
    }

    // Calculate effective reps for each historical set (reps + RIR)
    final List<Map<String, dynamic>> historyWithE1RM = topSetHistory.map((entry) {
      final double weight = (entry['weight'] as num?)?.toDouble() ?? 0.0;
      final double reps = (entry['reps'] as num?)?.toDouble() ?? 0.0;
      final double rir = (entry['rir'] as num?)?.toDouble() ?? 0;
      final double e1rm = calculateE1RM(weight, reps, rir);
      final double effectiveReps = reps + rir;
      final DateTime? date = entry['date'] is DateTime
          ? entry['date'] as DateTime
          : DateTime.tryParse(entry['date']?.toString() ?? '');

      return {
        'weight': weight,
        'reps': reps,
        'rir': rir,
        'e1rm': e1rm,
        'effectiveReps': effectiveReps,
        'date': date,
      };
    }).toList();

    final DateTime now = DateTime.now();
    final double targetEffectiveReps = repTarget + 0.0;

    // Step 1: Try to find exact or near match within 4 weeks
    final recentMatch = historyWithE1RM.firstWhere(
          (entry) {
        final date = entry['date'] as DateTime?;
        final eReps = entry['effectiveReps'] as double;
        return date != null &&
            now.difference(date).inDays <= 28 &&
            (eReps - targetEffectiveReps).abs() <= 0.5;
      },
      orElse: () => {},
    );

    double baseE1RM;

    if (recentMatch.isNotEmpty) {
      baseE1RM = recentMatch['e1rm'];
      print('✅ Using recent match for base E1RM → $baseE1RM');
    } else {
      // Step 2: Try average of entries within past 2 weeks
      final recentTwoWeeks = historyWithE1RM.where((entry) {
        final date = entry['date'] as DateTime?;
        return date != null && now.difference(date).inDays <= 14;
      }).toList();

      if (recentTwoWeeks.isNotEmpty) {
        baseE1RM = recentTwoWeeks.map((e) => e['e1rm'] as double).reduce((a, b) => a + b) / recentTwoWeeks.length;
        print('📆 Averaged E1RM from past 2 weeks → $baseE1RM');
      } else if (historyWithE1RM.length >= 4) {
        final lastFour = historyWithE1RM.take(4).toList();
        baseE1RM = lastFour.map((e) => e['e1rm'] as double).reduce((a, b) => a + b) / lastFour.length;
        print('📊 Using average of last 4 E1RMs → $baseE1RM');
      } else if (maxWeightByReps != null) {
        baseE1RM = (maxWeightByReps['weight'] as num?)?.toDouble() ?? defaultWeight;
        print('🪂 Using fallback maxWeightByReps → $baseE1RM');
      } else {
        print('🚨 No viable E1RM source. Using default weight → $defaultWeight');
        return {
          'weight': defaultWeight,
          'reps': repTarget,
        };
      }
    }

    final validWeights = roundToAllValidIncrements(
      baseWeight: defaultWeight,
      exerciseName: exerciseName,
    );

    print('🔍 [SmartProgression] Valid weights for $exerciseName:\n$validWeights');

    double bestWeight = defaultWeight;
    int bestReps = repTarget;
    double bestE1RM = baseE1RM;
    double bestScore = double.infinity;

    final double minProgressionPercent = 0.01; // 1% increase
    final double maxProgressionPercent = 0.03; // 3% cap
    final double minTargetE1RM = baseE1RM * (1 + minProgressionPercent);
    final double maxTargetE1RM = baseE1RM * (1 + maxProgressionPercent);

    for (final w in validWeights) {
      final Set<int> repTrials = {
        for (int d = -2; d <= 6; d++) (repTarget + d).clamp(1, 25),
        repTarget + 1, // ✅ Force include +1 rep
      };

      for (final tryReps in repTrials) {

        final double tryE1RM = calculateE1RM(w, tryReps.toDouble(), rirValue);


        if (tryE1RM < minTargetE1RM || tryE1RM > maxTargetE1RM) continue;

        final double e1rmOverage = tryE1RM - baseE1RM; // ✅ actual gain
        final double repDistance = (tryReps - repTarget).abs().toDouble();
        final double weightDistance = (w - defaultWeight).abs();

        // ✅ Prefer smallest valid E1RM increase + staying close to weight/reps
        final double score = (e1rmOverage * 1.0) + (repDistance * 1.5) + (weightDistance * 1.0);

        if (score < bestScore) {
          bestScore = score;
          bestWeight = w;
          bestReps = tryReps;
          bestE1RM = tryE1RM;
        }
        print('🔍 Trying: $w kg × $tryReps → E1RM = ${tryE1RM.toStringAsFixed(2)}');

        print('🔬 Trial: $w kg × $tryReps → E1RM = ${tryE1RM.toStringAsFixed(1)} (score = ${score.toStringAsFixed(2)})');
      }

    }

// After bestWeight, bestReps, bestE1RM are selected...
    final usedCombos = PeriodizationModelUtils.getUsedWeightRepsRirTripletsForExercise(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList, // ✅ reference static list
    );

// Convert current best to string key format for easy comparison
    final comboKey = '${bestWeight.toStringAsFixed(1)}_${bestReps}_${rirValue.toStringAsFixed(1)}';
    print('🔍 Final comboKey = $comboKey');
    print('📘 Used combos: $usedCombos');

// Check for duplication
    if (usedCombos.contains(comboKey)) {
      print('⚠️ [SmartProgression] Duplicate found for $comboKey → increasing reps to ensure novelty');

      // Bump reps by 1 if possible
      if (bestReps < 25) {
        bestReps += 1;
        bestE1RM = calculateE1RM(bestWeight, bestReps.toDouble(), rirValue);
        print('🔁 New recommendation: ${bestWeight}kg × $bestReps @ RIR $rirValue → E1RM = ${bestE1RM.toStringAsFixed(2)}');
      } else {
        print('❌ Cannot increase reps beyond 25 — keeping original suggestion.');
      }
    }



    print('🎯 Smart progression chosen: weight = $bestWeight, reps = $bestReps, RIR = $rirValue, projected E1RM = $bestE1RM (base = $baseE1RM)');

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
    print('🧠 [AddRepsProgression] Entered model for $exerciseName, week $weekIndex, OG reps = $repTarget');

    if (weekIndex == 0) {
      print('🕓 Week 1 detected → base weight and rep target used');
      return {
        'weight': defaultWeight,
        'reps': repTarget,
      };
    }

    // Load top set history
    final recentSets = PeriodizationModelUtils.topSetsByExercise[exerciseName] ?? [];

    if (recentSets.isEmpty) {
      print('🚫 No previous top sets found → using default weight and reps');
      return {
        'weight': defaultWeight,
        'reps': repTarget,
      };
    }

// 🐞 DEBUG: Show the most recent 4 entries
    print('🧾 [DEBUG] Top 4 sets for $exerciseName:');
    for (int i = 0; i < recentSets.length.clamp(0, 4); i++) {
      final set = recentSets[i];
      final w = (set['weight'] as num?)?.toDouble() ?? 0;
      final r = (set['reps'] as num?)?.toInt() ?? 0;
      final rir = (set['rir'] as num?)?.toDouble() ?? 0;
      final d = set['date'] ?? 'No Date';
      print('  #${i + 1} → $w kg × $r @ RIR $rir on $d');
    }

    recentSets.sort((a, b) {
      final aDate = a['date'] is DateTime ? a['date'] as DateTime : DateTime.tryParse(a['date']?.toString() ?? '') ?? DateTime(2000);
      final bDate = b['date'] is DateTime ? b['date'] as DateTime : DateTime.tryParse(b['date']?.toString() ?? '') ?? DateTime(2000);
      return bDate.compareTo(aDate); // descending
    });

    final latest = recentSets.first;

    final double lastWeight = (latest['weight'] as num?)?.toDouble() ?? defaultWeight;
    final int lastReps = (latest['reps'] as num?)?.toInt() ?? repTarget;

    print('📦 [AddRepsProgression] Last top set: $lastWeight × $lastReps');


    final currentE1RM = calculateE1RM(lastWeight, lastReps.toDouble(), rirValue);

    print('📈 Current E1RM = ${currentE1RM.toStringAsFixed(2)} from $lastWeight × $lastReps');

    // Build valid weight options
    final validWeights = roundToAllValidIncrements(
      baseWeight: defaultWeight,
      exerciseName: exerciseName,
    );
    validWeights.sort();
    final int weightIndex = validWeights.indexOf(lastWeight);
    final double? nextWeight = (weightIndex >= 0 && weightIndex + 1 < validWeights.length)
        ? validWeights[weightIndex + 1]
        : null;

    if (nextWeight == null) {
      print('🚧 No next weight found → staying at current');
      return {
        'weight': lastWeight,
        'reps': lastReps + 1,
      };
    }

    // Gating logic
    final int repsAboveOG = lastReps - repTarget;
    List<int> allowedNextWeightRepOptions = [];
    if (repsAboveOG >= 2) allowedNextWeightRepOptions.add(repTarget);       // OG
    if (repsAboveOG >= 3) allowedNextWeightRepOptions.add(repTarget - 1);   // OG -1
    if (repsAboveOG >= 4) allowedNextWeightRepOptions.add(repTarget - 2);   // OG -2

    double? promotedWeight;
    int? promotedReps;

    for (final reps in allowedNextWeightRepOptions) {
      if (reps < 1) continue;

      final double tryE1RM = calculateE1RM(nextWeight, reps.toDouble(), rirValue);
      final double threshold = tryE1RM * 1.040;

      print('🔍 Try $nextWeight × $reps → E1RM = ${tryE1RM.toStringAsFixed(2)}, threshold = ${threshold.toStringAsFixed(2)}');

      if (currentE1RM >= threshold) {
        print('✅ Threshold met → move to $nextWeight × $reps');
        promotedWeight = nextWeight;
        promotedReps = reps;
        break; // prefer higher reps (OG > OG-1 > OG-2)
      }
    }

    if (promotedWeight != null && promotedReps != null) {
      return {
        'weight': promotedWeight,
        'reps': promotedReps,
      };
    }

    print('➕ Staying at $lastWeight → increase reps to ${lastReps + 1}');
    return {
      'weight': lastWeight,
      'reps': lastReps + 1,
    };
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
  })
  {
    print("🧪 [Routing] About to run model logic: $model");

    switch (model) {
      case ProgressionModelType.linearWeightIncrease:
        return {
          'weight': getProgressedWeight(
            exerciseName: exerciseName,
            repTarget: repTarget,
            defaultWeight: defaultWeight,
            increments: increments,
            maxWeightByReps: maxWeightByReps,
            topSetHistory: topSetHistory,
            weekIndex: weekIndex,
          ),
          'reps': repTarget, // ← preserve original repTarget for now
        };

      case ProgressionModelType.smartProgression:
        return smartProgressionModel(
          exerciseName: exerciseName,
          repTarget: repTarget,
          defaultWeight: defaultWeight,
          increments: increments,
          maxWeightByReps: maxWeightByReps,
          topSetHistory: topSetHistory,
          weekIndex: weekIndex,
          rirValue: rirValue, // ✅ add this
        );

      case ProgressionModelType.addRepsProgressionModel:
        return addRepsProgressionModel(
          exerciseName: exerciseName,
          repTarget: repTarget,
          defaultWeight: defaultWeight,
          increments: increments,
          maxWeightByReps: maxWeightByReps,
          topSetHistory: topSetHistory,
          weekIndex: weekIndex,
          rirValue: rirValue,
        );



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

  static Future<void> fetchFullTopSetHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    print('🧠 [SmartProgression] Fetching full top set history...');
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(20)
        .get();

    topSetsByExercise.clear();

    for (var doc in snapshot.docs) {
      final workout = Workout.fromFirestore(doc);

      for (var exercise in workout.exercises) {
        final String name = exercise.name;

        for (var set in exercise.sets) {
          final double weight = _parseToDouble(set.weight);
          final double reps = _parseToDouble(set.reps);
          final double rir = _parseToDouble(set.rir);

          // Only store top sets (you can apply your own filtering logic here)
          if (reps > 0 && weight > 0) {
            topSetsByExercise.putIfAbsent(name, () => []);
            topSetsByExercise[name]!.add({
              'weight': weight,
              'reps': reps,
              'rir': rir,
              'date': workout.date,
            });
          }
        }
      }
    }

    print('✅ [SmartProgression] Loaded sets for: ${topSetsByExercise.keys}');
  }

  static Future<void> fetchLastWorkoutTopSetReps() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    print('🧪 [PMU] Fetching top sets for: ${user.uid}');


    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .orderBy('date', descending: true) // ✅ Fetch newest first
        .limit(12) // ✅ Get last 12 workouts
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
    required int weekIndex,
  }) {
    final weekStart = blockStartDate.add(Duration(days: weekIndex * 7));
    final weekEnd = weekStart.add(const Duration(days: 7));

    final usedDates = <String>{};



    for (final workout in savedWorkouts) {
      final dateStr = workout['date'] ?? '';
      final date = DateTime.tryParse(dateStr);
      if (date == null || date.isBefore(weekStart) || date.isAfter(weekEnd)) continue;

      final exercises = workout['exercises'];
      if (exercises is! List) continue;

      final targetId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
      final hasExercise = exercises.any((ex) {
        final exId = ex['exerciseId']?.toString();
        return exId == targetId;
      });


      if (hasExercise) {
        usedDates.add(dateStr); // Count once per day
      }
    }

    final count = usedDates.length;
    print('📊 [Week Instance Count] "$exerciseName" used on $count day(s) in week ${weekIndex + 1}');
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
          print('✅ Used combo added from exercises: $key');
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


