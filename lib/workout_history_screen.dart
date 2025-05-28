import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'workout_details_screen.dart'; // Import the details screen
import 'workout_model.dart'; // Import Workout and Exercise models

class WorkoutHistoryScreen extends StatefulWidget {
  const WorkoutHistoryScreen({super.key});

  @override
  _WorkoutHistoryScreenState createState() => _WorkoutHistoryScreenState();
}

class _WorkoutHistoryScreenState extends State<WorkoutHistoryScreen> {
  List<Workout> workouts = [];
  bool isLoading = true;
  String errorMessage = '';

  @override
  void initState() {
    super.initState();
    _fetchWorkouts();
  }

  Future<void> _fetchWorkouts() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        setState(() {
          errorMessage = "No user signed in.";
        });
        return;
      }

      final querySnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('workouts')
          .orderBy('date', descending: true)
          .get();

      if (querySnapshot.docs.isEmpty) {
        setState(() {
          errorMessage = "No workouts found.";
        });
        return;
      }

      workouts = querySnapshot.docs.map((doc) {
        final data = doc.data();

        return Workout(
          name: data['name'] ?? 'Unnamed Workout',
          date: (data['date'] is Timestamp) ? (data['date'] as Timestamp).toDate() : DateTime.tryParse(data['date']) ?? DateTime.now(),
          exercises: (data['exercises'] as List?)?.map((exerciseData) {
            final exerciseMap = exerciseData as Map<String, dynamic>;
            return Exercise(
              name: exerciseMap['name'] ?? 'Unnamed Exercise',
              sets: (exerciseMap['sets'] as List?)?.map((setData) {
                final setMap = setData as Map<String, dynamic>;
                return SetDetails(
                  reps: (setMap['reps'] is num) ? setMap['reps'] as int : int.tryParse(setMap['reps'].toString()) ?? 0,
                  weight: (setMap['weight'] is num) ? (setMap['weight'] as num).toDouble() : double.tryParse(setMap['weight'].toString()) ?? 0.0,
                  rir: (setMap['rir'] is num) ? (setMap['rir'] as num).toDouble() : double.tryParse(setMap['rir'].toString()) ?? 0.0,
                );
              }).toList() ?? [],
            );
          }).toList() ?? [],
        );
      }).where((workout) => workout != null).cast<Workout>().toList();

      if (workouts.isEmpty) {
        setState(() {
          errorMessage = "No valid workouts found.";
        });
      }

    } catch (error) {
      setState(() {
        errorMessage = "Failed to load workouts: $error";
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Workout History'),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage.isNotEmpty
              ? Center(child: Text(errorMessage))
              : workouts.isEmpty
                  ? const Center(child: Text('No workouts found.'))
                  : ListView.builder(
                      itemCount: workouts.length,
                      itemBuilder: (context, index) {
                        final workout = workouts[index];
                        return ListTile(
                          title: Text(workout.name),
                          subtitle: Text(
                              DateFormat('dd-MM-yyyy').format(workout.date)),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    WorkoutDetailsScreen(workout: workout),
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}
