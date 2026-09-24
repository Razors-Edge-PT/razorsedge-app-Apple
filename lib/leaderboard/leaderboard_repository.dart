/// Reads the server-ranked leaderboard.
///
/// ── Server-side ranking ─────────────────────────────────────────────────────
/// `leaderboards/{periodKey}/entries` is ordered BY FIRESTORE:
///   totalPointsUnits desc, tieBreakDateKey asc (the day the total was
///   reached — earlier wins), uid asc
/// so equal totals always rank the same way and the client never sorts a
/// whole list. Rows with no points are excluded by the query. Pages are
/// cursor-based (startAfterDocument); ranks continue across pages.
///
/// Backed by the composite index in firestore.indexes.json. Reads go through
/// Firestore's own persistence, so a leaderboard seen once still opens
/// offline (the page then reports [LeaderboardPageResult.isFromCache]).
library;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'leaderboard_models.dart';

class LeaderboardRepository {
  LeaderboardRepository(
      {FirebaseFirestore? firestore, DateTime Function()? clock})
      : _db = firestore ?? FirebaseFirestore.instance,
        _clock = clock ?? DateTime.now;

  final FirebaseFirestore _db;
  final DateTime Function() _clock;

  /// First page size. Later pages use the same.
  static const int pageSize = 50;

  /// The period key [period] resolves to right now.
  String periodKey(LeaderboardPeriod period) => periodKeyFor(period, _clock());

  Query<Map<String, dynamic>> _query(String key) => _db
      .collection('leaderboards')
      .doc(key)
      .collection('entries')
      .where('totalPointsUnits', isGreaterThan: 0)
      .orderBy('totalPointsUnits', descending: true)
      .orderBy('tieBreakDateKey')
      .orderBy('uid');

  /// One page of [period]. [after] is the previous page's cursor; [startRank]
  /// is the rank of its first row.
  Future<LeaderboardPageResult> fetchPage(
    LeaderboardPeriod period, {
    Object? after,
    int startRank = 1,
    int limit = pageSize,
  }) async {
    Query<Map<String, dynamic>> q = _query(periodKey(period)).limit(limit);
    if (after is DocumentSnapshot) q = q.startAfterDocument(after);
    final QuerySnapshot<Map<String, dynamic>> snap = await q.get();
    final List<LeaderboardEntry> entries = <LeaderboardEntry>[];
    int rank = startRank;
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs) {
      final LeaderboardEntry? e =
          LeaderboardEntry.fromMap(doc.id, doc.data(), rank: rank);
      if (e == null) continue;
      entries.add(e);
      rank += 1;
    }
    return LeaderboardPageResult(
      entries: entries,
      hasMore: snap.docs.length == limit,
      cursor: snap.docs.isEmpty ? after : snap.docs.last,
      isFromCache: snap.metadata.isFromCache,
    );
  }
}
