// Friend actions on profiles and the leaderboard, for the SIGNED-IN account:
// relationship transitions, leaderboard tap gating, always-public standings,
// self rows, DM navigation and a coach's selected-athlete context.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/directMessages.dart'
    show convIdFor, ensureDirectConversation;
import 'package:localtest222/leaderboard/leaderboard_repository.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/buddy_repository.dart';
import 'package:localtest222/social/ui/profile_social_actions.dart';
import 'package:localtest222/social/ui/user_row.dart' show BuddyAvatar;

const String kMe = 'me-uid';
final DateTime kNow = DateTime(2026, 9, 24, 10);

/// The real repository over a fake Firestore, with the four callables
/// replaced by what the server does to the same documents.
class FakeBuddies extends BuddyRepository {
  FakeBuddies(this.db, String uid) : super(firestore: db, overrideUid: uid);
  final FakeFirebaseFirestore db;
  final List<String> calls = <String>[];

  @override
  Future<BuddyRelationship> sendRequest(String targetUid) async {
    calls.add('send:$targetUid');
    await db
        .collection('buddyAssignments')
        .doc(currentUid)
        .set(<String, Object?>{
      'athletes': <String, Object?>{
        targetUid: <String, Object?>{'status': 'pending'}
      },
    }, SetOptions(merge: true));
    return BuddyRelationship.requested;
  }

  @override
  Future<BuddyRelationship> cancelRequest(String targetUid) async {
    calls.add('cancel:$targetUid');
    await db
        .collection('buddyAssignments')
        .doc(currentUid)
        .set(<String, Object?>{
      'athletes': <String, Object?>{targetUid: FieldValue.delete()},
    }, SetOptions(merge: true));
    return BuddyRelationship.none;
  }

  @override
  Future<BuddyRelationship> acceptRequest(String fromUid) async {
    calls.add('accept:$fromUid');
    await db
        .collection('users')
        .doc(currentUid)
        .collection('buddyInvites')
        .doc(fromUid)
        .delete();
    await db.collection('socialGraph').doc(currentUid).set(<String, Object?>{
      'friends': FieldValue.arrayUnion(<String>[fromUid]),
    }, SetOptions(merge: true));
    return BuddyRelationship.friends;
  }

  @override
  Future<BuddyRelationship> declineRequest(String fromUid) async {
    calls.add('decline:$fromUid');
    await db
        .collection('users')
        .doc(currentUid)
        .collection('buddyInvites')
        .doc(fromUid)
        .delete();
    return BuddyRelationship.none;
  }
}

Future<void> seedFriends(
        FakeFirebaseFirestore db, String uid, List<String> friends) =>
    db
        .collection('socialGraph')
        .doc(uid)
        .set(<String, Object?>{'friends': friends});

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

/// This month's board: me, a friend, a stranger, one who asked me, one I asked.
Future<void> seedBoard(FakeFirebaseFirestore db) async {
  int units = 5000000;
  for (final String uid in <String>[
    'friend',
    'stranger',
    'asker',
    'asked',
    kMe
  ]) {
    units -= 100000;
    await db
        .collection('leaderboards')
        .doc('2026-09')
        .collection('entries')
        .doc(uid)
        .set(<String, Object?>{
      'uid': uid,
      'username': 'name-$uid',
      'photoURL': 'https://example.test/$uid.jpg',
      'totalPointsUnits': units,
      'tieBreakDateKey': '2026-09-10',
    });
  }
}

class _AbsentStore implements ProfileImageStore {
  @override
  Future<File?> cached(String url, {String? key}) async => null;

  @override
  Future<File> download(String url, {String? key}) =>
      Future<File>.error(const SocketException('offline in tests'));

  @override
  Future<void> evict(String key) async {}
}

