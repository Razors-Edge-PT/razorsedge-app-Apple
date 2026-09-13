// Unread direct messages, read acknowledgement, targeted notification
// cancellation and conversation avatars — through the PRODUCTION pieces:
// DmUnreadService over a fake Firestore, the real NotificationPlatform over a
// mocked method channel, and the real DmBadgeButton / DirectMessages /
// LiveBuddyAvatar widgets.
//
// The server half (counting, idempotency, skipping a push for an already-read
// message) is functions/test-emulator/dm_unread.spec.js.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart'
    show DocumentReference, DocumentSnapshot, Timestamp;
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

/// Records what the app asks the platform to cancel, and fakes what the OS
/// reports as currently delivered (for reconciliation tests).
class RecordingPlatform extends NotificationPlatform {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];
  int cleared = 0;

  /// What `deliveredTags()` answers — set by a test to simulate the tray.
  List<String> delivered = <String>[];
  Object? deliveredTagsError;

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

  @override
  Future<List<String>> deliveredTags() async {
    if (deliveredTagsError != null) throw deliveredTagsError!;
    return delivered;
  }

  /// Every tag this platform was ever asked to cancel individually (never a
  /// prefix/convId blanket — the whole point of the redesign).
  List<String> get allCancelledTags => <String>[
        for (final Map<String, Object?> c in calls) ...c['tags']! as List<String>,
      ];

  bool cancelledTag(String tag) => allCancelledTags.contains(tag);

  /// True if any call used a blanket tagPrefix/convId clear — the old,
  /// unsafe behaviour this suite guards against ever coming back.
  bool get everClearedByPrefixOrConvId => calls.any((Map<String, Object?> c) =>
      (c['tagPrefixes']! as List<String>).isNotEmpty || (c['convIds']! as List<String>).isNotEmpty);
}

