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
import 'periodization_model_utils.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
// For JSON encoding
import 'debounce_Utils.dart';
import 'block_planner_repository.dart';
import 'block_repository.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';

Future<void> deleteAllUserWorkouts() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return; // Exit if no user is signed in

  try {
    final collectionRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts');

    final snapshot = await collectionRef.get();

    for (var doc in snapshot.docs) {
      await doc.reference.delete(); // Deletes each workout document
    }
  } catch (e) {
    // Handle error silently or show a message to the user if needed
  }
}

class BlockMeta {
  final String id;
  final String? name; // ✅ Now nullable
  final DateTime? startDate; // ✅ nullable
  final DateTime? endDate;   // ✅ nullable
  final List<String> selectedDays;

  BlockMeta({
    required this.id,
    this.name,
    this.startDate, // ✅ optional
    this.endDate,   // ✅ optional
    required this.selectedDays,
  });
}



class WorkoutPage extends StatefulWidget {
  final Template? initialTemplate;
  final Workout? workout; // Make workout optional
  final bool isNewWorkout;
  final List<Map<String, dynamic>>? prefilledExercisesWithCircuits;
  final List<String>? prefilledExercises; // ✅ Add this line back
  final DateTime? initialDate; // ✅ Add this line
  final String? initialWorkoutName; // ✅ Add this
  final String? blockId; // ✅ Needed for BP/BB2 integration

  const WorkoutPage({
    Key? key,
    this.initialTemplate,
    this.workout,
    this.isNewWorkout = true,
    this.prefilledExercisesWithCircuits,
    this.prefilledExercises, // ✅ Don’t forget this!
    this.initialDate,
    this.initialWorkoutName,
    this.blockId, // ✅ Wire through from navigation
  }) : super(key: key);

  @override
  _WorkoutPageState createState() => _WorkoutPageState();
}

class _WorkoutPageState extends State<WorkoutPage> with WidgetsBindingObserver {
  List<String> exercises = []; // Store selected exercises from dialog
  final TextEditingController _workoutNameController = TextEditingController();
  late DateTime _selectedDate;
  final List<Map<String, dynamic>> _selectedExercisesWithCircuits = [];
  List<String> plannedExercises = [];
  Map<String, Map<String, dynamic>> _exerciseSettings = {};
  Map<String, String> nameToIdMap = {}; // 🧠 Exercise name ➔ ID
  final List<List<SetDetails>> _workoutSets = [];
  final List<List<TextEditingController>> _repsControllers = [];
  final List<List<TextEditingController>> _weightControllers = [];
  final List<List<TextEditingController>> _rirControllers = [];
  List<List<TextEditingController>> _velocityControllers = [];
  List<List<TextEditingController>> _notesControllers = [];
  Map<String, bool> _showVelocityByExercise = {}; // exerciseName.toLowerCase() → true/false

  String get userId => UserContext.of(context, listen: false).currentUid;
  String? _lastMergedUid;
  late final String _cachedUid;
  DateTime? _lastMergedDate;



  final int _defaultSets = 3;
  VoidCallback? _lastUndoAction;
  Set<String> _selectDateHintFields = {};


  // 🧠 Block metadata
  DateTime? _blockStartDate;
  DateTime? _blockEndDate;
  DateTime? blockStartDate;
  DateTime? blockEndDate;


  List<String> _selectedDays = [];
  String? _activeBlockId;
  String? _selectedBlockId;
  List<BlockMeta> _allBlocks = [];

  late final BlockPlannerRepository _repo;

  // 🧠 BB2 and progression logic
  Map<String, Map<String, dynamic>> _bb2DataByExercise = {};
  Map<String, Map<String, dynamic>> _resolvedBB2Values = {};
  Map<String, String> _progressionModelsByExercise = {};
  final Map<int, Map<String, dynamic>> _cachedProgressedValues = {};

  bool _isLoadingData = true;
  bool _isInitialized = false;


  late Future<void> _initialLoad;
  late Future<void> _blockDateLoad;
  bool _delayRenderCards = true;

  //UI bits
  late ScrollController _horizontalScrollController;

  Future<void> loadPreviousWorkoutData() async {
    await PeriodizationModelUtils.fetchLastWorkoutTopSetReps(
      uid: UserContext.of(context, listen: false).currentUid,
    );

    setState(() {
      _isLoadingData = false; // ✅ Data has been fetched, UI can update
    });
  }

  static const TextStyle _headerStyle = TextStyle(
    fontSize: 10.0,
    color: Colors.white70,
    fontWeight: FontWeight.bold,
  );


  Future<void> loadPlannedExercisesFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(widget.blockId)
        .get();

    print(
        '[WorkoutPage] loading plannedExercises for blockId=${widget.blockId}');

