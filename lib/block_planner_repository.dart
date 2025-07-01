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
        .collection('planned_blocks')
        .doc(userId)
        .collection('blocks')
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

    final doc = await _db
        .collection('planned_blocks')
        .doc(user.uid)
        .get();

    if (!doc.exists) {
      print('❌ [Repo] No document found at planned_blocks/${user.uid}');
      return null;
    }

    final id = doc.data()?['activeBlockId'];
    print('🎯 [Repo] activeBlockId from Firestore = $id');

    return id as String?;
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
