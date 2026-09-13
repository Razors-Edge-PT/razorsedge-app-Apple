/// Unread direct messages for the SIGNED-IN account: one subscription, one
/// answer, and the phone alerts that go with it.
///
/// ── One source, one account ─────────────────────────────────────────────────
/// The message icon's badge and each conversation row used to count
/// separately — and two of the three call sites mixed accounts, querying with
/// `UserContext.currentUid` (a coach's SELECTED ATHLETE) while reading the
/// per-person state with the signed-in uid, one of them against a collection
/// that does not hold conversations at all. Everything unread now comes from
/// here, keyed on FirebaseAuth's uid, so a coach reviewing an athlete still
/// sees their OWN messages, and the badge and the rows can never disagree.
///
/// One Firestore subscription is shared by every listener (the two Home
/// badges and the Messages list), so opening the list does not add a second
/// query and a rebuild costs nothing. No message history is scanned: the
/// count is two integers on the conversation document.
///
/// ── What "unread" means ─────────────────────────────────────────────────────
///   incoming      how many deliverable messages have been sent to me — the
///                 server's ledger (functions/push/dm_unread.js)
///   readIncoming  how far I have acknowledged reading, written here
///   unread        max(0, incoming - readIncoming)
///
/// Conversations from before the ledger existed fall back to the legacy
/// `unreadCount` until their next message, which carries the old number
/// forward.
///
/// [acknowledge] never resets a counter; it records a POSITION the chat
/// actually displayed. A message arriving while the chat is opening gets a
/// higher position and stays unread. It never moves backwards, and it is not
/// a transaction, so it applies instantly offline and syncs on reconnect; if
/// another device (or an offline write landing late) reports a lower
/// position, this session re-acknowledges its own.
///
/// Reading a conversation also cancels that conversation's delivered phone
/// alerts — and only those.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../push/notification_platform.dart';
import '../push/push_intent.dart';

/// What one conversation contributes.
@immutable
class DmConversationUnread {
  const DmConversationUnread({
    required this.convId,
    required this.otherUid,
    required this.incoming,
    required this.readIncoming,
    required this.legacyUnread,
    this.updatedAt,
    this.lastMessageText = '',
  });

  final String convId;
  final String otherUid;

  /// The conversation row's preview text. Never message CONTENT beyond what
  /// the sender's own device already wrote to `lastMessage` for this purpose.
  final String lastMessageText;

  /// Server ledger: messages sent to me in this conversation.
  final int incoming;

  /// How far I have acknowledged.
  final int readIncoming;

  /// Pre-ledger counter, maintained by installed builds.
  final int legacyUnread;

  final DateTime? updatedAt;

  int get unread => incoming > 0
      ? math.max(0, incoming - readIncoming)
      : math.max(0, legacyUnread);

  static DmConversationUnread? fromDoc(
    String uid,
    String convId,
    Map<String, dynamic>? data,
  ) {
    if (data == null) return null;
    final Map<String, dynamic> participants =
        Map<String, dynamic>.from(data['participants'] as Map? ?? const <String, dynamic>{});
    final String otherUid = participants.keys.firstWhere(
      (String k) => k != uid,
      orElse: () => '',
    );
    final Map<String, dynamic> state =
        Map<String, dynamic>.from(data['participantState'] as Map? ?? const <String, dynamic>{});
    final Map<String, dynamic> mine =
        Map<String, dynamic>.from(state[uid] as Map? ?? const <String, dynamic>{});
    int intOf(Object? v) => v is int ? v : 0;
    final Object? updated = data['updatedAt'];
    final Object? lastMessage = data['lastMessage'];
    final Object? text = lastMessage is Map ? lastMessage['text'] : null;
    return DmConversationUnread(
      convId: convId,
      otherUid: otherUid,
      incoming: intOf(mine['incoming']),
      readIncoming: intOf(mine['readIncoming']),
      legacyUnread: intOf(mine['unreadCount']),
      updatedAt: updated is Timestamp ? updated.toDate() : null,
      lastMessageText: text is String ? text : '',
    );
  }
}

@immutable
class DmUnreadSnapshot {
  const DmUnreadSnapshot({
    required this.uid,
    required this.conversations,
    required this.loaded,
    this.error = false,
  });

