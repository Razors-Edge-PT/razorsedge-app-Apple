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

  // ✅ Function to calculate E1RM using Brzycki formula
  double calculateE1RM(double weight, double reps, double rir) {
    return weight * (36 / (37 - (reps + rir)));
  }

  @override
  Widget build(BuildContext context) {
    // ✅ Show up to 12 past workouts
    final List<Workout> limitedWorkouts = recentWorkouts.take(12).toList();

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
              'Past Workouts (Top Sets Only):',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: limitedWorkouts.length,
                itemBuilder: (context, index) {
                  final workout = limitedWorkouts[index];

                  // ✅ Find the exercise data from this workout
                  final exercise = workout.exercises.firstWhere(
                        (ex) => ex.name == exerciseName,
                    orElse: () => Exercise(name: '', sets: []),
                  );

                  if (exercise.sets.isNotEmpty) {
                    // ✅ Find the set with the highest E1RM
                    final topSet = exercise.sets.reduce((highest, current) {
                      double highestE1RM = calculateE1RM(
                        highest.weight ?? 0.0, // ✅ Provide default if null
                        (highest.reps ?? 0).toDouble(), // ✅ Convert safely
                        highest.rir ?? 0.0, // ✅ Provide default if null
                      );

                      double currentE1RM = calculateE1RM(
                        current.weight ?? 0.0, // ✅ Provide default if null
                        (current.reps ?? 0).toDouble(), // ✅ Convert safely
                        current.rir ?? 0.0, // ✅ Provide default if null
                      );

                      return currentE1RM > highestE1RM ? current : highest;
                    });

                    double topE1RM = calculateE1RM(
                      topSet.weight ?? 0.0, // ✅ Provide default if null
                      (topSet.reps ?? 0).toDouble(), // ✅ Convert safely
                      topSet.rir ?? 0.0, // ✅ Provide default if null
                    );

                    return ListTile(
                      title: Text(
                        'Workout Date: ${DateFormat('dd-MM-yyyy').format(workout.date)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${topSet.weight}kg',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 14),
                            ),
                            const TextSpan(
                              text: ' X ',
                              style: TextStyle(fontSize: 14, color: Colors.blue),
                            ),
                            TextSpan(
                              text: '${topSet.reps}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 14),
                            ),
                            const TextSpan(
                              text: ',   RIR: ',
                              style: TextStyle(fontSize: 14, color: Colors.blue),
                            ),
                            TextSpan(
                              text: '${topSet.rir}', // Keeping RIR normal
                              style: const TextStyle(fontSize: 14, color: Colors.black),
                            ),
                            const TextSpan(
                              text: ' |     E1RM: ',
                              style: TextStyle(fontSize: 14, color: Colors.blue),
                            ),
                            TextSpan(
                              text: '${topE1RM.toStringAsFixed(1)} kg',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    );
                  } else {
                    // ✅ Return an empty container to prevent null widget errors
                    return const SizedBox.shrink();
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
