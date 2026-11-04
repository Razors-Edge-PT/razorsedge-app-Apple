/// Profile identity — username, bio, avatar — read from and written to
/// `users_public/{uid}`, plus the server-published achievement snapshots.
///
/// ── Where the showcase comes from ───────────────────────────────────────────
/// `users_public` is readable by every signed-in account, so the derived
/// training achievements (profileShowcaseV1/V2) are published on the
/// friend-gated `users_showcase/{uid}` instead (functions/showcase). Only
/// the owner, a confirmed friend, the support override holder, an assigned
/// coach and the super admin may read it; anyone else gets a permission
/// denial, which is shown as NO showcase — the identity still renders.
/// Until the server migration has copied an athlete, their document does not
/// exist yet and the legacy users_public fields are used.
///
/// ── Offline model ───────────────────────────────────────────────────────────
/// Firestore's own persistent cache is the local store. A warm profile renders
/// from cache immediately (`isFromCache == true`) and is refreshed in the
/// background; no second copy of this data is kept anywhere, and Isar is not
/// involved.
///
/// ── Writes ──────────────────────────────────────────────────────────────────
/// Every write is a FIELD-LEVEL merge, so editing a bio cannot clobber an
/// avatar written from another device a second earlier. Two devices editing the
/// SAME field still resolve by Firestore's normal last-write-wins, which is the
/// right answer for a single-user-owned document.
///
/// `set()` completes only when the SERVER acknowledges. That is what lets this
/// repository tell "saved" from "saved offline" honestly rather than guessing:
/// a write that has not acknowledged within [_ackWindow] is queued locally, and
/// Firestore will deliver it when the connection returns.
library;

import '../../units/exercise_unit_registry.dart';
import '../../units/weight_unit.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/showcase_models.dart';
import '../core/showcase_v2_models.dart';

/// The maximum length of a bio, in characters.
const int kBioMaxLength = 150;

/// What the UI shows next to an edited field.
enum SaveState {
  /// Nothing in flight.
  idle,

  /// Written locally, waiting for the server.
  syncing,

  /// The server has it.
  saved,

  /// Queued on this device; it will sync when the connection returns.
  savedOffline,

  /// The write was rejected. Nothing was lost locally, but it is not saved.
  failed,
}

/// The profile as it is displayed.
@immutable
class ProfileIdentity {
  const ProfileIdentity({
    required this.uid,
    this.username,
    this.bio,
    this.photoURL,
    this.showcase = ProfileShowcase.empty,
    this.showcaseV2,
    this.exerciseUnits = const <String, ExerciseWeightUnit>{},
    this.isFromCache = false,
    this.hasPendingWrites = false,
    this.exists = false,
  });

  final String uid;
  final String? username;
  final String? bio;
  final String? photoURL;

  /// The Big Five snapshot mirrored by the server. Never written from a client.
  final ProfileShowcase showcase;

  /// The categories + RE Points snapshot (profileShowcaseV2), or null when it
  /// is absent or malformed — the UI then falls back to [showcase].
  final ProfileShowcaseV2? showcaseV2;

  /// The owner's published per-exercise display units
  /// (users_public.exerciseWeightUnits). Absent — every legacy profile — is
  /// kilograms for every exercise.
  final Map<String, ExerciseWeightUnit> exerciseUnits;

  /// True when this snapshot came from the local cache rather than the server.
  final bool isFromCache;

  /// True when this device has local edits the server has not acknowledged.
  final bool hasPendingWrites;

  final bool exists;

  static ProfileIdentity empty(String uid) => ProfileIdentity(uid: uid);

  ProfileIdentity copyWith({String? username, String? bio, String? photoURL}) {
    return ProfileIdentity(
      uid: uid,
      username: username ?? this.username,
      bio: bio ?? this.bio,
      photoURL: photoURL ?? this.photoURL,
      showcase: showcase,
      showcaseV2: showcaseV2,
      exerciseUnits: exerciseUnits,
      isFromCache: isFromCache,
      hasPendingWrites: hasPendingWrites,
      exists: exists,
    );
  }

