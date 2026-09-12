/// Social activity: who is told, what counts as read, and what clearing one
/// thing must NOT clear.
///
/// The rules these pin are the ones that are easy to get wrong and expensive
/// to get wrong: opening a screen is not reading; reading one post is not
/// reading another; an interaction arriving mid-acknowledgement is still new;
/// and a reaction to a message is never an unread message.
///
/// Everything runs against a fake Firestore, the real NotificationPlatform
/// over a recording stub, and the real widgets.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/push/notification_platform.dart';
import 'package:localtest222/push/push_intent.dart';
import 'package:localtest222/social/social_activity_service.dart';
import 'package:localtest222/social/ui/post_activity_scope.dart';

const String me = 'meUidmeUidmeUidmeUidmeUid0001';
const String bob = 'bobUidbobUidbobUidbobUidbob2';
const String carol = 'carolUidcarolUidcarolUidca03';

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
    return tags.length + tagPrefixes.length;
  }

  @override
  Future<void> clearDelivered() async => cleared++;

  List<String> get cancelledTags => <String>[
        for (final Map<String, Object?> c in calls) ...c['tags']! as List<String>,
      ];
}

/// Seeds one activity record, the way the server writes it.
Future<String> seedActivity(
  FakeFirebaseFirestore db, {
  required String id,
  required String type,
  String actor = bob,
  String? postId,
  String? commentId,
  String? convId,
  String? messageId,
  String? emoji,
  String? preview,
  bool read = false,
  String owner = me,
  int minutesAgo = 0,
}) async {
  final String subject = postId != null ? 'post:$postId' : 'dm:$convId';
  final String tag = postId != null
      ? postActivityTag(postId: postId, activityId: id)
      : dmReactionTag(convId: convId!, messageId: messageId!);
  await db
      .collection('users')
      .doc(owner)
      .collection('socialActivity')
      .doc(id)
      .set(<String, Object?>{
    'type': type,
    'actorUid': actor,
    'subject': subject,
    'read': read,
    if (postId != null) 'postId': postId,
    if (commentId != null) 'commentId': commentId,
    if (convId != null) 'conversationId': convId,
    if (messageId != null) 'messageId': messageId,
    if (emoji != null) 'emoji': emoji,
    if (preview != null) 'preview': preview,
    'tag': tag,
    'createdAt': Timestamp.fromDate(
      DateTime.utc(2026, 9, 1, 12).subtract(Duration(minutes: minutesAgo)),
    ),
  });
  return id;
}

Future<bool> isReadInStore(FakeFirebaseFirestore db, String id) async {
  final DocumentSnapshot<Map<String, dynamic>> snap = await db
      .collection('users')
      .doc(me)
      .collection('socialActivity')
      .doc(id)
      .get();
  return snap.data()?['read'] == true;
}