    if (doc.exists) {
      final data = doc.data();
      if (data != null && data['plannedExercises'] != null) {
        setState(() {
          plannedExercises = List<String>.from(data['plannedExercises']);
        });
      } else {
        setState(() {
          plannedExercises = []; // ✅ If null, safely empty list
        });
      }
    } else {
      setState(() {
        plannedExercises = []; // ✅ If doc doesn't exist, safely empty list
      });
    }
  }

  // ✅ Custom Hybrid E1RM Formula: Brzycki for ≤6 reps, Epley for >6 reps
  double calculateE1RM(double? weight, double? reps, double? rir) {
    double w = weight ?? 0.0;
    double r = reps ?? 0.0;
    double rValue = rir ?? 0.0;
    double totalReps = r + rValue; // ✅ No clamping, keeps raw calculation

    if (totalReps <= 6) {
      // ✅ Brzycki for low reps (≤6)
      return w * (36 / (37 - totalReps));
    } else {
      // ✅ Epley for higher reps (>6)
      return w * (1 + (0.0333 * totalReps));
    }
  }

  /// ✅ Helper Function to Parse Any Firestore Value to a Double
  double _parseToDouble(dynamic value) {
    if (value is double) return value; // ✅ Already a double, return it
    if (value is int) return value.toDouble(); // ✅ Convert int to double
    if (value is String)
      return double.tryParse(value) ?? 0; // ✅ Convert String to double
    return 0; // ✅ Default case
  }

  //Determine available rep targets for this workout:
  Map<String, List<double>> exercisePreviousE1RMs =
  {}; // ✅ E1RM history per exercise

  Map<String, List<int>> exercisePreviousTopSetReps =
  {}; // ✅ Tracks reps per exercise

  double getAverageE1RM(String exerciseName) {
    if (!PeriodizationModelUtils.exercisePreviousE1RMs
        .containsKey(exerciseName) ||
        PeriodizationModelUtils.exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      return 0.0; // ✅ Default if no history
    }

    List<double> recentE1RMs = PeriodizationModelUtils
        .exercisePreviousE1RMs[exerciseName]!
        .take(4)
        .toList();
    return recentE1RMs.reduce((a, b) => a + b) / recentE1RMs.length;
  }

  double getSet2E1RM(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set1Weight =
        double.tryParse(_weightControllers[exerciseIndex][0].text) ??
            set1SuggestedWeight(exerciseIndex);
    int set1Reps = int.tryParse(_repsControllers[exerciseIndex][0].text) ??
        set1SuggestedReps(exerciseIndex).toInt();
    double set1RIRValue =
        double.tryParse(_rirControllers[exerciseIndex][0].text) ??
            set1RIR(exerciseIndex);
    double set1EffectiveReps = set1Reps + set1RIRValue;

    double set1E1RM = (set1EffectiveReps <= 6)
        ? (set1Weight * (36 / (37 - set1EffectiveReps))) // Brzycki for low reps
        : (set1Weight *
        (1 + (0.0333 * set1EffectiveReps))); // Epley for high reps

    print(
        "Set 2 E1RM for $exerciseName: ${set1E1RM.toStringAsFixed(
            1)}"); // ✅ Debugging
    return (set1E1RM > 7) ? (set1E1RM - 7) : 1.0;
  }

  double getSet3E1RM(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set1Weight =
        double.tryParse(_weightControllers[exerciseIndex][0].text) ??
            set1SuggestedWeight(exerciseIndex);
    int set1Reps = int.tryParse(_repsControllers[exerciseIndex][0].text) ??
        set1SuggestedReps(exerciseIndex).toInt();
    double set1RIRValue =
        double.tryParse(_rirControllers[exerciseIndex][0].text) ??
            set1RIR(exerciseIndex);
    double set1EffectiveReps = set1Reps + set1RIRValue;

    double set1E1RM = (set1EffectiveReps <= 6)
        ? (set1Weight * (36 / (37 - set1EffectiveReps))) // Brzycki for low reps
        : (set1Weight *
        (1 + (0.0333 * set1EffectiveReps))); // Epley for high reps

    return (set1E1RM > 7) ? (set1E1RM - 10.5) : 1.0;
  }

  Future<void> _fetchLastWorkoutTopSetReps() async {
    final uid = UserContext.of(context, listen: false).currentUid;
    if (uid == null) return;
    print('📡 Fetching top sets for user: $uid');

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .orderBy('date', descending: true) // ✅ Fetch newest first
        .limit(12) // ✅ Get last 12 workouts
        .get();

    if (snapshot.docs.isNotEmpty) {
      setState(() {
        exercisePreviousTopSetReps.clear(); // ✅ Reset reps per exercise
        exercisePreviousE1RMs.clear(); // ✅ Reset E1RMs per exercise

        for (var doc in snapshot.docs) {
          final workout = Workout.fromFirestore(doc);

          if (workout.exercises.isNotEmpty) {
            for (var exercise in workout.exercises) {
              String exerciseName =
                  exercise.name; // ✅ Exercise-specific tracking

              SetDetails? topSet;
              double highestE1RM = 0.0;

              for (var set in exercise.sets) {
                double weight = _parseToDouble(set.weight);
                double reps = _parseToDouble(set.reps);
                double rir = _parseToDouble(set.rir);
                double totalReps = reps + rir;

                double e1rm = (totalReps <= 6)
                    ? (weight * (36 / (37 - totalReps))) // Brzycki formula
                    : (weight * (1 + (0.0333 * totalReps))); // Epley formula

                if (topSet == null || e1rm > highestE1RM) {
                  highestE1RM = e1rm;
                  topSet = set;
                }
              }

              if (topSet != null) {
                int effectiveReps =
                (_parseToDouble(topSet.reps) + _parseToDouble(topSet.rir))
                    .floor();

                // ✅ Store E1RM per exercise
                exercisePreviousE1RMs.putIfAbsent(exerciseName, () => []);
                exercisePreviousE1RMs[exerciseName]!.add(highestE1RM);

                // ✅ Keep only last 4 E1RMs per exercise
                if (exercisePreviousE1RMs[exerciseName]!.length > 4) {
                  exercisePreviousE1RMs[exerciseName] =
                      exercisePreviousE1RMs[exerciseName]!.take(4).toList();
                }

                // ✅ Store reps per exercise
                exercisePreviousTopSetReps.putIfAbsent(exerciseName, () => []);
                exercisePreviousTopSetReps[exerciseName]!.add(effectiveReps);

                // ✅ Keep only last 12 reps per exercise
                if (exercisePreviousTopSetReps[exerciseName]!.length > 12) {
                  exercisePreviousTopSetReps[exerciseName] =
                      exercisePreviousTopSetReps[exerciseName]!
                          .take(12)
                          .toList();
                }
              }
            }
          }
          // 🔍 Print final stored top sets for debugging
          for (final entry in exercisePreviousE1RMs.entries) {
            final name = entry.key;
            final e1rms = entry.value.map((e) => e.toStringAsFixed(2)).join(', ');
            final reps = exercisePreviousTopSetReps[name]?.join(', ') ?? '—';
            print('🔍 Top sets for $name → E1RMs: [$e1rms], Reps: [$reps]');
        }}
      });
    }
  }

  String? getRepTargetForExerciseWES(String exerciseName, int rowIndex) {
    if (_blockStartDate == null || _selectedDate == null) {
      print('❌ [WES] Block start or selected date is null');
      return null;
    }

    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
    if (exerciseId == null) return null;

    final details = PeriodizationModelUtils.plannedExerciseDetails[exerciseId];
    if (details == null) return null;

    final repTargets = details['repTargets'];
    if (repTargets == null) return null;

    final model = PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];
    final weekIndex = getWeekIndexFromDate(_selectedDate!, _blockStartDate!);

    print('🔍 [WES] Getting repTarget for $exerciseId → model: $model, weekIndex: $weekIndex');

    try {
      int? rep;

      switch (model) {
        case PeriodizationModelType.linearExposure:
          final exposureIndex = rowIndex;
          rep = PeriodizationModelUtils.getLinearExposureRepTarget(
            exerciseId: exerciseId,
            exposureIndex: exposureIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
          );
          break;

        case PeriodizationModelType.linearClassic:
        case PeriodizationModelType.dailyUndulatingWeek:
          rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: rowIndex,
            weekIndex: weekIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
            blockStartDate: _blockStartDate,
            blockEndDate: _blockEndDate,
          );
          break;

        case PeriodizationModelType.dupSignature:
        case PeriodizationModelType.dailyUndulatingExposure:
          rep = PeriodizationModelUtils.getSuggestedRepTargetByModel(
            exerciseName: exerciseId,
            plannedIndex: rowIndex,
            weekIndex: weekIndex,
            repTargetsByExercise: {exerciseId: {'repTargets': repTargets}},
            plannedExerciseDetails: PeriodizationModelUtils.plannedExerciseDetails,
          );
          break;

        default:
          return null;
      }

      print('✅ [WES] Final rep target for $exerciseName (row $rowIndex) = $rep');
      return rep?.toString();
    } catch (e) {
      print('❌ [WES] Error in getRepTargetForExerciseWES: $e');
      return null;
    }
  }




  double bb2HintReps(int i) {
    final exerciseName = _selectedExercisesWithCircuits[i]['name']?.trim() ?? '';
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;

    if (_blockStartDate == null || _selectedDate == null) {
      print('❌ [WES] 1_blockStartDate or _selectedDate is null — cannot compute weekIndex');
      return 10.0;
    }

    final weekIndex = getWeekIndexFromDate(_selectedDate!, _blockStartDate!);

    final repTarget = getRepTargetForExerciseWES(exerciseName, 0);


    if (repTarget == null || repTarget.trim().isEmpty) {
      print('❌ [WES] No rep target found for $exerciseName (week $weekIndex)');
      return 10.0;
    }

    final parsed = double.tryParse(repTarget.split('x').first.trim());
    print('🔢 [WES] BB2 hintReps for $exerciseName (week $weekIndex) = $parsed');
    return parsed ?? 10.0;
  }



  int getWeekIndexFromDate(DateTime selectedDate, DateTime blockStartDate) {
    return selectedDate.difference(blockStartDate).inDays ~/ 7;
  }




  void _debugPrintBlockDates() {
    print('🗓️ [DEBUG] _blockStartDate: $blockStartDate');
    print('🗓️ [DEBUG] _blockEndDate: $blockEndDate');
  }

  Future<void> debugPrintRepTargetsFromExerciseSettings(
      BuildContext context,
      String blockId,
      String exerciseId,
      ) async {
    final uid = UserContext.of(context, listen: false).actingAsUid;


    final docRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId);

    final docSnap = await docRef.get();
    if (!docSnap.exists) {
      print('🚫 [DEBUG] Block document not found for $blockId');
      return;
    }

    final data = docSnap.data();
    if (data == null || !data.containsKey('exerciseSettings')) {
      print('🚫 [DEBUG] No exerciseSettings field in block document.');
      print('🧾 [DEBUG] Full block doc:\n${jsonEncode(data)}');

      return;
    }

    final settings = data['exerciseSettings'][exerciseId];
    if (settings == null) {
      print('🚫 [DEBUG] No exerciseSettings found for $exerciseId');
      return;
    }

    final repTargets = settings['repTargets'];
    print('🔍 [DEBUG] repTargets from exerciseSettings for $exerciseId:\n${jsonEncode(repTargets)}');

    final week1 = repTargets?['week1'];
    if (week1 is! Map<String, dynamic>) {
      print('❌ [DEBUG] week1 not found in repTargets for $exerciseId');
      return;
    }

    final sorted = week1.entries
        .where((e) => e.key.startsWith('instance'))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    for (final e in sorted) {
      print('✅ [DEBUG] $exerciseId → ${e.key}: ${e.value}');
    }
  }


  Map<String, dynamic> _getProgressedValues(int exerciseIndex) {

    Future.microtask(() async {
      print('🐛 [WES] Triggering debugPrintRepTargetsFromExerciseSettings...');

      final blockId = _selectedBlockId;
      final exerciseName = _selectedExercisesWithCircuits.isNotEmpty
          ? _selectedExercisesWithCircuits.first['name']?.trim()
          : null;

      final exerciseId = exerciseName != null
          ? PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName
          : null;

      print('🛠 DEBUG: About to call debugPrintRepTargetsFromExerciseSettings with:');
      print('🔑 Block ID: $blockId');
      print('🏋️ Exercise Name: $exerciseName');
      print('💪 Exercise ID: $exerciseId');

      if (blockId != null && exerciseId != null) {
        await debugPrintRepTargetsFromExerciseSettings(
          context,
          blockId,
          exerciseId,
        );
      } else {
        print('🚫 [DEBUG] Could not resolve blockId or exerciseId from WES state.');
      }
    });




    // 🧠 STEP 1: If we already cached a GOOD value, return it
    final cached = _cachedProgressedValues[exerciseIndex];
    if (cached != null && blockStartDate != null && blockEndDate != null) {
      return cached;
    }

    _debugPrintBlockDates();
    // Get exercise info.
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;

    final weekIndex = _getApplicableWeekIndex(exerciseId);
    print('📅 [WES] selectedDate = $_selectedDate');
    print('📅 [WES] blockStartDate = $blockStartDate');
    print('🧮 [WES] Computed weekIndex = ${blockStartDate != null ? PeriodizationModelUtils.getWeekIndexForDate(_selectedDate, blockStartDate!) : '⚠️ blockStartDate is null!'}');



    // Determine how many times this exercise appeared before.
    int plannedCountBefore = 0;
    for (int i = 0; i < exerciseIndex; i++) {
      if (_selectedExercisesWithCircuits[i]['name'] == exerciseName) {
        plannedCountBefore++;
      }
    }

    // Get rep target.
    double repTarget;
    final model =
    PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];
    print('🔎 [WES] Progression model for $exerciseId (${exerciseName}): $model');

    if (model == PeriodizationModelType.dailyUndulatingExposure) {
      // (Assuming your existing model-specific logic is used here)
      final fullDetails = _exerciseSettings[exerciseId];
      final week1 = fullDetails?['repTargets']?['week1'];


      print('🔍 [WES] Checking DUP Exposure → exerciseId: $exerciseId, exerciseName: $exerciseName');
      print('📦 Full exerciseSettings[$exerciseId] = ${jsonEncode(fullDetails)}');
      print('📦 repTargets = ${jsonEncode(fullDetails?['repTargets'])}');
      print('📦 week1 = ${jsonEncode(week1)}');

      if (week1 is Map<String, dynamic>) {
        final sorted = week1.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        if (sorted.isNotEmpty) {

          final count =
          PeriodizationModelUtils.getInstanceCountForExerciseInBlock(
            exerciseName: exerciseName,
            savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
            blockStartDate: blockStartDate!,
            blockEndDate: blockEndDate!,
          );
          final index = count % sorted.length;
          final raw = sorted[index].value?.toString() ?? '';
          final match = RegExp(r'^(\d+)').firstMatch(raw);
          print('📦 Sorted week1 entries = ${sorted.map((e) => '${e.key}: ${e.value}').toList()}');
          print('🔢 Calculated instance count = $count → index = $index');
          print('🧾 raw value = "$raw"');
          print('📈 match = ${match?.group(1)}');

          repTarget = match != null
              ? int.tryParse(match.group(1)!)?.toDouble() ?? 10.0
              : 10.0;
        } else {
          repTarget = 10.0;
        }
      } else {
        repTarget = PeriodizationModelUtils.getSuggestedRepTargetByModel(
          exerciseName: exerciseId,
          plannedIndex: plannedCountBefore,
          weightText: _weightControllers[exerciseIndex][0].text,
          rirText: _rirControllers[exerciseIndex][0].text,
          weekIndex: weekIndex,
        ).toDouble();
      }
    } else if (model == PeriodizationModelType.dailyUndulatingWeek) {
      final weekKey = 'week${(weekIndex ?? 0) + 1}';
      final weekMap = _exerciseSettings[exerciseId]?['repTargets']?[weekKey];

      if (weekMap is Map<String, dynamic>) {
        final sorted = weekMap.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));

        if (sorted.isNotEmpty) {
          if (blockStartDate == null) {
            repTarget = 10.0;
          } else {
            final count = PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
              exerciseName: exerciseName,
              savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
              blockStartDate: blockStartDate!,
              weekIndex: weekIndex ?? 0,
            );
            final index = count % sorted.length;
            final raw = sorted[index].value?.toString() ?? '';
            final match = RegExp(r'^(\d+)').firstMatch(raw);
            print('📦 Sorted week1 entries = ${sorted.map((e) => '${e.key}: ${e.value}').toList()}');
            print('🔢 Calculated instance count = $count → index = $index');
            print('🧾 raw value = "$raw"');
            print('📈 match = ${match?.group(1)}');

            repTarget = match != null
                ? int.tryParse(match.group(1)!)?.toDouble() ?? 10.0
                : 10.0;
          }
        } else {
          repTarget = 10.0;
        }
      } else {
        repTarget = 10.0;
      }


      // ✅ Debug after dailyUndulatingWeek repTarget is determined
      print('🎯 [WES] dailyUndulatingWeek → repTarget = $repTarget for $exerciseName on $weekKey');

    } else if (model == PeriodizationModelType.linearClassic) {

      final repTargets = _exerciseSettings[exerciseId]?['repTargets'];

      print('🧠 [WES] LinearClassic → exerciseId = $exerciseId');
      print('📌 repTargets = $repTargets');
      print('📆 weekIndex = $weekIndex');

      final weekStart = repTargets?['week1'];
      final week = weekIndex ?? 0;
      final blockLength = PeriodizationModelUtils.getBlockLength(
        blockStartDate: blockStartDate!,
        blockEndDate: blockEndDate!,
      );
      if (weekStart is Map<String, dynamic>) {
        final instanceCount =
        PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
          exerciseName: exerciseName,
          savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
          blockStartDate: blockStartDate!,
          weekIndex: week,
        );
        final sortedKeys = weekStart.keys
            .where((k) => k.startsWith('instance'))
            .toList()
          ..sort();
        if (sortedKeys.isNotEmpty) {
          final instanceKey = sortedKeys[instanceCount % sortedKeys.length];
          final startRaw = weekStart[instanceKey]?.toString() ?? '10 x 3';
          final startMatch = RegExp(r'^(\d+)').firstMatch(startRaw);
          final startReps = startMatch != null
              ? int.tryParse(startMatch.group(1)!) ?? 10
              : 10;
          const endReps = 1;
          repTarget =
              (startReps + ((endReps - startReps) * (week / (blockLength - 1))))
                  .roundToDouble();
        } else {
          repTarget = 10.0;
        }
      } else {
        repTarget = 10.0;
      }
    } else {
      repTarget = PeriodizationModelUtils.getSuggestedRepTargetByModel(
        exerciseName: exerciseId,
        plannedIndex: plannedCountBefore,
        weightText: _weightControllers[exerciseIndex][0].text,
        rirText: _rirControllers[exerciseIndex][0].text,
        weekIndex: weekIndex,
      ).toDouble();
    }

    // Get default weight using rep and RIR logic.


    // Get the progression model info.
    final String? progressionModelName = _exerciseSettings[exerciseId]?['progressionModel'];
    print('🔧 [WES] progressionModelName for $exerciseId = $progressionModelName');
    print('📦 [WES] Full _exerciseSettings for $exerciseId: ${jsonEncode(_exerciseSettings[exerciseId])}');

    final progressionModel =
    PeriodizationModelUtils.parseProgressionModel(progressionModelName);
    final double rir = getRirFromPlanOrInput(exerciseIndex, 1);

    final double defaultWeight =
    PeriodizationModelUtils.getSuggestedWeightFromRep(
      exerciseName,
      repTarget.toInt(),
      rir,
    );

    // Call the progression model (which contains its internal logic).
    final increments = PeriodizationModelUtils.getIncrementsForExercise(exerciseId);
    if (increments == null || increments.isEmpty) {
    }

    final Map<String, dynamic> progressed =
    PeriodizationModelUtils.getWeightByProgressionModel(
      model: progressionModel,
      exerciseName: exerciseName,
      repTarget: repTarget.toInt(),
      defaultWeight: defaultWeight,
      rirValue: rir,
      increments: increments ?? [2.5], // ✅ fallback
      maxWeightByReps: _exerciseSettings[exerciseId]?['maxWeightByReps'],

      topSetHistory: PeriodizationModelUtils.topSetsByExercise[exerciseName],
      weekIndex: PeriodizationModelUtils.getWeekIndexForDate(_selectedDate, blockStartDate!),

    );


    // Cache and return
    _cachedProgressedValues[exerciseIndex] = progressed;

    print('🧮 [WES] Progressed for ${exerciseName} = ${progressed['weight']} kg @ ${repTarget} reps, RIR $rir');

    return progressed;
  }

  //Determine hint texts for this workout:NEW METHOD

  double set1SuggestedReps(int exerciseIndex) {

    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final rirText = _rirControllers[exerciseIndex][0].text;
    final weightText = _weightControllers[exerciseIndex][0].text;
    final repsText = _repsControllers[exerciseIndex][0].text;

    final normalizedKey = exerciseName.toLowerCase();
    final bb2Entry = _resolvedBB2Values[normalizedKey];

    final double? reps = double.tryParse(repsText);
    final double? weight = double.tryParse(weightText);
    final double rawRIR = double.tryParse(rirText) ?? set1RIR(exerciseIndex);
    final double? bb2Reps = bb2Entry?['reps']?.toDouble();
    final double? bb2Weight = bb2Entry?['weight']?.toDouble();
    final dynamic bb2RirRaw = bb2Entry?['rir'];
    final double? bb2Rir = (bb2RirRaw is num && bb2RirRaw > 0)
        ? (bb2RirRaw as num).toDouble()
        : null;

    final double usedRIR = bb2Rir ?? rawRIR?? 1.0;

    final progressed = _getProgressedValues(exerciseIndex);
    final double baseWeight = (progressed['weight'] ?? 20.0).toDouble();
    final double baseReps = (progressed['reps'] ?? 10).toDouble();
    final double baseE1RM = progressed['e1rm'] ?? PeriodizationModelUtils.calculateE1RM(
      baseWeight,
      baseReps,
      usedRIR,
    );
    print('🧠 [WES] Base E1RM used for ${exerciseName} = ${baseE1RM.toStringAsFixed(2)} '
        '(weight = ${baseWeight.toStringAsFixed(1)}, reps = ${baseReps.toStringAsFixed(1)}, RIR = $usedRIR)');

// Prioritization logic
    final bool hasUserReps = reps != null;
    final bool hasBB2Reps = bb2Reps != null && bb2Reps > 0;
    final double? usedWeight = weight ?? (bb2Weight != null && bb2Weight > 0 ? bb2Weight : null);

// CASE 1: Reps already entered by user → use it
    if (hasUserReps) return reps!;

// CASE 2: BB2-entered reps → use them
    if (hasBB2Reps) {
      print('🔁 [WES] Using BB2-entered reps for $exerciseName = $bb2Reps');
      return bb2Reps!;
    }

// CASE 3: Weight (from user or BB2) → derive reps
    if (usedWeight != null) {
      final derivedReps = PeriodizationModelUtils.reverseCalculateReps(
        targetE1RM: baseE1RM,
        weight: usedWeight,
        baseWeight: baseWeight,
        rir: usedRIR,
        minReps: baseReps,
      );

      final double roundedReps = derivedReps % 1 >= 0.85
          ? derivedReps.ceilToDouble()
          : derivedReps.floorToDouble();

      print('🔁 [WES] Using weight = $usedWeight & RIR = $usedRIR → derived reps = $derivedReps → rounded = $roundedReps (target E1RM = ${baseE1RM.toStringAsFixed(2)})');

      return roundedReps;
    }


    // CASE 3: No override → use model default
    return baseReps;
  }

  double set2SuggestedReps(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set2E1RM = getSet2E1RM(exerciseIndex);
    double? set1Reps =
        double.tryParse(_repsControllers[exerciseIndex][0].text) ??
            set1SuggestedReps(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet2RepsByModel(
      exerciseName: exerciseName,
      set2E1RM: set2E1RM,
      set1Reps: set1Reps,
      weightText: _weightControllers[exerciseIndex][1].text,
      rirText: _rirControllers[exerciseIndex][1].text,
    );
  }

  double set3SuggestedReps(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set3E1RM = getSet3E1RM(exerciseIndex);
    double? set2Reps =
        double.tryParse(_repsControllers[exerciseIndex][1].text) ??
            set2SuggestedReps(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet3RepsByModel(
      exerciseName: exerciseName,
      set3E1RM: set3E1RM,
      set2Reps: set2Reps,
      weightText: _weightControllers[exerciseIndex][2].text,
      rirText: _rirControllers[exerciseIndex][2].text,
    );
  }

  Map<String, dynamic>? getPlannedRirSetValuesWES({
    required String exerciseName,
    required int exerciseIndex,
    required int setNumber,
  }) {
    final exerciseId = PeriodizationModelUtils.nameToId[exerciseName];
    if (exerciseId == null) {
      print('❌ [WES ALT] No exerciseId found for "$exerciseName"');
      return null;
    }

    final rirPlan =
    PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['rirPlan'];
    if (rirPlan == null) {
      print('❌ [WES ALT] No rirPlan found for ID "$exerciseId"');
      return null;
    }

    final weekIndex = _getApplicableWeekIndex(exerciseId);
    if (weekIndex == null) {
      print('❌ [WES ALT] No weekIndex for "$exerciseName"');
      return null;
    }

    final sessionIndex =
    PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
      blockStartDate: _blockStartDate!,
      weekIndex: weekIndex,
    );

    final weekKey = 'week${weekIndex + 1}';
    final sessionKey = 'session${sessionIndex + 1}';
    final setKey = 'set$setNumber';

    print(
        '🧪 [WES ALT] $exerciseName ($exerciseId) → $weekKey > $sessionKey > $setKey');
    final sessionData = rirPlan[weekKey]?[sessionKey] as Map?;
    if (sessionData == null) {
      print('❌ [WES ALT] No session data found for $weekKey → $sessionKey');
      return null;
    }

    return sessionData.map((key, value) =>
        MapEntry(key, {
          'reps': value['reps'],
          'rir': value['rir'],
        }));
  }

  double getRirFromPlanOrInput(int exerciseIndex, int setNumber) {
    if (setNumber < 1 || setNumber > 8) return 1; // Safety fallback

    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final bb2Entry = _resolvedBB2Values[exerciseName.toLowerCase()];
    final rawBB2Rir = bb2Entry?['rir'];
    final bb2Rir = (rawBB2Rir != null && rawBB2Rir
        .toString()
        .trim()
        .isNotEmpty)
        ? double.tryParse(rawBB2Rir.toString())
        : null;

    // ✅ Set 1: Use BB2 if available
    if (setNumber == 1 && bb2Rir != null && bb2Rir != 0.0) {
      print(
          '🔁 [WES] Using BB2-entered RIR for "$exerciseName" Set 1: $bb2Rir');
      return bb2Rir;
    }

    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
    final weekIndex = _getApplicableWeekIndex(exerciseId);
    if (weekIndex == null) return setNumber == 1 ? 1 : 1.5;

    if (blockStartDate == null) {
      print(
          '❌ [WES] RIR_blockStartDate is null in getRirFromPlanOrInput for $exerciseName');
      return 1; // fallback RIR value
    }

    final sessionIndex =
    PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
      exerciseName: exerciseName,
      savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
      blockStartDate: blockStartDate!,
      weekIndex: weekIndex,
    );

    final rirPlan =
    PeriodizationModelUtils.plannedExerciseDetails[exerciseId]?['rirPlan'];
    final weekKey = 'week${weekIndex + 1}';
    final sessionKey = 'session${sessionIndex + 1}';
    final setKey = 'set$setNumber';

    final plannedRir = double.tryParse(
      rirPlan?[weekKey]?[sessionKey]?[setKey]?['rir']?.toString() ?? '',
    );

    // ✅ Sets 2–8: Use BB2 RIR if it's higher than planned
    if (setNumber > 1 && bb2Rir != null && plannedRir != null) {
      final chosen = bb2Rir > plannedRir ? bb2Rir : plannedRir;
      print(
          '🔁 [WES] Using higher of BB2 ($bb2Rir) vs planned ($plannedRir) → $chosen');
      return chosen;
    }

    final fallback = 1.0;

    final finalRir = plannedRir ?? fallback;
    print(
        '📦 [WES] Final RIR used for "$exerciseName" set $setNumber → $finalRir');
    return finalRir;
  }



  double set1RIR(int i) => getRirFromPlanOrInput(i, 1);

