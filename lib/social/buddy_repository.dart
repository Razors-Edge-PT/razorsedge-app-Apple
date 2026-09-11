/// The client half of the buddy relationship system.
///
/// ── The account this operates on ───────────────────────────────────────────
/// Every method here uses the AUTHENTICATED account and nothing else.
///
/// That is a deliberate departure from the legacy screens, which read the uid
/// out of `UserContext`. `UserContext` exposes two: `actorUid`, the signed-in
/// account, and `actingAsUid`, the athlete a coach currently has selected. The
/// old header badge used `actingAsUid`, so a coach reviewing an athlete saw
/// that athlete's buddy requests and could accept or decline them — a social
/// action taken on somebody else's account, from a permission granted for
/// training. Friendships belong to the person, not to the coaching session.
///
/// So this class never touches `UserContext`, and the callables behind it take
/// no uid argument at all: the server derives the actor from `request.auth`.
/// Even a client that wanted to act as somebody else has nothing to send.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// The viewer's relationship with another account. Mirrors `Relationship` in
/// functions/social/buddy_model.js.
enum BuddyRelationship { none, requested, incoming, friends, self }

BuddyRelationship relationshipFromName(String? raw) {
  switch (raw) {
    case 'requested':
      return BuddyRelationship.requested;
    case 'incoming':
      return BuddyRelationship.incoming;
    case 'friends':
      return BuddyRelationship.friends;
    case 'self':
      return BuddyRelationship.self;
    default:
      return BuddyRelationship.none;
  }
}

/// A request addressed to the viewer.
class IncomingRequest {
  const IncomingRequest({
    required this.fromUid,
    this.fromDisplayName = '',
    this.createdAt,
  });

  final String fromUid;
  final String fromDisplayName;
  final DateTime? createdAt;

  static IncomingRequest fromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) {
    final Map<String, dynamic> d = snap.data() ?? const <String, dynamic>{};
    final Object? created = d['createdAt'];
    return IncomingRequest(
      // The document id IS the sender, which is what the security rules key
      // on. Preferring it over the field means a malformed `fromUid` cannot
      // point a row at somebody else.
      fromUid: snap.id,
      fromDisplayName: (d['fromDisplayName'] as String?)?.trim() ?? '',
      createdAt: created is Timestamp ? created.toDate() : null,
    );
  }
}

/// A request the viewer sent that has not been answered.
class OutgoingRequest {
  const OutgoingRequest({
    required this.toUid,
    this.displayName = '',
    this.sentAt,
  });

  final String toUid;
  final String displayName;
  final DateTime? sentAt;
}

/// One of the viewer's OWN requests that the other person accepted, not yet
/// seen by the viewer.
///
/// Written only by the server (functions/social/notifications.js) when an
/// invite moves from pending to accepted while both sides accept, one document
/// per pair. firestore.rules denies every client create and delete, so a device
/// cannot fabricate one; the viewer's only write is marking it seen.
class AcceptedNotice {
  const AcceptedNotice({
    required this.id,
    required this.uid,
    this.acceptedAt,
  });

  /// The notification document id.
  final String id;

  /// The account that accepted.
  final String uid;

  final DateTime? acceptedAt;

  static AcceptedNotice? fromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snap, {
    required String viewerUid,
  }) {
    final Map<String, dynamic>? d = snap.data();
    if (d == null) return null;
    if (d['type'] != 'buddyAccepted' || d['seen'] != false) return null;
    final Object? other = d['otherUid'];
    if (other is! String || other.trim().isEmpty || other == viewerUid) {
      return null;
    }
    final Object? at = d['acceptedAt'] ?? d['createdAt'];
    return AcceptedNotice(
      id: snap.id,
      uid: other,
      acceptedAt: at is Timestamp ? at.toDate() : null,
    );
  }
}

/// What the header badge counts.
class BuddyBadge {
  const BuddyBadge({this.incoming = 0, this.accepted = 0});

  /// Requests addressed to the viewer that still need an answer.
  final int incoming;

  /// Acceptances of the viewer's own requests not yet seen.
  final int accepted;

  int get total => incoming + accepted;

  @override
  bool operator ==(Object other) =>
      other is BuddyBadge &&
      other.incoming == incoming &&
      other.accepted == accepted;

  @override
  int get hashCode => Object.hash(incoming, accepted);
}

