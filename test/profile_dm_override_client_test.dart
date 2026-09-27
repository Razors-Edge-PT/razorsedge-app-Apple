// The support profile + DM override in the app (display only — the rules are
// the boundary; see functions/test-rules/profile_dm_override_rules.spec.js):
//   * the holder sees Message BESIDE the genuine friendship control;
//   * the holder's leaderboard rows open any profile, still offering Add;
//   * the holder is shown a non-friend's stories, as a friend would be;
//   * both sides' inboxes include the holder's non-friend conversation;
//   * the cue-QA test account — like any other account — has none of it.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
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
import 'package:localtest222/push/notification_platform.dart';
import 'package:localtest222/social/access_grants.dart';
import 'package:localtest222/social/buddy_repository.dart';
import 'package:localtest222/social/dm_unread_service.dart';
import 'package:localtest222/social/ui/profile_social_actions.dart';

const String kRichard = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const String kTestAccount = 'jhIB7Yi1whYwPvBSmK27KltJGn23';
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

class _QuietPlatform extends NotificationPlatform {
  @override
  Future<int> clearNotifications({
    List<String> tagPrefixes = const <String>[],
    List<String> tags = const <String>[],
    List<String> convIds = const <String>[],
  }) async =>
      0;

  @override
  Future<void> clearDelivered() async {}

  @override
  Future<List<String>> deliveredTags() async => const <String>[];
}

Future<void> grant(FakeFirebaseFirestore db, String uid) => db
    .collection(AccessGrantsRepository.collection)
    .doc(uid)
    .set(<String, Object?>{AccessGrantsRepository.field: true});

Future<void> seedIncoming(FakeFirebaseFirestore db,
        {required String to, required String from}) =>
    db
        .collection('users')
        .doc(to)
        .collection('buddyInvites')
        .doc(from)
        .set(<String, Object?>{
      'fromUid': from,
      'status': 'pending',
      'createdAt': Timestamp.fromDate(kNow)
    });

