import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;


import 'package:flutter/services.dart' show rootBundle;


class ExerciseVideoPlayerScreen extends StatefulWidget {
  final String assetPath;
  final String exerciseName;


  const ExerciseVideoPlayerScreen({
    Key? key,
    required this.assetPath,
    required this.exerciseName,
  }) : super(key: key);


  @override
  State<ExerciseVideoPlayerScreen> createState() =>
      _ExerciseVideoPlayerScreenState();
}

class _ExerciseVideoPlayerScreenState
    extends State<ExerciseVideoPlayerScreen> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepareVideo();
  }

  Future<void> _prepareVideo() async {
    debugPrint(
        '🎞️ ExerciseVideoPlayerScreen created for: ${widget.assetPath}');

    try {
      // 1) Load asset bytes (we already know this works from your logs)
      final data = await rootBundle.load(widget.assetPath);
      debugPrint(
          '📦 Asset bundle load OK: ${widget.assetPath}, size=${data.lengthInBytes} bytes');

      // 2) Write to a temporary file
      final tempDir = Directory.systemTemp;
      final file = File(
          '${tempDir.path}/goodlift_ex_demo_${DateTime.now().microsecondsSinceEpoch}.mp4');
      await file.writeAsBytes(
        data.buffer.asUint8List(),
        flush: true,
      );
      debugPrint('📝 Wrote temp video file: ${file.path}');

      // 3) Create controller from the temp file instead of asset://
      final controller = VideoPlayerController.file(file);
      _controller = controller;

      await controller.initialize();
      debugPrint(
        '✅ Video initialized from file. '
            'duration=${controller.value.duration}, '
            'size=${controller.value.size}',
      );

      if (!mounted) return;
      setState(() {
        _initialized = true;
        _error = null;
      });

      controller.setLooping(true);
      controller.play();
    } catch (e, st) {
      debugPrint('❌ Video prepare / initialize failed: $e');
      debugPrint('STACK:\n$st');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _initialized = false;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Exercise demo',
              style: TextStyle(color: Colors.white),
            ),
            Text(
              widget.exerciseName,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),

      body: Center(
        child: _error != null
            ? Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Could not load video:\n$_error',
            style: const TextStyle(color: Colors.redAccent),
            textAlign: TextAlign.center,
          ),
        )
            : (!_initialized || controller == null)
            ? const CircularProgressIndicator(color: Colors.white)
            : AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              VideoPlayer(controller),
              _ControlsOverlay(controller: controller),
              VideoProgressIndicator(
                controller,
                allowScrubbing: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlsOverlay extends StatelessWidget {
  final VideoPlayerController controller;

  const _ControlsOverlay({Key? key, required this.controller})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (controller.value.isPlaying) {
          controller.pause();
        } else {
          controller.play();
        }
      },
      child: Stack(
        children: [
          if (!controller.value.isPlaying)
            const Center(
              child: Icon(
                Icons.play_arrow,
                color: Colors.white,
                size: 64,
              ),
            ),
        ],
      ),
    );
  }
}