/// The viewer's whole social state, as one value.
class BuddyState {
  const BuddyState({
    this.incoming = const <IncomingRequest>[],
    this.outgoing = const <OutgoingRequest>[],
    this.friends = const <String>[],
    this.unseenAccepted = const <AcceptedNotice>[],
    this.loaded = false,
  });

  final List<IncomingRequest> incoming;
  final List<OutgoingRequest> outgoing;

  /// Confirmed, MUTUAL friends, from the server-maintained projection.
  final List<String> friends;

  /// Acceptances of the viewer's own requests not yet seen. See [newBuddies].
  final List<AcceptedNotice> unseenAccepted;

  final bool loaded;

  int get pendingCount => incoming.length;

  /// Unseen acceptances the friend projection confirms, one per account.
  ///
  /// An acceptance for somebody who is not — or no longer — a confirmed
  /// friend is not news the viewer can act on, so it is neither counted nor
  /// shown.
  List<AcceptedNotice> get newBuddies {
    final Set<String> counted = <String>{};
    return unseenAccepted
        .where((AcceptedNotice n) =>
            friends.contains(n.uid) && counted.add(n.uid))
        .toList(growable: false);
  }

  /// What the header badge shows: requests waiting for an answer, plus
  /// acceptances not yet seen.
  BuddyBadge get badge =>
      BuddyBadge(incoming: incoming.length, accepted: newBuddies.length);

  BuddyRelationship relationshipWith(String uid) {
    if (friends.contains(uid)) return BuddyRelationship.friends;
    if (incoming.any((IncomingRequest r) => r.fromUid == uid)) {
      return BuddyRelationship.incoming;
    }
    if (outgoing.any((OutgoingRequest r) => r.toUid == uid)) {
      return BuddyRelationship.requested;
    }
    return BuddyRelationship.none;
  }
}

class BuddyRepository {
  BuddyRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    FirebaseAuth? auth,
    String? overrideUid,
    String? Function()? uidResolver,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _functions = functions,
        _auth = auth,
        _overrideUid = overrideUid,
        _uidResolver = uidResolver;

  final FirebaseFirestore _db;
  final FirebaseFunctions? _functions;
  final FirebaseAuth? _auth;
  final String? _overrideUid;

  /// Test seam standing in for FirebaseAuth itself — including returning null
  /// for a signed-out device. Never an "acting as" value.
  final String? Function()? _uidResolver;

  /// The signed-in account. Never the coach's selected athlete — see the
  /// library comment.
  String? get currentUid {
    if (_overrideUid != null) return _overrideUid;
    if (_uidResolver != null) return _uidResolver();
    final FirebaseAuth auth = _auth ?? FirebaseAuth.instance;
    return auth.currentUser?.uid;
  }

  CollectionReference<Map<String, dynamic>> _notifications(String uid) =>
      _db.collection('users').doc(uid).collection('socialNotifications');

  FirebaseFunctions get _fns => _functions ?? FirebaseFunctions.instance;

  // ── Reads ─────────────────────────────────────────────────────────────────

  /// Requests addressed to the viewer that are still waiting for an answer.
  ///
  /// This is also the badge source. It is a live query, so accepting on
  /// another device, or a new request arriving, updates the header without an
  /// app restart.
  Stream<List<IncomingRequest>> watchIncoming() {
    final String? uid = currentUid;
    if (uid == null) return Stream<List<IncomingRequest>>.value(const <IncomingRequest>[]);
    return _db
        .collection('users')
        .doc(uid)
        .collection('buddyInvites')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((QuerySnapshot<Map<String, dynamic>> q) => q.docs
            .map(IncomingRequest.fromSnapshot)
            // A self-request cannot be created any more, but one written
            // before the rule existed would otherwise sit in the badge count
            // forever with no way to clear it.
            .where((IncomingRequest r) => r.fromUid != uid)
            .toList(growable: false));
  }

