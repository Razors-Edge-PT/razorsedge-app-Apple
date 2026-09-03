// Shared post, comment and video-player components.
//
// MOVED VERBATIM out of the old 4,000-line profile_page.dart during the
// profile rebuild. They were never profile-specific: feed_post_card.dart
// already imported the `Post` model and `PostDetailPage` from there, so the
// profile page was acting as an accidental home for the app's post surfaces.
//
// Nothing here changed behaviour in the move — the same Firestore paths, the
// same like / GoodLift / comment logic, the same player. The new profile
// screen reuses these rather than carrying its own copies, which is why the
// rebuilt page has no post, comment or playback code of its own.

// Dart SDK
import 'dart:async'; // for unawaited, Futures

// Flutter
import 'package:flutter/material.dart';

// Firebase
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

// Media / cache
import 'package:video_player/video_player.dart';

// Project-local
import 'profile/core/media_identity.dart';
import 'profile/core/media_timeouts.dart';
import 'profile/core/media_models.dart';
import 'profile/data/media_cache_sweeper.dart';
import 'profile/data/media_deletion.dart';
import 'profile/data/media_video_source.dart';
import 'profile/ui/cached_network_image.dart';
import 'profile/ui/live_identity.dart';
import 'profile/ui/media_detail_page.dart';

// Local storage / utils

// Project-local

enum VideoStorageMode { local, firestore }

class LiftVideo {
  final String liftId; // stable key e.g., 'bench_barbell'
  final String? localPath; // file path on device
  final String? remoteUrl; // Firestore mode (future)
  final String? thumbUrl; // ✅ thumbnail image URL from Storage
  final DateTime updatedAt;

  LiftVideo({
    required this.liftId,
    this.localPath,
    this.remoteUrl,
    this.thumbUrl, // ✅ new optional field
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  bool get hasLocal => (localPath != null && localPath!.isNotEmpty);
  bool get hasRemote => (remoteUrl != null && remoteUrl!.isNotEmpty);
  bool get hasThumb =>
      (thumbUrl != null && thumbUrl!.isNotEmpty); // ✅ convenience

  Map<String, dynamic> toJson() => {
        'liftId': liftId,
        'localPath': localPath,
        'remoteUrl': remoteUrl,
        'thumbUrl': thumbUrl, // ✅ include in JSON
        'updatedAt': updatedAt.toIso8601String(),
      };

  static LiftVideo fromJson(Map<String, dynamic> j) => LiftVideo(
        liftId: j['liftId'] as String,
        localPath: j['localPath'] as String?,
        remoteUrl: j['remoteUrl'] as String?,
        thumbUrl: j['thumbUrl'] as String?, // ✅ parse from JSON
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? '') ?? DateTime.now(),
      );
}

class PostDetailPage extends StatelessWidget {
  final Post post;
  final Future<void> Function(Post) onToggleLike;
  final Future<void> Function(Post) onToggleGoodLift;
  final Future<void> Function(Post, String) onAddComment;
  final bool canDelete;

  const PostDetailPage({
    super.key,
    required this.post,
    required this.onToggleLike,
    required this.onToggleGoodLift,
    required this.onAddComment,
    required this.canDelete,
  });

