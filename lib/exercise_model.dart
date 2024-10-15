import 'package:cloud_firestore/cloud_firestore.dart';

class Exercise {
  final String id;
  final String name;
  final String bodyPart;
  final String category;

  Exercise({
    required this.id,
    required this.name,
    required this.bodyPart,
    required this.category});

  factory Exercise.fromDocumentSnapshot(DocumentSnapshot snapshot) {
    return Exercise(
      id: snapshot.id,
      name: snapshot.get('name'),
      bodyPart: snapshot.get('bodyPart'),
      category: snapshot.get('category'),
    );
  }
}