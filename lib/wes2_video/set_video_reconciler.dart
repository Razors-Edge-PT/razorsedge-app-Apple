/// Reconciles local footage against the server's PB projection.
///
/// Runs on a save, at startup, on resume, on reconnect, and after an
/// interrupted upload. It must therefore be IDEMPOTENT above all else: running
/// it five times in a row has to produce exactly one upload, or none.
///
/// It owns no policy. Whether a clip may be published is [planSetVideoPublication]'s
/// decision; performing the upload is the existing media outbox's job. This
/// only walks the candidates, asks, and records the answer.
///
/// ── Why the performance is looked up, not stored ───────────────────────────
/// The fingerprint has to describe the set as it is SAVED NOW, not as it was
/// when the camera stopped. A user can film a set and then correct the weight,
/// and the projection will only ever list the corrected performance. Reading
/// the current values at reconcile time is what keeps the two in agreement.
library;

import 'dart:io';

import '../profile/core/showcase_models.dart';
import 'set_video_publication.dart';
import 'set_video_store.dart';

/// The performance currently saved against a set.
class SetPerformance {
  const SetPerformance({
    required this.exerciseName,
    required this.weight,
    required this.reps,
  });

  final String exerciseName;
  final double? weight;
  final int? reps;
}

/// Reads the saved performance for one set.
abstract class SetPerformanceSource {
  Future<SetPerformance?> performanceFor({
    required String ownerUid,
    required String dateKey,
    required String exerciseId,
    required String setId,
  });
}

/// Supplies the SERVER-maintained showcase projection.
abstract class ShowcaseProjectionSource {
  /// The current projection for [ownerUid], or null when it cannot be read.
  ///
  /// A null must never be treated as "no records": that would make every clip
  /// look like a non-PB and, worse, an empty projection plus a retry could
  /// churn state. The reconciler simply does nothing until it can read one.
  Future<ProfileShowcase?> current(String ownerUid);
}

/// Hands a file to the existing media outbox as a proof upload.
abstract class ProofUploadQueue {
  /// Queues one upload and returns its media id.
  ///
  /// The same asset becomes the gallery tile and the proof, so this is called
  /// exactly once per clip however many record slots it satisfies.
  Future<String> queueProof({
    required String ownerUid,
    required File file,
    required String fingerprint,
    required String slot,
  });
}

/// What one reconciliation pass did.
class ReconcileReport {
  const ReconcileReport({
    required this.considered,
    required this.queued,
    required this.skipped,
  });

  final int considered;
  final int queued;
  final Map<SetVideoPublishDecision, int> skipped;

  @override
  String toString() =>
      'ReconcileReport(considered: $considered, queued: $queued, '
      'skipped: $skipped)';
}

class SetVideoReconciler {
  SetVideoReconciler({
    required SetVideoStore store,
    required SetPerformanceSource performances,
    required ShowcaseProjectionSource projections,
    required ProofUploadQueue uploads,
  })  : _store = store,
        _performances = performances,
        _projections = projections,
        _uploads = uploads;

  final SetVideoStore _store;
  final SetPerformanceSource _performances;
  final ShowcaseProjectionSource _projections;
  final ProofUploadQueue _uploads;

  bool _running = false;

  /// Considers every candidate for [actor]'s own profile.
  ///
  /// Re-entrancy is guarded rather than queued: the triggers overlap (a save
  /// landing just as the app resumes), and two concurrent passes over the same
  /// candidate is precisely how one clip becomes two uploads.
  Future<ReconcileReport> reconcile(SetVideoActor actor) async {
    if (_running) {
      return const ReconcileReport(
          considered: 0, queued: 0, skipped: <SetVideoPublishDecision, int>{});
    }
    _running = true;
    try {
      return await _pass(actor);
    } finally {
      _running = false;
    }
  }

