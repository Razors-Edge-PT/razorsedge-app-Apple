// The optional age-adjusted leaderboard view and the raw-board silver
// achievement (lib/leaderboard): raw is always the default; the menu toggles
// a server-ranked age board; silver appears on raw rows only; and the view
// resets to raw on app background, route pushes, disposal and late results.

import 'dart:async';
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_controller.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
import 'package:localtest222/main.dart' show routeObserver;
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/buddy_repository.dart';

const String kMe = 'me';
final DateTime kNow = DateTime(2026, 10, 20, 10);
const String kMonth = '2026-10';

class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

Future<void> seedRaw(
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

Future<void> seedAge(FakeFirebaseFirestore db, String period, String uid,
        int adjusted, int raw,
        {String model = kAgeModelVersion, bool complete = true}) =>
    db
        .collection(kLeaderboardsAgeCollection)
        .doc(period)
        .collection('entries')
        .doc(uid)
        .set(<String, Object?>{
      'uid': uid,
      'username': 'name-$uid',
      'ageModelVersion': model,
      'ageComplete': complete,
      'adjustedTotalUnits': complete ? adjusted : null,
      'rawTotalPointsUnits': raw,
      'tieBreakDateKey': '2026-10-05',
    });

/// 21 raw athletes: r0 (rank 1) … r20 (rank 21, an older athlete).
Future<void> seedBoards(FakeFirebaseFirestore db) async {
  for (int i = 0; i < 21; i++) {
    final int raw = 3000000 - i * 10000;
    await seedRaw(db, kMonth, 'r$i', raw);
    // r20 is weighted up to first place; r3 has no valid birth date (left out).
    if (i == 3) {
      await seedAge(db, kMonth, 'r$i', 0, raw, complete: false);
    } else {
      await seedAge(db, kMonth, 'r$i', i == 20 ? 4000000 : raw, raw);
    }
  }
  await seedAge(db, kMonth, 'stale', 9999999, 1, model: 'old-model');
  await db
      .collection(kLeaderboardsAgeCollection)
      .doc(kMonth)
      .set(<String, Object?>{
    'ageModelVersion': kAgeModelVersion,
    'silverUids': <String>['r1'],
    'rankedCount': 20,
    'incompleteCount': 1,
  });
}

Finder row(String uid) => find.byKey(ValueKey<String>('leaderboard-row-$uid'));
Finder silver(String uid) =>
    find.byKey(ValueKey<String>('leaderboard-silver-$uid'));
final Finder banner =
    find.byKey(const ValueKey<String>('leaderboard-age-banner'));

Future<LeaderboardController> pumpBoard(
    WidgetTester tester, FakeFirebaseFirestore db,
    {LeaderboardController? controller,
    List<NavigatorObserver> observers = const <NavigatorObserver>[]}) async {
  tester.view.physicalSize = const Size(420, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await db.collection('socialGraph').doc(kMe).set(<String, Object?>{
    'friends': <String>['r0']
  });
  final LeaderboardController c = controller ??
      LeaderboardController(
          repository: LeaderboardRepository(firestore: db, clock: () => kNow));
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: observers,
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

Future<void> chooseAgeView(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('leaderboard-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Age-adjusted view'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => profileImageStore = _AbsentStore());

  testWidgets('raw is the default; silver on raw rows only',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoards(db);
    final LeaderboardController c = await pumpBoard(tester, db);
    expect(c.ageView, isFalse);
    expect(find.text('Total RE Points · October 2026'), findsOneWidget);
    expect(banner, findsNothing);
    expect(row('r0'), findsOneWidget);
    expect(row('r20'), findsNothing, reason: 'raw rank 21 is not shown');
    expect(silver('r1'), findsOneWidget);
    expect(silver('r0'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('silver achievement')), findsOneWidget);
    c.dispose();
  });

  testWidgets('the menu shows the server-ranked age board, clearly labelled',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoards(db);
    final LeaderboardController c = await pumpBoard(tester, db);
    await chooseAgeView(tester);
    expect(c.ageView, isTrue);
    expect(find.text('Age-adjusted RE Points · October 2026'), findsOneWidget);
    expect(banner, findsOneWidget);
    // The website's concise copy: a heading and one line, nothing else.
    expect(
        find.descendant(
            of: banner, matching: find.text('Age-adjusted rankings')),
        findsOneWidget);
    expect(
        find.descendant(
            of: banner,
            matching: find.text("Scores use GoodLift's masters age factors.")),
        findsOneWidget);
    expect(find.descendant(of: banner, matching: find.byType(Text)),
        findsNWidgets(2));
    expect(find.textContaining('not ranked in this view'), findsNothing);
    expect(find.textContaining('Medals are the raw awards'), findsNothing);
    expect(find.textContaining('M1 40'), findsNothing);
    expect(find.textContaining('USA Powerlifting'), findsNothing);
    // The raw rank-21 athlete is first; the incomplete and stale-model ones are absent.
    expect(c.entries.first.uid, 'r20');
    expect(c.entries.first.rank, 1);
    expect(row('r20'), findsOneWidget);
    expect(row('r3'), findsNothing);
    expect(row('stale'), findsNothing);
    expect(find.text('400.00'), findsOneWidget);
    expect(find.text('adj. RE pts'), findsWidgets);
    expect(silver('r1'), findsNothing,
        reason: 'silver never appears in the age view');
    // Social actions keep working on age rows.
    expect(find.byKey(const ValueKey<String>('leaderboard-add-r20')),
        findsOneWidget);
    // Off again from the same menu.
    await chooseAgeView(tester);
    expect(c.ageView, isFalse);
    expect(row('r20'), findsNothing);
    expect(silver('r1'), findsOneWidget);
    c.dispose();
  });

  testWidgets(
      'the age panel is two short lines on both boards, also on a narrow phone',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoards(db);
    await seedRaw(db, kAllTimePeriodKey, 'r0', 5000000);
    await seedAge(db, kAllTimePeriodKey, 'r0', 5500000, 5000000);
    final LeaderboardController c = await pumpBoard(tester, db);
    tester.view.physicalSize = const Size(320, 6000);
    await tester.pumpAndSettle();
    await chooseAgeView(tester);

    Future<void> expectPanel(String caption) async {
      expect(find.text(caption), findsOneWidget,
          reason: 'the line above the panel is kept');
      final Rect panel = tester.getRect(banner);
      final Rect heading = tester.getRect(find.text('Age-adjusted rankings'));
      final Rect line = tester
          .getRect(find.text("Scores use GoodLift's masters age factors."));
      expect(heading.left, line.left);
      expect(line.top, moreOrLessEquals(heading.bottom, epsilon: 0.5),
          reason: 'directly underneath the heading');
      expect(panel.left, lessThanOrEqualTo(heading.left));
      expect(panel.right, greaterThanOrEqualTo(line.right),
          reason: 'the line fits the panel without clipping');
      // The test font is about twice as wide as the app's, so the second
      // line wraps here; on a phone it is the heading and one line.
      expect(panel.height, lessThan(80),
          reason: 'a short panel: the two sentences and their padding');
      expect(tester.takeException(), isNull);
    }

    await expectPanel('Age-adjusted RE Points · October 2026');
    await tester.tap(
        find.byKey(const ValueKey<String>('leaderboard-period-allTime')));
    await tester.pumpAndSettle();
    expect(c.ageView, isTrue);
    await expectPanel('Age-adjusted RE Points · All time');
    c.dispose();
  });

  testWidgets('app background resets to raw', (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoards(db);
    final LeaderboardController c = await pumpBoard(tester, db);
    await chooseAgeView(tester);
    expect(c.ageView, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(c.ageView, isFalse);
    // No frames are produced while paused: the raw board shows on return.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    expect(silver('r1'), findsOneWidget);
    c.dispose();
  });

  testWidgets('pushing another route resets to raw; opening the menu does not',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoards(db);
    final LeaderboardController c = await pumpBoard(tester, db,
        observers: <NavigatorObserver>[routeObserver]);
    await chooseAgeView(tester);
    expect(c.ageView, isTrue,
        reason: 'the popup menu route does not reset the view');
    final NavigatorState nav =
        tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('detail')))));
    await tester.pumpAndSettle();
    expect(c.ageView, isFalse);
    nav.pop();
    await tester.pumpAndSettle();
    expect(banner, findsNothing);
    c.dispose();
  });

  testWidgets('disposal of the view resets a host-retained controller',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoards(db);
    final LeaderboardController c = await pumpBoard(tester, db);
    await chooseAgeView(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(c.ageView, isFalse);
    c.dispose();
  });

  testWidgets(
      'age rows keep the raw medals; a medal opens the raw detail and resets the view',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoards(db);
    const List<String> cats = <String>[
      'horizontalPress',
      'verticalPull',
      'overheadPress',
      'hipHinge',
      'squatPattern'
    ];
    await db
        .collection('leaderboards')
        .doc(kMonth)
        .collection('entries')
        .doc('r20')
        .update(<String, Object?>{
      'categoryExerciseBreakdown': <String, Object?>{
        for (final String c in cats)
          c: c == 'hipHinge'
              ? <Object?>[
                  <String, Object?>{
                    'exerciseId': 'x',
                    'displayName': 'Deadlift, Conventional',
                    'pointsUnits': 2800000,
                    'sessionCount': 3
                  }
                ]
              : <Object?>[],
      },
    });
    await db.collection('leaderboardMedals').doc(kMonth).set(<String, Object?>{
      'schema': 'leaderboardMedals',
      'schemaVersion': 1,
      'periodKey': kMonth,
      'boardType': 'month',
      'revision': 1,
      'categories': <String, Object?>{
        for (final String c in cats)
          c: c == 'hipHinge'
              ? <Object?>[
                  <String, Object?>{
                    'uid': 'r20',
                    'place': 1,
                    'pointsUnits': 2800000,
                    'achievedDateKey': '2026-10-05'
                  }
                ]
              : <Object?>[],
      },
    });
    final LeaderboardController c = await pumpBoard(tester, db,
        observers: <NavigatorObserver>[routeObserver]);
    // The raw row of r20 (rank 21) is not loaded on the raw board here, so its
    // breakdown is not available; the medal itself is still the raw award.
    await chooseAgeView(tester);
    final Finder medal =
        find.byKey(const ValueKey<String>('leaderboard-medal-r20-hipHinge'));
    expect(medal, findsOneWidget);
    await tester.tap(medal);
    await tester.pumpAndSettle();
    expect(c.ageView, isFalse, reason: 'a medal detail is another route');
    expect(find.byKey(const ValueKey<String>('medal-detail')), findsOneWidget);
    c.dispose();
  });

  test('a late age result after a reset is discarded', () async {
    final _SlowRepo repo = _SlowRepo();
    final LeaderboardController c = LeaderboardController(repository: repo);
    await c.start();
    final Future<void> pending = c.setAgeView(true);
    expect(c.status, LeaderboardStatus.loading);
    c.resetToRaw();
    repo.age.complete(const LeaderboardPageResult(entries: <LeaderboardEntry>[
      LeaderboardEntry(
          uid: 'late', rank: 1, totalPointsUnits: 99, ageAdjusted: true),
    ], hasMore: false));
    await pending;
    expect(c.ageView, isFalse);
    expect(c.entries.map((LeaderboardEntry e) => e.uid), <String>['raw']);
    // Turning it on again loads afresh.
    repo.age = Completer<LeaderboardPageResult>();
    final Future<void> again = c.setAgeView(true);
    repo.age.complete(const LeaderboardPageResult(entries: <LeaderboardEntry>[
      LeaderboardEntry(
          uid: 'fresh', rank: 1, totalPointsUnits: 7, ageAdjusted: true),
    ], hasMore: false, isFromCache: true));
    await again;
    expect(c.entries.single.uid, 'fresh');
    expect(c.isFromCache, isTrue);
    c.dispose();
  });

  testWidgets('offline age results are labelled as age-adjusted',
      (WidgetTester tester) async {
    final _SlowRepo repo = _SlowRepo()..rawFromCache = true;
    final LeaderboardController c = LeaderboardController(repository: repo);
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await pumpBoard(tester, db, controller: c);
    expect(find.text('Offline — showing the last loaded standings.'),
        findsOneWidget);
    final Future<void> on = c.setAgeView(true);
    repo.age.complete(const LeaderboardPageResult(entries: <LeaderboardEntry>[
      LeaderboardEntry(
          uid: 'a', rank: 1, totalPointsUnits: 10000, ageAdjusted: true),
    ], hasMore: false, isFromCache: true));
    await on;
    await tester.pumpAndSettle();
    expect(
        find.text('Offline — showing the last loaded age-adjusted standings.'),
        findsOneWidget);
    c.dispose();
  });

  test('period switching keeps the chosen view and loads that period',
      () async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoards(db);
    await seedRaw(db, 'all_time', 'x', 5000000);
    await seedAge(db, 'all_time', 'x', 6000000, 5000000);
    final LeaderboardController c = LeaderboardController(
        repository: LeaderboardRepository(firestore: db, clock: () => kNow));
    await c.start();
    await c.setAgeView(true);
    await c.selectPeriod(LeaderboardPeriod.allTime);
    expect(c.ageView, isTrue);
    expect(c.entries.single.uid, 'x');
    expect(c.entries.single.totalPointsUnits, 6000000);
    expect(c.entries.single.rawPointsUnits, 5000000);
    c.dispose();
  });

  test('board info from another age model gives no silver and no counts', () {
    final LeaderboardBoardInfo info =
        LeaderboardBoardInfo.fromMap(<String, dynamic>{
      'ageModelVersion': 'goodlift-age-older',
      'silverUids': <String>['a'],
      'incompleteCount': 3,
    });
    expect(info.silverUids, isEmpty);
    expect(info.incompleteCount, isNull);
    final LeaderboardBoardInfo ok =
        LeaderboardBoardInfo.fromMap(<String, dynamic>{
      'ageModelVersion': kAgeModelVersion,
      'silverUids': <Object?>['a', '', 7],
      'incompleteCount': 3,
    });
    expect(ok.silverUids, <String>{'a'});
    expect(ok.incompleteCount, 3);
  });
}

/// Raw board instantly; the age page completes when the test says so.
class _SlowRepo extends LeaderboardRepository {
  _SlowRepo() : super(firestore: FakeFirebaseFirestore(), clock: () => kNow);

  Completer<LeaderboardPageResult> age = Completer<LeaderboardPageResult>();
  bool rawFromCache = false;

  @override
  Future<LeaderboardPageResult> fetchPage(LeaderboardPeriod period,
          {Object? after,
          int startRank = 1,
          int limit = LeaderboardRepository.pageSize}) async =>
      LeaderboardPageResult(entries: const <LeaderboardEntry>[
        LeaderboardEntry(uid: 'raw', rank: 1, totalPointsUnits: 10000),
      ], hasMore: false, isFromCache: rawFromCache);

  @override
  Future<LeaderboardPageResult> fetchAgePage(LeaderboardPeriod period,
          {int limit = LeaderboardRepository.boardSize}) =>
      age.future;
}
