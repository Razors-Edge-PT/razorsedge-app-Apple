// Opening a FRIEND's live stories from their profile avatar.
//
// The rebuilt profile always had one story ring and one viewer. What decides
// whether a visitor gets them is now explicit: the SIGNED-IN account and the
// profile must be confirmed friends, from the mutual projection for the
// authenticated uid. The rules still check both assignment documents on every
// read; the client simply never asks for a non-friend's stories — which
// matters for the accounts the rules DO let read, like the super admin, and
// makes coaching an athlete plainly not a friendship.

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/identity_repository.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_repository.dart';
import 'package:localtest222/profile/data/media_staging.dart';
import 'package:localtest222/profile/data/media_uploader.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';
import 'package:localtest222/profile/profile_controller.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/profile/ui/profile_header.dart';
import 'package:localtest222/profile/ui/story_launch.dart';
import 'package:localtest222/profile/ui/story_viewer.dart';

const String kMe = 'me-uid';
const String kFriend = 'friend-uid';
const String kStranger = 'stranger-uid';
const String kSuperAdmin = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const String kCoach = 'coach-uid';
const String kAthlete = 'athlete-uid';

/// Never on disk and never reachable: the viewer must not depend on bytes.
class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

/// Counts live-story queries, so "never asked" is provable, not inferred.
class _CountingStories extends StoryRepository {
  _CountingStories({super.firestore, required super.outbox});

  final List<String> liveQueriesFor = <String>[];

  @override
  Stream<List<StoryItem>> watchLive(String ownerUid,
      {DateTime Function()? clock}) {
    liveQueriesFor.add(ownerUid);
    return super.watchLive(ownerUid, clock: clock);
  }
}