  Future<ReconcileReport> _pass(SetVideoActor actor) async {
    final String ownerUid = actor.actingUid;
    final Map<SetVideoPublishDecision, int> skipped =
        <SetVideoPublishDecision, int>{};
    int queued = 0;

    // Nothing is published for a profile the signed-in user does not own, so
    // there is no reason to read anything at all in that case.
    if (!actor.ownsSelf(ownerUid)) {
      return ReconcileReport(
        considered: 0,
        queued: 0,
        skipped: <SetVideoPublishDecision, int>{
          SetVideoPublishDecision.actorMismatch: 1,
        },
      );
    }

    final List<SetVideoRecord> candidates =
        await _store.publishCandidates(ownerUid);
    if (candidates.isEmpty) {
      return const ReconcileReport(
          considered: 0, queued: 0, skipped: <SetVideoPublishDecision, int>{});
    }

    final ProfileShowcase? showcase = await _projections.current(ownerUid);
    if (showcase == null) {
      // Cannot confirm anything without the authority. Try again next trigger.
      return ReconcileReport(
          considered: candidates.length,
          queued: 0,
          skipped: const <SetVideoPublishDecision, int>{});
    }

    for (final SetVideoRecord record in candidates) {
      final SetPerformance? perf = await _performances.performanceFor(
        ownerUid: record.ownerUid,
        dateKey: record.dateKey,
        exerciseId: record.exerciseId,
        setId: record.setId,
      );

      final SetVideoPublishPlan plan = planSetVideoPublication(
        record: record,
        exerciseName: perf?.exerciseName ?? '',
        weight: perf?.weight,
        reps: perf?.reps,
        showcase: showcase,
        actor: actor,
      );

      if (!plan.shouldPublish) {
        skipped[plan.decision] = (skipped[plan.decision] ?? 0) + 1;
        continue;
      }

      final bool ok = await _queue(record, plan);
      if (ok) queued++;
    }

    return ReconcileReport(
      considered: candidates.length,
      queued: queued,
      skipped: skipped,
    );
  }

  Future<bool> _queue(SetVideoRecord record, SetVideoPublishPlan plan) async {
    final File file = File(record.localVideoPath);
    if (!file.existsSync()) {
      // The clip is gone from disk. Nothing to upload, and pretending otherwise
      // would queue a row whose file can never be read.
      return false;
    }

    // Re-read immediately before spending anything: minutes may have passed
    // since the candidate list was built, and the record may have been beaten,
    // replaced or deleted in between.
    final SetVideoRecord? fresh = await _store.byId(record.id);
    if (fresh == null ||
        fresh.generation != record.generation ||
        fresh.suppressed ||
        fresh.deletedAtMs != null ||
        fresh.state != SetVideoState.local) {
      return false;
    }

    final String mediaId = await _uploads.queueProof(
      ownerUid: record.ownerUid,
      file: file,
      fingerprint: plan.fingerprint!,
      slot: plan.slot!,
    );

    // Generation-checked: if the user replaced the clip while this was being
    // queued, the write is refused rather than pointing the record at an
    // upload of footage they have already replaced.
    return _store.markQueued(
      id: record.id,
      mediaId: mediaId,
      fingerprint: plan.fingerprint!,
      liftSlot: plan.slot!,
      generation: record.generation,
    );
  }

  /// Called when an upload commits. Confirms the fingerprint is STILL the live
  /// record before marking the clip published.
  ///
  /// A candidate can be beaten between queueing and committing. Publishing it
  /// anyway would attach a proof to a performance the projection no longer
  /// lists, which the profile would then have to hide.
  Future<bool> confirmPublished({
    required String recordId,
    required String postId,
    required SetVideoActor actor,
  }) async {
    final SetVideoRecord? record = await _store.byId(recordId);
    if (record == null) return false;
    if (!actor.ownsSelf(record.ownerUid)) return false;

    final ProfileShowcase? showcase =
        await _projections.current(record.ownerUid);
    if (showcase == null) return false;

    if (!fingerprintStillLive(showcase, record.fingerprint)) {
      // Superseded while in flight. Keep the footage locally — the user filmed
      // it and it is theirs — but do not spend storage publishing it.
      await _store.markLocalOnly(recordId);
      return false;
    }

    return _store.markPublished(
      id: recordId,
      postId: postId,
      generation: record.generation,
    );
  }
}
