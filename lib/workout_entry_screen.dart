import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // Import for date formatting
import 'package:localtest222/workout_model.dart';

import 'exercise_details_screen.dart'; // Import your exercise details screen
import 'exercise_selection_screen.dart';
import 'template_model.dart';
import 'templates.dart';

class WorkoutPage extends StatefulWidget {
  final Template? initialTemplate;
  final Workout? workout; // Make workout optional

  const WorkoutPage({Key? key, this.initialTemplate, this.workout})
      : super(key: key);

  @override
  _WorkoutPageState createState() => _WorkoutPageState();
}

class SetDetails {
  String reps;
  String weight;
  String rir;

  SetDetails({
    this.reps = '', // Empty string for reps
    this.weight = '', // Empty string for weight
    this.rir = '', // Empty string for RIR
  });

  Map<String, dynamic> toMap() => {
        'reps': reps,
        'weight': weight,
        'rir': rir,
      };
}

class _WorkoutPageState extends State<WorkoutPage> {
  final TextEditingController _workoutNameController = TextEditingController();
  DateTime _selectedDate = DateTime.now(); // Set the default date to today
  final List<String> _selectedExercises = [];
  final List<List<SetDetails>> _workoutSets = [];
  final List<List<TextEditingController>> _repsControllers = [];
  final List<List<TextEditingController>> _weightControllers = [];
  final List<List<TextEditingController>> _rirControllers =
      []; // New controller list for RIR
  final int _defaultSets = 3;

  @override
  void initState() {
    super.initState();
    if (widget.workout != null) {
      _loadWorkout(widget.workout!);
    } else if (widget.initialTemplate != null) {
      _loadTemplate(widget.initialTemplate!);
    } else {
      // No placeholder exercises are added here.
      _initializeControllers();
    }
  }