void main() {
  late FakeFirebaseFirestore db;
  late MediaOutbox outbox;
  late _CountingStories stories;
  late DateTime now;
  DateTime clock() => now;

  setUp(() {
    db = FakeFirebaseFirestore();
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
    stories = _CountingStories(firestore: db, outbox: outbox);
    now = DateTime.now().toUtc();
    profileImageStore = _AbsentStore();
  });

  tearDown(() async {
    resetProfileImageCache();
    await outbox.close();
  });

  ProfileController controllerFor({
    required String actor,
    String target = kFriend,
    Stream<List<String>> Function()? viewerFriends,
  }) {
    final ProfileRepository profiles = ProfileRepository(firestore: db);
    final ShowcaseRepository showcase = ShowcaseRepository(firestore: db);
    return ProfileController(
      targetUid: target,
      actorUid: actor,
      profiles: profiles,
      identity: IdentityRepository(firestore: db),
      showcase: showcase,
      media: MediaRepository(firestore: db, outbox: outbox),
      stories: stories,
      staging: MediaStaging(outbox: outbox),
      uploader: MediaUploader(
        firestore: db,
        outbox: outbox,
        profiles: profiles,
        showcase: showcase,
        stories: stories,
        ownerUidOverride: () => actor,
      ),
      clock: clock,
      viewerFriends: viewerFriends,
    );
  }

  Stream<List<String>> Function() friendsAre(List<String> uids) =>
      () => Stream<List<String>>.value(uids);

  Future<void> seedStory(String owner, String id, {required Duration ago}) =>
      db.collection('users').doc(owner).collection('stories').doc(id).set(
        <String, Object?>{
          'ownerUid': owner,
          'mediaType': MediaType.image,
          'url': 'https://example.invalid/$id.jpg',
          'publishedAt': Timestamp.fromDate(now.subtract(ago)),
        },
      );

  Future<void> pumpHeader(WidgetTester t, ProfileController c) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => AnimatedBuilder(
            animation: c,
            builder: (BuildContext context, _) => ProfileHeader(
              controller: c,
              onChangePhoto: () {},
              onAddStory: () {},
              onEditUsername: () {},
              onViewStories: () => openProfileStories(context, c),
            ),
          ),
        ),
      ),
    ));
    await t.pump();
  }

  Finder ring() => find.byWidgetPredicate((Widget w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration! as BoxDecoration).gradient != null);

  Future<void> tapAvatar(WidgetTester t) async {
    await t.tap(find.byType(ClipOval).first, warnIfMissed: false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  /// Closes the viewer and lets the route finish leaving: the frame that ends
  /// the pop animation is not the frame that removes the route.
  Future<void> closeViewer(WidgetTester t) async {
    await t.tap(find.byIcon(Icons.close_rounded));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await t.pump();
  }

  group('an accepted friend', () {
    testWidgets('with live stories: the ring, then the existing viewer, in order',
        (WidgetTester t) async {
      await seedStory(kFriend, 'older', ago: const Duration(hours: 3));
      await seedStory(kFriend, 'newer', ago: const Duration(hours: 1));
      final ProfileController c = controllerFor(
        actor: kMe,
        viewerFriends: friendsAre(<String>[kFriend, 'someone-else']),
      )..start();
      await t.pump(const Duration(milliseconds: 10));

      expect(c.viewerSeesStories, isTrue);
      expect(c.hasStoryRing, isTrue);
      await pumpHeader(t, c);
      expect(ring(), findsOneWidget, reason: 'the existing active-story ring');

      await tapAvatar(t);
      final StoryViewer viewer = t.widget<StoryViewer>(find.byType(StoryViewer));
      expect(viewer.stories.map((StoryItem s) => s.id), <String>['older', 'newer'],
          reason: 'the existing oldest-first viewing order');
      expect(viewer.isOwner, isFalse);
      expect(viewer.onDelete, isNull, reason: 'a visitor can delete nothing');
      // Media goes through the same disk-cached image widget as everywhere
      // else on the profile, so a story seen once is not downloaded again.
      expect(
        find.descendant(
          of: find.byType(StoryViewer),
          matching: find.byType(CachedProfileImage),
        ),
        findsOneWidget,
      );
      expect(stories.liveQueriesFor, <String>[kFriend],
          reason: 'one listener, reused — not a query per tap');

      await closeViewer(t);
      expect(find.byType(StoryViewer), findsNothing);
      c.dispose();
    });

    testWidgets('without a live story: the plain avatar, and no viewer',
        (WidgetTester t) async {
      final ProfileController c = controllerFor(
        actor: kMe,
        viewerFriends: friendsAre(<String>[kFriend]),
      )..start();
      await t.pump(const Duration(milliseconds: 10));
      expect(c.viewerSeesStories, isTrue);
      expect(c.hasStoryRing, isFalse);

      await pumpHeader(t, c);
      expect(ring(), findsNothing);
      await tapAvatar(t);
      expect(find.byType(StoryViewer), findsNothing);
      expect(find.text(kStoryGoneMessage), findsNothing,
          reason: 'the avatar simply is not a story control here');
      c.dispose();
    });

    testWidgets('expired stories are never offered, and a deleted one leaves',
        (WidgetTester t) async {
      await seedStory(kFriend, 'expired', ago: const Duration(hours: 25));
      await seedStory(kFriend, 'live', ago: const Duration(hours: 1));
      final ProfileController c = controllerFor(
        actor: kMe,
        viewerFriends: friendsAre(<String>[kFriend]),
      )..start();
      await t.pump(const Duration(milliseconds: 10));
      expect(c.stories.map((StoryItem s) => s.id), <String>['live']);

      await db
          .collection('users')
          .doc(kFriend)
          .collection('stories')
          .doc('live')
          .delete();
      await t.pump(const Duration(milliseconds: 10));
      expect(c.hasStoryRing, isFalse);
      c.dispose();
    });

    testWidgets('a story that expires between the ring and the tap opens nothing',
        (WidgetTester t) async {
      await seedStory(kFriend, 's1',
          ago: StoryItem.ttl - const Duration(minutes: 5));
      final ProfileController c = controllerFor(
        actor: kMe,
        viewerFriends: friendsAre(<String>[kFriend]),
      )..start();
      await t.pump(const Duration(milliseconds: 10));
      await pumpHeader(t, c);
      expect(ring(), findsOneWidget);

      // The clock passes the boundary while the ring is still painted.
      now = now.add(const Duration(minutes: 6));
      await tapAvatar(t);

      expect(find.byType(StoryViewer), findsNothing,
          reason: 'never an empty viewer');
      expect(find.text(kStoryGoneMessage), findsOneWidget);
      await t.pump(const Duration(seconds: 5)); // let the snack bar go
      c.dispose();
    });

    testWidgets('the friendship ending closes the ring and the listener, live',
        (WidgetTester t) async {
      await seedStory(kFriend, 's1', ago: const Duration(hours: 1));
      final StreamController<List<String>> friends =
          StreamController<List<String>>();
      final ProfileController c = controllerFor(
        actor: kMe,
        viewerFriends: () => friends.stream,
      )..start();

      friends.add(<String>[kFriend]);
      await t.pump(const Duration(milliseconds: 10));
      expect(c.hasStoryRing, isTrue);

      friends.add(const <String>[]); // removed as a buddy
      await t.pump(const Duration(milliseconds: 10));
      expect(c.viewerSeesStories, isFalse);
      expect(c.hasStoryRing, isFalse);
      expect(c.stories, isEmpty);

      friends.add(<String>[kFriend]); // and friends again
      await t.pump(const Duration(milliseconds: 10));
      expect(c.hasStoryRing, isTrue);
      expect(stories.liveQueriesFor, <String>[kFriend, kFriend]);

      c.dispose();
      // Not awaited: the controller has already cancelled its subscription,
      // and a close() future is not something this test needs to wait on.
      unawaited(friends.close());
    });
  });

  group('everyone else', () {
    testWidgets('a non-friend — even the super admin — never asks for stories',
        (WidgetTester t) async {
      await seedStory(kFriend, 's1', ago: const Duration(hours: 1));
      for (final String actor in <String>[kStranger, kSuperAdmin]) {
        final ProfileController c = controllerFor(
          actor: actor,
          viewerFriends: friendsAre(<String>['unrelated']),
        )..start();
        await t.pump(const Duration(milliseconds: 10));
        expect(c.viewerSeesStories, isFalse, reason: actor);
        expect(c.hasStoryRing, isFalse, reason: actor);
        c.dispose();
      }
      expect(stories.liveQueriesFor, isEmpty,
          reason: 'the stories were never requested at all');
    });

    testWidgets('coaching an athlete is not a friendship',
        (WidgetTester t) async {
      await seedStory(kAthlete, 's1', ago: const Duration(hours: 1));
      // The coach's OWN confirmed friends — the athlete is not among them.
      final ProfileController c = controllerFor(
        actor: kCoach,
        target: kAthlete,
        viewerFriends: friendsAre(<String>['coach-buddy']),
      )..start();
      await t.pump(const Duration(milliseconds: 10));
      expect(c.isOwner, isFalse);
      expect(c.hasStoryRing, isFalse);
      expect(stories.liveQueriesFor, isEmpty);
      c.dispose();
    });

    testWidgets('with no friendship source the gate stays closed',
        (WidgetTester t) async {
      await seedStory(kFriend, 's1', ago: const Duration(hours: 1));
      final ProfileController c = controllerFor(actor: kMe)..start();
      await t.pump(const Duration(milliseconds: 10));
      expect(c.hasStoryRing, isFalse);
      expect(stories.liveQueriesFor, isEmpty);
      c.dispose();
    });
  });

  group('the owner\'s own profile', () {
    testWidgets('is unchanged: own stories, own ring, own delete control',
        (WidgetTester t) async {
      // Two minutes of life left, so the controller's expiry timer has fired
      // by the end of the test — the owner path follows the established
      // pattern of disposing in tearDown, after the local outbox streams.
      await seedStory(kMe, 'mine',
          ago: StoryItem.ttl - const Duration(minutes: 2));
      final ProfileController c =
          controllerFor(actor: kMe, target: kMe)..start();
      addTearDown(c.dispose);
      await t.pump(const Duration(milliseconds: 10));
      expect(c.isOwner, isTrue);
      expect(c.viewerSeesStories, isTrue);
      expect(c.hasStoryRing, isTrue);
      expect(stories.liveQueriesFor, <String>[kMe]);

      await pumpHeader(t, c);
      expect(ring(), findsOneWidget);
      await tapAvatar(t);
      final StoryViewer viewer = t.widget<StoryViewer>(find.byType(StoryViewer));
      expect(viewer.isOwner, isTrue);

      await closeViewer(t);
      expect(find.byType(StoryViewer), findsNothing);

      // And the owner's ring still leaves at the exact expiry.
      now = now.add(const Duration(minutes: 2, seconds: 1));
      await t.pump(const Duration(minutes: 2, seconds: 1));
      expect(c.hasStoryRing, isFalse);
    });
  });
}
