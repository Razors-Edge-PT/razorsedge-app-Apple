import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart'; // Import Workout and Exercise models
import 'exercise_details_screen.dart'; // Import the ExerciseDetailsScreen
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class WorkoutDetailsScreen extends StatefulWidget {
  final Workout workout;

  const WorkoutDetailsScreen({
    super.key,
    required this.workout,
  });

  @override
  _WorkoutDetailsScreenState createState() => _WorkoutDetailsScreenState();
}

class _WorkoutDetailsScreenState extends State<WorkoutDetailsScreen> {
  List<Workout> allWorkouts = [];

  @override
  void initState() {
    super.initState();
    _fetchAllWorkouts(); // Fetch all workouts when the screen is initialized
  }

  Future<void> _fetchAllWorkouts() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('workouts')
            .orderBy('date', descending: true)
            .get();

        // Map Firestore documents to Workout objects
        allWorkouts = querySnapshot.docs.map((doc) => Workout.fromFirestore(doc)).toList();
      }
    } catch (error) {
      // Handle errors (e.g., show a Snackbar)
    }
  }

  List<Workout> getRecentWorkoutsForExercise(String exerciseName) {
    // Filter workouts that contain the specified exercise
    List<Workout> filteredWorkouts = allWorkouts.where((w) =>
        w.exercises.any((ex) => ex.name == exerciseName)).toList();

    // Sort workouts by date (most recent first)
    filteredWorkouts.sort((a, b) => b.date.compareTo(a.date));

    // Return only the most recent three workouts
    return filteredWorkouts.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.workout.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () {
              // Handle navigation to workout edit screen (optional)
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Workout Date: ${DateFormat('dd-MM-yyyy').format(widget.workout.date)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text(
              'Exercises:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: widget.workout.exercises.length,
                itemBuilder: (context, index) {
                  final exercise = widget.workout.exercises[index];
                  return GestureDetector(
                    onDoubleTap: () {
                      // Gather recent workouts for this exercise
                      List<Workout> recentWorkouts = getRecentWorkoutsForExercise(exercise.name);

                      // Navigate to the exercise details screen on double tap
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ExerciseDetailsScreen(
                            exerciseName: exercise.name, // Pass the exercise name
                            recentWorkouts: recentWorkouts, // Pass recent workouts
                          ),
                        ),
                      );
                    },
                    child: ExpansionTile(
                      title: Text(exercise.name),
                      children: exercise.sets.map((set) {
                        return ListTile(
                          title: Text('Set ${set.setNumber}'),
                          subtitle: Text('Reps: ${set.reps}, Weight: ${set.weight} kg'),
                        );
                      }).toList(),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
