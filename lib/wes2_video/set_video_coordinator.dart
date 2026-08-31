/// Drives the set-video flow from WES2, so the screen itself gains only a
/// callback and a lookup rather than the whole feature.
///
/// WES2_screen.dart is one of the repository's sensitive files. Everything that
/// can live outside it does: the capture route, the trim route, the durable
/// write, the attached-state menu and the undo are all here.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../WES2_models.dart';
import '../profile/core/big_five.dart';
import '../profile/ui/media_detail_page.dart';
import '../profile/core/media_models.dart';
import 'native_engines.dart';
import 'set_video_copy.dart';
import 'set_video_files.dart';
import 'set_video_pipeline.dart';
import 'set_video_store.dart';
import 'ui/set_video_capture_screen.dart';
import 'ui/set_video_trim_screen.dart';

/// What the user chose from the attached-video menu.
enum AttachedVideoAction { view, replace, delete }

class SetVideoCoordinator {
  SetVideoCoordinator({
    required SetVideoStore store,
    required SetVideoFiles files,
    required SetVideoPipeline pipeline,
  })  : _store = store,
        _files = files,
        _pipeline = pipeline;

  final SetVideoStore _store;
  final SetVideoFiles _files;
  final SetVideoPipeline _pipeline;

  static SetVideoCoordinator? _instance;
  static Completer<SetVideoCoordinator>? _opening;

  /// Opens the shared instance. Safe to call concurrently — the second caller
  /// waits on the first rather than opening a second database handle.
  static Future<SetVideoCoordinator> instance() async {
    final SetVideoCoordinator? existing = _instance;
    if (existing != null) return existing;
    final Completer<SetVideoCoordinator>? pending = _opening;
    if (pending != null) return pending.future;

    final Completer<SetVideoCoordinator> c = Completer<SetVideoCoordinator>();
    _opening = c;
    try {
      final SetVideoDatabase db = await SetVideoDatabase.open();
      final SetVideoStore store = SetVideoStore(db);
      final SetVideoFiles files = AppSupportSetVideoFiles();
      final SetVideoCoordinator made = SetVideoCoordinator(
        store: store,
        files: files,
        pipeline: SetVideoPipeline(
          store: store,
          files: files,
          trimmer: NativeSetVideoTrimEngine(),
          posters: const VideoThumbnailPosterEngine(),
        ),
      );
      _instance = made;
      c.complete(made);
      return made;
    } catch (e) {
      _opening = null;
      c.completeError(e);
      rethrow;
    }
  }

  /// Test seam.
  @visibleForTesting
  static set debugInstance(SetVideoCoordinator? value) => _instance = value;

  SetVideoStore get store => _store;
  SetVideoPipeline get pipeline => _pipeline;

