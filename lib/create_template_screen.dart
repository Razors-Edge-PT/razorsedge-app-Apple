import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'template_details.dart'; // 👈 Add this if not already imported
import 'exercise_model.dart';
import 'template_model.dart'; // Assuming your template model is in this file
import 'template_utils.dart'; // Import the shared methods
import 'package:firebase_auth/firebase_auth.dart';

class CreateTemplateScreen extends StatefulWidget {
  final VoidCallback onTemplateCreated; // Callback to refresh template list
  const CreateTemplateScreen({super.key, required this.onTemplateCreated});

  @override
  State<CreateTemplateScreen> createState() => _CreateTemplateScreenState();
}

class _CreateTemplateScreenState extends State<CreateTemplateScreen> {
  final _formKey = GlobalKey<FormState>();
  String _name = '';
  final _selectedExercises = <String>[]; // Initialize as empty list
  List<Exercise> exercises = []; // List of available exercises
  // Generate a unique ID (replace with your preferred method)
  final generatedId =
      'template_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1000)}';

  bool _plannedOnly = false;
  List<String> plannedExercises = []; // This will hold your planned exercise IDs
  Set<String> _plannedExerciseIds = {}; // stores planned exercise IDs


  @override
  void initState() {
    super.initState();
    _fetchExercises();
    _fetchPlannedExercises(); // <-- 🔥 Add this!
  }
  Future<void> _fetchPlannedExercises() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('block_planner')
        .doc('current_block')
        .get();

    if (doc.exists && doc.data() != null && doc.data()!.containsKey('plannedExercises')) {
      final List<dynamic> plannedList = doc.data()!['plannedExercises'];
      setState(() {
        _plannedExerciseIds = plannedList.cast<String>().toSet();
      });
      print('✅ Planned exercise IDs fetched: $_plannedExerciseIds'); // 👈 Add this
    }
  }


  Future<void> _fetchExercises() async {
    try {
      final querySnapshot =
          await FirebaseFirestore.instance.collection('exercises').get();

      final exerciseList = querySnapshot.docs
          .map((doc) => Exercise(
                id: doc.id,
                name: doc.get('name'),
                bodyPart: doc.get('bodyPart'), // Access the bodyPart field
                category: doc.get('category'), // Access the category field
              ))
          .toList();
      setState(() {
        exercises = exerciseList;
      });
      print('✅ All exercises fetched: ${exercises.map((e) => e.id).toList()}'); // 👈 Add this
    } catch (error) {
      print("Error fetching exercises: $error");
    }
  }
  List<Widget> _buildGroupedExerciseList(List<Exercise> displayedExercises) {
    final grouped = <String, List<Exercise>>{};

    for (var exercise in displayedExercises) {
      final category = exercise.category ?? 'Other';
      if (!grouped.containsKey(category)) {
        grouped[category] = [];
      }
      grouped[category]!.add(exercise);
    }

    // 🧠 Your custom category order
    final List<String> customCategoryOrder = [
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
      'Other', // fallback category if needed
    ];

    final List<Widget> widgets = [];

    for (final category in customCategoryOrder) {
      if (grouped.containsKey(category)) {
        final exercisesInCategory = grouped[category]!..sort((a, b) => a.name.compareTo(b.name));

        widgets.add(
          ExpansionTile(
            title: Text(category),
            children: exercisesInCategory.map((exercise) {
              return CheckboxListTile(
                title: Text(exercise.name),
                value: _selectedExercises.contains(exercise.id),
                onChanged: (value) => _handleExerciseSelection(exercise, value!),
              );
            }).toList(),
          ),
        );
      }
    }

    return widgets;
  }


  final Map<String, String> _exerciseNameMap = {};

  void _handleExerciseSelection(Exercise exercise, bool isSelected) {
    setState(() {
      if (isSelected) {
        _selectedExercises.add(exercise.id);
        _exerciseNameMap[exercise.id] = exercise.name; // Store exercise name
      } else {
        _selectedExercises.remove(exercise.id);
        _exerciseNameMap.remove(exercise.id); // Remove exercise name
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 👇 First decide which exercises to display based on toggle
    final displayedExercises = _plannedOnly
        ? exercises.where((e) => _plannedExerciseIds.contains(e.id)).toList()
        : exercises;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Design Workout'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () => _submitTemplate(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      decoration: const InputDecoration(
                        labelText: 'Template Name',
                      ),
                      validator: (value) =>
                      value!.isEmpty ? 'Please enter a name' : null,
                      onSaved: (value) => setState(() => _name = value!),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    children: [
                      const Text('Planned Only', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: _plannedOnly,
                        onChanged: (value) {
                          setState(() {
                            _plannedOnly = value;
                          });
                        },
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),

              Expanded(
                child: exercises.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : displayedExercises.isEmpty
                    ? const Center(child: Text('No exercises available'))
                    : ListView(
                  children: _buildGroupedExerciseList(displayedExercises),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }


  void _submitTemplate(BuildContext context) {
    if (_formKey.currentState!.validate()) {
      _formKey.currentState!.save();

      if (_selectedExercises.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select at least one exercise')),
        );
        return;
      }

      final newTemplate = Template(
        id: ' ', // Will be generated by Firestore
        name: _name,
        exercises: _selectedExercises.map((id) {
          final name = _exerciseNameMap[id]!;
          return {
            'name': name,
            'circuitIndex': 0,
          };
        }).toList(),
      );


      addTemplateToFirestore(newTemplate, generatedId).then((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Template created successfully')),
        );
        widget.onTemplateCreated();

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => TemplateDetailsScreen(
              template: Template( // 👈 build Template object
                id: generatedId,
                name: _name,
                exercises: _selectedExercises.map((id) {
                  final name = _exerciseNameMap[id]!;
                  return {
                    'name': name,
                    'circuitIndex': 0,
                  };
                }).toList(),
              ),
            ),
          ),
        );
      }).catchError((error) {
        // Handle errors
      });


    }
  }

}
