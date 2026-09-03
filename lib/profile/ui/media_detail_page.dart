/// Full-screen viewer for media with NO post document behind it.
///
/// Deliberately thin, and deliberately narrow in scope. Likes, GoodLifts,
/// comments, caption editing and owner deletion already live in the app's
/// PostDetailPage, and a PUBLISHED grid tile opens that — see
/// ProfileScreen._openMedia. This page is only for the cases where there is no
/// post to open:
///
///   * a pending upload, whose bytes are still only on this device,
///   * a proof opened straight from the showcase,
///   * a published post whose document could not be read right now.
///
/// It used to be what a published tile opened as well, which is why tapping a
/// photo on your own profile gave you a page with no comments and no like
/// button while the identical photo in the feed had both.
///
/// ── Every load ends somewhere ───────────────────────────────────────────────
/// Image and video alike resolve to exactly one of: media on screen, a BOUNDED
/// loading state, or a stated failure with a retry. `initialize()` has no
/// timeout of its own, so a stalled connection used to leave the spinner up for
/// as long as the page stayed open.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/media_identity.dart';
import '../core/media_models.dart';
import '../core/media_timeouts.dart';
import '../data/media_video_source.dart';
import 'cached_network_image.dart';
import 'profile_theme.dart';

class MediaDetailPage extends StatefulWidget {
  const MediaDetailPage({
    super.key,
    required this.title,
    required this.mediaType,
    required this.url,
    this.ownerUid = '',
    this.mediaId = '',
    this.storagePath = '',
    this.localFilePath,
    this.caption,
    this.badge,
    this.resolver,
    this.initTimeout = kVideoInitTimeout,
  });

  final String title;
  final String mediaType;
  final String url;

  /// Identity for the disk cache. Defaults keep every existing caller working:
  /// with none of them set the key falls back to the URL with its rotating
  /// token stripped, which is still stable.
  final String ownerUid;
  final String mediaId;
  final String storagePath;

  /// A staged local copy, for media that has not uploaded yet. Preferred over
  /// [url] when present — a pending item has no remote URL at all, and its
  /// owner should still be able to look at what they queued.
  final String? localFilePath;

  final String? caption;

  /// Optional achievement line, e.g. "Bench Press, Barbell · 180 kg × 2".
  final String? badge;

  /// Injectable for tests.
  final VideoSourceResolver? resolver;
  final Duration initTimeout;

  @override
  State<MediaDetailPage> createState() => _MediaDetailPageState();
}

class _MediaDetailPageState extends State<MediaDetailPage> {
  VideoPlayerController? _video;
  bool _ready = false;
  MediaLoadFailure? _failure;

  /// Identifies the live attempt. A retry bumps it, so a slow or failed earlier
  /// attempt can neither land its result nor touch a disposed widget.
  int _attempt = 0;

  VideoSourceResolver get _resolver =>
      widget.resolver ?? (_ownResolver ??= VideoSourceResolver());
  VideoSourceResolver? _ownResolver;

  String get _videoCacheKey => profileMediaCacheKey(
        ownerUid: widget.ownerUid,
        variant: MediaVariant.original,
        storagePath: widget.storagePath,
        mediaId: widget.mediaId,
        url: widget.url,
      );

  @override
  void initState() {
    super.initState();
    if (widget.mediaType == MediaType.video) unawaited(_openVideo());
  }

  /// Resolves a source and initialises the player, under a bound.
  ///
  /// Safe to call again: it starts a genuinely fresh attempt and disposes the
  /// controller the previous one left behind, so a retry button cannot re-await
  /// a future that has already failed.
  Future<void> _openVideo() async {
    final int attempt = ++_attempt;
    final VideoPlayerController? previous = _video;
    _video = null;
    unawaited(previous?.dispose().catchError((Object _) {}));

    if (mounted) {
      setState(() {
        _ready = false;
        _failure = null;
      });
    }

    final VideoSource source = await _resolver.resolve(
      url: widget.url,
      cacheKey: _videoCacheKey,
      localFilePath: widget.localFilePath,
    );
    if (!_current(attempt)) return;

    if (!source.isPlayable) {
      setState(() => _failure = source.failure ?? MediaLoadFailure.unavailable);
      return;
    }

    final VideoPlayerController c = source.file != null
        ? VideoPlayerController.file(source.file!)
        : VideoPlayerController.networkUrl(Uri.parse(source.url!));
    _video = c;

    try {
      await c.initialize().timeout(widget.initTimeout);
      await c.setLooping(true);
      await c.play();
      if (!_current(attempt)) return;
      setState(() => _ready = true);
    } on TimeoutException {
      if (!_current(attempt)) return;
      setState(() => _failure = MediaLoadFailure.timedOut);
      return;
    } catch (e) {
      if (!_current(attempt)) return;
      setState(() => _failure = isConnectivityFailure(e)
          ? MediaLoadFailure.offline
          : MediaLoadFailure.unavailable);
      return;
    }

    // Playing from the network leaves nothing on disk, so the next open would
    // be exactly as network-dependent as this one. Fill the cache behind the
    // playing video: nothing waits on it, it runs at most once per clip, and a
    // failure is invisible.
    final String? fill = source.fillFromUrl;
    if (fill != null && source.file == null) {
      unawaited(_resolver.fill(url: fill, cacheKey: _videoCacheKey));
    }
  }

