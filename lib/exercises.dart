import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class ExercisesScreen extends StatefulWidget {
  const ExercisesScreen({super.key});

  @override
  State<ExercisesScreen> createState() => _ExercisesScreenState();
}

class _ExercisesScreenState extends State<ExercisesScreen> {
  List<Map<String, dynamic>> exercises = [];
  final _formKey = GlobalKey<FormState>();
  String _name = '';
  String _bodyPart = '';
  String _category = '';

  @override
  void initState() {
    super.initState();
    _fetchExercises();
  }

  Future<void> _fetchExercises() async {
    try {
      final querySnapshot =
          await FirebaseFirestore.instance.collection('exercises').get();
      final data = querySnapshot.docs.map((doc) => doc.data()).toList();
      setState(() {
        exercises = data;
      });
    } catch (e) {
      print('Error fetching exercises: $e');
    }
  }

  void _showAddExerciseDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Add Exercise'),
          content: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  decoration: const InputDecoration(labelText: 'Name'),
                  onChanged: (value) {
                    _name = value;
                  },
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a name';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  decoration: const InputDecoration(labelText: 'Category'),
                  onChanged: (value) {
                    _category = value;
                  },
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a category';
                    }
                    return null;
                  },
                ),
                TextFormField(
                  decoration: const InputDecoration(labelText: 'Body Part'),
                  onChanged: (value) {
                    _bodyPart = value;
                  },
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a body part';
                    }
                    return null;
                  },
                ),
                // ... other TextFields for bodyPart and category
              ],
            ),
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Save'),
              onPressed: () {
                if (_formKey.currentState!.validate()) {
                  // Add exercise to Firebase
                  _addExercise(_name, _bodyPart, _category);
                  Navigator.of(context).pop();
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _addExercise(
      String name, String bodyPart, String category) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final exerciseData = {
        'name': name,
        'bodyPart': bodyPart,
        'category': category,
        // 'timestamp': FieldValue.serverTimestamp(), // Optional: Add timestamp
      };

      try {
        await FirebaseFirestore.instance
            .collection('exercises')
            .add(exerciseData);

        _fetchExercises();
      } catch (error) {
        // Handle potential errors during data saving
        print('Error adding exercise: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Exercises'),
      ),
      body: ListView.builder(
        itemCount: exercises.length,
        itemBuilder: (context, index) {
          final exercise = exercises[index];
          return ListTile(
            title: Text(exercise['name']),
            subtitle: Text('${exercise['bodyPart']} - ${exercise['category']}'),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddExerciseDialog,
        child: const Icon(Icons.add), // Add icon for the button
      ),
    );
  }
}
