import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'workout_model.dart'; // Import your Workout model

class TopSetsScreen extends StatefulWidget {
  @override
  _TopSetsScreenState createState() => _TopSetsScreenState();
}

class _TopSetsScreenState extends State<TopSetsScreen> {
  List<Workout> _workouts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchWorkoutHistory();
  }

  Future<void> _fetchWorkoutHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(10) // ✅ Limit to last 10 workouts
        .get();

    if (snapshot.docs.isNotEmpty) {
      setState(() {
        _workouts = snapshot.docs.map((doc) => Workout.fromFirestore(doc)).toList();
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

// ✅ Function to calculate E1RM using Brzycki formula
  double calculateE1RM(double weight, double reps, double rir) {
    return weight * (36 / (37 - (reps + rir)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Top Sets History')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _workouts.isEmpty
          ? const Center(child: Text("No previous workouts found."))
          : ListView.builder(
        itemCount: _workouts.length,
        itemBuilder: (context, index) {
          final workout = _workouts[index];

          // ✅ Find the top set with the highest E1RM in this workout
          SetDetails? topSet;
          double highestE1RM = 0.0;

          for (var exercise in workout.exercises) {
            for (var set in exercise.sets) {
              double weight = set.weight ?? 0.0;  // ✅ Provide default value if null
              double reps = (set.reps ?? 0).toDouble();  // ✅ Convert safely
              double rir = set.rir ?? 0.0;  // ✅ Provide default value if null

              double e1rm = calculateE1RM(weight, reps, rir);

              if (topSet == null || e1rm > highestE1RM) {
                highestE1RM = e1rm;
                topSet = set;
              }
            }
          }

          // ✅ If no valid sets were found, skip this workout
          if (topSet == null) return const SizedBox.shrink();

          return Card(
            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: ListTile(
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
                      text: '${highestE1RM.toStringAsFixed(1)} kg',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.blue, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
