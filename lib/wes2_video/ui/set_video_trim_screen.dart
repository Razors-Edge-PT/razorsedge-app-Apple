/// In-app trimming, opened immediately after recording stops.
///
/// Android does not guarantee a system video editor, and an external one would
/// take the user out of GoodLift mid-workout, so trimming is implemented here.
/// The controls are deliberately plain — a scrubbable preview, a filmstrip, and
/// two handles — because the task is narrow and the user is between sets.
///
/// ── Why the guidance is loud ────────────────────────────────────────────────
/// An untrimmed set is mostly setup: walking in, unracking, chalk. That footage
/// is the bulk of the file, and the file is what fills the user's device and,
/// for a personal best, the project's storage. The instruction is therefore
/// pinned above the timeline rather than tucked into a help sheet, and the
/// trimmed duration is always on screen so the cost is visible while choosing.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../set_video_copy.dart';
import '../set_video_pipeline.dart';

/// Produces filmstrip frames. Injected so the screen can be tested without a
/// decoder.
abstract class TrimFilmstripSource {
  /// [count] evenly spaced JPEG frames across the clip, in order. May return
  /// fewer (or none) — the timeline degrades to a plain bar.
  Future<List<Uint8List>> frames({required File video, required int count});
}

class SetVideoTrimScreen extends StatefulWidget {
  const SetVideoTrimScreen({
    super.key,
    required this.capture,
    this.filmstrip,
    this.controllerFactory,
  });

  final RawCapture capture;
  final TrimFilmstripSource? filmstrip;

  /// Injected for tests; defaults to a real file-backed player.
  final VideoPlayerController Function(File file)? controllerFactory;

  @override
  State<SetVideoTrimScreen> createState() => _SetVideoTrimScreenState();
}

class _SetVideoTrimScreenState extends State<SetVideoTrimScreen> {
  VideoPlayerController? _player;
  bool _ready = false;
  String? _error;
  bool _busy = false;

  Duration _total = Duration.zero;
  double _startMs = 0;
  double _endMs = 0;
  List<Uint8List> _frames = const <Uint8List>[];

