import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'profile_page.dart';
import 'post_service.dart';
import 'post_header.dart';
import 're_daily.dart'; // for ReDailyPostCard
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'profile/core/media_urls.dart';

class FeedPostCard extends StatelessWidget {
  final Post post;
  final VoidCallback onOpenDetail;
  final bool isHomeContext; // true when rendering in the Home tab

  const FeedPostCard({
    super.key,
    required this.post,
    required this.onOpenDetail,
    this.isHomeContext = false,
  });

  @override
  Widget build(BuildContext context) {
    final isReDaily = (post.type == 're_daily');

    return SizedBox(
      width: double.infinity, // 👈 stretch card to full available width
      child: Card(
        color: Theme.of(context).colorScheme.secondary, // 👈 your background
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

              // Media / Content (tap to open detail)
              if (!isReDaily)
                _FeedMediaSection(
                    key: ValueKey(post.id), post: post, onTap: onOpenDetail)
              else
                // Render the RE Daily card in place of media
                GestureDetector(
                  onTap: onOpenDetail,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child:
                        StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('posts')
                          .doc(post.id)
                          .snapshots(),
                      builder: (context, snap) {
                        if (snap.connectionState != ConnectionState.active &&
                            !snap.hasData) {
                          return const SizedBox(
                            height: 200,
                            child: Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          );
                        }
                        final d =
                            snap.data?.data() ?? const <String, dynamic>{};
                        final String dayKey = (d['dayKey'] ?? '') as String;
                        final double dailyTotal =
                            (d['dailyTotal'] as num?)?.toDouble() ?? 0.0;
                        final double? bodyweightUsedKg =
                            (d['bodyweightUsedKg'] as num?)?.toDouble();
                        final Map<String, dynamic> perLift =
                            (d['perLift'] as Map<String, dynamic>?) ??
                                const <String, dynamic>{};
                        final List<String> badges = ((d['badges'] as List?)
                                ?.map((e) => e.toString())
                                .toList()) ??
                            const <String>[];
                        final String? caption = (d['caption'] as String?);

                        final bool hasBadge = badges.isNotEmpty;
                        final bool promoted =
                            (d['promoteToHome'] as bool?) == true;

// In the Home tab, only render RE cards that are promoted AND have ≥1 badge.
// In the Points tab (isHomeContext == false), render all valid RE cards.
                        if (isHomeContext && (!promoted || !hasBadge)) {
                          return const SizedBox.shrink();
                        }

// Use the existing pretty card
                        return ReDailyPostCard(
                          dayKey: dayKey,
                          dailyTotal: dailyTotal,
                          perLift: perLift,
                          bodyweightKg: bodyweightUsedKg,
                          badges: badges,
                          caption: caption,
                        );
                      },
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

    final postDocStream =
        FirebaseFirestore.instance.collection('posts').doc(post.id).snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: postDocStream,
      builder: (context, snap) {
        int likeCount = post.likeCount;
        int goodLiftCount = post.goodLiftCount;
        int commentCount = post.commentCount;

        if (snap.hasData && snap.data!.data() != null) {
          final d = snap.data!.data()!;
          likeCount = (d['likeCount'] as num?)?.toInt() ?? likeCount;
          goodLiftCount =
              (d['goodLiftCount'] as num?)?.toInt() ?? goodLiftCount;
          commentCount = (d['commentCount'] as num?)?.toInt() ?? commentCount;
        }

        return Row(
          children: [
            IconButton(
              tooltip: 'Like',
              onPressed: () => svc.toggleLike(post.id).catchError((e) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Like failed: $e')));
              }),
              icon: const Icon(Icons.thumb_up_alt_outlined),
            ),
            Text('$likeCount'),
            const SizedBox(width: 16),
            if (isVideo) ...[
              IconButton(
                tooltip: 'Good lift',
                onPressed: () =>
                    svc.toggleGoodLift(post.id, isVideo: true).catchError((e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Good lift failed: $e')));
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
        .collection('posts')
        .doc(postId)
        .collection('comments')
        .orderBy('createdAt', descending: true)
        .limit(2);

    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: q.get(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
              height: 20,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
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
        for (final d in docs.reversed) {
          // oldest of the two first
          final m = d.data();
          final user = (m['username'] ?? m['uid'] ?? '').toString();
          final text = (m['text'] ?? '').toString();
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                      text: '$user: ',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, color: Colors.white)),
                  TextSpan(
                      text: text, style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ));
        }

        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                onPressed: onViewAll, child: const Text('View all comments')),
          ),
        );

        return Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children);
      },
    );
  }
}

// ─── Feed media section ──────────────────────────────────────────────────────

const double _kAutoplayThreshold = 0.6;

class _FeedMediaSection extends StatefulWidget {
  final Post post;
  final VoidCallback onTap;
  const _FeedMediaSection({super.key, required this.post, required this.onTap});

