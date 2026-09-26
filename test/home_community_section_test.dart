// The home page's Feed | Leaderboard section: Feed by default, a large
// Leaderboard target, feed state kept across switches, This Month by default,
// row taps opening the read-only profile, and the loading / empty / error
// states.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/home/home_community_section.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/feed_repository.dart';
import 'package:localtest222/social/ui/feed_card.dart';
import 'package:localtest222/social/buddy_repository.dart';
import 'package:localtest222/social/user_search_repository.dart';

const String kMe = 'me-uid';
final DateTime kNow = DateTime(2026, 9, 24, 10);

class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

/// Counts feed page loads, to prove switching never refetches the feed.
class _CountingFeed extends FeedRepository {
  _CountingFeed(FakeFirebaseFirestore db)
      : super(firestore: db, overrideUid: kMe);
  int loads = 0;

  @override
  Future<FeedPage> loadPage({
    DocumentSnapshot<Map<String, dynamic>>? cursor,
    bool fromServer = false,
  }) {
    loads += 1;
    return super.loadPage(cursor: cursor, fromServer: fromServer);
  }
}

class _FailingRepo extends LeaderboardRepository {
  _FailingRepo() : super(firestore: FakeFirebaseFirestore(), clock: () => kNow);
  int calls = 0;

  @override
  Future<LeaderboardPageResult> fetchPage(LeaderboardPeriod period,
      {Object? after,
      int startRank = 1,
      int limit = LeaderboardRepository.pageSize}) {
    calls += 1;
    return Future<LeaderboardPageResult>.error(StateError('down'));
  }
}

Future<void> seedFeed(FakeFirebaseFirestore db) async {
  for (int i = 0; i < 2; i++) {
    await db
        .collection('users')
        .doc(kMe)
        .collection('feed')
        .doc('f__p$i')
        .set(<String, Object?>{
      'ownerUid': 'f',
      'postId': 'p$i',
      'createdAt': Timestamp.fromDate(DateTime.utc(2026, 5, 1, 12 - i)),
      'mediaType': MediaType.image,
      'smallUrl': 'https://example.test/p$i.jpg',
      'thumbUrl': 'https://example.test/p${i}_t.jpg',
      'storagePathOriginal': 'posts/f/p$i.jpg',
      'thumbStoragePath': 'posts/f/p${i}_t.jpg',
      'caption': 'caption $i',
    });
  }
}