// ✅ Function to determine RIR for Set 2 (Default: 1.5, Modifiable in Future)
  double set2RIR(int i) => getRirFromPlanOrInput(i, 2);

  double set3RIR(int i) => getRirFromPlanOrInput(i, 3);

  double set4RIR(int i) => getRirFromPlanOrInput(i, 4);

  double set5RIR(int i) => getRirFromPlanOrInput(i, 5);

  double set6RIR(int i) => getRirFromPlanOrInput(i, 6);

  double set7RIR(int i) => getRirFromPlanOrInput(i, 7);

  double set8RIR(int i) => getRirFromPlanOrInput(i, 8);

  double set1SuggestedWeight(int exerciseIndex) {
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    final normalizedKey = exerciseName.toLowerCase();
    final bb2Entry = _resolvedBB2Values[normalizedKey];

    // ✅ Step 1: Use BB2-entered weight if available
    final double? bb2Weight = bb2Entry?['weight']?.toDouble();
    if (bb2Weight != null && bb2Weight > 0) {
      print('🔁 [WES] Using BB2-entered weight for $exerciseName: $bb2Weight');
      return bb2Weight;
    }

    // ✅ Step 2: Pull user-entered text fields
    final String weightText = _weightControllers[exerciseIndex][0].text;
    final String repsText = _repsControllers[exerciseIndex][0].text;
    final String rirText = _rirControllers[exerciseIndex][0].text;

    final double? userWeight = double.tryParse(weightText);
    final double? userReps = double.tryParse(repsText) ??
        ((bb2Entry?['reps'] is num && (bb2Entry?['reps'] as num) > 0)
            ? (bb2Entry?['reps'] as num).toDouble()
            : null);

    final double? userRir = double.tryParse(rirText) ??
        ((bb2Entry?['rir'] is num && (bb2Entry?['rir'] as num) > 0)
            ? (bb2Entry?['rir'] as num).toDouble()
            : null);


    // 🛑 Step 3: Respect user-entered weight
    if (userWeight != null) {
      print('✍️ [WES] User-entered weight for $exerciseName = $userWeight');
      return userWeight;
    }

    // ✅ Step 4: Pull model progression values
    final progressed = _getProgressedValues(exerciseIndex);
    final double baseWeight = progressed['weight']?.toDouble() ?? 20.0;
    final double baseReps = progressed['reps']?.toDouble() ?? 10.0;
    final double modelRir = getRirFromPlanOrInput(exerciseIndex, 1);

    // ✅ Step 5: Calculate base E1RM using progression model only
    final double baseE1RM =
    PeriodizationModelUtils.calculateE1RM(baseWeight, baseReps, modelRir);
    print('🧠 [WES] Base progression E1RM = ${baseE1RM.toStringAsFixed(2)} '
        '(from $baseWeight × $baseReps @ RIR $modelRir)');

    // ✅ Step 6: Use user RIR and/or reps if available
    if (userReps != null || userRir != null) {
      final double repsToUse = userReps ?? set1SuggestedReps(exerciseIndex);
      final double rirToUse = userRir ?? modelRir;

      final double derived = PeriodizationModelUtils.reverseCalculateWeight(
        targetE1RM: baseE1RM,
        reps: repsToUse.toInt(),
        rir: rirToUse,
      );

      final double rounded = PeriodizationModelUtils.roundToNearestValidIncrement(
        targetWeight: derived,
        exerciseName: exerciseName,
      );

      final double newE1RM = PeriodizationModelUtils.calculateE1RM(
        rounded,
        repsToUse,
        rirToUse,
      );

      print('🔁 [WES] Derived weight = $rounded using reps = $repsToUse and RIR = $rirToUse → new E1RM = ${newE1RM.toStringAsFixed(2)}');

      return rounded;
    }


    // ✅ Step 7: No overrides — fallback to rounded base weight
    final double fallbackRounded =
    PeriodizationModelUtils.roundToNearestValidIncrement(
      targetWeight: baseWeight,
      exerciseName: exerciseName,
    );
    print(
        '🎯 [WES] Final progression for $exerciseName using default RIR $modelRir → $fallbackRounded kg');
    return fallbackRounded;
  }

  double set2SuggestedWeight(int exerciseIndex) {
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';
    final set2E1RM = getSet2E1RM(exerciseIndex);

    final repsText = _repsControllers[exerciseIndex][1].text;
    final rirText = _rirControllers[exerciseIndex][1].text;

    final reps = double.tryParse(repsText) ?? set2SuggestedReps(exerciseIndex);
    final rir = double.tryParse(rirText) ?? set2RIR(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet2WeightByModel(
      exerciseName: exerciseName,
      set2E1RM: set2E1RM,
      reps: reps,
      rir: rir,
    );
  }

  double set3SuggestedWeight(int exerciseIndex) {
    final exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';
    final set3E1RM = getSet3E1RM(exerciseIndex);

    final repsText = _repsControllers[exerciseIndex][2].text;
    final rirText = _rirControllers[exerciseIndex][2].text;

    final reps = double.tryParse(repsText) ?? set3SuggestedReps(exerciseIndex);
    final rir = double.tryParse(rirText) ?? set3RIR(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet3WeightByModel(
      exerciseName: exerciseName,
      set3E1RM: set3E1RM,
      reps: reps,
      rir: rir,
    );
  }

  void _debugUid(String where) {
    final ctx = UserContext.of(context, listen: false);
    print('👤 [$where] actorUid=${ctx.actorUid} actingAsUid=${ctx.actingAsUid} currentUid=${ctx.currentUid}');
  }


  @override
  void initState() {
    super.initState();


    print('🚀 [WES] initState started');
    _debugUid('WES.initState');
    _cachedUid = UserContext.of(context, listen: false).currentUid;

    final contextUid = UserContext.of(context, listen: false).currentUid;
    final formattedDate = DateFormat('yyyy-MM-dd').format(DateTime.now());

    final legacyDraftKey = 'workout_draft_$formattedDate';
    final namespacedDraftKey = 'workout_draft_${contextUid}_$formattedDate';

    print('🧪 [WES DraftKey] contextUid = $contextUid');
    print('🧪 [WES DraftKey] legacy format = $legacyDraftKey');
    print('🧪 [WES DraftKey] new namespaced = $namespacedDraftKey');


    _blockDateLoad = _loadBlockDatesOnly(userId); // ✅ actingAsUid

    _repo = BlockPlannerRepository();
    WidgetsBinding.instance.addObserver(this);


    _selectedDate = widget.initialDate ?? DateTime.now();
    print('📅 [WES] Selected date: $_selectedDate');


    _initialLoad = _fetchActiveBlockThenMeta().then((_) {
      // ✅ Return an async function and immediately invoke it
      return (() async {
        try {
          await _blockDateLoad;

          print('⏳ [WES] fetchActiveBlockThenMeta() completed');

          if (_activeBlockId == null || _blockStartDate == null || _blockEndDate == null) {
            print('❌ [WES Init] Missing required block meta. Exiting...');
            return;
          }

          await _loadAllBlocks();
          print('📦 [WES] _loadAllBlocks complete, total blocks: ${_allBlocks.length}');

          _selectedBlockId = _allBlocks.firstWhere(
                (b) => b.id == _activeBlockId,
            orElse: () => _allBlocks.first,
          ).id;

          print("🧱 [WES] Selected blockId: $_selectedBlockId");

          await _loadInitialData();
          print("📥 [WES] Draft data loaded");

          await _fetchLastWorkoutTopSetReps();
          print("📈 [WES] Top set reps fetched");

          _debugPrintBlockDates();

          await _initializeDayDocIfNeeded(_selectedDate);
          print("📄 [WES] Day doc initialized if needed");

          if (widget.initialDate != null) {
            _selectedDate = widget.initialDate!;
            _workoutNameController.text = _formatWorkoutDate(_selectedDate);
          }

          _cachedProgressedValues.clear();
          _selectedExercisesWithCircuits.clear();
          _workoutSets.clear();
          _repsControllers.clear();
          _weightControllers.clear();
          _rirControllers.clear();
          _velocityControllers.clear();
          _notesControllers.clear();
          _resolvedBB2Values.clear();

          await _loadDraftLocallyIfAvailable();
          _populateVelocityFlags();
          print("🔀 [WES] Merged BB2 into draft");

          _cachedProgressedValues.clear();

          final hasUserData = _weightControllers.any((controllerList) =>
              controllerList.any((c) => c.text.trim().isNotEmpty));

          if (!hasUserData) {
            print('🔁 [WES Init] No user-entered data in WES → re-merging BB2 values');
            _lastMergedUid = null;
            await _mergeNewBB2ExercisesIntoDraft();
          } else {
            print('✅ [WES Init] Skipping BB2 re-merge — WES already has user-entered data');
          }


          Future.delayed(const Duration(milliseconds: 10), () {
            if (_selectedExercisesWithCircuits.isNotEmpty) {
              final testExercise = _selectedExercisesWithCircuits.first['name']?.trim() ?? '';
              final rep = getRepTargetForExerciseWES(testExercise, 0);
              print('🧪 [WES Init] Test rep target for "$testExercise" = $rep');
            } else {
              print('⚠️ [WES Init] No exercises in _selectedExercisesWithCircuits');
            }
          });

        } catch (e, stack) {
          print('💥 [WES Init] Exception caught: $e');
          print(stack);
        }
      })(); // ✅ ← This invokes and returns the async block
    });


    Future.microtask(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('wasSavedFromWES') == true) {
        prefs.remove('wasSavedFromWES');
        setState(() {
          print("🟣 Triggered UI update due to save from WES");
        });
      }
    });

    _horizontalScrollController = ScrollController();

    print('🧠 [WES] initState complete — awaiting _initialLoad...');
  }


  Future<void> _fetchActiveBlockThenMeta() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _activeBlockId = await BlockRepository().fetchActiveBlockId(userId);
    print('🎯 [WES] Active Block ID from Firestore = $_activeBlockId');

    if (_activeBlockId == null) {
      print('❌ [WES] No active block found');
      return;
    }

    // ⏳ Retry loop to wait for start/end dates if not yet available
    const maxAttempts = 5;
    const delayBetweenAttempts = Duration(milliseconds: 300);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final meta = await _repo.loadBlockMeta(
        userId: userId, // ✅ actingAsUid
        blockId: _activeBlockId!,
      );


      final start = meta.startDate;
      final end = meta.endDate;
      final days = meta.selectedDays;

      if (start != null && end != null) {
        blockStartDate = start;
        blockEndDate = end;
        _selectedDays = days;
        print('📦 [WES] BlockMeta (attempt $attempt) → start: $blockStartDate | end: $blockEndDate | days: $_selectedDays');
        return;
      } else {
        print('⏳ [WES] BlockMeta not ready (attempt $attempt) — retrying...');
        await Future.delayed(delayBetweenAttempts);
      }
    }

    // ❌ Still null after all attempts
    print('❌ [WES] Failed to fetch valid blockMeta after $maxAttempts attempts');
  }

  void _populateVelocityFlags() {
    for (final exercise in _selectedExercisesWithCircuits) {
      final name = (exercise['name'] as String?)?.toLowerCase() ?? '';
      final isTracked = PeriodizationModelUtils.isVelocityTracked(name); // ✅ declare it here
      _showVelocityByExercise[name] = isTracked;

      print('📈 Velocity Check → $name → $isTracked'); // ✅ now it exists
    }
  }



  Future<void> _loadBlockDatesOnly(String userId) async {
    final blockId = await BlockRepository().fetchActiveBlockId(userId);

    if (blockId == null) {
      throw StateError("No active block found");
    }

    final meta = await _repo.loadBlockMeta(
      userId: userId, // ✅ now passed in
      blockId: blockId,
    );

    _blockStartDate = meta.startDate;
    _blockEndDate = meta.endDate;

    print('✅ [WES] Loaded block dates: $_blockStartDate → $_blockEndDate');
  }


  Future<void> _loadAllBlocks() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    print('👤 [WES] _loadAllBlocks using userId=$userId and currentUser.uid=${FirebaseAuth.instance.currentUser?.uid}');

    final snap = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .get();

    print('🔍 [WES] Loaded ${snap.docs.length} blocks: ${snap.docs.map((d) => d.id)}');

    final blocks = snap.docs.map((d) {
      final data = d.data();

      final Timestamp? startTs = data.containsKey('startDate') ? data['startDate'] as Timestamp? : null;
      final Timestamp? endTs = data.containsKey('endDate') ? data['endDate'] as Timestamp? : null;

      return BlockMeta(
        id: d.id,
        name: data['name'], // nullable is fine now
        startDate: startTs?.toDate(),
        endDate: endTs?.toDate(),
        selectedDays: List<String>.from(data['selectedDays'] ?? []),
      );
    }).toList();



    setState(() {
      _allBlocks = blocks;
    });
  }

  Future<void> _initializeDayDocIfNeeded(DateTime date) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _selectedBlockId == null || blockStartDate == null) return;

    final blockId = _selectedBlockId!;
    final daysSinceStart = date.difference(blockStartDate!).inDays;
    if (daysSinceStart < 0) return;

    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex = daysSinceStart % 7;

    final dayDocRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId)
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex');

    final doc = await dayDocRef.get();
    if (!doc.exists) {
      // Look for fallback data
      final dateKey = DateFormat('yyyy-MM-dd').format(date);
      final blockDataDoc = await FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(userId)
          .collection('blocks')
          .doc(blockId)
          .collection('block_data')
          .doc(dateKey)
          .get();

      if (blockDataDoc.exists && blockDataDoc.data()?['rows'] != null) {
        print('[WES Init] Populating missing week/day doc from fallback block_data...');
        await dayDocRef.set({
          'exercises': blockDataDoc.data()!['rows'],
        });
      } else {
        print('[WES Init] No fallback block_data to populate day doc');
      }
    } else {
      print('[WES Init] Day doc already exists → no action needed');
    }
  }


  Future<void> _loadExercisesFromBB2ForDay() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _selectedBlockId == null || _selectedDate == null) return;
    if (user == null) {
      return;
    }
    if (_selectedBlockId == null) {
      return;
    }
    if (_selectedDate == null) {
      return;
    }

    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    print('📅 [WES] Loading BB2 exercises for $dateKey (block: $_selectedBlockId)');
    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(_selectedBlockId)
        .collection('block_data')
        .doc(dateKey)
        .get();

    if (!doc.exists) {
      print('🟡 [WES] No BB2 plan found for $dateKey in block $_selectedBlockId');
      return;
    }

    final data = doc.data();
    final List<dynamic> rows = data?['rows'] ?? [];

    // Optional: clear old list first
    _selectedExercisesWithCircuits.clear();

    for (final row in rows) {
      final name = row['name'] ?? '';
      final circuit = row['circuitIndex'] ?? 0;

      if (name.trim().isEmpty) continue;

      _selectedExercisesWithCircuits.add({
        'name': name.trim(),
        'circuitIndex': circuit,
      });
    }

    print('✅ [WES] Loaded ${_selectedExercisesWithCircuits.length} exercises from BB2 for $dateKey');

    setState(() {}); // 🧠 Trigger UI update
  }

  Future<void> _loadInitialData() async {
    print('🚀 [WES Init] Starting _loadInitialData');

    if (widget.prefilledExercisesWithCircuits?.isNotEmpty ?? false) {
      print('🧠 [WES Init] Using widget.prefilledExercisesWithCircuits');

      setState(() {
        _selectedExercisesWithCircuits.clear();
        _workoutSets.clear();
        _repsControllers.clear();
        _weightControllers.clear();
        _rirControllers.clear();
        _resolvedBB2Values.clear();
        _blockStartDate = widget.initialDate;
        _blockEndDate = widget.initialDate;

        _selectedExercisesWithCircuits.addAll(
          widget.prefilledExercisesWithCircuits!
              .map((e) => Map<String, dynamic>.from(e)),
        );

        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
          _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _velocityControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _notesControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        }

        print('✅ [WES Init] Pre-filled exercises: ${_selectedExercisesWithCircuits.map((e) => e['name'])}');
        print('✅ [WES Init] Skipping normal BB2 flow, returning early');

        _isLoadingData = false;
      });
      print('🚫 [WES Init] BB2 hint loading skipped due to prefilledExercisesWithCircuits');

      return;
    }

    // 🔁 Normal flow
    print('🔁 [WES Init] Running full BB2 plan load');
    await loadExercisesFromFirestoreForWES();
    await _buildNameToIdMapsFromFirestore();
    await _loadPlannedExerciseDetails();
    await PeriodizationModelUtils.fetchFullTopSetHistory(
      uid: UserContext.of(context, listen: false).currentUid,
    );
    await loadSavedWorkoutsForInstanceCount();

    await loadPlannedExercisesFromFirestore();
    await loadPreviousWorkoutData();

    // 💾 Draft Load
    print('💾 [WES Init] Attempting to load draft from cache...');
    final draftLoaded = await _loadWorkoutDraftFromCache();
    print('📦 [WES Init] Draft loaded: $draftLoaded');

    if (draftLoaded) {
      await Future.delayed(const Duration(milliseconds: 10));
      print('🔁 [WES Init] Merging BB2 exercises post-draft...');
      await _mergeNewBB2ExercisesIntoDraft();
    } else {
      print('📭 [WES Init] No draft found → merging BB2 from scratch');
      _selectedExercisesWithCircuits.clear(); // ensure fully fresh
      print('[WES Init] Exercises before BB2 merge: ${_selectedExercisesWithCircuits.length}');

      await _mergeNewBB2ExercisesIntoDraft();
      print('[WES Init] Exercises after BB2 merge: ${_selectedExercisesWithCircuits.length}');

    }

    print('🧠 [WES Init] Running final merge to reinforce BB2 values...');
    await _mergeNewBB2ExercisesIntoDraft();

    print('🧪 [WES Init] Resolved BB2 values:');
    _resolvedBB2Values.forEach((name, values) {
      print('    → $name → $values');
    });

    setState(() {
      _isLoadingData = false;
      _isInitialized = true;
      print('🟢 [WES Init] Final setState to force UI rebuild after BB2 exercise injection');
    });

    print('✅ [WES Init] _loadInitialData complete');

  }



  double _calculateFallbackSet1Reps(int exerciseIndex) {
    String exerciseName =
        _selectedExercisesWithCircuits[exerciseIndex]['name']?.trim() ?? '';
    int plannedCountBefore = 0;

    for (int i = 0; i < exerciseIndex; i++) {
      if (_selectedExercisesWithCircuits[i]['name'] == exerciseName) {
        plannedCountBefore++;
      }
    }

    final exerciseId =
        PeriodizationModelUtils.nameToId[exerciseName] ?? exerciseName;
    final weekIndex = _getApplicableWeekIndex(exerciseId);
    final model =
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];

    // dailyUndulatingExposure
    if (model == PeriodizationModelType.dailyUndulatingExposure) {
      final count = PeriodizationModelUtils.getInstanceCountForExerciseInBlock(
        exerciseName: exerciseName,
        savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
        blockStartDate: _blockStartDate!,
        blockEndDate: _blockEndDate!,
      );

      final week1 = PeriodizationModelUtils.plannedExerciseDetails[exerciseId]
          ?['repTargets']?['week1'];

      print("🔍 [DUP Exposure] Looking up reps for $exerciseName (ID: $exerciseId)");
      print("📦 week1 = $week1");

      if (week1 is Map<String, dynamic>) {
        final sorted = week1.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));


        print("📚 Found ${sorted.length} instances: ${sorted.map((e) => '${e.key}: ${e.value}').join(', ')}");
        print("🔢 Instance count for this exercise in block: $count");

        final frequency = sorted.length;
        if (frequency == 0) {
          print("⚠️ No rep targets found — falling back to 10.");
          return 10;
        }


        final index = count % frequency;
        final raw = sorted[index].value?.toString() ?? '';
        final match = RegExp(r'^(\d+)').firstMatch(raw);
        final parsed = match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;
        print("🎯 Selected raw rep string: '$raw' → Parsed: $parsed");
        return parsed.toDouble();
      } else {
        print("⚠️ week1 is not a Map<String, dynamic> → got: ${week1.runtimeType}");
      }
    }

    // dailyUndulatingWeek
    if (model == PeriodizationModelType.dailyUndulatingWeek) {
      final count = PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
        exerciseName: exerciseName,
        savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
        blockStartDate: _blockStartDate!,
        weekIndex: weekIndex ?? 0,
      );

      final repTargets = _exerciseSettings[exerciseId]?['repTargets'];

      final weekKey = 'week${(weekIndex ?? 0) + 1}';
      final weekMap = repTargets?[weekKey];

      if (weekMap is Map<String, dynamic>) {
        final sorted = weekMap.entries
            .where((e) => e.key.startsWith('instance'))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));

        final frequency = sorted.length;
        if (frequency == 0) return 10;

        final index = count % frequency;
        final raw = sorted[index].value?.toString() ?? '';
        final match = RegExp(r'^(\d+)').firstMatch(raw);
        final parsed = match != null ? int.tryParse(match.group(1)!) ?? 10 : 10;

        return parsed.toDouble();
      }
    }

    // linearClassic
    if (model == PeriodizationModelType.linearClassic) {
      final repTargets = _exerciseSettings[exerciseId]?['repTargets'];

      final weekStart = repTargets?['week1'];

      if (weekStart is Map<String, dynamic>) {
        final instanceCount =
            PeriodizationModelUtils.getInstanceCountForExerciseInWeek(
          exerciseName: exerciseName,
          savedWorkouts: PeriodizationModelUtils.savedWorkoutsList,
          blockStartDate: _blockStartDate!,
          weekIndex: weekIndex ?? 0,
        );

        final sortedKeys = weekStart.keys
            .where((k) => k.startsWith('instance'))
            .toList()
          ..sort();

        final frequency = sortedKeys.length;
        if (frequency == 0) return 10;

        final index = instanceCount % frequency;
        final instanceKey = sortedKeys[index];

        final startRaw = weekStart[instanceKey]?.toString() ?? '10 x 3';
        final startMatch = RegExp(r'^(\d+)').firstMatch(startRaw);
        final setMatch = RegExp(r'x\s*(\d+)').firstMatch(startRaw);

        final startReps =
            startMatch != null ? int.tryParse(startMatch.group(1)!) ?? 10 : 10;
        final sets = setMatch != null ? setMatch.group(1)! : '3';
        final endReps = 1;

        final blockLength = PeriodizationModelUtils.getBlockLength(
          blockStartDate: _blockStartDate!,
          blockEndDate: _blockEndDate!,
        );

        final week = weekIndex ?? 0;
        final reps =
            (startReps + ((endReps - startReps) * (week / (blockLength - 1))))
                .round();

        return reps.toDouble();
      }
    }

    // Default fallback
    return 10.0;
  }


  Future<void> loadExercisesFromFirestoreForWES() async {
    final snapshot =
        await FirebaseFirestore.instance.collection('exercises').get();

    for (final doc in snapshot.docs) {
      final id = doc.id;
      final name = doc['name']?.toString()?.trim();
      if (name != null && name.isNotEmpty) {
        PeriodizationModelUtils.nameToId[name] = id;
        PeriodizationModelUtils.idToName[id] = name;
        print('✅ [WES] Mapped "$name" → $id');
      }
    }
  }

  Future<Map<String, dynamic>> _loadPlannedExerciseDetails() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _selectedBlockId == null) return {};
    print('🔍 [WES] _loadPlannedExerciseDetails() using blockId: $_selectedBlockId');


    // ✅ 1. Load from BB2-style Firestore path using _selectedBlockId
    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(_selectedBlockId!)
        .get();
    print('🧾 [RAW] Full Firestore doc snapshot data: ${doc.data()}');


    if (!doc.exists) {
      print('❌ [WES] No plannedExerciseDetails found in block $_selectedBlockId');
      return {};
    }


    // ✅ 2. Extract data and handle blockMeta separately
    final data = doc.data()!;
    final blockMeta = data['blockMeta'] as Map<String, dynamic>? ?? {};

    final details = Map<String, dynamic>.from(data['plannedExerciseDetails'] ?? {});
    print('📦 [WES] Firestore plannedExerciseDetails keys: ${details.keys}');
    print('🧪 [WES] Raw plannedExerciseDetails contents:');
    details.forEach((exerciseId, entry) {
      print('  🔍 $exerciseId → $entry');
    });
    _exerciseSettings = Map<String, Map<String, dynamic>>.from(
      (data['exerciseSettings'] ?? {}).map(
            (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v)),
      ),
    );
    print('📦 [WES] Firestore exerciseSettings keys: ${_exerciseSettings.keys}');


    // ✅ 3. Do NOT setState() with plannedExercises — skipped by request

    // ✅ 4. Set blockStartDate and blockEndDate from meta directly
    _blockStartDate = DateTime.tryParse(blockMeta['blockStartDate'] ?? '');
    _blockEndDate = DateTime.tryParse(blockMeta['blockEndDate'] ?? '');
    print('📅 [WES] Loaded blockStartDate=$_blockStartDate, blockEndDate=$_blockEndDate');

    // ✅ 5. Reset PMU maps BEFORE setting anything
    PeriodizationModelUtils.plannedExerciseDetails.clear();
    PeriodizationModelUtils.exercisePeriodizationModels.clear();

    // Inject into PMU
    PeriodizationModelUtils.setExerciseSettings(details);
    print('✅ [WES] Injected exerciseSettings into PMU with keys: ${details.keys}');

    // Walk each exercise entry
    details.forEach((exerciseId, entry) {
      if (entry is! Map<String, dynamic>) return;

      // Store the raw settings
      PeriodizationModelUtils.plannedExerciseDetails[exerciseId] = entry;

      // Map periodizationModel → enum
      final String? modelName = entry['periodizationModel'] as String?;
      final modelEnum = modelName != null
          ? PeriodizationModelUtils.stringToModel(modelName)
          : null;
      print("🧠 [WES] modelName = $modelName → modelEnum = $modelEnum");

      if (modelEnum != null) {
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId] = modelEnum;
        print('✅ [WES] Mapped model $modelName → $modelEnum for $exerciseId');
      }

      // Track progressionModel if you need it later
      final progressionModel = entry['progressionModel'] ?? 'none';
      _progressionModelsByExercise[exerciseId] = progressionModel;
      print('🏗️ [WES] Progression model for $exerciseId: $progressionModel');
    });


    print('📄 [WES] Full plannedExerciseDetails loaded: ${details.keys}');
    return details;
  }


  Future<void> _buildNameToIdMapsFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('planned_blocks') // ← your real root
        .doc(userId)
        .collection('blocks')
        .doc(widget.blockId)
        .get();

    final data = doc.data();
    if (data == null || !data.containsKey('plannedExerciseDetails')) {
      print('❌ [WES] No plannedExerciseDetails found in Firestore');
      return;
    }

    final rawDetails =
        Map<String, dynamic>.from(data['plannedExerciseDetails']);
    print(
        '📦 [WES] [Firestore Function] Full raw Firestore data: ${jsonEncode(data)}');
    print(
        '📦 [WES] Extracted plannedExerciseDetails: ${jsonEncode(rawDetails)}');



    // ✅ Inject into PMU
    PeriodizationModelUtils.setExerciseSettings(rawDetails);
    print(
        '✅ [WES] Injected exerciseSettings into PMU with keys: ${rawDetails.keys}');

    // ✅ Build name ↔ ID maps
    final nameToIdMap = <String, String>{};
    final idToNameMap = <String, String>{};

    rawDetails.forEach((id, entry) {
      if (entry is Map<String, dynamic>) {
        // ✅ Try to get name directly from Firestore entry
        String? name = entry['name'];

        // ✅ Fallback: try to get it from injected _selectedExercisesWithCircuits
        if ((name == null || name.trim().isEmpty) &&
            PeriodizationModelUtils.idToName.containsKey(id)) {
          name = PeriodizationModelUtils.idToName[id];
          print('🔁 [WES] Using fallback name from idToName for $id → $name');
        }

        if (name != null && name.trim().isNotEmpty) {
          nameToIdMap[name.trim()] = id;
          idToNameMap[id] = name.trim();
          print('✅ [WES] Mapped name "$name" ↔ id $id');
        } else {
          print('❌ [WES] Still missing name for exerciseId: $id');
        }
      }
    });

    PeriodizationModelUtils.nameToId = nameToIdMap;
    PeriodizationModelUtils.idToName.clear();
    PeriodizationModelUtils.idToName.addAll(idToNameMap);

    print('✅ [WES] nameToIdMap injected with ${nameToIdMap.length} entries');
    print('✅ [WES] idToNameMap injected with ${idToNameMap.length} entries');
  }

  void _injectIdToNameFromSelectedExercises() {
    for (final ex in _selectedExercisesWithCircuits) {
      final id = ex['id'];
      final name = ex['name'];
      if (id != null && name != null) {
        PeriodizationModelUtils.idToName[id] = name;
        print("🧩 [WES inject] id=$id → name=$name"); // ✅ Debug print
      }
    }
  }

  Future<void> loadSavedWorkoutsForInstanceCount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('workouts')
        .get();

    final workouts = snapshot.docs.map((doc) => doc.data()).toList();
    PeriodizationModelUtils.savedWorkoutsList =
        List<Map<String, dynamic>>.from(workouts);

    print(
        '📦 [WES] Loaded ${workouts.length} saved workouts into savedWorkoutsList');
  }

  int? _getApplicableWeekIndex(String exerciseId) {
    final model =
        PeriodizationModelUtils.exercisePeriodizationModels[exerciseId];

    if (model == PeriodizationModelType.linearClassic ||
        model == PeriodizationModelType.dailyUndulatingWeek ||
        model == PeriodizationModelType.dupSignature ||
        model == PeriodizationModelType.dailyUndulatingExposure) {
      if (_blockStartDate == null) return 0;

      final daysSinceStart = _selectedDate.difference(_blockStartDate!).inDays;
      final weekIndex = (daysSinceStart / 7).floor().clamp(0, 11);

      print('📆 [WES] Calculated weekIndex=$weekIndex for $exerciseId');
      return weekIndex;
    }

    return null; // exposure-based models
  }

  void _setInitialWorkoutName() {
    if (widget.initialTemplate != null &&
        widget.initialTemplate!.name.isNotEmpty) {
      _workoutNameController.text = widget.initialTemplate!.name;
    } else if (widget.initialWorkoutName != null) {
      _workoutNameController.text = widget.initialWorkoutName!;
    } else {
      _workoutNameController.text =
          DateFormat('EEE d MMM yyyy').format(_selectedDate);
    }
  }
