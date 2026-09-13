/// What people did to your content â€” the durable record, its unread count, and
/// the phone alerts that go with it.
///
/// â”€â”€ Why this is not the message counter â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
/// A like on a post and an unread message are different kinds of fact and are
/// counted separately. Somebody tapping an emoji on a message you sent must
/// never make it look as though you have unread messages waiting: the reaction
/// is activity, the message ledger is untouched (see functions/push/dm_unread.js
/// and [DmUnreadService]).
///
/// â”€â”€ What "read" means here â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
/// Read is a property of ONE interaction, not of a screen. Opening Home, the
/// profile grid, or the Activity list does not mark anything read; what marks
/// an interaction read is that interaction actually being PRESENTED â€” the
/// comment scrolled into view, the post whose likes you are looking at, the
/// activity row on screen â€” while that route is visible and the app is in
/// front. So:
///
///   * viewing one post clears that post's interactions and leaves another
///     post's alone;
///   * a comment outside the page of comments the screen loaded stays unread
///     until it is actually shown;
///   * an interaction that arrives DURING an acknowledgement is not in the set
///     being acknowledged, so it stays unread.
///
/// The write is one field on one document (`read` false â†’ true), which the
/// rules make one-way: nothing â€” a replayed offline write, another device, a
/// resurrected event â€” can take an interaction back to unread. It is not a
/// transaction, so it applies to the local cache immediately (the badge drops
/// at once, offline too) and syncs when there is a connection.
///
/// Reading an interaction also cancels exactly its delivered phone alert, by
/// the tag the server stamped on it â€” never a blanket clear, and never another
/// post's or another conversation's alerts.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../push/notification_platform.dart';
import '../push/push_intent.dart';

/// One thing somebody did to this account's content.
@immutable
class SocialActivity {
  const SocialActivity({
    required this.id,
    required this.type,
    required this.actorUid,
    required this.subject,
    required this.read,
    this.postId,
    this.commentId,
    this.convId,
    this.messageId,
    this.emoji,
    this.preview,
    this.tag,
    this.createdAt,
    this.invalidated = false,
  });

  final String id;

  /// The push type that produced it: `postComment`, `postLike`,
  /// `postGoodLift`, `dmReaction`. Kept as a string so a record written by a
  /// newer server than this build simply renders as unknown rather than
  /// crashing a list.
  final String type;

  final String actorUid;

  /// `post:<postId>` or `dm:<convId>` â€” what reading this means reading.
  final String subject;

  final bool read;
  final String? postId;
  final String? commentId;
  final String? convId;
  final String? messageId;
  final String? emoji;

  /// A comment's opening words, for the list. Never used in a notification â€”
  /// that decision belongs to the server and the preview preference.
  final String? preview;

  /// The notification tag the alert for this interaction carries.
  final String? tag;

  final DateTime? createdAt;

  /// The interaction was withdrawn or its content deleted (the comment
  /// removed, the like taken back, the post deleted). The record survives —
  /// its id is what stops the same interaction alerting twice — but it counts
  /// for nothing and is not shown. Only the server sets this.
  final bool invalidated;

  PushKind? get kind => switch (type) {
        'postComment' => PushKind.postComment,
        'postLike' => PushKind.postLike,
        'postGoodLift' => PushKind.postGoodLift,
        'dmReaction' => PushKind.dmReaction,
        _ => null,
      };

  bool get isPostInteraction => kind?.isPostInteraction ?? false;

  /// True for a record this build knows how to show and open. A withdrawn
  /// interaction is not shown: the thing it points at is gone.
  bool get isRenderable => kind != null &&
      !invalidated &&
      (isPostInteraction ? postId != null : convId != null);