  @override
  Widget build(BuildContext context) {
    // For brevity: simple viewer + action row with counts.
    return Scaffold(
      backgroundColor: Colors.black, // 👈 add this line
      appBar: AppBar(
          backgroundColor: Colors.black, // 👈 optional, to blend header
          title: const Text('Post'),
          actions: [
            if (canDelete)
              IconButton(
                tooltip: 'Edit caption',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final docRef = FirebaseFirestore.instance
                      .collection('posts')
                      .doc(post.id);

                  // Prefill with current caption (best-effort fetch to get latest)
                  String current = post.caption ?? '';
                  try {
                    final snap = await docRef.get();
                    final d = snap.data();
                    if (d != null && d['caption'] is String) {
                      current = (d['caption'] as String).trim();
                    }
                  } catch (_) {}

                  final ctrl = TextEditingController(text: current);
                  final updated = await showDialog<String>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Edit caption'),
                      content: TextField(
                        controller: ctrl,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        maxLines: null,
                        decoration:
                            const InputDecoration(border: OutlineInputBorder()),
                      ),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(d),
                            child: const Text('Cancel')),
                        TextButton(
                            onPressed: () => Navigator.pop(d, ctrl.text.trim()),
                            child: const Text('Save')),
                      ],
                    ),
                  );
                  if (updated == null) return;

                  try {
                    await docRef.update({'caption': updated});

                    // No local patch-up needed. The old profile page kept its
                    // own in-memory post list and this reached up into its
                    // private State to keep the two in step. The rebuilt grid
                    // is a Firestore stream, so the edit arrives on its own.
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Caption update failed: $e')),
                      );
                    }
                  }
                },
              ),
            if (canDelete)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  // ... your existing delete code unchanged ...
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Delete post?'),
                      content: const Text(
                          'This will permanently remove the post and its media.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const Text('Cancel')),
                        TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text('Delete',
                              style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true) return;

                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Deleting post…')),
                    );
                  }

                  try {
                    // ONE deletion path, shared with the profile grid.
                    // Deleting here used to remove the post and its Storage
                    // objects and nothing else, which left every
                    // users/{uid}/proofs pointer that named this post behind —
                    // still claiming a Big Five record was proved by media
                    // that no longer existed.
                    await deletePostEverywhere(
                      firestore: FirebaseFirestore.instance,
                      storage: FirebaseStorage.instance,
                      ownerUid: post.ownerUid,
                      postId: post.id,
                      storagePath: post.storagePathOriginal,
                    );

                    if (context.mounted) {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Post deleted')),
                      );
                      Navigator.pop(context);
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Delete failed: $e')),
                      );
                    }
                  }
                },
              ),
          ]),
      body: Column(
        children: [
          Expanded(child: _PostMediaView(post: post)),

// --- Caption row (optional) ---
          if ((post.caption ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  post.caption ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),

// --- Simple comments list (last 20) ---
          SizedBox(
            height: 160,
            child: _CommentsList(postId: post.id),
          ),
        ],
      ),

      bottomNavigationBar: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1, color: Colors.white70),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: _PostActionsBar(
                post: post,
                onToggleLike: onToggleLike,
                onToggleGoodLift: onToggleGoodLift,
                onAddComment: onAddComment,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The media half of [PostDetailPage].
///
/// Replaces two FutureBuilders that between them produced the two worst
/// failures this screen had:
///
///   * the IMAGE branch drew a spinner for every state that was not
///     `done && hasData`. An error, a missing Storage object, an empty
///     `smallUrl`, a 404 or an offline cache miss all landed in that same
///     branch, so the page spun for as long as it stayed open and there was
///     nothing to tap.
///   * the VIDEO branch called `getDownloadURL()` on every open. The post
///     document already carries the playable URL, so that round trip bought
///     nothing — and it failed outright offline, which is exactly when a clip
///     already cached on the device should still play.
///
/// Every state now resolves: media, a bounded wait, or a stated failure with a
/// retry that starts a genuinely fresh attempt.
class _PostMediaView extends StatefulWidget {
  const _PostMediaView({required this.post});

  final Post post;

  @override
  State<_PostMediaView> createState() => _PostMediaViewState();
}

class _PostMediaViewState extends State<_PostMediaView> {
  static const TextStyle _text = TextStyle(color: Colors.white70);

  VideoSourceResolver? _ownResolver;
  VideoSourceResolver get _resolver =>
      _ownResolver ??= VideoSourceResolver();

  Post get _post => widget.post;

  String _cacheKey(String variant, String url) => profileMediaCacheKey(
        ownerUid: _post.ownerUid,
        variant: variant,
        storagePath: _post.storagePathOriginal,
        mediaId: _post.id,
        url: url,
      );

  // ── Video ──────────────────────────────────────────────────────────────────

  VideoPlayerController? _video;
  bool _ready = false;
  MediaLoadFailure? _failure;
  int _attempt = 0;

  /// The cached file this player is reading, pinned so a disk sweep cannot
  /// delete it mid-playback. Released in dispose, and on every fresh attempt.
  String? _pinnedPath;

  void _pin(String? path) {
    if (_pinnedPath == path) return;
    if (_pinnedPath != null) MediaCachePins.unpin(_pinnedPath!);
    _pinnedPath = path;
    if (path != null) MediaCachePins.pin(path);
  }

  @override
  void initState() {
    super.initState();
    if (_post.mediaType == MediaType.video) unawaited(_openVideo());
  }

  @override
  void dispose() {
    _attempt++; // Nothing in flight may touch state after this point.
    _pin(null);
    _video?.dispose();
    super.dispose();
  }

  bool _current(int attempt) => mounted && attempt == _attempt;

  Future<void> _openVideo() async {
    final int attempt = ++_attempt;
    final VideoPlayerController? previous = _video;
    _video = null;
    _pin(null);
    unawaited(previous?.dispose().catchError((Object _) {}));
    if (mounted) {
      setState(() {
        _ready = false;
        _failure = null;
      });
    }

    // The stored URL first. Storage is asked for one only when the document
    // has none, which is the only case where the round trip buys anything.
    String source = _post.smallUrl.trim();
    if (source.isEmpty && _post.storagePathOriginal.isNotEmpty) {
      try {
        source = (await FirebaseStorage.instance
                .ref(_post.storagePathOriginal)
                .getDownloadURL())
            .trim();
      } catch (e) {
        if (!_current(attempt)) return;
        setState(() => _failure = isConnectivityFailure(e)
            ? MediaLoadFailure.offline
            : MediaLoadFailure.unavailable);
        return;
      }
    }
    if (!_current(attempt)) return;

    final String key = _cacheKey(MediaVariant.original, source);
    final VideoSource resolved =
        await _resolver.resolve(url: source, cacheKey: key);
    if (!_current(attempt)) return;

    if (!resolved.isPlayable) {
      setState(
          () => _failure = resolved.failure ?? MediaLoadFailure.unavailable);
      return;
    }

    // Pinned BEFORE the controller is built: from here until dispose, the
    // sweeper must not delete the bytes underneath it.
    _pin(resolved.file?.path);

    if (!await _start(resolved, attempt, key)) return;

    final String? fill = _playingUrl;
    if (fill != null) {
      unawaited(_resolver.fill(url: fill, cacheKey: key));
    }
  }

  /// The remote URL actually playing, or null when playing from a file.
  String? _playingUrl;

  /// Builds a controller and initialises it, recovering ONCE from a URL whose
  /// access token has been revoked. See MediaDetailPage._start for why the
  /// failure is not classified: a single fresh URL that genuinely differs is
  /// the bounded, loop-free way to handle it.
  Future<bool> _start(VideoSource source, int attempt, String key,
      {bool allowRefresh = true}) async {
    _pin(source.file?.path);
    _playingUrl = source.file == null ? source.url : null;

    final VideoPlayerController c = source.file != null
        ? VideoPlayerController.file(source.file!)
        : VideoPlayerController.networkUrl(Uri.parse(source.url!));
    _video = c;
    try {
      await c.initialize().timeout(kVideoInitTimeout);
      await c.setLooping(true);
      await c.play();
      if (!_current(attempt)) return false;
      setState(() => _ready = true);
      return true;
    } on TimeoutException {
      if (!_current(attempt)) return false;
      setState(() => _failure = MediaLoadFailure.timedOut);
      return false;
    } catch (e) {
      if (!_current(attempt)) return false;

      final String? failedUrl = source.url;
      if (allowRefresh &&
          failedUrl != null &&
          _post.storagePathOriginal.isNotEmpty) {
        final String? fresh = await _resolver.refreshedSource(
          storagePath: _post.storagePathOriginal,
          failedUrl: failedUrl,
        );
        if (!_current(attempt)) return false;
        if (fresh != null) {
          unawaited(c.dispose().catchError((Object _) {}));
          return _start(VideoSource.network(fresh), attempt, key,
              allowRefresh: false);
        }
      }

      setState(() => _failure = isConnectivityFailure(e)
          ? MediaLoadFailure.offline
          : MediaLoadFailure.unavailable);
      return false;
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Not defaulted to image. A post whose `mediaType` is missing or unknown
    // is a record this build cannot render, and pushing it into the image
    // decoder is how a video became a broken still.
    if (!isSupportedMediaType(_post.mediaType)) {
      return const Center(
        child: MediaFailureView(
          failure: MediaLoadFailure.unusableSource,
          isVideo: false,
          textStyle: _text,
        ),
      );
    }
    return Center(
      child: _post.mediaType == MediaType.video ? _videoBody() : _imageBody(),
    );
  }

  Widget _imageBody() {
    final String url = _post.smallUrl.trim().isNotEmpty
        ? _post.smallUrl.trim()
        : _post.thumbUrl.trim();
    if (url.isEmpty) {
      return const MediaFailureView(
        failure: MediaLoadFailure.unusableSource,
        isVideo: false,
        textStyle: _text,
      );
    }
    return CachedProfileImage(
      url: url,
      cacheKey: _cacheKey(MediaVariant.small, url),
      // Lets a revoked access token be recovered from once, without changing
      // the cache entry the bytes belong to.
      storagePath: _post.storagePathOriginal,
      fit: BoxFit.contain,
      placeholder: const CircularProgressIndicator(),
      errorBuilder: (
        BuildContext context,
        MediaLoadFailure failure,
        VoidCallback retry,
      ) =>
          MediaFailureView(
        failure: failure,
        isVideo: false,
        onRetry: retry,
        textStyle: _text,
      ),
    );
  }

  Widget _videoBody() {
    final MediaLoadFailure? failure = _failure;
    if (failure != null) {
      return MediaFailureView(
        failure: failure,
        isVideo: true,
        textStyle: _text,
        onRetry:
            failure == MediaLoadFailure.unusableSource ? null : _openVideo,
      );
    }
    final VideoPlayerController? c = _video;
    if (c == null || !_ready) {
      return const CircularProgressIndicator();
    }
    return Container(
      color: Colors.black,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          AspectRatio(
            aspectRatio:
                c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
            child: VideoPlayer(c),
          ),
          GestureDetector(
            onTap: () =>
                setState(() => c.value.isPlaying ? c.pause() : c.play()),
            child: Container(color: Colors.transparent),
          ),
          if (!c.value.isPlaying)
            const Icon(Icons.play_circle_fill_rounded,
                size: 64, color: Colors.white70),
        ],
      ),
    );
  }
}

