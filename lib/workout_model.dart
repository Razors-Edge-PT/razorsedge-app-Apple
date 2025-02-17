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

    print("DEBUG - Firestore workout data: $data"); // Log entire workout data

    // Log the type of date
    if (data.containsKey('date')) {
      print("DEBUG - Type of 'date' field: ${data['date'].runtimeType}");
    } else {
      print("ERROR - 'date' field missing in Firestore data!");
    }

    // Convert date safely
    DateTime workoutDate;
    if (data['date'] is String) {
      try {
        workoutDate = DateTime.parse(data['date']); // Convert string to DateTime
      } catch (e) {
        print("ERROR - Failed to parse string date: ${data['date']}");
        workoutDate = DateTime.now(); // Fallback if parsing fails
      }
    } else {
      print("ERROR - Unexpected date format: ${data['date']}");
      workoutDate = DateTime.now(); // Default fallback
    }

    // Convert workout name to String (fix for double values)
    String workoutName = data['name'].toString(); // Ensure it's always a string

    // Convert exercises safely
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
      name: workoutName, // Always a string now
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
