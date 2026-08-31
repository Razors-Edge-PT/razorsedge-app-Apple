/// Production implementations of the pipeline's device boundaries.
///
/// Kept apart from [SetVideoPipeline] so the pipeline itself — where the
/// loss-safety ordering lives — stays testable with no plugin registered.
library;

import 'dart:io';

import 'package:flutter_native_video_trimmer/flutter_native_video_trimmer.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'set_video_pipeline.dart';

/// Trims via `flutter_native_video_trimmer`.
///
/// Both platforms perform a real re-export rather than a rename: Android
/// through Media3 Transformer, iOS through AVAssetExportSession with an mp4
/// output type. The result is genuinely an MP4, so the file name, the bytes and
/// the Content-Type the uploader later derives all agree. That matters because
/// a QuickTime file renamed to `.mp4` would pass every extension check while
/// being a lie the Storage rules and the player both eventually trip over.
///
/// The engine writes into the platform cache directory, which is why the
/// pipeline adopts the result into application support before recording it.
class NativeSetVideoTrimEngine implements SetVideoTrimEngine {
  NativeSetVideoTrimEngine({VideoTrimmer? trimmer})
      : _trimmer = trimmer ?? VideoTrimmer();

  final VideoTrimmer _trimmer;

  @override
  Future<File?> trim({
    required File source,
    required TrimSelection selection,
    bool includeAudio = true,
  }) async {
    try {
      await _trimmer.loadVideo(source.path);
      final String? out = await _trimmer.trimVideo(
        startTimeMs: selection.startMs,
        endTimeMs: selection.endMs,
        includeAudio: includeAudio,
      );
      if (out == null) return null;
      final File file = File(out);
      return file.existsSync() ? file : null;
    } catch (_) {
      // A platform refusal is a recoverable failure, not a crash: the pipeline
      // turns a null into a SetVideoFailure, cleans up, and leaves any
      // previously attached clip untouched.
      return null;
    }
  }

  @override
  Future<void> clearCache() async {
    try {
      await _trimmer.clearCache();
    } catch (_) {
      // Best-effort. Leftover scratch files are also swept on next startup.
    }
  }
}

/// Poster frames via `video_thumbnail`, the same package the profile media
/// staging already uses, so posters look identical wherever they come from.
class VideoThumbnailPosterEngine implements SetVideoPosterEngine {
  const VideoThumbnailPosterEngine();

  @override
  Future<File?> poster({required File video, required File target}) async {
    try {
      final String? path = await VideoThumbnail.thumbnailFile(
        video: video.path,
        thumbnailPath: target.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 720,
        quality: 70,
      );
      if (path == null) return null;
      final File file = File(path);
      return file.existsSync() ? file : null;
    } catch (_) {
      // A missing poster costs a thumbnail, never the clip.
      return null;
    }
  }
}
