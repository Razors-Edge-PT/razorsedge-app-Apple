import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'core_exercises.dart'; // at the top

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
    // ➡️ Group exercises by category
    final Map<String, List<Map<String, dynamic>>> groupedExercises = {};
    for (var exercise in exercises) {
      final category = exercise['category'] ?? 'Other';
      if (!groupedExercises.containsKey(category)) {
        groupedExercises[category] = [];
      }
      groupedExercises[category]!.add(exercise);
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

    return Scaffold(
      backgroundColor: Colors.blueGrey.shade900,
      appBar: AppBar(
        title: const Text('Exercises'),
        backgroundColor: Colors.blueGrey.shade800,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            // ➡️ Category groups
            ...categoryOrder
                .where((cat) => groupedExercises.containsKey(cat))
                .map((category) => _buildCategoryTile(category, groupedExercises[category]!)),

            // ➡️ Other categories
            ...groupedExercises.entries
                .where((entry) => !categoryOrder.contains(entry.key))
                .map((entry) => _buildCategoryTile(entry.key, entry.value)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.blueGrey.shade700,
        child: const Icon(Icons.add),
        onPressed: _showAddExerciseDialog,
      ),
    );
  }

// ➡️ Helper method to build a category card
  Widget _buildCategoryTile(String category, List<Map<String, dynamic>> exercises) {
    return Card(
      color: Colors.blueGrey.shade800,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        backgroundColor: Colors.blueGrey.shade800, // ✅ Keep category background
        collapsedBackgroundColor: Colors.blueGrey.shade800, // ✅ Collapsed too
        title: Text(
          category,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Colors.white,
          ),
        ),
        children: [
          Container(
            color: Colors.blueGrey.shade700, // ✅ Lighter background inside!
            child: Column(
              children: exercises.map((exercise) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        exercise['name'] ?? 'Unnamed Exercise',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        exercise['bodyPart'] ?? 'Unknown Body Part',
                        style: TextStyle(
                          color: Colors.grey.shade300,
                          fontSize: 12,
                        ),
                      ),
                      const Divider(
                        height: 16,
                        thickness: 0.5,
                        color: Colors.white24,
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }





}