  static SocialActivity? fromDoc(String id, Map<String, dynamic>? data) {
    if (data == null) return null;
    String? s(String key) {
      final Object? v = data[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final String? type = s('type');
    final String? actor = s('actorUid');
    if (type == null || actor == null) return null;
    final Object? created = data['createdAt'];
    return SocialActivity(
      id: id,
      type: type,
      actorUid: actor,
      subject: s('subject') ?? '',
      read: data['read'] == true,
      postId: s('postId'),
      commentId: s('commentId'),
      convId: s('conversationId'),
      messageId: s('messageId'),
      emoji: s('emoji'),
      preview: s('preview'),
      tag: s('tag'),
      createdAt: created is Timestamp ? created.toDate() : null,
      invalidated: data['invalidated'] == true,
    );
  }
}

/// The subject key for a post's interactions.
String postSubject(String postId) => 'post:$postId';

/// The subject key for a conversation's reactions.
String dmSubject(String convId) => 'dm:$convId';

@immutable
class SocialActivitySnapshot {
  const SocialActivitySnapshot({
    required this.uid,
    required this.unread,
    required this.loaded,
  });

  static const SocialActivitySnapshot empty =
      SocialActivitySnapshot(uid: null, unread: <SocialActivity>[], loaded: false);

  final String? uid;

  /// Unread interactions, newest first, bounded by [SocialActivityService.kWatchLimit].
  final List<SocialActivity> unread;

  /// False until the first snapshot for this account has arrived â€” a loading
  /// or failing stream must not be rendered as "nothing new".
  final bool loaded;

  int get unreadCount => unread.length;

  /// Unread interactions about one post or conversation.
  List<SocialActivity> unreadForSubject(String subject) =>
      unread.where((SocialActivity a) => a.subject == subject).toList(growable: false);
}

/// A screen may acknowledge only while it is the route on screen AND the app is
/// in front. A page under another route, or an app in the background (including
/// one woken by a notification), presents nothing and reads nothing.
bool shouldAcknowledgeActivity({
  required bool routeVisible,
  required bool appResumed,
  required bool signedIn,
}) =>
    routeVisible && appResumed && signedIn;

/// Which of [unread] a post screen showing [displayedCommentIds] has actually
/// presented.
///
/// Likes and Good Lifts are presented by the post itself â€” its counts are on
/// screen. A COMMENT is presented only if it is one of the comments the screen
/// is showing: the page loads a window of them, and one outside that window
/// (an older comment, or one further up a long thread) has not been seen and
/// must stay unread.
List<SocialActivity> presentedOnPost({
  required List<SocialActivity> unread,
  required String postId,
  required Set<String> displayedCommentIds,
}) {
  final String subject = postSubject(postId);
  return unread
      .where((SocialActivity a) =>
          a.subject == subject &&
          (a.type != 'postComment' ||
              (a.commentId != null && displayedCommentIds.contains(a.commentId))))
      .toList(growable: false);
}

/// Which of [unread] a conversation showing [displayedMessageIds] has presented.
List<SocialActivity> presentedInConversation({
  required List<SocialActivity> unread,
  required String convId,
  required Set<String> displayedMessageIds,
}) {
  final String subject = dmSubject(convId);
  return unread
      .where((SocialActivity a) =>
          a.subject == subject &&
          a.messageId != null &&
          displayedMessageIds.contains(a.messageId))
      .toList(growable: false);
}

class SocialActivityService {
  SocialActivityService({
    FirebaseFirestore? firestore,
    String? Function()? currentUid,
    NotificationPlatform? notifications,
  })  : _dbOverride = firestore,
        _currentUid =
            currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _notifications = notifications ?? NotificationPlatform();

  static final SocialActivityService instance = SocialActivityService();

  /// How many unread interactions are tracked at once. Beyond this the badge
  /// says "more than this many"; nothing is lost, and the query stays cheap.
  static const int kWatchLimit = 50;

  /// How many records the Activity list shows per page.
  static const int kListLimit = 50;

  /// How many unread records are fetched for one post or conversation when a
  /// screen presents it. Bounds the work for a very busy post.
  static const int kSubjectLimit = 50;

  /// How many delivered alerts are checked against their records during
  /// reconciliation. More than anybody has in a tray.
  static const int kReconcileLimit = 40;

  // Resolved lazily: constructing this must not require a live Firebase app,
  // so anything holding a reference stays testable without one.
  final FirebaseFirestore? _dbOverride;
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;
  final String? Function() _currentUid;
  final NotificationPlatform _notifications;

  /// The signed-in account, or null when there is no Firebase to ask.
  ///
  /// A badge is drawn in places that exist before (and in tests, without) a
  /// Firebase app. Asking an app that is not there throws, and a count nobody
  /// can produce is not a reason to fail a screen â€” it simply means there is
  /// nothing to show.
  String? _uidOrNull() {
    try {
      return _currentUid();
    } catch (_) {
      return null;
    }
  }

  final StreamController<SocialActivitySnapshot> _out =
      StreamController<SocialActivitySnapshot>.broadcast();
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  String? _subscribedUid;

  SocialActivitySnapshot _last = SocialActivitySnapshot.empty;

  /// Acknowledged in this session, so a snapshot that has not caught up yet
  /// cannot show something as unread again, and a repeat acknowledgement is
  /// not a repeat write.
  final Set<String> _acked = <String>{};

  SocialActivitySnapshot get snapshot => _last;

  int get unreadCount => _last.unreadCount;

  CollectionReference<Map<String, dynamic>> _collection(String uid) =>
      _db.collection('users').doc(uid).collection('socialActivity');

  /// Records that still stand, filtered by the SERVER.
  ///
  /// Withdrawn interactions keep `read: false` on purpose, so that one coming
  /// back comes back as it was. Filtering them out in Dart therefore meant a
  /// bounded query could return fifty retired records and nothing else: the
  /// badge showed zero while real unread activity sat just below the window,
  /// and the Activity list showed an empty state it could not page past. The
  /// condition belongs in the query, where the limit is applied after it.
  ///
  /// Every record the server writes carries `invalidated` explicitly, so no
  /// document is excluded for want of the field.
  Query<Map<String, dynamic>> _live(String uid) =>
      _collection(uid).where('invalidated', isEqualTo: false);

  /// Unread activity for the signed-in account. Shared: every listener gets the
  /// same underlying subscription and the latest value immediately.
  ///
  /// The replay matters. A badge built after the first snapshot — a second
  /// Home header, the Buddy Hub opening, a rebuild — subscribes to a broadcast
  /// stream that has already fired, so without this it would sit at zero until
  /// something else happened. It replays only state belonging to the account
  /// asking, so a subscriber that appears mid account-switch never sees the
  /// previous account's count, and it adds no Firestore subscription.
  Stream<SocialActivitySnapshot> watch() {
    _ensureSubscribed();
    final SocialActivitySnapshot current = _last;
    if (!current.loaded || current.uid == null || current.uid != _uidOrNull()) {
      return _out.stream;
    }
    // Deliberately not an `async*` generator over the broadcast stream: the
    // events never end, so cancelling a subscription to such a generator waits
    // for a return that cannot come, and a badge being disposed would hang on
    // its own cancel.
    return Stream<SocialActivitySnapshot>.multi(
      (MultiStreamController<SocialActivitySnapshot> out) {
        out.add(current);
        final StreamSubscription<SocialActivitySnapshot> sub = _out.stream.listen(
          out.add,
          onError: out.addError,
          onDone: out.close,
        );
        out.onCancel = sub.cancel;
      },
      isBroadcast: true,
    );
  }

  /// Sign-in, restore or account switch. Drops the other account's state so a
  /// stale badge can never be shown to the new one.
  void onAccountChanged(String? uid) {
    if (uid == _subscribedUid && uid != null) return;
    _sub?.cancel();
    _sub = null;
    _subscribedUid = null;
    _acked.clear();
    _last = SocialActivitySnapshot.empty;
    if (!_out.isClosed) _out.add(_last);
    if (uid != null && _out.hasListener) _ensureSubscribed();
  }

  void _ensureSubscribed() {
    final String? uid = _uidOrNull();
    if (uid == null) return;
    if (_sub != null && _subscribedUid == uid) return;
    _sub?.cancel();
    _subscribedUid = uid;
    if (_last.uid != uid) {
      _acked.clear();
      _last = SocialActivitySnapshot.empty;
    }
    _sub = _live(uid)
        .where('read', isEqualTo: false)
        .orderBy('createdAt', descending: true)
        .limit(kWatchLimit)
        .snapshots()
        .listen(
          (QuerySnapshot<Map<String, dynamic>> q) => _onSnapshot(uid, q),
          // Keep the last known state on a transient failure rather than
          // flashing an empty badge.
          onError: (Object e) => debugPrint('[activity] stream error: $e'),
        );
  }

  void _onSnapshot(String uid, QuerySnapshot<Map<String, dynamic>> q) {
    if (_uidOrNull() != uid) return; // account changed mid-flight
    final List<SocialActivity> unread = <SocialActivity>[];
    for (final QueryDocumentSnapshot<Map<String, dynamic>> d in q.docs) {
      final SocialActivity? a = SocialActivity.fromDoc(d.id, d.data());
      // Something acknowledged here but not yet confirmed by the server is
      // already read as far as this session is concerned. A withdrawn
      // interaction counts for nothing even while its record survives.
      if (a != null && !a.invalidated && !_acked.contains(a.id)) unread.add(a);
    }
    _last = SocialActivitySnapshot(uid: uid, unread: unread, loaded: true);
    if (!_out.isClosed) _out.add(_last);
  }

  /// The unread interactions for one post or conversation.
  List<SocialActivity> unreadForSubject(String subject) =>
      _last.unreadForSubject(subject);

  /// Every unread interaction for one subject, asked of the server.
  ///
  /// The live subscription tracks only the newest [kWatchLimit] unread
  /// records, so an older one — a comment from last week under fifty newer
  /// interactions — is not in it. A screen showing that comment must still be
  /// able to read it, and its alert must still be cancellable, so the subject
  /// is queried directly. Two equality filters and a bound: no composite
  /// index, no full scan.
  ///
  /// Falls back to the local view when the query cannot be made (offline).
  Future<List<SocialActivity>> unreadForSubjectFromServer(
    String subject, {
    int limit = kSubjectLimit,
  }) async {
    final String? uid = _uidOrNull();
    if (uid == null) return const <SocialActivity>[];
    try {
      final QuerySnapshot<Map<String, dynamic>> q = await _live(uid)
          .where('subject', isEqualTo: subject)
          .where('read', isEqualTo: false)
          .limit(limit)
          .get();
      final List<SocialActivity> out = <SocialActivity>[];
      for (final QueryDocumentSnapshot<Map<String, dynamic>> d in q.docs) {
        final SocialActivity? a = SocialActivity.fromDoc(d.id, d.data());
        if (a == null || a.invalidated || _acked.contains(a.id)) continue;
        out.add(a);
      }
      return out;
    } catch (e) {
      debugPrint('[activity] subject lookup failed for $subject: $e');
      return unreadForSubject(subject);
    }
  }

  /// One interaction, by id.
  ///
  /// The one lookup that no window can hide: a notification and an Activity
  /// row both name the exact record they are about, so the thing the person
  /// tapped can always be read, acknowledged and have its alert cancelled —
  /// however many newer interactions sit in front of it.
  Future<SocialActivity?> activityById(String activityId) async {
    final String? uid = _uidOrNull();
    if (uid == null || activityId.isEmpty) return null;
    try {
      final DocumentSnapshot<Map<String, dynamic>> doc =
          await _collection(uid).doc(activityId).get();
      final SocialActivity? a = SocialActivity.fromDoc(activityId, doc.data());
      if (a == null || a.invalidated) return null;
      return _withSessionRead(a);
    } catch (e) {
      debugPrint('[activity] could not read $activityId: $e');
      return null;
    }
  }

  /// Everything older than [anchor], newest first, as a LIVE query.
  ///
  /// Anchored on the anchor's own document rather than on a timestamp, so
  /// records sharing a timestamp to the millisecond are neither dropped nor
  /// repeated at the boundary — document order breaks the tie, exactly as it
  /// does inside the page above. Anchored on a FIXED document rather than on
  /// "the fiftieth newest", so new arrivals at the top cannot shift the
  /// boundary underneath the person.
  ///
  /// It stays a subscription because these rows are not a snapshot of the
  /// past: one of them being read here, or withdrawn by its author, has to
  /// show, and a cached copy would go on claiming otherwise.
  /// Deliberately not an `async*` generator: cancelling a subscription to one
  /// that is suspended in `yield*` over a stream that never ends does not
  /// complete, and a list disposing its older pages would hang on it.
  Stream<List<SocialActivity>> watchOlderThan({
    required SocialActivity anchor,
    int limit = kListLimit,
  }) {
    final String? uid = _uidOrNull();
    if (uid == null) {
      return Stream<List<SocialActivity>>.value(const <SocialActivity>[]);
    }
    late final StreamController<List<SocialActivity>> out;
    StreamSubscription<List<SocialActivity>>? sub;

    Future<void> start() async {
      try {
        final DocumentSnapshot<Map<String, dynamic>> cursor =
            await _collection(uid).doc(anchor.id).get();
        Query<Map<String, dynamic>> q =
            _live(uid).orderBy('createdAt', descending: true);
        if (cursor.exists) {
          q = q.startAfterDocument(cursor);
        } else {
          // The anchor has gone: its timestamp is all that is left to position
          // by, and anything sharing that instant is on the page above.
          final DateTime? at = anchor.createdAt;
          if (at == null) {
            out.add(const <SocialActivity>[]);
            return;
          }
          q = q.where('createdAt', isLessThan: Timestamp.fromDate(at));
        }
        if (out.isClosed) return;
        sub = q.limit(limit).snapshots().map(_mapDocs).listen(
              out.add,
              onError: out.addError,
              onDone: out.close,
            );
      } catch (e) {
        debugPrint('[activity] could not load older activity: $e');
        if (!out.isClosed) out.add(const <SocialActivity>[]);
      }
    }

    out = StreamController<List<SocialActivity>>(
      onListen: () => unawaited(start()),
      onCancel: () async => sub?.cancel(),
    );
    return out.stream;
  }

  List<SocialActivity> _mapDocs(QuerySnapshot<Map<String, dynamic>> q) {
    final List<SocialActivity> out = <SocialActivity>[];
    for (final QueryDocumentSnapshot<Map<String, dynamic>> d in q.docs) {
      final SocialActivity? a = SocialActivity.fromDoc(d.id, d.data());
      if (a == null || a.invalidated) continue;
      out.add(_withSessionRead(a));
    }
    return out;
  }

  /// True when THIS session has already acknowledged [activityId].
  ///
  /// Deliberately positive knowledge only. "Not in the unread list" is not the
  /// same as read: a push usually arrives before Firestore delivers the record
  /// it is about, and an interaction beyond the tracked window is not in the
  /// list either. Treating either as read would silently drop a real alert.
  bool isAcknowledged(String? activityId) =>
      activityId != null && _acked.contains(activityId);

  /// Records that [items] have actually been presented, and cancels exactly
  /// their delivered alerts.
  ///
  /// Idempotent, bounded and safe to call from a build-triggered callback: an
  /// item already acknowledged in this session is skipped.
  Future<void> acknowledge(Iterable<SocialActivity> items) async {
    final String? uid = _uidOrNull();
    if (uid == null) return;
    final List<SocialActivity> fresh = items
        .where((SocialActivity a) => !a.read && _acked.add(a.id))
        .toList(growable: false);
    if (fresh.isEmpty) return;

    // Drop them from the local view at once, so the badge falls immediately
    // even before the write is confirmed.
    _last = SocialActivitySnapshot(
      uid: _last.uid,
      unread: _last.unread
          .where((SocialActivity a) => !_acked.contains(a.id))
          .toList(growable: false),
      loaded: _last.loaded,
    );
    if (!_out.isClosed) _out.add(_last);

    unawaited(_clearAlertsFor(fresh));

    // Deliberately not awaited and not a transaction: Firestore applies each
    // update to the local cache at once and sends it when there is a
    // connection. The rules make it one-way, so a late write cannot un-read.
    for (final SocialActivity a in fresh) {
      unawaited(_collection(uid).doc(a.id).update(<String, Object?>{
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      }).catchError((Object e) {
        // Not confirmed: allow a later attempt to try again.
        _acked.remove(a.id);
        debugPrint('[activity] read not confirmed for ${a.id}: $e');
      }));
    }
  }

  Future<void> _clearAlertsFor(List<SocialActivity> items) {
    final List<String> tags = <String>[];
    for (final SocialActivity a in items) {
      final String? tag = a.tag;
      if (tag != null && tag.isNotEmpty) {
        tags.add(tag);
        continue;
      }
      // A record written before the tag was stored: rebuild it from the ids.
      if (a.isPostInteraction && a.postId != null) {
        tags.add(postActivityTag(postId: a.postId!, activityId: a.id));
      } else if (a.convId != null) {
        tags.add(dmReactionTag(convId: a.convId!, activityId: a.id));
      }
    }
    if (tags.isEmpty) return Future<void>.value();
    return _notifications.clearNotifications(tags: tags);
  }

  /// Startup and resume: drop alerts for interactions that are no longer
  /// unread â€” read here earlier, or on another device, or in a session that
  /// ended before it could cancel them.
  ///
  /// Driven by what is actually IN THE TRAY, not by a window of records. The
  /// old version read the newest fifty records and cancelled the read ones
  /// among them, so an alert whose record had since been pushed past fifty was
  /// never reconsidered and stayed in the tray for good. Each delivered alert
  /// names its own record in its tag, so the tray is the right list to work
  /// from: one document read per alert, capped, and independent of how many
  /// newer interactions have arrived since.
  ///
  /// Falls back to the record sweep when the platform cannot list the tray (an
  /// older native build, or a platform without the call).
  Future<void> reconcileDeliveredAlerts() async {
    final String? uid = _uidOrNull();
    if (uid == null) return;
    try {
      final List<String> delivered = await _notifications.deliveredTags();
      if (delivered.isEmpty) {
        await _reconcileFromRecentRecords(uid);
        return;
      }
      final List<String> stale = <String>[];
      int reads = 0;
      for (final String tag in delivered) {
        final String? activityId = activityIdFromTag(tag);
        if (activityId == null) continue; // not one of ours
        if (_acked.contains(activityId)) {
          stale.add(tag);
          continue;
        }
        if (reads >= kReconcileLimit) break;
        reads++;
        final DocumentSnapshot<Map<String, dynamic>> doc =
            await _collection(uid).doc(activityId).get();
        final SocialActivity? a = SocialActivity.fromDoc(activityId, doc.data());
        // Gone, already read, or withdrawn: nothing stands behind the alert.
        if (a == null || a.read || a.invalidated) stale.add(tag);
      }
      if (stale.isEmpty) return;
      await _notifications.clearNotifications(tags: stale);
    } catch (e) {
      debugPrint('[activity] alert reconciliation skipped: $e');
    }
  }

  Future<void> _reconcileFromRecentRecords(String uid) async {
    final QuerySnapshot<Map<String, dynamic>> recent = await _collection(uid)
        .orderBy('createdAt', descending: true)
        .limit(kListLimit)
        .get();
    final List<String> tags = <String>[];
    for (final QueryDocumentSnapshot<Map<String, dynamic>> d in recent.docs) {
      final SocialActivity? a = SocialActivity.fromDoc(d.id, d.data());
      if (a == null) continue;
      if (a.read || a.invalidated || _acked.contains(a.id)) {
        final String? tag = a.tag;
        if (tag != null && tag.isNotEmpty) tags.add(tag);
      }
    }
    if (tags.isEmpty) return;
    await _notifications.clearNotifications(tags: tags);
  }

  /// The Activity list: recent interactions, read and unread, newest first.
  Stream<List<SocialActivity>> watchRecent() {
    final String? uid = _uidOrNull();
    if (uid == null) return Stream<List<SocialActivity>>.value(const <SocialActivity>[]);
    return _live(uid)
        .orderBy('createdAt', descending: true)
        .limit(kListLimit)
        .snapshots()
        .map(_mapDocs);
  }

  /// Reflects this session's acknowledgements on a record the server has not
  /// caught up with yet, so a row cannot flicker back to unread.
  SocialActivity _withSessionRead(SocialActivity a) {
    if (a.read || !_acked.contains(a.id)) return a;
    return SocialActivity(
      id: a.id,
      type: a.type,
      actorUid: a.actorUid,
      subject: a.subject,
      read: true,
      postId: a.postId,
      commentId: a.commentId,
      convId: a.convId,
      messageId: a.messageId,
      emoji: a.emoji,
      preview: a.preview,
      tag: a.tag,
      createdAt: a.createdAt,
      invalidated: a.invalidated,
    );
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _subscribedUid = null;
  }
}
