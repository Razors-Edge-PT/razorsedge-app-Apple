/// Central identity service. The ONE place the app resolves or changes a
/// username.
///
/// Before this existed, three screens each wrote `username` / `usernameLower`
/// their own way, and one of them wrote only the private `users` document, so a
/// rename could leave `users_public` — the document every other screen searches
/// and displays — stale. Worse, all three checked availability with a query and
/// then wrote, which can never be race-free.
///
/// ── Identity resolution ─────────────────────────────────────────────────────
/// A username is resolved BY UID through [displayNameFor] / [watchDisplayName],
/// which read `users_public/{uid}` (served instantly from Firestore's
/// persistent cache, then refreshed). Usernames denormalised into comments,
/// posts, assignments and other historical documents are treated as FALLBACKS
/// and audit data — they record what the name was when that document was
/// written, not who the user is now.
///
/// ── Changing a username ─────────────────────────────────────────────────────
/// [changeUsername] calls the `profileChangeUsername` callable, which does the
/// whole thing in one Firestore transaction: reserve the new index key, release
/// the old one, update both user documents. It requires a connection and fails
/// closed — see [UsernameChangeOutcome.needsConnection].
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'username_rules.dart';

/// What happened when a username change was attempted.
enum UsernameChangeOutcome {
  /// The name is now the user's, everywhere.
  changed,

  /// The user already held exactly this name.
  unchanged,

  /// Definitively held by another account (case-insensitively).
  taken,

  /// Not a legal username.
  invalid,

  /// No connection. Uniqueness cannot be confirmed, so nothing was written.
  needsConnection,

  /// The call did not complete. Nothing was written.
  failed,
}

/// Result of a username change attempt.
@immutable
class UsernameChangeResult {
  const UsernameChangeResult(
    this.outcome, {
    this.username,
    this.message,
    this.authDisplayNameUpdated = false,
  });

  final UsernameChangeOutcome outcome;

  /// The name now in force, when the change succeeded.
  final String? username;

  /// User-facing explanation for a non-success outcome.
  final String? message;

  /// Whether the Firebase Auth displayName follow-up also succeeded. Firestore
  /// is authoritative either way — this is reported, never assumed.
  final bool authDisplayNameUpdated;

  bool get isSuccess =>
      outcome == UsernameChangeOutcome.changed ||
      outcome == UsernameChangeOutcome.unchanged;
}

/// What every surface needs about a person, resolved BY UID.
@immutable
class PublicIdentity {
  const PublicIdentity({required this.uid, this.displayName, this.photoURL});

  final String uid;

  /// The person's CURRENT username. Null when nothing has been resolved yet.
  final String? displayName;

  final String? photoURL;

  static PublicIdentity empty(String uid) => PublicIdentity(uid: uid);

  bool get hasName => displayName != null && displayName!.isNotEmpty;
}

/// Shown when a uid resolves to nothing at all — no live value, no
/// denormalised fallback. Better than a raw uid, which means nothing to a
/// reader and leaks an internal identifier into the UI.
const String kUnknownAthleteName = 'GoodLift athlete';

class IdentityRepository {
  IdentityRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    FirebaseAuth? auth,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _injectedFunctions = functions,
        _injectedAuth = auth;

  /// The app-wide instance.
  ///
  /// Shared so the uid → username cache is shared: the profile page, the feed,
  /// comment headers, the settings screen and signup all resolve identity
  /// through ONE cache rather than each reading the same document. It needs no
  /// initialisation, so it is safe to touch from anywhere at any time.
  static final IdentityRepository shared = IdentityRepository();

  final FirebaseFirestore _db;

  // Functions and Auth are resolved LAZILY. Touching `.instance` in the
  // constructor would require a live Firebase app just to construct the
  // repository, which makes identity resolution untestable without one — and
  // resolution is pure Firestore reads that a fake can serve perfectly well.
  final FirebaseFunctions? _injectedFunctions;
  final FirebaseAuth? _injectedAuth;

  FirebaseFunctions get _functions =>
      _injectedFunctions ?? FirebaseFunctions.instance;

  FirebaseAuth? get _authOrNull {
    final FirebaseAuth? injected = _injectedAuth;
    if (injected != null) return injected;
    try {
      return FirebaseAuth.instance;
    } catch (_) {
      return null;
    }
  }

  /// Process-lifetime cache of uid → display name. Backed by Firestore's own
  /// persistent cache, so a miss is still usually offline-answerable.
  ///
  /// This is a HINT for the first frame, never an answer that outlives a
  /// change: [watchPublicIdentity] keeps a live subscription open and
  /// overwrites this the moment the document changes.
  final Map<String, String> _nameCache = <String, String>{};

  /// Last known full public identity per uid, for the same first-frame reason.
  final Map<String, PublicIdentity> _identityCache = <String, PublicIdentity>{};

