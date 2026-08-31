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
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../profile/data/media_deletion.dart';
import '../profile/profile_services.dart';
import 'set_video_copy.dart';
import 'set_video_files.dart';
import 'set_video_pipeline.dart';
import 'set_video_service.dart';
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

  /// The coordinator for this process, built over the ONE store the
  /// [SetVideoService] owns.
  ///
  /// It deliberately does not open a database of its own. It used to, which
  /// meant two SQLite handles on one file: the capture flow wrote through one
  /// and every reconciliation, sweep and finalisation pass read through the
  /// other. Two handles let one pass act on a row the other has already
  /// claimed, which is the same hazard ProfileServices documents for the
  /// outbox.
  static Future<SetVideoCoordinator> instance() async {
    final SetVideoCoordinator? existing = _instance;
    if (existing != null) return existing;

    final ProfileServices services = await ProfileServices.ensureInitialised();
    final SetVideoService? service = services.setVideo;
    if (service == null) {
      throw StateError('Set video is unavailable: its store did not open.');
    }

    final SetVideoCoordinator made = SetVideoCoordinator(
      store: service.store,
      files: service.files,
      pipeline: service.pipeline,
    );
    _instance = made;
    return made;
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

  // ── Structural WES2 operations ────────────────────────────────────────────

  /// Soft-deletes the footage for a set of stable ids, as one structural
  /// operation.
  ///
  /// Called BEFORE the controller renumbers anything, with ids captured from
  /// the pre-mutation state: after a removal the surviving sets have shifted
  /// indexes, and there is no longer any way to tell which record belonged to
  /// the set that went. Identity is the only safe handle.
  ///
  /// Soft, not final: the files stay on disk while Undo is on offer. It also
  /// suppresses automatic publication, so a clip whose set has just been
  /// removed cannot be queued by a reconciliation pass that runs in between.
  ///
  /// Returns the record ids affected, so an Undo can restore exactly these.
  Future<List<String>> softDeleteForSets({
    required String ownerUid,
    required DateTime date,
    required String exerciseId,
    required Iterable<String> setIds,
  }) async {
    final List<String> affected = <String>[];
    final String dateKey = dateKeyFor(date);
    for (final String setId in setIds) {
      final SetVideoRecord? record = await _store.forSet(
        ownerUid: ownerUid,
        dateKey: dateKey,
        exerciseId: exerciseId,
        setId: setId,
      );
      if (record == null) continue;
      await _store.softDelete(record.id);
      affected.add(record.id);
    }
    return affected;
  }

  /// Soft-deletes every recording belonging to one exercise on one day.
  ///
  /// Used by remove-exercise, replace-exercise and whole-day/template
  /// replacement, so footage cannot be left behind pointing at a row the user
  /// can no longer reach.
  Future<List<String>> softDeleteForExercise({
    required String ownerUid,
    required DateTime date,
    required String exerciseId,
  }) async {
    final List<SetVideoRecord> day = await _store.forDay(
      ownerUid: ownerUid,
      dateKey: dateKeyFor(date),
    );
    final List<String> affected = <String>[];
    for (final SetVideoRecord r in day) {
      if (r.exerciseId != exerciseId) continue;
      await _store.softDelete(r.id);
      affected.add(r.id);
    }
    return affected;
  }

  /// Soft-deletes every recording on a day whose exercise is no longer present.
  ///
  /// The backstop for whole-day and template replacement, where rows are
  /// rebuilt wholesale: anything filmed against an exercise that has gone would
  /// otherwise be orphaned — invisible in the UI but still occupying storage
  /// and still a publication candidate.
  Future<List<String>> softDeleteOrphans({
    required String ownerUid,
    required DateTime date,
    required Set<String> survivingExerciseIds,
  }) async {
    final List<SetVideoRecord> day = await _store.forDay(
      ownerUid: ownerUid,
      dateKey: dateKeyFor(date),
    );
    final List<String> affected = <String>[];
    for (final SetVideoRecord r in day) {
      if (survivingExerciseIds.contains(r.exerciseId)) continue;
      await _store.softDelete(r.id);
      affected.add(r.id);
    }
    return affected;
  }

  /// Reverses a structural soft delete, restoring the SAME records.
  ///
  /// Never mints a new identity and never creates a second record: it lifts the
  /// deletion on the exact ids the operation reported, so the restored set
  /// shows the footage it always had.
  Future<void> undoStructuralDelete(Iterable<String> recordIds) async {
    for (final String id in recordIds) {
      await _store.undoDelete(id);
    }
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

    // Soft delete: the files survive while Undo is on offer, and suppression
    // stops a reconciliation pass re-queueing it in the meantime.
    await _store.softDelete(record.id);
    if (!context.mounted) return true;

    final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> bar =
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text(SetVideoCopy.videoDeleted),
      action: SnackBarAction(
        label: SetVideoCopy.undo,
        onPressed: () => unawaited(_store.undoDelete(record.id)),
      ),
    ));

    // The window closing is what makes the deletion real. Without this the row
    // stayed soft-deleted indefinitely and Delete only ever hid the video,
    // which is not a deletion the user can be told succeeded.
    unawaited(bar.closed.then((SnackBarClosedReason reason) async {
      if (reason == SnackBarClosedReason.action) return;
      await finalizeDeletion(record.id);
    }));
    return true;
  }

  /// Makes a soft deletion real: server work first, then the local bytes.
  ///
  /// The three cases are genuinely different and are kept distinct rather than
  /// collapsed into one "delete":
  ///
  ///   published        the media is user-visible on the profile, so it goes
  ///                    through the EXISTING central profile-media deletion
  ///                    rather than a second deletion path of our own.
  ///   queued, not live nothing is published yet, so the pending upload is
  ///                    cancelled — which also removes its staged copy — and no
  ///                    server object is left behind.
  ///   local only       nothing server-side to do.
  ///
  /// Idempotent: it re-reads the record, and every step tolerates having
  /// already run, so a retry or a duplicated trigger is harmless.
  Future<void> finalizeDeletion(String recordId) async {
    final SetVideoRecord? record = await _store.byId(recordId);
    if (record == null) return;
    if (record.deletedAtMs == null) return; // undone in the meantime

    try {
      final ProfileServices services =
          await ProfileServices.ensureInitialised();
      final String? mediaId = record.mediaId;

      if (record.state == SetVideoState.published && mediaId != null) {
        // The one central implementation, shared with the profile grid and the
        // feed's post detail page. storagePath is left empty because our
        // uploads live under users/{uid}/posts/{postId}/, which its folder
        // sweep removes wholesale — original and generated poster alike.
        await deletePostEverywhere(
          firestore: FirebaseFirestore.instance,
          storage: FirebaseStorage.instance,
          ownerUid: record.ownerUid,
          postId: record.postId ?? mediaId,
        );
      } else if (record.state == SetVideoState.queued && mediaId != null) {
        // Not published yet: cancelling removes the outbox row and its staged
        // file, so the upload never happens rather than happening and then
        // needing to be deleted.
        await services.media.cancelPending(mediaId);
      }
    } catch (_) {
      // Server-side cleanup is best effort. The local bytes are still removed
      // below, which is what the user asked for and what privacy requires.
    }

    // Unlinks video, poster and any superseded files, then purges the row.
    await _pipeline.finalizeExpiredDeletions(
        ownerUid: record.ownerUid, undoWindow: Duration.zero);
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
