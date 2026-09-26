/// Category medals of one leaderboard board (a month or all time).
///
/// Allocated ENTIRELY by the server (functions/leaderboard/medals.js) into
/// `leaderboardMedals/{periodKey}`: per RE category up to three winners —
/// gold, silver, bronze — each a uid, a place, the category score in integer
/// units and the date it was reached. The app never ranks or allocates; it
/// only attaches each award to the already-loaded row with the same uid, so a
/// renamed athlete keeps their medals without any reallocation.
library;

import '../profile/core/re_catalog.dart';
import 'leaderboard_models.dart';

/// Placement, communicated by the metal.
enum MedalTier { gold, silver, bronze }

extension MedalTierLabel on MedalTier {
  String get label => switch (this) {
        MedalTier.gold => 'Gold',
        MedalTier.silver => 'Silver',
        MedalTier.bronze => 'Bronze',
      };

  static MedalTier? ofPlace(Object? place) => switch (place) {
        1 => MedalTier.gold,
        2 => MedalTier.silver,
        3 => MedalTier.bronze,
        _ => null,
      };
}

/// The two-letter code engraved on a category's medal, in display order.
const Map<String, String> kMedalCategoryCodes = <String, String>{
  ReCategoryKey.horizontalPress: 'BP',
  ReCategoryKey.verticalPull: 'VP',
  ReCategoryKey.overheadPress: 'OH',
  ReCategoryKey.hipHinge: 'DL',
  ReCategoryKey.squatPattern: 'SQ',
};

/// Collection of the public snapshots.
const String kLeaderboardMedalsCollection = 'leaderboardMedals';

/// One award.
class LeaderboardMedal {
  const LeaderboardMedal({
    required this.uid,
    required this.tier,
    required this.categoryKey,
    required this.pointsUnits,
    required this.periodKey,
    this.achievedDateKey,
    this.exerciseId,
    this.recordDateKey,
  });

  final String uid;
  final MedalTier tier;

  /// A [ReCategoryKey].
  final String categoryKey;

  /// The category score it was awarded for, in 1/10,000 points.
  final int pointsUnits;

  /// 'YYYY-MM' or [kAllTimePeriodKey].
  final String periodKey;
  final String? achievedDateKey;

  /// All time only: the winning record's exercise and date.
  final String? exerciseId;
  final String? recordDateKey;

  bool get isAllTime => periodKey == kAllTimePeriodKey;
  int get place => tier.index + 1;
  String get code => kMedalCategoryCodes[categoryKey] ?? '?';
  String get categoryName =>
      reCategoryByKey(categoryKey)?.displayName ?? categoryKey;
  String get pointsLabel => formatRePointUnits(pointsUnits);

  /// The full, unambiguous description a screen reader announces.
  String get semanticsLabel =>
      '${tier.label} medal, $categoryName, $pointsLabel '
      '${isAllTime ? 'all-time best' : 'monthly'} RE Points';
}

/// Every award of one board, indexed by uid.
class LeaderboardMedals {
  LeaderboardMedals._(this.periodKey, this._byUid,
      {this.revision, this.isFromCache = false});

  /// A board with no awards (no snapshot yet, or nothing scored).
  factory LeaderboardMedals.empty(String periodKey,
          {bool isFromCache = false}) =>
      LeaderboardMedals._(periodKey, const <String, List<LeaderboardMedal>>{},
          isFromCache: isFromCache);

  final String periodKey;
  final int? revision;
  final bool isFromCache;
  final Map<String, List<LeaderboardMedal>> _byUid;

  bool get isEmpty => _byUid.isEmpty;

  /// [uid]'s medals in the fixed category order BP, VP, OH, DL, SQ.
  List<LeaderboardMedal> forUid(String uid) =>
      _byUid[uid] ?? const <LeaderboardMedal>[];

  /// Parses `leaderboardMedals/{periodKey}`. Anything malformed is dropped
  /// award by award; an absent or foreign document is an empty board.
  static LeaderboardMedals fromMap(String periodKey, Map<String, dynamic>? d,
      {bool isFromCache = false}) {
    if (d == null ||
        d['schema'] != 'leaderboardMedals' ||
        (d['periodKey'] != null && d['periodKey'] != periodKey)) {
      return LeaderboardMedals.empty(periodKey, isFromCache: isFromCache);
    }
    final Object? cats = d['categories'];
    final Map<String, List<LeaderboardMedal>> byUid =
        <String, List<LeaderboardMedal>>{};
    if (cats is Map) {
      for (final String categoryKey in kMedalCategoryCodes.keys) {
        final Object? list = cats[categoryKey];
        if (list is! List) continue;
        final Set<int> places = <int>{};
        final Set<String> uids = <String>{};
        for (final Object? raw in list) {
          if (raw is! Map) continue;
          final Object? uid = raw['uid'];
          final MedalTier? tier = MedalTierLabel.ofPlace(raw['place']);
          final Object? units = raw['pointsUnits'];
          if (uid is! String || uid.isEmpty || tier == null) continue;
          if (units is! num || !units.isFinite || units <= 0) continue;
          // One medal per place and per athlete in a category.
          if (!places.add(tier.index) || !uids.add(uid)) continue;
          String? str(String k) {
            final Object? v = raw[k];
            return v is String && v.isNotEmpty ? v : null;
          }

          (byUid[uid] ??= <LeaderboardMedal>[]).add(LeaderboardMedal(
            uid: uid,
            tier: tier,
            categoryKey: categoryKey,
            pointsUnits: units.round(),
            periodKey: periodKey,
            achievedDateKey: str('achievedDateKey'),
            exerciseId: str('exerciseId'),
            recordDateKey: str('recordDateKey'),
          ));
        }
      }
    }
    final Object? rev = d['revision'];
    return LeaderboardMedals._(
      periodKey,
      <String, List<LeaderboardMedal>>{
        for (final MapEntry<String, List<LeaderboardMedal>> e in byUid.entries)
          e.key: List<LeaderboardMedal>.unmodifiable(e.value),
      },
      revision: rev is int ? rev : null,
      isFromCache: isFromCache,
    );
  }
}

const List<String> _shortMonths = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "12 Sep 2026" for 'YYYY-MM-DD'; null when malformed.
String? describeDateKey(String? key) {
  if (key == null) return null;
  final List<String> p = key.split('-');
  if (p.length != 3) return null;
  final int? y = int.tryParse(p[0]);
  final int? m = int.tryParse(p[1]);
  final int? d = int.tryParse(p[2]);
  if (y == null || m == null || d == null || m < 1 || m > 12) return null;
  return '$d ${_shortMonths[m - 1]} $y';
}
