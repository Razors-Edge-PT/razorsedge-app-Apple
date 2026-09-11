// "Your buddy request was accepted" — the badge, the People view, and whose
// account both belong to.
//
// The header used to count only requests addressed TO the viewer. An
// acceptance of a request the viewer SENT said nothing anywhere. These drive
// the shipped repository and widgets against fake Firestore data laid out the
// way functions/social/notifications.js writes it.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/social/buddy_hub_screen.dart';
import 'package:localtest222/social/buddy_repository.dart';
import 'package:localtest222/social/ui/buddy_hub_button.dart';
import 'package:localtest222/social/user_search_repository.dart';

const String kMe = 'me-uid';
const String kCoach = 'coach-authenticated-uid';
const String kAthlete = 'athlete-selected-uid';

Future<void> seedNotice(
  FakeFirebaseFirestore db, {
  required String recipient,
  required String acceptor,
  bool seen = false,
  String type = 'buddyAccepted',
  String? id,
  DateTime? acceptedAt,
}) =>
    db
        .collection('users')
        .doc(recipient)
        .collection('socialNotifications')
        .doc(id ?? 'buddyAccepted_$acceptor')
        .set(<String, Object?>{
      'type': type,
      'otherUid': acceptor,
      'seen': seen,
      'createdAt': Timestamp.now(),
      'acceptedAt': Timestamp.fromDate(acceptedAt ?? DateTime(2026, 9, 1)),
      'sourceEventId': 'evt-$acceptor',
    });

Future<void> seedInvite(
  FakeFirebaseFirestore db, {
  required String toUid,
  required String fromUid,
  String status = 'pending',
}) =>
    db
        .collection('users')
        .doc(toUid)
        .collection('buddyInvites')
        .doc(fromUid)
        .set(<String, Object?>{
      'status': status,
      'fromUid': fromUid,
      'buddyUid': toUid,
      'createdAt': Timestamp.now(),
    });

Future<void> seedFriends(
  FakeFirebaseFirestore db,
  String uid,
  List<String> friends,
) =>
    db
        .collection('socialGraph')
        .doc(uid)
        .set(<String, Object?>{'uid': uid, 'friends': friends});

Future<Map<String, dynamic>> noticeDoc(
  FakeFirebaseFirestore db,
  String recipient,
  String acceptor,
) async =>
    (await db
            .collection('users')
            .doc(recipient)
            .collection('socialNotifications')
            .doc('buddyAccepted_$acceptor')
            .get())
        .data()!;

