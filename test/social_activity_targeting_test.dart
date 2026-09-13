/// Getting to the thing an alert was about, and reading exactly that.
///
/// Every UI assertion here drives the PRODUCTION widgets — the real
/// PostDetailPage, its real comments list, the real Activity list — and asks
/// what is on screen afterwards. Publishing a focus request, or reporting an
/// id as visible by hand, would only prove that the test can call a method;
/// these failures were all cases where the call was made and the destination
/// still showed the wrong thing.
///
/// The cases pinned here each failed against 0606d447:
///
///   * a target near the bottom of twenty long comments was never built, so
///     the scroll found no context, did nothing, and marked itself done;
///   * asking for the same target again after scrolling away did nothing;
///   * a subject lookup returning after the route was covered, or after the
///     account changed, still acknowledged;
///   * fifty withdrawn records filled the unread window and hid real ones;
///   * an older like on a post with no comments was never asked about;
///   * pagination on `createdAt <` dropped records sharing a timestamp;
///   * an older row went stale as soon as it was fetched.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/post_media.dart';
import 'package:localtest222/profile/data/identity_repository.dart';
import 'package:localtest222/push/foreground_focus.dart';
import 'package:localtest222/push/foreground_post.dart';
import 'package:localtest222/push/notification_platform.dart';
import 'package:localtest222/push/push_intent.dart';
import 'package:localtest222/social/social_activity_service.dart';
import 'package:localtest222/social/ui/activity_view.dart';
import 'package:localtest222/main.dart' show routeObserver;
import 'package:localtest222/social/ui/post_activity_scope.dart';
import 'package:localtest222/social/user_search_repository.dart';
import 'package:visibility_detector/visibility_detector.dart';

const String me = 'meUidmeUidmeUidmeUidmeUid0001';
const String bob = 'bobUidbobUidbobUidbobUidbob2';
const String carol = 'carolUidcarolUidcarolUidca03';

/// Long enough that a handful fill the viewport and the rest are never built.
const String longText =
    'Really strong work on that last set, the bar speed looked much better '
    'than last week and the brace held all the way through the sticking '
    'point, keep the same cue next session and it should carry over well.';

class StubPlatform extends NotificationPlatform {
  final List<String> cancelled = <String>[];
  List<String> tray = const <String>[];

  @override
  Future<List<String>> deliveredTags() async => tray;

  @override
  Future<int> clearNotifications({
    List<String> tagPrefixes = const <String>[],
    List<String> tags = const <String>[],
    List<String> convIds = const <String>[],
  }) async {
    cancelled.addAll(tags);
    return tags.length;
  }

  @override
  Future<void> clearDelivered() async {}
}

Future<void> seedActivity(
  FakeFirebaseFirestore db, {
  required String id,
  required String type,
  String owner = me,
  String actor = bob,
  String? postId,
  String? commentId,
  String? convId,
  String? messageId,
  bool read = false,
  bool invalidated = false,
  DateTime? at,
  int minutesAgo = 0,
}) async {
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
    'tag': postId != null
        ? postActivityTag(postId: postId, activityId: id)
        : dmReactionTag(convId: convId!, activityId: id),
    'createdAt': Timestamp.fromDate(
      at ?? DateTime.utc(2026, 9, 1, 12).subtract(Duration(minutes: minutesAgo)),
    ),
  });
}

Future<void> seedComment(
  FakeFirebaseFirestore db,
  String postId,
  String commentId, {
  String uid = bob,
  String text = longText,
  int minutesAgo = 0,
}) async {
  await db
      .collection('posts')
      .doc(postId)
      .collection('comments')
      .doc(commentId)
      .set(<String, Object?>{
    'uid': uid,
    'username': 'Sam',
    'text': text,
    'createdAt': Timestamp.fromDate(
        DateTime.utc(2026, 9, 1, 12).subtract(Duration(minutes: minutesAgo))),
  });
}

Post samplePost(String id) => Post(
      id: id,
      ownerUid: me,
      mediaType: 'image',
      storagePathOriginal: 'p/$id',
      smallUrl: '',
      thumbUrl: '',
      caption: null,
      likeCount: 0,
      goodLiftCount: 0,
      commentCount: 0,
      createdAt: Timestamp.fromDate(DateTime.utc(2026, 9, 1)),
    );