  /// One live channel per uid, shared by every widget showing that person.
  ///
  /// Twenty comments by one author cost ONE Firestore listener, not twenty —
  /// and, more importantly, all twenty update together the instant that author
  /// renames. The previous per-widget `FutureBuilder` + process-lifetime map
  /// could not: once a name was cached it was never re-read for the life of
  /// the process, so a rename simply did not appear until the app restarted.
  final Map<String, _IdentityChannel> _identityChannels =
      <String, _IdentityChannel>{};

  /// In-flight resolutions, so a grid of twenty comments by one author causes
  /// one read, not twenty.
  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};

  DocumentReference<Map<String, dynamic>> _publicRef(String uid) =>
      _db.collection('users_public').doc(uid);

  /// Last known name for [uid] without touching the network. Null when this
  /// process has never resolved it.
  String? cachedDisplayName(String uid) => _nameCache[uid];

  /// Last known public identity for [uid], for a StreamBuilder's initialData.
  PublicIdentity? cachedPublicIdentity(String uid) => _identityCache[uid];

  /// Live identity for [uid]: name and avatar, kept current.
  ///
  /// Broadcast and shared, so every surface showing this person subscribes to
  /// ONE Firestore listener and they all rebuild together. Firestore serves
  /// the first event from its persistent cache, so this is as fast as the old
  /// in-memory map on a warm start and correct on a rename, which the map
  /// never was.
  Stream<PublicIdentity> watchPublicIdentity(String uid) {
    if (uid.isEmpty) {
      return Stream<PublicIdentity>.value(PublicIdentity.empty(uid));
    }
    final _IdentityChannel channel = _identityChannels.putIfAbsent(
      uid,
      () => _IdentityChannel(
        source: _publicRef(uid).snapshots().map(
          (DocumentSnapshot<Map<String, dynamic>> snap) {
            final Map<String, dynamic>? data = snap.data();
            final PublicIdentity identity = PublicIdentity(
              uid: uid,
              displayName: _readName(data),
              photoURL: _readPhoto(data),
            );
            if (identity.hasName) _nameCache[uid] = identity.displayName!;
            _identityCache[uid] = identity;
            return identity;
          },
        ),
      ),
    );
    return channel.stream;
  }

  /// True when a live channel is already open for [uid]. For tests, and for
  /// asserting that N surfaces share ONE Firestore listener.
  @visibleForTesting
  bool hasOpenChannel(String uid) => _identityChannels.containsKey(uid);

  String? _readPhoto(Map<String, dynamic>? data) {
    final Object? url = data?['photoURL'];
    if (url is String && url.trim().isNotEmpty) return url.trim();
    return null;
  }

  /// Live username for [uid]. Emits the cached value immediately, then keeps
  /// up with the server.
  Stream<String?> watchDisplayName(String uid) => watchPublicIdentity(uid)
      .map((PublicIdentity identity) => identity.displayName);

  /// Resolves the CURRENT username for [uid].
  ///
  /// [fallback] is the denormalised name carried by whatever historical
  /// document prompted the lookup (a comment author, a post header, a roster
  /// row). It is used only when the authoritative lookup has nothing — it is
  /// never allowed to override the live value.
  Future<String?> displayNameFor(String uid, {String? fallback}) {
    final String? cached = _nameCache[uid];
    if (cached != null && cached.isNotEmpty)
      return Future<String?>.value(cached);

    return _inFlight.putIfAbsent(uid, () async {
      try {
        final DocumentSnapshot<Map<String, dynamic>> snap =
            await _publicRef(uid).get();
        final String? name = _readName(snap.data());
        if (name != null && name.isNotEmpty) {
          _nameCache[uid] = name;
          return name;
        }
      } catch (_) {
        // Offline with a cold cache, or a permission error. Fall through to
        // the historical value rather than showing nothing.
      } finally {
        _inFlight.remove(uid);
      }
      final String? fb = fallback?.trim();
      return (fb != null && fb.isNotEmpty) ? fb : null;
    });
  }

  /// Safe display name for the signed-in user when nothing else is known.
  String? get currentUserFallbackName {
    final User? user = _authOrNull?.currentUser;
    if (user == null) return null;
    final String? cached = _nameCache[user.uid];
    if (cached != null && cached.isNotEmpty) return cached;
    final String? display = user.displayName?.trim();
    if (display != null && display.isNotEmpty) return display;
    final String? email = user.email;
    if (email != null && email.contains('@')) return email.split('@').first;
    return null;
  }

  String? _readName(Map<String, dynamic>? data) {
    if (data == null) return null;
    final Object? username = data['username'];
    if (username is String && username.trim().isNotEmpty)
      return username.trim();
    final Object? displayName = data['displayName'];
    if (displayName is String && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }
    return null;
  }

  /// Cheap availability hint. NEVER authoritative — a `true` here can go stale
  /// between the check and the commit, which is exactly why the real decision
  /// is made inside the callable's transaction.
  ///
  /// Returns null when the check could not complete, which the UI must not
  /// present as "available".
  Future<bool?> isProbablyAvailable(String raw) async {
    final String lower = normalizeUsername(raw);
    if (lower.isEmpty) return null;
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await _db
          .collection('usernames')
          .doc(usernameIndexKey(lower))
          .get(const GetOptions(source: Source.server));
      if (!snap.exists) return true;
      return snap.data()?['uid'] == _authOrNull?.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  /// Changes the signed-in user's username everywhere, atomically.
  ///
  /// Never writes anything itself: the callable owns the reservation index and
  /// both user documents, so there is no path by which a client can half-apply
  /// a rename.
  Future<UsernameChangeResult> changeUsername(String raw) async {
    final UsernameProblem? problem = validateUsername(raw);
    if (problem != null) {
      return UsernameChangeResult(
        UsernameChangeOutcome.invalid,
        message: usernameProblemMessage(problem),
      );
    }

    try {
      final HttpsCallableResult<dynamic> res = await _functions
          .httpsCallable('profileChangeUsername')
          .call<dynamic>(<String, dynamic>{'username': displayUsername(raw)});

      final Map<Object?, Object?> data =
          (res.data as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
      final String username =
          (data['username'] as String?) ?? displayUsername(raw);
      final bool changed = data['changed'] == true;
      final bool authUpdated = data['authDisplayNameUpdated'] == true;

      final String? uid = _authOrNull?.currentUser?.uid;
      if (uid != null) {
        _nameCache[uid] = username;
        final PublicIdentity? previous = _identityCache[uid];
        _identityCache[uid] = PublicIdentity(
          uid: uid,
          displayName: username,
          photoURL: previous?.photoURL,
        );
      }

      return UsernameChangeResult(
        changed
            ? UsernameChangeOutcome.changed
            : UsernameChangeOutcome.unchanged,
        username: username,
        authDisplayNameUpdated: authUpdated,
      );
    } on FirebaseFunctionsException catch (e) {
      return _mapCallableError(e);
    } catch (e) {
      return UsernameChangeResult(
        UsernameChangeOutcome.failed,
        message: kUsernameCheckFailedMessage,
      );
    }
  }

  UsernameChangeResult _mapCallableError(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'already-exists':
        return const UsernameChangeResult(
          UsernameChangeOutcome.taken,
          message: kUsernameTakenMessage,
        );
      case 'invalid-argument':
        return UsernameChangeResult(
          UsernameChangeOutcome.invalid,
          message: e.message ?? 'That username can’t be used.',
        );
      case 'unavailable':
      case 'deadline-exceeded':
        // No connection, or one too poor to complete a transaction. Nothing
        // was written; say so plainly rather than implying the name is taken.
        return const UsernameChangeResult(
          UsernameChangeOutcome.needsConnection,
          message: kUsernameNeedsConnectionMessage,
        );
      default:
        return UsernameChangeResult(
          UsernameChangeOutcome.failed,
          message: kUsernameCheckFailedMessage,
        );
    }
  }
}

