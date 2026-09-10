/// Opening a feed card, using the post detail page the app already has.
///
/// ── Why the post is fetched on TAP and not with the page ───────────────────
/// A feed row carries what a card must DRAW — the media reference, the caption
/// and the timestamp — and deliberately not the like, GoodLift and comment
/// counts. Those change constantly and independently of the post itself, so
/// copying them into every friend's feed row would mean re-fanning-out a write
/// to every viewer each time somebody tapped a heart.
///
/// So the counts are read once, for the ONE post actually opened. That is a
/// single document read on a deliberate tap, rather than a read per card on
/// every page — and it is what keeps likes, GoodLifts, comments and deletion
/// working exactly as they do everywhere else in the app, because the detail
/// page and its callbacks are the existing ones, unchanged.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../main.dart' show showAppSnack;
import '../post_media.dart';
import '../post_service.dart';
import 'feed_repository.dart';

/// Opens [item] in the existing [PostDetailPage].
///
/// A row whose post has since been deleted, or which the viewer may no longer
/// read because the friendship ended, says so rather than opening an empty
/// page. Both are ordinary outcomes of a feed that is a projection: the row can
/// outlive what it points at by the time between the change and the fan-out.
Future<void> openFeedPost(
  BuildContext context,
  FeedItem item, {
  required String? viewerUid,
  FirebaseFirestore? firestore,
}) async {
  final FirebaseFirestore db = firestore ?? FirebaseFirestore.instance;
  DocumentSnapshot<Map<String, dynamic>> snap;
  try {
    snap = await db.collection('posts').doc(item.postId).get();
  } catch (_) {
    if (context.mounted) showAppSnack("Couldn't open that post.");
    return;
  }
  if (!context.mounted) return;
  if (!snap.exists || snap.data() == null) {
    showAppSnack('That post is no longer available.');
    return;
  }

  final Post post = Post.fromSnap(snap);
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PostDetailPage(
        post: post,
        onToggleLike: (Post p) => PostService.instance.toggleLike(p.id),
        onToggleGoodLift: (Post p) => PostService.instance
            .toggleGoodLift(p.id, isVideo: p.mediaType == 'video'),
        onAddComment: (Post p, String text) => PostService.instance
            .addComment(p.id, text, usernameFallback: 'user'),
        // Only the owner may delete, and the owner is the authenticated
        // account — never a coach's selected athlete.
        canDelete: viewerUid != null && viewerUid == post.ownerUid,
      ),
    ),
  );
}
