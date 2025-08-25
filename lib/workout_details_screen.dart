import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'workout_entry_screen.dart';
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

double calculateE1RM(double? weight, int? reps, double? rir) {
  double w = weight ?? 0.0;
  int r = reps ?? 0;
  double rValue = rir ?? 0.0;

  return w * (1 + (0.0333 * (r + rValue)));
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
        setState(() {
          allWorkouts = querySnapshot.docs.map((doc) => Workout.fromFirestore(doc)).toList();
        });
        // 🔍 Debugging: Print the total number of workouts retrieved
        print("Total workouts retrieved from Firestore: ${allWorkouts.length}");
      }
    } catch (error) {
      // Handle errors (e.g., show a Snackbar)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error fetching workouts: $error')),
      );
    }
  }

  List<Workout> getRecentWorkoutsForExercise(String exerciseName, DateTime currentWorkoutDate) {
    // Return the 12 most recent workouts that contain the exercise, regardless of date
    List<Workout> filteredWorkouts = allWorkouts.where(
            (w) => w.exercises.any((ex) => ex.name == exerciseName)
    ).toList();

    filteredWorkouts.sort((a, b) => b.date.compareTo(a.date));
    return filteredWorkouts.take(12).toList();
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Workout: ${widget.workout.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => WorkoutPage(workout: widget.workout),
                ),
              );
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
                  return Card(
                    elevation: 2.0,
                    margin: const EdgeInsets.symmetric(vertical: 4.0),
                    child: ExpansionTile(
                      title: Text(
                        exercise.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.info_outline),
                        onPressed: () {
                          // Gather recent workouts for this exercise
                          List<Workout> recentWorkouts = getRecentWorkoutsForExercise(exercise.name,widget.workout.date);
                          // Navigate to the exercise details screen
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ExerciseDetailsScreen(
                                exerciseId: exercise.id ?? exercise.name,  // 👈 required
                                exerciseName: exercise.name,               // optional
                              ),
                            ),
                          );

                        },
                      ),
                      children: exercise.sets.asMap().entries.map((entry) {
                        final int setIndex = entry.key + 1; // Set index starts from 1
                        final set = entry.value;

                        // ✅ Calculate E1RM using the hybrid formula
                        double weight = set.weight ?? 0.0;
                        double reps = (set.reps ?? 0).toDouble();  // ✅ Convert safely by defaulting to 0
                        double rir = set.rir ?? 0.0;
                        double totalReps = reps + rir;

                        double e1rm = (totalReps <= 6)
                            ? (weight * (36 / (37 - totalReps))) // Brzycki for low reps
                            : (weight * (1 + (0.0333 * totalReps))); // Epley for high reps

// ✅ Find the highest E1RM in this workout using the hybrid formula
                        double highestE1RM = exercise.sets
                            .map((s) {
                          double sWeight = s.weight ?? 0.0;
                          double sReps = (s.reps ?? 0).toDouble();
                          double sRIR = s.rir ?? 0.0;
                          double sTotalReps = sReps + sRIR;

                          return (sTotalReps <= 6)
                              ? (sWeight * (36 / (37 - sTotalReps))) // Brzycki for low reps
                              : (sWeight * (1 + (0.0333 * sTotalReps))); // Epley for high reps
                        })
                            .reduce((a, b) => a > b ? a : b); // ✅ Find max E1RM safely



                        return Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: e1rm == highestE1RM ? Colors.blue : Colors.transparent, // ✅ Blue border for highest E1RM
                              width: 2.0,
                            ),
                            borderRadius: BorderRadius.circular(8.0),
                          ),
                          margin: const EdgeInsets.symmetric(vertical: 4.0), // Space between sets
                          child: ListTile(
                            title: Text('Set $setIndex'),
                            subtitle: Text(
                              'W:${set.weight}kg X ${set.reps} Reps, RIR: ${set.rir} | '
                                  'E1RM: ${e1rm.toStringAsFixed(1)}kg',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: e1rm == highestE1RM ? FontWeight.bold : FontWeight.normal, // ✅ Bold for highest E1RM
                                color: e1rm == highestE1RM ? Colors.blue : Colors.black, // ✅ Blue text for highest E1RM
                              ),
                            ),
                          ),
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
