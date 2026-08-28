import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class BlockPlannerRepository {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Loads block metadata (start/end dates + selectedDays)
  Future<BlockMeta> loadBlockMeta({
    required String userId,
    required String blockId,
  }) async {
    final doc = await _db
        .collection('users')
        .doc(userId)
        .collection('planned_blocks')
        .doc(blockId)
        .get();
    if (!doc.exists) {
      throw Exception('Block not found');
    }
    final data = doc.data()!;
    return BlockMeta(
      startDate: (data['startDate'] as Timestamp).toDate(),
      endDate:   (data['endDate']   as Timestamp).toDate(),
      selectedDays: List<String>.from(data['selectedDays'] ?? []),
    );
  }

  /// ✅ Add this inside the class
  Future<String?> fetchActiveBlockId() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      print('❌ [Repo] No user signed in');
      return null;
    }

    print('🧪 [Repo] fetchActiveBlockId called for user: ${user.uid}');

    final blocks = await _db
        .collection('users')
        .doc(user.uid)
        .collection('planned_blocks')
        .where('isActive', isEqualTo: true)
        .limit(1)
        .get();

    if (blocks.docs.isEmpty) {
      print('❌ [Repo] No active planned block found for ${user.uid}');
      return null;
    }

    final id = blocks.docs.first.id;
    print('🎯 [Repo] activeBlockId from Firestore = $id');

    return id;
  }

}



class BlockMeta {
  final DateTime startDate;
  final DateTime endDate;
  final List<String> selectedDays;

  BlockMeta({
    required this.startDate,
    required this.endDate,
    required this.selectedDays,
  });
}
