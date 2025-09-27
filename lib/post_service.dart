import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PostService {
  PostService._();
  static final instance = PostService._();

  String get _actorUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Future<void> toggleLike(String postId) async {
    if (_actorUid.isEmpty) throw 'Not signed in';
    final likeRef = FirebaseFirestore.instance.collection('posts').doc(postId).collection('likes').doc(_actorUid);
    final postRef = FirebaseFirestore.instance.collection('posts').doc(postId);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final likeSnap = await tx.get(likeRef);
      final postSnap = await tx.get(postRef);
      if (!postSnap.exists) throw 'Post missing';

      final cur = (postSnap['likeCount'] ?? 0) as int;
      if (likeSnap.exists) {
        tx.delete(likeRef);
        tx.update(postRef, {'likeCount': (cur > 0) ? cur - 1 : 0});
      } else {
        tx.set(likeRef, {'createdAt': FieldValue.serverTimestamp()});
        tx.update(postRef, {'likeCount': cur + 1});
      }
    });
  }

  Future<void> toggleGoodLift(String postId, {required bool isVideo}) async {
    if (!isVideo) return;
    if (_actorUid.isEmpty) throw 'Not signed in';
    final glRef = FirebaseFirestore.instance.collection('posts').doc(postId).collection('goodLifts').doc(_actorUid);
    final postRef = FirebaseFirestore.instance.collection('posts').doc(postId);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final glSnap = await tx.get(glRef);
      final postSnap = await tx.get(postRef);
      if (!postSnap.exists) throw 'Post missing';

      final cur = (postSnap['goodLiftCount'] ?? 0) as int;
      if (glSnap.exists) {
        tx.delete(glRef);
        tx.update(postRef, {'goodLiftCount': (cur > 0) ? cur - 1 : 0});
      } else {
        tx.set(glRef, {'createdAt': FieldValue.serverTimestamp()});
        tx.update(postRef, {'goodLiftCount': cur + 1});
      }
    });
  }

  Future<void> addComment(String postId, String text, {required String usernameFallback}) async {
    final uid = _actorUid;
    if (uid.isEmpty || text.trim().isEmpty) return;

    // Pull username from users_public if available
    final userDoc = await FirebaseFirestore.instance.collection('users_public').doc(uid).get();
    final data = userDoc.data() ?? {};
    final username = (data['username'] ?? data['displayName'] ?? usernameFallback).toString();

    final postRef = FirebaseFirestore.instance.collection('posts').doc(postId);
    final commentRef = postRef.collection('comments').doc();

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final postSnap = await tx.get(postRef);
      if (!postSnap.exists) return;

      tx.set(commentRef, {
        'uid': uid,
        'username': username,
        'text': text.trim(),
        'createdAt': FieldValue.serverTimestamp(),
        'likeCount': 0,
      });

      final cur = (postSnap.data()?['commentCount'] ?? 0) as int;
      tx.update(postRef, {'commentCount': cur + 1});
    });
  }
}
