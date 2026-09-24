/// Immutable leaderboard models.
///
/// Entries are server-derived (functions/leaderboard): each carries the
/// athlete's uid, a minimal identity snapshot (username, avatar URL) and a
/// total in integer units of 1/10,000 RE Point. Units are converted to a
/// display value here and nowhere earlier, so no client ever adds floats.
library;

import '../profile/data/identity_repository.dart' show kUnknownAthleteName;

/// 1 RE Point = 10,000 units (functions/leaderboard/reducer.js POINT_UNITS).
const int kRePointUnits = 10000;

/// Period key of the all-time leaderboard.
const String kAllTimePeriodKey = 'all_time';

/// The two periods the app shows. Historical months are kept server-side but
/// not browsable yet.
enum LeaderboardPeriod { thisMonth, allTime }

extension LeaderboardPeriodLabel on LeaderboardPeriod {
  String get label =>
      this == LeaderboardPeriod.thisMonth ? 'This Month' : 'All Time';
}

/// The `YYYY-MM` key of [now]'s calendar month — the athlete's LOCAL month,
/// matching the local training dates workouts are keyed by.
String monthPeriodKey(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';

/// The period key to query for [period] at [now].
String periodKeyFor(LeaderboardPeriod period, DateTime now) =>
    period == LeaderboardPeriod.allTime
        ? kAllTimePeriodKey
        : monthPeriodKey(now);

/// "1234.56" from integer units. Always two decimals.
String formatRePointUnits(int units) {
  final bool negative = units < 0;
  final int abs = units.abs();
  // Round to hundredths in integers (half up), then format — no float drift.
  final int hundredths = (abs + 50) ~/ 100;
  final String whole = (hundredths ~/ 100).toString();
  final String frac = (hundredths % 100).toString().padLeft(2, '0');
  return '${negative ? '-' : ''}$whole.$frac';
}

const List<String> _months = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "September 2026" for a `YYYY-MM` key; the key itself if malformed.
String describeMonthKey(String key) {
  final List<String> parts = key.split('-');
  if (parts.length != 2) return key;
  final int? y = int.tryParse(parts[0]);
  final int? m = int.tryParse(parts[1]);
  if (y == null || m == null || m < 1 || m > 12) return key;
  return '${_months[m - 1]} $y';
}

/// One ranked row.
class LeaderboardEntry {
  const LeaderboardEntry({
    required this.uid,
    required this.rank,
    required this.totalPointsUnits,
    this.username,
    this.photoURL,
    this.tieBreakDateKey,
  });

  final String uid;

  /// 1-based ordinal position in the server's deterministic order
  /// (points desc, earlier tieBreakDateKey, then uid).
  final int rank;
  final int totalPointsUnits;
  final String? username;
  final String? photoURL;
  final String? tieBreakDateKey;

  String get displayName => (username != null && username!.isNotEmpty)
      ? username!
      : kUnknownAthleteName;

  String get pointsLabel => formatRePointUnits(totalPointsUnits);

  /// Parses an entry document, or returns null when it is unusable.
  static LeaderboardEntry? fromMap(String docId, Map<String, dynamic>? d,
      {required int rank}) {
    if (d == null) return null;
    final Object? total = d['totalPointsUnits'];
    if (total is! num || !total.isFinite) return null;
    final Object? uid = d['uid'];
    String? str(String k) {
      final Object? v = d[k];
      return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
    }

    return LeaderboardEntry(
      uid: (uid is String && uid.isNotEmpty) ? uid : docId,
      rank: rank,
      totalPointsUnits: total.round(),
      username: str('username'),
      photoURL: str('photoURL'),
      tieBreakDateKey: str('tieBreakDateKey'),
    );
  }
}

/// One fetched page.
class LeaderboardPageResult {
  const LeaderboardPageResult({
    required this.entries,
    required this.hasMore,
    this.cursor,
    this.isFromCache = false,
  });

  final List<LeaderboardEntry> entries;
  final bool hasMore;

  /// Opaque: hand back to the repository to fetch the next page.
  final Object? cursor;

  /// True when served from the local Firestore cache (offline).
  final bool isFromCache;
}
