/// The record → trim → keep pipeline, with every device boundary injected.
///
/// The camera, the native trimmer, the poster generator and the filesystem are
/// all interfaces here. That is what lets the ORDER of operations — which is
/// where all the loss-safety lives — be tested without a physical camera:
///
///   1. capture writes a raw file to a temporary directory;
///   2. the user trims it, producing a second temporary file;
///   3. the trimmed result is adopted into durable storage;
///   4. the record is committed;
///   5. only then is the raw capture deleted, and only then is any file the
///      record previously pointed at deleted.
///
/// Steps 4 and 5 are deliberately in that order. Deleting first and committing
/// second is the sequence that loses a user's video when the step in between
/// fails.
library;

import 'dart:io';

import 'set_video_files.dart';
import 'set_video_store.dart';

/// A finished capture: the raw file the camera produced.
class RawCapture {
  const RawCapture({required this.file, required this.durationMs});

  final File file;
  final int durationMs;
}

/// The user's trim choice, in milliseconds against the raw recording.
class TrimSelection {
  const TrimSelection({required this.startMs, required this.endMs});

  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;

  bool get isUsable => durationMs >= 1000 && startMs >= 0 && endMs > startMs;
}

/// Trims a video. Implemented over the native trimmer in production.
abstract class SetVideoTrimEngine {
  /// Produces a trimmed copy of [source], or null when the platform declined.
  ///
  /// The result is a real re-export, not a rename: both platforms write a
  /// genuine MP4 (Android via Media3 Transformer, iOS via AVAssetExportSession
  /// with an mp4 output type), so the extension and the bytes agree.
  Future<File?> trim({
    required File source,
    required TrimSelection selection,
    bool includeAudio = true,
  });

  /// Drops any scratch files the engine created.
  Future<void> clearCache();
}

/// Generates a poster frame for a clip.
abstract class SetVideoPosterEngine {
  /// Returns the poster file, or null when one could not be made.
  ///
  /// A missing poster is never fatal: the clip is still playable, and the UI
  /// falls back to an icon.
  Future<File?> poster({required File video, required File target});
}

/// Raised when a recording could not be kept. The raw capture is always
/// cleaned up before this escapes.
class SetVideoFailure implements Exception {
  SetVideoFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Commits captures into durable storage.
class SetVideoPipeline {
  SetVideoPipeline({
    required SetVideoStore store,
    required SetVideoFiles files,
    required SetVideoTrimEngine trimmer,
    SetVideoPosterEngine? posters,
  })  : _store = store,
        _files = files,
        _trimmer = trimmer,
        _posters = posters;

  final SetVideoStore _store;
  final SetVideoFiles _files;
  final SetVideoTrimEngine _trimmer;
  final SetVideoPosterEngine? _posters;

