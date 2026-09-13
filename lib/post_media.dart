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
import 'package:visibility_detector/visibility_detector.dart';

// Project-local
import 'profile/core/media_identity.dart';
import 'profile/core/media_timeouts.dart';
import 'profile/core/media_models.dart';
import 'profile/data/media_cache_sweeper.dart';
import 'profile/data/media_deletion.dart';
import 'profile/data/identity_repository.dart';
import 'profile/data/media_video_source.dart';
import 'profile/ui/cached_network_image.dart';
import 'profile/ui/live_identity.dart';
import 'profile/ui/media_detail_page.dart';
import 'push/foreground_focus.dart';
import 'social/social_activity_service.dart';
import 'social/ui/post_activity_scope.dart';

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

class PostDetailPage extends StatefulWidget {
  final Post post;
  final Future<void> Function(Post) onToggleLike;
  final Future<void> Function(Post) onToggleGoodLift;
  final Future<void> Function(Post, String) onAddComment;
  final bool canDelete;

  /// A comment to reveal — the one a notification or an Activity row is about.
  /// It is shown even when it is older than the page of comments this screen
  /// loads, which is the only way a notification about an older comment can
  /// lead anywhere.
  final String? focusCommentId;

  /// The activity record this page was opened for, named by the notification
  /// or the Activity row. Acknowledged by id, so it does not depend on being
  /// inside any query window.
  final String? focusActivityId;

  /// The signed-in account, when the caller knows it: a focus request
  /// addressed to another account is never acted on here.
  final String? viewerUid;

  /// Injectable for tests; production uses the shared instances.
  final FirebaseFirestore? firestore;
  final IdentityRepository? identity;
  final SocialActivityService? activityService;

  const PostDetailPage({
    super.key,
    required this.post,
    required this.onToggleLike,
    required this.onToggleGoodLift,
    required this.onAddComment,
    required this.canDelete,
    this.focusCommentId,
    this.focusActivityId,
    this.viewerUid,
    this.firestore,
    this.identity,
    this.activityService,
  });

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  Post get post => widget.post;
  bool get canDelete => widget.canDelete;
  Future<void> Function(Post) get onToggleLike => widget.onToggleLike;
  Future<void> Function(Post) get onToggleGoodLift => widget.onToggleGoodLift;
  Future<void> Function(Post, String) get onAddComment => widget.onAddComment;

  /// The comment being revealed. Starts as the one this page was opened for
  /// and moves when another alert about this same post points elsewhere.
  String? _focusCommentId;

  /// The interaction the page is currently dealing with. A later tap about
  /// this same post replaces it, so the record that gets read is the one the
  /// person actually tapped — including a like or Good Lift, which has no
  /// comment to scroll to but still has a badge and an alert of its own.
  String? _focusActivityId;

  /// Bumped for EVERY focus request, including a repeat of the one already
  /// showing. Tapping the same alert again after scrolling away has to bring
  /// that comment back; comparing ids alone made the second tap do nothing.
  int _focusSerial = 0;

  @override
  void initState() {
    super.initState();
    _focusCommentId = widget.focusCommentId;
    _focusActivityId = widget.focusActivityId;
    ForegroundFocus.requests.addListener(_onFocusRequest);
  }

  @override
  void didUpdateWidget(covariant PostDetailPage old) {
    super.didUpdateWidget(old);
    if (old.focusCommentId != widget.focusCommentId &&
        widget.focusCommentId != null) {
      _focusCommentId = widget.focusCommentId;
      _focusSerial++;
    }
    if (old.focusActivityId != widget.focusActivityId &&
        widget.focusActivityId != null) {
      _focusActivityId = widget.focusActivityId;
    }
  }

  @override
  void dispose() {
    ForegroundFocus.requests.removeListener(_onFocusRequest);
    super.dispose();
  }

  /// A second notification about this post, pointing at another comment — or
  /// at the same one again.
  void _onFocusRequest() {
    final FocusRequest? req = ForegroundFocus.requests.value;
    if (!mounted ||
        !shouldActOnFocus(
          req: req,
          subjectId: post.id,
          lastSerial: _seenFocusSerial,
          viewerUid: widget.viewerUid,
        )) {
      return;
    }
    _seenFocusSerial = req!.serial;
    setState(() {
      // A like or Good Lift names no comment; the post itself presents it, so
      // the list is left where it is and only the record changes.
      if (req.targetId != null) {
        _focusCommentId = req.targetId;
        _focusSerial++;
      }
      if (req.activityId != null) _focusActivityId = req.activityId;
    });
  }