  @override
  State<_FeedMediaSection> createState() => _FeedMediaSectionState();
}

class _FeedMediaSectionState extends State<_FeedMediaSection> {
  Future<File>? _imageFuture;
  Future<File>? _thumbFuture;
  VideoPlayerController? _ctrl;
  bool _videoReady = false;
  bool _shouldPlay = false;
  bool _isInitializing = false;

  @override
  void initState() {
    super.initState();
    if (widget.post.mediaType == 'video') {
      // Only a real IMAGE goes to the image decoder. Posts written before
      // 1.7.13 stored the video's own download URL in `thumbUrl`, and asking
      // the cache manager to decode an .mp4 as a poster frame is what made
      // every video card in this feed render as an empty box.
      final String? t = safeThumbnailUrl(widget.post.thumbUrl);
      if (t != null) _thumbFuture = DefaultCacheManager().getSingleFile(t);
      // _initVideo() NOT called here — lazy on visibility
    } else {
      _imageFuture = DefaultCacheManager().getSingleFile(widget.post.smallUrl);
    }
  }

  void _initVideo() {
    if (_ctrl != null || _isInitializing) return;
    final videoUrl = widget.post.smallUrl;
    if (videoUrl.isEmpty) return;
    _isInitializing = true;
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
    _ctrl!.initialize().then((_) {
      if (!mounted) return;
      _ctrl!.setLooping(true);
      _ctrl!.setVolume(0);
      setState(() => _videoReady = true);
      if (_shouldPlay) _ctrl!.play();
    }).catchError((_) {
      _isInitializing = false;
    });
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final wantsPlay = info.visibleFraction >= _kAutoplayThreshold;
    if (wantsPlay == _shouldPlay) return;
    setState(() => _shouldPlay = wantsPlay);
    if (wantsPlay) {
      if (_ctrl == null && !_isInitializing) _initVideo();
      if (_videoReady) _ctrl?.play();
    } else {
      if (_videoReady) _ctrl?.pause();
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 4 / 5,
          child:
              widget.post.mediaType == 'video' ? _buildVideo() : _buildImage(),
        ),
      ),
    );
  }

  Widget _buildImage() {
    return FutureBuilder<File>(
      future: _imageFuture,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.done && snap.hasData) {
          return Image.file(snap.data!,
              fit: BoxFit.cover, width: double.infinity);
        }
        return const ColoredBox(color: Color(0x11000000));
      },
    );
  }

  Widget _buildVideo() {
    return VisibilityDetector(
      key: Key('feed-vid-${widget.post.id}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildThumb(),
          if (_videoReady && _ctrl != null)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _ctrl!.value.size.width,
                  height: _ctrl!.value.size.height,
                  child: VideoPlayer(_ctrl!),
                ),
              ),
            ),
          const Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.play_circle_outline,
                  color: Colors.white70, size: 28),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumb() {
    final localPath = widget.post.localThumbPath;
    if (localPath != null && localPath.isNotEmpty) {
      final f = File(localPath);
      if (f.existsSync()) {
        return Image.file(f, fit: BoxFit.cover, width: double.infinity);
      }
    }
    if (_thumbFuture != null) {
      return FutureBuilder<File>(
        future: _thumbFuture,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.done && snap.hasData) {
            return Image.file(snap.data!,
                fit: BoxFit.cover, width: double.infinity);
          }
          return const ColoredBox(color: Color(0x11000000));
        },
      );
    }
    return const ColoredBox(color: Color(0x11000000));
  }
}

