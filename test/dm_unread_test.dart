// Unread direct messages, read acknowledgement, targeted notification
// cancellation and conversation avatars — through the PRODUCTION pieces:
// DmUnreadService over a fake Firestore, the real NotificationPlatform over a
// mocked method channel, and the real DmBadgeButton / DirectMessages /
// LiveBuddyAvatar widgets.
//
// The server half (counting, idempotency, skipping a push for an already-read
// message) is functions/test-emulator/dm_unread.spec.js.

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/directMessages.dart';
import 'package:localtest222/profile/data/identity_repository.dart';
import 'package:localtest222/push/notification_platform.dart';
import 'package:localtest222/push/push_intent.dart';
import 'package:localtest222/social/dm_unread_service.dart';
import 'package:localtest222/social/ui/dm_badge_button.dart';
import 'package:localtest222/social/ui/user_row.dart';

const String me = 'meUidmeUidmeUidmeUidmeUid001';
const String bob = 'bobUidbobUidbobUidbobUid0002';
const String carol = 'carolUidcarolUidcarolUid0003';
final String convBob = conversationIdFor(me, bob);
final String convCarol = conversationIdFor(me, carol);

/// Records what the app asks the platform to cancel.
class RecordingPlatform extends NotificationPlatform {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
  int cleared = 0;

  @override
  Future<int> clearNotifications({
    List<String> tagPrefixes = const <String>[],
    List<String> tags = const <String>[],
    List<String> convIds = const <String>[],
  }) async {
    calls.add(<String, Object?>{
      'tagPrefixes': tagPrefixes,
      'tags': tags,
      'convIds': convIds,
    });
    return tagPrefixes.length + tags.length;
  }

  @override
  Future<void> clearDelivered() async => cleared++;

  bool cancelledConversation(String convId) => calls.any((Map<String, Object?> c) =>
      (c['tagPrefixes']! as List<String>).contains(dmConversationTagPrefix(convId)));

  List<String> get allPrefixes => <String>[
        for (final Map<String, Object?> c in calls) ...c['tagPrefixes']! as List<String>,
      ];
}

/// Seeds a conversation with a server ledger position and my acknowledgement.
Future<void> seedConversation(
  FakeFirebaseFirestore db, {
  required String convId,
  required String other,
  int incoming = 0,
  int readIncoming = 0,
  int legacyUnread = 0,
}) async {
  await db.collection('conversations').doc(convId).set(<String, Object?>{
    'participants': <String, Object?>{me: true, other: true},
    'participantState': <String, Object?>{
      me: <String, Object?>{
        'incoming': incoming,
        'readIncoming': readIncoming,
        'unreadCount': legacyUnread,
      },
      other: <String, Object?>{'incoming': 0, 'readIncoming': 0},
    },
    'lastMessage': <String, Object?>{'text': 'hello', 'senderId': other},
    'updatedAt': Timestamp.now(),
  });
}

Future<int> readIncomingOf(FakeFirebaseFirestore db, String convId) async {
  final Map<String, dynamic>? d =
      (await db.collection('conversations').doc(convId).get()).data();
  final Map<String, dynamic> mine = Map<String, dynamic>.from(
      (d!['participantState'] as Map)[me] as Map);
  return (mine['readIncoming'] as int?) ?? 0;
}

/// Pumps past the cached-image loader's disk and network timeouts, which do
/// not resolve in a test without the storage plugins.
Future<void> settleImages(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 20));
  await tester.pump(const Duration(seconds: 20));
}