Future<void> seedBoard(FakeFirebaseFirestore db) async {
  Future<void> put(String period, String uid, int units, String tie) => db
          .collection('leaderboards')
          .doc(period)
          .collection('entries')
          .doc(uid)
          .set(<String, Object?>{
        'uid': uid,
        'username': 'name-$uid',
        'totalPointsUnits': units,
        'tieBreakDateKey': tie,
      });
  await put('2026-09', 'amy', 1234567, '2026-09-10');
  await put('2026-09', 'bob', 2000000, '2026-09-12');
  await put('all_time', 'cat', 9990000, '2026-06-01');
}

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  Future<void> pump(
    WidgetTester tester, {
    required FeedRepository feed,
    required UserSearchRepository search,
    required LeaderboardRepository board,
    void Function(String uid)? onOpenProfile,
    BuddyRepository? buddies,
  }) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ScrollController host = ScrollController();
    addTearDown(host.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          controller: host,
          padding: const EdgeInsets.all(16),
          child: HomeCommunitySection(
            scrollController: host,
            feed: feed,
            search: search,
            leaderboard: board,
            // The signed-in account's social state (friend gating).
            buddies: buddies ??
                BuddyRepository(
                    firestore: FakeFirebaseFirestore(), overrideUid: kMe),
            onOpenProfile: onOpenProfile ?? (_) {},
            onOpenPost: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapTab(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey<String>(key)));
    await tester.pumpAndSettle();
  }

  bool visible(WidgetTester tester, Finder f) =>
      f.hitTestable().evaluate().isNotEmpty;

  testWidgets(
      'Feed is selected on creation; the feed shows, no leaderboard is built',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedFeed(db);
    await pump(tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        board: LeaderboardRepository(firestore: db, clock: () => kNow));
    final SegmentedButton<HomeCommunityTab> sw = tester
        .widget(find.byKey(const ValueKey<String>('home-community-switch')));
    expect(sw.selected, <HomeCommunityTab>{HomeCommunityTab.feed});
    expect(visible(tester, find.byType(FeedCard)), isTrue);
    expect(find.byType(LeaderboardView), findsNothing);
  });

  testWidgets('Leaderboard is a large target and shows This Month by default',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedFeed(db);
    await seedBoard(db);
    await pump(tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        board: LeaderboardRepository(firestore: db, clock: () => kNow));
    final Size target = tester
        .getSize(find.byKey(const ValueKey<String>('home-community-switch')));
    expect(target.height, greaterThanOrEqualTo(48));
    await tapTab(tester, 'home-tab-leaderboard');

    expect(visible(tester, find.byType(FeedCard)), isFalse);
    expect(find.text('Total RE Points · September 2026'), findsOneWidget);
    final SegmentedButton<LeaderboardPeriod> period =
        tester.widget(find.byKey(const ValueKey<String>('leaderboard-period')));
    expect(period.selected, <LeaderboardPeriod>{LeaderboardPeriod.thisMonth});
    // Server order: bob (200.00) then amy (123.46), ranked.
    final double bobY = tester
        .getTopLeft(find.byKey(const ValueKey<String>('leaderboard-row-bob')))
        .dy;
    final double amyY = tester
        .getTopLeft(find.byKey(const ValueKey<String>('leaderboard-row-amy')))
        .dy;
    expect(bobY, lessThan(amyY));
    expect(find.text('200.00'), findsOneWidget);
    expect(find.text('123.46'), findsOneWidget);
    expect(find.text('name-cat'), findsNothing);
  });

  testWidgets('switching to All Time changes the result',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoard(db);
    await pump(tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        board: LeaderboardRepository(firestore: db, clock: () => kNow));
    await tapTab(tester, 'home-tab-leaderboard');
    await tapTab(tester, 'leaderboard-period-allTime');
    expect(find.text('name-cat'), findsOneWidget);
    expect(find.text('name-bob'), findsNothing);
    expect(find.text('Total RE Points · All time'), findsOneWidget);
  });

  testWidgets("tapping a FRIEND's row opens that athlete's profile",
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedBoard(db);
    await db.collection('socialGraph').doc(kMe).set(<String, Object?>{
      'friends': <String>['amy'],
    });
    final List<String> opened = <String>[];
    await pump(tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        board: LeaderboardRepository(firestore: db, clock: () => kNow),
        buddies: BuddyRepository(firestore: db, overrideUid: kMe),
        onOpenProfile: opened.add);
    await tapTab(tester, 'home-tab-leaderboard');
    await tester.tap(find.byKey(const ValueKey<String>('leaderboard-row-amy')));
    await tester.pumpAndSettle();
    expect(opened, <String>['amy']);
    // A non-friend's row stays public but does not open.
    await tester.tap(find.byKey(const ValueKey<String>('leaderboard-row-bob')));
    await tester.pumpAndSettle();
    expect(opened, <String>['amy']);
    expect(find.byKey(const ValueKey<String>('leaderboard-add-bob')),
        findsOneWidget);
  });

  testWidgets('the feed keeps its rows and never refetches across switches',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await seedFeed(db);
    await seedBoard(db);
    final _CountingFeed feed = _CountingFeed(db);
    await pump(tester,
        feed: feed,
        search: UserSearchRepository(firestore: db),
        board: LeaderboardRepository(firestore: db, clock: () => kNow));
    final int loadsBefore = feed.loads;
    final int cards = find.byType(FeedCard).evaluate().length;
    expect(cards, greaterThan(0));

    await tapTab(tester, 'home-tab-leaderboard');
    // Scrolling the page while the feed is hidden must not page it.
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tapTab(tester, 'home-tab-feed');

    expect(feed.loads, loadsBefore);
    expect(find.byType(FeedCard).evaluate().length, cards);
    expect(visible(tester, find.byType(FeedCard)), isTrue);
    // The leaderboard kept its state too: returning is instant.
    await tapTab(tester, 'home-tab-leaderboard');
    expect(find.text('name-bob'), findsOneWidget);
  });

  testWidgets('loading, then empty', (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    await pump(tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        board: LeaderboardRepository(firestore: db, clock: () => kNow));
    await tester
        .tap(find.byKey(const ValueKey<String>('home-tab-leaderboard')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('leaderboard-loading')),
        findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('leaderboard-empty')),
        findsOneWidget);
    expect(find.text('No RE Points scored this month yet.'), findsOneWidget);
  });

  testWidgets('error shows a retry that tries again',
      (WidgetTester tester) async {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    final _FailingRepo board = _FailingRepo();
    await pump(tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        board: board);
    await tapTab(tester, 'home-tab-leaderboard');
    expect(find.byKey(const ValueKey<String>('leaderboard-error')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('leaderboard-retry')));
    await tester.pumpAndSettle();
    expect(board.calls, 2);
  });

  test('HomeScreen2 opens leaderboard rows in the existing read-only profile',
      () {
    final String src = File('lib/home_screen_2.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final int start = src.indexOf('HomeCommunitySection(');
    expect(start, greaterThan(0));
    final String call = src.substring(start, start + 900);
    expect(
        call.contains('ProfileScreen(viewedUid: uid, readOnly: true)'), isTrue);
  });

  test(
      'the obsolete leaderboard is gone and nothing live imports or queries it',
      () {
    expect(File('lib/leaderboard_page.dart').existsSync(), isFalse);
    expect(File('lib/leaderboard_service.dart').existsSync(), isFalse);
    for (final FileSystemEntity f
        in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final String src = f.readAsStringSync();
      expect(src.contains('leaderboard_page.dart'), isFalse, reason: f.path);
      expect(src.contains('leaderboard_service.dart'), isFalse, reason: f.path);
      expect(src.contains('LeaderboardEmbedded'), isFalse, reason: f.path);
      expect(RegExp(r"\[\s*'rePointsMonthly").hasMatch(src), isFalse,
          reason: f.path);
      expect(src.contains("orderBy('rePoints"), isFalse, reason: f.path);
    }
  });
}
