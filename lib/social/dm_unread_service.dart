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
  });

  final String convId;
  final String otherUid;

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
    return DmConversationUnread(
      convId: convId,
      otherUid: otherUid,
      incoming: intOf(mine['incoming']),
      readIncoming: intOf(mine['readIncoming']),
      legacyUnread: intOf(mine['unreadCount']),
      updatedAt: updated is Timestamp ? updated.toDate() : null,
    );
  }
}

@immutable
class DmUnreadSnapshot {
  const DmUnreadSnapshot({
    required this.uid,
    required this.conversations,
    required this.loaded,
  });

  static const DmUnreadSnapshot empty =
      DmUnreadSnapshot(uid: null, conversations: <String, DmConversationUnread>{}, loaded: false);

  final String? uid;
  final Map<String, DmConversationUnread> conversations;

  /// False until the first snapshot for this account has arrived. A loading
  /// or failing stream must not be rendered as "nothing unread".
  final bool loaded;

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
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  String? _subscribedUid;

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
    _sub?.cancel();
    _sub = null;
    _subscribedUid = null;
    _acked.clear();
    _last = DmUnreadSnapshot.empty;
    if (!_out.isClosed) _out.add(_last);
    if (uid != null && _out.hasListener) _ensureSubscribed();
  }

  void _ensureSubscribed() {
    final String? uid = _currentUid();
    if (uid == null) return;
    if (_sub != null && _subscribedUid == uid) return;
    _sub?.cancel();
    _subscribedUid = uid;
    if (_last.uid != uid) {
      _acked.clear();
      _last = DmUnreadSnapshot.empty;
    }
    _sub = _db
        .collection('conversations')
        .where('participants.$uid', isEqualTo: true)
        .snapshots()
        .listen(
      (QuerySnapshot<Map<String, dynamic>> q) => _onSnapshot(uid, q),
      // Keep the last known counts on a transient failure rather than
      // flashing an empty badge.
      onError: (Object e) => debugPrint('[dm] unread stream error: $e'),
    );
  }

  void _onSnapshot(String uid, QuerySnapshot<Map<String, dynamic>> q) {
    if (_currentUid() != uid) return; // account changed mid-flight
    final Map<String, DmConversationUnread> next = <String, DmConversationUnread>{};
    for (final QueryDocumentSnapshot<Map<String, dynamic>> d in q.docs) {
      final DmConversationUnread? c =
          DmConversationUnread.fromDoc(uid, d.id, d.data());
      if (c != null) next[d.id] = c;
    }
    _last = DmUnreadSnapshot(uid: uid, conversations: next, loaded: true);
    if (!_out.isClosed) _out.add(_last);

    // A server value behind what this session already acknowledged means an
    // earlier write has not landed (offline, or overwritten by another
    // device). Re-assert it rather than letting a read message come back.
    for (final MapEntry<String, int> e in _acked.entries) {
      final DmConversationUnread? c = next[e.key];
      if (c != null && c.readIncoming < e.value) {
        _writeAcknowledgement(uid, e.key, e.value);
      }
    }
  }

  /// Records that everything up to [upToSeq] has been displayed in [convId],
  /// and cancels that conversation's delivered phone alerts.
  ///
  /// [messageIds] are the incoming messages on screen; they let alerts from
  /// builds before the conversation-scoped tag be cancelled too.
  Future<void> acknowledge({
    required String convId,
    required int upToSeq,
    Iterable<String> messageIds = const <String>[],
  }) async {
    final String? uid = _currentUid();
    if (uid == null) return;

    // Always clear this thread's alerts: they may be left over from an
    // earlier session even when nothing new needs recording.
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

  /// Cancels the delivered alerts for one conversation — and only those.
  Future<void> clearConversationAlerts(
    String convId, {
    Iterable<String> messageIds = const <String>[],
  }) {
    return _notifications.clearNotifications(
      tagPrefixes: <String>[dmConversationTagPrefix(convId)],
      // Alerts sent before the tag carried the conversation.
      tags: messageIds.map(dmLegacyMessageTag).toList(growable: false),
      convIds: <String>[convId],
    );
  }

  /// Startup/resume: drop alerts for conversations that are no longer unread
  /// (read here earlier, or on another device). Alerts for conversations that
  /// still have unread messages are left alone.
  Future<void> reconcileDeliveredAlerts() async {
    final DmUnreadSnapshot state = _last;
    if (!state.loaded) return;
    final List<String> prefixes = <String>[];
    final List<String> convIds = <String>[];
    for (final DmConversationUnread c in state.conversations.values) {
      if (c.unread == 0) {
        prefixes.add(dmConversationTagPrefix(c.convId));
        convIds.add(c.convId);
      }
    }
    if (prefixes.isEmpty) return;
    await _notifications.clearNotifications(
      tagPrefixes: prefixes,
      convIds: convIds,
    );
  }

  @visibleForTesting
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _subscribedUid = null;
  }
}
