/// Taps that land on a destination ALREADY on screen.
///
/// Routing that reaches an open page publishes a focus request instead of
/// navigating. That request used to carry only "which page" and "which
/// comment", which was not enough:
///
///   * the interaction's own record never travelled with it, so an older
///     comment or reaction — outside the unread window AND outside the
///     per-subject window — could be scrolled to while its badge and its
///     alert stayed exactly where they were;
///   * a like or Good Lift for the open post carried no target at all, so the
///     tap was dropped and its record never read;
///   * the open page compared TARGET IDS, so tapping the same alert again
///     after scrolling away did nothing, for the rest of the page's life.
///
/// These drive the production page and the production focus channel.
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
import 'package:visibility_detector/visibility_detector.dart';

const String me = 'meUidmeUidmeUidmeUidmeUid0001';
const String bob = 'bobUidbobUidbobUidbobUidbob2';
const String carol = 'carolUidcarolUidcarolUidca03';

const String longText =
    'Really strong work on that last set, the bar speed looked much better '
    'than last week and the brace held all the way through the sticking '
    'point, keep the same cue next session and it should carry over well.';

class StubPlatform extends NotificationPlatform {
  final List<String> cancelled = <String>[];

  @override
  Future<List<String>> deliveredTags() async => const <String>[];

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

/// A service whose by-id lookup is held open until the test releases it.
class HeldByIdService extends SocialActivityService {
  HeldByIdService({
    required super.firestore,
    required super.currentUid,
    required super.notifications,
  });

  final Completer<void> _gate = Completer<void>();
  final List<String> asked = <String>[];

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<SocialActivity?> activityById(String activityId) async {
    asked.add(activityId);
    await _gate.future;
    return super.activityById(activityId);
  }
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
        DateTime.utc(2026, 9, 1, 12).subtract(Duration(minutes: minutesAgo))),
  });
}

