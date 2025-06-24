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
