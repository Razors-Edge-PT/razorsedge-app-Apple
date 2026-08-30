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
///   5. Commit the metadata. A post and its proof pointer are ONE batch, so a
///      published achievement can never point at a post that does not exist,
///      and a proof video can never sit in the grid with no record attached.
///   6. ONLY THEN remove the row and the staged files.
///
/// ── The third crash window ──────────────────────────────────────────────────
/// Publishing a proof used to be two sequential awaits: write the post, then
/// write the pointer. Dying between them left a proof video in the gallery
/// with no achievement attached to it — and the retry could not repair it,
/// because the retry's "is this already committed?" check only looked at the
/// post. Finding the post, it declared the work done and deleted the outbox
/// row, making the half-published state permanent.
///
/// Both halves are now committed in one batch, and the check inspects BOTH
/// documents. A row whose post exists but whose pointer does not is REPAIRED
/// from the post's own stored URLs, with no re-upload.
library;

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../core/media_models.dart';
import '../core/media_urls.dart';
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

/// How many 20-row pages one pass will drain before yielding.
///
/// A backlog is bounded by what one person queued while offline, so this is
/// generous; it exists only so a corrupt row that somehow never leaves the
/// queue cannot spin the processor forever.
const int kMaxPagesPerPass = 25;

/// Rows claimed per page.
const int kOutboxPageSize = 20;

/// True when [error] means "not now", rather than "this will never work".
///
/// A transient failure must not consume one of the four automatic attempts.
/// Being offline, or running a pass in the moment before Firebase Auth has
/// restored the session, is not a failed attempt — it is not an attempt. The
/// old code counted them, so four passes during one commute exhausted the
/// budget and left the upload sitting in a "failed" state waiting for a tap
/// the user had no reason to know it needed.
bool isTransientUploadError(Object error) {
  if (error is SocketException) return true;
  if (error is TimeoutException) return true;
  if (error is FirebaseException) {
    switch (error.code) {
      // Firestore / Functions
      case 'unavailable':
      case 'deadline-exceeded':
      case 'aborted':
      case 'cancelled':
      case 'internal':
      case 'resource-exhausted':
      // Auth is not ready yet, or the token is being refreshed. The row is
      // fine; the session is not.
      case 'unauthenticated':
      case 'user-token-expired':
      case 'network-request-failed':
      // Storage
      case 'retry-limit-exceeded':
      case 'canceled':
      case 'unknown':
        return true;
      default:
        return false;
    }
  }
  // A bare network error from the platform channel, which arrives as a plain
  // exception with no code to inspect.
  final String text = error.toString().toLowerCase();
  return text.contains('network') ||
      text.contains('socket') ||
      text.contains('timed out') ||
      text.contains('timeout') ||
      text.contains('unavailable');
}

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

  /// The post exists but its proof pointer does not (crash window C: the
  /// process died between the two writes, in a build that made them
  /// separately). The media is already in Storage and already in the grid, so
  /// only the missing pointer is written.
  repairProofPointer,

  /// Upload, then commit.
  upload,
}

/// Which halves of a two-document publication are already present.
@immutable
class CommitState {
  const CommitState({required this.postExists, required this.proofExists});

  /// Nothing is known — the check could not complete (offline). Treated as
  /// "not committed", which is safe because every commit is idempotent.
  static const CommitState unknown =
      CommitState(postExists: false, proofExists: false);

  final bool postExists;
  final bool proofExists;
}

class MediaUploader {
  MediaUploader({
    required MediaOutbox outbox,
    required ProfileRepository profiles,
    required ShowcaseRepository showcase,
    required StoryRepository stories,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    FirebaseAuth? auth,
    String Function()? ownerUidOverride,
  })  : _outbox = outbox,
        _profiles = profiles,
        _showcase = showcase,
        _stories = stories,
        _db = firestore ?? FirebaseFirestore.instance,
        _injectedStorage = storage,
        _injectedAuth = auth,
        _ownerUidOverride = ownerUidOverride;

  final MediaOutbox _outbox;
  final ProfileRepository _profiles;
  final ShowcaseRepository _showcase;
  final StoryRepository _stories;
  final FirebaseFirestore _db;

  // Lazy for the same reason as MediaRepository: constructing the uploader must
  // not require a live Firebase app.
  final FirebaseStorage? _injectedStorage;

  // Auth is resolved lazily for the same reason: constructing the uploader
  // must not require a live Firebase app.
  final FirebaseAuth? _injectedAuth;

  /// Test seam. Supplies the owner directly, so the claim scoping can be
  /// exercised without a Firebase Auth instance.
  final String Function()? _ownerUidOverride;

  FirebaseStorage get _storage => _injectedStorage ?? FirebaseStorage.instance;