class _PostActionsBar extends StatefulWidget {
  final Post post;
  final Future<void> Function(Post) onToggleLike;
  final Future<void> Function(Post) onToggleGoodLift;
  final Future<void> Function(Post, String) onAddComment;

  const _PostActionsBar({
    required this.post,
    required this.onToggleLike,
    required this.onToggleGoodLift,
    required this.onAddComment,
  });

  @override
  State<_PostActionsBar> createState() => _PostActionsBarState();
}

class _PostActionsBarState extends State<_PostActionsBar> {
  bool _liking = false;
  bool _glifting = false;
  bool _commenting = false;

  Future<void> _promptAndComment() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add comment'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline, // ← Enter = newline
          maxLines: null, // ← grow as you type
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'Write a comment…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(d, ctrl.text),
              child: const Text('Post')),
        ],
      ),
    );

    if (text == null || text.trim().isEmpty) return;
    setState(() => _commenting = true);
    try {
      await widget.onAddComment(widget.post, text.trim());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Comment failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _commenting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Live counts from the post doc
    final postStream = FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.post.id)
        .snapshots();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: postStream,
      builder: (context, snap) {
        int likeCount = widget.post.likeCount;
        int goodLiftCount = widget.post.goodLiftCount;
        int commentCount = widget.post.commentCount;

        if (snap.hasData && snap.data!.data() != null) {
          final d = snap.data!.data()!;
          likeCount = (d['likeCount'] as num?)?.toInt() ?? likeCount;
          goodLiftCount =
              (d['goodLiftCount'] as num?)?.toInt() ?? goodLiftCount;
          commentCount = (d['commentCount'] as num?)?.toInt() ?? commentCount;
        }

        return Row(
          children: [
            // Like
            IconButton(
              tooltip: 'Like',
              onPressed: _liking
                  ? null
                  : () async {
                      setState(() => _liking = true);
                      try {
                        await widget.onToggleLike(widget.post);
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Like failed: $e')),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => _liking = false);
                      }
                    },
              icon: const Icon(Icons.thumb_up_alt_outlined),
            ),
            Text('$likeCount'),

            const SizedBox(width: 16),

            // Good Lift (videos only)
            if (widget.post.mediaType == 'video') ...[
              IconButton(
                tooltip: 'Good lift',
                onPressed: _glifting
                    ? null
                    : () async {
                        setState(() => _glifting = true);
                        try {
                          await widget.onToggleGoodLift(widget.post);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Good lift failed: $e')),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _glifting = false);
                        }
                      },
                icon: const Icon(Icons.check_circle_outline),
              ),
              Text('$goodLiftCount'),
              const SizedBox(width: 16),
            ],

            // Comments
            IconButton(
              tooltip: 'Comment',
              onPressed: _commenting ? null : _promptAndComment,
              icon: const Icon(Icons.mode_comment_outlined),
            ),
            Text('$commentCount'),

            const Spacer(),
          ],
        );
      },
    );
  }
}

