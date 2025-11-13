import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'exercise_video_assets.dart';
import 'exercise_video_player_screen.dart';

class ExerciseVideoButton extends StatelessWidget {
  final String exerciseId;   // may be an ID OR a name
  final double size;

  const ExerciseVideoButton({
    Key? key,
    required this.exerciseId,
    this.size = 24,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    debugPrint('🎥 [BUTTON] build for exerciseId="$exerciseId"');
    // 🔍 1) Try ID → 2) Try Name → 3) no video
    final assetPath =
        kExerciseVideoAssets[exerciseId] ??      // try ID
            kExerciseVideoAssets[exerciseId.trim()]; // try trimmed name

    debugPrint('🎥 ExerciseVideoButton lookup for "$exerciseId" → "$assetPath"');

    // ❌ No video found → hide icon
    if (assetPath == null) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: () => _openVideo(context, assetPath),
      onLongPress: () => _openVideo(context, assetPath),
      child: Icon(
        Icons.play_circle_fill,
        size: size,
        color: Colors.blueGrey.shade400,
      ),
    );
  }

  void _openVideo(BuildContext context, String assetPath) {
    debugPrint('▶️ Opening video: $assetPath');

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExerciseVideoPlayerScreen(
          assetPath: assetPath,
          exerciseName: exerciseId,   // ← Use the exerciseId/name you already have
        ),
      ),
    );
  }

}
