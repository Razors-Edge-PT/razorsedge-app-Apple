/// Reads the server-ranked leaderboard.
///
/// ── Server-side ranking ─────────────────────────────────────────────────────
/// `leaderboards/{periodKey}/entries` is ordered BY FIRESTORE:
///   totalPointsUnits desc, tieBreakDateKey asc (the day the total was
///   reached — earlier wins), uid asc
/// so equal totals always rank the same way and the client never sorts a
/// whole list. Rows with no points are excluded by the query. The app shows
/// only the top [LeaderboardRepository.boardSize] of each board; pages are
/// cursor-based (startAfterDocument) and ranks continue across pages.
///
/// Backed by the composite index in firestore.indexes.json. Reads go through
/// Firestore's own persistence, so a leaderboard seen once still opens
/// offline (the page then reports [LeaderboardPageResult.isFromCache]).
library;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../profile/core/showcase_v2_models.dart';
import '../profile/ui/record_presentation.dart';
import '../profile/ui/units.dart';
import '../units/exercise_unit_registry.dart';
import '../units/weight_unit.dart';
import 'leaderboard_medals.dart';
import 'leaderboard_models.dart';

class LeaderboardRepository {
  LeaderboardRepository(
      {FirebaseFirestore? firestore, DateTime Function()? clock})
      : _db = firestore ?? FirebaseFirestore.instance,
        _clock = clock ?? DateTime.now;

  final FirebaseFirestore _db;
  final DateTime Function() _clock;

  /// Default page size for [fetchPage].
  static const int pageSize = 50;

  /// Both boards (This Month and All Time) show ranks 1–[boardSize] only:
  /// the app never queries or shows a row below it. Server data is untouched.
  static const int boardSize = 20;

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