  /// The newest request this page has acted on, so a rebuild does not replay
  /// one and a genuine repeat is never mistaken for it.
  int _seenFocusSerial = 0;

  @override
  Widget build(BuildContext context) {
    // Interactions with THIS post are marked read as they are actually shown —
    // see PostActivityScope. Opening the page is not by itself reading.
    return PostActivityScope(
      postId: post.id,
      focusActivityId: _focusActivityId,
      service: widget.activityService,
      child: _build(context),
    );
  }

  Widget _build(BuildContext context) {
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

// --- Simple comments list (last 20, plus the one being revealed) ---
          SizedBox(
            height: 160,
            child: _CommentsList(
              postId: post.id,
              focusCommentId: _focusCommentId,
              focusSerial: _focusSerial,
              firestore: widget.firestore,
              identity: widget.identity,
            ),
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
                firestore: widget.firestore,
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

  final FirebaseFirestore? firestore;

  const _PostActionsBar({
    required this.post,
    required this.onToggleLike,
    required this.onToggleGoodLift,
    required this.onAddComment,
    this.firestore,
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
    final postStream = (widget.firestore ?? FirebaseFirestore.instance)
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

/// How much of a comment must be on screen before it counts as seen.
const double kCommentSeenFraction = 0.5;

class _CommentsList extends StatefulWidget {
  final String postId;

  /// A comment to make sure is on screen, even if it is older than the page
  /// this list loads.
  final String? focusCommentId;

  /// Changes on every focus REQUEST, so asking again for the comment already
  /// being shown still brings it back after the person has scrolled away.
  final int focusSerial;

  final FirebaseFirestore? firestore;
  final IdentityRepository? identity;

  const _CommentsList({
    required this.postId,
    this.focusCommentId,
    this.focusSerial = 0,
    this.firestore,
    this.identity,
  });

  @override
  State<_CommentsList> createState() => _CommentsListState();
}

class _CommentsListState extends State<_CommentsList> {
  // Track which comments are expanded
  final Set<String> _expanded = <String>{};
  final ScrollController _ctrl = ScrollController();

  /// The comment a notification pointed at, when it is not in the loaded page.
  /// Fetched once, by id, and shown at the top — one document read, rather
  /// than paging backwards through a thread of unknown length.
  Map<String, dynamic>? _pinnedData;
  bool _pinnedMissing = false;
  bool _pinnedRequested = false;

  /// The focus request that has actually been PRESENTED — set from the
  /// visibility callback, never from having asked for a scroll.
  ///
  /// An earlier version set this before scrolling, and scrolled by looking up
  /// a GlobalKey's context. A target near the bottom of twenty long comments
  /// has no context at all: `ListView` has not built that row, so the scroll
  /// silently did nothing while the target counted as revealed. The row is now
  /// pinned to the top of the list instead, which is a position that always
  /// exists, and only the visibility detector can call it revealed.
  int? _revealedSerial;

  /// The request this list is still trying to satisfy.
  int? _pendingSerial;

  @override
  void initState() {
    super.initState();
    if (widget.focusCommentId != null) _pendingSerial = widget.focusSerial;
  }

  @override
  void didUpdateWidget(covariant _CommentsList old) {
    super.didUpdateWidget(old);
    final bool newTarget = old.focusCommentId != widget.focusCommentId;
    final bool newRequest = old.focusSerial != widget.focusSerial;
    if (newTarget) {
      // A second alert about the same post, pointing at a different comment.
      _pinnedRequested = false;
      _pinnedData = null;
      _pinnedMissing = false;
    }
    if (newTarget || newRequest) {
      _revealedSerial = null;
      _pendingSerial = widget.focusCommentId == null ? null : widget.focusSerial;
    }
  }

  Future<void> _loadPinned() async {
    final String? id = widget.focusCommentId;
    if (id == null || _pinnedRequested) return;
    _pinnedRequested = true;
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap =
          await (widget.firestore ?? FirebaseFirestore.instance)
              .collection('posts')
              .doc(widget.postId)
              .collection('comments')
              .doc(id)
              .get();
      if (!mounted) return;
      setState(() {
        _pinnedData = snap.data();
        // Deleted, or no longer readable: say so quietly rather than leaving
        // the person looking for something that is not there.
        _pinnedMissing = !snap.exists || snap.data() == null;
      });
    } catch (_) {
      if (mounted) setState(() => _pinnedMissing = true);
    }
  }

  /// Comments currently in the viewport, by id.
  ///
  /// Loading is not seeing. The list fetches a page of twenty; on a phone
  /// perhaps three of them are on screen. Reporting all twenty marked
  /// comments read that the person never laid eyes on — including the ones a
  /// notification was about — so this reports only what a
  /// [VisibilityDetector] says is genuinely visible.
  void _reportVisible(String commentId, VisibilityInfo info) {
    if (!mounted) return;
    final bool visible = info.visibleFraction >= kCommentSeenFraction;
    // Leaving the viewport is reported too. Only what is on screen NOW may
    // suppress that comment's banner, so a set that only ever grew was a set
    // that silently swallowed later alerts about a comment scrolled past.
    PostActivityScope.of(context)?.reportCommentVisibility(commentId, visible);
    if (visible && commentId == widget.focusCommentId) {
      // The target is genuinely in front of the person: this request is done.
      _revealedSerial = widget.focusSerial;
      _pendingSerial = null;
    }
  }

  /// Brings the list back to the pinned target.
  ///
  /// The target always sits at index 0 while a request is outstanding, so
  /// there is nothing to search for and nothing that can fail to have been
  /// built: scrolling to the top of the list IS scrolling to the target.
  void _revealFocusedIfNeeded() {
    if (_pendingSerial == null || _pendingSerial == _revealedSerial) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingSerial == null) return;
      if (!_ctrl.hasClients) return;
      if (_ctrl.offset <= _ctrl.position.minScrollExtent) {
        // Already there — the visibility detector settles the rest.
        return;
      }
      unawaited(_ctrl.animateTo(
        _ctrl.position.minScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    final stream = (widget.firestore ?? FirebaseFirestore.instance)
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
        final String? focusId = widget.focusCommentId;
        QueryDocumentSnapshot<Map<String, dynamic>>? inPage;
        for (final d in docs) {
          if (d.id == focusId) inPage = d;
        }
        if (focusId != null && inPage == null) {
          // Not in the loaded window: fetch that one comment.
          unawaited(_loadPinned());
        }
        final Map<String, dynamic>? focusData =
            inPage?.data() ?? (focusId == null ? null : _pinnedData);
        final bool showPinned = focusId != null && focusData != null;

        if (docs.isEmpty && !showPinned) {
          return Center(
            child: Text(
              focusId != null && _pinnedMissing
                  ? 'That comment is no longer available'
                  : 'No comments yet',
            ),
          );
        }

        // The comment being revealed goes FIRST, whether or not the page
        // happens to contain it, and is left out of the thread below so it is
        // not shown twice. Index 0 is the one position a list is guaranteed to
        // have built, which is what makes the reveal reliable rather than
        // dependent on how far the viewport's build cache happens to reach.
        final List<MapEntry<String, Map<String, dynamic>>> rows =
            <MapEntry<String, Map<String, dynamic>>>[
          if (showPinned)
            MapEntry<String, Map<String, dynamic>>(focusId, focusData),
          for (final d in docs)
            if (!(showPinned && d.id == focusId))
              MapEntry<String, Map<String, dynamic>>(d.id, d.data()),
        ];

        if (showPinned) _revealFocusedIfNeeded();

        return ListView.separated(
          key: PageStorageKey('comments-${widget.postId}'),
          controller: _ctrl,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (_, i) {
            final d = rows[i].value;
            final cid = rows[i].key;
            final bool isFocused = focusId != null && cid == focusId;
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

            final Widget row = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.person_outline, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: LiveUserName(
                    uid: uid,
                    identity: widget.identity,
                    fallback: storedName,
                    builder: (_, String display) => nameAndText(display),
                  ),
                ),
              ],
            );
            // Only what is genuinely on screen counts as read.
            final Widget seen = VisibilityDetector(
              key: Key('comment-vis-${widget.postId}-$cid'),
              onVisibilityChanged: (VisibilityInfo info) =>
                  _reportVisible(cid, info),
              child: row,
            );
            if (!isFocused) return seen;
            // A quiet marker on the comment the person came here to see.
            return Container(
              key: const Key('comment-focused-row'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: seen,
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
