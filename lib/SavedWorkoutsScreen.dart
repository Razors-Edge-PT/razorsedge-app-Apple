import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'WorkoutSummaryScreen.dart';

import 'workout_details_screen.dart'; // Import the details screen
import 'workout_model.dart'; // Import Workout and Exercise models

class SavedWorkoutsScreen extends StatefulWidget {
  const SavedWorkoutsScreen({super.key});

  @override
  _SavedWorkoutsScreenState createState() => _SavedWorkoutsScreenState();
}

class _SavedWorkoutsScreenState extends State<SavedWorkoutsScreen> {
  Map<DateTime, List<Workout>> groupedWorkouts = {};
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

      final Map<DateTime, List<Workout>> grouped = {};

      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        final dateRaw = data['date'];

        if (dateRaw != null) {
          final DateTime date = (dateRaw is Timestamp)
              ? dateRaw.toDate()
              : DateTime.tryParse(dateRaw.toString()) ?? DateTime.now();
          final dayKey = DateTime(date.year, date.month, date.day); // normalize

          final workout = Workout(
            name: data['name'] ?? 'Unnamed Workout',
            date: date,
            exercises: (data['exercises'] as List?)?.map((exerciseData) {
              final exerciseMap = exerciseData as Map<String, dynamic>;
              return Exercise(
                name: exerciseMap['name'] ?? 'Unnamed Exercise',
                sets: (exerciseMap['sets'] as List?)?.map((setData) {
                  final setMap = setData as Map<String, dynamic>;
                  return SetDetails(
                    reps: (setMap['reps'] as num?)?.toInt() ?? 0,
                    weight: (setMap['weight'] as num?)?.toDouble() ?? 0.0,
                    rir: (setMap['rir'] as num?)?.toDouble() ?? 0.0,
                  );
                }).toList() ?? [],
              );
            }).toList() ?? [],
          );

          grouped.putIfAbsent(dayKey, () => []).add(workout);
        }
      }

      setState(() {
        groupedWorkouts = grouped;
        isLoading = false;
      });
    } catch (error) {
      setState(() {
        errorMessage = "Failed to load workouts: $error";
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sortedDates = groupedWorkouts.keys.toList()..sort((a, b) => b.compareTo(a));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Workouts'),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage.isNotEmpty
          ? Center(child: Text(errorMessage))
          : groupedWorkouts.isEmpty
          ? const Center(child: Text('No saved workouts found.'))
          : ListView.builder(
        itemCount: sortedDates.length,
        itemBuilder: (context, index) {
          final date = sortedDates[index];
          final workoutsForDay = groupedWorkouts[date]!;

          return Card(
            color: Colors.blueGrey.shade700,
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: ListTile(
              title: Text(
                '${DateFormat('EEE d MMM').format(date)} - Week ${_getWeekNumber(date)}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),

              subtitle: Text(
                    () {
                  final templateNames = workoutsForDay
                      .map((w) => w.name.trim())
                      .where((name) => name.isNotEmpty && name != 'Unnamed Workout')
                      .toSet()
                      .join(', ');
                  return templateNames.isNotEmpty
                      ? templateNames
                      : DateFormat('dd-MM-yyyy').format(date);
                }(),
                style: const TextStyle(color: Colors.white70),
              ),

              trailing: const Icon(Icons.chevron_right, color: Colors.white54),
              onTap: () {
                final allExercises = workoutsForDay
                    .expand((w) => w.exercises)
                    .map((e) => {
                  'name': e.name,
                  'sets': e.sets.map((s) => {
                    'weight': s.weight,
                    'reps': s.reps,
                    'rir': s.rir,
                  }).toList(),
                })
                    .toList();

                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => WorkoutSummaryScreen(
                      date: date,
                      workoutName: DateFormat('EEE d MMM yyyy').format(date),
                      exercises: allExercises,
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  DateTime blockStartDate = DateTime(2025, 3, 10); // Replace with actual start if needed

  int _getWeekNumber(DateTime date) {
    final daysSinceBlockStart = date.difference(blockStartDate).inDays;
    return (daysSinceBlockStart / 7).floor() + 1;
  }

}

