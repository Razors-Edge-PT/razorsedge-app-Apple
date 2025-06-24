import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class BlockRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  BlockRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Returns the ID of the block where `isActive == true`, or null if none.
  Future<String?> fetchActiveBlockId() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;

    final snap = await _firestore
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (snap.docs.isEmpty) return null;
    return snap.docs.first.id;
  }
}
