/// Notification targets, and what actually marks them read — through the real
/// widgets, the real router and the real service.
///
/// These are the regressions behind a specific set of complaints: badges that
/// would not clear, alerts that stayed in the tray, an Activity row that
/// counted as having read the comment it merely pointed at, a tap that opened
/// a post without the comment it was about, and a second tap dismissed as a
/// duplicate because it happened to share a post.
///
/// Everything here runs against a fake Firestore and the production widgets.
/// Nothing asserts on a private helper that the screens do not use.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/push/foreground_conversation.dart';
import 'package:localtest222/push/foreground_focus.dart';
import 'package:localtest222/push/foreground_post.dart';
import 'package:localtest222/push/notification_platform.dart';
import 'package:localtest222/push/push_intent.dart';
import 'package:localtest222/social/open_feed_post.dart';
import 'package:localtest222/social/social_activity_service.dart';
import 'package:localtest222/social/ui/activity_view.dart';
import 'package:localtest222/social/user_search_repository.dart';
import 'package:localtest222/social/ui/post_activity_scope.dart';

const String me = 'meUidmeUidmeUidmeUidmeUid0001';
const String bob = 'bobUidbobUidbobUidbobUidbob2';
const String carol = 'carolUidcarolUidcarolUidca03';

class StubPlatform extends NotificationPlatform {
  StubPlatform({this.tray = const <String>[]});

  /// What the OS says is in the tray right now.
  List<String> tray;
  final List<String> cancelled = <String>[];
  bool trayUnsupported = false;

  @override
  Future<List<String>> deliveredTags() async {
    if (trayUnsupported) return const <String>[];
    return tray;
  }

  @override
  Future<int> clearNotifications({
    List<String> tagPrefixes = const <String>[],
    List<String> tags = const <String>[],
    List<String> convIds = const <String>[],
  }) async {
    cancelled.addAll(tags);
    tray = tray.where((String t) => !tags.contains(t)).toList();
    return tags.length;
  }

  @override
  Future<void> clearDelivered() async {}
}

Future<void> seed(
  FakeFirebaseFirestore db, {
  required String id,
  required String type,
  String owner = me,
  String actor = bob,
  String? postId,
  String? commentId,
  String? convId,
  String? messageId,
  String? emoji,
  bool read = false,
  bool invalidated = false,
  int minutesAgo = 0,
}) async {
  final String tag = postId != null
      ? postActivityTag(postId: postId, activityId: id)
      : dmReactionTag(convId: convId!, activityId: id);
  await db
      .collection('users')
      .doc(owner)
      .collection('socialActivity')
      .doc(id)
      .set(<String, Object?>{
    'type': type,
    'actorUid': actor,
    'subject': postId != null ? 'post:$postId' : 'dm:$convId',
    'read': read,
    'invalidated': invalidated,
    if (postId != null) 'postId': postId,
    if (commentId != null) 'commentId': commentId,
    if (convId != null) 'conversationId': convId,
    if (messageId != null) 'messageId': messageId,
    if (emoji != null) 'emoji': emoji,
    'tag': tag,
    'createdAt': Timestamp.fromDate(
      DateTime.utc(2026, 9, 1, 12).subtract(Duration(minutes: minutesAgo)),
    ),
  });
}

Future<bool> readInStore(FakeFirebaseFirestore db, String id,
    {String owner = me}) async {
  final DocumentSnapshot<Map<String, dynamic>> s = await db
      .collection('users')
      .doc(owner)
      .collection('socialActivity')
      .doc(id)
      .get();
  return s.data()?['read'] == true;
}