  /// The top [limit] of [period]'s optional AGE-ADJUSTED view: every eligible
  /// athlete is ranked server-side (adjusted total desc, the raw tie date,
  /// uid) and only complete entries of the current age model are queried — the
  /// raw top 20 is never re-sorted locally.
  Future<LeaderboardPageResult> fetchAgePage(LeaderboardPeriod period,
      {int limit = boardSize}) async {
    final QuerySnapshot<Map<String, dynamic>> snap = await _db
        .collection(kLeaderboardsAgeCollection)
        .doc(periodKey(period))
        .collection('entries')
        .where('ageModelVersion', isEqualTo: kAgeModelVersion)
        .where('ageComplete', isEqualTo: true)
        .orderBy('adjustedTotalUnits', descending: true)
        .orderBy('tieBreakDateKey')
        .orderBy('uid')
        .limit(limit)
        .get();
    final List<LeaderboardEntry> entries = <LeaderboardEntry>[];
    int rank = 1;
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs) {
      final LeaderboardEntry? e =
          ageEntryFromMap(doc.id, doc.data(), rank: rank);
      if (e == null) continue;
      entries.add(e);
      rank += 1;
    }
    return LeaderboardPageResult(
      entries: entries,
      hasMore: false,
      isFromCache: snap.metadata.isFromCache,
    );
  }

  /// Server-generated top 20 of the selected sex, across the full ranked
  /// pool. One document; no filtering of the overall top 20, private profile
  /// reads, new indexes or client-side scoring. Published hourly with the web.
  Future<LeaderboardPageResult> fetchSexPage(
    LeaderboardPeriod period,
    LeaderboardSexFilter sex, {
    bool ageAdjusted = false,
    int limit = boardSize,
  }) async {
    if (sex == LeaderboardSexFilter.all) {
      return ageAdjusted
          ? fetchAgePage(period, limit: limit)
          : fetchPage(period, limit: limit);
    }
    final String key = periodKey(period);
    final DocumentSnapshot<Map<String, dynamic>> snap = await _db
        .collection(ageAdjusted ? kLeaderboardsAgeCollection : 'leaderboards')
        .doc('${key}_${sex.name}')
        .get();
    final Map<String, dynamic>? data = snap.data();
    final Object? rows = data?['entries'];
    if (data == null ||
        data['sexBoardSchemaVersion'] != 1 ||
        data['periodKey'] != key ||
        data['sexFilter'] != sex.name ||
        data['view'] != (ageAdjusted ? 'age' : 'raw') ||
        rows is! List ||
        rows.length > boardSize ||
        (ageAdjusted && data['ageModelVersion'] != kAgeModelVersion)) {
      throw StateError('Sex-filtered leaderboard unavailable');
    }
    final DateTime? generatedAt = DateTime.tryParse(
      data['generatedAt'] is String ? data['generatedAt'] as String : '',
    );
    // Seen-once boards remain available offline, matching the normal board.
    if (generatedAt == null ||
        (!snap.metadata.isFromCache &&
            _clock().difference(generatedAt).inMinutes > 150)) {
      throw StateError('Sex-filtered leaderboard needs an update');
    }
    final List<LeaderboardEntry> entries = <LeaderboardEntry>[];
    for (final Object? row in rows.take(limit)) {
      if (row is! Map) throw StateError('Invalid leaderboard row');
      final Map<String, dynamic> fields = Map<String, dynamic>.from(row);
      final Object? uid = fields['uid'];
      if (uid is! String || uid.isEmpty) throw StateError('Invalid athlete');
      final LeaderboardEntry? entry = ageAdjusted
          ? ageEntryFromMap(uid, fields, rank: entries.length + 1)
          : LeaderboardEntry.fromMap(uid, fields, rank: entries.length + 1);
      if (entry == null) throw StateError('Invalid leaderboard score');
      entries.add(entry);
    }
    return LeaderboardPageResult(
      entries: entries,
      hasMore: false,
      isFromCache: snap.metadata.isFromCache,
    );
  }

  /// [period]'s board extras: the raw-board silver set and the age view's
  /// counts. ONE small server-written document.
  Future<LeaderboardBoardInfo> fetchBoardInfo(LeaderboardPeriod period) async {
    final DocumentSnapshot<Map<String, dynamic>> snap = await _db
        .collection(kLeaderboardsAgeCollection)
        .doc(periodKey(period))
        .get();
    return LeaderboardBoardInfo.fromMap(snap.data(),
        isFromCache: snap.metadata.isFromCache);
  }

  /// The category medals of [period]: ONE small server-written document per
  /// board. Like the entries it goes through Firestore's persistence, so a
  /// board's medals seen once are still shown offline.
  Future<LeaderboardMedals> fetchMedals(LeaderboardPeriod period) async {
    final String key = periodKey(period);
    final DocumentSnapshot<Map<String, dynamic>> snap =
        await _db.collection(kLeaderboardMedalsCollection).doc(key).get();
    return LeaderboardMedals.fromMap(key, snap.data(),
        isFromCache: snap.metadata.isFromCache);
  }

  /// "Bench Press, Barbell — 158.5 kg × 9" for an all-time [medal], from the
  /// medallist's PUBLIC profile showcase (in the owner's unit) — or null when
  /// that record is not published or no longer the one the medal names.
  Future<String?> fetchMedalRecordSource(LeaderboardMedal medal) async {
    final String? exerciseId = medal.exerciseId;
    if (!medal.isAllTime || exerciseId == null) return null;
    final Map<String, dynamic>? pub =
        (await _db.collection('users_public').doc(medal.uid).get()).data();
    final ProfileShowcaseV2? showcase =
        ProfileShowcaseV2.fromMap(pub?['profileShowcaseV2']);
    if (showcase == null) return null;
    for (final category in showcase.categories) {
      for (final e in category.exercises) {
        if (e.exercise.exerciseId != exerciseId) continue;
        final record = e.pointsRecord;
        final double? points = e.rePoints;
        if (record == null || points == null) return null;
        // The medal's own record only — never a newer, different one.
        if ((points * kRePointUnits).round() != medal.pointsUnits) return null;
        final ExerciseWeightUnit unit = ExerciseUnits.parsePublished(
                pub?['exerciseWeightUnits'])[exerciseId] ??
            ExerciseWeightUnit.kg;
        return presentShowcaseRecord(
                record: record, isE1rm: false, units: WeightUnits.of(unit))
            .source;
      }
    }
    return null;
  }
}
