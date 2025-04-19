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



class WorkoutPage extends StatefulWidget {
  final Template? initialTemplate;
  final Workout? workout; // Make workout optional
  final bool isNewWorkout;
  final List<String>? prefilledExercises;
  final DateTime? initialDate; // ✅ Add this line
  final String? initialWorkoutName; // ✅ Add this

  const WorkoutPage({
    Key? key,
    this.initialTemplate,
    this.workout,
    this.isNewWorkout = true,
    this.prefilledExercises,
    this.initialDate,
    this.initialWorkoutName, // ✅ Add this
  }) : super(key: key);


  @override
  _WorkoutPageState createState() => _WorkoutPageState();
}

class _WorkoutPageState extends State<WorkoutPage> {
  List<String> exercises = []; // Use this to store selected exercises from the dialog
  final TextEditingController _workoutNameController = TextEditingController();
  late DateTime _selectedDate; // move this to the top of the State class
  final List<String> _selectedExercises = [];
  List<String> plannedExercises = [];
  final List<List<SetDetails>> _workoutSets = [];
  final List<List<TextEditingController>> _repsControllers = [];
  final List<List<TextEditingController>> _weightControllers = [];
  final List<List<TextEditingController>> _rirControllers =
  []; // New controller list for RIR
  final int _defaultSets = 3;
  VoidCallback? _lastUndoAction;


  bool _isLoadingData = true; // Tracks whether data is still loading

  Future<void> loadPreviousWorkoutData() async {
    await PeriodizationModelUtils.fetchLastWorkoutTopSetReps();
    setState(() {
      _isLoadingData = false; // ✅ Data has been fetched, UI can update
    });
  }

  Future<void> loadPlannedExercisesFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block')
        .get();

    if (doc.exists) {
      final data = doc.data();
      if (data != null && data['plannedExercises'] != null) {
        setState(() {
          plannedExercises = List<String>.from(data['plannedExercises']);
        });
      }
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
    if (value is String) return double.tryParse(value) ?? 0; // ✅ Convert String to double
    return 0; // ✅ Default case
  }

  final TextEditingController _mirroredRepsController = TextEditingController();


  //Determine available rep targets for this workout:

  Map<String, List<double>> exercisePreviousE1RMs = {}; // ✅ E1RM history per exercise

  Map<String, List<int>> exercisePreviousTopSetReps = {}; // ✅ Tracks reps per exercise


  double getAverageE1RM(String exerciseName) {
    if (!PeriodizationModelUtils.exercisePreviousE1RMs.containsKey(exerciseName) ||
        PeriodizationModelUtils.exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      return 0.0; // ✅ Default if no history
    }

    List<double> recentE1RMs = PeriodizationModelUtils.exercisePreviousE1RMs[exerciseName]!.take(4).toList();
    return recentE1RMs.reduce((a, b) => a + b) / recentE1RMs.length;
  }


  double getSet2E1RM(int exerciseIndex) {
    String exerciseName = _selectedExercises[exerciseIndex]; // ✅ Get exerciseName

    double set1Weight = double.tryParse(_weightControllers[exerciseIndex][0].text) ?? set1SuggestedWeight(exerciseIndex);
    int set1Reps = int.tryParse(_repsControllers[exerciseIndex][0].text) ?? set1SuggestedReps(exerciseIndex).toInt();
    double set1RIRValue = double.tryParse(_rirControllers[exerciseIndex][0].text) ?? set1RIR(exerciseIndex);
    double set1EffectiveReps = set1Reps + set1RIRValue;

    double set1E1RM = (set1EffectiveReps <= 6)
        ? (set1Weight * (36 / (37 - set1EffectiveReps))) // Brzycki for low reps
        : (set1Weight * (1 + (0.0333 * set1EffectiveReps))); // Epley for high reps

    print("Set 2 E1RM for $exerciseName: ${set1E1RM.toStringAsFixed(1)}"); // ✅ Debugging
    return (set1E1RM > 7) ? (set1E1RM - 7) : 1.0;
  }

  double getSet3E1RM(int exerciseIndex) {
    String exerciseName = _selectedExercises[exerciseIndex]; // ✅ Get exerciseName

    double set1Weight = double.tryParse(_weightControllers[exerciseIndex][0].text) ?? set1SuggestedWeight(exerciseIndex);
    int set1Reps = int.tryParse(_repsControllers[exerciseIndex][0].text) ?? set1SuggestedReps(exerciseIndex).toInt();
    double set1RIRValue = double.tryParse(_rirControllers[exerciseIndex][0].text) ?? set1RIR(exerciseIndex);
    double set1EffectiveReps = set1Reps + set1RIRValue;

    double set1E1RM = (set1EffectiveReps <= 6)
        ? (set1Weight * (36 / (37 - set1EffectiveReps))) // Brzycki for low reps
        : (set1Weight * (1 + (0.0333 * set1EffectiveReps))); // Epley for high reps

    return (set1E1RM > 7) ? (set1E1RM - 10.5) : 1.0;
  }


