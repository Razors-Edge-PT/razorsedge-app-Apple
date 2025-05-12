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
import 'dart:convert'; // For JSON encoding
import 'debounce_Utils.dart';



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
  final List<Map<String, dynamic>>? prefilledExercisesWithCircuits;
  final List<String>? prefilledExercises; // 👈 Add this line back
  final DateTime? initialDate; // ✅ Add this line
  final String? initialWorkoutName; // ✅ Add this

  const WorkoutPage({
    Key? key,
    this.initialTemplate,
    this.workout,
    this.isNewWorkout = true,
    this.prefilledExercisesWithCircuits,
    this.prefilledExercises, // ✅ Don't forget this!
    this.initialDate,
    this.initialWorkoutName, // ✅ Add this
  }) : super(key: key);


  @override
  _WorkoutPageState createState() => _WorkoutPageState();
}

class _WorkoutPageState extends State<WorkoutPage> with WidgetsBindingObserver {


  List<String> exercises = []; // Use this to store selected exercises from the dialog
  final TextEditingController _workoutNameController = TextEditingController();
  late DateTime _selectedDate; // move this to the top of the State class
  final List<Map<String, dynamic>> _selectedExercisesWithCircuits = [];
  List<String> plannedExercises = [];
  Map<String, String> nameToIdMap = {}; // 🧠 Exercise name ➔ ID
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
    String exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

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
    String exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

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


