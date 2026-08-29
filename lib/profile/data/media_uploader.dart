/// Drains the media outbox: prepare → upload → commit metadata → clean up.
///
/// Runs on app start, on resume, when connectivity returns, and on an explicit
/// user retry. Nothing about correctness depends on an upload task surviving —
/// it depends on the outbox row surviving, which it does.
///
/// ── The step order is the contract ──────────────────────────────────────────
///   1. Skip if superseded (a newer choice for this asset exists).
///   2. Skip the upload if the metadata document ALREADY exists — crash window
///      B, where Firestore committed and the app died before the row was
///      removed. Re-uploading would be waste; re-committing would duplicate.
///   3. Upload to the deterministic path. Crash window A (Storage succeeded,
///      Firestore did not) is handled by this being an overwrite of the same
///      object rather than a new one.
///   4. Re-check supersession IMMEDIATELY before committing. A slow upload
///      chosen at 10:00 must not become the live avatar after the 10:01 one
///      already did.
///   5. Commit the metadata.
///   6. ONLY THEN remove the row and the staged files.
library;

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../core/media_models.dart';
import 'media_outbox.dart';
import 'profile_repository.dart';
import 'showcase_repository.dart';
import 'story_repository.dart';

/// Outcome of one processing pass, for tests and diagnostics.
@immutable
class UploadPassResult {
  const UploadPassResult({
    this.committed = 0,
    this.skippedAlreadyCommitted = 0,
    this.skippedSuperseded = 0,
    this.failed = 0,
    this.orphansCleaned = 0,
  });

  final int committed;
  final int skippedAlreadyCommitted;
  final int skippedSuperseded;
  final int failed;
  final int orphansCleaned;
}

/// How many times an item retries automatically before it waits for the user.
const int kMaxAutomaticAttempts = 4;

/// What a processing pass should do with one outbox row.
///
/// Public so the two crash windows can be tested for what they are — decisions
/// — rather than only through a full upload with a live Storage bucket.
enum UploadStep {
  /// A newer generation of this replaceable asset exists. Never commit.
  skipSuperseded,

  /// The metadata document already exists (crash window B: Firestore committed
  /// and the app died before the row was removed). Finish, do not re-upload.
  skipAlreadyCommitted,

  /// Upload, then commit.
  upload,
}