  /// [showcase] is what the `users_showcase/{uid}` read gave; by default
  /// (and while that document does not exist) the legacy users_public fields.
  static ProfileIdentity fromSnapshot(
    String uid,
    DocumentSnapshot<Map<String, dynamic>> snap, {
    ShowcaseSource showcase = const ShowcaseSource.legacy(),
  }) {
    final Map<String, dynamic> d = snap.data() ?? const <String, dynamic>{};
    final Map<String, dynamic> s = showcase.fieldsFor(d);
    String? str(String key) {
      final Object? v = d[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      return null;
    }

    return ProfileIdentity(
      uid: uid,
      username: str('username') ?? str('displayName'),
      bio: (d['bio'] is String) ? d['bio'] as String : null,
      photoURL: str('photoURL') ?? str('photoUrl'),
      showcase: ProfileShowcase.fromMap(s[kShowcaseV1Field]),
      showcaseV2: ProfileShowcaseV2.fromMap(s[kShowcaseV2Field]),
      exerciseUnits:
          ExerciseUnits.parsePublished(d[kPublicExerciseUnitsField]),
      isFromCache: snap.metadata.isFromCache,
      hasPendingWrites: snap.metadata.hasPendingWrites,
      exists: snap.exists,
    );
  }
}

/// The friend-gated showcase document (functions/showcase/firestore_store.js).
const String kProfileShowcasesCollection = 'users_showcase';
const String kShowcaseV1Field = 'profileShowcaseV1';
const String kShowcaseV2Field = 'profileShowcaseV2';

/// The outcome of reading `users_showcase/{uid}`.
@immutable
class ShowcaseSource {
  /// The document's data.
  const ShowcaseSource.document(Map<String, dynamic> this._data)
      : _legacy = false;

  /// Not readable by this account (not a friend): no showcase at all.
  const ShowcaseSource.denied()
      : _data = const <String, dynamic>{},
        _legacy = false;

  /// Not read yet, or the document does not exist yet (an athlete the
  /// migration has not copied): the legacy users_public fields.
  const ShowcaseSource.legacy()
      : _data = null,
        _legacy = true;

  final Map<String, dynamic>? _data;
  final bool _legacy;

  /// The snapshot fields to use, given the users_public data [publicData].
  Map<String, dynamic> fieldsFor(Map<String, dynamic> publicData) =>
      _legacy ? publicData : _data ?? const <String, dynamic>{};

  /// Reads `users_showcase/[uid]` once. A permission denial is [denied].
  static Future<ShowcaseSource> read(FirebaseFirestore db, String uid) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> s =
          await db.collection(kProfileShowcasesCollection).doc(uid).get();
      return fromSnapshot(s);
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return const ShowcaseSource.denied();
      rethrow;
    }
  }

  static ShowcaseSource fromSnapshot(DocumentSnapshot<Map<String, dynamic>> s) {
    final Map<String, dynamic>? data = s.data();
    if (!s.exists || data == null) return const ShowcaseSource.legacy();
    return ShowcaseSource.document(data);
  }
}

class ProfileRepository {
  ProfileRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// How long to wait for a server acknowledgement before calling a write
  /// "saved offline". Long enough not to mislabel a slow-but-working network,
  /// short enough that the user is not left staring at a spinner.
  static const Duration _ackWindow = Duration(seconds: 4);

  DocumentReference<Map<String, dynamic>> _publicRef(String uid) =>
      _db.collection('users_public').doc(uid);

  DocumentReference<Map<String, dynamic>> _privateRef(String uid) =>
      _db.collection('users').doc(uid);

  DocumentReference<Map<String, dynamic>> _showcaseRef(String uid) =>
      _db.collection(kProfileShowcasesCollection).doc(uid);

