// The Silverback (raw-board silver) row treatment and the All Time board's
// category medals (lib/leaderboard): a silver row has a faint tint with no
// outline and "Silverback -" left of "RE pts"; All Time shows its own
// all-time awards, and a board's medals are read again when it is re-selected
// or the app resumes, so an empty first snapshot never sticks for a session.

import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_controller.dart';
import 'package:localtest222/leaderboard/leaderboard_medals.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
import 'package:localtest222/leaderboard/medal_badge.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/buddy_repository.dart';

const String kMe = 'me';
final DateTime kNow = DateTime(2026, 10, 20, 10);
const String kMonth = '2026-10';
const String kFormula = 'lb2-agg2-re3-e1rm1';

class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

/// Counts the raw row queries, to show a medal reload never refetches rows.
class _CountingRepo extends LeaderboardRepository {
  _CountingRepo(FakeFirebaseFirestore db)
      : super(firestore: db, clock: () => kNow);

  final List<LeaderboardPeriod> pages = <LeaderboardPeriod>[];
  final List<LeaderboardPeriod> medalReads = <LeaderboardPeriod>[];

  @override
  Future<LeaderboardPageResult> fetchPage(LeaderboardPeriod period,
      {Object? after,
      int startRank = 1,
      int limit = LeaderboardRepository.pageSize}) {
    pages.add(period);
    return super
        .fetchPage(period, after: after, startRank: startRank, limit: limit);
  }

  @override
  Future<LeaderboardMedals> fetchMedals(LeaderboardPeriod period) {
    medalReads.add(period);
    return super.fetchMedals(period);
  }
}

Future<void> seedEntry(
        FakeFirebaseFirestore db, String period, String uid, int units) =>
    db
        .collection('leaderboards')
        .doc(period)
        .collection('entries')
        .doc(uid)
        .set(<String, Object?>{
      'uid': uid,
      'username': 'name-$uid',
      'totalPointsUnits': units,
      'tieBreakDateKey': '2026-10-05',
    });

Map<String, Object?> award(String uid, int place, int units,
        {String? exerciseId}) =>
    <String, Object?>{
      'uid': uid,
      'place': place,
      'pointsUnits': units,
      'achievedDateKey': '2026-10-05',
      if (exerciseId != null) 'exerciseId': exerciseId,
      if (exerciseId != null) 'recordDateKey': '2026-10-05',
    };

Future<void> seedMedals(FakeFirebaseFirestore db, String period,
        Map<String, List<Object?>> categories) =>
    db.collection(kLeaderboardMedalsCollection).doc(period).set(
      <String, Object?>{
        'schema': 'leaderboardMedals',
        'schemaVersion': 1,
        'periodKey': period,
        'boardType': period == kAllTimePeriodKey ? 'allTime' : 'month',
        'formulaVersion': kFormula,
        'revision': 1,
        'categories': <String, Object?>{
          for (final String k in kMedalCategoryCodes.keys)
            k: categories[k] ?? <Object?>[],
        },
      },
    );

Future<void> seedSilver(
        FakeFirebaseFirestore db, String period, List<String> uids) =>
    db.collection(kLeaderboardsAgeCollection).doc(period).set(
      <String, Object?>{
        'ageModelVersion': kAgeModelVersion,
        'silverUids': uids,
        'rankedCount': 3,
        'incompleteCount': 0,
      },
    );

/// This Month: a, b, c — all time: a, b, c, d. The awards differ per board,
/// and `d` (silver on All Time only) holds no all-time medal.
Future<void> seedBoards(FakeFirebaseFirestore db,
    {bool allTimeMedals = true}) async {
  await seedEntry(db, kMonth, 'a', 3000000);
  await seedEntry(db, kMonth, 'b', 2000000);
  await seedEntry(db, kMonth, 'c', 1000000);
  await seedEntry(db, kAllTimePeriodKey, 'c', 5000000);
  await seedEntry(db, kAllTimePeriodKey, 'a', 4000000);
  await seedEntry(db, kAllTimePeriodKey, 'b', 3500000);
  await seedEntry(db, kAllTimePeriodKey, 'd', 2957300);
  await seedMedals(db, kMonth, <String, List<Object?>>{
    'horizontalPress': <Object?>[award('a', 1, 900000), award('b', 2, 800000)],
    'hipHinge': <Object?>[award('a', 1, 700000)],
  });
  await seedMedals(
      db,
      kAllTimePeriodKey,
      allTimeMedals
          ? <String, List<Object?>>{
              'squatPattern': <Object?>[
                award('c', 1, 1487840, exerciseId: 'sq'),
                award('b', 2, 792586, exerciseId: 'sq'),
              ],
              'verticalPull': <Object?>[
                award('c', 1, 905557, exerciseId: 'vp'),
              ],
              'overheadPress': <Object?>[
                award('c', 1, 918872, exerciseId: 'oh'),
              ],
            }
          : <String, List<Object?>>{});
  await seedSilver(db, kMonth, <String>[]);
  await seedSilver(db, kAllTimePeriodKey, <String>['d']);
}

