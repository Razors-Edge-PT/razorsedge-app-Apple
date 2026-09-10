// The client half of the friendship system: what the viewer is shown, and
// which account it belongs to.
//
// The defects these cover:
//   * the legacy header badge streamed `UserContext.actingAsUid`, so a coach
//     reviewing an athlete saw that athlete's buddy requests and could answer
//     them — a social action on somebody else's account;
//   * the confirmed-buddy list was derived from the viewer's OWN assignment
//     document, which says who the VIEWER accepted and is only half of a
//     friendship, so it listed people whose profiles the viewer could not open;
//   * a self-request written before the rules forbade it sat in the badge count
//     with no way to clear it.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/social/buddy_repository.dart';

const String kMe = 'me-uid';

Future<void> seedInvite(
  FakeFirebaseFirestore db, {
  required String toUid,
  required String fromUid,
  String status = 'pending',
  String fromDisplayName = '',
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
      'fromDisplayName': fromDisplayName,
      'createdAt': Timestamp.now(),
    });

Future<void> seedAssignment(
  FakeFirebaseFirestore db,
  String ownerUid,
  Map<String, Object?> athletes,
) =>
    db
        .collection('buddyAssignments')
        .doc(ownerUid)
        .set(<String, Object?>{'athletes': athletes});

Future<void> seedGraph(
  FakeFirebaseFirestore db,
  String uid,
  List<String> friends,
) =>
    db.collection('socialGraph').doc(uid).set(<String, Object?>{
      'uid': uid,
      'friends': friends,
    });

