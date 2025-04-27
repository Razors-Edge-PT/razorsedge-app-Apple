import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:string_similarity/string_similarity.dart'; // ✅ only need import
import 'core_exercises.dart'; // ✅ your updated master list

Future<void> updateExercisesInFirestore() async {
  final FirebaseFirestore firestore = FirebaseFirestore.instance;
  final CollectionReference exercisesCollection = firestore.collection('exercises');

  // Fetch existing exercises
  final snapshot = await exercisesCollection.get();
  final existingExercises = snapshot.docs.map((doc) => {
    'id': doc.id,
    'name': doc['name'] as String,
    'category': doc['category'] as String? ?? '',
    'bodyPart': doc['bodyPart'] as String? ?? '',
  }).toList();

  for (final core in coreExercises) {
    final coreName = core['name']!;
    final coreCategory = core['category']!;
    final coreBodyPart = core['bodyPart']!;

    // Find best match
    String? bestMatchId;
    double bestScore = 0.0;

    for (final existing in existingExercises) {
      final score = StringSimilarity.compareTwoStrings(
        coreName.toLowerCase(),
        existing['name']!.toLowerCase(),
      );

      if (score > bestScore) {
        bestScore = score;
        bestMatchId = existing['id'];
      }
    }

    // If good enough match (similarity score >= 0.7), update
    if (bestScore >= 0.7 && bestMatchId != null) {
      await exercisesCollection.doc(bestMatchId).update({
        'name': coreName,
        'category': coreCategory,
        'bodyPart': coreBodyPart,
      });
      print('✅ Renamed existing: "$coreName" (score: ${bestScore.toStringAsFixed(2)})');
    } else {
      // Otherwise, add it as a new exercise
      await exercisesCollection.add({
        'name': coreName,
        'category': coreCategory,
        'bodyPart': coreBodyPart,
      });
      print('➕ Added new exercise: "$coreName" (no close match found)');
    }
  }

  print('🎯 All exercises updated and added.');
}