  /// True when [attempt] is still the live one and the widget is mounted.
  bool _current(int attempt) => mounted && attempt == _attempt;

  @override
  void dispose() {
    // Explicit teardown; nothing is saved or uploaded from here.
    _attempt++; // Nothing in flight may touch state after this point.
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ProfilePalette.navy,
      appBar: AppBar(
        backgroundColor: ProfilePalette.navy,
        elevation: 0,
        foregroundColor: ProfilePalette.textPrimary,
        title: Text(widget.title, style: ProfileText.liftName(context)),
      ),
      body: Column(
        children: <Widget>[
          Expanded(child: Center(child: _body())),
          if (widget.badge != null || widget.caption != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(ProfileSpacing.lg),
              color: ProfilePalette.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (widget.badge != null) ...<Widget>[
                    const ProfilePill(
                      label: 'PROOF ATTACHED',
                      icon: Icons.military_tech_rounded,
                      color: ProfilePalette.accent,
                    ),
                    const SizedBox(height: ProfileSpacing.sm),
                    Text(widget.badge!,
                        style: ProfileText.recordDetail(context)),
                  ],
                  if (widget.caption != null &&
                      widget.caption!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: ProfileSpacing.sm),
                    Text(widget.caption!, style: ProfileText.bio(context)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    // A media type this build does not recognise is not an image. Defaulting it
    // to one is how a video ends up in the image decoder and how a record with
    // no media at all ends up presented as a broken photo.
    if (!isSupportedMediaType(widget.mediaType)) {
      return MediaFailureView(
        failure: MediaLoadFailure.unusableSource,
        isVideo: false,
      );
    }

    if (widget.mediaType == MediaType.video) return _videoBody();

    final String? local = widget.localFilePath;
    if (local != null && File(local).existsSync()) {
      return InteractiveViewer(child: Image.file(File(local)));
    }
    if (widget.url.isEmpty) {
      return Text('This media is still uploading.',
          style: ProfileText.recordDetail(context));
    }
    return InteractiveViewer(
      // Persisted to disk: an image opened once stays viewable after the app
      // is killed and reopened with no connection. Keyed by stable identity so
      // a rotated Storage token does not orphan the cached copy.
      child: CachedProfileImage(
        url: widget.url,
        cacheKey: profileMediaCacheKey(
          ownerUid: widget.ownerUid,
          variant: MediaVariant.small,
          storagePath: widget.storagePath,
          mediaId: widget.mediaId,
          url: widget.url,
        ),
        fit: BoxFit.contain,
        placeholder: const CircularProgressIndicator(
          color: ProfilePalette.action,
        ),
        errorBuilder: (
          BuildContext context,
          MediaLoadFailure failure,
          VoidCallback retry,
        ) =>
            MediaFailureView(
          failure: failure,
          isVideo: false,
          onRetry: retry,
        ),
      ),
    );
  }

  Widget _videoBody() {
    final MediaLoadFailure? failure = _failure;
    if (failure != null) {
      return MediaFailureView(
        failure: failure,
        isVideo: true,
        // An unusable source is not retryable: nothing about tapping again
        // turns a poster JPEG into a video.
        onRetry:
            failure == MediaLoadFailure.unusableSource ? null : _openVideo,
      );
    }

    final VideoPlayerController? c = _video;
    if (c == null || !_ready) {
      return const CircularProgressIndicator(color: ProfilePalette.action);
    }
    return AspectRatio(
      aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          VideoPlayer(c),
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

/// The one place a failed media load is put into words.
///
/// Shared by the profile viewer and the post detail page so "offline" and
/// "broken" read the same wherever the user meets them, and so no surface can
/// quietly go back to showing a spinner instead.
class MediaFailureView extends StatelessWidget {
  const MediaFailureView({
    super.key,
    required this.failure,
    required this.isVideo,
    this.onRetry,
    this.textStyle,
  });

  final MediaLoadFailure failure;
  final bool isVideo;
  final VoidCallback? onRetry;
  final TextStyle? textStyle;

  /// What actually happened, said plainly. "Offline" is separated from
  /// "unavailable" because only one of them is fixed by finding a signal.
  String get message {
    final String noun = isVideo ? 'video' : 'image';
    switch (failure) {
      case MediaLoadFailure.unusableSource:
        return isVideo
            ? 'There is nothing to play here.'
            : 'This media cannot be displayed.';
      case MediaLoadFailure.offline:
        return "You're offline, and this $noun isn't saved on this device.";
      case MediaLoadFailure.timedOut:
        return 'That $noun took too long to load.';
      case MediaLoadFailure.unavailable:
        return 'That $noun could not be loaded.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style = textStyle ?? ProfileText.recordDetail(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          failure == MediaLoadFailure.offline
              ? Icons.cloud_off_rounded
              : Icons.error_outline_rounded,
          color: ProfilePalette.textMuted,
          size: 36,
        ),
        const SizedBox(height: ProfileSpacing.sm),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: ProfileSpacing.lg),
          child: Text(message, style: style, textAlign: TextAlign.center),
        ),
        if (onRetry != null) ...<Widget>[
          const SizedBox(height: ProfileSpacing.sm),
          TextButton(
            onPressed: onRetry,
            child: Text('Try again', style: ProfileText.button(context)),
          ),
        ],
      ],
    );
  }
}
