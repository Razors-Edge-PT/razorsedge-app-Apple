import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'exercise_video_assets.dart';
import 'exercise_video_player_screen.dart'; // we'll create this next

class ExerciseVideoButton extends StatelessWidget {
  final String exerciseId;
  final double size;

  const ExerciseVideoButton({
    Key? key,
    required this.exerciseId,
    this.size = 24,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final assetPath = kExerciseVideoAssets[exerciseId];
    debugPrint('🎥 ExerciseVideoButton for "$exerciseId" → assetPath="$assetPath"');
    // No video defined for this exercise → no icon.
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExerciseVideoPlayerScreen(assetPath: assetPath),
      ),
    );
  }
}