Future<void> seedOutgoing(FakeFirebaseFirestore db,
        {required String from, required String to}) =>
    db.collection('buddyAssignments').doc(from).set(<String, Object?>{
      'athletes': <String, Object?>{
        to: <String, Object?>{'status': 'pending'}
      },
    }, SetOptions(merge: true));

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  group('profile actions', () {
    Future<List<String>> pump(WidgetTester tester, FakeFirebaseFirestore db,
        {required String me, required String target}) async {
      final List<String> opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProfileSocialActions(
            targetUid: target,
            buddies: BuddyRepository(firestore: db, overrideUid: me),
            openConversation: (BuildContext _, String a, String b) async =>
                opened.add('$a->$b'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return opened;
    }

    const KeyFinder add = KeyFinder('profile-social-add');
    const KeyFinder message = KeyFinder('profile-social-message');

    testWidgets('holder, no relationship: Add friend AND Message',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db.collection('socialGraph').doc(kRichard).set(<String, Object?>{
        'friends': <String>[],
      });
      await grant(db, kRichard);
      final List<String> opened =
          await pump(tester, db, me: kRichard, target: 'stranger');
      expect(add.f, findsOneWidget);
      expect(message.f, findsOneWidget);
      await tester.tap(message.f);
      await tester.pumpAndSettle();
      expect(opened, <String>['$kRichard->stranger']);
      // No friendship was created or implied by any of this.
      expect((await db.collection('socialGraph').doc(kRichard).get()).data(),
          <String, Object?>{'friends': <String>[]});
      expect((await db.collection('buddyAssignments').get()).docs, isEmpty);
    });

    testWidgets('holder, outgoing request: Requested · Cancel AND Message',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await grant(db, kRichard);
      await seedOutgoing(db, from: kRichard, to: 'asked');
      await pump(tester, db, me: kRichard, target: 'asked');
      expect(const KeyFinder('profile-social-cancel').f, findsOneWidget);
      expect(message.f, findsOneWidget);
    });

    testWidgets('holder, incoming request: Accept, Decline AND Message',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await grant(db, kRichard);
      await seedIncoming(db, to: kRichard, from: 'asker');
      await pump(tester, db, me: kRichard, target: 'asker');
      expect(const KeyFinder('profile-social-accept').f, findsOneWidget);
      expect(const KeyFinder('profile-social-decline').f, findsOneWidget);
      expect(message.f, findsOneWidget);
    });

    testWidgets('holder, friends: the normal single Message',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await grant(db, kRichard);
      await db.collection('socialGraph').doc(kRichard).set(<String, Object?>{
        'friends': <String>['pal'],
      });
      await pump(tester, db, me: kRichard, target: 'pal');
      expect(message.f, findsOneWidget);
      expect(add.f, findsNothing);
    });

    testWidgets('the test account and an ordinary account: Add friend only',
        (WidgetTester tester) async {
      for (final String me in <String>[kTestAccount, 'ordinary']) {
        final FakeFirebaseFirestore db = FakeFirebaseFirestore();
        await grant(db, kRichard); // someone else's grant changes nothing
        await pump(tester, db, me: me, target: 'stranger');
        expect(add.f, findsOneWidget, reason: me);
        expect(message.f, findsNothing, reason: me);
      }
    });
  });

  group('leaderboard', () {
    Future<List<String>> pumpBoard(
        WidgetTester tester, FakeFirebaseFirestore db, String me) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      int units = 5000000;
      for (final String uid in <String>['stranger', me]) {
        units -= 100000;
        await db
            .collection('leaderboards')
            .doc('2026-09')
            .collection('entries')
            .doc(uid)
            .set(<String, Object?>{
          'uid': uid,
          'username': 'name-$uid',
          'totalPointsUnits': units,
          'tieBreakDateKey': '2026-09-10',
        });
      }
      final List<String> opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: LeaderboardView(
              repository:
                  LeaderboardRepository(firestore: db, clock: () => kNow),
              buddies: BuddyRepository(firestore: db, overrideUid: me),
              onOpenProfile: opened.add,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('name-stranger'));
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('the holder opens a non-friend\'s profile; Add friend stays',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await grant(db, kRichard);
      expect(await pumpBoard(tester, db, kRichard), <String>['stranger']);
      expect(find.byKey(const ValueKey<String>('leaderboard-add-stranger')),
          findsOneWidget);
    });

    testWidgets('the test account cannot', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await grant(db, kRichard);
      expect(await pumpBoard(tester, db, kTestAccount), isEmpty);
    });
  });

  group('profile stories', () {
    late FakeFirebaseFirestore db;
    late MediaOutbox outbox;
    final DateTime now = DateTime.now().toUtc();

    setUp(() {
      db = FakeFirebaseFirestore();
      outbox = MediaOutbox(MediaOutboxDatabase.memory());
    });
    tearDown(() => outbox.close());

    ProfileController controllerFor(String actor, {required bool override}) {
      final StoryRepository stories =
          StoryRepository(firestore: db, outbox: outbox);
      final ProfileRepository profiles = ProfileRepository(firestore: db);
      final ShowcaseRepository showcase = ShowcaseRepository(firestore: db);
      return ProfileController(
        targetUid: 'stranger',
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
        clock: () => now,
        viewerFriends: () => Stream<List<String>>.value(const <String>[]),
        viewerOverride: () => Stream<bool>.value(override),
      );
    }

    testWidgets(
        'the holder is shown a non-friend\'s live story; others are not',
        (WidgetTester t) async {
      await db
          .collection('users')
          .doc('stranger')
          .collection('stories')
          .doc('s1')
          .set(<String, Object?>{
        'ownerUid': 'stranger',
        'mediaType': MediaType.image,
        'url': 'https://example.invalid/s1.jpg',
        'publishedAt':
            Timestamp.fromDate(now.subtract(const Duration(hours: 1))),
      });
      final ProfileController holder = controllerFor(kRichard, override: true)
        ..start();
      final ProfileController testAccount =
          controllerFor(kTestAccount, override: false)..start();
      await t.pump(const Duration(milliseconds: 20));
      expect(holder.viewerSeesStories, isTrue);
      expect(holder.hasStoryRing, isTrue);
      expect(testAccount.viewerSeesStories, isFalse);
      expect(testAccount.hasStoryRing, isFalse);
      holder.dispose();
      testAccount.dispose();
    });
  });

  group('inbox', () {
    Future<void> conversation(
        FakeFirebaseFirestore db, String a, String b) async {
      final List<String> pair = <String>[a, b]..sort();
      await db.collection('conversations').doc(pair.join('_')).set(
        <String, Object?>{
          'participants': <String, Object?>{a: true, b: true},
          'participantList': pair,
          'participantState': <String, Object?>{
            a: <String, Object?>{'incoming': 0, 'readIncoming': 0},
            b: <String, Object?>{'incoming': 1, 'readIncoming': 0},
          },
          'lastMessage': <String, Object?>{'text': 'hi', 'senderId': a},
          'updatedAt': Timestamp.now(),
        },
      );
    }

    Future<DmUnreadSnapshot> inboxOf(FakeFirebaseFirestore db, String me,
        bool Function(DmUnreadSnapshot) ready) async {
      final DmUnreadService s = DmUnreadService(
          firestore: db, currentUid: () => me, notifications: _QuietPlatform());
      addTearDown(s.dispose);
      return s.watch().firstWhere(ready).timeout(const Duration(seconds: 5));
    }

    test('the recipient\'s inbox includes the holder\'s conversation',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await grant(db, kRichard);
      await conversation(db, kRichard, 'athlete');
      final String id = (<String>[kRichard, 'athlete']..sort()).join('_');
      final DmUnreadSnapshot snap = await inboxOf(db, 'athlete',
          (DmUnreadSnapshot s) => s.conversations.containsKey(id));
      expect(snap.unreadFor(id), 1);
    });

    test('the holder\'s inbox includes its non-friend conversations', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await grant(db, kRichard);
      await conversation(db, kRichard, 'athlete');
      final String id = (<String>[kRichard, 'athlete']..sort()).join('_');
      final DmUnreadSnapshot snap = await inboxOf(db, kRichard,
          (DmUnreadSnapshot s) => s.conversations.containsKey(id));
      expect(snap.conversations.keys, contains(id));
    });

    test('without a grant, only friends\' conversations appear', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await conversation(db, kTestAccount, 'athlete');
      await db
          .collection('socialGraph')
          .doc(kTestAccount)
          .set(<String, Object?>{'friends': <String>[]});
      final DmUnreadSnapshot snap =
          await inboxOf(db, kTestAccount, (DmUnreadSnapshot s) => s.loaded);
      expect(snap.conversations, isEmpty);
    });
  });
}

/// A key finder by name.
class KeyFinder {
  const KeyFinder(this.key);
  final String key;
  Finder get f => find.byKey(ValueKey<String>(key));
}