  Future<void> _fetchLastWorkoutTopSetReps() async {
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
      setState(() {
        exercisePreviousTopSetReps.clear(); // ✅ Reset reps per exercise
        exercisePreviousE1RMs.clear(); // ✅ Reset E1RMs per exercise

        for (var doc in snapshot.docs) {
          final workout = Workout.fromFirestore(doc);

          if (workout.exercises.isNotEmpty) {
            for (var exercise in workout.exercises) {
              String exerciseName = exercise.name; // ✅ Exercise-specific tracking

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
                int effectiveReps = (_parseToDouble(topSet.reps) + _parseToDouble(topSet.rir)).floor();

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
                      exercisePreviousTopSetReps[exerciseName]!.take(12).toList();
                }
              }
            }
          }
        }
      });
    }
  }


  List<int> getForbiddenRepTargets(String exerciseName, int setIndex) {
    List<int>? pastReps = exercisePreviousTopSetReps[exerciseName]; // ✅ Now exerciseName is defined
    if (pastReps == null) return []; // ✅ Handle missing data


    Set<int> forbiddenReps = {};

    for (int i = 0; i < pastReps.length; i++) {
      int effectiveRep = pastReps[i]; // ✅ Now includes RIR (already adjusted in _lastWorkoutTopSetReps)

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


  List<int> _getAvailableRepTargets(int exerciseIndex, int setIndex) {
    int enteredReps = int.tryParse(_repsControllers[exerciseIndex][setIndex].text) ?? 0;
    double enteredRIR = double.tryParse(_rirControllers[exerciseIndex][setIndex].text) ?? 0.0;
    int effectiveReps = (enteredReps + enteredRIR).floor(); // ✅ Effective reps include RIR

    // ✅ Ensure max available reps do not exceed 12
    String exerciseName = _selectedExercises[exerciseIndex]; // ✅ Get the exercise name
    List<int> allReps = List.generate(12, (index) => index + 1);
    List<int> forbiddenReps = getForbiddenRepTargets(exerciseName, setIndex); // ✅ Now passing the correct name

    // ✅ Get available reps by filtering out forbidden ones
    List<int> availableReps = allReps.where((rep) => !forbiddenReps.contains(rep)).toList();

    // ✅ Sort available reps so the most distant target is first (i.e., least recently used)
      List<int>? pastReps = exercisePreviousTopSetReps[exerciseName]; // ✅ Get past reps for this exercise

    if (pastReps != null) {
      availableReps.sort((a, b) => pastReps.contains(a) ? 1 : -1); // ✅ Sort based on exercise history
    }


    return availableReps;
  }


  int getSuggestedRepTarget(int exerciseIndex, int setIndex, {double? weight}) {
    String exerciseName = _selectedExercises[exerciseIndex];

    // 🔢 Count how many times this exercise appears before the current set
    int plannedCountBefore = 0;
    for (int i = 0; i < setIndex; i++) {
      if (_selectedExercises[i] == exerciseName) {
        plannedCountBefore++;
      }
    }

    return PeriodizationModelUtils.getSuggestedRepTarget(
      exerciseName,
      plannedIndex: plannedCountBefore,
    );
  }




  //Determine hint texts for this workout:NEW METHOD

  double set1SuggestedReps(int exerciseIndex) {
    String exerciseName = _selectedExercises[exerciseIndex]; // ✅ Get exercise name
    List<double>? pastE1RMs = exercisePreviousE1RMs[exerciseName]; // ✅ Get E1RMs for this exercise

    if (pastE1RMs == null || pastE1RMs.isEmpty) {
      return 6.0; // ✅ Default reps if no history for this exercise
    }


    // ✅ Check if user has entered a weight
    bool hasUserWeightInput = _weightControllers[exerciseIndex][0].text.isNotEmpty;

    if (hasUserWeightInput) {
      // ✅ Get the average E1RM
      String exerciseName = _selectedExercises[exerciseIndex]; // ✅ Get the exercise name
      double avgE1RM = getAverageE1RM(exerciseName); // ✅ Pass exercise name to get its average E1RM


      // ✅ Get the newly entered weight
      double weight = double.tryParse(_weightControllers[exerciseIndex][0].text) ?? 0.0;

      // ✅ Ensure weight is valid
      if (weight <= 0 || avgE1RM <= weight) {

        return 1.0; // ✅ If weight is too high, return 1 rep
      }

      // ✅ Reverse Brzycki formula to calculate reps
      double rawReps = (weight / avgE1RM < 0.85)
          ? ((avgE1RM / weight) - 1) / 0.0333  // Epley formula for higher reps
          : (37 - ((weight * 36) / avgE1RM));  // Brzycki formula for lower reps

      // ✅ Get the current RIR (user input or default)
      double rir = double.tryParse(_rirControllers[exerciseIndex][0].text) ?? set1RIR(exerciseIndex);

      // ✅ Subtract RIR from the calculated reps
      double finalReps = (rawReps - rir);
      double decimalPart = finalReps - finalReps.floor();

      if (decimalPart >= 0.652) { // 1 - 0.098 = 0.902
        finalReps = finalReps.ceil().toDouble();
      } else {
        finalReps = finalReps.floor().toDouble();
      }

      return finalReps.clamp(1.0, 200.0); // ✅ Ensure reps are between 1 and 200
    }

    // ✅ Otherwise, return suggested rep target
    return PeriodizationModelUtils.upcomingRepTargetSequence(exerciseName, 1).first.toDouble();
  }


  double set2SuggestedReps(int exerciseIndex) {
    // ✅ Get Set 2's E1RM using the function
    double set2E1RM = getSet2E1RM(exerciseIndex);

    // ✅ Get Set 1 reps from UI or default to suggested
    double set1Reps = double.tryParse(_repsControllers[exerciseIndex][0].text) ?? set1SuggestedReps(exerciseIndex).toDouble();

    // ✅ Determine whether user has entered weight for Set 2
    bool hasUserWeightInput = _weightControllers[exerciseIndex][1].text.isNotEmpty;

    if (!hasUserWeightInput) {
      // ✅ Default behavior: use Set 1 reps - 1
      return (set1Reps - 1).clamp(1, 200);
    }

    // ✅ Get Set 2 weight from user input
    double weight = double.tryParse(_weightControllers[exerciseIndex][1].text) ?? 0.0;

    // ✅ Ensure weight is valid
    if (weight <= 0 || set2E1RM <= weight) {

      return 1; // ✅ If weight is too high, or below 0, return 1 rep
    }

    // ✅ Reverse Hybrid formula to calculate reps
    double rawReps = (weight / set2E1RM < 0.85)
        ? ((set2E1RM / weight) - 1) / 0.0333  // Epley formula for higher reps
        : (37 - ((weight * 36) / set2E1RM));  // Brzycki formula for lower reps

    // ✅ Get Set 2 RIR from UI
    double rir = double.tryParse(_rirControllers[exerciseIndex][1].text) ?? set2RIR(exerciseIndex);

    // ✅ Subtract RIR from the calculated reps
    double finalReps = (rawReps - rir);
    double decimalPart = finalReps - finalReps.floor();

    if (decimalPart >= 0.652) { // 1 - 0.198 = 0.802
      finalReps = finalReps.ceil().toDouble();
    } else {
      finalReps = finalReps.floor().toDouble();
    }

    return finalReps.clamp(1.0, 200.0); // ✅ Ensure reps are between 1 and 200
  }


  double set3SuggestedReps(int exerciseIndex) {
    // ✅ Get Set 1's E1RM using hint text or user input
    double set3E1RM = getSet3E1RM(exerciseIndex);

    double set2Reps = double.tryParse(_repsControllers[exerciseIndex][1].text) ?? set2SuggestedReps(exerciseIndex).toDouble();

    // ✅ Determine whether user has entered weight for Set 3
    bool hasUserWeightInput = _weightControllers[exerciseIndex][2].text.isNotEmpty;

    if (!hasUserWeightInput) {
      // ✅ Default behavior: use Set 2 reps - 1
      return (set2Reps - 1).clamp(1, 200);
    }

    // ✅ Get Set 2 weight from user input
    double weight = double.tryParse(_weightControllers[exerciseIndex][2].text) ?? 0.0;

    // ✅ Ensure weight is valid
    if (weight <= 0 || set3E1RM <= weight) {

      return 1; // ✅ If weight is too high, or below 0, return 1 rep
    }

    // ✅ Reverse Hybrid formula to calculate reps
    double rawReps = (weight / set3E1RM < 0.85)
        ? ((set3E1RM / weight) - 1) / 0.0333  // Epley formula for higher reps
        : (37 - ((weight * 36) / set3E1RM));  // Brzycki formula for lower reps

    // ✅ Get Set 3 RIR from UI
    double rir = double.tryParse(_rirControllers[exerciseIndex][2].text) ?? set2RIR(exerciseIndex);

    // ✅ Subtract RIR from the calculated reps
    double finalReps = (rawReps - rir);
    double decimalPart = finalReps - finalReps.floor();

    if (decimalPart >= 0.652) { // 1 - 0.198 = 0.802
      finalReps = finalReps.ceil().toDouble();
    } else {
      finalReps = finalReps.floor().toDouble();
    }

    return finalReps.clamp(1.0, 200.0); // ✅ Ensure reps are between 1 and 200
  }


  // ✅ Function to determine RIR for Set 1 (Default: 0.5, Modifiable in Future)
  double set1RIR(int exerciseIndex) {
    if (_rirControllers[exerciseIndex][0].text.isNotEmpty) {
      return double.tryParse(_rirControllers[exerciseIndex][0].text) ?? 0.5;
    }
    return 0.5; // Default RIR for Set 1
  }

// ✅ Function to determine RIR for Set 2 (Default: 1.5, Modifiable in Future)
  double set2RIR(int exerciseIndex) {
    if (_rirControllers[exerciseIndex][1].text.isNotEmpty) {
      return double.tryParse(_rirControllers[exerciseIndex][1].text) ?? 1.5;
    }
    return 1.5; // Default RIR for Set 2
  }

// ✅ Function to determine RIR for Set 3 (Default: 2.5, Modifiable in Future)
  double set3RIR(int exerciseIndex) {
    if (_rirControllers[exerciseIndex][2].text.isNotEmpty) {
      return double.tryParse(_rirControllers[exerciseIndex][2].text) ?? 2.5;
    }
    return 2.5; // Default RIR for Set 3
  }



  double set1SuggestedWeight(int exerciseIndex) {
    if (exercisePreviousE1RMs.isEmpty) return 20.0; // Default weight if no history

    // ✅ Get the last average of last 4 E1RMs (or fewer if not available)
    double avgE1RM = getAverageE1RM(_selectedExercises[exerciseIndex]); // ✅ FIXED


    // ✅ Get reps and RIR from UI or use default values
    int reps = int.tryParse(_repsControllers[exerciseIndex][0].text) ?? set1SuggestedReps(exerciseIndex).toInt();
    double rir = double.tryParse(_rirControllers[exerciseIndex][0].text) ?? set1RIR(exerciseIndex);
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      // ✅ Use Brzycki formula for lower rep ranges
      suggestedWeight = avgE1RM * (37 - effectiveReps) / 36;
    } else {
      // ✅ Use Epley formula for higher rep ranges
      suggestedWeight = avgE1RM / (1 + (0.0333 * effectiveReps));
    }

    // ✅ Prevent negative suggested weight
    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);

    // ✅ Round to the nearest 2.5kg increment
    return (suggestedWeight / 2.5).round() * 2.5;
  }

  double set2SuggestedWeight(int exerciseIndex) {
    if (exercisePreviousE1RMs.isEmpty) return 20.0; // Default weight if no history

    // ✅ Get Set 2's E1RM using the function
    double set2E1RM = getSet2E1RM(exerciseIndex);

    // ✅ Use Set 2 reps and RIR for weight calculation
    double reps = double.tryParse(_repsControllers[exerciseIndex][1].text) ?? set2SuggestedReps(exerciseIndex);
    double rir = double.tryParse(_rirControllers[exerciseIndex][1].text) ?? set2RIR(exerciseIndex);
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      // ✅ Use Brzycki formula for lower rep ranges
      suggestedWeight = set2E1RM * (37 - effectiveReps) / 36;
    } else {
      // ✅ Use Epley formula for higher rep ranges
      suggestedWeight = set2E1RM / (1 + (0.0333 * effectiveReps));
    }

    // ✅ Prevent negative suggested weight
    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);

    // ✅ Round to the nearest 2.5kg increment
    return (suggestedWeight / 2.5).round() * 2.5;
  }

  double set3SuggestedWeight(int exerciseIndex) {
    if (exercisePreviousE1RMs.isEmpty) return 20.0; // Default weight if no history

    double set3E1RM = getSet3E1RM(exerciseIndex);

    // ✅ Use Set 3 reps and RIR for weight calculation
    double reps = double.tryParse(_repsControllers[exerciseIndex][2].text) ?? set3SuggestedReps(exerciseIndex);
    double rir = double.tryParse(_rirControllers[exerciseIndex][2].text) ?? set3RIR(exerciseIndex);
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      // ✅ Use Brzycki formula for lower rep ranges
      suggestedWeight = set3E1RM * (37 - effectiveReps) / 36;
    } else {
      // ✅ Use Epley formula for higher rep ranges
      suggestedWeight = set3E1RM / (1 + (0.0333 * effectiveReps));
    }

    // ✅ Prevent negative suggested weight
    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);

    // ✅ Round to the nearest 2.5kg increment
    return (suggestedWeight / 2.5).round() * 2.5;
  }



  @override
  void initState() {
    super.initState();

    _selectedDate = widget.initialDate ?? DateTime.now();

    // ✅ Set the workout name first, before any template/workout logic can override it
    if (widget.initialWorkoutName != null) {
      _workoutNameController.text = widget.initialWorkoutName!;
    }

    loadPlannedExercisesFromFirestore(); // 🔥 Add this line
    loadPreviousWorkoutData(); // ✅ Ensures data is fetched before UI load

    if (widget.prefilledExercises != null) {
      // ✅ Initialize based on prefilled exercises
      _selectedExercises.addAll(widget.prefilledExercises!);
      for (int i = 0; i < _selectedExercises.length; i++) {
        _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
        _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      }
    } else if (widget.workout != null) {
      _loadWorkout(widget.workout!);
    } else if (widget.initialTemplate != null) {
      _loadTemplate(widget.initialTemplate!);
    } else {
      _initializeControllers();
    }

    _fetchLastWorkoutTopSetReps();
  }



  void _loadWorkout(Workout workout) {
    _workoutNameController.text = workout.name;
    _selectedDate = workout.date;
    _selectedExercises.clear();
    _selectedExercises.addAll(workout.exercises.map((exercise) => exercise.name));

    _workoutSets.clear();
    _workoutSets.addAll(
      workout.exercises.map((exercise) {
        return exercise.sets.map((set) => SetDetails(
          reps: set.reps,    // ✅ Now allows null
          weight: set.weight,
          rir: set.rir,
        )).toList();
      }).toList(),
    );

    _initializeControllers();
  }

  void _loadTemplate(Template template) {
    setState(() {
      _workoutNameController.text = template.name;
      _selectedExercises.clear();
      _workoutSets.clear();

      _selectedExercises.addAll(template.exercises);
      _workoutSets.addAll(List.generate(
        _selectedExercises.length,
            (index) => List.generate(
          _defaultSets,
              (setIndex) => SetDetails(
            reps: null,  // ✅ Now null instead of placeholder
            weight: null,
            rir: null,
          ),
        ),
      ));
      _initializeControllers();
    });
  }


  @override
  void dispose() {
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
    super.dispose();
  }


  void _initializeControllers() {
    // ✅ Ensure controller lists are at least as long as _selectedExercises
    while (_repsControllers.length < _selectedExercises.length) {
      _repsControllers.add([]);
    }
    while (_weightControllers.length < _selectedExercises.length) {
      _weightControllers.add([]);
    }
    while (_rirControllers.length < _selectedExercises.length) {
      _rirControllers.add([]);
    }

    for (int i = 0; i < _selectedExercises.length; i++) {
      List<SetDetails> sets = _workoutSets[i];

      // ✅ Only add controllers if they don't already exist (to keep user-entered data)
      if (_repsControllers[i].isEmpty) {
        _repsControllers[i] = sets.map((set) {
          return TextEditingController(text: set.reps?.toString() ?? '');
        }).toList();
      }

      if (_weightControllers[i].isEmpty) {
        _weightControllers[i] = sets.map((set) {
          return TextEditingController(text: set.weight != null ? set.weight!.toStringAsFixed(1) : '');
        }).toList();
      }

      if (_rirControllers[i].isEmpty) {
        _rirControllers[i] = sets.map((set) {
          return TextEditingController(text: set.rir != null ? set.rir!.toStringAsFixed(1) : '');
        }).toList();
      }
    }
  }

  void _navigateToTemplateSelection() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const TemplatesScreen(fromWorkoutPage: true),
      ),
    ).then((selectedTemplate) {
      if (selectedTemplate != null && selectedTemplate is Template) {
        _loadTemplate(selectedTemplate);
      }
    });
  }

  void _showExercisePickerDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs.map((doc) => {
      'name': doc['name'] as String,
      'category': doc['category'] as String,
    }).toList();

    bool showPlannedOnly = true;
    final Map<String, bool> expandedGroups = {}; // ✅ Moved outside StatefulBuilder

    final List<String> selected = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        List<String> tempSelected = [..._selectedExercises];

        return StatefulBuilder(builder: (context, setLocalState) {
          final filteredExercises = showPlannedOnly
              ? allExercises.where((ex) => plannedExercises.contains(ex['name'])).toList()
              : allExercises;

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

          // ✅ Only initialize new entries without overwriting toggled states
          for (final category in orderedGrouped.keys) {
            expandedGroups.putIfAbsent(category, () => false);
          }

          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Select Exercises", style: TextStyle(fontSize: 13, color: Colors.white)),
                Row(
                  children: [
                    const Text("Planned Only", style: TextStyle(fontSize: 12, color: Colors.white70)),
                    Switch(
                      value: showPlannedOnly,
                      onChanged: (value) => setLocalState(() => showPlannedOnly = value),
                      activeColor: Colors.lightBlueAccent,
                    ),
                  ],
                ),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                children: orderedGrouped.entries.map((entry) {
                  final category = entry.key;
                  final exercises = entry.value;
                  final isExpanded = expandedGroups[category] ?? false;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        tileColor: Colors.blueGrey.shade800,
                        title: Text(category, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        trailing: Icon(
                          isExpanded ? Icons.expand_less : Icons.expand_more,
                          color: Colors.white70,
                        ),
                        onTap: () {
                          setLocalState(() {
                            expandedGroups[category] = !isExpanded;
                          });
                        },
                      ),
                      if (isExpanded)
                        ...exercises.map((name) {
                          final isChecked = tempSelected.contains(name);
                          return CheckboxListTile(
                            value: isChecked,
                            title: Text(name, style: const TextStyle(color: Colors.white)),
                            controlAffinity: ListTileControlAffinity.leading,
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
                      const Divider(height: 10, color: Colors.grey),
                    ],
                  );
                }).toList(),
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
    ) ?? [];

    setState(() {
      _selectedExercises.clear();
      _selectedExercises.addAll(selected);

      _workoutSets.clear();
      _workoutSets.addAll(
        List.generate(
          _selectedExercises.length,
              (_) => List.generate(_defaultSets, (_) => SetDetails()),
        ),
      );

      _initializeControllers();
    });
  }



  void _onReorderExercises(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;

      final movedExercise = _selectedExercises.removeAt(oldIndex);
      final movedSets = _workoutSets.removeAt(oldIndex);
      final movedReps = _repsControllers.removeAt(oldIndex);
      final movedWeight = _weightControllers.removeAt(oldIndex);
      final movedRir = _rirControllers.removeAt(oldIndex);

      _selectedExercises.insert(newIndex, movedExercise);
      _workoutSets.insert(newIndex, movedSets);
      _repsControllers.insert(newIndex, movedReps);
      _weightControllers.insert(newIndex, movedWeight);
      _rirControllers.insert(newIndex, movedRir);
    });
  }




  void _navigateToExerciseSelection() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExerciseSelectionScreen(
          selectedExercises: _selectedExercises,
        ),
      ),
    ).then((selectedExercises) {
      if (selectedExercises != null && selectedExercises is List<String>) {
        setState(() {
          _selectedExercises.clear();
          _selectedExercises.addAll(selectedExercises);

          _workoutSets.clear();
          _workoutSets.addAll(
            List.generate(
              _selectedExercises.length,
                  (index) => List.generate(
                _defaultSets,
                    (setIndex) => SetDetails(
                  reps: null,  // ✅ Now using null instead of placeholder
                  weight: null,
                  rir: null,
                ),
              ),
            ),
          );

          _initializeControllers();
        });
      }
    });
  }


  Future<void> _saveWorkout() async {
    if (_workoutNameController.text.isEmpty || _selectedExercises.isEmpty) {
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

    // ✅ Sync TextField input into _workoutSets
    for (int i = 0; i < _selectedExercises.length; i++) {
      for (int j = 0; j < _workoutSets[i].length; j++) {
        final repsText = _repsControllers[i][j].text.trim();
        final weightText = _weightControllers[i][j].text.trim();
        final rirText = _rirControllers[i][j].text.trim();

        _workoutSets[i][j].reps = repsText.isNotEmpty ? int.tryParse(repsText) : null;
        _workoutSets[i][j].weight = weightText.isNotEmpty ? double.tryParse(weightText) : null;
        _workoutSets[i][j].rir = rirText.isNotEmpty ? double.tryParse(rirText) : null;
      }
    }

    // ✅ Create Firestore save payload
    final workoutData = {
      'name': _workoutNameController.text,
      'date': _selectedDate.toIso8601String(),
      'userId': user.uid,
      'exercises': _selectedExercises.asMap().entries.map((exerciseEntry) {
        int exerciseIndex = exerciseEntry.key;
        String exerciseName = exerciseEntry.value;

        List<Map<String, dynamic>> validSets = [];

        for (int setIndex = 0; setIndex < _workoutSets[exerciseIndex].length; setIndex++) {
          final set = _workoutSets[exerciseIndex][setIndex];
          final weight = set.weight ?? 0.0;

          if (weight > 0) {
            validSets.add({
              'exerciseName': exerciseName,
              'reps': set.reps ?? 0,
              'weight': weight,
              'rir': set.rir ?? 0.0,
            });
          }
        }

        return validSets.isNotEmpty
            ? {
          'name': exerciseName,
          'sets': validSets,
        }
            : null;
      }).where((e) => e != null).toList(),
    };

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('workouts')
          .add(workoutData);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Workout saved successfully.')),
      );

      // ✅ Push workout into BlockBuilder day (block_data)
      final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);