Future<void> seedComment(
  FakeFirebaseFirestore db,
  String postId,
  String commentId, {
  int minutesAgo = 0,
}) async {
  await db
      .collection('posts')
      .doc(postId)
      .collection('comments')
      .doc(commentId)
      .set(<String, Object?>{
    'uid': bob,
    'username': 'Sam',
    'text': longText,
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

  Widget page({SocialActivityService? withService}) => MaterialApp(
        home: PostDetailPage(
          post: samplePost('P'),
          canDelete: false,
          viewerUid: me,
          firestore: db,
          identity: IdentityRepository(firestore: db),
          activityService: withService ?? service,
          onToggleLike: (_) async {},
          onToggleGoodLift: (_) async {},
          onAddComment: (_, __) async {},
        ),
      );

  bool onScreen(WidgetTester t, String commentId) {
    final Finder row = find.byKey(Key('comment-vis-P-$commentId'));
    if (row.evaluate().isEmpty) return false;
    final RenderBox listBox = t.renderObject<RenderBox>(find.byType(ListView));
    final Rect viewport = listBox.localToGlobal(Offset.zero) & listBox.size;
    final RenderBox rowBox = t.renderObject<RenderBox>(row.first);
    final Rect rect = rowBox.localToGlobal(Offset.zero) & rowBox.size;
    return rect.top < viewport.bottom && rect.bottom > viewport.top;
  }

  /// Enough newer unread interactions to fill BOTH windows: the live unread
  /// view, and post P's own per-subject list. What is left can be reached only
  /// by the record the tap names.
  ///
  /// The per-subject filler is comments that are never displayed, so opening
  /// the post does not read them.
  Future<void> crowdTheWindow() async {
    for (int i = 0; i < 55; i++) {
      await seedActivity(db, id: 'n$i', type: 'postLike',
          postId: 'OTHER$i', minutesAgo: i);
    }
    for (int i = 0; i < 60; i++) {
      await seedComment(db, 'P', 'filler$i', minutesAgo: 10 + i);
      await seedActivity(db, id: 'sub$i', type: 'postComment',
          postId: 'P', commentId: 'filler$i', minutesAgo: 10 + i);
    }
  }

  /// Fails the test if [id] is reachable by either ordinary window — the point
  /// of these cases is the record the tap carries.
  Future<void> assertOutsideBothWindows(
      SocialActivityService s, String id) async {
    expect(s.snapshot.unread.any((SocialActivity a) => a.id == id), isFalse,
        reason: '$id must be outside the unread window');
    expect(
        (await s.unreadForSubjectFromServer('post:P'))
            .any((SocialActivity a) => a.id == id),
        isFalse,
        reason: '$id must be outside the per-subject window');
  }

  group('a tap into an open post carries its record', () {
    testWidgets('an older COMMENT alert reveals it and reads its record',
        (WidgetTester t) async {
      await crowdTheWindow();
      for (int i = 0; i < 20; i++) {
        await seedComment(db, 'P', 'c$i', minutesAgo: i);
      }
      await seedComment(db, 'P', 'ancient', minutesAgo: 9000);
      await seedActivity(db, id: 'deep', type: 'postComment',
          postId: 'P', commentId: 'ancient', minutesAgo: 9000);
      service.watch();
      await settle(t);
      await assertOutsideBothWindows(service, 'deep');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.pumpWidget(page());
      await settle(t);
      expect(onScreen(t, 'ancient'), isFalse);

      // The alert lands on the post already in front of the person.
      ForegroundPost.shown('P');
      expect(
        ForegroundFocus.request(
          subjectId: 'P',
          targetId: 'ancient',
          activityId: 'deep',
          recipientUid: me,
        ),
        isTrue,
      );
      await settle(t);
      await settle(t);

      expect(onScreen(t, 'ancient'), isTrue, reason: 'the page moved to it');
      expect(await readInStore(db, 'deep'), isTrue,
          reason: 'and the record it named was read');
      expect(platform.cancelled,
          contains(postActivityTag(postId: 'P', activityId: 'deep')));
    });

    testWidgets('an older LIKE alert for the open post reads its record',
        (WidgetTester t) async {
      await crowdTheWindow();
      await seedActivity(db, id: 'oldLike', type: 'postLike',
          postId: 'P', minutesAgo: 9000);
      service.watch();
      await settle(t);
      await assertOutsideBothWindows(service, 'oldLike');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(page());
      await settle(t);
      ForegroundPost.shown('P');

      // A like names no comment: there is nothing to scroll to, but the
      // request must still be made and its record still read.
      expect(
        ForegroundFocus.request(
            subjectId: 'P', activityId: 'oldLike', recipientUid: me),
        isTrue,
      );
      await settle(t);
      await settle(t);
      expect(await readInStore(db, 'oldLike'), isTrue);
    });

    testWidgets('a request addressed to another account is ignored',
        (WidgetTester t) async {
      await crowdTheWindow();
      await seedActivity(db, id: 'notMine', type: 'postLike',
          postId: 'P', minutesAgo: 9000);
      service.watch();
      await settle(t);
      await assertOutsideBothWindows(service, 'notMine');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(page());
      await settle(t);
      ForegroundPost.shown('P');

      ForegroundFocus.request(
          subjectId: 'P', activityId: 'notMine', recipientUid: carol);
      await settle(t);
      await settle(t);
      expect(await readInStore(db, 'notMine'), isFalse,
          reason: 'a tap addressed to another account acts on nothing here');
    });

    testWidgets('a newer request arriving during a lookup is the one that wins',
        (WidgetTester t) async {
      await crowdTheWindow();
      await seedActivity(db, id: 'first', type: 'postLike',
          postId: 'P', minutesAgo: 9000);
      await seedActivity(db, id: 'second', type: 'postLike',
          postId: 'P', minutesAgo: 9001);
      final HeldByIdService held = HeldByIdService(
        firestore: db,
        currentUid: () => signedIn,
        notifications: platform,
      );
      addTearDown(held.dispose);
      held.watch();
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await t.pumpWidget(page(withService: held));
      await settle(t);
      ForegroundPost.shown('P');

      ForegroundFocus.request(
          subjectId: 'P', activityId: 'first', recipientUid: me);
      await settle(t);
      // The second tap lands while the first lookup is still held open.
      ForegroundFocus.request(
          subjectId: 'P', activityId: 'second', recipientUid: me);
      await settle(t);
      held.release();
      await settle(t);
      await settle(t);

      expect(await readInStore(db, 'second'), isTrue,
          reason: 'the newest tap is the one that stands');
    });

    testWidgets('an account switch during the lookup acknowledges nothing',
        (WidgetTester t) async {
      await crowdTheWindow();
      await seedActivity(db, id: 'mine', type: 'postLike',
          postId: 'P', minutesAgo: 9000);
      final HeldByIdService held = HeldByIdService(
        firestore: db,
        currentUid: () => signedIn,
        notifications: platform,
      );
      addTearDown(held.dispose);
      held.watch();
      await settle(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(page(withService: held));
      await settle(t);
      ForegroundPost.shown('P');

      ForegroundFocus.request(
          subjectId: 'P', activityId: 'mine', recipientUid: me);
      await settle(t);
      expect(held.asked, contains('mine'), reason: 'the lookup is in flight');

      signedIn = carol;
      held.onAccountChanged(carol);
      held.release();
      await settle(t);
      await settle(t);
      expect(await readInStore(db, 'mine'), isFalse,
          reason: "another account's session may not read this one's activity");
    });
  });

  // ── The rule both open destinations share ─────────────────────────────────
  // The conversation page cannot be mounted in a test without an auth seam
  // this release does not add, so its half of the behaviour is pinned on the
  // production predicate it calls, and on what the router publishes.
  group('the focus rule both open destinations share', () {
    FocusRequest make({
      String subject = 'conv1',
      String? target = 'm1',
      String? activity = 'dr_1',
      String? uid = me,
      int serial = 5,
    }) =>
        FocusRequest(
          subjectId: subject,
          targetId: target,
          activityId: activity,
          recipientUid: uid,
          serial: serial,
          at: DateTime.utc(2026, 9, 1),
        );

    test('the SAME reaction target asked for again is acted on again', () {
      // Tapped, scrolled away from, tapped again. Comparing target ids dropped
      // this for ever.
      expect(
        shouldActOnFocus(
            req: make(serial: 6), subjectId: 'conv1', lastSerial: 5),
        isTrue,
      );
    });

    test('a request already acted on is not replayed by a rebuild', () {
      expect(
        shouldActOnFocus(
            req: make(serial: 5), subjectId: 'conv1', lastSerial: 5),
        isFalse,
      );
    });

    test('another page, another account, and an empty request are refused', () {
      expect(shouldActOnFocus(req: make(), subjectId: 'other', lastSerial: 0),
          isFalse);
      expect(
        shouldActOnFocus(
            req: make(uid: bob),
            subjectId: 'conv1',
            lastSerial: 0,
            viewerUid: me),
        isFalse,
      );
      expect(
        shouldActOnFocus(
            req: make(target: null, activity: null),
            subjectId: 'conv1',
            lastSerial: 0),
        isFalse,
        reason: 'nothing to reveal and no record to read is not a request',
      );
    });

    test('a record with no target is still a request', () {
      expect(
        shouldActOnFocus(
            req: make(target: null), subjectId: 'conv1', lastSerial: 0),
        isTrue,
      );
    });

    test('a request that asks for nothing is never published', () {
      expect(ForegroundFocus.request(subjectId: 'P', activityId: 'pl_1'), isTrue);
      final FocusRequest published = ForegroundFocus.requests.value!;
      expect(published.activityId, 'pl_1');
      expect(published.targetId, isNull);
      expect(ForegroundFocus.request(subjectId: 'P'), isFalse);
      expect(ForegroundFocus.requests.value!.serial, published.serial,
          reason: 'and it does not consume a serial');
    });
  });
}
