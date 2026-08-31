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
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/media_models.dart';
import '../core/media_urls.dart';
import 'cached_network_image.dart';
import 'profile_theme.dart';

class MediaDetailPage extends StatefulWidget {
  const MediaDetailPage({
    super.key,
    required this.title,
    required this.mediaType,
    required this.url,
    this.localFilePath,
    this.caption,
    this.badge,
  });

  final String title;
  final String mediaType;
  final String url;

  /// A staged local copy, for media that has not uploaded yet. Preferred over
  /// [url] when present — a pending item has no remote URL at all, and its
  /// owner should still be able to look at what they queued.
  final String? localFilePath;

  final String? caption;

  /// Optional achievement line, e.g. "Bench Press, Barbell · 180 kg × 2".
  final String? badge;

  @override
  State<MediaDetailPage> createState() => _MediaDetailPageState();
}

class _MediaDetailPageState extends State<MediaDetailPage> {
  VideoPlayerController? _video;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final bool hasLocal = widget.localFilePath != null &&
        File(widget.localFilePath!).existsSync();
    if (widget.mediaType != MediaType.video) return;

    if (hasLocal) {
      _initVideo();
      return;
    }

    // A poster URL is not a video. Callers have handed one here before — a
    // showcase proof's `thumbUrl` — and the player then initialised against a
    // JPEG and spun for ever. Refuse it at the boundary so no caller can
    // reintroduce that, and say plainly that there is nothing to play.
    final String? playable = safeVideoSource(widget.url);
    if (playable == null) {
      if (widget.url.trim().isNotEmpty) {
        _error = 'That video could not be played.';
      }
      return;
    }
    _initVideo(playable);
  }

  Future<void> _initVideo([String? remote]) async {
    final String? local = widget.localFilePath;
    final VideoPlayerController c = local != null && File(local).existsSync()
        ? VideoPlayerController.file(File(local))
        : VideoPlayerController.networkUrl(Uri.parse(remote ?? widget.url));
    _video = c;
    try {
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = 'That video could not be played.');
    }
  }

  @override
  void dispose() {
    // Explicit teardown; nothing is saved or uploaded from here.
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
    if (_error != null) {
      return Text(_error!, style: ProfileText.recordDetail(context));
    }
    if (widget.mediaType == MediaType.video) {
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
      // is killed and reopened with no connection.
      child: CachedProfileImage(
        url: widget.url,
        fit: BoxFit.contain,
        placeholder: const CircularProgressIndicator(
          color: ProfilePalette.action,
        ),
        fallback: Text(
          'That image could not be loaded.',
          style: ProfileText.recordDetail(context),
        ),
      ),
    );
  }
}
