import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'onboarding_prefs.dart';

/// Full-screen video demo overlay for the Workout Planner.
///
/// Marks [actorUid]'s wpDemoComplete flag the first time the video plays
/// to completion, regardless of whether this was auto-shown or manually opened.
/// Manual replay never clears the flag.
///
/// When [autoCloseAfterCompletion] is true the modal pops itself 2 s after the
/// video finishes its first playthrough. Set to false for manual replay so the
/// user stays in control of closing.
class WpDemoPlayer extends StatefulWidget {
  final String actorUid;
  final bool autoCloseAfterCompletion;
  const WpDemoPlayer({
    super.key,
    required this.actorUid,
    this.autoCloseAfterCompletion = false,
  });

  @override
  State<WpDemoPlayer> createState() => _WpDemoPlayerState();
}

class _WpDemoPlayerState extends State<WpDemoPlayer> {
  late final VideoPlayerController _vpc;
  bool _initialized = false;
  bool _loadError   = false;
  bool _markedComplete = false;
  Timer? _autoCloseTimer;

  @override
  void initState() {
    super.initState();
    _vpc = VideoPlayerController.asset(
      'assets/screen_recordings/workout_planner_demo.mp4',
    );
    _vpc.addListener(_onTick);
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      await _vpc.initialize();
      if (!mounted) return;
      setState(() => _initialized = true);
      await _vpc.play();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = true);
    }
  }

  void _onTick() {
    if (_markedComplete) return;
    final v = _vpc.value;
    if (!v.isInitialized || v.duration == Duration.zero) return;
    if (v.position >= v.duration - const Duration(milliseconds: 800)) {
      _markedComplete = true;
      OnboardingPrefs.setWpDone(widget.actorUid);
      if (widget.autoCloseAfterCompletion) {
        _autoCloseTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) Navigator.of(context).maybePop();
        });
      }
    }
  }

  @override
  void dispose() {
    _autoCloseTimer?.cancel();
    _vpc.removeListener(_onTick);
    _vpc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black87,
      child: SafeArea(
        child: Column(
          children: [
            // ── Controls row ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.replay, color: Colors.white70),
                    tooltip: 'Replay',
                    onPressed: _initialized
                        ? () async {
                            await _vpc.seekTo(Duration.zero);
                            await _vpc.play();
                          }
                        : null,
                  ),
                ],
              ),
            ),
            // ── Video / loading / error ───────────────────────────────────
            Expanded(
              child: Center(child: _buildBody()),
            ),
            // ── Thin progress bar ─────────────────────────────────────────
            if (_initialized)
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: _vpc,
                builder: (_, v, __) {
                  final total = v.duration.inMilliseconds;
                  final pos   = v.position.inMilliseconds;
                  final prog  = (total > 0)
                      ? (pos / total).clamp(0.0, 1.0)
                      : 0.0;
                  return LinearProgressIndicator(
                    value: prog,
                    backgroundColor: Colors.white24,
                    color: Colors.white70,
                    minHeight: 2,
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loadError) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Could not load demo video.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close', style: TextStyle(color: Colors.white70)),
          ),
        ],
      );
    }
    if (!_initialized) {
      return const CircularProgressIndicator(color: Colors.white54);
    }
    return AspectRatio(
      aspectRatio: _vpc.value.aspectRatio,
      child: VideoPlayer(_vpc),
    );
  }
}