BuddyRepository repoFor(FakeFirebaseFirestore db, String uid) =>
    BuddyRepository(firestore: db, overrideUid: uid);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('the repository', () {
    test('an unseen acceptance of my request is reported', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      final List<AcceptedNotice> n =
          await repoFor(db, kMe).watchUnseenAcceptances().first;
      expect(n.single.uid, 'bob');
      expect(n.single.id, 'buddyAccepted_bob');
      expect(n.single.acceptedAt, DateTime(2026, 9, 1));
    });

    test('seen, malformed, self and unknown-type notices are ignored',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kMe, acceptor: 'seen', seen: true);
      await seedNotice(db, recipient: kMe, acceptor: kMe);
      await seedNotice(db, recipient: kMe, acceptor: 'x', type: 'other');
      await db
          .collection('users')
          .doc(kMe)
          .collection('socialNotifications')
          .doc('broken')
          .set(<String, Object?>{'type': 'buddyAccepted', 'seen': false});
      expect(await repoFor(db, kMe).watchUnseenAcceptances().first, isEmpty);
    });

    test('the badge adds unseen acceptances to pending requests', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedInvite(db, toUid: kMe, fromUid: 'a');
      await seedInvite(db, toUid: kMe, fromUid: 'b');
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      await seedFriends(db, kMe, <String>['bob']);

      final BuddyBadge badge = await repoFor(db, kMe)
          .watchBadge()
          .firstWhere((BuddyBadge b) => b.total == 3);
      expect(badge.incoming, 2);
      expect(badge.accepted, 1);
    });

    test('an acceptance the friend projection does not confirm is not counted',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kMe, acceptor: 'zed');
      await seedFriends(db, kMe, <String>['bob']);
      final BuddyState s = await repoFor(db, kMe)
          .watchState()
          .firstWhere((BuddyState s) => s.loaded);
      expect(s.unseenAccepted.single.uid, 'zed');
      expect(s.newBuddies, isEmpty);
      expect(s.badge.total, 0);
    });

    test('the same acceptance is never counted twice', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      // A stray second document for the same account.
      await seedNotice(db, recipient: kMe, acceptor: 'bob', id: 'stray');
      await seedFriends(db, kMe, <String>['bob']);
      final BuddyState s = await repoFor(db, kMe)
          .watchState()
          .firstWhere((BuddyState s) => s.loaded);
      expect(s.newBuddies.length, 1);
      expect(s.badge.total, 1);
    });

    test('acknowledging marks only acceptances seen; requests stay pending',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedInvite(db, toUid: kMe, fromUid: 'a');
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      await seedFriends(db, kMe, <String>['bob']);
      final BuddyRepository repo = repoFor(db, kMe);

      await repo.acknowledgeAcceptances(
          await repo.watchUnseenAcceptances().first);

      final Map<String, dynamic> n = await noticeDoc(db, kMe, 'bob');
      expect(n['seen'], isTrue);
      expect(n['seenAt'], isA<Timestamp>());
      expect(n['otherUid'], 'bob', reason: 'nothing but seen/seenAt changes');
      final DocumentSnapshot<Map<String, dynamic>> invite = await db
          .collection('users')
          .doc(kMe)
          .collection('buddyInvites')
          .doc('a')
          .get();
      expect(invite.data()!['status'], 'pending');
      expect(
        await repo.watchBadge().firstWhere((BuddyBadge b) => b.total == 1),
        const BuddyBadge(incoming: 1, accepted: 0),
      );
    });

    test('the account that accepted is not told about its own acceptance',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      // Alice asked, I accepted: the notice is Alice's, not mine.
      await seedNotice(db, recipient: 'alice', acceptor: kMe);
      await seedFriends(db, kMe, <String>['alice']);
      expect(await repoFor(db, kMe).watchUnseenAcceptances().first, isEmpty);
    });

    test('signed out: nothing to count and nothing to acknowledge', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      final BuddyRepository repo =
          BuddyRepository(firestore: db, uidResolver: () => null);
      expect(repo.currentUid, isNull);
      expect(await repo.watchBadge().first, const BuddyBadge());
      await repo.acknowledgeAcceptances(const <AcceptedNotice>[
        AcceptedNotice(id: 'buddyAccepted_bob', uid: 'bob'),
      ]);
      expect((await noticeDoc(db, kMe, 'bob'))['seen'], isFalse);
    });

    test('a coach acting as an athlete counts and clears only their own',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kAthlete, acceptor: 'p');
      await seedFriends(db, kAthlete, <String>['p']);
      await seedNotice(db, recipient: kCoach, acceptor: 'q');
      await seedFriends(db, kCoach, <String>['q']);

      // The repository is the AUTHENTICATED account's; nothing names the
      // athlete a coach has selected.
      final BuddyRepository coach = repoFor(db, kCoach);
      final List<AcceptedNotice> mine =
          await coach.watchUnseenAcceptances().first;
      expect(mine.map((AcceptedNotice n) => n.uid), <String>['q']);

      await coach.acknowledgeAcceptances(mine);
      expect((await noticeDoc(db, kCoach, 'q'))['seen'], isTrue);
      expect((await noticeDoc(db, kAthlete, 'p'))['seen'], isFalse,
          reason: "the athlete's notice is never touched by the coach");

      // Even a notice id taken from the athlete lands on the coach's own
      // collection, where it does not exist — so it cannot reach the athlete.
      await expectLater(
        coach.acknowledgeAcceptances(const <AcceptedNotice>[
          AcceptedNotice(id: 'buddyAccepted_p', uid: 'p'),
        ]),
        throwsA(anything),
      );
      expect((await noticeDoc(db, kAthlete, 'p'))['seen'], isFalse);
    });
  });

  group('the header badge', () {
    testWidgets('counts pending requests and new buddies together, live',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedInvite(db, toUid: kMe, fromUid: 'a');
      await seedFriends(db, kMe, <String>['bob']);
      await tester.pumpWidget(host(BuddyHubButton(buddies: repoFor(db, kMe))));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      // Bob accepts on his device; the notice arrives with no restart.
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      await tester.pump();
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).tooltip,
        '2 buddy updates',
      );
    });

    testWidgets('an acceptance alone says so in the tooltip',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      await seedFriends(db, kMe, <String>['bob']);
      await tester.pumpWidget(host(BuddyHubButton(buddies: repoFor(db, kMe))));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip,
          '1 new buddy');
    });

    testWidgets('a large combined count stays a compact badge',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final List<String> friends = <String>[];
      for (int i = 0; i < 6; i += 1) {
        await seedInvite(db, toUid: kMe, fromUid: 'r$i');
        await seedNotice(db, recipient: kMe, acceptor: 'f$i');
        friends.add('f$i');
      }
      await seedFriends(db, kMe, friends);
      await tester.pumpWidget(host(BuddyHubButton(buddies: repoFor(db, kMe))));
      await tester.pump();
      expect(find.text('$kMaxBadgeCount+'), findsOneWidget);
      expect(find.text('12'), findsNothing);
    });
  });

  group('the People view', () {
    Future<BuddyRepository> openHub(
      WidgetTester tester,
      FakeFirebaseFirestore db, {
      String uid = kMe,
      bool actingAsOtherAccount = false,
    }) async {
      final BuddyRepository repo = repoFor(db, uid);
      await tester.pumpWidget(host(BuddyHubScreen(
        buddies: repo,
        search: UserSearchRepository(firestore: db),
        showOwnAccountNotice: actingAsOtherAccount,
      )));
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('explains the badge, then marks the acceptance seen',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedInvite(db, toUid: kMe, fromUid: 'carol');
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      await seedFriends(db, kMe, <String>['bob']);

      await openHub(tester, db);

      expect(find.text('NEW BUDDIES'), findsOneWidget);
      expect(find.text('Accepted your request'), findsOneWidget);
      expect((await noticeDoc(db, kMe, 'bob'))['seen'], isTrue,
          reason: 'shown, so seen');

      // The explanation stays for the visit even though the notice is seen.
      await tester.pumpAndSettle();
      expect(find.text('NEW BUDDIES'), findsOneWidget);

      // The pending request is untouched and still actionable.
      expect(find.text('REQUESTS'), findsOneWidget);
      final DocumentSnapshot<Map<String, dynamic>> invite = await db
          .collection('users')
          .doc(kMe)
          .collection('buddyInvites')
          .doc('carol')
          .get();
      expect(invite.data()!['status'], 'pending');
    });

    testWidgets('an unconfirmed acceptance is neither shown nor cleared',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kMe, acceptor: 'zed');
      await seedFriends(db, kMe, <String>['bob']);
      await openHub(tester, db);
      expect(find.text('NEW BUDDIES'), findsNothing);
      expect((await noticeDoc(db, kMe, 'zed'))['seen'], isFalse);
    });

    testWidgets('an old, already-seen acceptance is not presented as new',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kMe, acceptor: 'bob', seen: true);
      await seedFriends(db, kMe, <String>['bob']);
      await openHub(tester, db);
      expect(find.text('NEW BUDDIES'), findsNothing);
      expect(find.textContaining('BUDDIES · 1'), findsOneWidget);
    });

    testWidgets('a search replacing the list does not count as seeing it',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedFriends(db, kMe, <String>['bob']);
      final BuddyRepository repo = repoFor(db, kMe);
      await tester.pumpWidget(host(BuddyHubScreen(
        buddies: repo,
        search: UserSearchRepository(firestore: db),
      )));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zz');
      await tester.pumpAndSettle();

      // Bob's acceptance arrives while the search is showing.
      await seedNotice(db, recipient: kMe, acceptor: 'bob');
      await tester.pumpAndSettle();
      expect((await noticeDoc(db, kMe, 'bob'))['seen'], isFalse);
    });

    testWidgets('a coach sees and clears only the signed-in account\'s notices',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedNotice(db, recipient: kCoach, acceptor: 'q');
      await seedFriends(db, kCoach, <String>['q']);
      await seedNotice(db, recipient: kAthlete, acceptor: 'p');
      await seedFriends(db, kAthlete, <String>['p']);

      await openHub(tester, db, uid: kCoach, actingAsOtherAccount: true);

      expect(find.textContaining('Your own buddies'), findsWidgets);
      expect((await noticeDoc(db, kCoach, 'q'))['seen'], isTrue);
      expect((await noticeDoc(db, kAthlete, 'p'))['seen'], isFalse);
    });
  });
}
