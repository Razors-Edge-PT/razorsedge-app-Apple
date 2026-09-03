/// The profile media grid: reads the existing `posts` collection, merges in
/// the owner's still-uploading items from the outbox, and performs owner-only
/// deletion across Firestore AND Storage.
///
/// Nothing here reimplements posts, comments, likes or playback — those already
/// exist in the app (`post_service.dart`, `feed_post_card.dart`, the post
/// detail page) and are reused. This repository's job is the grid: what to
/// show, in what order, and how to add to and remove from it safely.
library;

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../core/media_identity.dart';
import '../core/media_models.dart';
import '../core/media_urls.dart';
import 'media_deletion.dart';
import 'media_outbox.dart';

class MediaRepository {
  MediaRepository({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    required MediaOutbox outbox,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _injectedStorage = storage,
        _outbox = outbox;

  final FirebaseFirestore _db;

  // Storage is resolved LAZILY so this repository can be constructed — and its
  // grid behaviour tested — without a live Firebase app. Reading the grid never
  // touches Storage; only deletion does.
  final FirebaseStorage? _injectedStorage;
  final MediaOutbox _outbox;

  FirebaseStorage get _storage => _injectedStorage ?? FirebaseStorage.instance;

  CollectionReference<Map<String, dynamic>> get _posts =>
      _db.collection('posts');

  /// Published grid media for [ownerUid], newest first.
  ///
  /// ── Why eligibility is decided by the SERVER ───────────────────────────────
  /// `posts` is not a gallery collection. RE Daily writes a summary record into
  /// it on every training day - `type: 're_daily'`, an `ownerUid` and a
  /// `createdAt`, and NO media of any kind (`_upsertDailyPost` in re_daily.dart,
  /// and the same shape again in functions/index.js). Anything else that lands
  /// in `posts` without belonging in a gallery has the same effect.
  ///
  /// Deciding on the CLIENT meant `limit` was spent before the decision was
  /// made. Sixty daily records since the last upload produced an empty gallery;
  /// sixty posts hidden with `showInGrid: false` did exactly the same thing,
  /// and those carry a perfectly valid `mediaType`, so filtering on type alone
  /// did not save them. Both clauses have to be in the query, ahead of the
  /// limit.
  ///
  ///   * `showInGrid == true` is the direct statement of gallery eligibility.
  ///     Every current publication path writes it explicitly - the post, proof
  ///     and image/video branches of `MediaUploader.commitMetadata` - and no
  ///     non-gallery writer writes it at all.
  ///   * `mediaType in [image, video]` is type validation at the query level: a
  ///     record with a missing or unknown type never reaches the grid, so
  ///     nothing malformed is handed to an image decoder on the strength of a
  ///     defaulted field.
  ///
  /// ── What this deliberately gives up ────────────────────────────────────────
  /// `showInGrid` was introduced in 1.7.13, so posts written before it carry no
  /// such field and are now ABSENT from the gallery. That is a chosen trade,
  /// not an oversight: correctness of the current system comes first, and the
  /// alternative - a second query, or a client-side merge that reintroduces the
  /// pre-limit problem for the sake of old records - would put the defect back.
  /// Nothing is migrated and no legacy document is modified to compensate.
  ///
  /// Requires the composite index
  /// `ownerUid ASC, showInGrid ASC, mediaType ASC, createdAt DESC`
  /// declared in firestore.indexes.json.
  Stream<List<ProfileMediaItem>> watchGrid(String ownerUid, {int limit = 60}) {
    return _posts
        .where('ownerUid', isEqualTo: ownerUid)
        .where('showInGrid', isEqualTo: true)
        .where('mediaType', whereIn: kSupportedMediaTypes.toList())
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots(includeMetadataChanges: true)
        .map((QuerySnapshot<Map<String, dynamic>> q) => q.docs
            .map(ProfileMediaItem.fromSnapshot)
            .where(_belongsInGrid)
            .toList(growable: false));
  }

  /// The same eligibility test the query applies, repeated in Dart.
  ///
  /// Not redundant: [mergeGrid] folds in optimistic outbox tiles that never
  /// went through the query, and a malformed record reaching here by any other
  /// route meets the same rule rather than a defaulted one.
  bool _belongsInGrid(ProfileMediaItem item) =>
      item.showInGrid && isSupportedMediaType(item.mediaType);

  /// The owner's pending uploads, so their own grid shows a new item the
  /// instant they choose it — including across an app restart.
  Stream<List<ProfileMediaItem>> watchPending(String ownerUid) {
    return _outbox.watchPendingFor(ownerUid).map((List<OutboxItem> rows) => rows
        .where((OutboxItem r) =>
            r.kind == OutboxKind.post || r.kind == OutboxKind.proof)
        .map(_pendingItem)
        .toList(growable: false));
  }

  /// The staged path of the owner's newest pending avatar, or null.
  ///
  /// Only the HIGHEST generation is offered: while two avatar choices are in
  /// flight, the preview must show the one the user chose last, not whichever
  /// row happens to come first.
  Stream<String?> watchPendingAvatarPath(String ownerUid) {
    return _outbox.watchPendingFor(ownerUid).map((List<OutboxItem> rows) {
      final List<OutboxItem> avatars = rows
          .where((OutboxItem r) => r.kind == OutboxKind.avatar)
          .toList()
        ..sort((OutboxItem a, OutboxItem b) =>
            b.generation.compareTo(a.generation));
      return avatars.isEmpty ? null : avatars.first.localFilePath;
    });
  }

  ProfileMediaItem _pendingItem(OutboxItem row) => ProfileMediaItem(
        id: row.mediaId,
        ownerUid: row.ownerUid,
        mediaType: row.mediaType,
        kind: row.kind == OutboxKind.proof ? PostKind.proof : PostKind.upload,
        storagePath: row.storagePath,
        caption: row.caption,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAtMs),
        proof: row.achievementFingerprint == null
            ? null
            : ProofLink(
                fingerprint: row.achievementFingerprint!,
                slot: row.achievementSlot ?? '',
              ),
        localFilePath: row.localFilePath,
        localThumbPath: row.localThumbPath,
        pending: true,
        failed: row.state == OutboxState.failed,
        lastError: row.lastError,
      );

  /// Merges published and pending items into one newest-first list, dropping
  /// any pending item whose published document has already arrived.
  static List<ProfileMediaItem> mergeGrid(
    List<ProfileMediaItem> published,
    List<ProfileMediaItem> pending,
  ) {
    final Set<String> publishedIds =
        published.map((ProfileMediaItem i) => i.id).toSet();
    final List<ProfileMediaItem> merged = <ProfileMediaItem>[
      ...pending.where((ProfileMediaItem i) => !publishedIds.contains(i.id)),
      ...published,
    ];
    merged.sort((ProfileMediaItem a, ProfileMediaItem b) {
      final DateTime ad = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime bd = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });
    return merged;
  }

  /// Owner-only deletion of a published item.
  ///
  /// Delegates to [deletePostEverywhere], which is the single implementation
  /// the feed's post detail page uses too — so a proof video deleted from the
  /// feed loses its achievement pointer exactly as one deleted from the grid
  /// does. See media_deletion.dart for the order and why it is that order.
  Future<void> deleteMedia(ProfileMediaItem item) => deletePostEverywhere(
        firestore: _db,
        storage: _storage,
        ownerUid: item.ownerUid,
        postId: item.id,
        storagePath: item.storagePath,
      );

  /// Cancels a still-pending upload and removes its staged files.
  Future<void> cancelPending(String mediaId) async {
    final OutboxItem? row = await _outbox.byId(mediaId);
    if (row == null) return;
    // Either object may or may not have made it up; deleting is idempotent.
    await _deleteObject(row.storagePath);
    final String? thumbPath = thumbnailStoragePathFor(row.storagePath);
    if (thumbPath != null) await _deleteObject(thumbPath);
    await _deleteLocal(row.localFilePath);
    await _deleteLocal(row.localThumbPath);
    await _outbox.remove(mediaId);
  }

  Future<void> retryPending(String mediaId) => _outbox.retry(mediaId);

  Future<void> _deleteObject(String path) async {
    if (path.isEmpty) return;
    try {
      await _storage.ref(path).delete();
    } on FirebaseException catch (e) {
      // 'object-not-found' is the expected outcome of a repeat run.
      if (e.code != 'object-not-found') rethrow;
    }
  }

  Future<void> _deleteLocal(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final File f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // A staged file that is already gone is not a problem.
    }
  }
}