/// Seeds a conversation with a server ledger position, and marks [other] as
/// one of `me`'s confirmed friends in `socialGraph/me` (merging with any
/// friend already seeded) — the projection DmUnreadService now reads instead
/// of listing `conversations` directly.
Future<void> seedConversation(
  FakeFirebaseFirestore db, {
  required String convId,
  required String other,
  int incoming = 0,
  int readIncoming = 0,
  int legacyUnread = 0,
  bool friend = true,
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
  if (friend) await addFriend(db, other);
}

/// Seeds one message document with the ledger position a reconciliation
/// lookup would read.
Future<void> seedMessage(
  FakeFirebaseFirestore db, {
  required String convId,
  required String msgId,
  required int incomingSeq,
  String senderId = bob,
}) {
  return db
      .collection('conversations')
      .doc(convId)
      .collection('messages')
      .doc(msgId)
      .set(<String, Object?>{'senderId': senderId, 'text': 'hi', 'incomingSeq': incomingSeq});
}

/// Adds [other] to `me`'s confirmed-friend projection, merging with whoever
/// is already there.
Future<void> addFriend(FakeFirebaseFirestore db, String other) async {
  final DocumentReference<Map<String, dynamic>> ref = db.collection('socialGraph').doc(me);
  final DocumentSnapshot<Map<String, dynamic>> cur = await ref.get();
  final Set<String> friends = <String>{
    ...((cur.data()?['friends'] as List?) ?? const <Object?>[]).whereType<String>(),
    other,
  };
  await ref.set(<String, Object?>{'uid': me, 'friends': friends.toList()..sort()});
}

/// Removes [other] from `me`'s confirmed-friend projection — an unfriend, as
/// the server-side projection would apply it.
Future<void> removeFriend(FakeFirebaseFirestore db, String other) async {
  final DocumentReference<Map<String, dynamic>> ref = db.collection('socialGraph').doc(me);
  final DocumentSnapshot<Map<String, dynamic>> cur = await ref.get();
  final Set<String> friends = <String>{
    ...((cur.data()?['friends'] as List?) ?? const <Object?>[]).whereType<String>(),
  }..remove(other);
  await ref.set(<String, Object?>{'uid': me, 'friends': friends.toList()..sort()});
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

      // Only Bob's alerts were cancelled — by exact message tag, not a
      // conversation-wide prefix/convId clear.
      expect(platform.cancelledTag(dmMessageTag(convId: convBob, messageId: 'b1')), isTrue);
      expect(platform.everClearedByPrefixOrConvId, isFalse);
      expect(platform.cleared, 0, reason: 'clear-all is for logout only');

      // Then Carol's.
      await service.acknowledge(convId: convCarol, upToSeq: 2, messageIds: <String>['c1', 'c2']);
      snap = await service.watch().firstWhere((DmUnreadSnapshot s) => s.total == 0);
      expect(snap.unreadFor(convCarol), 0);
      expect(platform.cancelledTag(dmMessageTag(convId: convCarol, messageId: 'c1')), isTrue);
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
      expect(platform.cancelledTag(dmMessageTag(convId: convBob, messageId: 'm1')), isTrue,
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

    test('reconciliation cancels a delivered alert only when its OWN message is covered', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 1, readIncoming: 1);
      await seedMessage(db, convId: convBob, msgId: 'read1', incomingSeq: 1);
      await seedConversation(db, convId: convCarol, other: carol, incoming: 1, readIncoming: 0);
      await seedMessage(db, convId: convCarol, msgId: 'unread1', incomingSeq: 1);
      await firstLoaded(service);

      platform.delivered = <String>[
        dmMessageTag(convId: convBob, messageId: 'read1'),
        dmMessageTag(convId: convCarol, messageId: 'unread1'),
      ];
      await service.reconcileDeliveredAlerts();

      expect(platform.cancelledTag(dmMessageTag(convId: convBob, messageId: 'read1')), isTrue);
      expect(platform.cancelledTag(dmMessageTag(convId: convCarol, messageId: 'unread1')), isFalse);
      expect(platform.everClearedByPrefixOrConvId, isFalse,
          reason: 'never a blind conversation-wide clear');
    });
  });

  // ── Defect: premature cancellation of a newly delivered alert ─────────────
  group('reconciliation never speculatively cancels', () {
    late FakeFirebaseFirestore db;
    late RecordingPlatform platform;
    late DmUnreadService service;

    setUp(() async {
      db = FakeFirebaseFirestore();
      platform = RecordingPlatform();
      service = DmUnreadService(firestore: db, currentUid: () => me, notifications: platform);
    });

    tearDown(() => service.dispose());

    test('a cached zero followed by a fresh unread server value protects the new alert', () async {
      // The service's own snapshot still says zero unread (the "cached
      // zero") when a new message arrives and its notification is posted —
      // the write did not go through the service's listener at all, exactly
      // as a push racing ahead of Firestore's own snapshot delivery would.
      await seedConversation(db, convId: convBob, other: bob, incoming: 0, readIncoming: 0);
      await firstLoaded(service);
      expect(service.snapshot.unreadFor(convBob), 0, reason: 'the stale/cached zero');

      await db.collection('conversations').doc(convBob).update(<String, Object?>{
        'participantState.$me.incoming': 1,
      });
      await seedMessage(db, convId: convBob, msgId: 'new1', incomingSeq: 1);
      platform.delivered = <String>[dmMessageTag(convId: convBob, messageId: 'new1')];

      // Reconciliation runs against whatever `_last` currently holds — which
      // may still be the cached zero above — but must not trust it.
      await service.reconcileDeliveredAlerts();
      expect(platform.calls, isEmpty,
          reason: 'a cached zero must never establish that a new message was read');
    });

    test('a loaded zero followed by a brand-new notification protects only the new one', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 1, readIncoming: 1);
      await seedMessage(db, convId: convBob, msgId: 'old1', incomingSeq: 1);
      await firstLoaded(service);

      // A new message lands immediately before resume runs reconciliation.
      await db.collection('conversations').doc(convBob).update(<String, Object?>{
        'participantState.$me.incoming': 2,
      });
      await seedMessage(db, convId: convBob, msgId: 'new2', incomingSeq: 2);
      platform.delivered = <String>[
        dmMessageTag(convId: convBob, messageId: 'old1'),
        dmMessageTag(convId: convBob, messageId: 'new2'),
      ];

      await service.reconcileDeliveredAlerts();
      expect(platform.cancelledTag(dmMessageTag(convId: convBob, messageId: 'old1')), isTrue,
          reason: 'genuinely already read');
      expect(platform.cancelledTag(dmMessageTag(convId: convBob, messageId: 'new2')), isFalse,
          reason: 'arrived after the read boundary — must survive');
    });

    test('a permission/platform failure with stale counts cached triggers no cancellation', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 1, readIncoming: 1);
      await firstLoaded(service);
      platform.deliveredTagsError = Exception('permission-denied');

      await service.reconcileDeliveredAlerts();
      expect(platform.calls, isEmpty,
          reason: 'unknown/failed reads must never trigger speculative cancellation');
    });

    test('an unreadable conversation at reconciliation time is skipped, not treated as read', () async {
      // Stands in for a permission failure on the per-conversation read
      // itself: fromDoc/_serverReadBoundary sees no data and returns null,
      // the same branch a denied read would hit.
      await seedConversation(db, convId: convBob, other: bob, incoming: 1, readIncoming: 1);
      await seedMessage(db, convId: convBob, msgId: 'm1', incomingSeq: 1);
      await firstLoaded(service);

      await db.collection('conversations').doc(convBob).delete();
      platform.delivered = <String>[dmMessageTag(convId: convBob, messageId: 'm1')];

      await service.reconcileDeliveredAlerts();
      expect(platform.calls, isEmpty);
    });

    test('explicit acknowledgement clears exactly what was displayed, protecting a message that '
        'arrives during cleanup', () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 1, readIncoming: 0);
      await firstLoaded(service);

      // The chat computed its boundary over ONE displayed message; a second
      // real message is written to the SAME conversation right as the
      // cancellation call goes out. It must never be swept up.
      await seedMessage(db, convId: convBob, msgId: 'shown1', incomingSeq: 1);
      await seedMessage(db, convId: convBob, msgId: 'brandNew2', incomingSeq: 2);

      await service.acknowledge(convId: convBob, upToSeq: 1, messageIds: <String>['shown1']);

      expect(platform.cancelledTag(dmMessageTag(convId: convBob, messageId: 'shown1')), isTrue);
      expect(platform.cancelledTag(dmMessageTag(convId: convBob, messageId: 'brandNew2')), isFalse);
      expect(platform.everClearedByPrefixOrConvId, isFalse);
    });

    test('an offline acknowledgement still protects its own messages before the server catches up',
        () async {
      await seedConversation(db, convId: convBob, other: bob, incoming: 1, readIncoming: 0);
      await seedMessage(db, convId: convBob, msgId: 'm1', incomingSeq: 1);
      await firstLoaded(service);

      // acknowledge() records `_acked` locally and fires the server write
      // unawaited — reconciliation must trust the local acknowledgement
      // immediately, not wait for the write to land.
      unawaited(service.acknowledge(convId: convBob, upToSeq: 1, messageIds: <String>['m1']));
      platform.delivered = <String>[dmMessageTag(convId: convBob, messageId: 'm1')];
      await service.reconcileDeliveredAlerts();

      expect(platform.cancelledTag(dmMessageTag(convId: convBob, messageId: 'm1')), isTrue);
    });

    test('switching accounts drops the previous account\'s state before reconciliation ever runs',
        () async {
      String uid = me;
      final DmUnreadService switching =
          DmUnreadService(firestore: db, currentUid: () => uid, notifications: platform);
      addTearDown(switching.dispose);

      await seedConversation(db, convId: convBob, other: bob, incoming: 1, readIncoming: 1);
      await switching.watch().firstWhere((DmUnreadSnapshot s) => s.loaded);
      expect(switching.snapshot.uid, me);

      uid = 'someoneElseUid0000000000000';
      switching.onAccountChanged(uid);
      platform.delivered = <String>[dmMessageTag(convId: convBob, messageId: 'anything')];
      await switching.reconcileDeliveredAlerts();
      expect(platform.calls, isEmpty,
          reason: 'the new account has no loaded state yet — nothing to reconcile against');
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