  FirebaseAuth? get _authOrNull {
    final FirebaseAuth? injected = _injectedAuth;
    if (injected != null) return injected;
    try {
      return FirebaseAuth.instance;
    } catch (_) {
      return null;
    }
  }

  /// The account whose rows this pass may claim, or null when there is none.
  ///
  /// An ANONYMOUS session returns null. An anonymous user cannot own profile
  /// media — their uid changes the moment they upgrade to a real account, so
  /// anything uploaded under it would be stranded at a Storage path nobody can
  /// reach again. Waiting is strictly better than publishing to a uid that is
  /// about to stop existing.
  String? get currentOwnerUid {
    final String Function()? override = _ownerUidOverride;
    if (override != null) {
      final String value = override();
      return value.isEmpty ? null : value;
    }
    final User? user = _authOrNull?.currentUser;
    if (user == null) return null;
    if (user.isAnonymous) return null;
    return user.uid.isEmpty ? null : user.uid;
  }

  bool _running = false;

  /// Processes everything the signed-in owner has waiting, then cleans up
  /// their superseded rows.
  ///
  /// Safe to call concurrently — overlapping calls collapse into one pass.
  ///
  /// ── The backlog is drained, not sampled ─────────────────────────────────
  /// The old pass claimed ONE page of 20 and stopped. Someone who queued 30
  /// items on a flight got 20 of them back on reconnect and the other 10
  /// whenever something happened to trigger another pass — which, if they
  /// simply left the profile open, might be never. Pages are now drained until
  /// the queue stops shrinking.
  ///
  /// PROGRESS, not page count, is what ends the loop: a page whose rows all
  /// deferred because the device is offline leaves the queue exactly as long,
  /// so the pass stops instead of spinning on the same 20 rows.
  /// [kMaxPagesPerPass] is a backstop, not the normal exit.
  Future<UploadPassResult> processAll() async {
    if (_running) return const UploadPassResult();
    final String? ownerUid = currentOwnerUid;
    // No signed-in real account: there is nothing this pass may claim. Not a
    // failure, and emphatically not an attempt.
    if (ownerUid == null) return const UploadPassResult();

    _running = true;
    int committed = 0;
    int alreadyCommitted = 0;
    int superseded = 0;
    int failed = 0;
    try {
      int remaining = await _outbox.claimableCount(ownerUid);
      for (int page = 0; page < kMaxPagesPerPass && remaining > 0; page++) {
        final List<OutboxItem> work = await _outbox.claimable(
          ownerUid: ownerUid,
          limit: kOutboxPageSize,
        );
        if (work.isEmpty) break;

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
            case _ItemOutcome.deferred:
              break;
          }
        }

        final int after = await _outbox.claimableCount(ownerUid);
        if (after >= remaining) break; // no progress; stop rather than spin
        remaining = after;
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
    return stepFor(item, await inspectCommit(item));
  }