void main() {
  group('incoming requests', () {
    test('only pending requests count', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedInvite(db, toUid: kMe, fromUid: 'a');
      await seedInvite(db, toUid: kMe, fromUid: 'b', status: 'denied');
      await seedInvite(db, toUid: kMe, fromUid: 'c', status: 'accepted');

      final BuddyRepository repo =
          BuddyRepository(firestore: db, overrideUid: kMe);
      final List<IncomingRequest> incoming = await repo.watchIncoming().first;
      expect(incoming.map((IncomingRequest r) => r.fromUid), <String>['a']);
    });

    test('the sender is the document id, not a field that could point elsewhere',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      // A malformed row whose fromUid names somebody else. The rules key on the
      // document id, so the UI must too — otherwise a row could be made to
      // display, and be answered as, a request from another account.
      await db
          .collection('users')
          .doc(kMe)
          .collection('buddyInvites')
          .doc('real-sender')
          .set(<String, Object?>{
        'status': 'pending',
        'fromUid': 'someone-else',
        'buddyUid': kMe,
      });

      final List<IncomingRequest> incoming =
          await BuddyRepository(firestore: db, overrideUid: kMe)
              .watchIncoming()
              .first;
      expect(incoming.single.fromUid, 'real-sender');
    });

    test('a legacy self-request cannot sit in the badge forever', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedInvite(db, toUid: kMe, fromUid: kMe);
      await seedInvite(db, toUid: kMe, fromUid: 'a');

      final BuddyRepository repo =
          BuddyRepository(firestore: db, overrideUid: kMe);
      expect(await repo.watchPendingCount().first, 1);
    });

    test('the badge counts exactly the pending requests', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      for (final String u in <String>['a', 'b', 'c']) {
        await seedInvite(db, toUid: kMe, fromUid: u);
      }
      expect(
        await BuddyRepository(firestore: db, overrideUid: kMe)
            .watchPendingCount()
            .first,
        3,
      );
    });

    test('a missing display name does not break the row', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db
          .collection('users')
          .doc(kMe)
          .collection('buddyInvites')
          .doc('a')
          .set(<String, Object?>{'status': 'pending'});
      final List<IncomingRequest> incoming =
          await BuddyRepository(firestore: db, overrideUid: kMe)
              .watchIncoming()
              .first;
      expect(incoming.single.fromDisplayName, '');
      expect(incoming.single.createdAt, isNull);
    });
  });

  group('outgoing requests', () {
    test('only the viewer\'s own pending entries are outgoing', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedAssignment(db, kMe, <String, Object?>{
        'waiting': <String, Object?>{'status': 'pending', 'displayName': 'Wai'},
        'friend': <String, Object?>{'status': 'accepted'},
      });
      final List<OutgoingRequest> out =
          await BuddyRepository(firestore: db, overrideUid: kMe)
              .watchOutgoing()
              .first;
      expect(out.map((OutgoingRequest r) => r.toUid), <String>['waiting']);
      expect(out.single.displayName, 'Wai');
    });

    test('ordering is deterministic when nothing carries a timestamp', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedAssignment(db, kMe, <String, Object?>{
        'zeta': <String, Object?>{'status': 'pending'},
        'alpha': <String, Object?>{'status': 'pending'},
      });
      final List<OutgoingRequest> out =
          await BuddyRepository(firestore: db, overrideUid: kMe)
              .watchOutgoing()
              .first;
      expect(out.map((OutgoingRequest r) => r.toUid), <String>['alpha', 'zeta']);
    });

    test('no assignment document is no outgoing requests, not an error',
        () async {
      final List<OutgoingRequest> out = await BuddyRepository(
        firestore: FakeFirebaseFirestore(),
        overrideUid: kMe,
      ).watchOutgoing().first;
      expect(out, isEmpty);
    });

    test('a malformed athletes map is ignored safely', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db
          .collection('buddyAssignments')
          .doc(kMe)
          .set(<String, Object?>{'athletes': 'not a map'});
      expect(
        await BuddyRepository(firestore: db, overrideUid: kMe)
            .watchOutgoing()
            .first,
        isEmpty,
      );
    });
  });

  group('confirmed friends', () {
    test('come from the server-maintained mutual projection', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedGraph(db, kMe, <String>['friend-a', 'friend-b']);
      // The viewer's OWN document also lists someone they accepted who has not
      // accepted back. Deriving the list locally would show that person and
      // lead to a profile the rules deny.
      await seedAssignment(db, kMe, <String, Object?>{
        'friend-a': <String, Object?>{'status': 'accepted'},
        'friend-b': <String, Object?>{'status': 'accepted'},
        'not-mutual': <String, Object?>{'status': 'accepted'},
      });

      final List<String> friends =
          await BuddyRepository(firestore: db, overrideUid: kMe)
              .watchFriends()
              .first;
      expect(friends, <String>['friend-a', 'friend-b']);
      expect(friends, isNot(contains('not-mutual')));
    });

    test('no projection yet is no friends, not an error', () async {
      expect(
        await BuddyRepository(
          firestore: FakeFirebaseFirestore(),
          overrideUid: kMe,
        ).watchFriends().first,
        isEmpty,
      );
    });

    test('a non-string entry in the projection is skipped', () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db.collection('socialGraph').doc(kMe).set(<String, Object?>{
        'friends': <Object?>['ok', 42, null],
      });
      expect(
        await BuddyRepository(firestore: db, overrideUid: kMe)
            .watchFriends()
            .first,
        <String>['ok'],
      );
    });
  });

  group('relationship as the row renders it', () {
    const BuddyState state = BuddyState(
      incoming: <IncomingRequest>[IncomingRequest(fromUid: 'asked-me')],
      outgoing: <OutgoingRequest>[OutgoingRequest(toUid: 'i-asked')],
      friends: <String>['buddy'],
      loaded: true,
    );

    test('each kind of relationship is distinguished', () {
      expect(state.relationshipWith('buddy'), BuddyRelationship.friends);
      expect(state.relationshipWith('asked-me'), BuddyRelationship.incoming);
      expect(state.relationshipWith('i-asked'), BuddyRelationship.requested);
      expect(state.relationshipWith('stranger'), BuddyRelationship.none);
    });

    test('a confirmed friendship outranks any leftover request row', () {
      // Both crossed requests resolving into one acceptance leaves rows behind
      // for a moment. "Friends" is the truthful answer, and it is the one that
      // makes the profile reachable.
      const BuddyState overlapping = BuddyState(
        incoming: <IncomingRequest>[IncomingRequest(fromUid: 'x')],
        outgoing: <OutgoingRequest>[OutgoingRequest(toUid: 'x')],
        friends: <String>['x'],
        loaded: true,
      );
      expect(overlapping.relationshipWith('x'), BuddyRelationship.friends);
    });

    test('an incoming request outranks an outgoing one', () {
      // The person can ACT on an incoming request; showing "Requested" while
      // the other side waits is the wrong instruction.
      const BuddyState crossed = BuddyState(
        incoming: <IncomingRequest>[IncomingRequest(fromUid: 'x')],
        outgoing: <OutgoingRequest>[OutgoingRequest(toUid: 'x')],
        loaded: true,
      );
      expect(crossed.relationshipWith('x'), BuddyRelationship.incoming);
    });

    test('the pending count is the badge', () {
      expect(state.pendingCount, 1);
      expect(const BuddyState().pendingCount, 0);
    });
  });

  group('combined state', () {
    test('one stream carries requests, sent requests and buddies together',
        () async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await seedInvite(db, toUid: kMe, fromUid: 'asked-me');
      await seedAssignment(db, kMe, <String, Object?>{
        'i-asked': <String, Object?>{'status': 'pending'},
        'buddy': <String, Object?>{'status': 'accepted'},
      });
      await seedGraph(db, kMe, <String>['buddy']);

      final BuddyRepository repo =
          BuddyRepository(firestore: db, overrideUid: kMe);
      final BuddyState state = await repo
          .watchState()
          .firstWhere((BuddyState s) => s.loaded);

      expect(state.incoming.single.fromUid, 'asked-me');
      expect(state.outgoing.single.toUid, 'i-asked');
      expect(state.friends, <String>['buddy']);
      expect(state.relationshipWith('buddy'), BuddyRelationship.friends);
    });

    test('an empty account settles as loaded with nothing in it', () async {
      final BuddyState state = await BuddyRepository(
        firestore: FakeFirebaseFirestore(),
        overrideUid: kMe,
      ).watchState().firstWhere((BuddyState s) => s.loaded);
      expect(state.incoming, isEmpty);
      expect(state.outgoing, isEmpty);
      expect(state.friends, isEmpty);
    });
  });

  group('relationship names crossing the wire', () {
    test('each server state parses back to itself', () {
      expect(relationshipFromName('friends'), BuddyRelationship.friends);
      expect(relationshipFromName('requested'), BuddyRelationship.requested);
      expect(relationshipFromName('incoming'), BuddyRelationship.incoming);
      expect(relationshipFromName('self'), BuddyRelationship.self);
      expect(relationshipFromName('none'), BuddyRelationship.none);
    });

    test('an unknown or absent state is "none", never a guess', () {
      expect(relationshipFromName(null), BuddyRelationship.none);
      expect(relationshipFromName('nonsense'), BuddyRelationship.none);
    });
  });

  group('error messages a person can act on', () {
    test('offline is named as offline, with a retry implied', () {
      final String msg = describeSocialError(
        FirebaseFunctionsException(
          code: 'unavailable',
          message: 'transport failed',
        ),
      );
      expect(msg.toLowerCase(), contains('offline'));
    });

    test('a rate limit says to wait rather than blaming the person', () {
      expect(
        describeSocialError(
          FirebaseFunctionsException(code: 'resource-exhausted', message: 'x'),
        ).toLowerCase(),
        contains('try again'),
      );
    });

    test('anything unrecognised still produces something sayable', () {
      expect(describeSocialError(Exception('boom')), isNotEmpty);
      expect(describeSocialError('a bare string'), isNotEmpty);
    });
  });
}
