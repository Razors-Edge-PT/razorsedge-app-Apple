/// Full-screen story viewer.
///
/// Expiry is re-checked on every frame boundary, not only when the list was
/// fetched: a story that crosses its 24-hour mark while it is on screen is
/// dropped immediately rather than finishing its turn. A story with no
/// publication time (the owner's own pending upload) is shown only to its
/// owner and is labelled as not yet published, because its 24 hours have not
/// begun.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/media_models.dart';
import 'cached_network_image.dart';
import 'profile_theme.dart';

class StoryViewer extends StatefulWidget {
  const StoryViewer({
    super.key,
    required this.stories,
    required this.username,
    this.isOwner = false,
    this.onDelete,
  });

  final List<StoryItem> stories;
  final String username;
  final bool isOwner;
  final void Function(StoryItem story)? onDelete;

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> {
  int _index = 0;
  Timer? _advance;
  Timer? _expiry;
  VideoPlayerController? _video;

  static const Duration _imageDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<StoryItem> get _visible {
    final DateTime now = DateTime.now();
    return widget.stories
        .where((StoryItem s) => s.pending ? widget.isOwner : s.isLiveAt(now))
        .toList(growable: false);
  }

  /// Rebuilds at the EXACT instant the story on screen expires.
  ///
  /// A viewer can be left open — a long video, a paused phone — across the
  /// boundary. Without this the story would keep playing after it stopped
  /// being readable, and the next server read would simply fail. The timer
  /// makes the viewer drop it at the same moment the rules do.
  void _scheduleExpiry(StoryItem story) {
    _expiry?.cancel();
    _expiry = null;
    final DateTime? expires = story.expiresAt;
    if (expires == null) return; // a pending upload has not started its clock
    final Duration remaining =
        expires.difference(DateTime.now()) + const Duration(microseconds: 1);
    if (remaining.isNegative) return;
    _expiry = Timer(remaining, () {
      if (!mounted) return;
      // _visible re-filters on the current time, so a rebuild is all it takes;
      // _load() then either advances or closes.
      setState(() {});
      _load();
    });
  }

  void _load() {
    _advance?.cancel();
    _expiry?.cancel();
    unawaited(_video?.dispose());
    _video = null;

    final List<StoryItem> items = _visible;
    if (items.isEmpty || _index >= items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _close());
      return;
    }

    final StoryItem story = items[_index];
    _scheduleExpiry(story);
    if (story.mediaType == MediaType.video && story.url.isNotEmpty) {
      final VideoPlayerController c =
          VideoPlayerController.networkUrl(Uri.parse(story.url));
      _video = c;
      c.initialize().then((_) {
        if (!mounted) return;
        setState(() {});
        c.play();
        _advance = Timer(c.value.duration, _next);
      }).catchError((Object _) {
        _advance = Timer(_imageDuration, _next);
      });
    } else {
      _advance = Timer(_imageDuration, _next);
    }
  }

  void _next() {
    if (!mounted) return;
    setState(() => _index++);
    _load();
  }

  void _prev() {
    if (!mounted || _index == 0) return;
    setState(() => _index--);
    _load();
  }

  void _close() {
    if (mounted && Navigator.canPop(context)) Navigator.pop(context);
  }

  @override
  void dispose() {
    _advance?.cancel();
    _expiry?.cancel();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<StoryItem> items = _visible;
    if (items.isEmpty || _index >= items.length) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final StoryItem story = items[_index];

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (TapUpDetails d) {
          final double third = MediaQuery.of(context).size.width / 3;
          if (d.localPosition.dx < third) {
            _prev();
          } else {
            _next();
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Center(child: _media(story)),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: ProfileSpacing.md,
              right: ProfileSpacing.md,
              child: Column(
                children: <Widget>[
                  Row(
                    children: List<Widget>.generate(
                      items.length,
                      (int i) => Expanded(
                        child: Container(
                          height: 2.5,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            color: i <= _index
                                ? ProfilePalette.accent
                                : Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: ProfileSpacing.md),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(widget.username,
                            style: ProfileText.liftName(context)),
                      ),
                      if (story.pending)
                        const ProfilePill(
                          label: 'NOT PUBLISHED YET',
                          icon: Icons.cloud_upload_rounded,
                        ),
                      if (widget.isOwner &&
                          !story.pending &&
                          widget.onDelete != null) ...<Widget>[
                        const SizedBox(width: ProfileSpacing.sm),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded,
                              color: Colors.white70),
                          onPressed: () {
                            widget.onDelete!(story);
                            _next();
                          },
                        ),
                      ],
                      IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white70),
                        onPressed: _close,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _media(StoryItem story) {
    if (story.pending) {
      final String? path = story.localFilePath;
      if (path != null && File(path).existsSync()) {
        return Image.file(File(path), fit: BoxFit.contain);
      }
      return const SizedBox.shrink();
    }
    if (story.mediaType == MediaType.video) {
      final VideoPlayerController? c = _video;
      if (c == null || !c.value.isInitialized) {
        return const CircularProgressIndicator(color: ProfilePalette.accent);
      }
      return AspectRatio(
        aspectRatio: c.value.aspectRatio == 0 ? 9 / 16 : c.value.aspectRatio,
        child: VideoPlayer(c),
      );
    }
    if (story.url.isEmpty) return const SizedBox.shrink();
    // Persisted to disk, so a story already viewed once still shows on a cold
    // start with no connection — for as long as it is still live.
    return CachedProfileImage(
      url: story.url,
      fit: BoxFit.contain,
      placeholder: const CircularProgressIndicator(
        color: ProfilePalette.accent,
      ),
    );
  }
}