  int getSuggestedRepTarget(int exerciseIndex, int setIndex, {double? weight}) {
    String exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    // 🔢 Count how many times this exercise appears before this exerciseIndex
    int plannedCountBefore = 0;
    for (int i = 0; i < exerciseIndex; i++) {
      if (_selectedExercisesWithCircuits[i]['name'] == exerciseName) {
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
    String exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    int plannedCountBefore = 0;
    for (int i = 0; i < exerciseIndex; i++) {
      if (_selectedExercisesWithCircuits[i]['name'] == exerciseName) {
        plannedCountBefore++;
      }
    }

    final reps = PeriodizationModelUtils.getSuggestedRepTargetByModel(
      exerciseName: exerciseName,
      plannedIndex: plannedCountBefore,
      weightText: _weightControllers[exerciseIndex][0].text,
      rirText: _rirControllers[exerciseIndex][0].text,
    );

    return reps.toDouble();
  }



  double set2SuggestedReps(int exerciseIndex) {
    String exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set2E1RM = getSet2E1RM(exerciseIndex);
    double? set1Reps = double.tryParse(_repsControllers[exerciseIndex][0].text) ?? set1SuggestedReps(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet2RepsByModel(
      exerciseName: exerciseName,
      set2E1RM: set2E1RM,
      set1Reps: set1Reps,
      weightText: _weightControllers[exerciseIndex][1].text,
      rirText: _rirControllers[exerciseIndex][1].text,
    );
  }



  double set3SuggestedReps(int exerciseIndex) {
    String exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    double set3E1RM = getSet3E1RM(exerciseIndex);
    double? set2Reps = double.tryParse(_repsControllers[exerciseIndex][1].text) ?? set2SuggestedReps(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet3RepsByModel(
      exerciseName: exerciseName,
      set3E1RM: set3E1RM,
      set2Reps: set2Reps,
      weightText: _weightControllers[exerciseIndex][2].text,
      rirText: _rirControllers[exerciseIndex][2].text,
    );
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
    final exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';

    final repsText = _repsControllers[exerciseIndex][0].text;
    final rirText = _rirControllers[exerciseIndex][0].text;

    final reps = double.tryParse(repsText) ?? set1SuggestedReps(exerciseIndex);
    final rir = double.tryParse(rirText) ?? set1RIR(exerciseIndex);

    return PeriodizationModelUtils.getSuggestedSet1WeightByModel(
      exerciseName: exerciseName,
      reps: reps,
      rir: rir,
    );
  }

  double set2SuggestedWeight(int exerciseIndex) {
    final exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';
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
    final exerciseName = _selectedExercisesWithCircuits[exerciseIndex]['name'] ?? '';
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


  @override
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedDate = widget.initialDate ?? DateTime.now();
    _setInitialWorkoutName();
    _loadInitialData();
    _fetchLastWorkoutTopSetReps();
  }



  Future<void> _loadInitialData() async {
    await loadPlannedExercisesFromFirestore();
    await loadPreviousWorkoutData();

    final draftLoaded = await _loadWorkoutDraftFromCache();
    print('[WES] Checking data sources for $_selectedDate...');
    print('→ hasDraft: $draftLoaded');
    print('→ hasPrefilled: ${widget.prefilledExercisesWithCircuits != null && widget.prefilledExercisesWithCircuits!.isNotEmpty}');
    if (draftLoaded) {
      // ✅ Priority 1: Use saved draft
      await Future.delayed(const Duration(milliseconds: 400));
      await _mergeNewBB2ExercisesIntoDraft();
    } else if (widget.prefilledExercisesWithCircuits != null &&
        widget.prefilledExercisesWithCircuits!.isNotEmpty) {
      print('[WES] Received prefilledExercisesWithCircuits:');
      for (final ex in widget.prefilledExercisesWithCircuits!) {
        print('• ${ex['name']} (circuitIndex: ${ex['circuitIndex']})');
      }

      // ✅ Priority 2: Use freshly passed BB2 data
      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(
          List<Map<String, dynamic>>.from(widget.prefilledExercisesWithCircuits!)
      );

      _workoutSets.clear();
      _repsControllers.clear();
      _weightControllers.clear();
      _rirControllers.clear();

      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
        _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      }

      await _saveWorkoutDraftToCache();
    } else {
      // ✅ Priority 3: Load saved BB2 plan from Firestore
      await _loadPlannedBlockBuilderExercisesIfAny();

      if (_selectedExercisesWithCircuits.isNotEmpty) {
        _workoutSets.clear();
        _repsControllers.clear();
        _weightControllers.clear();
        _rirControllers.clear();

        for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
          _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
          _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
          _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
        }

        await _saveWorkoutDraftToCache();
      }
    }

    if (_selectedExercisesWithCircuits.isNotEmpty) {
      _initializeControllers();
    }

    setState(() {});

  }

  void _setInitialWorkoutName() {
    if (widget.initialTemplate != null && widget.initialTemplate!.name.isNotEmpty) {
      _workoutNameController.text = widget.initialTemplate!.name;
    } else if (widget.initialWorkoutName != null) {
      _workoutNameController.text = widget.initialWorkoutName!;
    } else {
      _workoutNameController.text = DateFormat('EEE d MMM yyyy').format(_selectedDate);
    }
  }


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      final prefs = await SharedPreferences.getInstance();
      final dateKey = '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
      final timestampStr = prefs.getString('draft_last_saved_$dateKey');
      if (timestampStr != null) {
        final savedAt = DateTime.tryParse(timestampStr);
        final now = DateTime.now();
        if (savedAt != null && now.difference(savedAt).inHours < 2) {
          print('[WES] App resumed — refreshing draft with BB2 merge');
          await _mergeNewBB2ExercisesIntoDraft();
          setState(() {}); // Refresh UI if merged
        }
      }
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
        'circuitIndex': exercise.circuitIndex ?? 0, // ✅ fallback to 0 if missing
      });

