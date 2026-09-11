// The home page's buddy feed: directly beneath the calendar, with nothing in
// front of it, and the SAME feed as the Buddy Hub.
//
// The three-icon selector that sat below the calendar drove three empty stubs
// on HomeScreen2 — dead controls on the page every user lands on. It is gone,
// and the working feed from the Buddy Hub now sits where it was. These drive
// the shipped section inside a host that mirrors HomeScreen2 (one outer
// scroll view, the calendar, then the feed), plus source checks on
// home_screen_2.dart itself so the layout cannot quietly drift back.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/feed_repository.dart';
import 'package:localtest222/social/feed_view.dart';
import 'package:localtest222/social/home_feed_section.dart';
import 'package:localtest222/social/ui/feed_card.dart';
import 'package:localtest222/social/user_search_repository.dart';
import 'package:table_calendar/table_calendar.dart';

const String kMe = 'me-uid';
const String kCoach = 'coach-authenticated-uid';
const String kAthlete = 'athlete-selected-uid';

class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

/// A repository whose pages are scripted, for the states Firestore's fake
/// cannot produce on its own (an offline cache miss, a failed read).
class _ScriptedFeed extends FeedRepository {
  // A fake Firestore is passed only because the base constructor would
  // otherwise reach for FirebaseFirestore.instance; loadPage never uses it.
  _ScriptedFeed(this.pages)
      : super(firestore: FakeFirebaseFirestore(), overrideUid: kMe);

  final List<Future<FeedPage> Function()> pages;
  int calls = 0;

  @override
  Future<FeedPage> loadPage({
    DocumentSnapshot<Map<String, dynamic>>? cursor,
    bool fromServer = false,
  }) {
    final int i = calls < pages.length ? calls : pages.length - 1;
    calls += 1;
    return pages[i]();
  }
}

