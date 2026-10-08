/// Immutable leaderboard models.
///
/// Entries are server-derived (functions/leaderboard): each carries the
/// athlete's uid, a minimal identity snapshot (username, avatar URL) and a
/// total in integer units of 1/10,000 RE Point. Units are converted to a
/// display value here and nowhere earlier, so no client ever adds floats.
library;

import '../profile/core/re_catalog.dart' show reExerciseById;
import '../profile/data/identity_repository.dart' show kUnknownAthleteName;

/// 1 RE Point = 10,000 units (functions/leaderboard/reducer.js POINT_UNITS).
const int kRePointUnits = 10000;

/// Period key of the all-time leaderboard.
const String kAllTimePeriodKey = 'all_time';

/// The two periods the app shows. Historical months are kept server-side but
/// not browsable yet.
enum LeaderboardPeriod { thisMonth, allTime }

/// Ephemeral presentation choice; never a profile or stored preference.
enum LeaderboardSexFilter { all, male, female }

extension LeaderboardSexFilterLabel on LeaderboardSexFilter {
  String get label => switch (this) {
        LeaderboardSexFilter.all => 'All',
        LeaderboardSexFilter.male => 'Male',
        LeaderboardSexFilter.female => 'Female',
      };
}

/// The age model the optional age-adjusted view reads
/// (functions/leaderboard/age.js AGE_MODEL_VERSION). Entries and boards
/// written under any other version are never shown.
const String kAgeModelVersion = 'goodlift-age-usapl-2026-10-v1';

/// Server-written age view (functions/leaderboard/age_firestore.js).
const String kLeaderboardsAgeCollection = 'leaderboardsAge';

/// Per-board extras of the age projection: the athletes with the raw-board
/// silver achievement and the age view's counts. Only uids — never a birth
/// date, an age or a band.
class LeaderboardBoardInfo {
  const LeaderboardBoardInfo({
    this.silverUids = const <String>{},
    this.rankedCount,
    this.incompleteCount,
    this.isFromCache = false,
  });

  /// Raw-board silver (strictly older than 60, strictly above 280 all-time or
  /// 2,000 monthly raw points), computed server-side.
  final Set<String> silverUids;

  /// Athletes ranked in the age view, and those left out of it because their
  /// required data (a valid birth date) is missing.
  final int? rankedCount;
  final int? incompleteCount;
  final bool isFromCache;

  static const LeaderboardBoardInfo empty = LeaderboardBoardInfo();

  /// Parses `leaderboardsAge/{periodKey}`; anything from another model
  /// version counts as nothing.
  static LeaderboardBoardInfo fromMap(Map<String, dynamic>? d,
      {bool isFromCache = false}) {
    if (d == null || d['ageModelVersion'] != kAgeModelVersion) {
      return LeaderboardBoardInfo(isFromCache: isFromCache);
    }
    int? count(String k) {
      final Object? v = d[k];
      return v is num && v.isFinite && v >= 0 ? v.round() : null;
    }

    final Object? raw = d['silverUids'];
    return LeaderboardBoardInfo(
      silverUids: raw is List
          ? <String>{
              for (final Object? u in raw)
                if (u is String && u.isNotEmpty) u
            }
          : const <String>{},
      rankedCount: count('rankedCount'),
      incompleteCount: count('incompleteCount'),
      isFromCache: isFromCache,
    );
  }
}

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

/// One exercise's share of a monthly category total: the RE Points of the
/// training days on which it won that category's daily score, and how many
/// such days (shown as "sessions"). Server-derived
/// (functions/leaderboard/reducer.js categoryExerciseBreakdown).
class MonthlyExerciseContribution {
  const MonthlyExerciseContribution({
    required this.exerciseId,
    required this.displayName,
    required this.pointsUnits,
    required this.sessionCount,
  });

  final String? exerciseId;
  final String displayName;

  /// In 1/10,000 points.
  final int pointsUnits;
  final int sessionCount;

  String get pointsLabel => formatRePointUnits(pointsUnits);

  String get sessionsLabel =>
      '$sessionCount ${sessionCount == 1 ? 'session' : 'sessions'}';

  /// "Bench Press, Barbell — 1000.00 RE pts · 13 sessions".
  String get label => '$displayName — $pointsLabel RE pts · $sessionsLabel';

