import 'package:cloud_firestore/cloud_firestore.dart';
import 'set_details.dart';

class Workout {
  final String name;
  final DateTime date;
  final List<Exercise> exercises;
  final String id;

  Workout({
    required this.name,
    required this.date,
    required this.exercises,
    required this.id,
  });

  factory Workout.fromFirestore(DocumentSnapshot<Map<String, dynamic>> snapshot) {
    final data = snapshot.data() ?? {};

    DateTime workoutDate;
    if (data['date'] is Timestamp) {
      workoutDate = (data['date'] as Timestamp).toDate();
    } else if (data['date'] is String) {
      workoutDate = DateTime.parse(data['date']);
    } else {
      workoutDate = DateTime.now();
    }

    List<Exercise> exercises = [];
    if (data['exercises'] is List) {
      exercises = (data['exercises'] as List).map((exercise) {
        if (exercise is Map<String, dynamic>) {
          return Exercise.fromFirestore(exercise);
        } else {
          return Exercise(name: 'Unnamed Exercise', sets: []);
        }
      }).toList();
    }

    return Workout(
      id: snapshot.id,
      name: data['name'] ?? 'Unnamed Workout',
      date: workoutDate,
      exercises: exercises,
    );
  }
}

class Exercise {
  final String name;
  final List<SetDetails> sets;

  Exercise({required this.name, required this.sets});

  factory Exercise.fromFirestore(Map<String, dynamic> data) {
    List<SetDetails> sets = [];
    if (data['sets'] is List) {
      sets = (data['sets'] as List).map((set) {
        if (set is Map<String, dynamic>) {
          return SetDetails.fromFirestore(set);
        } else {
          return SetDetails(setNumber: 1, reps: '', weight: '', rir: '');
        }
      }).toList();
    }

    return Exercise(
      name: data['name'] ?? 'Unnamed Exercise',
      sets: sets,
    );
  }
}