  /// Trims [raw] and keeps ONLY the trimmed result against the given set.
  ///
  /// The raw capture is temporary by contract and is deleted on every exit
  /// path, success or failure. If a clip was already attached to this set, its
  /// file survives until the new one is committed, and is removed last.
  ///
  /// Throws [SetVideoFailure] if the trim fails; nothing is written and the
  /// previous clip, if any, is left exactly as it was.
  Future<SetVideoRecord> keepTrimmed({
    required String ownerUid,
    required String dateKey,
    required String exerciseId,
    required String setId,
    required int setIndex,
    required RawCapture raw,
    required TrimSelection selection,
    String? liftSlot,
    bool includeAudio = true,
  }) async {
    if (!selection.isUsable) {
      await _files.deleteQuietly(raw.file.path);
      throw SetVideoFailure('Trim to at least one second.');
    }

    File? trimmed;
    try {
      trimmed = await _trimmer.trim(
        source: raw.file,
        selection: selection,
        includeAudio: includeAudio,
      );
      if (trimmed == null || !trimmed.existsSync()) {
        throw SetVideoFailure(
            'That clip could not be trimmed. The recording has not been saved.');
      }

      final String recordId = setVideoIdFor(
        ownerUid: ownerUid,
        dateKey: dateKey,
        exerciseId: exerciseId,
        setId: setId,
      );
      final SetVideoRecord? previous = await _store.byId(recordId);
      final int nextGeneration = (previous?.generation ?? -1) + 1;

      // Into durable storage BEFORE the record is written: a row is a promise
      // that the bytes are safe, so it must not be made before they are.
      final File durable = await _files.adopt(
        ownerUid: ownerUid,
        recordId: recordId,
        generation: nextGeneration,
        source: trimmed,
      );

      final File? posterFile = await _makePoster(
        ownerUid: ownerUid,
        recordId: recordId,
        generation: nextGeneration,
        video: durable,
      );

      final SetVideoRecord record = await _store.put(
        ownerUid: ownerUid,
        dateKey: dateKey,
        exerciseId: exerciseId,
        setId: setId,
        localVideoPath: durable.path,
        localPosterPath: posterFile?.path,
        setIndex: setIndex,
        durationMs: selection.durationMs,
        sizeBytes: durable.existsSync() ? durable.lengthSync() : 0,
        liftSlot: liftSlot,
      );

      // Committed. Only now is anything deleted.
      await _files.deleteQuietly(record.supersededVideoPath);
      await _files.deleteQuietly(record.supersededPosterPath);
      await _store.clearSuperseded(record.id);

      return record;
    } finally {
      // The raw recording is temporary on EVERY path. It is the largest file
      // in the flow and the whole point of trimming is not to keep it.
      await _files.deleteQuietly(raw.file.path);
      if (trimmed != null) await _files.deleteQuietly(trimmed.path);
      await _trimmer.clearCache();
    }
  }

  Future<File?> _makePoster({
    required String ownerUid,
    required String recordId,
    required int generation,
    required File video,
  }) async {
    final SetVideoPosterEngine? engine = _posters;
    if (engine == null) return null;
    try {
      final Directory dir = await _files.videoDir(ownerUid);
      final File target = File(
        '${dir.path}${Platform.pathSeparator}'
        '${recordId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}'
        '_g$generation.jpg',
      );
      return await engine.poster(video: video, target: target);
    } catch (_) {
      // A poster is a convenience. Failing to make one must not cost the user
      // the clip they just recorded.
      return null;
    }
  }

  /// Discards a capture the user cancelled. Idempotent.
  Future<void> discard(RawCapture raw) async {
    await _files.deleteQuietly(raw.file.path);
    await _trimmer.clearCache();
  }

  /// Soft-deletes a set's footage, keeping the files while Undo is offered.
  Future<void> deleteForSet({
    required String ownerUid,
    required String dateKey,
    required String exerciseId,
    required String setId,
  }) async {
    final SetVideoRecord? record = await _store.forSet(
      ownerUid: ownerUid,
      dateKey: dateKey,
      exerciseId: exerciseId,
      setId: setId,
    );
    if (record == null) return;
    await _store.softDelete(record.id);
  }

  /// Finalises soft deletions whose Undo window has closed. Idempotent, so it
  /// is safe to run on every startup.
  Future<int> finalizeExpiredDeletions({
    required String ownerUid,
    Duration undoWindow = const Duration(seconds: 12),
  }) async {
    final List<SetVideoRecord> due = await _store.finalizable(
      ownerUid: ownerUid,
      before: DateTime.now().subtract(undoWindow),
    );
    for (final SetVideoRecord r in due) {
      await _files.deleteQuietly(r.localVideoPath);
      await _files.deleteQuietly(r.localPosterPath);
      await _files.deleteQuietly(r.supersededVideoPath);
      await _files.deleteQuietly(r.supersededPosterPath);
      await _store.purge(r.id);
    }
    return due.length;
  }

  /// Startup housekeeping: drop raw captures and half-written files left by a
  /// capture that was cancelled or killed.
  Future<int> sweepTemporary(String ownerUid) => _files.sweepTemp(ownerUid);
}
