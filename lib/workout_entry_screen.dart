import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart'; // Import this package for date formatting
import 'exercise_selection_screen.dart';
import 'template_model.dart';
import 'templates.dart';
import 'exercise_details_screen.dart'; // Import your exercise details screen

class WorkoutPage extends StatefulWidget {
  const WorkoutPage({super.key});

  @override
  _WorkoutPageState createState() => _WorkoutPageState();
}

class SetDetails {
  String reps;
  String weight;

  SetDetails({required this.reps, required this.weight});

  Map<String, dynamic> toMap() => {
    'reps': reps,
    'weight': weight,
  };
}

class _WorkoutPageState extends State<WorkoutPage> {
  final TextEditingController _workoutNameController = TextEditingController();
  DateTime _selectedDate = DateTime.now(); // Set the default date to today
  final List<String> _selectedExercises = [];
  final List<List<SetDetails>> _workoutSets = [];
  final List<List<TextEditingController>> _repsControllers = [];
  final List<List<TextEditingController>> _weightControllers = [];
  final int _defaultSets = 3;

  @override
  void dispose() {
    _workoutNameController.dispose();
    // Dispose all controllers
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
    super.dispose();
  }

  void _initializeControllers() {
    _repsControllers.clear();
    _weightControllers.clear();

    for (int i = 0; i < _selectedExercises.length; i++) {
      _repsControllers.add(
        _workoutSets[i].map((set) => TextEditingController(text: set.reps)).toList(),
      );
      _weightControllers.add(
        _workoutSets[i].map((set) => TextEditingController(text: set.weight)).toList(),
      );
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
        setState(() {
          _workoutNameController.text = selectedTemplate.name;
          _selectedExercises.clear();
          _workoutSets.clear();

          _selectedExercises.addAll(selectedTemplate.exercises);
          _workoutSets.addAll(List.generate(
            _selectedExercises.length,
                (index) => List.generate(
              _defaultSets,
                  (setIndex) => SetDetails(reps: '', weight: ''), // No setNumber here
            ),
          ));
          // Initialize TextEditingControllers
          _initializeControllers();
        });
      }
    });
  }

  void _navigateToExerciseSelection() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExerciseSelectionScreen(
          selectedExercises: _selectedExercises, // Pass current selections
        ),
      ),
    ).then((selectedExercises) {
      if (selectedExercises != null && selectedExercises is List<String>) {
        setState(() {
          _selectedExercises.clear();
          _selectedExercises.addAll(selectedExercises);

          // Generate sets for each exercise
          _workoutSets.clear();
          _workoutSets.addAll(
            List.generate(
              _selectedExercises.length,
                  (index) => List.generate(
                _defaultSets,
                    (setIndex) => SetDetails(reps: '', weight: ''), // No setNumber here
              ),
            ),
          );
          _initializeControllers(); // Make sure controllers are updated
        });
      }
    });
  }

  Future<void> _saveWorkout() async {
    if (_workoutNameController.text.isEmpty ||
        _selectedExercises.isEmpty) {
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
      'date': _selectedDate.toIso8601String(), // Use the selected date
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
      _workoutSets[exerciseIndex].add(SetDetails(reps: '', weight: ''));
      _repsControllers[exerciseIndex].add(TextEditingController());
      _weightControllers[exerciseIndex].add(TextEditingController());
    });
  }

  void removeSet(int exerciseIndex, int setIndex) {
    if (setIndex == 0) {
      if (_workoutSets[exerciseIndex].length == 1) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Confirm Removal'),
              content: const Text('Are you sure you want to remove this exercise?'),
              actions: <Widget>[
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(); // Close the dialog
                  },
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedExercises.removeAt(exerciseIndex);
                      _workoutSets.removeAt(exerciseIndex);
                    });
                    Navigator.of(context).pop(); // Close the dialog after removal
                  },
                  child: const Text('Yes'),
                ),
              ],
            );
          },
        );
      } else {
        setState(() {
          _workoutSets[exerciseIndex].removeAt(setIndex);
        });
      }
    } else {
      setState(() {
        _workoutSets[exerciseIndex].removeAt(setIndex);
      });
    }
  }

  // New method to show date picker
  Future<void> _selectDate(BuildContext context) async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );
    if (pickedDate != null && pickedDate != _selectedDate) {
      setState(() {
        _selectedDate = pickedDate; // Update the selected date
      });
    }
  }

  // Method to navigate to exercise details screen
  void _navigateToExerciseDetails(String exerciseName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExerciseDetailsScreen(exerciseName: exerciseName, recentWorkouts: const [],),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workout Entry'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _navigateToExerciseSelection,
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveWorkout,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date picker
            Row(
              children: [
                Text(
                  'Workout Date: ${DateFormat('dd-MM-yyyy').format(_selectedDate)}',
                  style: const TextStyle(fontSize: 16),
                ),
                IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: () => _selectDate(context),
                ),
              ],
            ),
            const SizedBox(height: 16.0),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _selectedExercises.length,
              itemBuilder: (context, exerciseIndex) {
                return GestureDetector(
                  onDoubleTap: () {
                    _navigateToExerciseDetails(_selectedExercises[exerciseIndex]);
                  },
                  child: ExpansionTile(
                    key: Key('exercise_$exerciseIndex'),
                    title: Text(_selectedExercises[exerciseIndex]),
                    children: [
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _workoutSets[exerciseIndex].length,
                        itemBuilder: (context, setIndex) {
                          final setDetails = _workoutSets[exerciseIndex][setIndex];
                          return Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('Set ${setIndex + 1}'),
                                  if (setIndex == 0)
                                    IconButton(
                                      icon: const Icon(Icons.add_circle),
                                      onPressed: () => addSet(exerciseIndex),
                                    ),
                                  if (setIndex > 0)
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle),
                                      onPressed: () => removeSet(exerciseIndex, setIndex),
                                    ),
                                ],
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _repsControllers[exerciseIndex][setIndex],
                                      decoration: const InputDecoration(
                                        labelText: 'Reps',
                                      ),
                                      keyboardType: TextInputType.number,
                                    ),
                                  ),
                                  const SizedBox(width: 16.0),
                                  Expanded(
                                    child: TextField(
                                      controller: _weightControllers[exerciseIndex][setIndex],
                                      decoration: const InputDecoration(
                                        labelText: 'Weight',
                                      ),
                                      keyboardType: TextInputType.number,
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