//101here
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    print('📱 [WES] AppLifecycleState changed: $state');
    print('📱 [WES] mounted = $mounted');

    if (state == AppLifecycleState.resumed) {
      final prefs = await SharedPreferences.getInstance();
      final dateKey =
          '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
      final timestampStr = prefs.getString('draft_last_saved_$dateKey');

      print('🔍 [WES] Checking last draft timestamp for key: $dateKey → $timestampStr');

      if (timestampStr != null) {
        final savedAt = DateTime.tryParse(timestampStr);
        final now = DateTime.now();
        print('🕒 [WES] Draft last saved at: $savedAt — now: $now');

        if (savedAt != null && now.difference(savedAt).inHours < 2) {
          print('[WES] App resumed — refreshing draft with BB2 merge');
          await _mergeNewBB2ExercisesIntoDraft();
          setState(() {}); // Refresh UI if merged
        }
      }
    }

    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      print('📦 [WES] App paused/inactive — attempting to save draft...');
      _persistDraftLocally();
    }
  }


  void _loadWorkout(Workout workout) {
    _workoutNameController.text = workout.name;
    _selectedDate = workout.date;

    _selectedExercisesWithCircuits.clear();
    _workoutSets.clear();

    for (var exercise in workout.exercises) {
      _selectedExercisesWithCircuits.add({
        'name': exercise.name,
        'circuitIndex':
            exercise.circuitIndex ?? 0, // ✅ fallback to 0 if missing
      });

      _workoutSets.add(
        exercise.sets
            .map((set) => SetDetails(
                  reps: set.reps,
                  weight: set.weight,
                  rir: set.rir,
                ))
            .toList(),
      );
    }

   // _initializeControllers();
  }

  void _loadTemplate(Template template) {
    setState(() {
      _workoutNameController.text = template.name;
      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();

      // ✅ Convert each exercise into a Map with name + circuitIndex
      for (var e in template.exercises) {
        _selectedExercisesWithCircuits.add({
          'name': (e is String) ? e : (e['name'] ?? 'Unnamed'),
          'circuitIndex': (e is Map && e.containsKey('circuitIndex'))
              ? e['circuitIndex']
              : 0,
        });
      }

      // ✅ Initialize sets and controllers
      _workoutSets.addAll(List.generate(
        _selectedExercisesWithCircuits.length,
        (_) => List.generate(
          _defaultSets,
          (_) => SetDetails(reps: null, weight: null, rir: null),
        ),
      ));

     _initializeControllers();
    });
  }

  void _showTemplateSelectionDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('templates')
        .get();

    final templates = snapshot.docs
        .map((doc) => Template.fromFirestore(doc.data(), doc.id))
        .toList();

    final selectedTemplate = await showDialog<Template>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade800,
          title: const Text('Select Template',
              style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: templates.isEmpty
                ? const Center(
                    child: Text(
                      'No templates available.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: templates.length,
                    itemBuilder: (context, index) {
                      final template = templates[index];
                      return ListTile(
                        title: Text(template.name,
                            style: const TextStyle(color: Colors.white)),
                        dense: true, // ✅ THIS is what reduces vertical space
                        onTap: () => Navigator.pop(context, template),
                      );
                    },
                  ),
          ),
        );
      },
    );

    if (selectedTemplate != null) {
      _loadTemplate(selectedTemplate);
    }
  }

  void _addNewCircuitExercise() {
    setState(() {
      int nextCircuitIndex = 0;

      if (_selectedExercisesWithCircuits.isNotEmpty) {
        final lastCircuitIndex =
            _selectedExercisesWithCircuits.last['circuitIndex'] ?? 0;
        nextCircuitIndex = lastCircuitIndex + 1;
      }

      _selectedExercisesWithCircuits.add({
        'name': '',
        'circuitIndex': nextCircuitIndex,
      });

      _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
      _repsControllers
          .add(List.generate(_defaultSets, (_) => TextEditingController()));
      _weightControllers
          .add(List.generate(_defaultSets, (_) => TextEditingController()));
      _rirControllers
          .add(List.generate(_defaultSets, (_) => TextEditingController()));
    });
  }

  @override
  void dispose() {
    //101here
    print('🧹 [WES] dispose — saving draft for $_cachedUid');
    _persistDraftLocally();

    _workoutNameController.dispose();
    for (var controllers in _repsControllers) {
      for (var controller in controllers) {
        controller.dispose();
      }
    }
    for (var controllers in _weightControllers) {
      for (var controller in controllers) {
        controller.dispose();
      }
    }
    for (var controllers in _rirControllers) {
      for (var controller in controllers) {
        controller.dispose();
      }
    }
    WidgetsBinding.instance.removeObserver(this);

    _horizontalScrollController.dispose();
    super.dispose();
  }

  void _initializeControllers() {
    // ✅ Ensure controller lists are at least as long as the exercise list
    while (_repsControllers.length < _selectedExercisesWithCircuits.length) {
      _repsControllers.add([]);
    }
    while (_weightControllers.length < _selectedExercisesWithCircuits.length) {
      _weightControllers.add([]);
    }
    while (_rirControllers.length < _selectedExercisesWithCircuits.length) {
      _rirControllers.add([]);
    }
    while (_velocityControllers.length < _selectedExercisesWithCircuits.length) {
      _velocityControllers.add([]);
    }
    while (_notesControllers.length < _selectedExercisesWithCircuits.length) {
      _notesControllers.add([]);
    }

    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      List<SetDetails> sets = _workoutSets[i];

      // ✅ Only add controllers if they don't already exist
      if (_repsControllers[i].isEmpty) {
        _repsControllers[i] = sets.map((set) {
          return TextEditingController(text: set.reps?.toString() ?? '');
        }).toList();
      }

      if (_weightControllers[i].isEmpty) {
        _weightControllers[i] = sets.map((set) {
          return TextEditingController(
              text: set.weight != null ? set.weight!.toStringAsFixed(1) : '');
        }).toList();
      }

      if (_rirControllers[i].isEmpty) {
        _rirControllers[i] = sets.map((set) {
          return TextEditingController(
              text: set.rir != null ? set.rir!.toStringAsFixed(1) : '');
        }).toList();
      }

      if (_velocityControllers[i].isEmpty) {
        _velocityControllers[i] = sets.map((set) {
          return TextEditingController(
              text: set.velocity != null ? set.velocity!.toStringAsFixed(2) : '');
        }).toList();
      }

      if (_notesControllers[i].isEmpty) {
        _notesControllers[i] = sets.map((set) {
          return TextEditingController(text: set.notes ?? '');
        }).toList();
      }
    }
  }

  //Values persisting block: start

  String get _draftKey {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    return 'wes_draft_$dateKey';
  }

  //101here
  Future<void> _persistDraftLocally() async {
    if (!mounted) {
      print('🚫 [WES] Skipped draft save — widget is unmounted.');
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();

      // Sync current TextField values into _workoutSets
      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        for (int j = 0; j < _workoutSets[i].length; j++) {
          _workoutSets[i][j].reps = int.tryParse(_repsControllers[i][j].text.trim());
          _workoutSets[i][j].weight = double.tryParse(_weightControllers[i][j].text.trim());
          _workoutSets[i][j].rir = double.tryParse(_rirControllers[i][j].text.trim());
          _workoutSets[i][j].velocity = double.tryParse(_velocityControllers[i][j].text.trim());
          _workoutSets[i][j].notes = _notesControllers[i][j].text.trim();
        }
      }

      final draft = {
        'workoutName': _workoutNameController.text,
        'exercises': List.generate(_selectedExercisesWithCircuits.length, (i) => {
          'name': _selectedExercisesWithCircuits[i]['name'],
          'circuitIndex': _selectedExercisesWithCircuits[i]['circuitIndex'],
          'sets': _workoutSets[i].map((set) => set.toMap()).toList(),
        }),
      };

      final key = _getDraftKey(); // 👈 use your helper
      await prefs.setString(key, jsonEncode(draft));
      print('💾 [WES] Draft saved for ${_selectedDate.toIso8601String()} under key: $key');

      // print('💾 Draft saved: $_draftKey');
    } catch (e) {
      print('❌ Failed to persist WES draft: $e');
    }
  }

  String _getDraftKey() {
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    return 'workout_draft_${_cachedUid}_$dateKey';
  }



  //101here
  Future<void> _loadDraftLocallyIfAvailable() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _getDraftKey(); // 👈 use your helper
      final jsonStr = prefs.getString(key);
      print('📥 [WES] Loading draft using key: $key');

      if (jsonStr == null) return;

      final decoded = jsonDecode(jsonStr);
      final List exercises = decoded['exercises'] ?? [];

      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();
      _velocityControllers.clear();
      _notesControllers.clear();

      _workoutNameController.text = decoded['workoutName'] ?? _formatWorkoutDate(_selectedDate);

      for (final e in exercises) {
        _selectedExercisesWithCircuits.add({
          'name': e['name'],
          'circuitIndex': e['circuitIndex'] ?? 0,
        });

        final List<Map<String, dynamic>> setMaps = List<Map<String, dynamic>>.from(e['sets'] ?? []);
        final sets = setMaps.map((s) => SetDetails(
          reps: (s['reps'] is int) ? s['reps'] : int.tryParse(s['reps']?.toString() ?? ''),
          weight: (s['weight'] is num) ? (s['weight'] as num).toDouble() : null,
          rir: (s['rir'] is num) ? (s['rir'] as num).toDouble() : null,
          velocity: (s['velocity'] is num) ? (s['velocity'] as num).toDouble() : null,
          notes: s['notes']?.toString(),
        )).toList();

        _workoutSets.add(sets);
      }

      _initializeControllers();
    } catch (e) {
      print('❌ Failed to load WES draft: $e');
    }
  }


  //101here
  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getDraftKey(); // 👈 use helper
    await prefs.remove(key);
    print('🧹 [WES] Cleared draft for key: $key');
  }



  void _showExercisePickerDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (plannedExercises.isEmpty) {
      await loadPlannedExercisesFromFirestore();
    }