class MediaUploader {
  MediaUploader({
    required MediaOutbox outbox,
    required ProfileRepository profiles,
    required ShowcaseRepository showcase,
    required StoryRepository stories,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _outbox = outbox,
        _profiles = profiles,
        _showcase = showcase,
        _stories = stories,
        _db = firestore ?? FirebaseFirestore.instance,
        _injectedStorage = storage;

  final MediaOutbox _outbox;
  final ProfileRepository _profiles;
  final ShowcaseRepository _showcase;
  final StoryRepository _stories;
  final FirebaseFirestore _db;

  // Lazy for the same reason as MediaRepository: constructing the uploader must
  // not require a live Firebase app.
  final FirebaseStorage? _injectedStorage;

  FirebaseStorage get _storage => _injectedStorage ?? FirebaseStorage.instance;

  bool _running = false;

  /// Processes everything currently claimable, then cleans up superseded rows.
  /// Safe to call concurrently — overlapping calls collapse into one pass.
  Future<UploadPassResult> processAll() async {
    if (_running) return const UploadPassResult();
    _running = true;
    int committed = 0;
    int alreadyCommitted = 0;
    int superseded = 0;
    int failed = 0;
    try {
      final List<OutboxItem> work = await _outbox.claimable(limit: 20);
      for (final OutboxItem item in work) {
        final _ItemOutcome outcome = await _processOne(item);
        switch (outcome) {
          case _ItemOutcome.committed:
            committed++;
          case _ItemOutcome.alreadyCommitted:
            alreadyCommitted++;
          case _ItemOutcome.superseded:
            superseded++;
          case _ItemOutcome.failed:
            failed++;
        }
      }
      final int orphans = await cleanupSuperseded();
      return UploadPassResult(
        committed: committed,
        skippedAlreadyCommitted: alreadyCommitted,
        skippedSuperseded: superseded,
        failed: failed,
        orphansCleaned: orphans,
      );
    } finally {
      _running = false;
    }
  }

  /// Decides what to do with [item] without doing any of it.
  Future<UploadStep> planFor(OutboxItem item) async {
    if (await _outbox.isSuperseded(item)) return UploadStep.skipSuperseded;
    if (await metadataExists(item)) return UploadStep.skipAlreadyCommitted;
    return UploadStep.upload;
  }

  Future<_ItemOutcome> _processOne(OutboxItem item) async {
    final UploadStep step = await planFor(item);
    // 1. A newer generation already won.
    if (step == UploadStep.skipSuperseded) return _ItemOutcome.superseded;

    // 2. Crash window B: the metadata is already there.
    if (step == UploadStep.skipAlreadyCommitted) {
      await _finish(item);
      return _ItemOutcome.alreadyCommitted;
    }

    await _outbox.markUploading(item.mediaId);
    await _outbox.bumpAttempt(item.mediaId);

    try {
      final File file = File(item.localFilePath);
      if (!file.existsSync()) {
        // The staged copy is gone; there is nothing to upload and no way to
        // recover it. Stop retrying rather than looping forever.
        await _outbox.markFailed(
          item.mediaId,
          'The file is no longer available on this device.',
          terminal: true,
        );
        return _ItemOutcome.failed;
      }

      // 3. Deterministic path: a retry OVERWRITES, it never duplicates.
      final Reference ref = _storage.ref(item.storagePath);
      await ref.putFile(
        file,
        SettableMetadata(contentType: _contentTypeFor(item)),
      );
      final String url = await ref.getDownloadURL();

      // 4. Supersession is re-checked here, not only at the start: the upload
      //    may have taken minutes, and the user may have chosen again.
      if (await _outbox.isSuperseded(item)) return _ItemOutcome.superseded;

      // 5. Commit metadata.
      await commitMetadata(item, url);

      // 6. Only now is it safe to forget.
      await _finish(item);
      return _ItemOutcome.committed;
    } catch (e) {
      final OutboxItem? current = await _outbox.byId(item.mediaId);
      final int attempts = current?.attemptCount ?? item.attemptCount + 1;
      await _outbox.markFailed(
        item.mediaId,
        e.toString(),
        terminal: attempts >= kMaxAutomaticAttempts,
      );
      return _ItemOutcome.failed;
    }
  }

  String _contentTypeFor(OutboxItem item) =>
      item.mediaType == MediaType.video ? 'video/mp4' : 'image/jpeg';

  /// True when this item's metadata document already exists.
  ///
  /// Public so crash window B is directly testable.
  Future<bool> metadataExists(OutboxItem item) async {
    try {
      switch (item.kind) {
        case OutboxKind.story:
          return await _stories.exists(item.ownerUid, item.mediaId);
        case OutboxKind.post:
        case OutboxKind.proof:
          final DocumentSnapshot<Map<String, dynamic>> snap = await _db
              .collection('posts')
              .doc(item.mediaId)
              .get(const GetOptions(source: Source.server));
          return snap.exists;
        case OutboxKind.avatar:
          // An avatar has no document of its own; the profile field is the
          // metadata, and it is idempotent to write, so there is nothing to
          // skip. Always proceed.
          return false;
        default:
          return false;
      }
    } catch (_) {
      // Cannot tell (offline). Proceeding is safe: every commit below is an
      // idempotent set() on a deterministic document id.
      return false;
    }
  }

  /// Writes the Firestore metadata for a completed upload.
  ///
  /// Every write is an idempotent `set(merge: true)` on a DETERMINISTIC
  /// document id, which is what makes crash window A (Storage succeeded,
  /// Firestore did not) safe to retry: the second attempt overwrites identical
  /// content instead of creating a duplicate post.
  ///
  /// Public so that idempotency is testable.
  Future<void> commitMetadata(OutboxItem item, String url) async {
    switch (item.kind) {
      case OutboxKind.avatar:
        await _profiles.saveAvatar(item.ownerUid, url, item.storagePath);

      case OutboxKind.story:
        await _stories.publish(
          ownerUid: item.ownerUid,
          storyId: item.mediaId,
          mediaType: item.mediaType,
          storagePath: item.storagePath,
          url: url,
        );

      case OutboxKind.post:
      case OutboxKind.proof:
        final bool isProof = item.kind == OutboxKind.proof;
        await _db.collection('posts').doc(item.mediaId).set(<String, Object?>{
          'ownerUid': item.ownerUid,
          'mediaType': item.mediaType,
          'type': isProof ? PostKind.proof : PostKind.upload,
          'storagePathOriginal': item.storagePath,
          'smallUrl': url,
          'thumbUrl': url,
          'caption': item.caption,
          'showInGrid': true,
          'mediaId': item.mediaId,
          if (isProof && item.achievementFingerprint != null)
            'achievement': <String, Object?>{
              'fingerprint': item.achievementFingerprint,
              'slot': item.achievementSlot ?? '',
            },
          'likeCount': 0,
          'goodLiftCount': 0,
          'commentCount': 0,
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        if (isProof && item.achievementFingerprint != null) {
          // The proof pointer references the SAME asset — one upload serves
          // both the grid tile and the achievement.
          await _db
              .collection('users')
              .doc(item.ownerUid)
              .collection('proofs')
              .doc(item.achievementFingerprint!)
              .set(<String, Object?>{
            'fingerprint': item.achievementFingerprint,
            'slot': item.achievementSlot ?? '',
            'postId': item.mediaId,
            'storagePath': item.storagePath,
            'mediaType': item.mediaType,
            'thumbUrl': url,
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
    }
  }

  /// Removes the row and its staged files. Called only after a confirmed
  /// commit.
  Future<void> _finish(OutboxItem item) async {
    await _deleteLocal(item.localFilePath);
    await _deleteLocal(item.localThumbPath);
    await _outbox.remove(item.mediaId);
  }

  /// Cleans up rows a newer generation replaced: their staged files, and any
  /// Storage object a partially-finished upload left behind.
  ///
  /// Only ever touches objects whose deterministic path belongs to a
  /// superseded row, so it can never delete the live asset.
  Future<int> cleanupSuperseded() async {
    final List<OutboxItem> orphans = await _outbox.superseded();
    int cleaned = 0;
    for (final OutboxItem item in orphans) {
      try {
        await _storage.ref(item.storagePath).delete();
      } on FirebaseException catch (e) {
        if (e.code != 'object-not-found') continue; // retry next pass
      } catch (_) {
        continue;
      }
      await _deleteLocal(item.localFilePath);
      await _deleteLocal(item.localThumbPath);
      await _outbox.remove(item.mediaId);
      cleaned++;
    }
    return cleaned;
  }

  Future<void> _deleteLocal(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final File f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // A staged file that is already gone is fine.
    }
  }

  /// Attaches an already-uploaded post as proof, for the relink flow.
  Future<void> relinkProof({
    required String ownerUid,
    required ProfileMediaItem media,
    required record,
  }) =>
      _showcase.relinkExistingMedia(
        ownerUid: ownerUid,
        record: record,
        postId: media.id,
        storagePath: media.storagePath,
        mediaType: media.mediaType,
        thumbUrl: media.thumbUrl,
      );
}

enum _ItemOutcome { committed, alreadyCommitted, superseded, failed }