class _CommentsList extends StatefulWidget {
  final String postId;
  const _CommentsList({required this.postId});

  @override
  State<_CommentsList> createState() => _CommentsListState();
}

class _CommentsListState extends State<_CommentsList> {
  // Track which comments are expanded
  final Set<String> _expanded = <String>{};
  final ScrollController _ctrl = ScrollController();

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('posts')
        .doc(widget.postId)
        .collection('comments')
        .orderBy('createdAt', descending: true)
        .limit(20)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) {
          return const Center(child: Text('No comments yet'));
        }

        return ListView.separated(
          key: PageStorageKey('comments-${widget.postId}'),
          controller: _ctrl,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (_, i) {
            final doc = docs[i];
            final d = doc.data();
            final cid = doc.id;
            final text = (d['text'] ?? '') as String;
            final uid = (d['uid'] ?? '') as String;
            // The name this comment was written under. AUDIT DATA: it records
            // what the author was called then, not who they are now. It is a
            // fallback for the first frame and for a cold offline cache, and
            // never a preference over the live value — preferring it is what
            // used to leave a renamed athlete's old name on every comment they
            // had ever written, permanently.
            final storedName = (d['username'] as String?)?.trim();

            Widget nameAndText(String displayName) {
              final isExpanded = _expanded.contains(cid);
              return InkWell(
                onTap: () {
                  final prev = _ctrl.hasClients ? _ctrl.offset : 0.0;
                  setState(() {
                    if (isExpanded) {
                      _expanded.remove(cid);
                    } else {
                      _expanded.add(cid);
                    }
                  });
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _ctrl.hasClients) {
                      _ctrl.jumpTo(prev); // keep the same scroll position
                    }
                  });
                },
                child: Text(
                  '$displayName: $text',
                  maxLines: isExpanded ? null : 3,
                  overflow:
                      isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                ),
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.person_outline, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: LiveUserName(
                    uid: uid,
                    fallback: storedName,
                    builder: (_, String display) => nameAndText(display),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ===== Profile Posts (grid) =====
class Post {
  final String id;
  final String ownerUid;
  final String mediaType; // "image" | "video"
  final String? type; // e.g. "re_daily" for Daily RE posts
  final String storagePathOriginal; // path in Storage
  final String smallUrl;
  final String thumbUrl;
  final String? caption;
  final int likeCount;
  final int goodLiftCount;
  final int commentCount;
  final Timestamp createdAt;
  final String? localThumbPath; // for instant preview before upload completes
  final bool promoteToHome; // RE daily: shared to Home feed
  final List<String> badges; // RE daily: earned badges list
  final double dailyTotal; // RE daily: total RE points scored

  Post({
    required this.id,
    required this.ownerUid,
    required this.mediaType,
    this.type,
    required this.storagePathOriginal,
    required this.smallUrl,
    required this.thumbUrl,
    required this.caption,
    required this.likeCount,
    required this.goodLiftCount,
    required this.commentCount,
    required this.createdAt,
    this.localThumbPath,
    this.promoteToHome = false,
    this.badges = const [],
    this.dailyTotal = 0.0,
  });

  static Post fromSnap(DocumentSnapshot<Map<String, dynamic>> s) {
    final d = s.data()!;
    return Post(
      id: s.id,
      ownerUid: (d['ownerUid'] ?? '') as String,
      mediaType: (d['mediaType'] ?? 'image') as String,
      type: d['type'] as String?,
      storagePathOriginal: (d['storagePathOriginal'] ?? '') as String,
      smallUrl: (d['smallUrl'] ?? '') as String,
      thumbUrl: (d['thumbUrl'] ?? '') as String,
      caption: (d['caption'] as String?),
      likeCount: (d['likeCount'] as num?)?.toInt() ?? 0,
      goodLiftCount: (d['goodLiftCount'] as num?)?.toInt() ?? 0,
      commentCount: (d['commentCount'] as num?)?.toInt() ?? 0,
      createdAt: (d['createdAt'] as Timestamp?) ?? Timestamp.now(),
      promoteToHome: (d['promoteToHome'] as bool?) == true,
      badges: ((d['badges'] as List?)?.map((e) => e.toString()).toList()) ??
          const [],
      dailyTotal: (d['dailyTotal'] as num?)?.toDouble() ?? 0.0,
    );
  }

  // Add at the bottom of class Post
  Post copyWith({
    String? id,
    String? ownerUid,
    String? mediaType,
    String? type,
    String? thumbUrl,
    String? smallUrl,
    String? storagePathOriginal,
    String? caption,
    int? likeCount,
    int? goodLiftCount,
    int? commentCount,
    Timestamp? createdAt, // import cloud_firestore for Timestamp
    String? localThumbPath, // set a new local preview path
    bool clearLocalThumbPath = false, // set true to clear local preview
  }) {
    return Post(
      id: id ?? this.id,
      ownerUid: ownerUid ?? this.ownerUid,
      mediaType: mediaType ?? this.mediaType,
      type: type ?? this.type,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      smallUrl: smallUrl ?? this.smallUrl,
      storagePathOriginal: storagePathOriginal ?? this.storagePathOriginal,
      caption: caption ?? this.caption,
      likeCount: likeCount ?? this.likeCount,
      goodLiftCount: goodLiftCount ?? this.goodLiftCount,
      commentCount: commentCount ?? this.commentCount,
      createdAt: createdAt ?? this.createdAt,
      localThumbPath:
          clearLocalThumbPath ? null : (localThumbPath ?? this.localThumbPath),
      promoteToHome: this.promoteToHome,
      badges: this.badges,
      dailyTotal: this.dailyTotal,
    );
  }
}