void main() {
  setUp(() => profileImageStore = _AbsentStore());
  tearDown(resetProfileImageCache);

  group('leaderboard', () {
    Future<List<String>> pumpBoard(
        WidgetTester tester, FakeFirebaseFirestore db, BuddyRepository buddies,
        {Size size = const Size(400, 1400)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final List<String> opened = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: LeaderboardView(
              repository:
                  LeaderboardRepository(firestore: db, clock: () => kNow),
              buddies: buddies,
              onOpenProfile: opened.add,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return opened;
    }

    Future<FakeFirebaseFirestore> world() async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedBoard(db);
      await seedFriends(db, kMe, <String>['friend']);
      await seedIncoming(db, to: kMe, from: 'asker');
      await seedOutgoing(db, from: kMe, to: 'asked');
      return db;
    }

    Finder row(String uid) =>
        find.byKey(ValueKey<String>('leaderboard-row-$uid'));

    testWidgets('every row shows its public rank, name, photo and points',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = await world();
      await pumpBoard(tester, db, FakeBuddies(db, kMe));
      expect(tester.takeException(), isNull);
      for (final String uid in <String>[
        'friend',
        'stranger',
        'asker',
        'asked',
        kMe
      ]) {
        expect(find.descendant(of: row(uid), matching: find.text('name-$uid')),
            findsOneWidget);
        final BuddyAvatar avatar = tester.widget<BuddyAvatar>(
            find.descendant(of: row(uid), matching: find.byType(BuddyAvatar)));
        expect(avatar.photoURL, 'https://example.test/$uid.jpg');
      }
      expect(
          find.descendant(of: row('stranger'), matching: find.text('480.00')),
          findsOneWidget);
      expect(find.descendant(of: row('stranger'), matching: find.text('2')),
          findsOneWidget,
          reason: 'rank');
    });

    testWidgets('only my own row and a friend\'s row open a profile',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = await world();
      final List<String> opened =
          await pumpBoard(tester, db, FakeBuddies(db, kMe));
      for (final String uid in <String>[
        'friend',
        'stranger',
        'asker',
        'asked',
        kMe
      ]) {
        // The standing itself (its points), never the relationship button.
        await tester
            .tap(find.descendant(of: row(uid), matching: find.text('RE pts')));
        await tester.pumpAndSettle();
        // The avatar is part of the row: tapping it must behave the same.
        await tester.tap(
            find.descendant(of: row(uid), matching: find.byType(BuddyAvatar)));
        await tester.pumpAndSettle();
      }
      expect(opened, <String>['friend', 'friend', kMe, kMe]);
    });

    testWidgets(
        'each non-friend shows its real state; no second Add while pending',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = await world();
      await pumpBoard(tester, db, FakeBuddies(db, kMe));
      expect(find.byKey(const ValueKey<String>('leaderboard-add-stranger')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('leaderboard-accept-asker')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('leaderboard-requested-asked')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('leaderboard-add-asked')),
          findsNothing);
      for (final String uid in <String>['friend', kMe]) {
        expect(
            find.byKey(ValueKey<String>('leaderboard-add-$uid')), findsNothing);
        expect(find.byKey(ValueKey<String>('leaderboard-requested-$uid')),
            findsNothing);
      }
    });

    testWidgets(
        'Add friend sends exactly one request, then shows Requested (still not openable)',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = await world();
      final FakeBuddies buddies = FakeBuddies(db, kMe);
      final List<String> opened = await pumpBoard(tester, db, buddies);
      final Finder add =
          find.byKey(const ValueKey<String>('leaderboard-add-stranger'));
      await tester.tap(add);
      await tester.tap(add, warnIfMissed: false); // a double tap
      await tester.pumpAndSettle();
      expect(buddies.calls, <String>['send:stranger']);
      expect(
          find.byKey(const ValueKey<String>('leaderboard-requested-stranger')),
          findsOneWidget);
      expect(add, findsNothing);
      await tester.tap(row('stranger'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty, reason: 'a request is not a friendship');
    });

    testWidgets(
        'accepting an incoming request makes the row a friend row that opens',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = await world();
      final FakeBuddies buddies = FakeBuddies(db, kMe);
      final List<String> opened = await pumpBoard(tester, db, buddies);
      await tester
          .tap(find.byKey(const ValueKey<String>('leaderboard-accept-asker')));
      await tester.pumpAndSettle();
      expect(buddies.calls, <String>['accept:asker']);
      expect(find.byKey(const ValueKey<String>('leaderboard-accept-asker')),
          findsNothing);
      await tester.tap(row('asker'));
      await tester.pumpAndSettle();
      expect(opened, <String>['asker']);
    });

    testWidgets(
        'a coach with an athlete selected is gated by THEIR OWN friendships',
        (WidgetTester tester) async {
      // The coach's selected athlete is friends with 'stranger'; the coach is
      // not. The board, and every action on it, belongs to the coach.
      final FakeFirebaseFirestore db = await world();
      await seedFriends(db, 'selected-athlete', <String>['stranger']);
      final FakeBuddies coach = FakeBuddies(db, 'coach-uid');
      final List<String> opened = await pumpBoard(tester, db, coach);
      await tester.tap(
          find.descendant(of: row('stranger'), matching: find.text('RE pts')));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await tester
          .tap(find.byKey(const ValueKey<String>('leaderboard-add-stranger')));
      await tester.pumpAndSettle();
      expect(coach.calls, <String>['send:stranger']);
      final DocumentSnapshot<Map<String, dynamic>> coachDoc =
          await db.collection('buddyAssignments').doc('coach-uid').get();
      expect((coachDoc.data()!['athletes'] as Map)['stranger'], isNotNull,
          reason: 'the request is from the signed-in coach');
      expect(
          (await db
                  .collection('buddyAssignments')
                  .doc('selected-athlete')
                  .get())
              .exists,
          isFalse);
    });

    testWidgets('narrow phone: rows with actions do not overflow',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = await world();
      await pumpBoard(tester, db, FakeBuddies(db, kMe),
          size: const Size(320, 1400));
      expect(tester.takeException(), isNull);
    });
  });

  group('profile actions', () {
    Future<List<String>> pumpActions(
        WidgetTester tester, FakeBuddies buddies, String target) async {
      final List<String> conversations = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: <Widget>[
            const Text('PROFILE'),
            ProfileSocialActions(
              targetUid: target,
              buddies: buddies,
              openConversation:
                  (BuildContext context, String me, String other) async {
                conversations.add('$me→$other');
                await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('CONVERSATION')),
                ));
              },
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      return conversations;
    }

    Finder key(String k) => find.byKey(ValueKey<String>('profile-social-$k'));

    testWidgets('never on my own profile', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await pumpActions(tester, FakeBuddies(db, kMe), kMe);
      expect(find.byKey(const ValueKey<String>('profile-social-actions')),
          findsNothing);
      for (final String k in <String>['add', 'cancel', 'accept', 'message']) {
        expect(key(k), findsNothing);
      }
    });

    testWidgets(
        'no relationship → Add friend → Requested · Cancel → Add friend again',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final FakeBuddies buddies = FakeBuddies(db, kMe);
      await pumpActions(tester, buddies, 'stranger');
      await tester.tap(key('add'));
      await tester.pumpAndSettle();
      expect(buddies.calls, <String>['send:stranger']);
      expect(key('add'), findsNothing, reason: 'no duplicate request');
      expect(key('cancel'), findsOneWidget);
      await tester.tap(key('cancel'));
      await tester.pumpAndSettle();
      expect(buddies.calls, <String>['send:stranger', 'cancel:stranger']);
      expect(key('add'), findsOneWidget);
    });

    testWidgets('incoming request: Accept → Message; Decline → Add friend',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedIncoming(db, to: kMe, from: 'asker');
      final FakeBuddies buddies = FakeBuddies(db, kMe);
      await pumpActions(tester, buddies, 'asker');
      expect(key('accept'), findsOneWidget);
      expect(key('decline'), findsOneWidget);
      expect(key('add'), findsNothing);
      await tester.tap(key('accept'));
      await tester.pumpAndSettle();
      expect(key('message'), findsOneWidget);

      await tester.pumpWidget(const SizedBox()); // a fresh visit
      final FakeFirebaseFirestore db2 = FakeFirebaseFirestore();
      await seedIncoming(db2, to: kMe, from: 'asker');
      final FakeBuddies buddies2 = FakeBuddies(db2, kMe);
      await pumpActions(tester, buddies2, 'asker');
      await tester.tap(key('decline'));
      await tester.pumpAndSettle();
      expect(buddies2.calls, <String>['decline:asker']);
      expect(key('add'), findsOneWidget);
    });

    testWidgets(
        'a friend gets Message: it opens MY conversation with them, and Back returns',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFriends(db, kMe, <String>['friend']);
      final List<String> opened =
          await pumpActions(tester, FakeBuddies(db, kMe), 'friend');
      expect(key('add'), findsNothing);
      await tester.tap(key('message'));
      await tester.pumpAndSettle();
      expect(opened, <String>['$kMe→friend']);
      expect(find.text('CONVERSATION'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.text('PROFILE'), findsOneWidget);
      expect(key('message'), findsOneWidget);
    });

    testWidgets('a coach viewing their selected athlete acts as the coach',
        (WidgetTester tester) async {
      // The athlete is friends with nobody the coach knows; the coach has no
      // relationship with the athlete → Add friend, sent FROM the coach.
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFriends(db, 'athlete', <String>['someone']);
      final FakeBuddies coach = FakeBuddies(db, 'coach-uid');
      await pumpActions(tester, coach, 'athlete');
      await tester.tap(key('add'));
      await tester.pumpAndSettle();
      expect(coach.calls, <String>['send:athlete']);
      expect(key('cancel'), findsOneWidget);
    });

    testWidgets('nothing is offered before the social state has loaded',
        (WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProfileSocialActions(targetUid: 'x', buddies: _NeverLoads()),
        ),
      ));
      await tester.pump();
      expect(key('add'), findsNothing);
    });
  });

  group('conversation creation', () {
    test('creates the pair conversation once, then only touches it', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final String id = await ensureDirectConversation(
          myUid: kMe, otherUid: 'friend', firestore: db);
      expect(id, convIdFor(kMe, 'friend'));
      expect(id, convIdFor('friend', kMe), reason: 'the established pair id');
      final Map<String, dynamic> created =
          (await db.collection('conversations').doc(id).get()).data()!;
      expect(created['participants'],
          <String, Object?>{kMe: true, 'friend': true});
      expect(created['participantList'], (<String>[kMe, 'friend']..sort()));
      await db
          .collection('conversations')
          .doc(id)
          .update(<String, Object?>{'lastMessage': 'hello'});
      await ensureDirectConversation(
          myUid: kMe, otherUid: 'friend', firestore: db);
      expect(
          (await db.collection('conversations').doc(id).get())
              .data()!['lastMessage'],
          'hello',
          reason: 'an existing thread is never overwritten');
    });
  });

  test('the profile page and both Home boards use these shared pieces', () {
    String src(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');
    expect(
        src('lib/profile/profile_screen.dart'),
        allOf(contains('ProfileSocialActions('),
            contains('targetUid: c.targetUid')));
    expect(src('lib/home/home_community_section.dart'),
        contains('LeaderboardView('));
    expect(src('lib/home_screen.dart'), contains('LeaderboardView('));
    expect(src('lib/social/ui/buddy_hub_button.dart'),
        contains('Icons.groups_outlined'));
  });
}

/// A repository whose social state never arrives.
class _NeverLoads extends BuddyRepository {
  _NeverLoads() : super(firestore: FakeFirebaseFirestore(), overrideUid: kMe);
  @override
  Stream<BuddyState> watchState() => const Stream<BuddyState>.empty();
}
