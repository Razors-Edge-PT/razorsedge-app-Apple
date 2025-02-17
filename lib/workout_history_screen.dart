import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'workout_details_screen.dart'; // Import the details screen
import 'workout_model.dart'; // Import Workout model

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
      if (user != null) {
        final querySnapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('workouts')
            .orderBy('date', descending: true)
            .get();

        workouts = querySnapshot.docs
            .map((doc) => Workout.fromFirestore(doc))
            .toList();
      }
    } catch (error) {
      errorMessage = 'Failed to load workouts: $error';
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
          return Card(
            margin: const EdgeInsets.symmetric(
                vertical: 8, horizontal: 12),
            elevation: 3,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: Icon(
                Icons.fitness_center,
                color: Colors.blueAccent,
              ),
              title: Text(
                workout.name,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                'Date: ${DateFormat('dd MMM yyyy').format(workout.date)}',
                style: const TextStyle(color: Colors.grey),
              ),
              trailing: const Icon(Icons.arrow_forward_ios,
                  color: Colors.blueGrey),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        WorkoutDetailsScreen(workout: workout),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
