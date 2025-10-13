import 'package:cloud_firestore/cloud_firestore.dart';

class LeaderboardService {
  LeaderboardService._();
  static final instance = LeaderboardService._();

  Stream<QuerySnapshot<Map<String, dynamic>>> streamMonthlyTop({int limit = 100}) {
    return FirebaseFirestore.instance
        .collection('users_public')
        .orderBy('rePointsMonthlyCurrent', descending: true)
        .limit(limit)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> streamAllTimeTop({int limit = 100}) {
    return FirebaseFirestore.instance
        .collection('users_public')
        .orderBy('rePoints', descending: true)
        .limit(limit)
        .snapshots();
  }
}