  /// Requests the viewer has sent and that have not been answered.
  ///
  /// Read from the viewer's OWN assignment document, because the invite itself
  /// lives under the receiver's account and the rules — correctly — do not let
  /// a sender read there.
  Stream<List<OutgoingRequest>> watchOutgoing() {
    final String? uid = currentUid;
    if (uid == null) return Stream<List<OutgoingRequest>>.value(const <OutgoingRequest>[]);
    return _db
        .collection('buddyAssignments')
        .doc(uid)
        .snapshots()
        .map((DocumentSnapshot<Map<String, dynamic>> snap) {
      final Object? athletes = (snap.data() ?? const <String, dynamic>{})['athletes'];
      if (athletes is! Map) return const <OutgoingRequest>[];
      final List<OutgoingRequest> out = <OutgoingRequest>[];
      athletes.forEach((Object? key, Object? value) {
        if (key is! String || value is! Map) return;
        if (value['status'] != 'pending') return;
        final Object? added = value['addedAt'];
        out.add(OutgoingRequest(
          toUid: key,
          displayName: (value['displayName'] as String?)?.trim() ?? '',
          sentAt: added is Timestamp ? added.toDate() : null,
        ));
      });
      out.sort((OutgoingRequest a, OutgoingRequest b) {
        final DateTime? x = a.sentAt;
        final DateTime? y = b.sentAt;
        if (x == null && y == null) return a.toUid.compareTo(b.toUid);
        if (x == null) return 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
      return out;
    });
  }

  /// Confirmed friends, from the server-maintained mutual projection.
  ///
  /// NOT derived from the viewer's own assignment document. That document says
  /// who the VIEWER has accepted, which is only half of a friendship — and the
  /// other half is in a document the rules do not let the viewer read. Deriving
  /// the list locally would show people who have not accepted back, and every
  /// one of those rows would lead to a profile the viewer cannot actually open.
  Stream<List<String>> watchFriends() {
    final String? uid = currentUid;
    if (uid == null) return Stream<List<String>>.value(const <String>[]);
    return _db
        .collection('socialGraph')
        .doc(uid)
        .snapshots()
        .map((DocumentSnapshot<Map<String, dynamic>> snap) {
      final Object? friends = (snap.data() ?? const <String, dynamic>{})['friends'];
      if (friends is! List) return const <String>[];
      return friends.whereType<String>().toList(growable: false);
    });
  }

  /// Acceptances of the viewer's own requests that the viewer has not seen.
  ///
  /// A live query over the viewer's OWN notices, so an acceptance lands in the
  /// badge without a restart, and one seen on another device leaves it there
  /// too. Newest first.
  Stream<List<AcceptedNotice>> watchUnseenAcceptances() {
    final String? uid = currentUid;
    if (uid == null) {
      return Stream<List<AcceptedNotice>>.value(const <AcceptedNotice>[]);
    }
    return _notifications(uid)
        .where('seen', isEqualTo: false)
        .snapshots()
        .map((QuerySnapshot<Map<String, dynamic>> q) {
      final List<AcceptedNotice> out = <AcceptedNotice>[];
      for (final QueryDocumentSnapshot<Map<String, dynamic>> d in q.docs) {
        final AcceptedNotice? n = AcceptedNotice.fromSnapshot(d, viewerUid: uid);
        if (n != null) out.add(n);
      }
      out.sort((AcceptedNotice a, AcceptedNotice b) {
        final DateTime? x = a.acceptedAt;
        final DateTime? y = b.acceptedAt;
        if (x == null && y == null) return a.uid.compareTo(b.uid);
        if (x == null) return 1;
        if (y == null) return -1;
        return y.compareTo(x);
      });
      return out;
    });
  }

  /// Everything the People view needs, as one stream.
  Stream<BuddyState> watchState() {
    final String? uid = currentUid;
    if (uid == null) return Stream<BuddyState>.value(const BuddyState(loaded: true));

    // Three listeners for the whole screen — never one per row. Combined here
    // rather than with three separate builders so the list cannot render a
    // half-updated state (a request accepted but not yet a friend, say).
    final StreamController<BuddyState> controller =
        StreamController<BuddyState>.broadcast();
    List<IncomingRequest> incoming = const <IncomingRequest>[];
    List<OutgoingRequest> outgoing = const <OutgoingRequest>[];
    List<String> friends = const <String>[];
    List<AcceptedNotice> accepted = const <AcceptedNotice>[];
    bool sawIncoming = false;
    bool sawOutgoing = false;
    bool sawFriends = false;
    bool sawAccepted = false;

    void emit() {
      if (controller.isClosed) return;
      controller.add(BuddyState(
        incoming: incoming,
        outgoing: outgoing,
        friends: friends,
        unseenAccepted: accepted,
        loaded: sawIncoming && sawOutgoing && sawFriends && sawAccepted,
      ));
    }

    final List<StreamSubscription<void>> subs = <StreamSubscription<void>>[
      watchIncoming().listen((List<IncomingRequest> v) {
        incoming = v;
        sawIncoming = true;
        emit();
      }, onError: (Object _) {
        sawIncoming = true;
        emit();
      }),
      watchOutgoing().listen((List<OutgoingRequest> v) {
        outgoing = v;
        sawOutgoing = true;
        emit();
      }, onError: (Object _) {
        sawOutgoing = true;
        emit();
      }),
      watchFriends().listen((List<String> v) {
        friends = v;
        sawFriends = true;
        emit();
      }, onError: (Object _) {
        sawFriends = true;
        emit();
      }),
      watchUnseenAcceptances().listen((List<AcceptedNotice> v) {
        accepted = v;
        sawAccepted = true;
        emit();
      }, onError: (Object _) {
        sawAccepted = true;
        emit();
      }),
    ];

    controller.onCancel = () async {
      for (final StreamSubscription<void> s in subs) {
        await s.cancel();
      }
    };
    return controller.stream;
  }

  /// Just the pending-request number.
  Stream<int> watchPendingCount() =>
      watchIncoming().map((List<IncomingRequest> r) => r.length);

  /// The header badge: pending requests plus unseen acceptances of the
  /// viewer's own requests. Live, and the viewer's own account only.
  Stream<BuddyBadge> watchBadge() =>
      watchState().map((BuddyState s) => s.badge).distinct();

  /// Marks [notices] seen, on the signed-in account only.
  ///
  /// Called by the People view once it has SHOWN them, never on opening the
  /// Hub, so the badge is never cleared without an explanation. The write is
  /// `seen: true` with `seenAt` at the server's clock — the only notice write
  /// the rules allow — and it is queued offline like any Firestore write, so a
  /// notice seen without a connection stays seen across restarts and devices.
  /// Pending requests are a different collection and are never touched here.
  Future<void> acknowledgeAcceptances(Iterable<AcceptedNotice> notices) async {
    final String? uid = currentUid;
    if (uid == null) return;
    final List<AcceptedNotice> list = notices.toList(growable: false);
    if (list.isEmpty) return;
    final WriteBatch batch = _db.batch();
    for (final AcceptedNotice n in list) {
      batch.update(_notifications(uid).doc(n.id), <String, Object?>{
        'seen': true,
        'seenAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  // ── Mutations ─────────────────────────────────────────────────────────────
  //
  // All four are callables. None of them takes an "acting as" uid, and none of
  // them can be replayed into a duplicate: the server keys an invite on the
  // sender's uid and writes absolute state rather than deltas.

  Future<BuddyRelationship> sendRequest(String targetUid) =>
      _call('buddySendRequest', <String, Object?>{'targetUid': targetUid});

  Future<BuddyRelationship> acceptRequest(String fromUid) =>
      _call('buddyRespondToRequest',
          <String, Object?>{'fromUid': fromUid, 'action': 'accept'});

  Future<BuddyRelationship> declineRequest(String fromUid) =>
      _call('buddyRespondToRequest',
          <String, Object?>{'fromUid': fromUid, 'action': 'decline'});

  Future<BuddyRelationship> cancelRequest(String targetUid) =>
      _call('buddyCancelRequest', <String, Object?>{'targetUid': targetUid});

  Future<BuddyRelationship> removeFriend(String buddyUid) =>
      _call('buddyRemoveFriend', <String, Object?>{'buddyUid': buddyUid});

  Future<BuddyRelationship> _call(
    String name,
    Map<String, Object?> payload,
  ) async {
    final HttpsCallableResult<Object?> result =
        await _fns.httpsCallable(name).call<Object?>(payload);
    final Object? data = result.data;
    if (data is Map) {
      return relationshipFromName(data['state'] as String?);
    }
    return BuddyRelationship.none;
  }
}

/// Why a social action could not be completed, in words a person can act on.
///
/// Social mutations need connectivity: they are two-account transactions and
/// there is no durable outbox behind them, so an optimistic "Requested" that
/// silently never happened would be a lie the UI never corrects. Saying so and
/// offering a retry is the honest option.
String describeSocialError(Object error) {
  if (error is FirebaseFunctionsException) {
    switch (error.code) {
      case 'unavailable':
      case 'deadline-exceeded':
        return "You're offline. Check your connection and try again.";
      case 'resource-exhausted':
        return 'Too many buddy requests just now. Try again a little later.';
      case 'not-found':
        return 'That account is no longer available.';
      case 'permission-denied':
      case 'unauthenticated':
        return 'Sign in again to manage your buddies.';
      case 'failed-precondition':
        return error.message ?? 'That is no longer possible.';
      default:
        return error.message ?? 'Something went wrong. Try again.';
    }
  }
  return 'Something went wrong. Try again.';
}