// 🧠 Double guard: If it's still empty after loading, just skip the planned-only filter.
    bool plannedModeAvailable = plannedExercises.isNotEmpty;

    final snapshot =
        await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs
        .map((doc) => {
              'id': doc.id,
              'name': doc['name'] as String,
              'category': doc['category'] as String,
            })
        .toList();

    // 🔥 Build Name ➔ ID map
    final Map<String, String> nameToIdMap = {
      for (final ex in allExercises) ex['name']!: ex['id']!,
    };

    bool showPlannedOnly = true;
    final Map<String, bool> expandedGroups = {};

    final List<String> selected = await showDialog<List<String>>(
          context: context,
          builder: (ctx) {
            List<String> tempSelected = _selectedExercisesWithCircuits
                .map((e) => e['name'] as String)
                .toList();
            String searchQuery = "";

            return StatefulBuilder(builder: (context, setLocalState) {
              List<Map<String, String>> filteredExercises =
                  (showPlannedOnly && plannedModeAvailable)
                      ? allExercises
                          .where((ex) => plannedExercises.contains(ex['id']))
                          .toList()
                      : allExercises;

// 🔍 Apply case-insensitive name filter
              if (searchQuery.trim().isNotEmpty) {
                final query = searchQuery.toLowerCase();
                filteredExercises = filteredExercises.where((ex) {
                  final name = ex['name']?.toLowerCase() ?? "";
                  return name.contains(query);
                }).toList();
              }

              print('Planned Exercise IDs: $plannedExercises');
              print(
                  'Loaded Exercises (id, name): ${allExercises.map((e) => '${e['id']} (${e['name']})').toList()}');
              print(
                  'Filtered Exercises (${showPlannedOnly ? "Planned Only" : "All"}): ${filteredExercises.map((e) => e['name']).toList()}');

              final Map<String, List<String>> grouped = {};

              for (final exercise in filteredExercises) {
                final category = exercise['category'] ?? 'Other';
                final name = exercise['name'] ?? 'Unnamed';
                grouped.putIfAbsent(category, () => []).add(name);
              }

              for (final group in grouped.values) {
                group
                    .sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
              }

              const categoryOrder = [
                'Horizontal Press',
                'Horizontal Pull',
                'Vertical Press',
                'Vertical Pull',
                'Lateral Raise',
                'Arm Extension',
                'Arm Curl',
                'Squat Pattern',
                'Hip Hinge',
                'Leg Extension',
                'Leg Curl',
                'Hip Abduction/adduction',
                'Calf Raise',
                'Core',
              ];

              final Map<String, List<String>> orderedGrouped = {};
              for (final cat in categoryOrder) {
                if (grouped.containsKey(cat)) {
                  orderedGrouped[cat] = grouped[cat]!;
                }
              }
              for (final entry in grouped.entries) {
                if (!orderedGrouped.containsKey(entry.key)) {
                  orderedGrouped[entry.key] = entry.value;
                }
              }

              for (final category in orderedGrouped.keys) {
                expandedGroups.putIfAbsent(category, () => false);
              }

              return AlertDialog(
                backgroundColor: Colors.blueGrey.shade900,
                insetPadding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 2), // 🔧 reduce horizontal margin
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12), // 🔧 reduce internal padding
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Select Exercises",
                        style: TextStyle(fontSize: 13, color: Colors.white)),
                    if (plannedModeAvailable)
                      Row(
                        children: [
                          Text(
                            showPlannedOnly ? "Planned Only" : "All Exercises",
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white70),
                          ),
                          Switch(
                            value: showPlannedOnly,
                            onChanged: (value) =>
                                setLocalState(() => showPlannedOnly = value),
                            activeColor: Colors.lightBlueAccent,
                          ),
                        ],
                      )
                    else
                      const SizedBox(),
                  ],
                ),
                content: SizedBox(
                  width: double.maxFinite,
                  child: Column(
                    children: [
                      // 🔍 Search bar
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: TextField(
                          onChanged: (value) =>
                              setLocalState(() => searchQuery = value),
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: "Search exercises...",
                            hintStyle: const TextStyle(color: Colors.white54),
                            filled: true,
                            fillColor: Colors.blueGrey.shade800,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8.0)),
                            prefixIcon:
                                const Icon(Icons.search, color: Colors.white70),
                          ),
                        ),
                      ),

                      // 🔍 Filtered exercise list
                      Expanded(
                        child: searchQuery.trim().isNotEmpty
                            ? ListView(
                                children: filteredExercises.map((ex) {
                                  final name = ex['name']!;
                                  final isChecked = tempSelected.contains(name);
                                  return CheckboxListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 10), // 🔧 tighter spacing
                                    dense: true, // ✅ less vertical space
                                    value: isChecked,
                                    title: Text(
                                      name,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 18),
                                    ),
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    activeColor: Colors.lightBlueAccent,
                                    checkColor: Colors.black,

                                    onChanged: (checked) {
                                      setLocalState(() {
                                        if (checked == true) {
                                          tempSelected.add(name);
                                        } else {
                                          tempSelected.remove(name);
                                        }
                                      });
                                    },
                                  );
                                }).toList(),
                              )
                            : ListView(
                                children: orderedGrouped.entries.map((entry) {
                                  final category = entry.key;
                                  final exercises = entry.value;
                                  final isExpanded =
                                      expandedGroups[category] ?? false;

                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ListTile(
                                        tileColor: Colors.blueGrey.shade800,
                                        title: Text(category,
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold)),
                                        trailing: Icon(
                                          isExpanded
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                          color: Colors.white70,
                                        ),
                                        onTap: () {
                                          setLocalState(() {
                                            expandedGroups[category] =
                                                !isExpanded;
                                          });
                                        },
                                      ),
                                      if (isExpanded)
                                        ...exercises.map((name) {
                                          final isChecked =
                                              tempSelected.contains(name);
                                          return CheckboxListTile(
                                            value: isChecked,
                                            title: Text(name,
                                                style: const TextStyle(
                                                    color: Colors.white)),
                                            controlAffinity:
                                                ListTileControlAffinity.leading,
                                            activeColor: Colors.lightBlueAccent,
                                            checkColor: Colors.black,
                                            onChanged: (checked) {
                                              setLocalState(() {
                                                if (checked == true) {
                                                  tempSelected.add(name);
                                                } else {
                                                  tempSelected.remove(name);
                                                }
                                              });
                                            },
                                          );
                                        }),
                                      const Divider(
                                          height: 10, color: Colors.grey),
                                    ],
                                  );
                                }).toList(),
                              ),
                      ),
                    ],
                  ),
                ),

                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("Cancel"),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, tempSelected),
                    child: const Text("Save"),
                  ),
                ],
              );
            });
          },
        ) ??
        [];

    setState(() {
      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(
        selected.map((name) => {
              'name': name,
              'circuitIndex': 0,
            }),
      );

      _workoutSets.clear();
      _workoutSets.addAll(
        List.generate(
          _selectedExercisesWithCircuits.length,
          (_) => List.generate(_defaultSets, (_) => SetDetails()),
        ),
      );

      _initializeControllers();
      _populateVelocityFlags();
    });
  }

  void _showExercisePickerForRow(int index) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (plannedExercises.isEmpty) {
      await loadPlannedExercisesFromFirestore();
    }

    bool plannedModeAvailable = plannedExercises.isNotEmpty;
    final snapshot =
        await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs
        .map((doc) => {
              'id': doc.id,
              'name': doc['name'] as String,
              'category': doc['category'] as String,
            })
        .toList();

    final Map<String, String> nameToIdMap = {
      for (final ex in allExercises) ex['name']!: ex['id']!,
    };

    bool showPlannedOnly = true;
    final Map<String, bool> expandedGroups = {};
    String searchQuery = '';

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (context, setLocalState) {
          List<Widget> _buildExerciseList() {
            final filteredExercises = (showPlannedOnly && plannedModeAvailable)
                ? allExercises
                    .where((ex) => plannedExercises.contains(ex['id']))
                    .toList()
                : allExercises;

            final searched = searchQuery.isNotEmpty
                ? filteredExercises
                    .where(
                        (ex) => ex['name']!.toLowerCase().contains(searchQuery))
                    .toList()
                : filteredExercises;

            if (searchQuery.isNotEmpty) {
              return searched
                  .map((ex) => ListTile(
                        title: Text(ex['name']!,
                            style: const TextStyle(color: Colors.white70)),
                        onTap: () => Navigator.pop(ctx, ex['name']!),
                        dense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 10),
                      ))
                  .toList();
            }

            final Map<String, List<String>> grouped = {};
            for (final exercise in filteredExercises) {
              final category = exercise['category'] ?? 'Other';
              final name = exercise['name'] ?? 'Unnamed';
              grouped.putIfAbsent(category, () => []).add(name);
            }

            for (final group in grouped.values) {
              group.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
            }

            const categoryOrder = [
              'Horizontal Press',
              'Horizontal Pull',
              'Vertical Press',
              'Vertical Pull',
              'Lateral Raise',
              'Arm Extension',
              'Arm Curl',
              'Squat Pattern',
              'Hip Hinge',
              'Leg Extension',
              'Leg Curl',
              'Hip Abduction/adduction',
              'Calf Raise',
              'Core',
            ];

            final Map<String, List<String>> orderedGrouped = {};
            for (final cat in categoryOrder) {
              if (grouped.containsKey(cat)) {
                orderedGrouped[cat] = grouped[cat]!;
              }
            }
            for (final entry in grouped.entries) {
              if (!orderedGrouped.containsKey(entry.key)) {
                orderedGrouped[entry.key] = entry.value;
              }
            }

            for (final category in orderedGrouped.keys) {
              expandedGroups.putIfAbsent(category, () => false);
            }

            return orderedGrouped.entries.map((entry) {
              final category = entry.key;
              final exercises = entry.value;
              final isExpanded = expandedGroups[category] ?? false;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    tileColor: Colors.blueGrey.shade800,
                    title: Text(category,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    trailing: Icon(
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white70,
                    ),
                    onTap: () => setLocalState(
                        () => expandedGroups[category] = !isExpanded),
                  ),
                  if (isExpanded)
                    ...exercises.map((name) => ListTile(
                          title: Text(name,
                              style: const TextStyle(color: Colors.white70)),
                          onTap: () => Navigator.pop(ctx, name),
                          dense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 10),
                        )),
                  const Divider(height: 10, color: Colors.grey),
                ],
              );
            }).toList();
          }

          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            insetPadding: const EdgeInsets.symmetric(
                horizontal: 24, vertical: 2), // 🔧 reduce horizontal margin
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12), // 🔧 reduce internal padding
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Select Exercise",
                    style: TextStyle(fontSize: 13, color: Colors.white)),
                if (plannedModeAvailable)
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        onChanged: (value) =>
                            setLocalState(() => showPlannedOnly = value),
                        activeColor: Colors.lightBlueAccent,
                      ),
                    ],
                  )
                else
                  const SizedBox(),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              height: 400,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10.0),
                    child: TextField(
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search exercises...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.blueGrey.shade800,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8.0)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10.0, vertical: 10.0),
                      ),
                      onChanged: (val) =>
                          setLocalState(() => searchQuery = val.toLowerCase()),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: _buildExerciseList(),
                    ),
                  ),
                ],
              ),
            ),
          );
        });
      },
    );

    if (selected != null && selected.isNotEmpty) {
      setState(() {
        _selectedExercisesWithCircuits[index]['name'] = selected;
        _populateVelocityFlags();
      });
    }
  }

  void _onReorderExercises(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;

      // Remove data from old position
      final movedExercise = _selectedExercisesWithCircuits.removeAt(oldIndex);
      final movedSets = _workoutSets.removeAt(oldIndex);
      final movedReps = _repsControllers.removeAt(oldIndex);
      final movedWeight = _weightControllers.removeAt(oldIndex);
      final movedRir = _rirControllers.removeAt(oldIndex);

      // Get new circuit index from neighbor (fallback to 0)
      int newCircuitIndex = 0;
      if (_selectedExercisesWithCircuits.isNotEmpty) {
        if (newIndex == 0) {
          newCircuitIndex =
              _selectedExercisesWithCircuits.first['circuitIndex'] ?? 0;
        } else if (newIndex >= _selectedExercisesWithCircuits.length) {
          newCircuitIndex =
              _selectedExercisesWithCircuits.last['circuitIndex'] ?? 0;
        } else {
          newCircuitIndex =
              _selectedExercisesWithCircuits[newIndex]['circuitIndex'] ?? 0;
        }
      }

      movedExercise['circuitIndex'] = newCircuitIndex;

      _cachedProgressedValues.clear();

      // Insert at new position
      _selectedExercisesWithCircuits.insert(newIndex, movedExercise);
      _workoutSets.insert(newIndex, movedSets);
      _repsControllers.insert(newIndex, movedReps);
      _weightControllers.insert(newIndex, movedWeight);
      _rirControllers.insert(newIndex, movedRir);
    });
  }

  Future<void> _saveWorkout() async {
    if (_workoutNameController.text.isEmpty ||
        _selectedExercisesWithCircuits.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields.')),
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to save workouts.')),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final dateKey =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    final draftJson = prefs.getString(draftKey);
    final timestampStr = prefs.getString(timestampKey);

    if (draftJson != null && timestampStr != null) {
      final savedTime = DateTime.tryParse(timestampStr);
      final now = DateTime.now();

      if (savedTime != null && now.difference(savedTime).inMinutes >= 120) {
        try {
          final parsed = jsonDecode(draftJson);
          final exercises =
              List<Map<String, dynamic>>.from(parsed['exercises'] ?? []);
          final sets = List<List>.from(parsed['sets'] ?? []);

          final filtered = <Map<String, dynamic>>[];

          for (int i = 0; i < exercises.length; i++) {
            final exercise = exercises[i];
            final setList = List<Map<String, dynamic>>.from(sets[i]);

            final hasData = setList
                .any((s) => (s['weight'] ?? 0) > 0 || (s['reps'] ?? 0) > 0);
            if (hasData) {
              filtered.add({
                'name': exercise['name'],
                'circuitIndex': exercise['circuitIndex'],
                'sets': setList
              });
            }
          }

          if (filtered.isNotEmpty) {
            print("[WES] Injecting expired draft data before save");

            _selectedExercisesWithCircuits.clear();
            _workoutSets.clear();

            for (final ex in filtered) {
              _selectedExercisesWithCircuits.add({
                'name': ex['name'],
                'circuitIndex': ex['circuitIndex'],
              });

              final setList = List<Map<String, dynamic>>.from(ex['sets']);
              final sets = setList
                  .map((s) => SetDetails(
                reps: s['reps'],
                weight: (s['weight'] as num?)?.toDouble(),
                rir: (s['rir'] as num?)?.toDouble(),
                velocity: (s['velocity'] as num?)?.toDouble(), // ✅ even if null, fine
                notes: s['notes']?.toString(),                // ✅ string or null
              ))
                  .toList();


              _workoutSets.add(sets);
            }

            _initializeControllers();
          }

          await prefs.remove(draftKey);
          await prefs.remove(timestampKey);
        } catch (e) {
          debugPrint('[WES] Failed to inject expired draft: $e');
        }
      }
    }

    // ✅ Sync TextField input into _workoutSets
    for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
      for (int j = 0; j < _workoutSets[i].length; j++) {
        final repsText = _repsControllers[i][j].text.trim();
        final weightText = _weightControllers[i][j].text.trim();
        final rirText = _rirControllers[i][j].text.trim();
        final velocityText = _velocityControllers[i][j].text.trim();
        final notesText = _notesControllers[i][j].text.trim();

        _workoutSets[i][j].reps =
            repsText.isNotEmpty ? int.tryParse(repsText) : null;
        _workoutSets[i][j].weight =
            weightText.isNotEmpty ? double.tryParse(weightText) : null;
        _workoutSets[i][j].rir =
            rirText.isNotEmpty ? double.tryParse(rirText) : null;
        _workoutSets[i][j].velocity =
        velocityText.isNotEmpty ? double.tryParse(velocityText) : null;
        _workoutSets[i][j].notes = notesText.isNotEmpty ? notesText : null;
      }
    }

    // ✅ Create Firestore save payload
    final workoutData = {
      'name': _workoutNameController.text,
      'date': _selectedDate.toIso8601String(),
      'userId': user.uid,
      'exercises': _selectedExercisesWithCircuits
          .asMap()
          .entries
          .map((entry) {
            int exerciseIndex = entry.key;
            String exerciseName = (entry.value['name'] is String &&
                    entry.value['name'].toString().trim().isNotEmpty)
                ? entry.value['name']
                : 'Unnamed';

            int circuitIndex = entry.value['circuitIndex'] ?? 0;

            List<Map<String, dynamic>> validSets = [];

            for (int setIndex = 0;
                setIndex < _workoutSets[exerciseIndex].length;
                setIndex++) {
              final set = _workoutSets[exerciseIndex][setIndex];
              final weight = set.weight ?? 0.0;

              if (weight > 0) {
                validSets.add({
                  'exerciseName': exerciseName,
                  'reps': set.reps ?? 0,
                  'weight': weight,
                  'rir': set.rir ?? 0.0,
                  'velocity': set.velocity,
                  'notes': set.notes,
                });

              }
            }

            return validSets.isNotEmpty
                ? {
                    'name': exerciseName,
                    'circuitIndex': circuitIndex,
                    'sets': validSets,
                  }
                : null;
          })
          .where((e) => e != null)
          .toList(),
    };

    try {
      print("🧠 Saving to Firestore: ${jsonEncode(workoutData)}");
      print("📍 Writing to /users/${user.uid}/workouts/");

      // 🔍 Debug each key in the workoutData map
      workoutData.forEach((key, value) {
        if (value == null) {
          print('⚠️ workoutData["$key"] is null!');
        } else {
          print('✅ workoutData["$key"] = ${value.runtimeType} → $value');
        }
      });

      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('workouts')
          .add(workoutData);

      print("✅ Workout saved to Firestore successfully.");

      Navigator.pop(context); // ✅ Restores the old behavior
    } catch (e) {
      print("❌ Failed to save workout: $e");

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workout saved successfully.')),
      );

      // ✅ Push workout into BlockBuilder day (block_data)
      final userDoc =
          FirebaseFirestore.instance.collection('users').doc(userId);

// 1️⃣ Reference your actual block document:
      final blockId = widget.blockId;
      if (blockId != null && blockId.isNotEmpty) {
        final blockRef = FirebaseFirestore.instance
            .collection('planned_blocks')
            .doc(userId)
            .collection('blocks')
            .doc(blockId);

        // 2️⃣ Fetch its meta:
        final blockSnap = await blockRef.get();
        if (blockSnap.exists) {
          // 3️⃣ Read the startDate as a Timestamp
          final ts = blockSnap.get('startDate') as Timestamp?;
          if (ts != null) {
            final blockStart = ts.toDate();

            // 4️⃣ Compute week/day indexes
            final daysSinceStart = _selectedDate.difference(blockStart).inDays;
            final weekIndex = (daysSinceStart / 7).floor();
            final dayIndex = daysSinceStart % 7;

            // 5️⃣ Point at the exact week doc under your block:
            final weekDocRef =
                blockRef.collection('weeks').doc('week_$weekIndex');

            // Ensure week doc exists
            await weekDocRef.set({'exists': true}, SetOptions(merge: true));

            final List<Map<String, dynamic>> updatedExercises = [];

            for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
              final name =
                  _selectedExercisesWithCircuits[i]['name'] ?? 'Unnamed';
              final circuitIndex =
                  _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;
              final sets = _workoutSets[i];

              final validSets = sets.where((s) {
                final reps = s.reps ?? 0;
                final weight = s.weight ?? 0.0;
                return reps >= 1 || weight > 1;
              }).toList();

              if (validSets.isEmpty) continue;

              final bestSet = validSets.fold<SetDetails?>(null, (prev, curr) {
                if (prev == null) return curr;
                final prevE1RM =
                    calculateE1RM(prev.weight, prev.reps?.toDouble(), prev.rir);
                final currE1RM =
                    calculateE1RM(curr.weight, curr.reps?.toDouble(), curr.rir);
                return (currE1RM > prevE1RM) ? curr : prev;
              });

              if (bestSet != null && bestSet.weight != null && bestSet.reps != null) {
                final topSetData = {
                  'name': name,
                  'circuitIndex': circuitIndex,
                  'weight': bestSet.weight,
                  'reps': bestSet.reps,
                  'rir': bestSet.rir ?? 0.0,
                };

                // ✅ Include velocity if available
                if (bestSet.velocity != null && bestSet.velocity! > 0) {
                  topSetData['velocity'] = bestSet.velocity;
                }

                // ✅ Include notes if available
                if (bestSet.notes != null && bestSet.notes!.isNotEmpty) {
                  topSetData['notes'] = bestSet.notes;
                }

                updatedExercises.add(topSetData);
              }

            }

            // Fetch current day data
            final dayDoc =
                await weekDocRef.collection('days').doc('day_$dayIndex').get();
            final existing = dayDoc.data();
            final List<Map<String, dynamic>> existingExercises =
                List<Map<String, dynamic>>.from(existing?['exercises'] ?? []);

            // Merge existing + new, keeping highest E1RM
            for (final newEx in updatedExercises) {
              final matchIndex = existingExercises
                  .indexWhere((e) => e['name'] == newEx['name']);
              if (matchIndex == -1) {
                existingExercises.add(newEx);
              } else {
                final existingEx = existingExercises[matchIndex];
                final oldE1RM = calculateE1RM(existingEx['weight'],
                    existingEx['reps']?.toDouble(), existingEx['rir']);
                final newE1RM = calculateE1RM(
                    newEx['weight'], newEx['reps']?.toDouble(), newEx['rir']);
                if (newE1RM > oldE1RM) {
                  existingExercises[matchIndex] = newEx;
                }
              }
            }

            await weekDocRef
                .collection('days')
                .doc('day_$dayIndex')
                .set({'exercises': existingExercises}, SetOptions(merge: true));
          }
        }
      }

      // ✅ Return top sets to BlockBuilder
      Navigator.pop(context, {
        'date': _selectedDate,
        'topSets': List.generate(_selectedExercisesWithCircuits.length, (i) {
          final sets = _workoutSets[i];
          final validSets = sets.where((s) {
            final reps = s.reps ?? 0;
            final weight = s.weight ?? 0.0;
            return reps >= 1 || weight > 1;
          }).toList();

          if (validSets.isEmpty) return null;

          final bestSet = validSets.fold<SetDetails?>(null, (prev, curr) {
            if (prev == null) return curr;
            final prevE1RM =
                calculateE1RM(prev.weight, prev.reps?.toDouble(), prev.rir);
            final currE1RM =
                calculateE1RM(curr.weight, curr.reps?.toDouble(), curr.rir);
            return (currE1RM > prevE1RM) ? curr : prev;
          });

          if (bestSet == null) return null;

          final topSet = {
            'exercise': _selectedExercisesWithCircuits[i],
            'weight': bestSet.weight,
            'reps': bestSet.reps,
            'rir': bestSet.rir,
          };

// ✅ Optionally include velocity and notes
          if (bestSet.velocity != null && bestSet.velocity! > 0) {
            topSet['velocity'] = bestSet.velocity;
          }
          if (bestSet.notes != null && bestSet.notes!.isNotEmpty) {
            topSet['notes'] = bestSet.notes;
          }

          return topSet;

        }).where((e) => e != null).toList(),
        // ← collection-if: only include when date actually changed
        if (_selectedDate != widget.initialDate)
          'reschedule': {
            'from': widget.initialDate!,
            'to': _selectedDate,
          },
      });

      await clearWorkoutDraftCache(); // ✅ Clear saved draft once workout is committed
      print('Draft cache cleared after workout save.');

