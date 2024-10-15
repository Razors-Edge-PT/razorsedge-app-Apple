import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'template_model.dart';

Future<void> addTemplateToFirestore(Template template, String generatedId) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user != null) {
    try {
      final userDoc = FirebaseFirestore.instance.collection('users').doc(user.uid);
      final newTemplateDoc = await userDoc.collection('templates').add(template.toJson());
      final newTemplateId = newTemplateDoc.id;
    } catch (error) {
      print('Error adding template: $error');
    }
  }
}