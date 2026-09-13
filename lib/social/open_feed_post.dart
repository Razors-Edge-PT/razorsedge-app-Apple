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

import 'dart:async';

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
}) =>
    openPostById(
      context,
      item.postId,
      viewerUid: viewerUid,
      firestore: firestore,
    );

/// Opens one post by id — the path a notification tap and an Activity row take.
///
/// [focusCommentId] is the comment to reveal, which the detail page shows even
/// when it is older than the page of comments it loads.
///
/// Access is decided by the rules, not here: a post the viewer may no longer
/// read (the friendship ended) fails the read and is reported as unavailable,
/// exactly as a deleted one is. Returns true when a screen was opened.
///
/// [stillValid] is re-checked immediately before navigating, after the fetch.
/// The fetch is a network round trip, and in that time the person may have
/// logged out or switched accounts — `context.mounted` alone does not notice
/// either, and the post would open for whoever is signed in now. Callers that
/// act on a notification or an Activity row pass their own account check.
Future<bool> openPostById(
  BuildContext context,
  String postId, {
  required String? viewerUid,
  String? focusCommentId,
  FirebaseFirestore? firestore,
  bool Function()? stillValid,
}) async {
  final FirebaseFirestore db = firestore ?? FirebaseFirestore.instance;
  bool valid() => (stillValid == null || stillValid()) && context.mounted;
  if (!valid()) return false;
  DocumentSnapshot<Map<String, dynamic>> snap;
  try {
    snap = await db.collection('posts').doc(postId).get();
  } catch (_) {
    if (valid()) showAppSnack("Couldn't open that post.");
    return false;
  }
  // Re-checked AFTER the fetch, not just for a mounted context.
  if (!valid()) return false;
  if (!snap.exists || snap.data() == null) {
    showAppSnack('That post is no longer available.');
    return false;
  }

  final Post post = Post.fromSnap(snap);
  // Not awaited: `Navigator.push` completes when the route is POPPED, and a
  // caller that waited for that would stall every following notification tap.
  unawaited(Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PostDetailPage(
        post: post,
        focusCommentId: focusCommentId,
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
  ));
  return true;
}