      _workoutSets.add(
        exercise.sets.map((set) => SetDetails(
          reps: set.reps,
          weight: set.weight,
          rir: set.rir,
        )).toList(),
      );
    }

    _initializeControllers();
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
          'circuitIndex': (e is Map && e.containsKey('circuitIndex')) ? e['circuitIndex'] : 0,
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
        .doc(user.uid)
        .collection('templates')
        .get();

    final templates = snapshot.docs.map((doc) => Template.fromFirestore(doc.data(), doc.id)).toList();


    final selectedTemplate = await showDialog<Template>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.blueGrey.shade800,
          title: const Text('Select Template', style: TextStyle(color: Colors.white)),
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
                  title: Text(template.name, style: const TextStyle(color: Colors.white)),
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
        final lastCircuitIndex = _selectedExercisesWithCircuits.last['circuitIndex'] ?? 0;
        nextCircuitIndex = lastCircuitIndex + 1;
      }

      _selectedExercisesWithCircuits.add({
        'name': '',
        'circuitIndex': nextCircuitIndex,
      });

      _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
      _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
      _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
    });
  }





  @override
  void dispose() {
    _saveWorkoutDraftToCache(); // ✅ Auto-save workout on screen exit

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
    }
  }




  void _showExercisePickerDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (plannedExercises.isEmpty) {
      await loadPlannedExercisesFromFirestore();
    }

