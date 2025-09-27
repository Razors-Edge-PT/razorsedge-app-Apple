import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'profile_page.dart';
import 'post_service.dart';
import 'post_header.dart';

class FeedPostCard extends StatelessWidget {
  final Post post;
  final VoidCallback onOpenDetail;

  const FeedPostCard({super.key, required this.post, required this.onOpenDetail});

  @override
  Widget build(BuildContext context) {
    final isVideo = post.mediaType == 'video';
    final mediaUrl = isVideo ? post.thumbUrl : post.smallUrl;

    return SizedBox(
      width: double.infinity, // 👈 stretch card to full available width
      child: Card(
        color: Colors.blueGrey.shade600, // 👈 your background
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              PostHeader(
                ownerUid: post.ownerUid,
                createdAt: post.createdAt.toDate(),
              ),
              const SizedBox(height: 8),

              // Media (tap to open detail)
              GestureDetector(
                onTap: onOpenDetail,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: 4 / 5, // 👈 taller image (was 1:1)
                    child: FutureBuilder<File>(
                      future: DefaultCacheManager().getSingleFile(mediaUrl),
                      builder: (ctx, snap) {
                        if (snap.connectionState == ConnectionState.done && snap.hasData) {
                          return Image.file(
                            snap.data!,
                            fit: BoxFit.cover,
                            width: double.infinity, // 👈 fill horizontally
                          );
                        }
                        return const ColoredBox(color: Color(0x11000000));
                      },
                    ),
                  ),
                ),
              ),

              // Actions row (snapshot counts)
              const SizedBox(height: 8),
              _ActionRow(post: post),

              // Caption (optional)
              if ((post.caption ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(post.caption!.trim()),
              ],

              // Last 2 comments + View all
              const SizedBox(height: 8),
              _LastTwoComments(postId: post.id, onViewAll: onOpenDetail),
            ],
          ),
        ),
      ),
    );

  }
}

class _ActionRow extends StatelessWidget {
  final Post post;
  const _ActionRow({required this.post});

  @override
  Widget build(BuildContext context) {
    final svc = PostService.instance;
    final isVideo = post.mediaType == 'video';

    final postDocStream = FirebaseFirestore.instance.collection('posts').doc(post.id).snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: postDocStream,
      builder: (context, snap) {
        int likeCount = post.likeCount;
        int goodLiftCount = post.goodLiftCount;
        int commentCount = post.commentCount;

        if (snap.hasData && snap.data!.data() != null) {
          final d = snap.data!.data()!;
          likeCount = (d['likeCount'] as num?)?.toInt() ?? likeCount;
          goodLiftCount = (d['goodLiftCount'] as num?)?.toInt() ?? goodLiftCount;
          commentCount = (d['commentCount'] as num?)?.toInt() ?? commentCount;
        }

        return Row(
          children: [
            IconButton(
              tooltip: 'Like',
              onPressed: () => svc.toggleLike(post.id).catchError((e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Like failed: $e')));
              }),
              icon: const Icon(Icons.thumb_up_alt_outlined),
            ),
            Text('$likeCount'),

            const SizedBox(width: 16),

            if (isVideo) ...[
              IconButton(
                tooltip: 'Good lift',
                onPressed: () => svc.toggleGoodLift(post.id, isVideo: true).catchError((e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Good lift failed: $e')));
                }),
                icon: const Icon(Icons.check_circle_outline),
              ),
              Text('$goodLiftCount'),
              const SizedBox(width: 16),
            ],

            const Icon(Icons.mode_comment_outlined),
            const SizedBox(width: 4),
            Text('$commentCount'),
            const Spacer(),
          ],
        );
      },
    );
  }
}

class _LastTwoComments extends StatelessWidget {
  final String postId;
  final VoidCallback onViewAll;
  const _LastTwoComments({required this.postId, required this.onViewAll});

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance
        .collection('posts').doc(postId)
        .collection('comments')
        .orderBy('createdAt', descending: true)
        .limit(2);

    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: q.get(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(height: 20, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) {
          return Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onViewAll,
              child: const Text('View all comments'),
            ),
          );
        }

        final children = <Widget>[];
        for (final d in docs.reversed) { // oldest of the two first
          final m = d.data();
          final user = (m['username'] ?? m['uid'] ?? '').toString();
          final text = (m['text'] ?? '').toString();
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(text: '$user: ', style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                  TextSpan(text: text, style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ));
        }

        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: onViewAll, child: const Text('View all comments')),
          ),
        );

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
      },
    );
  }
}
