/// Full-screen media viewer for a grid tile or an attached proof video.
///
/// Deliberately thin. Likes, GoodLifts, comments and the existing post detail
/// experience already live in the app's post surfaces — this reuses the app's
/// PostDetailPage for a real post rather than reimplementing any of it, and
/// only draws its own player for the cases that have no post behind them
/// (a proof opened straight from the showcase).
library;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/media_models.dart';
import 'profile_theme.dart';

class MediaDetailPage extends StatefulWidget {
  const MediaDetailPage({
    super.key,
    required this.title,
    required this.mediaType,
    required this.url,
    this.caption,
    this.badge,
  });

  final String title;
  final String mediaType;
  final String url;
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
    if (widget.mediaType == MediaType.video && widget.url.isNotEmpty) {
      _initVideo();
    }
  }

  Future<void> _initVideo() async {
    final VideoPlayerController c =
        VideoPlayerController.networkUrl(Uri.parse(widget.url));
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
    if (widget.url.isEmpty) {
      return Text('This media is still uploading.',
          style: ProfileText.recordDetail(context));
    }
    return InteractiveViewer(
      child: Image.network(
        widget.url,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Text(
          'That image could not be loaded.',
          style: ProfileText.recordDetail(context),
        ),
      ),
    );
  }
}
