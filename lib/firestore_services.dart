import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../workout_model.dart';

class FirestoreService {
  static final _auth = FirebaseAuth.instance;
  static final _firestore = FirebaseFirestore.instance;

  static Future<String?> fetchMostRecentWeight() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final snapshot = await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('weights')
        .orderBy('timestamp', descending: true)
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) return null;

    final data = snapshot.docs.first.data();
    return '${data['weight']} ${data['unit']}';
  }

  static Future<Workout?> fetchMostRecentWorkout() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final snapshot = await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .orderBy('date', descending: true)
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) return null;

    final data = snapshot.docs.first.data();

    return Workout(
      name: data['name'] ?? 'Unnamed Workout',
      date: data['date'] is Timestamp
          ? (data['date'] as Timestamp).toDate()
          : DateTime.parse(data['date']),
      exercises: (data['exercises'] as List<dynamic>).map((exercise) {
        final exerciseData = exercise as Map<String, dynamic>;
        return Exercise(
          name: exerciseData['name'] ?? 'Unnamed Exercise',
          sets: (exerciseData['sets'] as List<dynamic>).map((set) {
            final setData = set as Map<String, dynamic>;
            return SetDetails(
              reps: (setData['reps'] is num)
                  ? setData['reps'] as int
                  : int.tryParse(setData['reps'].toString()) ?? 0,
              weight: (setData['weight'] is num)
                  ? (setData['weight'] as num).toDouble()
                  : double.tryParse(setData['weight'].toString()) ?? 0.0,
              rir: (setData['rir'] is num)
                  ? (setData['rir'] as num).toDouble()
                  : double.tryParse(setData['rir'].toString()) ?? 0.0,
            );
          }).toList(),
        );
      }).toList(),
    );
  }

  static Future<DocumentSnapshot<Object?>> fetchActiveBlock() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) throw Exception('User not logged in');

    final query = await _firestore
        .collection('users')
        .doc(userId)
        .collection('planned_blocks')
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (query.docs.isNotEmpty) {
      return query.docs.first;
    } else {
      throw Exception('No active block found');
    }
  }

  static Future<List<Map<String, dynamic>>> fetchTopLifts() async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return [];

    final snapshot = await _firestore
        .collection('users')
        .doc(userId)
        .collection('workouts')
        .get();

    Map<String, double> maxes = {};

    for (var doc in snapshot.docs) {
      final exercises = List.from(doc['exercises'] ?? []);
      for (var exercise in exercises) {
        final name = exercise['name'] ?? '';
        final sets = List.from(exercise['sets'] ?? []);
        for (var set in sets) {
          final weight = (set['weight'] as num?)?.toDouble() ?? 0;
          if (!maxes.containsKey(name) || weight > maxes[name]!) {
            maxes[name] = weight;
          }
        }
      }
    }

    return maxes.entries
        .map((e) => {'exercise': e.key, 'weight': e.value})
        .toList();
  }
}