  /// The pure decision, separated from the reads so both crash windows can be
  /// tested as decisions rather than only through a live Storage bucket.
  static UploadStep stepFor(OutboxItem item, CommitState state) {
    if (!state.postExists) return UploadStep.upload;
    final bool needsProof =
        item.kind == OutboxKind.proof && item.achievementFingerprint != null;
    if (needsProof && !state.proofExists) return UploadStep.repairProofPointer;
    return UploadStep.skipAlreadyCommitted;
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

    // 2b. Crash window C: the post landed but its proof pointer did not. The
    //     media is already uploaded and already in the grid, so re-uploading
    //     would be pure waste — only the missing half is written.
    if (step == UploadStep.repairProofPointer) {
      try {
        await repairProofPointer(item);
        await _finish(item);
        return _ItemOutcome.committed;
      } catch (e) {
        return _recordFailure(item, e);
      }
    }

    // The attempt is NOT counted here. It is counted in _recordFailure, and
    // only for a failure that is actually this row's problem — see
    // isTransientUploadError.
    await _outbox.markUploading(item.mediaId);

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

      // 3. Deterministic path: a retry OVERWRITES, it never duplicates. The
      //    Content-Type is derived from the object's real extension, so a
      //    QuickTime upload is declared video/quicktime rather than being
      //    mislabelled as MP4.
      final Reference ref = _storage.ref(item.storagePath);
      await ref.putFile(
        file,
        SettableMetadata(contentType: contentTypeForPath(item.storagePath)),
      );
      final String url = await ref.getDownloadURL();

      // 3b. The poster frame is a SEPARATE object at a deterministic sibling
      //     path. Without it there is no image to put in `thumbUrl`, which is
      //     why earlier builds stored the video's own URL there and every
      //     video tile rendered as a broken image.
      final String thumbUrl = await uploadThumbnail(item) ?? '';

      // 4. Supersession is re-checked here, not only at the start: the upload
      //    may have taken minutes, and the user may have chosen again.
      if (await _outbox.isSuperseded(item)) return _ItemOutcome.superseded;

      // 5. Commit metadata.
      await commitMetadata(item, url, thumbUrl: thumbUrl);
      // The row worked. Clear its history so an earlier partial failure cannot
      // count against a later retry of the same asset.
      await _outbox.resetAttempts(item.mediaId);

      // 6. Only now is it safe to forget.
      await _finish(item);
      return _ItemOutcome.committed;
    } catch (e) {
      return _recordFailure(item, e);
    }
  }

  /// Uploads the locally generated poster frame to the deterministic sibling
  /// path and returns its download URL, or null when there is none.
  ///
  /// A missing or unuploadable thumbnail is NOT a failure: the post is still
  /// worth publishing, and the grid falls back to a video placeholder. What it
  /// must never do is silently substitute the video URL.
  Future<String?> uploadThumbnail(OutboxItem item) async {
    if (item.mediaType != MediaType.video) return null;
    final String? thumbPath = thumbnailStoragePathFor(item.storagePath);
    final String? localThumb = item.localThumbPath;
    if (thumbPath == null || localThumb == null || localThumb.isEmpty) {
      return null;
    }
    final File thumbFile = File(localThumb);
    if (!thumbFile.existsSync()) return null;
    try {
      final Reference ref = _storage.ref(thumbPath);
      await ref.putFile(
        thumbFile,
        SettableMetadata(contentType: contentTypeForPath(thumbPath)),
      );
      return await ref.getDownloadURL();
    } catch (_) {
      return null;
    }
  }

  /// Records a failure, and decides whether it cost the row an attempt.
  ///
  /// Returns the outcome to report: `deferred` for a transient condition,
  /// `failed` for a real one.
  Future<_ItemOutcome> _recordFailure(OutboxItem item, Object error) async {
    if (isTransientUploadError(error)) {
      // Not an attempt. The row goes straight back to pending with its budget
      // untouched, and the next pass — on reconnect, on resume — tries again.
      await _outbox.markDeferred(item.mediaId, error.toString());
      return _ItemOutcome.deferred;
    }
    // A real failure. NOW it costs an attempt.
    await _outbox.bumpAttempt(item.mediaId);
    final OutboxItem? current = await _outbox.byId(item.mediaId);
    final int attempts = current?.attemptCount ?? item.attemptCount + 1;
    await _outbox.markFailed(
      item.mediaId,
      error.toString(),
      terminal: attempts >= kMaxAutomaticAttempts,
    );
    return _ItemOutcome.failed;
  }

  /// Which halves of this item's publication already exist.
  ///
  /// BOTH documents are inspected for a proof. Looking only at the post is
  /// what made crash window C permanent: the retry found the post, declared
  /// the work finished and deleted the outbox row, stranding a proof video in
  /// the gallery with no achievement attached.
  ///
  /// Public so both crash windows are directly testable.
  Future<CommitState> inspectCommit(OutboxItem item) async {
    try {
      switch (item.kind) {
        case OutboxKind.story:
          final bool exists =
              await _stories.exists(item.ownerUid, item.mediaId);
          return CommitState(postExists: exists, proofExists: exists);
        case OutboxKind.post:
        case OutboxKind.proof:
          final DocumentSnapshot<Map<String, dynamic>> snap = await _db
              .collection('posts')
              .doc(item.mediaId)
              .get(const GetOptions(source: Source.server));
          final String? fingerprint = item.achievementFingerprint;
          if (item.kind != OutboxKind.proof || fingerprint == null) {
            return CommitState(postExists: snap.exists, proofExists: true);
          }
          final DocumentSnapshot<Map<String, dynamic>> proof = await _db
              .collection('users')
              .doc(item.ownerUid)
              .collection('proofs')
              .doc(fingerprint)
              .get(const GetOptions(source: Source.server));
          return CommitState(
            postExists: snap.exists,
            proofExists: proof.exists &&
                (proof.data()?['postId'] as String?) == item.mediaId,
          );
        case OutboxKind.avatar:
          // An avatar has no document of its own; the profile field is the
          // metadata, and it is idempotent to write, so there is nothing to
          // skip. Always proceed.
          return CommitState.unknown;
        default:
          return CommitState.unknown;
      }
    } catch (_) {
      // Cannot tell (offline). Proceeding is safe: every commit below is an
      // idempotent set() on a deterministic document id.
      return CommitState.unknown;
    }
  }

  /// True when this item's post document already exists. Retained for callers
  /// that only care about the post half.
  Future<bool> metadataExists(OutboxItem item) async =>
      (await inspectCommit(item)).postExists;

  /// Writes ONLY the missing proof pointer for a post that is already
  /// published, using the URLs the post itself already carries.
  ///
  /// No re-upload: the media is in Storage and the tile is in the grid. The
  /// only thing missing is the claim that it proves a record.
  Future<void> repairProofPointer(OutboxItem item) async {
    final String? fingerprint = item.achievementFingerprint;
    if (fingerprint == null) return;
    final DocumentSnapshot<Map<String, dynamic>> post =
        await _db.collection('posts').doc(item.mediaId).get();
    final Map<String, dynamic> d = post.data() ?? const <String, dynamic>{};
    await _proofRef(item.ownerUid, fingerprint).set(
      _proofPointer(
        item,
        thumbUrl: (d['thumbUrl'] as String?) ?? '',
        storagePath: (d['storagePathOriginal'] as String?) ?? item.storagePath,
      ),
      SetOptions(merge: true),
    );
  }

  DocumentReference<Map<String, dynamic>> _proofRef(
          String ownerUid, String fingerprint) =>
      _db
          .collection('users')
          .doc(ownerUid)
          .collection('proofs')
          .doc(fingerprint);

  Map<String, Object?> _proofPointer(
    OutboxItem item, {
    required String thumbUrl,
    required String storagePath,
  }) =>
      <String, Object?>{
        'fingerprint': item.achievementFingerprint,
        'slot': item.achievementSlot ?? '',
        'postId': item.mediaId,
        'storagePath': storagePath,
        'mediaType': item.mediaType,
        'thumbUrl': thumbUrl,
        'createdAt': FieldValue.serverTimestamp(),
      };

  /// Writes the Firestore metadata for a completed upload.
  ///
  /// [url] is the PLAYABLE media URL. [thumbUrl] is a still image, and is
  /// empty when none could be generated — it is never quietly filled with
  /// [url], because a video URL handed to an image decoder renders as a broken
  /// image rather than a poster frame.
  ///
  /// Every write is an idempotent `set(merge: true)` on a DETERMINISTIC
  /// document id, which is what makes crash window A (Storage succeeded,
  /// Firestore did not) safe to retry: the second attempt overwrites identical
  /// content instead of creating a duplicate post.
  ///
  /// A proof publishes as ONE BATCH — the post and the pointer that claims it
  /// proves a record commit together or not at all. Two sequential writes left
  /// a window in which the process could die with the video in the grid and no
  /// achievement attached to it.
  ///
  /// Public so that idempotency is testable.
  Future<void> commitMetadata(
    OutboxItem item,
    String url, {
    String thumbUrl = '',
  }) async {
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
          thumbUrl: thumbUrl,
          thumbPath: thumbnailStoragePathFor(item.storagePath) ?? '',
        );

      case OutboxKind.post:
      case OutboxKind.proof:
        final bool isProof = item.kind == OutboxKind.proof;
        // An image is its own thumbnail; a video only has one when the poster
        // frame uploaded. Anything else stays EMPTY.
        final String posterUrl =
            item.mediaType == MediaType.video ? thumbUrl : url;

        final WriteBatch batch = _db.batch();
        batch.set(
          _db.collection('posts').doc(item.mediaId),
          <String, Object?>{
            'ownerUid': item.ownerUid,
            'mediaType': item.mediaType,
            'type': isProof ? PostKind.proof : PostKind.upload,
            'storagePathOriginal': item.storagePath,
            'smallUrl': url,
            'thumbUrl': posterUrl,
            if (posterUrl.isNotEmpty)
              'thumbStoragePath': thumbnailStoragePathFor(item.storagePath),
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
          },
          SetOptions(merge: true),
        );

        if (isProof && item.achievementFingerprint != null) {
          // The proof pointer references the SAME asset — one upload serves
          // both the grid tile and the achievement — and lands in the SAME
          // batch, so there is no instant at which one exists without the
          // other.
          batch.set(
            _proofRef(item.ownerUid, item.achievementFingerprint!),
            _proofPointer(
              item,
              thumbUrl: posterUrl,
              storagePath: item.storagePath,
            ),
            SetOptions(merge: true),
          );
        }

        await batch.commit();
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
    final String? ownerUid = currentOwnerUid;
    if (ownerUid == null) return 0;
    final List<OutboxItem> orphans = await _outbox.superseded(ownerUid);
    int cleaned = 0;
    for (final OutboxItem item in orphans) {
      try {
        await _storage.ref(item.storagePath).delete();
      } on FirebaseException catch (e) {
        if (e.code != 'object-not-found') continue; // retry next pass
      } catch (_) {
        continue;
      }
      // The poster frame is a second object beside the media; a superseded row
      // may have got as far as uploading it.
      final String? thumbPath = thumbnailStoragePathFor(item.storagePath);
      if (thumbPath != null) {
        try {
          await _storage.ref(thumbPath).delete();
        } catch (_) {
          // Absent is the common case, and is fine.
        }
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

enum _ItemOutcome {
  committed,
  alreadyCommitted,
  superseded,
  failed,

  /// Not now: offline, or the session is not ready. No attempt was consumed.
  deferred,
}
