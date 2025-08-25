import 'package:cloud_firestore/cloud_firestore.dart';

class Workout {
  final String name;
  final DateTime date;
  final List<Exercise> exercises;

  Workout({required this.name, required this.date, required this.exercises});

  // Factory constructor for converting Firestore data into a Workout object
  factory Workout.fromFirestore(DocumentSnapshot<Map<String, dynamic>> snapshot) {
    final data = snapshot.data()!;


    double parseToDouble(dynamic value) {
      if (value is double) return value;
      if (value is int) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0.0;
      return 0.0; // Default if null
    }

    // Handle both Firestore Timestamp and String date formats
    DateTime workoutDate;
    if (data['date'] is Timestamp) {
      workoutDate = (data['date'] as Timestamp).toDate();
    } else if (data['date'] is String) {
      workoutDate = DateTime.tryParse(data['date']) ?? DateTime.now();
    } else {
      throw Exception('Invalid date format');
    }

    // ✅ Ensure `exercisesData` is a List before mapping
    List<dynamic> exercisesData = data['exercises'] ?? [];

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
  final String? id;                  // 👈 optional id
  final String name;
  final List<SetDetails> sets;
  final int circuitIndex; // ✅ Added for circuit support

  Exercise({
    this.id,                         // 👈 not required
    required this.name,
    required this.sets,
    this.circuitIndex = 0, // ✅ Default to 0 for backward compatibility
  });

  factory Exercise.fromFirestore(Map<String, dynamic> data) {
    var setsData = data['sets'] as List<dynamic>;

    List<SetDetails> sets = setsData.asMap().entries.map((entry) {
      return SetDetails.fromFirestore(entry.value as Map<String, dynamic>, entry.key + 1);
    }).toList();

    return Exercise(
      id: data['id']?.toString(),                   // 👈 safely pick up id if present
      name: data['name'] ?? 'Unnamed Exercise',
      sets: sets,
      circuitIndex: data['circuitIndex'] ?? 0, // ✅ Read from Firestore or fallback
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      if (id != null) 'id': id,                     // 👈 only save if present
      'name': name,
      'circuitIndex': circuitIndex, // ✅ Include in save
      'sets': sets.map((s) => s.toMap()).toList(),
    };
  }
}



class SetDetails {
  int? reps;
  double? weight;
  double? rir;

  // ✅ New fields
  double? velocity;
  String? notes;

  SetDetails({
    this.reps,
    this.weight,
    this.rir,
    this.velocity,
    this.notes,
  });

  factory SetDetails.fromFirestore(Map<String, dynamic> data, int setNumber) {
    return SetDetails(
      reps: (data['reps'] is int)
          ? data['reps']
          : (data['reps'] is double)
          ? (data['reps'] as double).toInt()
          : int.tryParse(data['reps']?.toString() ?? ''),
      weight: (data['weight'] is num)
          ? (data['weight'] as num).toDouble()
          : null,
      rir: (data['rir'] is num)
          ? (data['rir'] as num).toDouble()
          : null,

      // ✅ Handle velocity
      velocity: (data['velocity'] is num)
          ? (data['velocity'] as num).toDouble()
          : double.tryParse(data['velocity']?.toString() ?? ''),

      // ✅ Handle notes
      notes: data['notes']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
    'reps': reps,
    'weight': weight,
    'rir': rir,
    'velocity': velocity,
    'notes': notes,
  };

  /// ✅ Check if a SetDetails entry is empty (for hint text logic)
  bool isEmpty() {
    return reps == null && weight == null && rir == null;
  }
}






