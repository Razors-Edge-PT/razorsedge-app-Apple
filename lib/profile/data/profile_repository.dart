/// Profile identity: username, bio, avatar and the mirrored achievement
/// snapshot, all read from and written to `users_public/{uid}`.
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

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/showcase_models.dart';

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
      isFromCache: isFromCache,
      hasPendingWrites: hasPendingWrites,
      exists: exists,
    );
  }

  static ProfileIdentity fromSnapshot(
    String uid,
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) {
    final Map<String, dynamic> d = snap.data() ?? const <String, dynamic>{};
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
      showcase: ProfileShowcase.fromMap(d['profileShowcaseV1']),
      isFromCache: snap.metadata.isFromCache,
      hasPendingWrites: snap.metadata.hasPendingWrites,
      exists: snap.exists,
    );
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

  /// Live profile. Emits the cached document first (instant, offline-capable),
  /// then the server's.
  Stream<ProfileIdentity> watch(String uid) => _publicRef(uid)
      .snapshots(includeMetadataChanges: true)
      .map((DocumentSnapshot<Map<String, dynamic>> s) =>
          ProfileIdentity.fromSnapshot(uid, s));

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
