/// The production set-video service: one store handle, three real adapters,
/// and the maintenance pass the whole feature depends on.
///
/// ── Why this file exists ───────────────────────────────────────────────────
/// The reconciler, the publication gate and the pipeline were previously built
/// and unit-tested in isolation with fake interfaces, and NOTHING in the
/// application ever constructed them. Set footage was captured and stored, and
/// then no pass ever ran: a personal best was never published, a soft delete
/// was never finalised, and abandoned raw captures were never swept. This
/// wires those parts to the app and gives them real implementations.
///
/// ── One handle ─────────────────────────────────────────────────────────────
/// The set-video SQLite file is opened HERE and nowhere else, for the same
/// reason ProfileServices opens the outbox exactly once: two handles on one
/// file let two passes act on a row the other has already claimed. The
/// coordinator that drives the capture UI takes its store from this service
/// rather than opening its own.
library;

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../WES2_repository.dart';
import '../profile/core/showcase_models.dart';
import '../profile/data/media_outbox.dart';
import '../profile/data/media_staging.dart';
import 'native_engines.dart';
import 'set_video_files.dart';
import 'set_video_pipeline.dart';
import 'set_video_publication.dart';
import 'set_video_reconciler.dart';
import 'set_video_store.dart';

// ── Production adapters ──────────────────────────────────────────────────────

/// Reads the saved performance for one set out of the WES2 workout document.
///
/// Delegates to [Wes2Repository.savedPerformanceForSet] rather than reimplementing
/// the document shape, and that method matches on stable identity only — never
/// on display index, which is renumbered whenever a set is removed.
class Wes2SetPerformanceSource implements SetPerformanceSource {
  Wes2SetPerformanceSource(this._repository);

  final Wes2Repository _repository;

  @override
  Future<SetPerformance?> performanceFor({
    required String ownerUid,
    required String dateKey,
    required String exerciseId,
    required String setId,
  }) async {
    final DateTime? date = parseDateKey(dateKey);
    if (date == null) return null;
    try {
      final Wes2SavedSetPerformance? saved =
          await _repository.savedPerformanceForSet(
        uid: ownerUid,
        date: date,
        exerciseId: exerciseId,
        setId: setId,
      );
      if (saved == null) return null;
      return SetPerformance(
        exerciseName: saved.exerciseName,
        weight: saved.weight,
        reps: saved.reps,
      );
    } catch (_) {
      // Unreadable (offline with a cold cache, or a permission error) is NOT
      // "no performance": returning null here makes the gate report
      // `incomplete`, which declines to publish and retries next pass.
      return null;
    }
  }
}