// 🧠 Save savedFields to SharedPreferences for BB2 to pick up
      final prefs = await SharedPreferences.getInstance();
      final List<String> savedFieldKeys = [];

      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final name = _selectedExercisesWithCircuits[i]['name'];
        final circuitIndex =
            _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;
        final set = _workoutSets[i].isNotEmpty ? _workoutSets[i][0] : null;
        if (set == null) continue;

        final blockDoc = await FirebaseFirestore.instance
            .collection('planned_blocks')
            .doc(userId)
            .collection('blocks')
            .doc(blockId)
            .get();
        final blockStartStr = blockDoc.data()?['blockStartDate'];
        final blockStart = DateTime.parse(blockStartStr);
        final daysSinceStart = _selectedDate.difference(blockStart).inDays;
        final weekIndex = (daysSinceStart / 7).floor();
        final dayIndex = daysSinceStart % 7;

        if ((set.weight ?? 0) > 0) {
          savedFieldKeys.add('w${weekIndex}_d${dayIndex}_r${i}_weight');
        }
        if ((set.reps ?? 0) > 0) {
          savedFieldKeys.add('w${weekIndex}_d${dayIndex}_r${i}_reps');
        }
        if ((set.rir ?? 0) > 0) {
          savedFieldKeys.add('w${weekIndex}_d${dayIndex}_r${i}_rir');
        }
        if ((set.velocity ?? 0) > 0) {
          savedFieldKeys.add('w${weekIndex}_d${dayIndex}_r${i}_velocity');
        }
        if ((set.notes ?? '').toString().trim().isNotEmpty) {
          savedFieldKeys.add('w${weekIndex}_d${dayIndex}_r${i}_notes');
        }

      }

      await prefs.setStringList(
        'savedFields_${_selectedDate.toIso8601String().substring(0, 10)}',
        savedFieldKeys,
      );
    }
    await _clearDraft();
    setState(() {
      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();
      _velocityControllers.clear();
      _notesControllers.clear();
      _resolvedBB2Values.clear();
      _workoutNameController.text = _formatWorkoutDate(_selectedDate);
    });


  }

  Future<Map<String, dynamic>?> getBB2ExerciseValuesForDate({
    required String exerciseName,
    required DateTime date,
    required DateTime blockStartDate,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    // 1️⃣ Make sure we have a blockId on this screen
    final blockId = widget.blockId;
    if (blockId == null || blockId.isEmpty) return null;

    // 2️⃣ Compute which week/day to read
    final normalizedName = exerciseName.trim().toLowerCase();
    final weekIndex =
        PeriodizationModelUtils.getWeekIndexForDate(date, blockStartDate);
    final dayIndex = date.weekday - 1; // Mon=0 ... Sun=6

    // 3️⃣ Point at planned_blocks/{uid}/blocks/{blockId}/weeks/week_<i>
    final blockRef = FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
        .doc(blockId);

    final weekDocRef = blockRef.collection('weeks').doc('week_$weekIndex');

    // 4️⃣ Grab that day document
    final daySnapshot =
        await weekDocRef.collection('days').doc('day_$dayIndex').get();

    if (!daySnapshot.exists) return null;

    // 5️⃣ Parse out your saved exercises
    final exercises = List<Map<String, dynamic>>.from(
        daySnapshot.data()?['exercises'] ?? <Map<String, dynamic>>[]);

    // 6️⃣ Find the matching exercise by (lower-case) name
    for (final ex in exercises) {
      final name = (ex['name'] ?? '').toString().trim().toLowerCase();
      if (name == normalizedName) {
        final reps = ex['reps'] is num ? (ex['reps'] as num).toInt() : null;
        final weight =
            ex['weight'] is num ? (ex['weight'] as num).toDouble() : null;
        final rir = ex['rir'] is num ? (ex['rir'] as num).toDouble() : null;

        return {
          'reps': reps,
          'weight': weight,
          'rir': rir,
        };
      }
    }

    return null;
  }

  Future<Map<String, dynamic>?> getBB2SavedValuesFromSharedPrefs(
      String exerciseName, DateTime date) async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final raw = prefs.getString('bb2_dayData_$dateKey');

    if (raw == null) {
      print('❌ [WES] No BB2 SharedPrefs for $dateKey');
      return null;
    }

    final data = jsonDecode(raw);
    final exercises = List<Map<String, dynamic>>.from(data['exercises'] ?? []);

    final match = exercises.firstWhere(
      (e) =>
          (e['name']?.toString().trim().toLowerCase() ?? '') ==
          exerciseName.trim().toLowerCase(),
      orElse: () => {},
    );

    if (match.isNotEmpty) {
      print('🧪 [WES] BB2 SharedPrefs match for "$exerciseName": $match');
      return {
        'reps': match['reps'],
        'weight': match['weight'],
        'rir': match['rir'],
      };
    } else {
      print(
          '🚫 [WES] No matching exercise "$exerciseName" found in SharedPrefs for $dateKey');
      return null;
    }
  }

  Future<void> _saveWorkoutDraftToCache() async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    final workoutDraft = {
      'name': _workoutNameController.text,
      'date': _selectedDate.toIso8601String(),
      'exercises': _selectedExercisesWithCircuits,
      'sets': _workoutSets.map((setsForExercise) {
        return setsForExercise
            .map((set) => {
                  'reps': set.reps,
                  'weight': set.weight,
                  'rir': set.rir,
                })
            .toList();
      }).toList(),
    };

    await prefs.setString(
        draftKey, jsonEncode(workoutDraft)); // ✅ actually save the draft
    await prefs.setString(
        timestampKey, DateTime.now().toIso8601String()); // ✅ save timestamp

    print("[WES] Draft saved for $_selectedDate under key: $draftKey");
  }

  Future<bool> _loadWorkoutDraftFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey =
        '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    final draftJson = prefs.getString(draftKey);
    final savedAtString = prefs.getString(timestampKey);

    if (draftJson == null || savedAtString == null) {
      print('[WES] No draft found for $dateKey.');
      return false;
    }

    try {
      final savedAt = DateTime.parse(savedAtString);
      final now = DateTime.now();
      final draft = jsonDecode(draftJson);

      final exercises =
          List<Map<String, dynamic>>.from(draft['exercises'] ?? []);
      final sets = List<List>.from(draft['sets'] ?? []);

      final filteredExercises = <Map<String, dynamic>>[];
      final filteredSets = <List<Map<String, dynamic>>>[];

      for (int i = 0; i < exercises.length; i++) {
        final setList = List<Map<String, dynamic>>.from(sets[i]);
        final hasRealData = setList.any((s) =>
            (s['weight'] ?? 0) > 0 ||
            (s['reps'] ?? 0) > 0 ||
            (s['rir'] ?? 0) > 0);
        if (hasRealData) {
          filteredExercises.add(exercises[i]);
          filteredSets.add(setList);
        }
      }

      final isExpired = now.difference(savedAt) > const Duration(hours: 2);

      if (isExpired) {
        await prefs.remove(draftKey);
        await prefs.remove(timestampKey);

        if (filteredExercises.isEmpty) {
          print('[WES] Draft expired and had no usable data — discarded.');
          return false;
        } else {
          print('[WES] Draft expired, but kept ${filteredExercises.length} non-empty exercises.');
        }
      } else {
        if (filteredExercises.isEmpty) {
          print('[WES] Draft is fresh but has no real data — skipping.');
          return false;
        }
        print('[WES] Draft is fresh — all exercises kept.');
      }



      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(filteredExercises);

      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();

      for (int i = 0; i < filteredExercises.length; i++) {
        final setList = filteredSets[i];

        _workoutSets.add(setList
            .map((s) => SetDetails(
                  reps: s['reps'],
                  weight: (s['weight'] as num?)?.toDouble(),
                  rir: (s['rir'] as num?)?.toDouble(),
                ))
            .toList());

        _repsControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));
        _weightControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));
        _rirControllers
            .add(List.generate(setList.length, (_) => TextEditingController()));
      }

      _initializeControllers();
      _workoutNameController.text = draft['name'] ?? '';

      print(
          '[WES] Loaded draft (expired=$isExpired, kept=${filteredExercises.length})');

      return true;
    } catch (e) {
      debugPrint('[WES] Failed to load workout draft for $dateKey: $e');
      return false;
    }
  }



  Future<void> _mergeNewBB2ExercisesIntoDraft() async {
    print('[WES] Attempting to merge BB2 exercises into draft for $_selectedDate');

    final uid = UserContext.of(context, listen: false).currentUid;
    if (_selectedBlockId == null || _selectedDate == null) return;

    print('👤 [BB2 Merge] Using uid=$uid for athlete merge');

    // ✅ Clear state only if the selected athlete has changed
    final shouldForceMerge = _lastMergedUid != uid || _lastMergedDate != _selectedDate;

    if (shouldForceMerge) {
      print('🔁 [WES] Triggering BB2 merge due to athlete/date switch');
      setState(() {
        _selectedExercisesWithCircuits.clear();
        _workoutSets.clear();
        _repsControllers.clear();
        _weightControllers.clear();
        _rirControllers.clear();
        _velocityControllers.clear();
        _notesControllers.clear();
        _resolvedBB2Values.clear();
      });
      _lastMergedUid = uid;
      _lastMergedDate = _selectedDate;
    }



    final blockId = _selectedBlockId!;
    final daysSinceStart = _selectedDate.difference(blockStartDate!).inDays;
    if (daysSinceStart < 0) return;
    print('[WES Merge] daysSinceStart = $daysSinceStart');


    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex = daysSinceStart % 7;

    // Try modern BB2 source: weeks > days
    final dayDoc = await FirebaseFirestore.instance
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc(blockId)
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex')
        .get();

    print('[DEBUG] WES fetched day_$dayIndex → exists = ${dayDoc.exists}');
    print('[DEBUG] WES data = ${dayDoc.data()}');

    List<Map<String, dynamic>> bb2Exercises = [];

    if (dayDoc.exists && dayDoc.data()?['exercises'] != null) {
      bb2Exercises = List<Map<String, dynamic>>.from(dayDoc.data()!['exercises']);
      print('[WES] BB2 day doc exercises (weeks/days): ${bb2Exercises.length}');
    }

    // 🔁 Fallback to block_data if no new BB2 exercises found
    if (bb2Exercises.isEmpty) {
      final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final blockDataDoc = await FirebaseFirestore.instance
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
          .doc(blockId)
          .collection('block_data')
          .doc(dateKey)
          .get();

      if (blockDataDoc.exists && blockDataDoc.data()?['rows'] != null) {
        bb2Exercises = List<Map<String, dynamic>>.from(blockDataDoc.data()!['rows']);
        print('[WES] BB2 fallback exercises (block_data): ${bb2Exercises.length}');
      }
    }

    if (bb2Exercises.isEmpty) {
      print('[WES] No BB2 exercises to merge for $_selectedDate');
      return;
    }

    // Merge logic
    final existingNames = _selectedExercisesWithCircuits.map((e) => e['name']).toSet();
    final newOnes = bb2Exercises.where((ex) => !existingNames.contains(ex['name'])).toList();

    print('[WES] Found ${newOnes.length} new BB2 exercises to merge');

    if (newOnes.isNotEmpty) {
      setState(() {
        for (final newEx in newOnes) {
          _selectedExercisesWithCircuits.add({
            'name': newEx['name'],
            'circuitIndex': newEx['circuitIndex'] ?? 0,
          });

          _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
          _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _velocityControllers.add(List.generate(_defaultSets, (_) => TextEditingController())); // ✅ NEW
          _notesControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));    // ✅ NEW
        }
      });

      for (final newEx in newOnes) {
        final name = newEx['name']?.toString().trim().toLowerCase();
        if (name == null || _resolvedBB2Values.containsKey(name)) continue;

        // 🔍 Try modern flat structure first
        final flatReps = newEx['reps'];
        final flatWeight = newEx['weight'];
        final flatRir = newEx['rir'];

        if (flatReps != null || flatWeight != null || flatRir != null) {
          _resolvedBB2Values[name] = {
            'reps': flatReps,
            'weight': flatWeight,
            'rir': flatRir,
          };
          print('🧠 [WES Merge] Injected FLAT BB2 values for $name = ${_resolvedBB2Values[name]}');
          continue;
        }

        // 🔁 Fallback to legacy sets[0] structure
        final rawSets = newEx['sets'];
        if (rawSets is List && rawSets.isNotEmpty) {
          final firstSet = rawSets.first;
          _resolvedBB2Values[name] = {
            'reps': firstSet['reps'],
            'weight': firstSet['weight'],
            'rir': firstSet['rir'],
          };
          print('🧠 [WES Merge] Injected SETS[0] BB2 values for $name = ${_resolvedBB2Values[name]}');
        } else {
          print('❌ [WES Merge] No valid sets or flat fields found for $name');
        }
      }





      print("[WES] Merged ${newOnes.length} new BB2 exercises into draft");
      await _saveWorkoutDraftToCache();
    }

  }


  void addSet(int exerciseIndex) {
    setState(() {
      _workoutSets[exerciseIndex].add(SetDetails(reps: 0, weight: 0, rir: 0));
      _repsControllers[exerciseIndex].add(TextEditingController());
      _weightControllers[exerciseIndex].add(TextEditingController());
      _rirControllers[exerciseIndex].add(TextEditingController());
    });
  }

  void removeSet(int exerciseIndex, int setIndex) {
    setState(() {
      // Check if only one set remains and confirm removal
      if (_workoutSets[exerciseIndex].length == 1) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Confirm Removal'),
              content:
                  const Text('Are you sure you want to remove this exercise?'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedExercisesWithCircuits.removeAt(exerciseIndex);
                      _workoutSets.removeAt(exerciseIndex);
                      _repsControllers.removeAt(exerciseIndex);
                      _weightControllers.removeAt(exerciseIndex);
                      _rirControllers.removeAt(exerciseIndex);
                    });
                    Navigator.of(context).pop();
                  },
                  child: const Text('Yes'),
                ),
              ],
            );
          },
        );
      } else {
        // Remove the specific set at setIndex
        _workoutSets[exerciseIndex].removeAt(setIndex);
        _repsControllers[exerciseIndex].removeAt(setIndex);
        _weightControllers[exerciseIndex].removeAt(setIndex);
        _rirControllers[exerciseIndex].removeAt(setIndex);

        // Re-initialize controllers for consistent UI behavior
        _initializeControllers();
      }
    });
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );

    if (pickedDate == null || pickedDate == _selectedDate) {
      print('⛔️ [WES] Date selection cancelled or unchanged');
      return;
    }

    print('📆 [WES] Date changed to: ${DateFormat('yyyy-MM-dd').format(pickedDate)}');


    _cachedProgressedValues.clear(); // ✅ Main fix

    await _persistDraftLocally(); // ✅ Save previous date before switching


    // 2️⃣ Update selected date and clear UI state
    print('🧼 [WES] Clearing UI and updating selected date...');
    setState(() {
      _selectedDate = pickedDate;
      _workoutNameController.text = _formatWorkoutDate(_selectedDate);
      _selectedExercisesWithCircuits.clear();
      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();
      _resolvedBB2Values.clear();

    });