Future<void> seedFeedRow(
  FakeFirebaseFirestore db, {
  String viewer = kMe,
  required String ownerUid,
  required String postId,
  required DateTime createdAt,
}) =>
    db
        .collection('users')
        .doc(viewer)
        .collection('feed')
        .doc('${ownerUid}__$postId')
        .set(<String, Object?>{
      'ownerUid': ownerUid,
      'postId': postId,
      'createdAt': Timestamp.fromDate(createdAt),
      'mediaType': MediaType.image,
      'smallUrl': 'https://example.test/$postId.jpg',
      'thumbUrl': 'https://example.test/${postId}_t.jpg',
      'storagePathOriginal': 'posts/$ownerUid/$postId.jpg',
      'thumbStoragePath': 'posts/$ownerUid/${postId}_t.jpg',
      'caption': 'caption for $postId',
    });

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  final DateTime base = DateTime.utc(2026, 5, 1, 12);

  /// A host shaped like HomeScreen2: one outer scroll view, the calendar,
  /// the same 8px gap, then the feed section.
  Future<ScrollController> pumpHome(
    WidgetTester tester, {
    required FeedRepository feed,
    required UserSearchRepository search,
    bool actingAsOtherAccount = false,
    bool withFeed = true,
    void Function(String uid)? onOpenProfile,
    void Function(FeedItem item)? onOpenPost,
    void Function(DateTime day)? onDaySelected,
    void Function(DateTime focused)? onPageChanged,
    // A phone-shaped surface: the default 800x600 test view puts the first
    // square card below the fold, where no tap can reach it.
    Size surface = const Size(400, 900),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ScrollController host = ScrollController();
    addTearDown(host.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          controller: host,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TableCalendar<int>(
                firstDay: DateTime.utc(2020, 1, 1),
                lastDay: DateTime.utc(2100, 12, 31),
                focusedDay: DateTime.utc(2026, 5, 15),
                availableCalendarFormats: const <CalendarFormat, String>{
                  CalendarFormat.month: 'Month',
                },
                headerStyle: const HeaderStyle(
                  formatButtonVisible: false,
                  titleCentered: true,
                ),
                onDaySelected: (DateTime selected, DateTime _) =>
                    onDaySelected?.call(selected),
                onPageChanged: (DateTime focused) =>
                    onPageChanged?.call(focused),
              ),
              const SizedBox(height: 8),
              if (withFeed)
                HomeBuddyFeedSection(
                  scrollController: host,
                  feed: feed,
                  search: search,
                  actingAsOtherAccount: actingAsOtherAccount,
                  onOpenProfile: onOpenProfile ?? (_) {},
                  onOpenPost: onOpenPost ?? (_) {},
                ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return host;
  }

  List<String> cardIds(WidgetTester tester) => tester
      .widgetList<FeedCard>(find.byType(FeedCard))
      .map((FeedCard c) => c.item.id)
      .toList(growable: false);

  group('placement', () {
    testWidgets('the feed starts immediately beneath the calendar',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(db, ownerUid: 'f', postId: 'p1', createdAt: base);
      await pumpHome(
        tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
      );

      final double calendarBottom =
          tester.getBottomLeft(find.byType(TableCalendar<int>)).dy;
      final double feedTop = tester.getTopLeft(find.byType(FeedCard)).dy;
      expect(feedTop, greaterThanOrEqualTo(calendarBottom));
      expect(feedTop - calendarBottom, lessThanOrEqualTo(8.5),
          reason: 'nothing sits between the calendar and the first card');
    });

    testWidgets('no selector, no tab and no "Feed" label',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(db, ownerUid: 'f', postId: 'p1', createdAt: base);
      await pumpHome(
        tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
      );
      expect(find.byType(SegmentedButton<Object>), findsNothing);
      expect(find.byIcon(Icons.leaderboard_outlined), findsNothing);
      expect(find.byIcon(Icons.emoji_events_outlined), findsNothing);
      expect(find.text('Feed'), findsNothing);
      expect(find.text('FEED'), findsNothing);
      expect(find.byType(Tab), findsNothing);
    });

    test('HomeScreen2 itself: the selector is gone and the section follows '
        'the calendar', () {
      // Normalised: the working tree may hold CRLF line endings.
      final String src = File('lib/home_screen_2.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(src.contains('SegmentedButton'), isFalse);
      expect(src.contains('_HomeV2Feed'), isFalse);
      expect(src.contains('Icons.leaderboard_outlined'), isFalse);
      expect(src.contains('Icons.emoji_events_outlined'), isFalse);

      final int calendar = src.indexOf('TableCalendar(');
      final int section = src.indexOf('HomeBuddyFeedSection(');
      expect(calendar, greaterThan(0));
      expect(section, greaterThan(calendar),
          reason: 'the feed section is placed after the calendar');
      // Between the end of the calendar and the section: spacing and comments
      // only — no widget, no label.
      final String between = src.substring(
          src.indexOf('const SizedBox(height: 8),', calendar), section);
      final String code = between
          .split('\n')
          .where((String l) => !l.trim().startsWith('//'))
          .join('\n');
      expect(code.trim(), 'const SizedBox(height: 8),');
      // The page scroll view drives the feed's paging.
      expect(src.contains('controller: _homeScrollCtrl'), isTrue);
      expect(src.contains('scrollController: _homeScrollCtrl'), isTrue);
    });
  });

  group('it is the Buddy Hub feed', () {
    testWidgets('the same view, renderer and repository',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(db, ownerUid: 'f', postId: 'p1', createdAt: base);
      final FeedRepository repo = FeedRepository(firestore: db, overrideUid: kMe);
      await pumpHome(tester,
          feed: repo, search: UserSearchRepository(firestore: db));

      final BuddyFeedView view =
          tester.widget<BuddyFeedView>(find.byType(BuddyFeedView));
      expect(view.feed, same(repo));
      expect(view.scrollController, isNotNull,
          reason: 'embedded, paging from the host');
      expect(find.byType(FeedCard), findsOneWidget);
      expect(find.text('caption for p1'), findsOneWidget);
      // One scrollable on the page: the host's. No nested feed list.
      expect(find.byType(Scrollable), findsWidgets);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('pages as the page scrolls, with no repeats',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      for (int i = 0; i < 12; i += 1) {
        await seedFeedRow(db,
            ownerUid: 'f',
            postId: 'p$i',
            createdAt: base.subtract(Duration(hours: i)));
      }
      final ScrollController host = await pumpHome(
        tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe, pageSize: 3),
        search: UserSearchRepository(firestore: db),
      );
      final int firstScreen = cardIds(tester).length;
      expect(host.position.maxScrollExtent, greaterThan(0));
      // Real drags, started below the calendar: TableCalendar keeps its own
      // vertical-swipe gesture, so a drag that begins on it never reaches the
      // page — on the home page as much as here.
      for (int i = 0; i < 20; i += 1) {
        await tester.dragFrom(const Offset(200, 820), const Offset(0, -700));
        await tester.pumpAndSettle();
      }
      final List<String> ids = cardIds(tester);
      expect(ids.length, greaterThan(firstScreen));
      expect(ids.length, 12, reason: 'the whole feed is reachable');
      expect(ids.toSet().length, ids.length, reason: 'no post twice');
      expect(ids.first, 'f__p0');
      expect(ids.last, 'f__p11');
    });

    testWidgets('a short first page keeps fetching until the page fills',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      for (int i = 0; i < 8; i += 1) {
        await seedFeedRow(db,
            ownerUid: 'f',
            postId: 'p$i',
            createdAt: base.subtract(Duration(hours: i)));
      }
      await pumpHome(
        tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe, pageSize: 3),
        search: UserSearchRepository(firestore: db),
        surface: const Size(500, 9000),
      );
      final List<String> ids = cardIds(tester);
      expect(ids.length, 8);
      expect(ids.toSet().length, 8);
    });

    testWidgets('overlapping pages merge into one row per post',
        (WidgetTester tester) async {
      final FeedItem a = FeedItem(
        id: 'f__a',
        ownerUid: 'f',
        postId: 'a',
        mediaType: MediaType.image,
        smallUrl: 'https://example.test/a.jpg',
        createdAt: base,
      );
      final List<FeedItem> merged =
          FeedRepository.merge(<FeedItem>[a], <FeedItem>[a]);
      expect(merged.length, 1);
    });

    testWidgets('a post and a poster open the existing pages',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(db, ownerUid: 'friend-uid', postId: 'p1', createdAt: base);
      FeedItem? opened;
      String? profile;
      await pumpHome(
        tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        onOpenPost: (FeedItem i) => opened = i,
        onOpenProfile: (String uid) => profile = uid,
      );
      await tester.tap(find.byType(FeedCard));
      await tester.pump();
      expect(opened?.postId, 'p1');
      await tester.tap(find.text('GoodLift member'));
      await tester.pump();
      expect(profile, 'friend-uid');
    });
  });

  group('states', () {
    testWidgets('empty', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await pumpHome(
        tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
      );
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('offline with nothing cached says so, and offers a retry',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await pumpHome(
        tester,
        feed: _ScriptedFeed(<Future<FeedPage> Function()>[
          () async => const FeedPage(items: <FeedItem>[], fromCache: true),
        ]),
        search: UserSearchRepository(firestore: db),
      );
      expect(find.text("You're offline"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a failed load offers a retry that recovers',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(db, ownerUid: 'f', postId: 'p1', createdAt: base);
      final FeedRepository real = FeedRepository(firestore: db, overrideUid: kMe);
      final _ScriptedFeed feed = _ScriptedFeed(<Future<FeedPage> Function()>[
        () => Future<FeedPage>.error(
            FirebaseException(plugin: 'cloud_firestore', code: 'unavailable')),
        () => real.loadPage(),
      ]);
      await pumpHome(tester,
          feed: feed, search: UserSearchRepository(firestore: db));
      expect(find.text("Couldn't load the feed"), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byType(FeedCard), findsOneWidget);
      expect(feed.calls, 2);
    });
  });

  group('whose feed it is', () {
    testWidgets('a coach sees their OWN feed, and is told so',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(db,
          viewer: kCoach, ownerUid: 'coach-buddy', postId: 'mine', createdAt: base);
      await seedFeedRow(db,
          viewer: kAthlete, ownerUid: 'athlete-buddy', postId: 'theirs', createdAt: base);

      await pumpHome(
        tester,
        // The AUTHENTICATED account; nothing on the section names the athlete.
        feed: FeedRepository(firestore: db, overrideUid: kCoach),
        search: UserSearchRepository(firestore: db),
        actingAsOtherAccount: true,
      );
      expect(find.text('caption for mine'), findsOneWidget);
      expect(find.text('caption for theirs'), findsNothing);
      expect(find.text(kHomeOwnFeedNotice), findsOneWidget);
    });

    testWidgets('an athlete on their own account sees no coaching caption',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await pumpHome(
        tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
      );
      expect(find.text(kHomeOwnFeedNotice), findsNothing);
    });

    test('HomeScreen2 hands the section a caption flag, never an account', () {
      // Normalised: the working tree may hold CRLF line endings.
      final String src = File('lib/home_screen_2.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final int start = src.indexOf('HomeBuddyFeedSection(');
      final String call = src.substring(start, src.indexOf('),\n                  ],', start));
      expect(call.contains('isActingAsSelf'), isTrue);
      expect(call.contains('actingAsUid'), isFalse,
          reason: 'the feed must not be pointed at the selected athlete');
      expect(call.contains('feed:'), isFalse,
          reason: 'production uses the FirebaseAuth-resolved repository');
    });
  });

  group('the calendar is undisturbed', () {
    testWidgets('same size with and without the feed beneath it',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(db, ownerUid: 'f', postId: 'p1', createdAt: base);
      await pumpHome(tester,
          feed: FeedRepository(firestore: db, overrideUid: kMe),
          search: UserSearchRepository(firestore: db),
          withFeed: false);
      final Size alone = tester.getSize(find.byType(TableCalendar<int>));
      await pumpHome(tester,
          feed: FeedRepository(firestore: db, overrideUid: kMe),
          search: UserSearchRepository(firestore: db));
      expect(tester.getSize(find.byType(TableCalendar<int>)), alone);
    });

    testWidgets('selecting a day and changing month still work',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(db, ownerUid: 'f', postId: 'p1', createdAt: base);
      DateTime? selected;
      DateTime? paged;
      await pumpHome(
        tester,
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        onDaySelected: (DateTime d) => selected = d,
        onPageChanged: (DateTime d) => paged = d,
      );
      await tester.tap(find.text('20').first);
      await tester.pumpAndSettle();
      expect(selected?.day, 20);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(paged?.month, 6);
      // The feed is still there after the calendar moved.
      expect(find.byType(FeedCard), findsOneWidget);
    });
  });
}
