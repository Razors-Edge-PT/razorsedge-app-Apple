import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'exercise_model.dart';

class ExerciseSelectionScreen extends StatefulWidget {
  final List<String> selectedExercises;

  const ExerciseSelectionScreen({required this.selectedExercises, super.key});

  @override
  State<ExerciseSelectionScreen> createState() =>
      _ExerciseSelectionScreenState();
}

class _ExerciseSelectionScreenState extends State<ExerciseSelectionScreen> {
  final List<String> _selectedExercises = []; // Local list to track selections
  final Map<String, List<Exercise>> _groupedExercises =
      {}; // Grouped exercises by body part

  @override
  void initState() {
    super.initState();
    _selectedExercises
        .addAll(widget.selectedExercises); // Copy initial selections
    _fetchExercises();
  }

  Future<void> _fetchExercises() async {
    try {
      final querySnapshot =
          await FirebaseFirestore.instance.collection('exercises').get();
      final exercises = querySnapshot.docs
          .map((doc) => Exercise.fromDocumentSnapshot(doc))
          .toList();

      // Group exercises by body part
      final Map<String, List<Exercise>> grouped = {};
      for (var exercise in exercises) {
        if (!grouped.containsKey(exercise.bodyPart)) {
          grouped[exercise.bodyPart] = [];
        }
        grouped[exercise.bodyPart]!.add(exercise);
      }

      setState(() {
        _groupedExercises.clear();
        _groupedExercises.addAll(grouped);
      });
    } catch (e) {
      print('Error fetching exercises: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to fetch exercises. Please try again later.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Exercises'),
      ),
      body: ListView(
        children: _groupedExercises.keys.map((bodyPart) {
          final exercises = _groupedExercises[bodyPart]!;

          return ExpansionTile(
            title: Text(bodyPart,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            children: exercises.map((exercise) {
              return CheckboxListTile(
                title: Text(exercise.name),
                value: _selectedExercises.contains(exercise.name),
                onChanged: (value) {
                  setState(() {
                    if (value != null) {
                      if (value) {
                        _selectedExercises.add(exercise.name);
                      } else {
                        _selectedExercises.remove(exercise.name);
                      }
                    }
                  });
                },
              );
            }).toList(),
          );
        }).toList(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.pop(context, _selectedExercises);
        },
        child: const Icon(Icons.check),
      ),
    );
  }
}