  static String dateKeyFor(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Display indices that currently have footage, per exerciseId.
  ///
  /// Resolved by matching the DURABLE record's setId against the rows in
  /// memory, so a set that has been renumbered still shows its own video
  /// rather than inheriting a neighbour's.
  Future<Map<String, Set<int>>> attachedByExercise({
    required String ownerUid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  }) async {
    final Map<String, Set<int>> out = <String, Set<int>>{};
    if (ownerUid.isEmpty) return out;

    final List<SetVideoRecord> records =
        await _store.forDay(ownerUid: ownerUid, dateKey: dateKeyFor(date));
    if (records.isEmpty) return out;

    final Map<String, SetVideoRecord> bySetId = <String, SetVideoRecord>{
      for (final SetVideoRecord r in records) '${r.exerciseId}|${r.setId}': r,
    };

    for (final Wes2ExerciseRow row in rows) {
      for (final Wes2SetState s in row.sets) {
        final String? id = s.setId;
        if (id == null) continue;
        final SetVideoRecord? rec = bySetId['${row.exerciseId}|$id'];
        if (rec == null) continue;
        (out[row.exerciseId] ??= <int>{}).add(s.setIndex);
        // Keep the advisory index fresh for diagnostics; never used to find it.
        if (rec.setIndex != s.setIndex) {
          unawaited(_store.touchSetIndex(rec.id, s.setIndex));
        }
      }
    }
    return out;
  }

  /// The full flow for one tap on the set-row control.
  ///
  /// Returns true when something changed and the caller should refresh.
  Future<bool> handleTap(
    BuildContext context, {
    required String ownerUid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required String setId,
  }) async {
    final String dateKey = dateKeyFor(date);
    final SetVideoRecord? existing = await _store.forSet(
      ownerUid: ownerUid,
      dateKey: dateKey,
      exerciseId: row.exerciseId,
      setId: setId,
    );
    if (!context.mounted) return false;

    if (existing != null) {
      // Never silently overwrite footage the user already has.
      final AttachedVideoAction? action = await _askAttached(context);
      if (!context.mounted || action == null) return false;

      switch (action) {
        case AttachedVideoAction.view:
          await _view(context, existing);
          return false;
        case AttachedVideoAction.delete:
          return _delete(context, existing);
        case AttachedVideoAction.replace:
          break; // fall through to capture
      }
    }

    // Re-checked after the sheet: the replace path crosses an async gap that
    // the earlier guard does not cover once the switch has fallen through.
    if (!context.mounted) return false;

    return _captureAndKeep(
      context,
      ownerUid: ownerUid,
      dateKey: dateKey,
      row: row,
      setIndex: setIndex,
      setId: setId,
    );
  }

  Future<AttachedVideoAction?> _askAttached(BuildContext context) {
    return showModalBottomSheet<AttachedVideoAction>(
      context: context,
      backgroundColor: const Color(0xFF14202E),
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading:
                  const Icon(Icons.play_circle_outline, color: Colors.white70),
              title: const Text(SetVideoCopy.viewVideo,
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(ctx).pop(AttachedVideoAction.view),
            ),
            ListTile(
              leading:
                  const Icon(Icons.videocam_outlined, color: Colors.white70),
              title: const Text(SetVideoCopy.replaceVideo,
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(ctx).pop(AttachedVideoAction.replace),
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text(SetVideoCopy.deleteVideo,
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.of(ctx).pop(AttachedVideoAction.delete),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _view(BuildContext context, SetVideoRecord record) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MediaDetailPage(
        title: 'Set video',
        mediaType: MediaType.video,
        // Device-only footage has no remote URL at all; it plays from the file.
        url: '',
        localFilePath: record.localVideoPath,
      ),
    ));
  }

  Future<bool> _delete(BuildContext context, SetVideoRecord record) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text(SetVideoCopy.deleteVideoTitle),
        content: const Text(SetVideoCopy.deleteVideoBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(SetVideoCopy.deleteVideo,
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;

    // Soft delete: the files survive while Undo is on offer.
    await _store.softDelete(record.id);
    if (!context.mounted) return true;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text(SetVideoCopy.videoDeleted),
      action: SnackBarAction(
        label: SetVideoCopy.undo,
        onPressed: () => unawaited(_store.undoDelete(record.id)),
      ),
    ));
    return true;
  }

  Future<bool> _captureAndKeep(
    BuildContext context, {
    required String ownerUid,
    required String dateKey,
    required Wes2ExerciseRow row,
    required int setIndex,
    required String setId,
  }) async {
    final Directory tmp = await _files.tempDir(ownerUid);
    if (!context.mounted) return false;

    final CaptureResult? captured =
        await Navigator.of(context).push<CaptureResult>(
      MaterialPageRoute<CaptureResult>(
        builder: (_) => SetVideoCaptureScreen(tempDirectory: tmp),
      ),
    );
    if (!context.mounted) return false;

    if (captured == null || captured.outcome != CaptureOutcome.recorded) {
      final String? message = captured?.message;
      if (message != null) _toast(context, message);
      return false;
    }

    final RawCapture raw = captured.capture!;

    // Trimming opens immediately — not behind another tap.
    final TrimSelection? selection =
        await Navigator.of(context).push<TrimSelection>(
      MaterialPageRoute<TrimSelection>(
        builder: (_) => SetVideoTrimScreen(capture: raw),
      ),
    );

    if (selection == null) {
      await _pipeline.discard(raw);
      return false;
    }

    try {
      await _pipeline.keepTrimmed(
        ownerUid: ownerUid,
        dateKey: dateKey,
        exerciseId: row.exerciseId,
        setId: setId,
        setIndex: setIndex,
        raw: raw,
        selection: selection,
        liftSlot: matchBigFive(rawId: row.exerciseId, rawName: row.name)?.slot,
      );
      if (context.mounted) _toast(context, SetVideoCopy.videoSaved);
      return true;
    } on SetVideoFailure catch (e) {
      if (context.mounted) _toast(context, e.message);
      return false;
    } catch (_) {
      if (context.mounted) _toast(context, SetVideoCopy.trimFailed);
      return false;
    }
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