  /// Live profile. Emits the cached document first (instant, offline-capable),
  /// then the server's. The showcase follows `users_showcase/{uid}`: until
  /// that read answers, and when it is denied, no showcase is shown — a
  /// non-friend is never handed the legacy copy. Its other errors surface on
  /// this stream like the identity's own.
  Stream<ProfileIdentity> watch(String uid) => combineIdentity(
        uid,
        _publicRef(uid).snapshots(includeMetadataChanges: true),
        _showcaseRef(uid).snapshots(),
      );

  /// [watch]'s combination of the identity and showcase streams.
  @visibleForTesting
  static Stream<ProfileIdentity> combineIdentity(
    String uid,
    Stream<DocumentSnapshot<Map<String, dynamic>>> publicSnapshots,
    Stream<DocumentSnapshot<Map<String, dynamic>>> showcaseSnapshots,
  ) {
    late final StreamController<ProfileIdentity> out;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? pubSub;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? showcaseSub;
    DocumentSnapshot<Map<String, dynamic>>? pub;
    ShowcaseSource showcase = const ShowcaseSource.denied();

    void emit() {
      final DocumentSnapshot<Map<String, dynamic>>? p = pub;
      if (p == null || out.isClosed) return;
      out.add(ProfileIdentity.fromSnapshot(uid, p, showcase: showcase));
    }

    out = StreamController<ProfileIdentity>(
      onListen: () {
        pubSub = publicSnapshots.listen(
          (DocumentSnapshot<Map<String, dynamic>> s) {
            pub = s;
            emit();
          },
          onError: out.addError,
        );
        showcaseSub = showcaseSnapshots.listen(
          (DocumentSnapshot<Map<String, dynamic>> s) {
            showcase = ShowcaseSource.fromSnapshot(s);
            emit();
          },
          onError: (Object e) {
            if (e is FirebaseException && e.code == 'permission-denied') {
              showcase = const ShowcaseSource.denied();
              emit();
              return;
            }
            out.addError(e);
          },
        );
      },
      onCancel: () async {
        await pubSub?.cancel();
        await showcaseSub?.cancel();
      },
    );
    return out.stream;
  }

  /// Trims a bio to the allowed length. Applied on the way in AND on the way
  /// out, so an over-long value written by an older build still displays.
  static String clampBio(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.length <= kBioMaxLength) return trimmed;
    return trimmed.substring(0, kBioMaxLength);
  }

  /// Saves the bio with a field-level merge.
  ///
  /// Mirrored onto the private `users` document as a best-effort convenience
  /// for existing screens that read it there; the public document is
  /// authoritative and its result is what this returns.
  Future<SaveState> saveBio(String uid, String bio) {
    final String value = clampBio(bio);
    // The mirror is deliberately not awaited: it must never be able to turn a
    // successful public write into a reported failure.
    unawaited(_privateRef(uid).set(
      <String, Object?>{'bio': value},
      SetOptions(merge: true),
    ).catchError((Object _) {}));

    return _writeWithState(_publicRef(uid), <String, Object?>{
      'bio': value,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Points the profile at a newly uploaded avatar.
  Future<SaveState> saveAvatar(
      String uid, String photoURL, String storagePath) {
    unawaited(_privateRef(uid).set(
      <String, Object?>{'photoURL': photoURL},
      SetOptions(merge: true),
    ).catchError((Object _) {}));

    return _writeWithState(_publicRef(uid), <String, Object?>{
      'photoURL': photoURL,
      'photoStoragePath': storagePath,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Runs a merge write and reports what actually happened.
  Future<SaveState> _writeWithState(
    DocumentReference<Map<String, dynamic>> ref,
    Map<String, Object?> data,
  ) async {
    // The write is applied to the local cache synchronously; this future is
    // the SERVER acknowledgement.
    final Future<void> ack = ref.set(data, SetOptions(merge: true));

    // A rejected write must surface as a failure even if it takes a while.
    unawaited(ack.catchError((Object _) {}));

    try {
      await ack.timeout(_ackWindow);
      return SaveState.saved;
    } on TimeoutException {
      // Not an error: Firestore has the write queued durably and will send it.
      return SaveState.savedOffline;
    } catch (_) {
      return SaveState.failed;
    }
  }
}