  static const DmUnreadSnapshot empty = DmUnreadSnapshot(
    uid: null,
    conversations: <String, DmConversationUnread>{},
    loaded: false,
  );

  final String? uid;
  final Map<String, DmConversationUnread> conversations;

  /// False until every conversation for this account's currently-confirmed
  /// friends has reported at least once. A loading or failing stream must not
  /// be rendered as "nothing unread" — see [error] for the failing case.
  final bool loaded;

  /// True when the underlying subscription is currently failing (e.g. a
  /// permission error) AND nothing has loaded yet this account-session, so a
  /// caller can show a genuine error state instead of an empty inbox. Once
  /// [loaded] has been true at all, later transient errors keep the last
  /// known data instead of flipping this on — a brief reconnect blip should
  /// not replace a working list with an error screen.
  final bool error;

  int get total =>
      conversations.values.fold(0, (int sum, DmConversationUnread c) => sum + c.unread);

  int unreadFor(String convId) => conversations[convId]?.unread ?? 0;
}

/// One message as the read rules see it.
typedef DmDisplayedMessage = ({String id, String senderId, int? incomingSeq});

/// What a chat may acknowledge: the highest ledger position among the
/// INCOMING messages it is displaying, and their ids (for cancelling alerts
/// sent by builds that tagged per message).
///
/// A message still waiting for its ledger position (the trigger has not run
/// yet) contributes no position, so it cannot be acknowledged early — it is
/// picked up by a later build once the position arrives.
@immutable
class DmReadBoundary {
  const DmReadBoundary({required this.upToSeq, required this.incomingIds});

  final int upToSeq;
  final List<String> incomingIds;

  bool get isEmpty => upToSeq == 0 && incomingIds.isEmpty;
}

DmReadBoundary computeReadBoundary({
  required String uid,
  required List<DmDisplayedMessage> messages,
}) {
  int maxSeq = 0;
  final List<String> ids = <String>[];
  for (final DmDisplayedMessage m in messages) {
    if (m.senderId == uid) continue; // my own messages are not unread
    final int? seq = m.incomingSeq;
    if (seq != null && seq > maxSeq) maxSeq = seq;
    ids.add(m.id);
  }
  return DmReadBoundary(upToSeq: maxSeq, incomingIds: ids);
}

/// A conversation counts as read only while it is the route on screen AND the
/// app is in front. A chat under another screen, or an app in the background
/// (including one woken by a notification), reads nothing.
bool shouldAcknowledgeRead({
  required bool routeVisible,
  required bool appResumed,
  required bool signedIn,
}) =>
    routeVisible && appResumed && signedIn;