  static const int _frameCount = 8;
  static const int _minTrimMs = 1000;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final VideoPlayerController c = (widget.controllerFactory ??
        (File f) => VideoPlayerController.file(f))(widget.capture.file);
    _player = c;
    try {
      await c.initialize();
      if (!mounted) return;
      final Duration d = c.value.duration.inMilliseconds > 0
          ? c.value.duration
          : Duration(milliseconds: widget.capture.durationMs);
      setState(() {
        _total = d;
        _startMs = 0;
        _endMs = d.inMilliseconds.toDouble();
        _ready = true;
      });
      await c.setLooping(false);
      unawaited(_loadFrames());
    } catch (_) {
      if (mounted) setState(() => _error = SetVideoCopy.trimFailed);
    }
  }

  Future<void> _loadFrames() async {
    final TrimFilmstripSource? source = widget.filmstrip;
    if (source == null) return;
    try {
      final List<Uint8List> f =
          await source.frames(video: widget.capture.file, count: _frameCount);
      if (mounted) setState(() => _frames = f);
    } catch (_) {
      // The filmstrip is a convenience; the handles work without it.
    }
  }

  int get _trimmedMs => (_endMs - _startMs).round();

  bool get _canSave => _ready && _trimmedMs >= _minTrimMs && !_busy;

  String _fmt(num ms) {
    final int total = (ms / 1000).floor();
    final int m = total ~/ 60;
    final int s = total % 60;
    final int tenths = ((ms % 1000) / 100).floor();
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.$tenths';
  }

  Future<void> _seek(double ms) async {
    final VideoPlayerController? c = _player;
    if (c == null || !_ready) return;
    await c.seekTo(Duration(milliseconds: ms.round()));
  }

  Future<void> _previewTrimmed() async {
    final VideoPlayerController? c = _player;
    if (c == null || !_ready) return;
    await c.seekTo(Duration(milliseconds: _startMs.round()));
    await c.play();
    // Stop at the chosen end so the preview shows the clip that will be saved,
    // not the tail that will not be.
    Timer(Duration(milliseconds: _trimmedMs), () async {
      if (!mounted) return;
      await c.pause();
    });
  }

  void _save() {
    if (!_canSave) return;
    setState(() => _busy = true);
    Navigator.of(context).pop(
      TrimSelection(startMs: _startMs.round(), endMs: _endMs.round()),
    );
  }

  Future<void> _cancel() async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text(SetVideoCopy.discardRecordingTitle),
        content: const Text(SetVideoCopy.discardRecordingBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(SetVideoCopy.keepRecording),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(SetVideoCopy.discard),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    Navigator.of(context).pop<TrimSelection?>(null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(SetVideoCopy.trimTitle),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: SetVideoCopy.cancelTrim,
          onPressed: _cancel,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _canSave ? _save : null,
            child: Text(
              SetVideoCopy.saveTrimmed,
              style: TextStyle(
                color: _canSave ? Colors.lightBlueAccent : Colors.white24,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
              ),
            )
          : Column(
              children: <Widget>[
                Expanded(child: Center(child: _preview())),
                _guidance(),
                _timeline(),
                const SizedBox(height: 16),
              ],
            ),
    );
  }

  Widget _preview() {
    final VideoPlayerController? c = _player;
    if (!_ready || c == null) {
      return const CircularProgressIndicator(color: Colors.white);
    }
    return GestureDetector(
      onTap: _previewTrimmed,
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            VideoPlayer(c),
            if (!c.value.isPlaying)
              const Icon(Icons.play_circle_fill,
                  size: 56, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  Widget _guidance() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.lightBlueAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: Colors.lightBlueAccent.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.content_cut,
                    color: Colors.lightBlueAccent, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    SetVideoCopy.trimGuidance,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            SetVideoCopy.privacyNotice,
            style: const TextStyle(
                color: Colors.white54, fontSize: 11.5, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget _timeline() {
    final int totalMs = _total.inMilliseconds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text('Start ${_fmt(_startMs)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
              Semantics(
                liveRegion: true,
                label:
                    'Trimmed length ${(_trimmedMs / 1000).toStringAsFixed(1)}'
                    ' seconds',
                child: Text(
                  '${(_trimmedMs / 1000).toStringAsFixed(1)}s',
                  style: TextStyle(
                    color: _trimmedMs >= _minTrimMs
                        ? Colors.lightBlueAccent
                        : Colors.amberAccent,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text('End ${_fmt(_endMs)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 56,
            child: _Filmstrip(frames: _frames),
          ),
          if (totalMs > 0) ...<Widget>[
            _handle(
              label: 'Trim start',
              value: _startMs,
              min: 0,
              max: (_endMs - _minTrimMs).clamp(0, totalMs.toDouble()),
              onChanged: (double v) {
                setState(() => _startMs = v);
                unawaited(_seek(v));
              },
            ),
            _handle(
              label: 'Trim end',
              value: _endMs,
              min: (_startMs + _minTrimMs).clamp(0, totalMs.toDouble()),
              max: totalMs.toDouble(),
              onChanged: (double v) {
                setState(() => _endMs = v);
                unawaited(_seek(v));
              },
            ),
          ],
          if (_trimmedMs < _minTrimMs)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                SetVideoCopy.trimTooShort,
                style: TextStyle(color: Colors.amberAccent, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _handle({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    // A degenerate range would make the slider throw; show it inert instead.
    final bool usable = max > min;
    return Semantics(
      slider: true,
      label: label,
      value: _fmt(value),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, usable ? max : min),
              min: min,
              max: usable ? max : min + 1,
              activeColor: Colors.lightBlueAccent,
              inactiveColor: Colors.white24,
              onChanged: usable ? onChanged : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Filmstrip extends StatelessWidget {
  const _Filmstrip({required this.frames});

  final List<Uint8List> frames;

  @override
  Widget build(BuildContext context) {
    if (frames.isEmpty) {
      // No decoder, or none produced. The handles are still fully usable.
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(6),
        ),
        child: const SizedBox.expand(),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Row(
        children: <Widget>[
          for (final Uint8List f in frames)
            Expanded(
              child: Image.memory(
                f,
                fit: BoxFit.cover,
                height: double.infinity,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) =>
                    const ColoredBox(color: Colors.white10),
              ),
            ),
        ],
      ),
    );
  }
}
