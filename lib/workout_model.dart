import 'package:cloud_firestore/cloud_firestore.dart';

class Workout {
  final String name;
  final DateTime date;
  final List<Exercise> exercises;

  Workout({required this.name, required this.date, required this.exercises});

  // Factory constructor for converting Firestore data into a Workout object
  factory Workout.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> snapshot) {
    final data = snapshot.data()!;

    // Handle both Firestore Timestamp and String date formats
    DateTime workoutDate;
    if (data['date'] is Timestamp) {
      workoutDate = (data['date'] as Timestamp).toDate();
    } else if (data['date'] is String) {
      workoutDate = DateTime.parse(data['date']);
    } else {
      throw Exception('Invalid date format');
    }

    // Parse exercises from List<Map<String, dynamic>>
    var exercisesData = data['exercises'] as List<dynamic>;
    List<Exercise> exercises = exercisesData.map((exercise) {
      return Exercise.fromFirestore(exercise as Map<String, dynamic>);
    }).toList();

    return Workout(
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

  // Factory expects a Map<String, dynamic> instead of DocumentSnapshot
  factory Exercise.fromFirestore(Map<String, dynamic> data) {
    var setsData = data['sets'] as List<dynamic>;
    List<SetDetails> sets = setsData.asMap().entries.map((entry) {
      return SetDetails.fromFirestore(entry.value as Map<String, dynamic>,
          entry.key + 1); // Pass set index as setNumber
    }).toList();

    return Exercise(
      name: data['name'] ?? 'Unnamed Exercise',
      sets: sets,
    );
  }
}

class SetDetails {
  final int setNumber; // New field for set number
  String reps;
  String weight;
  String rir; // New field for RIR

  SetDetails({
    required this.setNumber,
    required this.reps,
    required this.weight,
    required this.rir,
  });

  factory SetDetails.fromFirestore(Map<String, dynamic> data, int setNumber) {
    return SetDetails(
      setNumber: setNumber, // Assign set number
      reps: data['reps'] ?? '0',
      weight: data['weight'] ?? '0',
      rir: data['rir'] ?? '0', // Default RIR
    );
  }

  Map<String, dynamic> toMap() => {
        'setNumber': setNumber, // Include set number when converting to map
        'reps': reps,
        'weight': weight,
        'rir': rir,
      };
}