void main() {
  late FakeFirebaseFirestore db;
  late RecordingPlatform platform;
  late SocialActivityService service;

  setUp(() {
    db = FakeFirebaseFirestore();
    platform = RecordingPlatform();
    service = SocialActivityService(
      firestore: db,
      currentUid: () => me,
      notifications: platform,
    );
  });

  tearDown(() async => service.dispose());

  Future<void> settle(WidgetTester t) async {
    for (int i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
  }

  // ── What counts as presented ──────────────────────────────────────────────
  group('only what is actually shown counts as read', () {
    test('a comment outside the loaded window is not presented by the post',
        () {
      const SocialActivity shown = SocialActivity(
        id: 'a1', type: 'postComment', actorUid: bob, subject: 'post:p1',
        read: false, postId: 'p1', commentId: 'c-new',
      );
      const SocialActivity offscreen = SocialActivity(
        id: 'a2', type: 'postComment', actorUid: bob, subject: 'post:p1',
        read: false, postId: 'p1', commentId: 'c-old',
      );
      const SocialActivity like = SocialActivity(
        id: 'a3', type: 'postLike', actorUid: bob, subject: 'post:p1',
        read: false, postId: 'p1',
      );
      final List<SocialActivity> presented = presentedOnPost(
        unread: <SocialActivity>[shown, offscreen, like],
        postId: 'p1',
        displayedCommentIds: <String>{'c-new'},
      );
      expect(presented.map((SocialActivity a) => a.id), <String>['a1', 'a3'],
          reason: 'the post presents its likes; only shown comments are read');
    });

    test('another post\'s interactions are never presented by this one', () {
      const SocialActivity other = SocialActivity(
        id: 'b1', type: 'postLike', actorUid: bob, subject: 'post:p2',
        read: false, postId: 'p2',
      );
      expect(
        presentedOnPost(
          unread: <SocialActivity>[other],
          postId: 'p1',
          displayedCommentIds: const <String>{},
        ),
        isEmpty,
      );
    });

    test('a reaction is presented only when its message is on screen', () {
      const SocialActivity shown = SocialActivity(
        id: 'r1', type: 'dmReaction', actorUid: bob, subject: 'dm:c1',
        read: false, convId: 'c1', messageId: 'm1',
      );
      const SocialActivity offscreen = SocialActivity(
        id: 'r2', type: 'dmReaction', actorUid: bob, subject: 'dm:c1',
        read: false, convId: 'c1', messageId: 'm-old',
      );
      expect(
        presentedInConversation(
          unread: <SocialActivity>[shown, offscreen],
          convId: 'c1',
          displayedMessageIds: <String>{'m1'},
        ).map((SocialActivity a) => a.id),
        <String>['r1'],
      );
    });

    test('a covered route, a backgrounded app and a signed-out account '
        'present nothing', () {
      expect(
        shouldAcknowledgeActivity(routeVisible: false, appResumed: true, signedIn: true),
        isFalse,
      );
      expect(
        shouldAcknowledgeActivity(routeVisible: true, appResumed: false, signedIn: true),
        isFalse,
      );
      expect(
        shouldAcknowledgeActivity(routeVisible: true, appResumed: true, signedIn: false),
        isFalse,
      );
      expect(
        shouldAcknowledgeActivity(routeVisible: true, appResumed: true, signedIn: true),
        isTrue,
      );
    });
  });

  // ── The service ───────────────────────────────────────────────────────────
  group('reading one thing leaves everything else alone', () {
    testWidgets('three interactions on A and two on B: viewing A clears only A',
        (WidgetTester t) async {
      await seedActivity(db, id: 'a1', type: 'postComment', postId: 'A', commentId: 'c1');
      await seedActivity(db, id: 'a2', type: 'postLike', postId: 'A');
      await seedActivity(db, id: 'a3', type: 'postGoodLift', postId: 'A');
      await seedActivity(db, id: 'b1', type: 'postComment', postId: 'B', commentId: 'c9');
      await seedActivity(db, id: 'b2', type: 'postLike', postId: 'B');

      service.watch();
      await settle(t);
      expect(service.unreadCount, 5);

      // Viewing post A, with its one comment on screen.
      await service.acknowledge(presentedOnPost(
        unread: service.snapshot.unread,
        postId: 'A',
        displayedCommentIds: <String>{'c1'},
      ));
      await settle(t);

      expect(service.unreadCount, 2, reason: "B's two are untouched");
      expect(service.snapshot.unread.map((SocialActivity a) => a.id),
          unorderedEquals(<String>['b1', 'b2']));
      expect(await isReadInStore(db, 'a1'), isTrue);
      expect(await isReadInStore(db, 'a3'), isTrue);
      expect(await isReadInStore(db, 'b1'), isFalse);

      // A's alerts are cancelled; B's are not.
      expect(platform.cancelledTags,
          contains(postActivityTag(postId: 'A', activityId: 'a1')));
      expect(platform.cancelledTags,
          isNot(contains(postActivityTag(postId: 'B', activityId: 'b1'))));

      // Now B.
      await service.acknowledge(presentedOnPost(
        unread: service.snapshot.unread,
        postId: 'B',
        displayedCommentIds: <String>{'c9'},
      ));
      await settle(t);
      expect(service.unreadCount, 0);
      expect(platform.cancelledTags,
          contains(postActivityTag(postId: 'B', activityId: 'b2')));
    });

    testWidgets('an interaction arriving during acknowledgement stays unread',
        (WidgetTester t) async {
      await seedActivity(db, id: 'a1', type: 'postLike', postId: 'A');
      service.watch();
      await settle(t);

      final List<SocialActivity> beingRead = presentedOnPost(
        unread: service.snapshot.unread,
        postId: 'A',
        displayedCommentIds: const <String>{},
      );
      // A new like lands while the acknowledgement is in flight.
      await seedActivity(db, id: 'a2', type: 'postLike', postId: 'A', actor: carol);
      await service.acknowledge(beingRead);
      await settle(t);

      expect(await isReadInStore(db, 'a1'), isTrue);
      expect(await isReadInStore(db, 'a2'), isFalse,
          reason: 'it was not in the set that was on screen');
      expect(service.snapshot.unread.map((SocialActivity a) => a.id), <String>['a2']);
    });

    testWidgets('acknowledging is idempotent and never re-writes',
        (WidgetTester t) async {
      await seedActivity(db, id: 'a1', type: 'postLike', postId: 'A');
      service.watch();
      await settle(t);
      final List<SocialActivity> items = service.snapshot.unread;
      await service.acknowledge(items);
      await settle(t);
      final int callsAfterFirst = platform.calls.length;
      await service.acknowledge(items);
      await settle(t);
      expect(platform.calls.length, callsAfterFirst,
          reason: 'nothing to do the second time');
      expect(service.unreadCount, 0);
    });

    testWidgets('a read interaction is never shown as unread again',
        (WidgetTester t) async {
      await seedActivity(db, id: 'a1', type: 'postLike', postId: 'A', read: true);
      service.watch();
      await settle(t);
      expect(service.unreadCount, 0);
      expect(service.isAcknowledged('a1'), isFalse,
          reason: 'this session did not acknowledge it; it was already read');
    });

    testWidgets('signing into another account drops the previous one\'s state',
        (WidgetTester t) async {
      await seedActivity(db, id: 'a1', type: 'postLike', postId: 'A');
      service.watch();
      await settle(t);
      expect(service.unreadCount, 1);

      service.onAccountChanged(carol);
      await settle(t);
      expect(service.snapshot.uid, isNot(me));
      expect(service.unreadCount, 0,
          reason: "one account's activity is never shown to another");
    });

    testWidgets('a reaction acknowledgement cancels exactly that alert',
        (WidgetTester t) async {
      const String convId = 'conv1';
      await seedActivity(db, id: 'r1', type: 'dmReaction',
          convId: convId, messageId: 'm1', emoji: '🔥');
      await seedActivity(db, id: 'r2', type: 'dmReaction',
          convId: convId, messageId: 'm2', emoji: '👏');
      service.watch();
      await settle(t);

      await service.acknowledge(presentedInConversation(
        unread: service.snapshot.unread,
        convId: convId,
        displayedMessageIds: <String>{'m1'},
      ));
      await settle(t);

      expect(platform.cancelledTags,
          contains(dmReactionTag(convId: convId, messageId: 'm1')));
      expect(platform.cancelledTags,
          isNot(contains(dmReactionTag(convId: convId, messageId: 'm2'))));
      expect(service.unreadCount, 1);
    });

    testWidgets('startup reconciliation clears alerts for what is already read',
        (WidgetTester t) async {
      await seedActivity(db, id: 'a1', type: 'postLike', postId: 'A', read: true);
      await seedActivity(db, id: 'a2', type: 'postLike', postId: 'B');
      service.watch();
      await settle(t);

      await service.reconcileDeliveredAlerts();
      await settle(t);
      expect(platform.cancelledTags,
          contains(postActivityTag(postId: 'A', activityId: 'a1')));
      expect(platform.cancelledTags,
          isNot(contains(postActivityTag(postId: 'B', activityId: 'a2'))),
          reason: 'an unread interaction keeps its alert');
    });
  });

  // ── The post screen's scope ───────────────────────────────────────────────
  group('the post screen acknowledges what it shows', () {
    Widget host({required Widget child}) => MaterialApp(
          navigatorObservers: <NavigatorObserver>[routeObserverForTest],
          home: child,
        );

    testWidgets('a visible post reads its likes, and its shown comments only',
        (WidgetTester t) async {
      await seedActivity(db, id: 'a1', type: 'postLike', postId: 'P');
      await seedActivity(db, id: 'a2', type: 'postComment', postId: 'P', commentId: 'shown');
      await seedActivity(db, id: 'a3', type: 'postComment', postId: 'P', commentId: 'hidden');
      service.watch();
      await settle(t);
      // The test binding starts with no lifecycle state; the scope reads
      // nothing unless the app is genuinely in front.
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.pumpWidget(host(
        child: PostActivityScope(
          postId: 'P',
          service: service,
          child: Builder(builder: (BuildContext context) {
            // What the comments list reports as displayed.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              PostActivityScope.of(context)
                  ?.reportDisplayedComments(<String>['shown']);
            });
            return const SizedBox.shrink();
          }),
        ),
      ));
      await settle(t);
      await t.pump(const Duration(milliseconds: 50));

      expect(await isReadInStore(db, 'a1'), isTrue, reason: 'the like is on screen');
      expect(await isReadInStore(db, 'a2'), isTrue);
      expect(await isReadInStore(db, 'a3'), isFalse,
          reason: 'a comment that was never displayed stays unread');
    });
  });

  // ── Intents and tags ──────────────────────────────────────────────────────
  group('what a notification says, and what it opens', () {
    test('post interactions parse with their post, comment and record', () {
      final PushIntent? i = PushIntent.fromData(<String, dynamic>{
        'v': '1',
        'type': 'postComment',
        'recipientUid': me,
        'actorUid': bob,
        'postId': 'p1',
        'commentId': 'c1',
        'activityId': 'pc_x',
      });
      expect(i, isNotNull);
      expect(i!.kind, PushKind.postComment);
      expect(i.kind.isPostInteraction, isTrue);
      expect(i.postId, 'p1');
      expect(i.commentId, 'c1');
      expect(i.activityId, 'pc_x');
    });

    test('a post interaction with no post, and a self-addressed one, are refused',
        () {
      expect(
        PushIntent.fromData(<String, dynamic>{
          'type': 'postLike', 'recipientUid': me, 'actorUid': bob,
        }),
        isNull,
      );
      expect(
        PushIntent.fromData(<String, dynamic>{
          'type': 'postLike', 'recipientUid': me, 'actorUid': me, 'postId': 'p1',
        }),
        isNull,
      );
    });

    test('a reaction parses only for its own conversation and message', () {
      final String convId = conversationIdFor(me, bob);
      expect(
        PushIntent.fromData(<String, dynamic>{
          'type': 'dmReaction', 'recipientUid': me, 'actorUid': bob,
          'convId': convId, 'msgId': 'm1',
        })?.kind,
        PushKind.dmReaction,
      );
      // A conversation that is not this pair.
      expect(
        PushIntent.fromData(<String, dynamic>{
          'type': 'dmReaction', 'recipientUid': me, 'actorUid': bob,
          'convId': conversationIdFor(me, carol), 'msgId': 'm1',
        }),
        isNull,
      );
      // No message to reveal.
      expect(
        PushIntent.fromData(<String, dynamic>{
          'type': 'dmReaction', 'recipientUid': me, 'actorUid': bob, 'convId': convId,
        }),
        isNull,
      );
    });

    test('one post\'s alerts share a prefix, and differ from another\'s', () {
      final String a = postActivityTag(postId: 'p1', activityId: 'x');
      final String b = postActivityTag(postId: 'p1', activityId: 'y');
      final String other = postActivityTag(postId: 'p2', activityId: 'x');
      expect(a.startsWith(postTagPrefix('p1')), isTrue);
      expect(b.startsWith(postTagPrefix('p1')), isTrue);
      expect(other.startsWith(postTagPrefix('p1')), isFalse);
      expect(a, isNot(b));
    });

    test('a banner is suppressed for the post in front, and nothing else', () {
      PushIntent intent(String postId) => PushIntent(
            kind: PushKind.postLike,
            recipientUid: me,
            actorUid: bob,
            postId: postId,
            receivedAt: DateTime.utc(2026, 9, 1),
          );
      expect(
        shouldShowForegroundBanner(
          intent: intent('p1'), currentUid: me, visibleConvId: null,
          appResumed: true, visiblePostId: 'p1',
        ),
        isFalse,
      );
      expect(
        shouldShowForegroundBanner(
          intent: intent('p2'), currentUid: me, visibleConvId: null,
          appResumed: true, visiblePostId: 'p1',
        ),
        isTrue,
        reason: 'another post is still news',
      );
      // Backgrounded: the post is not really in front.
      expect(
        shouldShowForegroundBanner(
          intent: intent('p1'), currentUid: me, visibleConvId: null,
          appResumed: false, visiblePostId: 'p1',
        ),
        isTrue,
      );
    });

    test('the new categories default on, previews default off, and a saved '
        'document keeps its answers', () {
      const PushPreferences defaults = PushPreferences();
      expect(defaults.postComments, isTrue);
      expect(defaults.postReactions, isTrue);
      expect(defaults.messageReactions, isTrue);
      expect(defaults.commentPreviews, isFalse);

      final PushPreferences saved = PushPreferences.fromMap(<String, dynamic>{
        'friendRequests': false,
        'messagePreviews': true,
      });
      expect(saved.friendRequests, isFalse, reason: 'their answer is kept');
      expect(saved.messagePreviews, isTrue);
      expect(saved.postComments, isTrue, reason: 'a new category starts on');
      expect(saved.commentPreviews, isFalse);
      expect(saved.valueOf(PushPreferences.fPostReactions), isTrue);
      expect(
        saved.withField(PushPreferences.fPostReactions, false).postReactions,
        isFalse,
      );
    });
  });
}

/// The app's route observer is a global in main.dart; tests that need
/// RouteAware callbacks supply their own.
final RouteObserver<ModalRoute<void>> routeObserverForTest =
    RouteObserver<ModalRoute<void>>();