Future<bool> readInStore(FakeFirebaseFirestore db, String id) async {
  final DocumentSnapshot<Map<String, dynamic>> s = await db
      .collection('users')
      .doc(me)
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
    // The detector batches callbacks on a timer; in a test the frames are
    // ours, so it has to report as it happens.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    db = FakeFirebaseFirestore();
    platform = StubPlatform();
    signedIn = me;
    service = SocialActivityService(
      firestore: db,
      currentUid: () => signedIn,
      notifications: platform,
    );
    ForegroundPost.reset();
    ForegroundFocus.reset();
  });

  tearDown(() async => service.dispose());

  Future<void> settle(WidgetTester t) async {
    for (int i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 30));
    }
  }

  /// The production page, with the fakes its Firebase calls need.
  Widget page({String? focusCommentId, String? focusActivityId}) => MaterialApp(
        navigatorObservers: <NavigatorObserver>[routeObserver],
        home: PostDetailPage(
          post: samplePost('P'),
          canDelete: false,
          focusCommentId: focusCommentId,
          focusActivityId: focusActivityId,
          firestore: db,
          identity: IdentityRepository(firestore: db),
          activityService: service,
          onToggleLike: (_) async {},
          onToggleGoodLift: (_) async {},
          onAddComment: (_, __) async {},
        ),
      );

  /// Is [commentId]'s row actually within the comments viewport?
  bool onScreen(WidgetTester t, String commentId) {
    final Finder row = find.byKey(Key('comment-vis-P-$commentId'));
    if (row.evaluate().isEmpty) return false;
    final Finder list = find.byType(ListView);
    final RenderBox listBox = t.renderObject<RenderBox>(list);
    final Offset listTop = listBox.localToGlobal(Offset.zero);
    final Rect viewport = listTop & listBox.size;
    final RenderBox rowBox = t.renderObject<RenderBox>(row.first);
    final Rect rect = rowBox.localToGlobal(Offset.zero) & rowBox.size;
    return rect.top < viewport.bottom && rect.bottom > viewport.top;
  }

  // ══ 1. Comment targeting through the rendered list ═════════════════════════

  group('the comment an alert is about is actually shown', () {
    testWidgets('a target near the bottom of twenty long comments is on screen',
        (WidgetTester t) async {
      for (int i = 0; i < 20; i++) {
        await seedComment(db, 'P', 'c$i', minutesAgo: i);
      }
      // The eighteenth comment down: far outside the viewport, and outside
      // what the list builds ahead.
      await seedActivity(db, id: 'a-deep', type: 'postComment',
          postId: 'P', commentId: 'c17');
      service.watch();
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.pumpWidget(page(focusCommentId: 'c17', focusActivityId: 'a-deep'));
      await settle(t);
      await settle(t);

      expect(find.byKey(const Key('comment-focused-row')), findsOneWidget,
          reason: 'the target is rendered at all');
      expect(onScreen(t, 'c17'), isTrue,
          reason: 'and it is in the viewport, not merely in the widget tree');
      expect(await readInStore(db, 'a-deep'), isTrue,
          reason: 'being genuinely presented is what reads it');
    });

    testWidgets('a target outside the loaded page is fetched and shown',
        (WidgetTester t) async {
      for (int i = 0; i < 20; i++) {
        await seedComment(db, 'P', 'c$i', minutesAgo: i);
      }
      // Older than the twenty the list loads.
      await seedComment(db, 'P', 'ancient', minutesAgo: 5000);
      await seedActivity(db, id: 'a-old', type: 'postComment',
          postId: 'P', commentId: 'ancient', minutesAgo: 5000);
      service.watch();
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.pumpWidget(
          page(focusCommentId: 'ancient', focusActivityId: 'a-old'));
      await settle(t);
      await settle(t);

      expect(onScreen(t, 'ancient'), isTrue);
      expect(await readInStore(db, 'a-old'), isTrue);
    });

    testWidgets('a second target is revealed, and asking for the first again '
        'after scrolling away brings it back', (WidgetTester t) async {
      for (int i = 0; i < 20; i++) {
        await seedComment(db, 'P', 'c$i', minutesAgo: i);
      }
      await seedActivity(db, id: 'a-17', type: 'postComment',
          postId: 'P', commentId: 'c17');
      await seedActivity(db, id: 'a-12', type: 'postComment',
          postId: 'P', commentId: 'c12');
      service.watch();
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.pumpWidget(page(focusCommentId: 'c17', focusActivityId: 'a-17'));
      await settle(t);
      expect(onScreen(t, 'c17'), isTrue);

      // A second alert about this same post, pointing somewhere else. The page
      // is already open, so this is the ForegroundFocus path.
      ForegroundPost.shown('P');
      ForegroundFocus.request(subjectId: 'P', targetId: 'c12');
      await settle(t);
      await settle(t);
      expect(onScreen(t, 'c12'), isTrue, reason: 'the page moved to it');
      expect(await readInStore(db, 'a-12'), isTrue);

      // The person scrolls away, then taps the SAME alert again.
      await t.drag(find.byType(ListView), const Offset(0, -400));
      await settle(t);
      expect(onScreen(t, 'c12'), isFalse, reason: 'scrolled past it');

      ForegroundFocus.request(subjectId: 'P', targetId: 'c12');
      await settle(t);
      await settle(t);
      expect(onScreen(t, 'c12'), isTrue,
          reason: 'the same target again is still a request to show it');
    });

    testWidgets('a comment scrolled out of view stops suppressing its banner',
        (WidgetTester t) async {
      for (int i = 0; i < 20; i++) {
        await seedComment(db, 'P', 'c$i', minutesAgo: i);
      }
      service.watch();
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(page());
      await settle(t);

      expect(ForegroundPost.isCommentVisible('P', 'c0'), isTrue);
      await t.drag(find.byType(ListView), const Offset(0, -600));
      await settle(t);
      await settle(t);
      expect(ForegroundPost.isCommentVisible('P', 'c0'), isFalse,
          reason: 'what is on screen is a statement about now, not about ever');
    });
  });

  // ══ 2. Guards around the asynchronous subject lookup ═══════════════════════

  group('a lookup in flight cannot acknowledge for a page that has gone', () {
    /// A service whose per-subject lookup is held open, so the test can decide
    /// what happens WHILE it is in flight.
    late Completer<void> gate;
    late _HeldLookupService held;

    void makeHeld() {
      gate = Completer<void>();
      held = _HeldLookupService(
        firestore: db,
        currentUid: () => signedIn,
        notifications: platform,
        gate: gate.future,
      );
    }

    testWidgets('an account switch during the lookup acknowledges nothing',
        (WidgetTester t) async {
      // Not in the live window: only the subject lookup can find it.
      for (int i = 0; i < 55; i++) {
        await seedActivity(db, id: 'n$i', type: 'postLike',
            postId: 'OTHER$i', minutesAgo: i);
      }
      await seedActivity(db, id: 'a1', type: 'postLike',
          postId: 'P', minutesAgo: 900);
      makeHeld();
      addTearDown(held.dispose);
      held.watch();
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.pumpWidget(MaterialApp(
        home: PostActivityScope(
          postId: 'P',
          service: held,
          child: const SizedBox.shrink(),
        ),
      ));
      await settle(t);
      expect(held.lookups, greaterThan(0), reason: 'the lookup is in flight');

      // The account switches, and only THEN does the lookup return.
      signedIn = carol;
      held.onAccountChanged(carol);
      gate.complete();
      await settle(t);
      await settle(t);

      expect(await readInStore(db, 'a1'), isFalse,
          reason: "another account's page may not read this one's activity");
    });

    testWidgets('a route covered during the lookup acknowledges nothing',
        (WidgetTester t) async {
      for (int i = 0; i < 55; i++) {
        await seedActivity(db, id: 'n$i', type: 'postLike',
            postId: 'OTHER$i', minutesAgo: i);
      }
      await seedActivity(db, id: 'a1', type: 'postLike',
          postId: 'P', minutesAgo: 900);
      makeHeld();
      addTearDown(held.dispose);
      held.watch();
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: <NavigatorObserver>[routeObserver],
        home: PostActivityScope(
          postId: 'P',
          service: held,
          child: const SizedBox.shrink(),
        ),
      ));
      await settle(t);
      expect(held.lookups, greaterThan(0));

      // Another screen covers the post, and then the lookup returns.
      unawaited(nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('on top')),
      )));
      await settle(t);
      gate.complete();
      await settle(t);
      await settle(t);

      expect(find.text('on top'), findsOneWidget);
      expect(await readInStore(db, 'a1'), isFalse,
          reason: 'a post under another screen presents nothing');
    });
  });

  // ══ 3. Withdrawn records must not crowd out real ones ══════════════════════

  group('retired records cannot hide live ones', () {
    testWidgets('fifty newer withdrawn records still leave the badge right',
        (WidgetTester t) async {
      for (int i = 0; i < 50; i++) {
        await seedActivity(db, id: 'dead$i', type: 'postLike',
            postId: 'X$i', invalidated: true, minutesAgo: i);
      }
      // Older, and perfectly real.
      await seedActivity(db, id: 'live1', type: 'postLike',
          postId: 'P', minutesAgo: 500);
      await seedActivity(db, id: 'live2', type: 'postComment',
          postId: 'P', commentId: 'c1', minutesAgo: 501);

      service.watch();
      await settle(t);
      expect(service.unreadCount, 2,
          reason: 'withdrawn records take no room in the window');
      expect(service.snapshot.unread.map((SocialActivity a) => a.id),
          unorderedEquals(<String>['live1', 'live2']));
    });

    testWidgets('a whole page of withdrawn records does not become an empty '
        'Activity list', (WidgetTester t) async {
      for (int i = 0; i < 60; i++) {
        await seedActivity(db, id: 'dead$i', type: 'postLike',
            postId: 'X$i', invalidated: true, minutesAgo: i);
      }
      await seedActivity(db, id: 'realOne', type: 'postLike',
          postId: 'P', minutesAgo: 900);

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

      expect(find.byKey(const Key('activity-realOne')), findsOneWidget,
          reason: 'real activity is not stranded behind withdrawn records');
      expect(find.text('Nothing yet'), findsNothing);
    });

    testWidgets('a per-subject lookup skips withdrawn records too',
        (WidgetTester t) async {
      for (int i = 0; i < 60; i++) {
        await seedActivity(db, id: 'dead$i', type: 'postComment',
            postId: 'P', commentId: 'x$i', invalidated: true, minutesAgo: i);
      }
      await seedActivity(db, id: 'live', type: 'postLike',
          postId: 'P', minutesAgo: 800);
      final List<SocialActivity> found =
          await service.unreadForSubjectFromServer('post:P');
      expect(found.map((SocialActivity a) => a.id), <String>['live']);
    });
  });

  // ══ 4. Reaching a target no window contains ════════════════════════════════

  group('the interaction that was tapped is always reachable', () {
    testWidgets('an older like on a post with no comments is read on opening',
        (WidgetTester t) async {
      // Fifty newer unread interactions elsewhere fill the live window.
      for (int i = 0; i < 55; i++) {
        await seedActivity(db, id: 'n$i', type: 'postLike',
            postId: 'OTHER$i', minutesAgo: i);
      }
      await seedActivity(db, id: 'oldLike', type: 'postLike',
          postId: 'P', minutesAgo: 999);
      service.watch();
      await settle(t);
      expect(service.snapshot.unread.any((SocialActivity a) => a.id == 'oldLike'),
          isFalse, reason: 'it really is outside the live window');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      // No comments at all on this post: nothing to report as displayed.
      await t.pumpWidget(page(focusActivityId: 'oldLike'));
      await settle(t);
      await settle(t);

      expect(await readInStore(db, 'oldLike'), isTrue,
          reason: 'the post presents its likes, whatever window they are in');
      expect(platform.cancelled,
          contains(postActivityTag(postId: 'P', activityId: 'oldLike')));
    });

    testWidgets('a target outside the per-subject window is still acknowledged',
        (WidgetTester t) async {
      // More unread interactions on this ONE post than the per-subject query
      // will ever return, all newer than the one the alert names.
      for (int i = 0; i < 60; i++) {
        await seedActivity(db, id: 's$i', type: 'postComment',
            postId: 'P', commentId: 'other$i', minutesAgo: i);
      }
      await seedActivity(db, id: 'target', type: 'postLike',
          postId: 'P', minutesAgo: 4000);
      service.watch();
      await settle(t);
      final List<SocialActivity> window =
          await service.unreadForSubjectFromServer('post:P');
      expect(window.any((SocialActivity a) => a.id == 'target'), isFalse,
          reason: 'outside the per-subject window as well');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.pumpWidget(page(focusActivityId: 'target'));
      await settle(t);
      await settle(t);

      expect(await readInStore(db, 'target'), isTrue,
          reason: 'named by the alert, so read by id');
    });
  });

  // ══ 5. Pagination ══════════════════════════════════════════════════════════

  group('older activity pages without dropping or repeating anything', () {
    testWidgets('more than fifty records share one timestamp and all appear',
        (WidgetTester t) async {
      // Every record at the SAME instant. A `createdAt < cursor` page boundary
      // loses the whole tied group; document order is the only thing that can
      // separate them.
      final DateTime same = DateTime.utc(2026, 9, 1, 10);
      for (int i = 0; i < 60; i++) {
        await seedActivity(db, id: 'tie${i.toString().padLeft(2, '0')}',
            type: 'postLike', postId: 'P$i', at: same);
      }

      // The two windows the list is built from, as the list gets them.
      final List<SocialActivity> live = await service.watchRecent().first;
      final List<List<SocialActivity>> older = <List<SocialActivity>>[];
      final StreamSubscription<List<SocialActivity>> sub = service
          .watchOlderThan(anchor: live.last, limit: 50)
          .listen(older.add);
      await settle(t);
      unawaited(sub.cancel());

      final List<String> ids = <String>[
        for (final SocialActivity a in live) a.id,
        for (final SocialActivity a in older.isEmpty ? const <SocialActivity>[] : older.last)
          a.id,
      ];
      expect(ids.toSet().length, ids.length, reason: 'nothing is listed twice');
      expect(ids.length, 60,
          reason: 'and nothing falls between the pages either');

      // And the list really does render the tail of that tied group.
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
      for (int i = 0; i < 40; i++) {
        final Finder more =
            find.byKey(const ValueKey<String>('activity-load-older'));
        if (more.evaluate().isNotEmpty) {
          await t.tap(more);
          await settle(t);
          break;
        }
        await t.drag(find.byType(ListView), const Offset(0, -400));
        await settle(t);
      }
      for (int i = 0; i < 60; i++) {
        if (find.byKey(const Key('activity-tie59')).evaluate().isNotEmpty) break;
        await t.drag(find.byType(ListView), const Offset(0, -400));
        await settle(t);
      }
      expect(find.byKey(const Key('activity-tie59')), findsOneWidget,
          reason: 'the last of the tied records is reachable on screen');
    });

    testWidgets('an older row shows a read that happened after it was fetched',
        (WidgetTester t) async {
      for (int i = 0; i < 55; i++) {
        await seedActivity(db, id: 'r${i.toString().padLeft(2, '0')}',
            type: 'postLike', postId: 'P$i', minutesAgo: i);
      }
      service.watch();
      await settle(t);
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
      for (int i = 0; i < 40; i++) {
        if (find
            .byKey(const ValueKey<String>('activity-load-older'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await t.drag(find.byType(ListView), const Offset(0, -400));
        await settle(t);
      }
      await t.tap(find.byKey(const ValueKey<String>('activity-load-older')));
      await settle(t);
      expect(find.byKey(const Key('activity-r54'), skipOffstage: false),
          findsOneWidget);

      // That older interaction is read somewhere else, and withdrawn.
      await db
          .collection('users')
          .doc(me)
          .collection('socialActivity')
          .doc('r54')
          .update(<String, Object?>{'invalidated': true});
      await settle(t);

      expect(find.byKey(const Key('activity-r54'), skipOffstage: false),
          findsNothing,
          reason: 'an older row is live, not a copy taken when it was fetched');
    });
  });
}

/// A service whose per-subject lookup only returns when the test says so.
/// Everything else is the production implementation.
class _HeldLookupService extends SocialActivityService {
  _HeldLookupService({
    required super.firestore,
    required super.currentUid,
    required super.notifications,
    required this.gate,
  });

  final Future<void> gate;
  int lookups = 0;

  @override
  Future<List<SocialActivity>> unreadForSubjectFromServer(
    String subject, {
    int limit = SocialActivityService.kSubjectLimit,
  }) async {
    lookups++;
    await gate;
    return super.unreadForSubjectFromServer(subject, limit: limit);
  }
}