  /// Parses one row, or null when it is unusable.
  static MonthlyExerciseContribution? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['exerciseId'];
    final Object? name = raw['displayName'];
    final Object? units = raw['pointsUnits'];
    final Object? sessions = raw['sessionCount'];
    if (units is! num || !units.isFinite || units <= 0) return null;
    if (sessions is! num || !sessions.isFinite || sessions < 1) return null;
    final String? exerciseId = id is String && id.isNotEmpty ? id : null;
    // The app's catalogue name wins; the server's copy is the fallback.
    final String? resolved =
        exerciseId == null ? null : reExerciseById(exerciseId)?.displayName;
    final String? stored =
        name is String && name.trim().isNotEmpty ? name.trim() : null;
    final String? displayName = resolved ?? stored;
    if (displayName == null) return null;
    return MonthlyExerciseContribution(
      exerciseId: exerciseId,
      displayName: displayName,
      pointsUnits: units.round(),
      sessionCount: sessions.round(),
    );
  }
}

/// Parses `categoryExerciseBreakdown`; null when the entry predates it.
Map<String, List<MonthlyExerciseContribution>>? parseCategoryBreakdown(
    Object? raw) {
  if (raw is! Map) return null;
  final Map<String, List<MonthlyExerciseContribution>> out =
      <String, List<MonthlyExerciseContribution>>{};
  for (final MapEntry<Object?, Object?> e in raw.entries) {
    final Object? key = e.key;
    final Object? rows = e.value;
    if (key is! String || rows is! List) continue;
    final List<MonthlyExerciseContribution> parsed =
        <MonthlyExerciseContribution>[
      for (final Object? r in rows)
        if (MonthlyExerciseContribution.fromMap(r)
            case final MonthlyExerciseContribution c)
          c,
    ];
    // The server's order, re-applied: points descending, then name.
    parsed.sort(
        (MonthlyExerciseContribution a, MonthlyExerciseContribution b) =>
            b.pointsUnits != a.pointsUnits
                ? b.pointsUnits.compareTo(a.pointsUnits)
                : a.displayName.compareTo(b.displayName));
    out[key] = List<MonthlyExerciseContribution>.unmodifiable(parsed);
  }
  return Map<String, List<MonthlyExerciseContribution>>.unmodifiable(out);
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
    this.categoryBreakdown,
    this.ageAdjusted = false,
    this.rawPointsUnits,
  });

  final String uid;

  /// 1-based ordinal position in the server's deterministic order
  /// (points desc, earlier tieBreakDateKey, then uid).
  final int rank;
  final int totalPointsUnits;
  final String? username;
  final String? photoURL;
  final String? tieBreakDateKey;

  /// Monthly entries only: per category, the exercises its total came from.
  /// Null for all time and for monthly entries written before it existed.
  final Map<String, List<MonthlyExerciseContribution>>? categoryBreakdown;

  /// A row of the optional age-adjusted view: [totalPointsUnits] is then the
  /// ADJUSTED total and [rawPointsUnits] the athlete's raw total.
  final bool ageAdjusted;
  final int? rawPointsUnits;

  /// [categoryKey]'s contributions, or null when this entry has none recorded.
  List<MonthlyExerciseContribution>? contributionsFor(String categoryKey) {
    final Map<String, List<MonthlyExerciseContribution>>? b = categoryBreakdown;
    if (b == null) return null;
    return b[categoryKey] ?? const <MonthlyExerciseContribution>[];
  }

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
      categoryBreakdown: parseCategoryBreakdown(d['categoryExerciseBreakdown']),
    );
  }
}

/// Parses an age-view entry (`leaderboardsAge/{periodKey}/entries/{uid}`):
/// the adjusted total ranks it. Null when unusable, incomplete or from another
/// age model.
LeaderboardEntry? ageEntryFromMap(String docId, Map<String, dynamic>? d,
    {required int rank}) {
  if (d == null || d['ageModelVersion'] != kAgeModelVersion) return null;
  if (d['ageComplete'] != true) return null;
  final Object? adjusted = d['adjustedTotalUnits'];
  if (adjusted is! num || !adjusted.isFinite || adjusted <= 0) return null;
  final Object? raw = d['rawTotalPointsUnits'];
  final Object? uid = d['uid'];
  String? str(String k) {
    final Object? v = d[k];
    return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
  }

  return LeaderboardEntry(
    uid: (uid is String && uid.isNotEmpty) ? uid : docId,
    rank: rank,
    totalPointsUnits: adjusted.round(),
    username: str('username'),
    photoURL: str('photoURL'),
    tieBreakDateKey: str('tieBreakDateKey'),
    ageAdjusted: true,
    rawPointsUnits: raw is num && raw.isFinite ? raw.round() : null,
  );
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