// 🧠 Double guard: If it's still empty after loading, just skip the planned-only filter.
    bool plannedModeAvailable = plannedExercises.isNotEmpty;

    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs.map((doc) => {
      'id': doc.id,
      'name': doc['name'] as String,
      'category': doc['category'] as String,
    }).toList();

    // 🔥 Build Name ➔ ID map
    final Map<String, String> nameToIdMap = {
      for (final ex in allExercises) ex['name']!: ex['id']!,
    };

    bool showPlannedOnly = true;
    final Map<String, bool> expandedGroups = {};

    final List<String> selected = await showDialog<List<String>>(
      context: context,
      builder: (ctx) {
        List<String> tempSelected = _selectedExercisesWithCircuits.map((e) => e['name'] as String).toList();

        return StatefulBuilder(builder: (context, setLocalState) {
          final filteredExercises = (showPlannedOnly && plannedModeAvailable)
              ? allExercises.where((ex) => plannedExercises.contains(ex['id'])).toList()
              : allExercises;


          print('Planned Exercise IDs: $plannedExercises');
          print('Loaded Exercises (id, name): ${allExercises.map((e) => '${e['id']} (${e['name']})').toList()}');
          print('Filtered Exercises (${showPlannedOnly ? "Planned Only" : "All"}): ${filteredExercises.map((e) => e['name']).toList()}');

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

          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Select Exercises", style: TextStyle(fontSize: 13, color: Colors.white)),
                if (plannedModeAvailable)
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        onChanged: (value) => setLocalState(() => showPlannedOnly = value),
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
    });
  }

  void _showExercisePickerForRow(int index) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (plannedExercises.isEmpty) {
      await loadPlannedExercisesFromFirestore();
    }

    bool plannedModeAvailable = plannedExercises.isNotEmpty;
    final snapshot = await FirebaseFirestore.instance.collection('exercises').get();

    final allExercises = snapshot.docs.map((doc) => {
      'id': doc.id,
      'name': doc['name'] as String,
      'category': doc['category'] as String,
    }).toList();

    final Map<String, String> nameToIdMap = {
      for (final ex in allExercises) ex['name']!: ex['id']!,
    };

    bool showPlannedOnly = true;
    final Map<String, bool> expandedGroups = {};

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (context, setLocalState) {
          final filteredExercises = (showPlannedOnly && plannedModeAvailable)
              ? allExercises.where((ex) => plannedExercises.contains(ex['id'])).toList()
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

          for (final category in orderedGrouped.keys) {
            expandedGroups.putIfAbsent(category, () => false);
          }

          return AlertDialog(
            backgroundColor: Colors.blueGrey.shade900,
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Select Exercise", style: TextStyle(fontSize: 13, color: Colors.white)),
                if (plannedModeAvailable)
                  Row(
                    children: [
                      Text(
                        showPlannedOnly ? "Planned Only" : "All Exercises",
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      Switch(
                        value: showPlannedOnly,
                        onChanged: (value) => setLocalState(() => showPlannedOnly = value),
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
                          return ListTile(
                            title: Text(name, style: const TextStyle(color: Colors.white70)),
                            onTap: () => Navigator.pop(ctx, name),
                          );
                        }),
                      const Divider(height: 10, color: Colors.grey),
                    ],
                  );
                }).toList(),
              ),
            ),
          );
        });
      },
    );

    if (selected != null && selected.isNotEmpty) {
      setState(() {
        _selectedExercisesWithCircuits[index]['name'] = selected;
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
          newCircuitIndex = _selectedExercisesWithCircuits.first['circuitIndex'] ?? 0;
        } else if (newIndex >= _selectedExercisesWithCircuits.length) {
          newCircuitIndex = _selectedExercisesWithCircuits.last['circuitIndex'] ?? 0;
        } else {
          newCircuitIndex = _selectedExercisesWithCircuits[newIndex]['circuitIndex'] ?? 0;
        }
      }

      movedExercise['circuitIndex'] = newCircuitIndex;

      // Insert at new position
      _selectedExercisesWithCircuits.insert(newIndex, movedExercise);
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
          selectedExercises: _selectedExercisesWithCircuits.map((e) => e['name'] as String).toList(),
        ),
      ),
    ).then((selectedExercises) {
      if (selectedExercises != null && selectedExercises is List<String>) {
        setState(() {
          _selectedExercisesWithCircuits.clear();
          _selectedExercisesWithCircuits.addAll(
            selectedExercises.map((name) => {
              'name': name,
              'circuitIndex': 0, // ✅ Default for new selection
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
        });
      }
    });
  }



  Future<void> _saveWorkout() async {
    if (_workoutNameController.text.isEmpty || _selectedExercisesWithCircuits.isEmpty) {

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
    final dateKey = '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
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
          final exercises = List<Map<String, dynamic>>.from(parsed['exercises'] ?? []);
          final sets = List<List>.from(parsed['sets'] ?? []);

          final filtered = <Map<String, dynamic>>[];

          for (int i = 0; i < exercises.length; i++) {
            final exercise = exercises[i];
            final setList = List<Map<String, dynamic>>.from(sets[i]);

            final hasData = setList.any((s) => (s['weight'] ?? 0) > 0 || (s['reps'] ?? 0) > 0);
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
              final sets = setList.map((s) => SetDetails(
                reps: s['reps'],
                weight: (s['weight'] as num?)?.toDouble(),
                rir: (s['rir'] as num?)?.toDouble(),
              )).toList();

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
      'exercises': _selectedExercisesWithCircuits.asMap().entries.map((entry) {
        int exerciseIndex = entry.key;
        String exerciseName = entry.value['name'] ?? 'Unnamed';
        int circuitIndex = entry.value['circuitIndex'] ?? 0;

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
          'circuitIndex': circuitIndex,
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

          for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
            final name = _selectedExercisesWithCircuits[i]['name'] ?? 'Unnamed';
            final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;
            final sets = _workoutSets[i];

            final validSets = sets.where((s) {
              final reps = s.reps ?? 0;
              final weight = s.weight ?? 0.0;
              return reps >= 1 || weight > 1;
            }).toList();


            if (validSets.isEmpty) continue;

            final bestSet = validSets.fold<SetDetails?>(null, (prev, curr) {
              if (prev == null) return curr;
              final prevE1RM = calculateE1RM(prev.weight, prev.reps?.toDouble(), prev.rir);
              final currE1RM = calculateE1RM(curr.weight, curr.reps?.toDouble(), curr.rir);
              return (currE1RM > prevE1RM) ? curr : prev;
            });

            if (bestSet != null && bestSet.weight != null && bestSet.reps != null) {
              updatedExercises.add({
                'name': name,
                'circuitIndex': circuitIndex,
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
            final prevE1RM = calculateE1RM(prev.weight, prev.reps?.toDouble(), prev.rir);
            final currE1RM = calculateE1RM(curr.weight, curr.reps?.toDouble(), curr.rir);
            return (currE1RM > prevE1RM) ? curr : prev;
          });

          if (bestSet == null) return null;

          return {
            'exercise': _selectedExercisesWithCircuits[i],
            'weight': bestSet.weight,
            'reps': bestSet.reps,
            'rir': bestSet.rir,
          };
        }).where((e) => e != null).toList(),

      });
      await clearWorkoutDraftCache(); // ✅ Clear saved draft once workout is committed
      print('Draft cache cleared after workout save.');

// 🧠 Save savedFields to SharedPreferences for BB2 to pick up
      final prefs = await SharedPreferences.getInstance();
      final List<String> savedFieldKeys = [];

      for (int i = 0; i < _selectedExercisesWithCircuits.length; i++) {
        final name = _selectedExercisesWithCircuits[i]['name'];
        final circuitIndex = _selectedExercisesWithCircuits[i]['circuitIndex'] ?? 0;
        final set = _workoutSets[i].isNotEmpty ? _workoutSets[i][0] : null;
        if (set == null) continue;

        final blockDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('block_planner')
            .doc('current_block')
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
      }

      await prefs.setStringList(
        'savedFields_${_selectedDate.toIso8601String().substring(0, 10)}',
        savedFieldKeys,
      );


    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save workout: $error')),
      );
    }



  }

  Future<void> _loadPlannedBlockBuilderExercisesIfAny() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);

    // Fetch block start date
    final blockDoc = await userDoc.collection('block_planner').doc('current_block').get();
    if (!blockDoc.exists) return;

    final blockStartStr = blockDoc.data()?['blockStartDate'];
    if (blockStartStr == null) return;

    final blockStart = DateTime.parse(blockStartStr);
    final daysSinceStart = _selectedDate.difference(blockStart).inDays;
    if (daysSinceStart < 0) return; // Before block

    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex = daysSinceStart % 7;

    final dayDoc = await userDoc
        .collection('block_data')
        .doc('current_block')
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex')
        .get();

    if (!dayDoc.exists) return;

    final exercises = List<Map<String, dynamic>>.from(dayDoc.data()?['exercises'] ?? []);
    if (exercises.isEmpty) return;

    setState(() {
      _selectedExercisesWithCircuits.clear();
      _selectedExercisesWithCircuits.addAll(
        exercises.map((e) => {
          'name': e['name'] ?? '',
          'circuitIndex': e['circuitIndex'] ?? 0,
        }),
      );

      _workoutSets.clear();
      _workoutSets.addAll(List.generate(exercises.length, (_) => List.generate(_defaultSets, (_) => SetDetails())));

      _initializeControllers();
    });
  }


  Future<void> _saveWorkoutDraftToCache() async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey = '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
    final draftKey = 'workout_draft_$dateKey';
    final timestampKey = 'draft_last_saved_$dateKey';

    final workoutDraft = {
      'name': _workoutNameController.text,
      'date': _selectedDate.toIso8601String(),
      'exercises': _selectedExercisesWithCircuits,
      'sets': _workoutSets.map((setsForExercise) {
        return setsForExercise.map((set) => {
          'reps': set.reps,
          'weight': set.weight,
          'rir': set.rir,
        }).toList();
      }).toList(),
    };

    await prefs.setString(draftKey, jsonEncode(workoutDraft)); // ✅ actually save the draft
    await prefs.setString(timestampKey, DateTime.now().toIso8601String()); // ✅ save timestamp

    print("[WES] Draft saved for $_selectedDate under key: $draftKey");
  }



  Future<bool> _loadWorkoutDraftFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey = '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2, '0')}-${_selectedDate.day.toString().padLeft(2, '0')}';
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

      final exercises = List<Map<String, dynamic>>.from(draft['exercises'] ?? []);
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
        // 🧠 Draft is still fresh, so keep everything
        filteredExercises.clear();
        filteredExercises.addAll(exercises);
        filteredSets.clear();
        filteredSets.addAll(sets.map((s) => List<Map<String, dynamic>>.from(s)));
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

        _workoutSets.add(setList.map((s) => SetDetails(
          reps: s['reps'],
          weight: (s['weight'] as num?)?.toDouble(),
          rir: (s['rir'] as num?)?.toDouble(),
        )).toList());

        _repsControllers.add(List.generate(setList.length, (_) => TextEditingController()));
        _weightControllers.add(List.generate(setList.length, (_) => TextEditingController()));
        _rirControllers.add(List.generate(setList.length, (_) => TextEditingController()));
      }

      _initializeControllers();
      _workoutNameController.text = draft['name'] ?? '';

      print('[WES] Loaded draft (expired=$isExpired, kept=${filteredExercises.length})');

      return true;
    } catch (e) {
      debugPrint('[WES] Failed to load workout draft for $dateKey: $e');
      return false;
    }
  }





  Future<void> _mergeNewBB2ExercisesIntoDraft() async {
    print('[WES] Attempting to merge BB2 exercises into draft for $_selectedDate');

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
    final blockDoc = await userDoc.collection('block_planner').doc('current_block').get();
    final blockStartStr = blockDoc.data()?['blockStartDate'];

    if (blockStartStr == null) return;

    final blockStart = DateTime.parse(blockStartStr);
    final daysSinceStart = _selectedDate.difference(blockStart).inDays;
    if (daysSinceStart < 0) return;

    final weekIndex = (daysSinceStart / 7).floor();
    final dayIndex = daysSinceStart % 7;

    final dayDoc = await userDoc
        .collection('block_data')
        .doc('current_block')
        .collection('weeks')
        .doc('week_$weekIndex')
        .collection('days')
        .doc('day_$dayIndex')
        .get();

    if (!dayDoc.exists) return;

    final bb2Exercises = List<Map<String, dynamic>>.from(dayDoc.data()?['exercises'] ?? []);
    if (bb2Exercises.isEmpty) return;

    final existingNames = _selectedExercisesWithCircuits.map((e) => e['name']).toSet();
    final newOnes = bb2Exercises.where((ex) => !existingNames.contains(ex['name'])).toList();

    if (newOnes.isNotEmpty) {
      _selectedExercisesWithCircuits.addAll(
        newOnes.map((e) => {
          'name': e['name'],
          'circuitIndex': e['circuitIndex'] ?? 0,
        }),
      );

      _workoutSets.addAll(List.generate(newOnes.length, (_) => List.generate(_defaultSets, (_) => SetDetails())));
      print('[WES] _mergeNewBB2ExercisesIntoDraft() called');
      print("[WES] Merged ${newOnes.length} new BB2 exercises into draft");
      await _saveWorkoutDraftToCache();
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

    if (pickedDate != null && pickedDate != _selectedDate) {
      // Step 1: Save current date's draft
      await _saveWorkoutDraftToCache();

      // Step 2: Switch date and reset workout name
      setState(() {
        _selectedDate = pickedDate;
        _workoutNameController.text = _formatWorkoutDate(_selectedDate);
      });

      // Step 3: Try load draft for new date
      final draftLoaded = await _loadWorkoutDraftFromCache();

      // Step 4: If no draft, fall back to BB2
      if (!draftLoaded) {
        await _loadPlannedBlockBuilderExercisesIfAny();
      } else {
        // If draft was loaded, merge in any new exercises from BB2
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
          final blockDoc = await userDoc.collection('block_planner').doc('current_block').get();
          final blockStartStr = blockDoc.data()?['blockStartDate'];
          if (blockStartStr != null) {
            final blockStart = DateTime.parse(blockStartStr);
            final daysSinceStart = _selectedDate.difference(blockStart).inDays;
            if (daysSinceStart >= 0) {
              final weekIndex = (daysSinceStart / 7).floor();
              final dayIndex = daysSinceStart % 7;

              final dayDoc = await userDoc
                  .collection('block_data')
                  .doc('current_block')
                  .collection('weeks')
                  .doc('week_$weekIndex')
                  .collection('days')
                  .doc('day_$dayIndex')
                  .get();

              if (dayDoc.exists) {
                final bb2Exercises = List<Map<String, dynamic>>.from(dayDoc.data()?['exercises'] ?? []);

                // Filter for only new ones not in draft
                final existingNames = _selectedExercisesWithCircuits.map((e) => e['name']).toSet();
                final newExercises = bb2Exercises.where((e) => !existingNames.contains(e['name'])).toList();

                if (newExercises.isNotEmpty) {
                  setState(() {
                    _selectedExercisesWithCircuits.addAll(
                      newExercises.map((e) => {
                        'name': e['name'] ?? '',
                        'circuitIndex': e['circuitIndex'] ?? 0,
                      }),
                    );
                    for (int i = 0; i < newExercises.length; i++) {
                      _workoutSets.add(List.generate(_defaultSets, (_) => SetDetails()));
                      _repsControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
                      _weightControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
                      _rirControllers.add(List.generate(_defaultSets, (_) => TextEditingController()));
                    }
                  });
                }
              }
            }
          }
        }
      }
    }
  }



  String _formatWorkoutDate(DateTime date) {
    final dayOfWeek = DateFormat('EEEE').format(date); // e.g., Tuesday
    final day = date.day; // 29
    final month = DateFormat('MMMM').format(date); // April
    final year = date.year; // 2025

    return '$dayOfWeek $day $month $year';
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
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(20)
        .get();

    final recentWorkouts = snapshot.docs.map((doc) {
      return Workout.fromFirestore(doc);
    }).where((workout) => workout.exercises.any((ex) => ex.name == exerciseName)).toList();

    if (recentWorkouts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No recent workouts found for this exercise.')),
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
              style: TextStyle(fontSize: 18),  textAlign: TextAlign.center, // 👈 Center the text,
              decoration: InputDecoration( // ✅ remove `const`
                labelStyle: const TextStyle(color: Colors.white),
                filled: true,
                fillColor: Colors.blueGrey.shade900, // ✅ works now
                border: OutlineInputBorder(borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12), // 👈 Tighten spacing
              ),
            ),
// 🆕 Add a non-editable display of the workout date
            // 🆕 Date displayed below, uneditable

            Padding(
              padding: const EdgeInsets.only(left: 8.0, bottom: 7.0), // 👈 shifts it to the right
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
              padding: const EdgeInsets.only(left: 5, top: 0, right:5, bottom: 0), // 🔥 Added cleaner side spacing
              child: Row(
                children: [
                  Flexible(
                    flex: 4,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text("Add Exercises", style: TextStyle(fontSize: 14)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
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
                        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
                      ),
                      onPressed: _showTemplateSelectionDialog,
                      child: const Text('Load Template', style: TextStyle(fontSize: 13, fontFamily: 'Verdana', color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    flex: 3,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey.shade700,
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
                      ),
                      onPressed: () => _selectDate(context),
                      child: const Text('Select Date', style: TextStyle(fontFamily: 'Verdana', color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),




            const SizedBox(height: 4.0),
            if (_selectedExercisesWithCircuits.isEmpty)
              Column(
                children: [
                  const Text(
                      'No exercises selected yet. Add some to get started.', style: TextStyle(fontFamily: 'Verdana', color: Colors.white, fontSize: 14),),
                  const SizedBox(height: 6.0),
                ],
              ),


    ReorderableListView(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    onReorder: _onReorderExercises,
      children: List.generate(_selectedExercisesWithCircuits.length, (i) {
        final current = _selectedExercisesWithCircuits[i];
        final prev = i > 0 ? _selectedExercisesWithCircuits[i - 1] : null;
        final isNewCircuit = i == 0 || current['circuitIndex'] != prev?['circuitIndex'];

        return Column(
            key: ValueKey("column_$i"),
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
        final removedExercise = _selectedExercisesWithCircuits[i];
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
        _selectedExercisesWithCircuits.insert(i, removedExercise);
        _workoutSets.insert(i, removedSets);
        _repsControllers.insert(i, removedReps);
        _weightControllers.insert(i, removedWeight);
        _rirControllers.insert(i, removedRIR);
        });
        };

        ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
        content: Text('Deleted "${removedExercise['name']}"'),
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
        child: Card(
        key: ValueKey("card_$i"), // 👈 Unique per exercise
        // 🔁 All your existing ExpansionTile UI goes here
    color: Colors.blueGrey.shade700,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
    margin: const EdgeInsets.only(left: 0, top: 2, right: 0, bottom: 0),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 8), // ✅ Shrink horizontal padding
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
      _navigateToExerciseDetails(_selectedExercisesWithCircuits[i]['name'] ?? '');

    },
    ),
    const SizedBox(width: 4),
    ElevatedButton(
    style: ElevatedButton.styleFrom(
    backgroundColor: Colors.blueGrey,
    ),
    onPressed: () {
    _navigateToTopSets(_selectedExercisesWithCircuits[i]['name'] ?? '');
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
        padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 0),
        child: Row(

          mainAxisAlignment: MainAxisAlignment.end, // 👈 Pushes to the right
          children: [
          ],
        ),
      ),


      for (int j = 0; j < _workoutSets[i].length; j++)
                      Padding(
                        padding: const EdgeInsets.only(left: 6, bottom: 0, top: 0, right: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [



                            if (j == 0) ...[
                              const SizedBox(height: 2),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 1),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment: CrossAxisAlignment.center, // ✅ Center vertically
                                  children: [
                                    // ➡️ Previous Rep Targets + Available Rep Targets (on the LEFT)
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                              () {
                                            final reps = exercisePreviousTopSetReps[_selectedExercisesWithCircuits[i]['name'] ?? ''] ?? [];
                                            final recent = reps.take(7).join(", ");
                                            return 'Previous Rep Targets: ${recent.isEmpty ? "None" : recent}';
                                          }(),
                                          style: const TextStyle(
                                            fontSize: 10.0,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white24,
                                          ),
                                        ),
                                        const SizedBox(height: 0),
                                        Builder(
                                          builder: (context) {
                                            final exerciseName = _selectedExercisesWithCircuits[i]['name'] ?? '';
                                            final reps = PeriodizationModelUtils.getAvailableRepTargets(exerciseName);

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

                                    // ➡️ Spacer to push Avg E1RM to the right
                                    const Spacer(),

                                    // ➡️ Avg E1RM (on the RIGHT)
                                    Text(
                                      'Avg E1RM: ${getAverageE1RM(_selectedExercisesWithCircuits[i]['name'] ?? '').toStringAsFixed(1)}Kg',
                                      style: const TextStyle(
                                        fontSize: 12.0,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blueGrey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 1),
                            ],


                            SizedBox(
                              height: 25, // or 26, or 28 (experiment to see what feels tight but readable)
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4, top: 3),
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
                                    padding: const EdgeInsets.only(top: 2),
                                    child: IconButton(
                                      icon: const Icon(Icons.remove),
                                      iconSize: 18,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => removeSet(i, j),
                                    ),
                                  ),
                                ],
                              ),
                            ),



                            // ✅ Header Row with aligned labels
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), // ✅ Align horizontally cleanly
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.start, // ✅ Center vertically
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Weight',
                                      textAlign: TextAlign.left,
                                      style: TextStyle(fontSize: 10.0, color: Colors.white70, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 4.0),
                                  const Expanded(
                                    child: Text(
                                      'Reps',
                                      textAlign: TextAlign.left,
                                      style: TextStyle(fontSize: 10.0, color: Colors.white70, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 4.0),
                                  const Expanded(
                                    child: Text(
                                      'RIR',
                                      textAlign: TextAlign.left,
                                      style: TextStyle(fontSize: 10.0, color: Colors.white70, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 4.0),
                                  const Expanded(
                                    child: Text(
                                      'E1RM',
                                      textAlign: TextAlign.left,
                                      style: TextStyle(fontSize: 10.0, color: Colors.white70, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
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
                                      hintText: (j == 0)
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
                                      contentPadding: EdgeInsets.only(left: 4), // ✅ Add slight left padding inside field
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
              ), //old bracket for Card
        ),
            ],

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
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToExerciseSelection,
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}