// Get block start date
      final blockDoc = await userDoc.collection('block_planner').doc('current_block').get();
      if (blockDoc.exists) {
        final blockStartStr = blockDoc.data()?['blockStartDate'];
        if (blockStartStr != null) {
          final blockStart = DateTime.parse(blockStartStr);
          final daysSinceStart = _selectedDate.difference(blockStart).inDays;
          final weekIndex = (daysSinceStart / 7).floor();
          final dayIndex = daysSinceStart % 7;

          final weekDocRef = userDoc
              .collection('block_data')
              .doc('current_block')
              .collection('weeks')
              .doc('week_$weekIndex');

          // Ensure week doc exists
          await weekDocRef.set({'exists': true}, SetOptions(merge: true));

          final List<Map<String, dynamic>> updatedExercises = [];

          for (int i = 0; i < _selectedExercises.length; i++) {
            final name = _selectedExercises[i];
            final sets = _workoutSets[i];
            final bestSet = sets.where((s) => s.weight != null && s.reps != null).fold<SetDetails?>(null, (prev, curr) {
              if (prev == null) return curr;
              final prevE1RM = calculateE1RM(prev.weight, prev.reps?.toDouble(), prev.rir);
              final currE1RM = calculateE1RM(curr.weight, curr.reps?.toDouble(), curr.rir);
              return (currE1RM > prevE1RM) ? curr : prev;
            });

            if (bestSet != null && bestSet.weight != null && bestSet.reps != null) {
              updatedExercises.add({
                'name': name,
                'weight': bestSet.weight,
                'reps': bestSet.reps,
                'rir': bestSet.rir ?? 0.0,
              });
            }
          }

          // Fetch current day data
          final dayDoc = await weekDocRef.collection('days').doc('day_$dayIndex').get();
          final existing = dayDoc.data();
          final List<Map<String, dynamic>> existingExercises = List<Map<String, dynamic>>.from(existing?['exercises'] ?? []);

          // Merge existing + new, keeping highest E1RM
          for (final newEx in updatedExercises) {
            final matchIndex = existingExercises.indexWhere((e) => e['name'] == newEx['name']);
            if (matchIndex == -1) {
              existingExercises.add(newEx);
            } else {
              final existingEx = existingExercises[matchIndex];
              final oldE1RM = calculateE1RM(existingEx['weight'], existingEx['reps']?.toDouble(), existingEx['rir']);
              final newE1RM = calculateE1RM(newEx['weight'], newEx['reps']?.toDouble(), newEx['rir']);
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


      // ✅ Return top sets to BlockBuilder
      Navigator.pop(context, {
        'date': _selectedDate,
        'topSets': List.generate(_selectedExercises.length, (i) {
          if (_workoutSets[i].isEmpty) return null;
          final topSet = _workoutSets[i][0]; // Customize later
          return {
            'exercise': _selectedExercises[i],
            'weight': topSet.weight,
            'reps': topSet.reps,
            'rir': topSet.rir,
          };
        }).where((e) => e != null).toList(),
      });
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save workout: $error')),
      );
    }
  }


  void addSet(int exerciseIndex) {
    setState(() {
      _workoutSets[exerciseIndex]
          .add(SetDetails(reps: 0, weight: 0, rir: 0));
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
                      _selectedExercises.removeAt(exerciseIndex);
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
    if (pickedDate != null && pickedDate != _selectedDate) {
      setState(() {
        _selectedDate = pickedDate;
      });
    }
  }

  void _navigateToExerciseDetails(String exerciseName) async {
    List<Workout> recentWorkouts = await getRecentWorkoutsForExercise(exerciseName, _selectedDate);

    if (recentWorkouts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No recent workouts found for this exercise.')),
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
    List<Workout> recentWorkouts = await getRecentWorkoutsForExercise(exerciseName,_selectedDate); // ✅ Fetch all previous workouts

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TopSetsScreen(
          exerciseName: exerciseName,
          recentWorkouts: recentWorkouts, // ✅ Pass the resolved List<Workout>
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
          .doc(user.uid)
          .collection('workouts')
          .orderBy('date', descending: true)
          .limit(12)
          .get();

      List<Workout> filteredWorkouts = snapshot.docs.map((doc) {
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
              .map((exercise) => Exercise.fromFirestore(exercise as Map<String, dynamic>))
              .toList();
        }

        return Workout(
          name: data['name'] ?? 'Unnamed Workout',
          date: workoutDate,
          exercises: exercises,
        );
      }).where((workout) =>
      workout.date.isBefore(currentWorkoutDate) &&
          workout.exercises.any((exercise) => exercise.name == exerciseName))
          .toList();

      return filteredWorkouts;
    } catch (error) {
      print('Error fetching workouts: $error');
      return [];
    }
  }


  @override
  Widget build(BuildContext context) {
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
                    title: const Text('Clear Workout', style: TextStyle(fontFamily: 'Verdana', color: Colors.white),),
                    content: const Text('Delete this workout?', style: TextStyle(fontFamily: 'Verdana', color: Colors.white),),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _workoutNameController.clear();
                            _selectedExercises.clear();
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
              decoration: InputDecoration( // ✅ remove `const`
                labelText: 'Workout Name',
                labelStyle: const TextStyle(color: Colors.white),
                filled: true,
                fillColor: Colors.blueGrey.shade900, // ✅ works now
                border: OutlineInputBorder(borderSide: BorderSide.none),
              ),
            ),


            const SizedBox(height: 10.0),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text("Add Exercises"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onPressed: _showExercisePickerDialog,
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                  ),
                  onPressed: () => _selectDate(context),
                  child: const Text('Select Date', style: TextStyle(fontFamily: 'Verdana', color: Colors.black)),
                ),
              ],
            ),
            const SizedBox(height: 0.0),
            if (_selectedExercises.isEmpty)
              Column(
                children: [
                  const Text(
                      'No exercises selected yet. Add some to get started.', style: TextStyle(fontFamily: 'Verdana', color: Colors.white),),
                  const SizedBox(height: 10.0),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ElevatedButton(
                        onPressed: _navigateToTemplateSelection,
                        child: const Text('Load Template', style: TextStyle(fontFamily: 'Verdana', color: Colors.black),),
                      ),
                    ],
                  ),
                ],
              ),
    ReorderableListView(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    onReorder: _onReorderExercises,
    children: List.generate(_selectedExercises.length, (i) {
    return Dismissible(
    key: ValueKey(_selectedExercises[i]),
    direction: DismissDirection.endToStart,
    background: Container(
    color: Colors.red,
    alignment: Alignment.centerRight,
    padding: const EdgeInsets.only(right: 16),
    child: const Icon(Icons.delete, color: Colors.white),
    ),
      onDismissed: (_) {
        final removedExercise = _selectedExercises[i];
        final removedSets = _workoutSets[i];
        final removedReps = _repsControllers[i];
        final removedWeight = _weightControllers[i];
        final removedRIR = _rirControllers[i];

        setState(() {
          _selectedExercises.removeAt(i);
          _workoutSets.removeAt(i);
          _repsControllers.removeAt(i);
          _weightControllers.removeAt(i);
          _rirControllers.removeAt(i);
        });

        _lastUndoAction = () {
          setState(() {
            _selectedExercises.insert(i, removedExercise);
            _workoutSets.insert(i, removedSets);
            _repsControllers.insert(i, removedReps);
            _weightControllers.insert(i, removedWeight);
            _rirControllers.insert(i, removedRIR);
          });
        };

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted "$removedExercise"'),
            action: SnackBarAction(
              label: 'Undo',
              textColor: Colors.blueGrey.shade700, // 🔧 Optional: make 'Undo' visible
              onPressed: () {
                _lastUndoAction?.call();
                _lastUndoAction = null;
              },
            ),
          ),
        );
      },


      child: Card(
    key: ValueKey("card_$i"), // 👈 Ensure each card also has a key for ReorderableListView
    color: Colors.blueGrey.shade700,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    margin: const EdgeInsets.only(left: 0, top: 2, right: 0, bottom: 0),
    child: ExpansionTile(
    // 🧠 Everything you already had inside the card
    title: Text(
    _selectedExercises[i],
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
    _navigateToExerciseDetails(_selectedExercises[i]);
    },
    ),
    const SizedBox(width: 4),
    ElevatedButton(
    style: ElevatedButton.styleFrom(
    backgroundColor: Colors.blueGrey,
    ),
    onPressed: () {
    _navigateToTopSets(_selectedExercises[i]);
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
                    // New row between selected exercise and workout sets:
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0),
        child: Row(

          mainAxisAlignment: MainAxisAlignment.end, // 👈 Pushes to the right
          children: [
            Text(
              'Avg E1RM: ${getAverageE1RM(_selectedExercises[i]).toStringAsFixed(1)} kg',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.blueGrey,
              ),
            ),
          ],
        ),
      ),


      for (int j = 0; j < _workoutSets[i].length; j++)
                      Padding(
                        padding: const EdgeInsets.only(left: 6, bottom: 0, top: 0, right: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [



                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        const SizedBox(width: 6),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                Text(
                                                  'Set ${j + 1}',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12.0,
                                                    color: Colors.black,
                                                  ),
                                                ),
                                                const SizedBox(width: 16),

                                                if (j == 0)
                                                  Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Text(
                                                            () {
                                                          final reps = exercisePreviousTopSetReps[_selectedExercises[i]] ?? [];
                                                          final recent = reps.take(7).join(", ");
                                                          return 'Previous Rep Targets: ${recent.isEmpty ? "None" : recent}';
                                                        }(),
                                                        style: const TextStyle(
                                                          fontSize: 10.0,
                                                          fontWeight: FontWeight.bold,
                                                          color: Colors.white24
                                                        ),
                                                      ),
                                                      Builder(
                                                        builder: (context) {
                                                          final reps = _getAvailableRepTargets(i, j);
                                                          final displayText = reps.length >= 11 ? 'All (1–12)' : reps.join(", ");
                                                          return Text(
                                                            'Available Rep Targets: $displayText',
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


                                              ],
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                ),

                                IconButton(
                                  icon: const Icon(Icons.remove),
                                  onPressed: () => removeSet(i, j),
                                ),
                              ],
                            ),
                            const SizedBox(height: 0.0),

                            // ✅ Header Row with aligned labels
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Expanded(
                                    child: Text('Weight',
                                        textAlign: TextAlign.left,
                                        style: TextStyle(fontSize: 10.0, color: Colors.black, fontWeight: FontWeight.bold))),
                                const SizedBox(width: 4.0), // Reduce spacing for more room
                                const Expanded(
                                    child: Text('Reps',
                                        textAlign: TextAlign.left,
                                        style: TextStyle(fontSize: 10.0,  color: Colors.black, fontWeight: FontWeight.bold))),
                                const SizedBox(width: 4.0), // Reduce spacing for more room
                                const Expanded(
                                    child: Text('RIR',
                                        textAlign: TextAlign.left,
                                        style: TextStyle(fontSize: 10.0,  color: Colors.black, fontWeight: FontWeight.bold))),
                                const SizedBox(width: 4.0), // Reduce spacing for more room

                                // ✅ E1RM label (same level as the other headers)
                                const Expanded(
                                    child: Text('E1RM',
                                        textAlign: TextAlign.left,
                                        style: TextStyle(fontSize: 10.0, color: Colors.black, fontWeight: FontWeight.bold))),
                              ],
                            ),
                            const SizedBox(height: 0.0),

                            // ✅ Input Row with aligned values


                            Row(
                              children: [
                                // ✅ Weight Input Field with Suggested Weight for Each Set
                                Expanded(
                                  child: TextField(

                                    controller: _weightControllers[i][j],
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      hintText: (j == 0) ? set1SuggestedWeight(i).toStringAsFixed(1)
                                          : (j == 1) ? set2SuggestedWeight(i).toStringAsFixed(1)
                                          : (j == 2) ? set3SuggestedWeight(i).toStringAsFixed(1)
                                          : '20',
                                      hintStyle: const TextStyle(
                                        color: Colors.grey,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 12,
                                      ),
                                    ),
                                    onChanged: (value) {
                                      setState(() {});
                                    },
                                    style: TextStyle(
                                      color: _weightControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                    ),
                                  ),
                                ),

                                const SizedBox(width: 4.0),

                                // ✅ Updated UI for Reps in all Sets
                                Expanded(
                                  child: TextField(
                                    controller: _repsControllers[i][j],
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      hintText: _isLoadingData
                                          ? '' // ✅ Show no hint while loading
                                          : (j == 0)
                                          ? set1SuggestedReps(i).toInt().toString()
                                          : (j == 1)
                                          ? set2SuggestedReps(i).toInt().toString()
                                          : (j == 2)
                                          ? set3SuggestedReps(i).toInt().toString()
                                          : '10', // Default for other sets
                                      hintStyle: const TextStyle(
                                        color: Colors.grey,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 12,
                                      ),
                                    ),
                                    onChanged: (value) {
                                      setState(() {});
                                    },
                                    style: TextStyle(
                                      color: _repsControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                    ),
                                  ),

                                ),



                                const SizedBox(width: 4.0),

                                // ✅ Updated UI for RIR Input Field
                                Expanded(
                                  child: TextField(
                                    controller: _rirControllers[i][j],
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      hintText: (j == 0) ? set1RIR(i).toString()
                                          : (j == 1) ? set2RIR(i).toString()
                                          : (j == 2) ? set3RIR(i).toString()
                                          : '1', // Default for other sets
                                      hintStyle: const TextStyle(
                                        color: Colors.grey,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 14,
                                      ),
                                    ),
                                    onChanged: (value) {
                                      setState(() {});
                                    },
                                    style: TextStyle(
                                      color: _rirControllers[i][j].text.isEmpty ? Colors.grey : Colors.white,
                                    ),
                                  ),
                                ),


                                const SizedBox(width: 4.0),

                                // ✅ E1RM Display using Brzycki Formula with Suggested Weight, Reps, and RIR as Default
                                Expanded(
                                  child: Text(
                                    calculateE1RM(
                                        double.tryParse(_weightControllers[i][j].text) ??
                                            ((j == 0) ? set1SuggestedWeight(i)
                                                : (j == 1) ? set2SuggestedWeight(i)
                                                : (j == 2) ? set3SuggestedWeight(i)
                                                : 20.0),
                                        (int.tryParse(_repsControllers[i][j].text) ??
                                            ((j == 0) ? set1SuggestedReps(i).toInt()
                                                : (j == 1) ? set2SuggestedReps(i).toDouble()
                                                : (j == 2) ? set3SuggestedReps(i).toDouble()
                                                : 10)).toDouble(),
                                        double.tryParse(_rirControllers[i][j].text) ??
                                            ((j == 0) ? set1RIR(i)
                                                : (j == 1) ? set2RIR(i)
                                                : (j == 2) ? set3RIR(i)
                                                : 1.0) // Now correctly using set-specific RIR
                                    ).toStringAsFixed(1),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: (_weightControllers[i][j].text.isNotEmpty ||
                                          _repsControllers[i][j].text.isNotEmpty ||
                                          _rirControllers[i][j].text.isNotEmpty)
                                          ? Colors.white
                                          : Colors.grey,
                                    ),
                                  ),
                                ),

                              ],

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
              ),
    );
    }),
    ),],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToExerciseSelection,
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}