class DmUnreadService {
  DmUnreadService({
    FirebaseFirestore? firestore,
    String? Function()? currentUid,
    NotificationPlatform? notifications,
  })  : _dbOverride = firestore,
        _currentUid =
            currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid),
        _notifications = notifications ?? NotificationPlatform();

  static final DmUnreadService instance = DmUnreadService();

  // Resolved lazily: constructing this must not require a live Firebase app,
  // so anything holding a reference (the push service, a widget) stays
  // testable without one.
  final FirebaseFirestore? _dbOverride;
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;
  final String? Function() _currentUid;
  final NotificationPlatform _notifications;

  final StreamController<DmUnreadSnapshot> _out =
      StreamController<DmUnreadSnapshot>.broadcast();

  // ── Subscription shape ───────────────────────────────────────────────────
  // `conversations` has no query this account can safely LIST: its read rule
  // requires a confirmed friendship, checked with get()/exists() against
  // buddyAssignments, and Firestore will not evaluate that safely for a
  // collection query — a query is denied wholesale if the rule cannot be
  // proven from the query's own filters, and get()/exists() calls make that
  // impossible regardless of what they would actually return. A single
  // document read/listen is unaffected; only `.where(...)` list queries are.
  // See firestore.rules `isConvFriend()` and functions/test-rules for the
  // conversations collection.
  //
  // So instead of listing, this reads `socialGraph/{uid}.friends` — the
  // existing, server-maintained, owner-readable projection of confirmed
  // friendships (see functions/social/feed.js) — and holds one individual
  // document listener per derived conversation id. A friend gained or lost
  // adds or drops exactly that one listener; every other conversation is
  // unaffected, so a lapsed friendship can never poison the rest of the
  // inbox the way the old collection query could.
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _friendsSub;
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
      _convSubs = <String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>{};
  final Map<String, DmConversationUnread> _conversations =
      <String, DmConversationUnread>{};

  /// Conversation ids attached but not yet reporting their first snapshot.
  /// [loaded] withholds itself until this is empty, so a friend's
  /// conversation that has not answered yet cannot look like zero unread.
  final Set<String> _pendingFirst = <String>{};

  String? _subscribedUid;
  bool _friendsLoaded = false;
  bool _hadError = false;

  /// Sticky once true for this account-session: a friend added later, whose
  /// conversation has not reported yet, must not make an already-working
  /// inbox look unloaded again.
  bool _everLoaded = false;

  DmUnreadSnapshot _last = DmUnreadSnapshot.empty;

  /// The highest position acknowledged in this session, per conversation.
  /// Survives a snapshot that has not caught up yet.
  final Map<String, int> _acked = <String, int>{};

  /// The current answer: last known state, never a transient zero.
  DmUnreadSnapshot get snapshot => _last;

  int get total => _last.total;

  int unreadFor(String convId) => _last.unreadFor(convId);

  /// True when [seq] in [convId] has already been read — used to drop a
  /// foreground banner for a message the person has seen.
  bool isAcknowledged(String convId, int? seq) {
    if (seq == null || seq <= 0) return false;
    final int acked = math.max(
      _acked[convId] ?? 0,
      _last.conversations[convId]?.readIncoming ?? 0,
    );
    return acked >= seq;
  }

  /// Unread state for the signed-in account. Shared: every listener gets the
  /// same underlying subscription, and the latest value immediately.
  Stream<DmUnreadSnapshot> watch() {
    _ensureSubscribed();
    return _out.stream;
  }

  /// Sign-in, restore or account switch. Drops another account's state so a
  /// stale count can never be shown to the new one.
  void onAccountChanged(String? uid) {
    if (uid == _subscribedUid && uid != null) return;
    _teardown();
    _acked.clear();
    _last = DmUnreadSnapshot.empty;
    if (!_out.isClosed) _out.add(_last);
    if (uid != null && _out.hasListener) _ensureSubscribed();
  }

  void _teardown() {
    _friendsSub?.cancel();
    _friendsSub = null;
    for (final StreamSubscription<Object?> s in _convSubs.values) {
      s.cancel();
    }
    _convSubs.clear();
    _conversations.clear();
    _pendingFirst.clear();
    _subscribedUid = null;
    _friendsLoaded = false;
    _hadError = false;
    _everLoaded = false;
  }

  void _ensureSubscribed() {
    final String? uid = _currentUid();
    if (uid == null) return;
    if (_subscribedUid == uid) return;
    _teardown();
    _subscribedUid = uid;
    if (_last.uid != uid) {
      _acked.clear();
      _last = DmUnreadSnapshot.empty;
    }
    _friendsSub = _db.collection('socialGraph').doc(uid).snapshots().listen(
      (DocumentSnapshot<Map<String, dynamic>> snap) => _onFriendsSnapshot(uid, snap),
      onError: (Object e) {
        debugPrint('[dm] friend list unavailable: $e');
        if (_subscribedUid != uid) return;
        _hadError = true;
        _emit(uid);
      },
    );
  }

  void _onFriendsSnapshot(String uid, DocumentSnapshot<Map<String, dynamic>> snap) {
    if (_currentUid() != uid || _subscribedUid != uid) return;
    _friendsLoaded = true;
    _hadError = false;
    final Map<String, dynamic>? data = snap.data();
    final Object? rawFriends = data?['friends'];
    final Set<String> friends = <String>{
      if (rawFriends is List)
        for (final Object? f in rawFriends)
          if (f is String && f.isNotEmpty) f,
    };
    final Map<String, String> desired = <String, String>{
      for (final String f in friends) conversationIdFor(uid, f): f,
    };

    for (final String convId in _convSubs.keys.where((String c) => !desired.containsKey(c)).toList()) {
      _convSubs.remove(convId)?.cancel();
      _conversations.remove(convId);
      _pendingFirst.remove(convId);
    }
    for (final String convId in desired.keys) {
      if (_convSubs.containsKey(convId)) continue;
      _pendingFirst.add(convId);
      _convSubs[convId] = _db.collection('conversations').doc(convId).snapshots().listen(
        (DocumentSnapshot<Map<String, dynamic>> doc) => _onConversationSnapshot(uid, convId, doc),
        onError: (Object e) {
          debugPrint('[dm] conversation $convId unavailable: $e');
          if (_currentUid() != uid || _subscribedUid != uid) return;
          _pendingFirst.remove(convId); // do not block loading forever
          _emit(uid);
        },
      );
    }
    _emit(uid);
  }

  void _onConversationSnapshot(
      String uid, String convId, DocumentSnapshot<Map<String, dynamic>> doc) {
    if (_currentUid() != uid || _subscribedUid != uid) return;
    _pendingFirst.remove(convId);
    final Map<String, dynamic>? data = doc.data();
    final DmConversationUnread? c =
        data == null ? null : DmConversationUnread.fromDoc(uid, convId, data);
    if (c == null) {
      _conversations.remove(convId);
    } else {
      _conversations[convId] = c;
    }
    _emit(uid);

    // A server value behind what this session already acknowledged means an
    // earlier write has not landed (offline, or overwritten by another
    // device). Re-assert it rather than letting a read message come back.
    final int? acked = _acked[convId];
    if (acked != null && c != null && c.readIncoming < acked) {
      _writeAcknowledgement(uid, convId, acked);
    }
  }

  void _emit(String uid) {
    if (_friendsLoaded && _pendingFirst.isEmpty) _everLoaded = true;
    _last = DmUnreadSnapshot(
      uid: uid,
      conversations: Map<String, DmConversationUnread>.of(_conversations),
      loaded: _everLoaded,
      error: _hadError && !_everLoaded,
    );
    if (!_out.isClosed) _out.add(_last);
  }

  /// Records that everything up to [upToSeq] has been displayed in [convId],
  /// and cancels the delivered alerts for exactly [messageIds] — the incoming
  /// messages actually displayed. A message that arrives after this chat
  /// computed that list (and so is not in it) is never cancelled here, even
  /// though it shares the conversation: it was not what was read.
  Future<void> acknowledge({
    required String convId,
    required int upToSeq,
    Iterable<String> messageIds = const <String>[],
  }) async {
    final String? uid = _currentUid();
    if (uid == null) return;

    unawaited(clearConversationAlerts(convId, messageIds: messageIds));

    final int serverRead = _last.conversations[convId]?.readIncoming ?? 0;
    final int target =
        math.max(upToSeq, math.max(_acked[convId] ?? 0, serverRead));
    if (target <= 0) return;
    _acked[convId] = target;
    if (target <= serverRead) return; // already recorded server-side
    _writeAcknowledgement(uid, convId, target);
  }

  void _writeAcknowledgement(String uid, String convId, int upToSeq) {
    // Deliberately not awaited and not a transaction: Firestore applies it to
    // the local cache at once (so the badge drops immediately, offline too)
    // and sends it when there is a connection.
    unawaited(_db.collection('conversations').doc(convId).update(<String, Object?>{
      'participantState.$uid.readIncoming': upToSeq,
      'participantState.$uid.lastReadAt': FieldValue.serverTimestamp(),
      // Installed builds still show this one.
      'participantState.$uid.unreadCount': 0,
    }).catchError((Object e) {
      debugPrint('[dm] read acknowledgement not confirmed: $e');
    }));
  }

  /// Cancels the delivered alerts for exactly [messageIds] in [convId] — the
  /// messages an explicit read acknowledgement actually covers. Deliberately
  /// NOT a prefix/conversation-wide clear: a message posted between this
  /// chat computing [messageIds] and this call reaching the platform shares
  /// the conversation but is not in the list, and must stay delivered.
  Future<void> clearConversationAlerts(
    String convId, {
    Iterable<String> messageIds = const <String>[],
  }) {
    final List<String> ids = messageIds.toList(growable: false);
    if (ids.isEmpty) return Future<void>.value();
    return _notifications.clearNotifications(
      tags: <String>[
        for (final String id in ids) dmMessageTag(convId: convId, messageId: id),
        // Alerts sent before the tag carried the conversation.
        for (final String id in ids) dmLegacyMessageTag(id),
      ],
    );
  }

  /// Startup/resume: drops delivered alerts that a CONFIRMED read already
  /// covers, and nothing else. Never trusts a conversation's cached/last-known
  /// unread bucket for this: it asks the OS which alerts are actually still in
  /// the tray, then verifies each one's own message and this account's own
  /// read boundary directly against the server before cancelling it — so a
  /// stale cached zero, a permission failure, or a message that arrived a
  /// moment ago can never cause a speculative cancellation. Unknown or
  /// unverifiable alerts are left exactly as they are.
  Future<void> reconcileDeliveredAlerts() async {
    final String? uid = _currentUid();
    if (uid == null) return;
    if (_last.uid != uid || !_last.loaded) return;
    final List<String> convIds = _last.conversations.keys.toList(growable: false);
    if (convIds.isEmpty) return;

    List<String> tags;
    try {
      tags = await _notifications.deliveredTags();
    } catch (_) {
      return;
    }
    if (tags.isEmpty) return;

    final Map<String, List<String>> byConv = <String, List<String>>{};
    for (final String convId in convIds) {
      final String prefix = dmConversationTagPrefix(convId);
      for (final String tag in tags) {
        if (tag.startsWith(prefix)) {
          byConv.putIfAbsent(convId, () => <String>[]).add(tag);
        }
      }
    }
    if (byConv.isEmpty) return;

    final List<String> toCancel = <String>[];
    for (final MapEntry<String, List<String>> entry in byConv.entries) {
      if (_currentUid() != uid) return; // account changed mid-flight
      final String convId = entry.key;
      final int? boundary = await _serverReadBoundary(uid, convId);
      if (boundary == null) continue; // unknown/failed: never speculative
      final String prefix = dmConversationTagPrefix(convId);
      for (final String tag in entry.value) {
        final String msgId = tag.substring(prefix.length);
        if (msgId.isEmpty) continue;
        final int? seq = await _serverMessageSeq(convId, msgId);
        if (seq != null && seq <= boundary) toCancel.add(tag);
      }
    }
    if (_currentUid() != uid || toCancel.isEmpty) return;
    await _notifications.clearNotifications(tags: toCancel);
  }

  /// This account's read boundary for [convId], fetched fresh from the
  /// server (never cache) and combined with anything acknowledged locally
  /// this session. Null when it cannot be established right now — offline, a
  /// permission failure, or an unexpectedly missing document — so the caller
  /// treats it as unknown rather than as zero.
  Future<int?> _serverReadBoundary(String uid, String convId) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await _db
          .collection('conversations')
          .doc(convId)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 5));
      final Map<String, dynamic>? data = snap.data();
      if (data == null) return null;
      final DmConversationUnread? c = DmConversationUnread.fromDoc(uid, convId, data);
      if (c == null) return null;
      return math.max(c.readIncoming, _acked[convId] ?? 0);
    } catch (e) {
      debugPrint('[dm] read boundary unavailable for reconciliation: $e');
      return null;
    }
  }

  /// [msgId]'s ledger position in [convId], fetched fresh from the server.
  /// Null when unknown, so the caller never guesses.
  Future<int?> _serverMessageSeq(String convId, String msgId) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await _db
          .collection('conversations')
          .doc(convId)
          .collection('messages')
          .doc(msgId)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 5));
      final Object? seq = snap.data()?['incomingSeq'];
      return seq is int ? seq : null;
    } catch (e) {
      debugPrint('[dm] message seq unavailable for reconciliation: $e');
      return null;
    }
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _friendsSub?.cancel();
    for (final StreamSubscription<Object?> s in _convSubs.values) {
      await s.cancel();
    }
    _friendsSub = null;
    _convSubs.clear();
    _subscribedUid = null;
  }
}
