import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'workout_model.dart'; // Import Workout and Exercise models

class ExerciseDetailsScreen extends StatelessWidget {
  final String exerciseName;
  final List<Workout> recentWorkouts;

  const ExerciseDetailsScreen({
    super.key,
    required this.exerciseName,
    required this.recentWorkouts,
  });

  @override
  Widget build(BuildContext context) {
    // Take only the first 3 workouts (if there are more than 3)
    final List<Workout> limitedWorkouts = recentWorkouts.take(3).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Exercise: $exerciseName'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recent Workouts (Set 1):',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: limitedWorkouts.length, // Use the limited list of 3
                itemBuilder: (context, index) {
                  final workout = limitedWorkouts[index];
                  final exercise = workout.exercises.firstWhere(
                    (ex) => ex.name == exerciseName,
                    orElse: () => Exercise(name: '', sets: []), // Safety check
                  );

                  if (exercise.sets.isNotEmpty) {
                    final set1 = exercise.sets.first; // Get Set 1

                    return ListTile(
                      title: Text(
                          'Workout Date: ${DateFormat('dd-MM-yyyy').format(workout.date)}'),
                      subtitle: Text(
                        'Reps: ${set1.reps}, Weight: ${set1.weight} kg, RIR: ${set1.rir}',
                      ),
                    );
                  } else {
                    return const ListTile(
                      title: Text('No Set 1 data available'),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