Future<DmUnreadSnapshot> firstLoaded(DmUnreadService s) =>
    s.watch().firstWhere((DmUnreadSnapshot x) => x.loaded);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('unread counting', () {
    late FakeFirebaseFirestore db;
    late RecordingPlatform platform;
    late DmUnreadService service;

    setUp(() async {
      db = FakeFirebaseFirestore();
      platform = RecordingPlatform();
      service = DmUnreadService(
        firestore: db,
        currentUid: () => me,
        notifications: platform,
      );
    });

    tearDown(() => service.dispose());

    test('three from one friend and two from another total five, then clear one at a time',
        () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 3);
      await seedConversation(db, convId: convCarol, other: carol, incoming: 2);

      DmUnreadSnapshot snap = await firstLoaded(service);
      expect(snap.total, 5);
      expect(snap.unreadFor(convBob), 3);
      expect(snap.unreadFor(convCarol), 2);

      // Reading Bob's conversation: its three go, Carol's two stay.
      await service.acknowledge(convId: convBob, upToSeq: 3, messageIds: <String>['b1', 'b2', 'b3']);
      snap = await service.watch().firstWhere((DmUnreadSnapshot s) => s.total == 2);
      expect(snap.unreadFor(convBob), 0);
      expect(snap.unreadFor(convCarol), 2);
      expect(await readIncomingOf(db, convBob), 3);

      // Only Bob's alerts were cancelled.
      expect(platform.cancelledConversation(convBob), isTrue);
      expect(platform.cancelledConversation(convCarol), isFalse);
      expect(platform.cleared, 0, reason: 'clear-all is for logout only');

      // Then Carol's.
      await service.acknowledge(convId: convCarol, upToSeq: 2);
      snap = await service.watch().firstWhere((DmUnreadSnapshot s) => s.total == 0);
      expect(snap.unreadFor(convCarol), 0);
      expect(platform.cancelledConversation(convCarol), isTrue);
    });

    test('a message arriving during the acknowledgement stays unread', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 2);
      await firstLoaded(service);

      // The chat displayed two; a third arrives before the write lands.
      await db.collection('conversations').doc(convBob).update(<String, Object?>{
        'participantState.$me.incoming': 3,
      });
      await service.acknowledge(convId: convBob, upToSeq: 2);

      final DmUnreadSnapshot snap =
          await service.watch().firstWhere((DmUnreadSnapshot s) => s.loaded && s.total == 1);
      expect(snap.unreadFor(convBob), 1);
      expect(await readIncomingOf(db, convBob), 2, reason: 'only what was displayed');
    });

    test('acknowledgement never moves backwards', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 5, readIncoming: 4);
      await firstLoaded(service);

      // A stale acknowledgement (an older device, or a late offline write).
      await service.acknowledge(convId: convBob, upToSeq: 2);
      expect(await readIncomingOf(db, convBob), 4);
      expect(service.snapshot.unreadFor(convBob), 1);

      await service.acknowledge(convId: convBob, upToSeq: 5);
      expect(await readIncomingOf(db, convBob), 5);
    });

    test('a server value behind this session is re-asserted', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 4);
      await firstLoaded(service);
      await service.acknowledge(convId: convBob, upToSeq: 4);
      expect(await readIncomingOf(db, convBob), 4);

      // Another device (or a replayed write) puts it back.
      await db.collection('conversations').doc(convBob).update(<String, Object?>{
        'participantState.$me.readIncoming': 1,
      });
      await service.watch().firstWhere((DmUnreadSnapshot s) => s.unreadFor(convBob) == 0);
      expect(await readIncomingOf(db, convBob), 4, reason: 'this session re-asserts its own read');
    });

    test('conversations from before the ledger keep showing their legacy count', () async {
      await seedConversation(db, convId: convBob, other: bob, legacyUnread: 3);
      final DmUnreadSnapshot snap = await firstLoaded(service);
      expect(snap.total, 3);
      // Reading it clears the legacy counter too, for older devices.
      await service.acknowledge(convId: convBob, upToSeq: 0, messageIds: <String>['m1']);
      expect(platform.cancelledConversation(convBob), isTrue,
          reason: 'alerts still go even with no ledger position');
    });

    test('the last known counts survive a rebuild; no transient zero', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 2);
      await firstLoaded(service);
      expect(service.snapshot.total, 2);
      // A new listener gets the current answer immediately.
      expect(service.snapshot.loaded, isTrue);
      expect(DmUnreadSnapshot.empty.loaded, isFalse,
          reason: 'an unloaded state is distinguishable from zero unread');
    });

    test('logout and account switch drop the previous account\'s counts', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 3);
      await firstLoaded(service);
      expect(service.snapshot.total, 3);

      service.onAccountChanged(null); // logout
      expect(service.snapshot.total, 0);
      expect(service.snapshot.loaded, isFalse);
      expect(service.snapshot.uid, isNull);

      service.onAccountChanged('someoneElseUid0000000000000');
      expect(service.snapshot.total, 0);
    });

    test('isAcknowledged answers per message, for stale banner suppression', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 5, readIncoming: 3);
      await firstLoaded(service);
      expect(service.isAcknowledged(convBob, 3), isTrue);
      expect(service.isAcknowledged(convBob, 4), isFalse);
      expect(service.isAcknowledged(convBob, null), isFalse);
      expect(service.isAcknowledged('other', 1), isFalse);
    });

    test('reconciliation cancels alerts only for conversations that are read', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 2, readIncoming: 2);
      await seedConversation(db, convId: convCarol, other: carol, incoming: 2);
      await firstLoaded(service);

      await service.reconcileDeliveredAlerts();
      expect(platform.allPrefixes, contains(dmConversationTagPrefix(convBob)));
      expect(platform.allPrefixes, isNot(contains(dmConversationTagPrefix(convCarol))));
    });
  });

  // ── What counts as reading ────────────────────────────────────────────────

  group('read boundary', () {
    List<DmDisplayedMessage> msgs() => <DmDisplayedMessage>[
          (id: 'm1', senderId: bob, incomingSeq: 1),
          (id: 'm2', senderId: me, incomingSeq: null), // my own reply
          (id: 'm3', senderId: bob, incomingSeq: 2),
        ];

    test('the boundary is the newest INCOMING position displayed', () {
      final DmReadBoundary b = computeReadBoundary(uid: me, messages: msgs());
      expect(b.upToSeq, 2);
      expect(b.incomingIds, <String>['m1', 'm3']);
    });

    test('a message still waiting for its position cannot be acknowledged early', () {
      final DmReadBoundary b = computeReadBoundary(uid: me, messages: <DmDisplayedMessage>[
        ...msgs(),
        (id: 'm4', senderId: bob, incomingSeq: null), // trigger has not run yet
      ]);
      expect(b.upToSeq, 2, reason: 'm4 is not swallowed');
      expect(b.incomingIds, contains('m4'));
    });

    test('my own messages never make me read', () {
      final DmReadBoundary b = computeReadBoundary(uid: me, messages: <DmDisplayedMessage>[
        (id: 'x', senderId: me, incomingSeq: 9),
      ]);
      expect(b.upToSeq, 0);
      expect(b.incomingIds, isEmpty);
      expect(b.isEmpty, isTrue);
    });

    test('only a visible chat in a foregrounded app reads', () {
      expect(shouldAcknowledgeRead(routeVisible: true, appResumed: true, signedIn: true), isTrue);
      expect(shouldAcknowledgeRead(routeVisible: false, appResumed: true, signedIn: true), isFalse,
          reason: 'covered by another route');
      expect(shouldAcknowledgeRead(routeVisible: true, appResumed: false, signedIn: true), isFalse,
          reason: 'app in the background');
      expect(shouldAcknowledgeRead(routeVisible: true, appResumed: true, signedIn: false), isFalse);
    });
  });

  // ── The native bridge ─────────────────────────────────────────────────────

  group('notification platform bridge', () {
    const MethodChannel channel = MethodChannel('goodlift/notifications');
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return 2;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('asks the platform for exactly the conversation being read', () async {
      final NotificationPlatform platform = NotificationPlatform(channel: channel);
      final int removed = await platform.clearNotifications(
        tagPrefixes: <String>[dmConversationTagPrefix(convBob)],
        tags: <String>[dmLegacyMessageTag('m1')],
        convIds: <String>[convBob],
      );
      expect(removed, 2);
      expect(calls.single.method, 'clearNotifications');
      final Map<Object?, Object?> args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['tagPrefixes'], <String>[dmConversationTagPrefix(convBob)]);
      expect(args['tags'], <String>['dm_m1'], reason: 'pre-1.7.24 alerts by message id');
      expect(args['convIds'], <String>[convBob]);
      // Never the other conversation.
      expect(
        (args['tagPrefixes']! as List<Object?>).contains(dmConversationTagPrefix(convCarol)),
        isFalse,
      );
    });

    test('an empty request never reaches the platform', () async {
      final NotificationPlatform platform = NotificationPlatform(channel: channel);
      expect(await platform.clearNotifications(), 0);
      expect(calls, isEmpty);
    });

    test('clear-all stays available for logout', () async {
      await NotificationPlatform(channel: channel).clearDelivered();
      expect(calls.single.method, 'clearDelivered');
    });

    test('tags match what the server sends', () {
      // functions/test/push_dm_unread.test.js asserts the same strings from
      // the server side.
      expect(dmMessageTag(convId: convBob, messageId: 'm1'),
          '${dmConversationTagPrefix(convBob)}m1');
      expect(dmConversationTagPrefix(convBob), startsWith('dm|'));
      expect(dmConversationTagPrefix(convBob), isNot(dmConversationTagPrefix(convCarol)));
      expect(friendRequestTag(bob), 'fr_$bob');
      expect(friendAcceptedTag(bob), 'fa_$bob');
    });

    test('a DM payload carries the message and its position', () {
      final PushIntent? intent = PushIntent.fromData(<String, dynamic>{
        'type': 'directMessage',
        'recipientUid': me,
        'actorUid': bob,
        'convId': convBob,
        'msgId': 'm7',
        'seq': '7',
      });
      expect(intent!.messageId, 'm7');
      expect(intent.incomingSeq, 7);

      // An older payload still routes.
      final PushIntent? legacy = PushIntent.fromData(<String, dynamic>{
        'type': 'directMessage',
        'recipientUid': me,
        'actorUid': bob,
        'convId': convBob,
      });
      expect(legacy!.messageId, isNull);
      expect(legacy.incomingSeq, isNull);
      expect(legacy.convId, convBob);
    });
  });

  // ── The widgets people actually see ───────────────────────────────────────

  group('badge and list', () {
    testWidgets('the message badge totals the signed-in account\'s unread', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final DmUnreadService service = DmUnreadService(
        firestore: db,
        currentUid: () => me,
        notifications: RecordingPlatform(),
      );
      addTearDown(service.dispose);
      await seedConversation(db, convId: convBob, other: bob, incoming: 3);
      await seedConversation(db, convId: convCarol, other: carol, incoming: 2);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(appBar: AppBar(actions: <Widget>[DmBadgeButton(unreadService: service)])),
      ));
      await tester.pumpAndSettle();
      expect(find.text('5'), findsOneWidget);

      await service.acknowledge(convId: convBob, upToSeq: 3);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(find.text('5'), findsNothing);

      await service.acknowledge(convId: convCarol, upToSeq: 2);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsNothing);
      expect(find.byType(Icon), findsWidgets, reason: 'the icon stays, the badge goes');
    });

    testWidgets('each row shows its own count, and opening the list reads nothing',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final RecordingPlatform platform = RecordingPlatform();
      final DmUnreadService service = DmUnreadService(
        firestore: db,
        currentUid: () => me,
        notifications: platform,
      );
      addTearDown(service.dispose);
      await seedConversation(db, convId: convBob, other: bob, incoming: 3);
      await seedConversation(db, convId: convCarol, other: carol, incoming: 2);

      await tester.pumpWidget(MaterialApp(
        home: DirectMessages(
          unreadService: service,
          firestore: db,
          uid: me,
          identity: IdentityRepository(firestore: db),
        ),
      ));
      await settleImages(tester);

      expect(find.text('3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // Merely listing conversations is not reading them.
      expect(await readIncomingOf(db, convBob), 0);
      expect(await readIncomingOf(db, convCarol), 0);
      expect(platform.calls, isEmpty);
    });
  });

  group('conversation avatars', () {
    testWidgets('shows the OTHER participant\'s photo, live, with a clean fallback',
        (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      final IdentityRepository identity = IdentityRepository(firestore: db);
      await db.collection('users_public').doc(bob).set(<String, Object?>{
        'displayName': 'Bob B',
        'photoURL': 'https://example.test/bob.jpg',
      });
      await db.collection('users_public').doc(me).set(<String, Object?>{
        'displayName': 'Me',
        'photoURL': 'https://example.test/ME-WRONG.jpg',
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LiveBuddyAvatar(uid: bob, identity: identity)),
      ));
      await settleImages(tester);

      BuddyAvatar avatar = tester.widget<BuddyAvatar>(find.byType(BuddyAvatar));
      expect(avatar.photoURL, 'https://example.test/bob.jpg');
      expect(avatar.photoURL, isNot(contains('ME-WRONG')));

      // The other person changes their picture.
      await db.collection('users_public').doc(bob).update(<String, Object?>{
        'photoURL': 'https://example.test/bob2.jpg',
      });
      await settleImages(tester);
      avatar = tester.widget<BuddyAvatar>(find.byType(BuddyAvatar));
      expect(avatar.photoURL, 'https://example.test/bob2.jpg');

      // And removes it: a neutral fallback, no broken image.
      await db.collection('users_public').doc(bob).update(<String, Object?>{'photoURL': ''});
      await settleImages(tester);
      avatar = tester.widget<BuddyAvatar>(find.byType(BuddyAvatar));
      expect(avatar.photoURL, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an account with no public profile still renders', (WidgetTester tester) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LiveBuddyAvatar(uid: carol, identity: IdentityRepository(firestore: db)),
        ),
      ));
      await settleImages(tester);
      expect(tester.widget<BuddyAvatar>(find.byType(BuddyAvatar)).photoURL, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
