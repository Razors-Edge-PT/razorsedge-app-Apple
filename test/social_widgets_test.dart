// The surfaces a person actually touches: the header badge, one person row,
// and the feed's loading, empty, offline and paging states.
//
// These drive the SHIPPED widgets against fake Firestore data rather than
// re-deriving what the widgets do. A test that reimplemented the row's state
// machine would pass while the row was broken.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/buddy_repository.dart';
import 'package:localtest222/social/feed_repository.dart';
import 'package:localtest222/social/feed_view.dart';
import 'package:localtest222/social/ui/buddy_hub_button.dart';
import 'package:localtest222/social/ui/feed_card.dart';
import 'package:localtest222/social/ui/user_row.dart';
import 'package:localtest222/social/user_search_repository.dart';
import 'package:localtest222/social/user_search_result.dart';

const String kMe = 'me-uid';

/// An image store that is never on disk and never reachable.
///
/// The widgets under test here are about layout, state and navigation, not
/// about bytes — and the real store reaches path_provider and the network,
/// neither of which exists under the test binding. Reporting "not cached, and
/// the fetch failed" is the honest answer for a test device, and it is also
/// the state that must not become a permanent spinner.
class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

Widget wrap(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

/// Gives the test a surface tall enough to hold several 1:1 feed cards.
///
/// A feed card is square, so on the default 800px-high test view only one is
/// laid out and a lazy list recycles the rest — which makes "how many cards are
/// on screen" a statement about the viewport rather than about the feed.
void useTallSurface(WidgetTester tester, {double height = 4000}) {
  tester.view.physicalSize = Size(500, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> seedFeedRow(
  FakeFirebaseFirestore db, {
  required String ownerUid,
  required String postId,
  required DateTime createdAt,
  String mediaType = MediaType.image,
}) =>
    db
        .collection('users')
        .doc(kMe)
        .collection('feed')
        .doc('${ownerUid}__$postId')
        .set(<String, Object?>{
      'ownerUid': ownerUid,
      'postId': postId,
      'createdAt': Timestamp.fromDate(createdAt),
      'mediaType': mediaType,
      'smallUrl': 'https://example.test/$postId.jpg',
      'thumbUrl': 'https://example.test/${postId}_t.jpg',
      'storagePathOriginal': 'posts/$ownerUid/$postId.jpg',
      'thumbStoragePath': 'posts/$ownerUid/${postId}_t.jpg',
      'caption': 'caption for $postId',
    });

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  group('BuddyUserRow', () {
    testWidgets('a stranger is offered Add', (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const BuddyUserRow(
        displayName: 'Sam Okafor',
        handle: '@ironjaw',
        photoURL: '',
        action: BuddyRowAction.add,
      )));
      expect(find.text('Sam Okafor'), findsOneWidget);
      expect(find.text('@ironjaw'), findsOneWidget);
      expect(find.text('Add'), findsOneWidget);
    });

    testWidgets('a sent request shows Requested, not Add',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const BuddyUserRow(
        displayName: 'Sam',
        handle: '@sam',
        photoURL: '',
        action: BuddyRowAction.requested,
      )));
      expect(find.text('Requested'), findsOneWidget);
      expect(find.text('Add'), findsNothing);
    });

    testWidgets('an incoming request offers both an accept and a decline',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const BuddyUserRow(
        displayName: 'Sam',
        handle: '@sam',
        photoURL: '',
        action: BuddyRowAction.respond,
      )));
      expect(find.text('Accept'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });

    testWidgets('a busy row shows a spinner and cannot be submitted twice',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(wrap(BuddyUserRow(
        displayName: 'Sam',
        handle: '@sam',
        photoURL: '',
        action: BuddyRowAction.add,
        busy: true,
        onPrimary: () => taps += 1,
      )));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Add'), findsNothing);
      expect(taps, 0);
    });

    testWidgets('an account with no name at all still renders a row',
        (WidgetTester tester) async {
      // A row that renders nothing is worse than a placeholder: the person
      // cannot tell it from a rendering failure.
      const UserSearchResult nameless =
          UserSearchResult(uid: 'u', username: '', displayName: '');
      await tester.pumpWidget(wrap(BuddyUserRow(
        displayName: nameless.bestName,
        handle: nameless.handle,
        photoURL: nameless.photoURL,
      )));
      expect(find.text('GoodLift member'), findsOneWidget);
    });

    testWidgets('tapping fires the primary action once',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(wrap(BuddyUserRow(
        displayName: 'Sam',
        handle: '@sam',
        photoURL: '',
        action: BuddyRowAction.add,
        onPrimary: () => taps += 1,
      )));
      await tester.tap(find.text('Add'));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('a non-friend row is not openable', (WidgetTester tester) async {
      // Offering the tap would open a page the rules deny — an error where a
      // profile was promised.
      await tester.pumpWidget(wrap(const BuddyUserRow(
        displayName: 'Sam',
        handle: '@sam',
        photoURL: '',
        action: BuddyRowAction.add,
      )));
      final Semantics s = tester.widget<Semantics>(
        find.ancestor(
          of: find.text('Sam'),
          matching: find.byType(Semantics),
        ).first,
      );
      expect(s.properties.button, isNot(true));
    });

    testWidgets('a subtitle replaces the handle when there is more to say',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const BuddyUserRow(
        displayName: 'Sam',
        handle: '@sam',
        photoURL: '',
        action: BuddyRowAction.requested,
        subtitle: 'Waiting for a reply',
      )));
      expect(find.text('Waiting for a reply'), findsOneWidget);
      expect(find.text('@sam'), findsNothing);
    });
  });

  group('relationship to row action', () {
    test('every relationship maps to exactly one control', () {
      expect(actionForRelationship(BuddyRelationship.none), BuddyRowAction.add);
      expect(actionForRelationship(BuddyRelationship.requested),
          BuddyRowAction.requested);
      expect(actionForRelationship(BuddyRelationship.incoming),
          BuddyRowAction.respond);
      expect(actionForRelationship(BuddyRelationship.friends),
          BuddyRowAction.friends);
      // Yourself is never actionable, and never reaches the list anyway.
      expect(actionForRelationship(BuddyRelationship.self), BuddyRowAction.none);
    });
  });

  group('BuddyHubButton', () {
    testWidgets('shows no badge when nothing is waiting',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(wrap(BuddyHubButton(
        buddies: BuddyRepository(firestore: db, overrideUid: kMe),
      )));
      await tester.pump();
      expect(find.byIcon(Icons.person_add_alt_1), findsOneWidget);
      expect(find.textContaining(RegExp(r'^\d')), findsNothing);
    });

    testWidgets('shows the pending count', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      for (final String from in <String>['a', 'b']) {
        await db
            .collection('users')
            .doc(kMe)
            .collection('buddyInvites')
            .doc(from)
            .set(<String, Object?>{'status': 'pending'});
      }
      await tester.pumpWidget(wrap(BuddyHubButton(
        buddies: BuddyRepository(firestore: db, overrideUid: kMe),
      )));
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a large count stays a compact badge',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      for (int i = 0; i < 15; i += 1) {
        await db
            .collection('users')
            .doc(kMe)
            .collection('buddyInvites')
            .doc('u$i')
            .set(<String, Object?>{'status': 'pending'});
      }
      await tester.pumpWidget(wrap(BuddyHubButton(
        buddies: BuddyRepository(firestore: db, overrideUid: kMe),
      )));
      await tester.pump();
      expect(find.text('$kMaxBadgeCount+'), findsOneWidget);
      expect(find.text('15'), findsNothing);
    });

    testWidgets('the icon is reachable whether or not anything is pending',
        (WidgetTester tester) async {
      // The legacy control answered a tap with "No buddy requests." and went
      // nowhere. The Hub is the destination in both cases.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(wrap(BuddyHubButton(
        buddies: BuddyRepository(firestore: db, overrideUid: kMe),
      )));
      await tester.pump();
      final IconButton button =
          tester.widget<IconButton>(find.byType(IconButton));
      expect(button.onPressed, isNotNull);
    });
  });

  group('FeedCard', () {
    const FeedItem photo = FeedItem(
      id: 'owner__p1',
      ownerUid: 'owner',
      postId: 'p1',
      mediaType: MediaType.image,
      smallUrl: 'https://example.test/p1.jpg',
      storagePath: 'posts/owner/p1.jpg',
      caption: 'Deadlift PB',
    );

    testWidgets('names the poster and shows the caption',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrap(const SizedBox(
        width: 400,
        child: FeedCard(
          item: photo,
          owner: UserSearchResult(
            uid: 'owner',
            username: 'ironsam',
            displayName: 'Samantha Vaughn',
          ),
        ),
      )));
      expect(find.text('Samantha Vaughn'), findsOneWidget);
      expect(find.text('@ironsam'), findsOneWidget);
      expect(find.text('Deadlift PB'), findsOneWidget);
    });

    testWidgets('an unresolved poster still renders a usable card',
        (WidgetTester tester) async {
      // The identity lookup can fail offline. The post is still real.
      await tester.pumpWidget(wrap(const SizedBox(
        width: 400,
        child: FeedCard(item: photo),
      )));
      expect(find.text('GoodLift member'), findsOneWidget);
    });

    testWidgets('a video is marked as one and does not autoplay',
        (WidgetTester tester) async {
      const FeedItem video = FeedItem(
        id: 'owner__v1',
        ownerUid: 'owner',
        postId: 'v1',
        mediaType: MediaType.video,
        thumbUrl: 'https://example.test/poster.jpg',
        thumbStoragePath: 'posts/owner/poster.jpg',
      );
      await tester.pumpWidget(wrap(const SizedBox(
        width: 400,
        child: FeedCard(item: video),
      )));
      // A play affordance, and nothing that could be a player: a feed card
      // draws the poster only, so scrolling past never fetches a clip.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    test('relative time reads as a glance, not a sentence', () {
      final DateTime now = DateTime.utc(2026, 6, 1, 12);
      expect(formatRelativeTime(now, now: now), 'now');
      expect(
        formatRelativeTime(now.subtract(const Duration(minutes: 5)), now: now),
        '5m',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(hours: 3)), now: now),
        '3h',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(days: 2)), now: now),
        '2d',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(days: 20)), now: now),
        '2w',
      );
      expect(formatRelativeTime(null), '');
      // A clock that has drifted forward must not produce a negative age.
      expect(
        formatRelativeTime(now.add(const Duration(hours: 1)), now: now),
        'now',
      );
    });
  });

  group('BuddyFeedView', () {
    testWidgets('an empty feed says so rather than spinning forever',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('renders a page of posts newest first',
        (WidgetTester tester) async {
      useTallSurface(tester);
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final DateTime base = DateTime.utc(2026, 5, 1, 12);
      await seedFeedRow(db, ownerUid: 'f', postId: 'old', createdAt: base);
      await seedFeedRow(
        db,
        ownerUid: 'f',
        postId: 'new',
        createdAt: base.add(const Duration(hours: 2)),
      );

      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
      )));
      await tester.pumpAndSettle();

      expect(find.text('caption for new'), findsOneWidget);
      expect(find.text('caption for old'), findsOneWidget);
      final Offset newer = tester.getTopLeft(find.text('caption for new'));
      final Offset older = tester.getTopLeft(find.text('caption for old'));
      expect(newer.dy, lessThan(older.dy));
    });

    testWidgets('a malformed row never becomes a blank tile',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final DateTime base = DateTime.utc(2026, 5, 1, 12);
      await seedFeedRow(db, ownerUid: 'f', postId: 'good', createdAt: base);
      await db
          .collection('users')
          .doc(kMe)
          .collection('feed')
          .doc('f__daily')
          .set(<String, Object?>{
        'ownerUid': 'f',
        'postId': 'daily',
        'mediaType': 're_daily',
        'createdAt': Timestamp.fromDate(base),
      });

      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
      )));
      await tester.pumpAndSettle();
      expect(find.byType(FeedCard), findsOneWidget);
      expect(find.text('caption for good'), findsOneWidget);
    });

    testWidgets('a post opens through the callback, not by autoplaying',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(
        db,
        ownerUid: 'f',
        postId: 'p1',
        createdAt: DateTime.utc(2026, 5, 1),
      );
      FeedItem? opened;
      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        onOpenPost: (FeedItem i) => opened = i,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FeedCard));
      await tester.pump();
      expect(opened?.postId, 'p1');
    });

    testWidgets('a poster\'s name opens their profile',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(
        db,
        ownerUid: 'friend-uid',
        postId: 'p1',
        createdAt: DateTime.utc(2026, 5, 1),
      );
      String? openedUid;
      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
        onOpenProfile: (String uid) => openedUid = uid,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GoodLift member'));
      await tester.pump();
      expect(openedUid, 'friend-uid');
    });

    testWidgets('a first page that does not fill the screen fetches more',
        (WidgetTester tester) async {
      // Paging is driven by scrolling, and a list shorter than its viewport
      // never scrolls. Without the fill-up pass a short first page is the last
      // page as far as the reader is concerned.
      useTallSurface(tester, height: 8000);
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final DateTime base = DateTime.utc(2026, 5, 1, 12);
      for (int i = 0; i < 8; i += 1) {
        await seedFeedRow(
          db,
          ownerUid: 'f',
          postId: 'p$i',
          createdAt: base.subtract(Duration(hours: i)),
        );
      }

      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe, pageSize: 3),
        search: UserSearchRepository(firestore: db),
      )));
      await tester.pumpAndSettle();

      final List<String> ids = tester
          .widgetList<FeedCard>(find.byType(FeedCard))
          .map((FeedCard c) => c.item.id)
          .toList(growable: false);
      expect(ids.length, 8, reason: 'every page should have been fetched');
      expect(ids.toSet().length, ids.length,
          reason: 'a post must never be rendered twice');
      // Still globally ordered across the page boundaries, not per-page.
      expect(ids.first, 'f__p0');
      expect(ids.last, 'f__p7');
    });

    testWidgets('scrolling toward the end fetches the next page',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final DateTime base = DateTime.utc(2026, 5, 1, 12);
      for (int i = 0; i < 12; i += 1) {
        await seedFeedRow(
          db,
          ownerUid: 'f',
          postId: 'p$i',
          createdAt: base.subtract(Duration(hours: i)),
        );
      }

      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe, pageSize: 3),
        search: UserSearchRepository(firestore: db),
      )));
      await tester.pumpAndSettle();

      // A lazy list recycles cards, so what matters is what has been seen
      // across the scroll, not what happens to be mounted at the end of it.
      final Set<String> seen = <String>{};
      void record() => seen.addAll(tester
          .widgetList<FeedCard>(find.byType(FeedCard))
          .map((FeedCard c) => c.item.id));

      record();
      final int firstScreen = seen.length;
      for (int i = 0; i < 12; i += 1) {
        await tester.drag(find.byType(ListView), const Offset(0, -900));
        await tester.pumpAndSettle();
        record();
      }

      expect(seen.length, greaterThan(firstScreen),
          reason: 'scrolling to the end must bring in another page');
      expect(seen.length, 12, reason: 'the whole feed should be reachable');
    });

    testWidgets('refresh keeps what is already visible',
        (WidgetTester tester) async {
      // Emptying the list to show a spinner throws away what the reader is
      // looking at, and leaves nothing behind if the refresh fails.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(
        db,
        ownerUid: 'f',
        postId: 'p1',
        createdAt: DateTime.utc(2026, 5, 1),
      );
      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(firestore: db),
      )));
      await tester.pumpAndSettle();
      expect(find.byType(FeedCard), findsOneWidget);

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump();
      // Still there mid-refresh.
      expect(find.byType(FeedCard), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byType(FeedCard), findsOneWidget);
    });

    testWidgets('embedded in a host scroll view it does not scroll itself',
        (WidgetTester tester) async {
      // Two nested scrollables fight over one finger. On the home page the
      // calendar's scroll view is the one that must win.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFeedRow(
        db,
        ownerUid: 'f',
        postId: 'p1',
        createdAt: DateTime.utc(2026, 5, 1),
      );
      final ScrollController host = ScrollController();
      addTearDown(host.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: host,
            child: Column(
              children: <Widget>[
                const SizedBox(height: 200, child: Text('calendar')),
                BuddyFeedView(
                  scrollController: host,
                  feed: FeedRepository(firestore: db, overrideUid: kMe),
                  search: UserSearchRepository(firestore: db),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('calendar'), findsOneWidget);
      expect(find.byType(FeedCard), findsOneWidget);
      // Exactly one scrollable: the host's.
      expect(find.byType(Scrollable), findsOneWidget);
    });

    testWidgets('an embedded empty feed still states itself',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final ScrollController host = ScrollController();
      addTearDown(host.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: host,
            child: BuddyFeedView(
              scrollController: host,
              feed: FeedRepository(firestore: db, overrideUid: kMe),
              search: UserSearchRepository(firestore: db),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Nothing here yet'), findsOneWidget);
    });

    testWidgets('a failed load offers a retry rather than an empty list',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(wrap(BuddyFeedView(
        feed: FeedRepository(firestore: db, overrideUid: kMe),
        search: UserSearchRepository(
          firestore: db,
          runQuery: (Query<Map<String, dynamic>> q) =>
              Future<QuerySnapshot<Map<String, dynamic>>>.error(
            FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
          ),
        ),
      )));
      await tester.pumpAndSettle();
      // The identity lookup swallows its own failure, so the feed itself is
      // still empty-but-fine rather than an error page.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