// ─── RE Daily detail page ─────────────────────────────────────────────────────

class ReDailyDetailPage extends StatelessWidget {
  final String postId;
  const ReDailyDetailPage({super.key, required this.postId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Daily RE Points'),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('posts')
            .doc(postId)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.active && !snap.hasData) {
            return const Center(
                child: CircularProgressIndicator(strokeWidth: 2));
          }
          final d = snap.data?.data() ?? const <String, dynamic>{};
          final String dayKey = (d['dayKey'] ?? '') as String;
          final double dailyTotal =
              (d['dailyTotal'] as num?)?.toDouble() ?? 0.0;
          final double? bodyweightUsedKg =
              (d['bodyweightUsedKg'] as num?)?.toDouble();
          final Map<String, dynamic> perLift =
              (d['perLift'] as Map<String, dynamic>?) ??
                  const <String, dynamic>{};
          final List<String> badges =
              ((d['badges'] as List?)?.map((e) => e.toString()).toList()) ??
                  const <String>[];
          final String? caption = (d['caption'] as String?);
          final bool alreadyPromoted = (d['promoteToHome'] as bool?) == true;
          final bool hasBadge = badges.isNotEmpty;
          final bool canPromote = hasBadge && !alreadyPromoted;

          final dummyPost = Post(
            id: postId,
            ownerUid: (d['ownerUid'] ?? '') as String,
            mediaType:
                (d['mediaType'] ?? 'image') as String, // ignored for daily
            storagePathOriginal: (d['storagePathOriginal'] ?? '') as String,
            smallUrl: (d['smallUrl'] ?? '') as String,
            thumbUrl: (d['thumbUrl'] ?? '') as String,
            caption: caption,
            likeCount: (d['likeCount'] as num?)?.toInt() ?? 0,
            goodLiftCount: (d['goodLiftCount'] as num?)?.toInt() ?? 0,
            commentCount: (d['commentCount'] as num?)?.toInt() ?? 0,
            createdAt: (d['createdAt'] as Timestamp?) ?? Timestamp.now(),
            type: d['type'] as String?,
          );

          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  children: [
                    ReDailyPostCard(
                      dayKey: dayKey,
                      dailyTotal: dailyTotal,
                      perLift: perLift,
                      bodyweightKg: bodyweightUsedKg,
                      badges: badges,
                      caption: caption,
                    ),
                    const SizedBox(height: 12),
                    if (canPromote)
                      Card(
                        color: Colors.blueGrey.shade700,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              const Icon(Icons.campaign, color: Colors.white),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                    'Nice! You earned a badge today. Share this to your Home feed?',
                                    style: TextStyle(color: Colors.white)),
                              ),
                              TextButton(
                                onPressed: () async {
                                  try {
                                    await FirebaseFirestore.instance
                                        .collection('posts')
                                        .doc(postId)
                                        .update({
                                      'promoteToHome': true,
                                      'promotedAt':
                                          FieldValue.serverTimestamp(),
                                    });
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                            content:
                                                Text('Shared to Home feed')),
                                      );
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                            content: Text('Share failed: $e')),
                                      );
                                    }
                                  }
                                },
                                child: const Text('Share'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    _ActionRow(post: dummyPost),
                    const SizedBox(height: 12),
                    _LastTwoComments(postId: postId, onViewAll: () {}),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white70),
              // Optional: future action bar area
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: const [
                      // Placeholder for future actions or share
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