/// One long-lived Firestore subscription for one uid, fanned out to every
/// listener.
///
/// ── Why not `asBroadcastStream()` ───────────────────────────────────────────
/// A stream returned by `asBroadcastStream()` cancels its upstream
/// subscription when its LAST listener leaves, and does not restart it. So a
/// single `await stream.first` anywhere in the app — a one-shot resolution, a
/// test, a widget that is disposed — permanently killed the shared channel,
/// and every surface that subscribed afterwards received nothing. That is the
/// same "read once and never again" failure the process-lifetime cache had,
/// arrived at by a different route.
///
/// This holds the upstream subscription open for the life of the repository
/// (one small document per person the user has looked at) and replays the last
/// known value to each new listener, so a late subscriber renders immediately
/// instead of waiting for the next change.
class _IdentityChannel {
  _IdentityChannel({required Stream<PublicIdentity> source}) : _source = source;

  final Stream<PublicIdentity> _source;
  final StreamController<PublicIdentity> _out =
      StreamController<PublicIdentity>.broadcast();

  StreamSubscription<PublicIdentity>? _upstream;
  PublicIdentity? _last;

  Stream<PublicIdentity> get stream {
    _subscribe();
    final PublicIdentity? last = _last;
    if (last == null) return _out.stream;
    // Replay, then continue.
    return _out.stream.transform(
      StreamTransformer<PublicIdentity, PublicIdentity>.fromBind(
        (Stream<PublicIdentity> events) async* {
          yield last;
          yield* events;
        },
      ),
    );
  }

  void _subscribe() {
    if (_upstream != null) return;
    _upstream = _source.listen(
      (PublicIdentity identity) {
        _last = identity;
        if (!_out.isClosed) _out.add(identity);
      },
      // Offline with a cold cache, or a permission error: keep the channel
      // alive and report what is already known rather than tearing every
      // subscriber down with an error.
      onError: (Object _) {},
    );
  }
}