void main() {
  late FakeFirebaseFirestore db;
  late StubPlatform platform;
  late SocialActivityService service;
  String? signedIn;

  setUp(() {
    db = FakeFirebaseFirestore();
    platform = StubPlatform();
    signedIn = me;
    service = SocialActivityService(
      firestore: db,
      currentUid: () => signedIn,
      notifications: platform,
    );
    ForegroundPost.reset();
    ForegroundConversation.reset();
    ForegroundFocus.reset();
  });

  tearDown(() async => service.dispose());

  Future<void> settle(WidgetTester t) async {
    for (int i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
  }

  // ══ 1. The Activity list points; it does not present ═══════════════════════

  group('opening Activity does not read anything', () {
    testWidgets('scrolling rows past the eye leaves every one of them unread',
        (WidgetTester t) async {
      for (int i = 0; i < 12; i++) {
        await seed(db,
            id: 'a$i', type: 'postComment', postId: 'P', commentId: 'c$i',
            minutesAgo: i);
      }
      service.watch();
      await settle(t);
      expect(service.unreadCount, 12);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ActivityView(
              active: true,
              service: service,
              search: UserSearchRepository(firestore: db),
              viewerUid: me,
            ),
          ),
        ),
      ));
      await settle(t);
      expect(find.byType(InkWell), findsWidgets, reason: 'rows are rendered');

      // Every row on screen, then scrolled through top to bottom.
      await t.drag(find.byType(ListView), const Offset(0, -600));
      await settle(t);
      await t.drag(find.byType(ListView), const Offset(0, 600));
      await settle(t);

      expect(service.unreadCount, 12,
          reason: 'a pointer to a comment is not the comment');
      expect(platform.cancelled, isEmpty,
          reason: 'and no alert may be cancelled on the strength of it');
      expect(await readInStore(db, 'a0'), isFalse);
    });

    testWidgets('older activity is reachable, and still unread when it arrives',
        (WidgetTester t) async {
      // 55 records: more than one page, oldest ones well outside the window.
      for (int i = 0; i < 55; i++) {
        await seed(db,
            id: 'a${i.toString().padLeft(2, '0')}',
            type: 'postLike', postId: 'P$i', minutesAgo: i, read: i > 5);
      }
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: ActivityView(
              active: true,
              service: service,
              search: UserSearchRepository(firestore: db),
              viewerUid: me,
            ),
          ),
        ),
      ));
      await settle(t);

      expect(find.byKey(const Key('activity-a54')), findsNothing,
          reason: 'the oldest is beyond the first page');

      Future<void> scrollToEnd() async {
        for (int i = 0; i < 30; i++) {
          if (find.byKey(const ValueKey<String>('activity-load-older'))
              .evaluate()
              .isNotEmpty) {
            return;
          }
          await t.drag(find.byType(ListView), const Offset(0, -400));
          await settle(t);
        }
      }

      await scrollToEnd();
      expect(find.byKey(const ValueKey<String>('activity-load-older')),
          findsOneWidget);
      await t.tap(find.byKey(const ValueKey<String>('activity-load-older')));
      await settle(t);

      for (int i = 0; i < 40; i++) {
        if (find.byKey(const Key('activity-a54')).evaluate().isNotEmpty) break;
        await t.drag(find.byType(ListView), const Offset(0, -400));
        await settle(t);
      }
      expect(find.byKey(const Key('activity-a54')), findsOneWidget,
          reason: 'last month is a tap away, not lost');
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('a withdrawn interaction is not listed and does not count',
        (WidgetTester t) async {
      await seed(db, id: 'a1', type: 'postLike', postId: 'P');
      await seed(db, id: 'a2', type: 'postComment', postId: 'P',
          commentId: 'c1', invalidated: true);
      service.watch();
      await settle(t);

      expect(service.unreadCount, 1, reason: 'the deleted comment counts for nothing');
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ActivityView(
            active: true,
            service: service,
            search: UserSearchRepository(firestore: db),
            viewerUid: me,
          ),
        ),
      ));
      await settle(t);
      expect(find.byKey(const Key('activity-a1')), findsOneWidget);
      expect(find.byKey(const Key('activity-a2')), findsNothing);
    });
  });

  // ══ 2. Badges, second subscribers and account isolation ════════════════════

  group('the badge is right for whoever is signed in', () {
    testWidgets('a badge built after the first snapshot is not stuck at zero',
        (WidgetTester t) async {
      await seed(db, id: 'a1', type: 'postLike', postId: 'P');
      await seed(db, id: 'a2', type: 'postLike', postId: 'Q');

      final List<int> first = <int>[];
      final StreamSubscription<SocialActivitySnapshot> one =
          service.watch().listen((SocialActivitySnapshot s) => first.add(s.unreadCount));
      await settle(t);
      expect(first.last, 2);

      // A second header, opened later, subscribes to a broadcast stream that
      // has already fired.
      final List<int> second = <int>[];
      final StreamSubscription<SocialActivitySnapshot> two =
          service.watch().listen((SocialActivitySnapshot s) => second.add(s.unreadCount));
      await settle(t);
      expect(second, isNotEmpty, reason: 'the current state is replayed');
      expect(second.first, 2);

      // Not awaited: inside testWidgets, awaiting the cancel of ANY broadcast
      // subscription never returns, so it would say nothing about this one.
      unawaited(one.cancel());
      unawaited(two.cancel());
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets("a subscriber appearing mid-switch never sees the other "
        "account's count", (WidgetTester t) async {
      await seed(db, id: 'a1', type: 'postLike', postId: 'P');
      final StreamSubscription<SocialActivitySnapshot> one =
          service.watch().listen((_) {});
      await settle(t);
      expect(service.unreadCount, 1);

      // Signed out; the service has not been told yet.
      signedIn = carol;
      final List<int> late_ = <int>[];
      final StreamSubscription<SocialActivitySnapshot> two =
          service.watch().listen((SocialActivitySnapshot s) => late_.add(s.unreadCount));
      await settle(t);
      expect(late_.where((int c) => c > 0), isEmpty,
          reason: "carol is never shown me's unread interactions");

      unawaited(one.cancel());
      unawaited(two.cancel());
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  // ══ 3. Reading a target outside the live window ════════════════════════════

  group('an old interaction can still be read', () {
    testWidgets('a comment under fifty newer READ records is acknowledged when '
        'the post shows it', (WidgetTester t) async {
      // The one that matters is old and unread; everything newer is read, so
      // the live unread window does not contain it at all.
      await seed(db, id: 'old', type: 'postComment', postId: 'P',
          commentId: 'c-old', minutesAgo: 5000);
      for (int i = 0; i < 60; i++) {
        await seed(db, id: 'n$i', type: 'postLike', postId: 'Q',
            read: true, minutesAgo: i);
      }
      service.watch();
      await settle(t);
      expect(service.snapshot.unread.map((SocialActivity a) => a.id),
          <String>['old']);

      // Prove the point even when the live view has been emptied: the screen
      // must be able to find it by subject.
      final List<SocialActivity> found =
          await service.unreadForSubjectFromServer('post:P');
      expect(found.map((SocialActivity a) => a.id), <String>['old']);

      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(MaterialApp(
        home: PostActivityScope(
          postId: 'P',
          service: service,
          child: Builder(builder: (BuildContext context) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              PostActivityScope.of(context)
                  ?.reportDisplayedComments(<String>['c-old']);
            });
            return const SizedBox.shrink();
          }),
        ),
      ));
      await settle(t);
      await t.pump(const Duration(milliseconds: 50));
      await settle(t);

      expect(await readInStore(db, 'old'), isTrue,
          reason: 'presented on screen, however old it is');
      expect(platform.cancelled,
          contains(postActivityTag(postId: 'P', activityId: 'old')));
    });

    testWidgets('reconciliation cancels an alert whose record is far outside '
        'the newest page', (WidgetTester t) async {
      await seed(db, id: 'old', type: 'postLike', postId: 'P',
          read: true, minutesAgo: 9000);
      for (int i = 0; i < 60; i++) {
        await seed(db, id: 'n$i', type: 'postLike', postId: 'Q', minutesAgo: i);
      }
      final String staleTag = postActivityTag(postId: 'P', activityId: 'old');
      platform.tray = <String>[staleTag, 'post|zzzz|n1'];
      service.watch();
      await settle(t);

      await service.reconcileDeliveredAlerts();
      await settle(t);

      expect(platform.cancelled, contains(staleTag),
          reason: 'the tray names the record, so the window does not matter');
      expect(platform.cancelled, isNot(contains('post|zzzz|n1')),
          reason: 'an unread interaction keeps its alert');
    });

    testWidgets('a withdrawn interaction loses its alert on reconciliation',
        (WidgetTester t) async {
      await seed(db, id: 'a1', type: 'postComment', postId: 'P',
          commentId: 'c1', invalidated: true);
      final String tag = postActivityTag(postId: 'P', activityId: 'a1');
      platform.tray = <String>[tag];
      service.watch();
      await settle(t);

      await service.reconcileDeliveredAlerts();
      await settle(t);
      expect(platform.cancelled, contains(tag));
    });
  });

  // (Routing itself — which tap opens what, and which reveals a target in a
  // page already open — runs against the real Navigator in
  // push_permission_routing_test.dart.)

  // ══ 4. Account checks survive the fetch ════════════════════════════════════

  group('a slow fetch cannot open the wrong account\'s post', () {
    testWidgets('logging out during the post fetch opens nothing',
        (WidgetTester t) async {
      await db.collection('posts').doc('P').set(<String, Object?>{
        'ownerUid': me,
        'mediaType': 'image',
        'createdAt': Timestamp.now(),
      });

      String? account = me;
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: SizedBox.shrink()),
      ));

      final Future<bool> opening = openPostById(
        nav.currentContext!,
        'P',
        viewerUid: me,
        firestore: db,
        // Logged out while the read is in flight.
        stillValid: () => account == me,
      );
      account = null;
      final bool opened = await opening;
      await settle(t);

      expect(opened, isFalse,
          reason: "the post belongs to an account that is no longer signed in");
      expect(find.byType(PageRoute<void>), findsNothing);
    });

    testWidgets('an account still signed in opens normally',
        (WidgetTester t) async {
      await db.collection('posts').doc('P').set(<String, Object?>{
        'ownerUid': me,
        'mediaType': 'image',
        'createdAt': Timestamp.now(),
      });
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: SizedBox.shrink()),
      ));
      final bool opened = await openPostById(
        nav.currentContext!,
        'P',
        viewerUid: me,
        firestore: db,
        stillValid: () => true,
      );
      expect(opened, isTrue);
    });
  });

  // ══ 6. Banners ═════════════════════════════════════════════════════════════

  group('a banner is suppressed only for what is actually on screen', () {
    PushIntent comment(String postId, String commentId) => PushIntent(
          kind: PushKind.postComment,
          recipientUid: me,
          actorUid: bob,
          postId: postId,
          commentId: commentId,
          activityId: 'pc_x',
          receivedAt: DateTime.utc(2026, 9, 1),
        );

    test('the post being open is not the comment being visible', () {
      expect(
        shouldShowForegroundBanner(
          intent: comment('P', 'c-new'),
          currentUid: me,
          visibleConvId: null,
          visiblePostId: 'P',
          appResumed: true,
          targetOnScreen: false,
        ),
        isTrue,
        reason: 'a comment further up the thread has not been seen',
      );
      expect(
        shouldShowForegroundBanner(
          intent: comment('P', 'c-new'),
          currentUid: me,
          visibleConvId: null,
          visiblePostId: 'P',
          appResumed: true,
          targetOnScreen: true,
        ),
        isFalse,
        reason: 'it is right there on screen',
      );
    });

    test('an interaction already acknowledged never banners', () {
      expect(
        shouldShowForegroundBanner(
          intent: comment('Q', 'c1'),
          currentUid: me,
          visibleConvId: null,
          visiblePostId: 'P',
          appResumed: true,
          alreadyAcknowledged: true,
        ),
        isFalse,
      );
    });

    test('the visible-comment registry answers per post and per comment', () {
      ForegroundPost.shown('P');
      ForegroundPost.reportVisibleComments('P', <String>{'c1', 'c2'});
      expect(ForegroundPost.isCommentVisible('P', 'c1'), isTrue);
      expect(ForegroundPost.isCommentVisible('P', 'c9'), isFalse);
      expect(ForegroundPost.isCommentVisible('Q', 'c1'), isFalse);
      // Covered by another post: nothing of P's is on screen.
      ForegroundPost.shown('Q');
      expect(ForegroundPost.isCommentVisible('P', 'c1'), isFalse);
    });

    test('the visible-message registry answers per conversation', () {
      const String conv = 'a_b';
      ForegroundConversation.shown(conv);
      ForegroundConversation.reportVisibleMessages(conv, <String>{'m1'});
      expect(ForegroundConversation.isMessageVisible(conv, 'm1'), isTrue);
      expect(ForegroundConversation.isMessageVisible(conv, 'm-old'), isFalse);
      ForegroundConversation.reportVisibleMessages(conv, <String>{});
      expect(ForegroundConversation.isMessageVisible(conv, 'm1'), isFalse);
    });
  });

  // ══ 7. Acknowledgement is not swept ════════════════════════════════════════

  testWidgets('an interaction arriving while a post is open is not read by the '
      'acknowledgement already in flight', (WidgetTester t) async {
    await seed(db, id: 'a1', type: 'postComment', postId: 'P', commentId: 'c1');
    service.watch();
    await settle(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    final ValueNotifier<List<String>> shown =
        ValueNotifier<List<String>>(<String>['c1']);
    await t.pumpWidget(MaterialApp(
      home: PostActivityScope(
        postId: 'P',
        service: service,
        child: ValueListenableBuilder<List<String>>(
          valueListenable: shown,
          builder: (BuildContext context, List<String> ids, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              PostActivityScope.of(context)?.reportDisplayedComments(ids);
            });
            return const SizedBox.shrink();
          },
        ),
      ),
    ));
    await settle(t);
    await t.pump(const Duration(milliseconds: 50));
    expect(await readInStore(db, 'a1'), isTrue);

    // A new comment lands. It is NOT on screen — the list has not shown it.
    await seed(db, id: 'a2', type: 'postComment', postId: 'P',
        commentId: 'c2', actor: carol);
    await settle(t);
    await t.pump(const Duration(milliseconds: 50));
    expect(await readInStore(db, 'a2'), isFalse,
        reason: 'it was never presented, so the open page does not read it');

    // Once it is genuinely on screen, it is read.
    shown.value = <String>['c1', 'c2'];
    await settle(t);
    await t.pump(const Duration(milliseconds: 50));
    await settle(t);
    expect(await readInStore(db, 'a2'), isTrue);
  });
}