/// Reads the server-maintained `profileShowcaseV1` projection.
///
/// The projection is the authority on what a personal best is. This never
/// computes one: it reads `users_public/{uid}` and hands over what the server
/// currently says.
class FirestoreShowcaseProjectionSource implements ShowcaseProjectionSource {
  FirestoreShowcaseProjectionSource({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  @override
  Future<ProfileShowcase?> current(String ownerUid) async {
    if (ownerUid.isEmpty) return null;
    try {
      // Server-only: a cached copy can be arbitrarily stale, and publishing
      // against a stale projection would attach a proof to a record the server
      // no longer holds. Failing to reach the server means "not currently
      // confirmable", which is a retry, not a "no".
      final DocumentSnapshot<Map<String, dynamic>> snap = await _db
          .collection('users_public')
          .doc(ownerUid)
          .get(const GetOptions(source: Source.server));

      final Map<String, dynamic>? data = snap.data();
      if (data == null) return null;
      final Object? raw = data['profileShowcaseV1'];
      if (raw == null) {
        // The document exists and genuinely has no showcase yet. That IS a
        // confirmed "no records", so an empty projection is returned rather
        // than null.
        return ProfileShowcase.empty;
      }
      return ProfileShowcase.fromMap(raw);
    } catch (_) {
      // Offline, or the read failed. Explicitly NOT ProfileShowcase.empty:
      // that would look like "no records exist" and would make every clip a
      // confirmed non-PB for as long as the network was down.
      return null;
    }
  }
}

/// Hands a trimmed clip to the EXISTING media outbox as a proof upload.
///
/// No parallel uploader: [MediaStaging.queueProof] stages the bytes into
/// application support, enforces the same 100 MB limit and truthful container
/// handling as every other upload, and enqueues one durable outbox row. The
/// same asset becomes the gallery tile and the proof, so a fingerprint owning
/// both record categories still produces exactly one upload.
class OutboxProofUploadQueue implements ProofUploadQueue {
  OutboxProofUploadQueue(this._staging);

  final MediaStaging _staging;

  @override
  Future<String> queueProof({
    required String ownerUid,
    required File file,
    required String fingerprint,
    required String slot,
  }) async {
    final OutboxItem item = await _staging.queueProof(
      ownerUid: ownerUid,
      source: file,
      fingerprint: fingerprint,
      slot: slot,
    );
    return item.mediaId;
  }
}

/// `yyyy-MM-dd` → DateTime, or null.
DateTime? parseDateKey(String dateKey) {
  final List<String> parts = dateKey.split('-');
  if (parts.length != 3) return null;
  final int? y = int.tryParse(parts[0]);
  final int? m = int.tryParse(parts[1]);
  final int? d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

// ── The service ──────────────────────────────────────────────────────────────

/// Owns the set-video store, the pipeline and the reconciler for the process.
class SetVideoService {
  SetVideoService({
    required this.store,
    required this.files,
    required this.pipeline,
    required this.reconciler,
    required MediaOutbox outbox,
    required FirebaseFirestore firestore,
  })  : _outbox = outbox,
        _db = firestore;

  final SetVideoStore store;
  final SetVideoFiles files;
  final SetVideoPipeline pipeline;
  final SetVideoReconciler reconciler;
  final MediaOutbox _outbox;
  final FirebaseFirestore _db;

  static SetVideoService? _instance;
  static Future<SetVideoService>? _initialising;

  /// The service if it is already open, else null. Used by callers that must
  /// not force the database open (a plain UI rebuild, say).
  static SetVideoService? get maybeInstance => _instance;

  /// Opens the store and builds the service. Idempotent and concurrency-safe,
  /// so overlapping callers share ONE SQLite handle.
  ///
  /// A failed build clears the in-flight future rather than caching the
  /// rejection, so one unlucky moment at launch does not disable set video for
  /// the rest of the session.
  static Future<SetVideoService> ensureInitialised({
    required MediaStaging staging,
    required MediaOutbox outbox,
    Wes2Repository? repository,
    FirebaseFirestore? firestore,
  }) {
    final SetVideoService? existing = _instance;
    if (existing != null) return Future<SetVideoService>.value(existing);
    final Future<SetVideoService>? inFlight = _initialising;
    if (inFlight != null) return inFlight;

    final Future<SetVideoService> started = _build(
      staging: staging,
      outbox: outbox,
      repository: repository,
      firestore: firestore,
    );
    _initialising = started;
    return started;
  }

  static Future<SetVideoService> _build({
    required MediaStaging staging,
    required MediaOutbox outbox,
    Wes2Repository? repository,
    FirebaseFirestore? firestore,
  }) async {
    try {
      final FirebaseFirestore db = firestore ?? FirebaseFirestore.instance;
      final SetVideoDatabase database = await SetVideoDatabase.open();
      final SetVideoStore store = SetVideoStore(database);
      final SetVideoFiles files = AppSupportSetVideoFiles();

      final SetVideoService service = SetVideoService(
        store: store,
        files: files,
        pipeline: SetVideoPipeline(
          store: store,
          files: files,
          trimmer: NativeSetVideoTrimEngine(),
          posters: const VideoThumbnailPosterEngine(),
        ),
        reconciler: SetVideoReconciler(
          store: store,
          performances:
              Wes2SetPerformanceSource(repository ?? FirestoreWes2Repository()),
          projections: FirestoreShowcaseProjectionSource(firestore: db),
          uploads: OutboxProofUploadQueue(staging),
        ),
        outbox: outbox,
        firestore: db,
      );
      _instance = service;
      _initialising = null;
      return service;
    } catch (_) {
      _initialising = null;
      rethrow;
    }
  }

  @visibleForTesting
  static void debugOverride(SetVideoService? service) {
    _instance = service;
    _initialising = null;
  }

  bool _running = false;

  /// The single maintenance pass, run from every production trigger.
  ///
  /// Order matters. Housekeeping first, so a clip whose deletion has expired is
  /// gone before anything considers publishing it; then upload recovery, so a
  /// record left `queued` by a terminated process is resolved from durable
  /// state; then reconciliation.
  ///
  /// Guarded against overlap: the triggers genuinely coincide (a save landing
  /// as the app resumes and the network returns), and two passes over one
  /// candidate is how a single clip becomes two uploads.
  Future<SetVideoMaintenanceReport> runMaintenance({
    required SetVideoActor actor,
    Duration undoWindow = const Duration(seconds: 12),
  }) async {
    if (_running) return const SetVideoMaintenanceReport.skipped();
    _running = true;
    try {
      final String ownerUid = actor.actingUid;

      // Owner-scoped: a coach acting as an athlete must not sweep, finalise or
      // publish anything belonging to that athlete.
      if (!actor.ownsSelf(ownerUid)) {
        return const SetVideoMaintenanceReport.skipped();
      }

      int swept = 0;
      int finalised = 0;
      try {
        swept = await pipeline.sweepTemporary(ownerUid);
        finalised =
            await pipeline.finalizeExpiredDeletions(undoWindow: undoWindow);
      } catch (_) {
        // Housekeeping is best-effort and must never block publication.
      }

      final int recovered = await _recoverQueued(actor);
      final ReconcileReport report = await reconciler.reconcile(actor);

      return SetVideoMaintenanceReport(
        swept: swept,
        finalised: finalised,
        recovered: recovered,
        reconcile: report,
      );
    } finally {
      _running = false;
    }
  }

  /// Resolves records stuck in [SetVideoState.queued] from DURABLE state.
  ///
  /// This is what makes upload completion survive process death. The uploader
  /// publishes a post at `posts/{mediaId}` and then removes the outbox row, so
  /// after a restart the truth is recoverable without any in-memory callback:
  ///
  ///   outbox row still present  → the upload is still owed; leave it alone.
  ///   row gone, post exists     → it published; record the real post id.
  ///   row gone, no post         → the work was dropped; return it to local so
  ///                               a later pass can retry without duplicating.
  Future<int> _recoverQueued(SetVideoActor actor) async {
    int resolved = 0;
    final List<SetVideoRecord> all = await store.allFor(actor.actingUid);
    for (final SetVideoRecord record in all) {
      if (record.state != SetVideoState.queued) continue;
      final String? mediaId = record.mediaId;
      if (mediaId == null || mediaId.isEmpty) {
        await store.markLocalOnly(record.id);
        resolved++;
        continue;
      }

      try {
        if (await _outbox.byId(mediaId) != null) continue; // still owed

        final DocumentSnapshot<Map<String, dynamic>> post =
            await _db.collection('posts').doc(mediaId).get();

        if (post.exists) {
          // The uploader names the post document with the mediaId, so this IS
          // the published identifier — not a guess.
          final bool ok = await reconciler.confirmPublished(
            recordId: record.id,
            postId: mediaId,
            actor: actor,
          );
          if (!ok) await store.markLocalOnly(record.id);
        } else {
          await store.markLocalOnly(record.id);
        }
        resolved++;
      } catch (_) {
        // Cannot tell yet. Leaving it queued is the safe answer: it will be
        // resolved on a later pass rather than duplicated now.
      }
    }
    return resolved;
  }

  /// Closes the store. Tests only — the app keeps one handle for its lifetime.
  @visibleForTesting
  Future<void> close() => store.close();
}

/// What one maintenance pass did.
class SetVideoMaintenanceReport {
  const SetVideoMaintenanceReport({
    required this.swept,
    required this.finalised,
    required this.recovered,
    required this.reconcile,
  });

  const SetVideoMaintenanceReport.skipped()
      : swept = 0,
        finalised = 0,
        recovered = 0,
        reconcile = null;

  final int swept;
  final int finalised;
  final int recovered;
  final ReconcileReport? reconcile;

  bool get ran => reconcile != null;

  @override
  String toString() => 'SetVideoMaintenance(swept: $swept, '
      'finalised: $finalised, recovered: $recovered, reconcile: $reconcile)';
}
