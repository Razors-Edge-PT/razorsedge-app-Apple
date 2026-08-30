/// Stories: 24-hour media that expires exactly 24 hours after it PUBLISHES.
///
/// ── Where the clock comes from ──────────────────────────────────────────────
/// `publishedAt` is written as a server timestamp and the security rules
/// require it to equal `request.time`, so the 24 hours are measured by the
/// server, not by a device clock that may be wrong or deliberately moved.
///
/// ── Why queries filter on publishedAt, not expiresAt ────────────────────────
/// `expiresAt` is stamped by the storyOnPublished trigger a moment after the
/// document lands. Filtering on it would make a story invisible for that
/// moment. Filtering on `publishedAt > now - 24h` is exact from the instant the
/// document exists, needs no second write, and cannot be fooled — the rules
/// already pinned publishedAt to the server clock.
///
/// ── Offline ─────────────────────────────────────────────────────────────────
/// A story chosen while offline is staged in the media outbox and shown to its
/// OWNER as pending. It has no publishedAt, so [StoryItem.isLiveAt] is false,
/// nobody else can see it, and its 24 hours have not begun. They begin when the
/// upload and this document both succeed.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/media_models.dart';
import 'media_outbox.dart';

/// How far the live-story query's cutoff is moved forward, to stay inside the
/// server-enforced 24 hours whatever this device's clock says.
///
/// 90 seconds absorbs ordinary NTP drift and a modest manual clock error. A
/// device further behind than this loses story listing entirely rather than
/// seeing expired stories — the query is denied and the stream reports empty,
/// which is the right way for a clock disagreement to fail.
const Duration kStoryQuerySkewMargin = Duration(seconds: 90);

class StoryRepository {
  StoryRepository({FirebaseFirestore? firestore, required MediaOutbox outbox})
      : _db = firestore ?? FirebaseFirestore.instance,
        _outbox = outbox;

  final FirebaseFirestore _db;
  final MediaOutbox _outbox;

  CollectionReference<Map<String, dynamic>> _stories(String uid) =>
      _db.collection('users').doc(uid).collection('stories');

  /// Live stories for [ownerUid], oldest first (the order they are viewed in).
  ///
  /// The query excludes expired documents at the source, and [StoryItem.isLiveAt]
  /// filters again on the client so a story cannot linger on screen just
  /// because the snapshot arrived a few seconds before it expired.
  ///
  /// ── Why the cutoff carries a margin ─────────────────────────────────────
  /// The security rule now enforces the same 24 hours, measured on the SERVER
  /// clock. Firestore rules are not filters: if a query's result set contains
  /// one document the reader may not read, the WHOLE query is denied. So a
  /// device whose clock is a little slow would ask for a story the server
  /// considers expired and lose every story on the profile, not just that one.
  ///
  /// Moving the cutoff forward by [kStoryQuerySkewMargin] makes the request
  /// strictly narrower than the rule allows for any device up to that far
  /// behind. The cost is that a story in its final minute is not listed — a
  /// minute the viewer was about to lose anyway.
  Stream<List<StoryItem>> watchLive(String ownerUid,
      {DateTime Function()? clock}) {
    final DateTime Function() now = clock ?? DateTime.now;
    final Timestamp cutoff = Timestamp.fromDate(
      now().subtract(StoryItem.ttl).add(kStoryQuerySkewMargin),
    );
    return _stories(ownerUid)
        .where('publishedAt', isGreaterThan: cutoff)
        .orderBy('publishedAt')
        .snapshots()
        .map((QuerySnapshot<Map<String, dynamic>> q) => q.docs
            .map(StoryItem.fromSnapshot)
            .where((StoryItem s) => s.isLiveAt(now()))
            .toList(growable: false))
        .handleError((Object _) {});
  }

  /// The owner's own stories that have not published yet. Visible only to them.
  Stream<List<StoryItem>> watchPending(String ownerUid) {
    return _outbox.watchPendingFor(ownerUid).map((List<OutboxItem> rows) => rows
        .where((OutboxItem r) => r.kind == OutboxKind.story)
        .map((OutboxItem r) => StoryItem(
              id: r.mediaId,
              ownerUid: r.ownerUid,
              mediaType: r.mediaType,
              storagePath: r.storagePath,
              // No publishedAt: the 24 hours have NOT started.
              publishedAt: null,
              pending: true,
              localFilePath: r.localThumbPath ?? r.localFilePath,
            ))
        .toList(growable: false));
  }

  /// Publishes a story whose media is already in Storage.
  ///
  /// `publishedAt` is a server timestamp — the rules reject anything else — and
  /// `expiresAt` is deliberately NOT sent, because a client-supplied expiry is
  /// exactly what a client should not be trusted with.
  Future<void> publish({
    required String ownerUid,
    required String storyId,
    required String mediaType,
    required String storagePath,
    required String url,
    String thumbUrl = '',
    String thumbPath = '',
  }) {
    return _stories(ownerUid).doc(storyId).set(<String, Object?>{
      'ownerUid': ownerUid,
      'mediaType': mediaType,
      'storagePath': storagePath,
      'thumbPath': thumbPath,
      'url': url,
      'thumbUrl': thumbUrl,
      'publishedAt': FieldValue.serverTimestamp(),
    });
  }

  /// True when the story document already exists — the check that makes a
  /// retry after the "metadata committed, outbox row survived" crash window a
  /// no-op instead of a duplicate.
  Future<bool> exists(String ownerUid, String storyId) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap =
          await _stories(ownerUid).doc(storyId).get();
      return snap.exists;
    } catch (_) {
      return false;
    }
  }

  Future<void> delete(String ownerUid, String storyId) =>
      _stories(ownerUid).doc(storyId).delete();
}