  void _loadWorkout(Workout workout) {
    _workoutNameController.text = workout.name;
    _selectedDate = workout.date;
    _selectedExercises.clear();
    _selectedExercises
        .addAll(workout.exercises.map((exercise) => exercise.name));

    // Map workout exercises and sets to initialize _workoutSets and controllers
    _workoutSets.clear();
    _workoutSets.addAll(
      workout.exercises.map((exercise) {
        return exercise.sets
            .map((set) => SetDetails(
                reps: set.reps.toString(),
                weight: set.weight.toString(),
                rir: set.rir))
            .toList();
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
          (setIndex) => SetDetails(), // Using SetDetails default values
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
    // Clear existing controllers
    _repsControllers.clear();
    _weightControllers.clear();
    _rirControllers.clear();

    // Re-create controllers based on _selectedExercises with default placeholder values for each set
    for (int i = 0; i < _selectedExercises.length; i++) {
      List<SetDetails> sets = List.generate(
        _defaultSets,
        (setIndex) => SetDetails(),
      );

      _workoutSets.add(sets);

      // Ensure TextEditingController is initialized with empty string and no default text
      _repsControllers.add(sets.map((set) => TextEditingController()).toList());
      _weightControllers
          .add(sets.map((set) => TextEditingController()).toList());
      _rirControllers.add(sets.map((set) => TextEditingController()).toList());
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
                    reps: '',
                    weight: '',
                    rir: ''), // Include RIR initialization
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

    final workoutData = {
      'name': _workoutNameController.text,
      'date': _selectedDate.toIso8601String(),
      'userId': user.uid,
      'exercises': _selectedExercises.map((exercise) {
        return {
          'name': exercise,
          'sets': _workoutSets[_selectedExercises.indexOf(exercise)]
              .map((set) => set.toMap())
              .toList(),
        };
      }).toList(),
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
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save workout.')),
      );
    }
  }

  void addSet(int exerciseIndex) {
    setState(() {
      _workoutSets[exerciseIndex]
          .add(SetDetails(reps: '', weight: '', rir: ''));
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
    // Fetch recent workouts for the selected exercise using the workout date
    List<Workout> recentWorkouts =
        await getRecentWorkoutsForExercise(exerciseName, _selectedDate);

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

  Future<List<Workout>> getRecentWorkoutsForExercise(
      String exerciseName, DateTime currentWorkoutDate) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return [];
    }

    // Fetch workouts from Firebase
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .get();

    // Filter workouts by exercise name and date
    List<Workout> filteredWorkouts = snapshot.docs
        .map((doc) => Workout.fromFirestore(doc))
        .where((workout) =>
            workout.date.isBefore(currentWorkoutDate) &&
            workout.exercises.any((exercise) => exercise.name == exerciseName))
        .toList();

    // Sort by date in descending order
    filteredWorkouts.sort((a, b) => b.date.compareTo(a.date));

    // Return the top 3 recent workouts
    return filteredWorkouts.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workout Entry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete), // Trash icon
            onPressed: () {
              // Confirm clear action with an alert dialog
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text('Clear Workout'),
                    content: const Text('Delete this workout?'),
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
                            _initializeControllers(); // Reset controllers
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
              decoration: const InputDecoration(
                labelText: 'Workout Name',
              ),
            ),
            const SizedBox(height: 10.0),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Date: ${DateFormat('yMMMd').format(_selectedDate)}'),
                ElevatedButton(
                  onPressed: () => _selectDate(context),
                  child: const Text('Select Date'),
                ),
              ],
            ),
            const SizedBox(height: 0.0),
            if (_selectedExercises.isEmpty)
              const Text('No exercises selected yet. Add some to get started.'),
            for (int i = 0; i < _selectedExercises.length; i++)
              Card(
                margin:
                    const EdgeInsets.only(left: 0, top: 4, right: 0, bottom: 0),
                child: ExpansionTile(
                  title: Text(_selectedExercises[i]),
                  trailing: IconButton(
                    icon: const Icon(Icons.info_outline),
                    onPressed: () {
                      // Navigate to the exercise details screen for the selected exercise
                      _navigateToExerciseDetails(_selectedExercises[i]);
                    },
                  ),
                  children: [
                    for (int j = 0; j < _workoutSets[i].length; j++)
                      Padding(
                        padding: const EdgeInsets.only(
                            left: 6, bottom: 0, top: 0, right: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Row for the Set number and Remove Set icon
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Set ${j + 1}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12.0,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.remove),
                                  onPressed: () => removeSet(i, j),
                                ),
                              ],
                            ),
                            const SizedBox(height: 0.0),
                            // Row for the labels
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: const [
                                Expanded(
                                    child: Text('Weight',
                                        textAlign: TextAlign.left,
                                        style: TextStyle(fontSize: 10.0))),
                                SizedBox(width: 8.0),
                                Expanded(
                                    child: Text('Reps',
                                        textAlign: TextAlign.left,
                                        style: TextStyle(fontSize: 10.0))),
                                SizedBox(width: 8.0),
                                Expanded(
                                    child: Text('RIR',
                                        textAlign: TextAlign.left,
                                        style: TextStyle(fontSize: 10.0)))
                              ],
                            ),
                            const SizedBox(height: 0.0),
                            // Row for the text fields
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _weightControllers[i][j],
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      hintText: '20',
                                      // Placeholder weight value
                                      hintStyle: const TextStyle(
                                        color: Colors.grey,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 12,
                                      ),
                                    ),
                                    onChanged: (value) {
                                      _workoutSets[i][j].weight = value;
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8.0),
                                Expanded(
                                  child: TextField(
                                    controller: _repsControllers[i][j],
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      hintText: '10', // Placeholder reps value
                                      hintStyle: const TextStyle(
                                        color: Colors.grey,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 12,
                                      ),
                                    ),
                                    onChanged: (value) {
                                      _workoutSets[i][j].reps = value;
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8.0),
                                Expanded(
                                  child: TextField(
                                    controller: _rirControllers[i][j],
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      hintText: '2', // Placeholder RIR value
                                      hintStyle: const TextStyle(
                                        color: Colors.grey,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 12,
                                      ),
                                    ),
                                    onChanged: (value) {
                                      _workoutSets[i][j].rir = value;
                                    },
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
                  ],
                ),
              )
          ],
        ),
      ),
      // Floating action button for adding exercise
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToExerciseSelection,
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation:
          FloatingActionButtonLocation.endFloat, // Position at bottom-right
    );
  }
}