Finder row(String uid) => find.byKey(ValueKey<String>('leaderboard-row-$uid'));
Finder silver(String uid) =>
    find.byKey(ValueKey<String>('leaderboard-silver-$uid'));
Finder silverbackLabel(String uid) =>
    find.byKey(ValueKey<String>('leaderboard-silverback-label-$uid'));
Finder medalsOf(String uid) =>
    find.descendant(of: row(uid), matching: find.byType(MedalButton));

List<String> medalLabels(WidgetTester tester, String uid) => tester
    .widgetList<MedalButton>(medalsOf(uid))
    .map((MedalButton b) =>
        '${b.medal.tier.name}:${b.medal.code}:${b.medal.periodKey}')
    .toList();

Future<LeaderboardController> pumpBoard(
    WidgetTester tester, FakeFirebaseFirestore db,
    {LeaderboardRepository? repository}) async {
  tester.view.physicalSize = const Size(420, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await db.collection('socialGraph').doc(kMe).set(<String, Object?>{
    'friends': <String>['a', 'b', 'c', 'd']
  });
  final LeaderboardController c = LeaderboardController(
      repository: repository ??
          LeaderboardRepository(firestore: db, clock: () => kNow));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: LeaderboardView(
          controller: c,
          buddies: BuddyRepository(firestore: db, overrideUid: kMe),
          onOpenProfile: (_) {},
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return c;
}

Future<void> choose(WidgetTester tester, LeaderboardPeriod p) async {
  await tester
      .tap(find.byKey(ValueKey<String>('leaderboard-period-${p.name}')));
  await tester.pumpAndSettle();
}

Future<void> chooseAgeView(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('leaderboard-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Age-adjusted view'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => profileImageStore = _AbsentStore());

  group('Silverback row', () {
    test('the decoration has no outline and only a faint tint', () {
      expect(kSilverRowDecoration.border, isNull);
      expect(kSilverRowDecoration.boxShadow, isNull);
      expect(kSilverRowDecoration.color, isNull);
      final LinearGradient g = kSilverRowDecoration.gradient! as LinearGradient;
      for (final Color c in g.colors) {
        expect(c.a, lessThanOrEqualTo(0.12),
            reason: 'a tint over the dark row, never an opaque panel');
        expect(c.a, greaterThan(0), reason: 'still distinguishable');
      }
    });

    testWidgets('"Silverback -" sits under the points, left of "RE pts"',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoards(db);
      final LeaderboardController c = await pumpBoard(tester, db);
      await choose(tester, LeaderboardPeriod.allTime);

      expect(silver('d'), findsOneWidget);
      final DecoratedBox box = tester.widget<DecoratedBox>(silver('d'));
      expect((box.decoration as BoxDecoration).border, isNull);

      expect(silverbackLabel('d'), findsOneWidget);
      expect(tester.widget<Text>(silverbackLabel('d')).data, 'Silverback -');
      final Finder unit =
          find.descendant(of: row('d'), matching: find.text('RE pts'));
      final Finder score =
          find.descendant(of: row('d'), matching: find.text('295.73'));
      expect(unit, findsOneWidget);
      expect(score, findsOneWidget);
      final Rect label = tester.getRect(silverbackLabel('d'));
      final Rect units = tester.getRect(unit);
      final Rect points = tester.getRect(score);
      expect(label.right, lessThanOrEqualTo(units.left),
          reason: 'immediately left of RE pts');
      expect(units.left - label.right, lessThan(12));
      expect(label.center.dy, moreOrLessEquals(units.center.dy, epsilon: 0.5),
          reason: 'the same metadata line');
      expect(label.top, greaterThanOrEqualTo(points.bottom - 0.5),
          reason: 'under the numerical score');
      expect(units.right, moreOrLessEquals(points.right, epsilon: 0.5),
          reason: 'RE pts keeps its right-hand position');
      // The same muted caption as RE pts: no badge, chip or emphasis.
      final TextStyle a = tester.widget<Text>(silverbackLabel('d')).style!;
      final TextStyle b = tester.widget<Text>(unit).style!;
      expect(a.color, b.color);
      expect(a.fontSize, b.fontSize);
      expect(a.fontWeight, b.fontWeight);
      c.dispose();
    });

    testWidgets('no label or tint for athletes without the achievement',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoards(db);
      final LeaderboardController c = await pumpBoard(tester, db);
      // This Month: nobody is silver.
      expect(find.text('Silverback -'), findsNothing);
      for (final String uid in <String>['a', 'b', 'c']) {
        expect(silver(uid), findsNothing);
      }
      await choose(tester, LeaderboardPeriod.allTime);
      expect(find.text('Silverback -'), findsOneWidget);
      for (final String uid in <String>['a', 'b', 'c']) {
        expect(silver(uid), findsNothing);
        expect(silverbackLabel(uid), findsNothing);
      }
      c.dispose();
    });

    testWidgets('never in the age-adjusted view', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoards(db);
      await db
          .collection(kLeaderboardsAgeCollection)
          .doc(kAllTimePeriodKey)
          .collection('entries')
          .doc('d')
          .set(<String, Object?>{
        'uid': 'd',
        'username': 'name-d',
        'ageModelVersion': kAgeModelVersion,
        'ageComplete': true,
        'adjustedTotalUnits': 4000000,
        'rawTotalPointsUnits': 2957300,
        'tieBreakDateKey': '2026-10-05',
      });
      final LeaderboardController c = await pumpBoard(tester, db);
      await choose(tester, LeaderboardPeriod.allTime);
      expect(silverbackLabel('d'), findsOneWidget);
      await chooseAgeView(tester);
      expect(c.ageView, isTrue);
      expect(row('d'), findsOneWidget);
      expect(silver('d'), findsNothing);
      expect(find.text('Silverback -'), findsNothing);
      expect(find.text('adj. RE pts'), findsWidgets);
      c.dispose();
    });

    testWidgets(
        'a long name, Requested, five medals and silver fit a narrow phone',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      LeaderboardMedal medal(String category, MedalTier tier) =>
          LeaderboardMedal(
              uid: 'd',
              tier: tier,
              categoryKey: category,
              pointsUnits: 1000000,
              periodKey: kAllTimePeriodKey);
      const LeaderboardEntry entry = LeaderboardEntry(
        uid: 'd',
        rank: 10,
        totalPointsUnits: 2957300,
        username: 'The_Dragon_With_A_Very_Long_Username_Indeed',
        photoURL: 'https://example.invalid/p.jpg',
      );
      Widget host(bool isSilver) => MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: LeaderboardRow(
                  entry: entry,
                  onTap: null,
                  silver: isSilver,
                  action: LeaderboardRowAction.requested,
                  medals: <LeaderboardMedal>[
                    for (final String k in kMedalCategoryCodes.keys)
                      medal(k, MedalTier.gold),
                  ],
                ),
              ),
            ),
          );
      await tester.pumpWidget(host(false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final double plainHeight = tester.getSize(find.byType(LeaderboardRow)).height;

      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(MedalButton), findsNWidgets(5));
      expect(find.text('Requested'), findsOneWidget);
      expect(find.text('Silverback -'), findsOneWidget);
      expect(tester.getSize(find.byType(LeaderboardRow)).height, plainHeight,
          reason: 'the label does not change the row height');
      final Rect rowRect = tester.getRect(find.byType(LeaderboardRow));
      for (final Element e in find.byType(MedalButton).evaluate()) {
        final Rect r = tester.getRect(find.byWidget(e.widget));
        expect(r.left, greaterThanOrEqualTo(rowRect.left));
        expect(r.right, lessThanOrEqualTo(rowRect.right));
        expect(r.width, greaterThan(0));
      }
    });
  });

  group('All Time medals', () {
    testWidgets('All Time shows its own all-time awards; This Month is unchanged',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoards(db);
      final LeaderboardController c = await pumpBoard(tester, db);

      // This Month: the monthly snapshot.
      expect(medalLabels(tester, 'a'),
          <String>['gold:BP:$kMonth', 'gold:DL:$kMonth']);
      expect(medalLabels(tester, 'b'), <String>['silver:BP:$kMonth']);
      expect(medalsOf('c'), findsNothing);

      // All Time: the all-time snapshot, in category order, never the month's.
      await choose(tester, LeaderboardPeriod.allTime);
      expect(medalLabels(tester, 'c'), <String>[
        'gold:VP:all_time',
        'gold:OH:all_time',
        'gold:SQ:all_time',
      ]);
      expect(medalLabels(tester, 'b'), <String>['silver:SQ:all_time']);
      expect(medalsOf('a'), findsNothing,
          reason: "a's monthly medals are not all-time medals");
      expect(medalsOf('d'), findsNothing);
      for (final MedalButton b
          in tester.widgetList<MedalButton>(find.byType(MedalButton))) {
        expect(b.medal.isAllTime, isTrue);
      }
      expect(tester.takeException(), isNull);

      // And back: the month's own awards again.
      await choose(tester, LeaderboardPeriod.thisMonth);
      expect(medalLabels(tester, 'a'),
          <String>['gold:BP:$kMonth', 'gold:DL:$kMonth']);
      expect(medalLabels(tester, 'b'), <String>['silver:BP:$kMonth']);
      c.dispose();
    });

    testWidgets('an all-time medal still opens its detail',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoards(db);
      final LeaderboardController c = await pumpBoard(tester, db);
      await choose(tester, LeaderboardPeriod.allTime);
      await tester.tap(medalsOf('b').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Squat'), findsWidgets);
      expect(tester.takeException(), isNull);
      c.dispose();
    });

    testWidgets(
        'an All Time board first seen without medals gains them when re-selected, '
        'without refetching rows', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoards(db, allTimeMedals: false);
      final _CountingRepo repo = _CountingRepo(db);
      final LeaderboardController c =
          await pumpBoard(tester, db, repository: repo);
      await choose(tester, LeaderboardPeriod.allTime);
      expect(find.byType(MedalButton), findsNothing,
          reason: 'the snapshot was empty when the board was first loaded');

      // The server writes the awards afterwards.
      await seedMedals(db, kAllTimePeriodKey, <String, List<Object?>>{
        'squatPattern': <Object?>[award('c', 1, 1487840, exerciseId: 'sq')],
      });
      await choose(tester, LeaderboardPeriod.thisMonth);
      expect(medalLabels(tester, 'a'),
          <String>['gold:BP:$kMonth', 'gold:DL:$kMonth']);
      await choose(tester, LeaderboardPeriod.allTime);
      expect(medalLabels(tester, 'c'), <String>['gold:SQ:all_time']);
      expect(repo.pages, <LeaderboardPeriod>[
        LeaderboardPeriod.thisMonth,
        LeaderboardPeriod.allTime,
      ], reason: 'rows are loaded once per board');
      c.dispose();
    });

    testWidgets('resuming the app reads the shown board\'s medals again',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoards(db, allTimeMedals: false);
      final _CountingRepo repo = _CountingRepo(db);
      final LeaderboardController c =
          await pumpBoard(tester, db, repository: repo);
      await choose(tester, LeaderboardPeriod.allTime);
      expect(find.byType(MedalButton), findsNothing);
      await seedMedals(db, kAllTimePeriodKey, <String, List<Object?>>{
        'verticalPull': <Object?>[award('a', 1, 905557, exerciseId: 'vp')],
      });
      final int before = repo.medalReads.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(repo.medalReads.sublist(before),
          <LeaderboardPeriod>[LeaderboardPeriod.allTime]);
      expect(medalLabels(tester, 'a'), <String>['gold:VP:all_time']);
      expect(repo.pages.length, 2);
      c.dispose();
    });

    test('a failed reload keeps the medals already shown', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoards(db);
      final _FailingSecondRead repo = _FailingSecondRead(db);
      final LeaderboardController c = LeaderboardController(
          repository: repo, initialPeriod: LeaderboardPeriod.allTime);
      await c.start();
      await Future<void>.delayed(Duration.zero);
      expect(c.medalsFor('c').length, 3);
      await c.reloadMedals();
      expect(repo.reads, 2);
      expect(c.medalsFor('c').length, 3);
      c.dispose();
    });

    test('reloadMedals does nothing before the board has been loaded', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final _CountingRepo repo = _CountingRepo(db);
      final LeaderboardController c = LeaderboardController(repository: repo);
      await c.reloadMedals();
      expect(repo.medalReads, isEmpty);
      c.dispose();
    });
  });
}

class _FailingSecondRead extends LeaderboardRepository {
  _FailingSecondRead(FakeFirebaseFirestore db)
      : super(firestore: db, clock: () => kNow);

  int reads = 0;

  @override
  Future<LeaderboardMedals> fetchMedals(LeaderboardPeriod period) {
    reads += 1;
    if (reads > 1) throw StateError('offline');
    return super.fetchMedals(period);
  }
}