// 3️⃣ Load locally saved draft (if available)
    print('📂 [WES] Attempting to load local draft for new date...');
    await _loadDraftLocallyIfAvailable();


    // 4️⃣ Merge in BB2 exercises (this now acts as the **primary** loader)
    print('🔁 [WES] Merging in BB2 exercises for selected date...');
    await _mergeNewBB2ExercisesIntoDraft();



    // 5️⃣ Always load read-only BB2 visual hints (e.g. pink fields)
    print('🔍 [WES] Loading BB2 read-only visual hints...');
    //await _loadExercisesFromBB2ForDay();

    print('✅ [WES] Date switch complete.');
  }




  String _formatWorkoutDate(DateTime date) {
    final dayOfWeek = DateFormat('EEEE').format(date); // e.g., Tuesday
    final day = date.day; // 29
    final month = DateFormat('MMMM').format(date); // April
    final year = date.year; // 2025

    return '$dayOfWeek $day $month $year';
  }

  void _navigateToExerciseDetails(String exerciseName) async {
    List<Workout> recentWorkouts =
        await getRecentWorkoutsForExercise(exerciseName, _selectedDate);

    if (recentWorkouts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No recent workouts found for this exercise.')),
      );
      return; // ✅ Do not navigate if no workouts exist
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExerciseDetailsScreen(
          exerciseName: exerciseName,
          recentWorkouts: recentWorkouts,
        ),
      ),
    );
  }

  void _navigateToTopSets(String exerciseName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(20)
        .get();

    final recentWorkouts = snapshot.docs
        .map((doc) {
          return Workout.fromFirestore(doc);
        })
        .where(
            (workout) => workout.exercises.any((ex) => ex.name == exerciseName))
        .toList();

    if (recentWorkouts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No recent workouts found for this exercise.')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TopSetsScreen(
          exerciseName: exerciseName,
          recentWorkouts: recentWorkouts,
        ),
      ),
    );
  }

  Future<List<Workout>> getRecentWorkoutsForExercise(
      String exerciseName, DateTime currentWorkoutDate) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return [];
    }

    try {
      // ✅ Fetch last 12 workouts from Firestore
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('workouts')
          .orderBy('date', descending: true)
          .limit(12)
          .get();

      List<Workout> filteredWorkouts = snapshot.docs
          .map((doc) {
            final data = doc.data();

            // ✅ Handle both Firestore Timestamp and String date formats safely
            DateTime workoutDate;
            if (data['date'] is Timestamp) {
              workoutDate = (data['date'] as Timestamp).toDate();
            } else if (data['date'] is String) {
              workoutDate = DateTime.tryParse(data['date']) ?? DateTime.now();
            } else {
              throw Exception('Invalid date format in Firestore');
            }

            // ✅ Convert exercises safely
            List<Exercise> exercises = [];
            if (data['exercises'] is List) {
              exercises = (data['exercises'] as List)
                  .map((exercise) =>
                      Exercise.fromFirestore(exercise as Map<String, dynamic>))
                  .toList();
            }

            return Workout(
              name: data['name'] ?? 'Unnamed Workout',
              date: workoutDate,
              exercises: exercises,
            );
          })
          .where((workout) =>
              workout.date.isBefore(currentWorkoutDate) &&
              workout.exercises
                  .any((exercise) => exercise.name == exerciseName))
          .toList();

      return filteredWorkouts;
    } catch (error) {
      print('Error fetching workouts: $error');
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
        future: _initialLoad, // ✅ only runs once, doesn't re-run on rebuild
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          // ✅ Once data is loaded, render full WES UI
         // final exercises = widget.prefilledExercisesWithCircuits;
          // ✅ DEBUG: Log what exercises we're rendering
          print('🖼️ [WES UI] build() triggered — exercises in _selectedExercisesWithCircuits = ${_selectedExercisesWithCircuits.length}');
          for (var ex in _selectedExercisesWithCircuits) {
            print('     → ${ex['name']}');
          }

          return Scaffold(
      backgroundColor: Colors.blueGrey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.blueGrey.shade800,
        title: const Text(
          'Razors Edge',
          style: TextStyle(fontFamily: 'Verdana', color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: "Undo last action",
            onPressed: _lastUndoAction != null
                ? () {
                    _lastUndoAction?.call();
                    _lastUndoAction = null;
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text(
                      'Clear Workout',
                      style:
                          TextStyle(fontFamily: 'Verdana', color: Colors.white),
                    ),
                    content: const Text(
                      'Delete this workout?',
                      style:
                          TextStyle(fontFamily: 'Verdana', color: Colors.white),
                    ),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _workoutNameController.clear();
                            _selectedExercisesWithCircuits.clear();
                            _workoutSets.clear();
                            _initializeControllers();
                          });
                          Navigator.of(context).pop();
                        },
                        child: const Text('Yes'),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveWorkout,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(left: 12, top: 0, right: 12, bottom: 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _workoutNameController,
              style: TextStyle(fontSize: 18),
              textAlign: TextAlign.center, // 👈 Center the text,
              decoration: InputDecoration(
                // ✅ remove `const`
                labelStyle: const TextStyle(color: Colors.white),
                filled: true,
                fillColor: Colors.blueGrey.shade900, // ✅ works now
                border: OutlineInputBorder(borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 12), // 👈 Tighten spacing
              ),
            ),
// 🆕 Add a non-editable display of the workout date
            // 🆕 Date displayed below, uneditable

            Padding(
              padding: const EdgeInsets.only(
                  left: 8.0, bottom: 7.0), // 👈 shifts it to the right
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  DateFormat('EEE d MMM yyyy').format(_selectedDate),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 0.0),
            Padding(
              padding: const EdgeInsets.only(
                  left: 5,
                  top: 0,
                  right: 5,
                  bottom: 0), // 🔥 Added cleaner side spacing
              child: Row(
                children: [
                  Flexible(
                    flex: 4,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text("Add Exercises",
                          style: TextStyle(fontSize: 14)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 8),
                      ),
                      onPressed: _showExercisePickerDialog,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    flex: 3,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 2, vertical: 8),
                      ),
                      onPressed: _showTemplateSelectionDialog,
                      child: const Text('Load Template',
                          style: TextStyle(
                              fontSize: 13,
                              fontFamily: 'Verdana',
                              color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    flex: 3,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 8),
                      ),
                      onPressed: () => _selectDate(context),
                      child: const Text('Select Date',
                          style: TextStyle(
                              fontFamily: 'Verdana', color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 4.0),
            if (_selectedExercisesWithCircuits.isEmpty)
              Column(
                children: [
                  Text(
                    'No exercises selected yet. Add some to get started.',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 6),
                ],
              )
            else
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorder: _onReorderExercises,
                children: List.generate(_selectedExercisesWithCircuits.length, (i) {
                  // 🛡 Defensive check for list mismatches
                  if (i >= _selectedExercisesWithCircuits.length ||
                      i >= _workoutSets.length ||
                      i >= _repsControllers.length ||
                      i >= _weightControllers.length ||
                      i >= _rirControllers.length) {
                    print("⚠️ Skipping index $i due to mismatched list lengths");
                    return  SizedBox(
                      key: ValueKey('skipped_$i'), // 🔑 Ensure even placeholder has a key
                    );
                  }

                  final current = _selectedExercisesWithCircuits[i];
                  final prev = i > 0 ? _selectedExercisesWithCircuits[i - 1] : null;
                  final isNewCircuit = i == 0 || current['circuitIndex'] != prev?['circuitIndex'];

                  return Column(
                    key: ValueKey("column_$i"), // 🔑 Required for ReorderableListView
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isNewCircuit)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                          child: Text(
                            'Circuit ${current['circuitIndex'] + 1}',
                            style: const TextStyle(
                              color: Colors.lightBlueAccent,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      Dismissible(
                        key: ValueKey(current['name']),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) {
                          final removedExercise =
                              _selectedExercisesWithCircuits[i];
                          final removedSets = _workoutSets[i];
                          final removedReps = _repsControllers[i];
                          final removedWeight = _weightControllers[i];
                          final removedRIR = _rirControllers[i];

                          setState(() {
                            _selectedExercisesWithCircuits.removeAt(i);
                            _workoutSets.removeAt(i);
                            _repsControllers.removeAt(i);
                            _weightControllers.removeAt(i);
                            _rirControllers.removeAt(i);
                          });

                          _lastUndoAction = () {
                            setState(() {
                              _selectedExercisesWithCircuits.insert(
                                  i, removedExercise);
                              _workoutSets.insert(i, removedSets);
                              _repsControllers.insert(i, removedReps);
                              _weightControllers.insert(i, removedWeight);
                              _rirControllers.insert(i, removedRIR);
                            });
                          };

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text('Deleted "${removedExercise['name']}"'),
                              action: SnackBarAction(
                                label: 'Undo',
                                textColor: Colors.blueGrey.shade700,
                                onPressed: () {
                                  _lastUndoAction?.call();
                                  _lastUndoAction = null;
                                },
                              ),
                            ),
                          );
                        },
    child: FutureBuilder<void>(
        future: _initialLoad, // ✅ Wait for full blockMeta + data load
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Padding(
          padding: EdgeInsets.all(8),
          child: SizedBox(
            height: 48,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        );
      }
      print("⏱️ [WES Row Delay] Delay complete for row $i — blockStartDate = $_blockStartDate");

      return Card(
        key: ValueKey("card_$i"),
        // 👈 Unique per exercise
        color: Colors.blueGrey.shade700,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(3),
        ),
        margin: const EdgeInsets.only(left: 0, top: 2, right: 0, bottom: 0),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 8),
          title: (_selectedExercisesWithCircuits[i]['name'] ?? '').isEmpty
              ? TextButton(
            onPressed: () => _showExercisePickerForRow(i),
            child: const Text(
              'Select Exercise',
              style: TextStyle(color: Colors.white70),
            ),
          )
              : Text(
            _selectedExercisesWithCircuits[i]['name'],
            style: TextStyle(
              color: Colors.grey.shade300,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [

              IconButton(
                icon: const Icon(Icons.info_outline),
                color: Colors.blueGrey,
                onPressed: () {
                  _navigateToExerciseDetails(
                      _selectedExercisesWithCircuits[i]['name'] ?? '');
                },
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey,
                ),
                onPressed: () {
                  _navigateToTopSets(
                      _selectedExercisesWithCircuits[i]['name'] ?? '');
                },
                child: Text(
                  'Top Sets',
                  style: TextStyle(
                    fontFamily: 'Verdana',
                    color: Colors.blueGrey.shade900,
                  ),
                ),
              ),
            ],
          ),
          children: [
            // 👇 Your set rows and other ExpansionTile children continue here

            // New row between selected exercise and workout sets:
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6.0, vertical: 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment
                    .end, // 👈 Pushes to the right
                children: [],
              ),
            ),

            for (int j = 0; j < _workoutSets[i].length; j++)
              Padding(
                padding: const EdgeInsets.only(
                    left: 6, bottom: 0, top: 0, right: 6),
                child: Column(
                  crossAxisAlignment:
                  CrossAxisAlignment.start,
                  children: [
                    if (j == 0) ...[
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 1),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisAlignment:
                            MainAxisAlignment
                                .spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment
                                .center, // ✅ Center vertically
                            children: [
                              // ➡️ Previous Rep Targets + Available Rep Targets (on the LEFT)
                              Column(
                                crossAxisAlignment:
                                CrossAxisAlignment.start,
                                children: [
                                  Text(
                                        () {
                                      final exerciseName =
                                          _selectedExercisesWithCircuits[
                                          i]
                                          ['name']
                                              ?.trim() ??
                                              '';
                                      final targetWeight = _isInitialized
                                          ? set1SuggestedWeight(i)
                                          : 20.0;

                                      final history =
                                          PeriodizationModelUtils
                                              .topSetsByExercise[
                                          exerciseName] ??
                                              [];

                                      final matchingSets = history
                                          .where((s) =>
                                      (s['weight']
                                      as double)
                                          .toStringAsFixed(
                                          1) ==
                                          targetWeight
                                              .toStringAsFixed(
                                              1))
                                          .toList();

                                      if (matchingSets
                                          .isEmpty)
                                        return 'No previous sets at ${targetWeight
                                            .toStringAsFixed(1)} kg';

                                      matchingSets
                                          .sort((a, b) {
                                        final repsA =
                                            a['reps'] ?? 0.0;
                                        final repsB =
                                            b['reps'] ?? 0.0;
                                        final rirA =
                                            a['rir'] ?? 99.0;
                                        final rirB =
                                            b['rir'] ?? 99.0;

                                        if (repsB.compareTo(
                                            repsA) !=
                                            0)
                                          return repsB
                                              .compareTo(
                                              repsA);
                                        return rirA
                                            .compareTo(rirB);
                                      });

                                      final best =
                                          matchingSets.first;
                                      final reps =
                                      best['reps'];
                                      final rir = best['rir'];

                                      return 'Best at ${targetWeight
                                          .toStringAsFixed(
                                          1)} kg: $reps reps @ RIR $rir';
                                    }(),
                                    style: const TextStyle(
                                      fontSize: 10.0,
                                      fontWeight:
                                      FontWeight.bold,
                                      color: Colors.white24,
                                    ),
                                  ),
                                  const SizedBox(height: 0),
                                  Builder(
                                    builder: (context) {
                                      if (!_isInitialized) {
                                        return const Text(
                                          'Loading...',
                                          style: TextStyle(
                                            fontSize: 10.0,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white54,
                                          ),
                                        );
                                      }

                                      final exerciseName = _selectedExercisesWithCircuits[i]['name']
                                          ?.trim() ?? '';
                                      final repTarget = set1SuggestedReps(
                                          i); // no `.round()` yet

                                      if (repTarget == null) {
                                        return const Text(
                                          'Loading...',
                                          style: TextStyle(
                                            fontSize: 10.0,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white54,
                                          ),
                                        );
                                      }

                                      final roundedTarget = repTarget.round();
                                      final history = PeriodizationModelUtils
                                          .topSetsByExercise[exerciseName] ??
                                          [];

                                      final matchingSets = history.where((s) {
                                        final reps = (s['reps'] as num?)
                                            ?.round();
                                        return reps == repTarget;
                                      }).toList();

                                      if (matchingSets.isEmpty) {
                                        return Text(
                                          'No previous sets at $repTarget reps',
                                          style: const TextStyle(
                                            fontSize: 10.0,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white54,
                                          ),
                                        );
                                      }

                                      matchingSets.sort((a, b) {
                                        final wa = a['weight'] ?? 0.0;
                                        final wb = b['weight'] ?? 0.0;
                                        return (wb as num).compareTo(wa as num);
                                      });

                                      final best = matchingSets.first;
                                      final weight = best['weight'];
                                      final rir = best['rir'];

                                      return Text(
                                        'Best at $repTarget reps: ${weight
                                            .toStringAsFixed(1)} kg @ RIR ${rir
                                            .toString()}',
                                        style: const TextStyle(
                                          fontSize: 10.0,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white54,
                                        ),
                                      );
                                    },

                                  ),
                                ],
                              ),

                              const SizedBox(
                                  width:
                                  12),
                              // ✅ Optional spacing between sections

                              // ➡️ Avg E1RM (on the RIGHT)
                              Text(
                                'Avg E1RM: ${getAverageE1RM(
                                    _selectedExercisesWithCircuits[i]['name'] ??
                                        '').toStringAsFixed(1)}Kg',
                                style: const TextStyle(
                                  fontSize: 12.0,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueGrey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 1),
                    ],

                    SizedBox(
                      height:
                      25,
                      // or 26, or 28 (experiment to see what feels tight but readable)
                      child: Row(
                        mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                        crossAxisAlignment:
                        CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 4, top: 5),
                            child: Text(
                              'Set ${j + 1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12.0,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          Container(
                            padding:
                            const EdgeInsets.only(top: 2),
                            child: IconButton(
                              icon: const Icon(Icons.remove),
                              iconSize: 18,
                              padding: EdgeInsets.zero,
                              constraints:
                              const BoxConstraints(),
                              onPressed: () =>
                                  removeSet(i, j),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ✅ Header Row with aligned labels
                    SingleChildScrollView(
                      controller: _horizontalScrollController,
                      scrollDirection: Axis.horizontal,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 🟨 Header Row (per exercise row)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(
                                width: 68,
                                child: Padding(
                                  padding: EdgeInsets.only(left: 3),
                                  child: Text('Weight', style: _headerStyle),
                                ),
                              ),
                              const SizedBox(width: 4),

                              const SizedBox(
                                width: 50,
                                child: Padding(
                                  padding: EdgeInsets.only(left: 2),
                                  child: Text('Reps', style: _headerStyle),
                                ),
                              ),
                              const SizedBox(width: 4),

                              const SizedBox(
                                width: 50,
                                child: Padding(
                                  padding: EdgeInsets.only(left: 3),
                                  child: Text('RIR', style: _headerStyle),
                                ),
                              ),
                              const SizedBox(width: 4),



                              const SizedBox(width: 55, child: Text('E1RM', style: _headerStyle)),
                              const SizedBox(width: 4),

                              // ✅ Conditionally include Velocity (for this exercise only)
                              if (_showVelocityByExercise[
                              (_selectedExercisesWithCircuits[i]['name'] as String).toLowerCase()] ==
                                  true) ...[
                                const SizedBox(width: 45, child: Text('Vel.', style: _headerStyle)),
                                const SizedBox(width: 4),
                              ],
                              const SizedBox(width: 120, child: Text('Notes', style: _headerStyle)),
                            ],
                          ),



                          const SizedBox(height: 2),

                          // 🟩 Input Row
                          Row(
                            children: [
                              // Weight
                              SizedBox(
                                width: 68,
                                child: TextField(
                                  controller: _weightControllers[i][j],
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    hintText: !_isInitialized
                                        ? ''
                                        : (j == 0)
                                        ? set1SuggestedWeight(i).toStringAsFixed(1)
                                        : (j == 1)
                                        ? set2SuggestedWeight(i).toStringAsFixed(1)
                                        : (j == 2)
                                        ? set3SuggestedWeight(i).toStringAsFixed(1)
                                        : '20',
                                    hintStyle: const TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                    contentPadding: const EdgeInsets.only(left: 4),
                                  ),
                                  onChanged: (value) => setState(() {}),
                                  style: TextStyle(
                                    color: _weightControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),

                              // Reps
                              SizedBox(
                                width: 50,
                                child: TextField(
                                  controller: _repsControllers[i][j],
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.only(left: 3),
                                    hintText: (_isLoadingData || !_isInitialized)
                                        ? ''
                                        : (j == 0)
                                        ? (set1SuggestedReps(i)?.toInt().toString() ?? '')
                                        : (j == 1)
                                        ? (set2SuggestedReps(i)?.toInt().toString() ?? '')
                                        : (j == 2)
                                        ? (set3SuggestedReps(i)?.toInt().toString() ?? '')
                                        : '15',
                                    hintStyle: const TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onChanged: (value) => setState(() {}),
                                  style: TextStyle(
                                    color: _repsControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),

                              // RIR
                              SizedBox(
                                width: 50,
                                child: TextField(
                                  controller: _rirControllers[i][j],
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    contentPadding: const EdgeInsets.only(left: 2),
                                    hintText: (j == 0)
                                        ? set1RIR(i).toString()
                                        : (j == 1)
                                        ? set2RIR(i).toString()
                                        : (j == 2)
                                        ? set3RIR(i).toString()
                                        : '1',
                                    hintStyle: const TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onChanged: (value) => setState(() {}),
                                  style: TextStyle(
                                    color: _rirControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),



                              // E1RM
                              SizedBox(
                                width: 55,
                                child: TextField(
                                  controller: TextEditingController(
                                    text: calculateE1RM(
                                        double.tryParse(_weightControllers[i][j].text) ??
                                            (j == 0
                                                ? (_isInitialized ? set1SuggestedWeight(i) : 20.0)
                                                : j == 1
                                                ? (_isInitialized ? set2SuggestedWeight(i) : 20.0)
                                                : (_isInitialized ? set3SuggestedWeight(i) : 20.0)),
                                        (int.tryParse(_repsControllers[i][j].text) ??
                                            (j == 0
                                                ? (_isInitialized ? set1SuggestedReps(i).toDouble() : 15.0)
                                                : j == 1
                                                ? (_isInitialized ? set2SuggestedReps(i).toDouble() : 10.0)
                                                : (_isInitialized ? set3SuggestedReps(i).toDouble() : 10.0)))
                                            .toDouble(),
                                        double.tryParse(_rirControllers[i][j].text) ??
                                            (j == 0
                                                ? (_isInitialized ? set1RIR(i) : 0.5)
                                                : j == 1
                                                ? (_isInitialized ? set2RIR(i) : 0.5)
                                                : (_isInitialized ? set3RIR(i) : 0.5)))
                                        .toStringAsFixed(1),
                                  ),
                                  enabled: false,
                                  readOnly: true,
                                  decoration: const InputDecoration(
                                    hintText: '',
                                    hintStyle: TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                    contentPadding: EdgeInsets.only(left: 4),
                                    enabledBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(color: Colors.white, width: 1),
                                    ),
                                    disabledBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(color: Colors.white, width: 1),
                                    ),
                                    focusedBorder: UnderlineInputBorder(
                                      borderSide: BorderSide(color: Colors.white, width: 1.5),
                                    ),
                                  ),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: (_weightControllers[i][j].text.isNotEmpty ||
                                        _repsControllers[i][j].text.isNotEmpty ||
                                        _rirControllers[i][j].text.isNotEmpty)
                                        ? Colors.white
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),

                              // ✅ Conditionally show Velocity
                              if (_showVelocityByExercise[
                              (_selectedExercisesWithCircuits[i]['name'] as String).toLowerCase()] ==
                                  true) ...[
                                SizedBox(
                                  width: 45,
                                  child: TextField(
                                    controller: _velocityControllers[i][j],
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      hintText: '',
                                      hintStyle: TextStyle(
                                        color: Colors.grey,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 11,
                                      ),
                                    ),
                                    onChanged: (value) => setState(() {}),
                                    style: TextStyle(
                                      color: _velocityControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                              ],

                              // Notes
                              SizedBox(
                                width: 120,
                                child: TextField(
                                  controller: _notesControllers[i][j],
                                  keyboardType: TextInputType.text,
                                  decoration: const InputDecoration(
                                    hintText: '',
                                    hintStyle: TextStyle(
                                      color: Colors.grey,
                                      fontStyle: FontStyle.italic,
                                      fontSize: 12,
                                    ),
                                  ),
                                  onChanged: (value) => setState(() {}),
                                  style: TextStyle(
                                    color: _notesControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          )

                        ],
                      ),
                    ),


                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(Icons.add),
                onPressed: () => addSet(i),
              ),
            ),
          ], //paste point
        ),

      );
       //old bracket for Card
    }),
    )],
                  );
                }),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: _addNewCircuitExercise,
                  icon: const Icon(Icons.add),
                  label: const Text("Add Circuit"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    });
  }
}
