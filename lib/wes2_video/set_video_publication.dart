/// The one gate that decides whether a set video may leave the device.
///
/// Almost every recording is private: it is filmed against an ordinary set and
/// never uploaded at all. Publication is the narrow exception, and every
/// condition for it is checked HERE, in one pure function, so the rule can be
/// read and tested in one place rather than inferred from scattered call sites.
///
/// ── Why this does not decide what a PB is ───────────────────────────────────
/// It does not compute a personal best. The server-maintained
/// `profileShowcaseV1` projection on `users_public/{uid}` is the authoritative
/// lifetime PB, and this only asks whether that projection currently lists this
/// exact record fingerprint. A locally guessed best is never sufficient — the
/// client cannot see the user's whole history, so it would publish footage the
/// server would not recognise. Deriving PBs here would also be a third
/// implementation of a rule that already exists twice, in
/// `showcase_reducer.dart` and `functions/showcase/reducer.js`.
///
/// ── Why the canonical lift list is not repeated ─────────────────────────────
/// Matching goes through [matchBigFive], the same function the showcase uses.
/// The canonical list is expected to grow; nothing in this feature names a lift,
/// so an addition to `big_five.dart` (and its server mirror) is picked up with
/// no change here.
library;

import '../profile/core/big_five.dart';
import '../profile/core/showcase_models.dart';
import 'set_video_store.dart';

/// Why a recording may or may not be published.
enum SetVideoPublishDecision {
  /// Every condition is met: queue exactly one upload.
  publish,

  /// The exercise is not one of the canonical point-scoring lifts.
  notCanonical,

  /// The projection does not list this performance as a live record.
  notPersonalBest,

  /// The actor, the authenticated user and the profile owner are not all the
  /// same person. A coach acting as an athlete must never publish for them.
  actorMismatch,

  /// The user explicitly deleted or detached this footage.
  suppressed,

  /// Already queued or already live. Re-queueing would duplicate the upload.
  alreadyHandled,

  /// Not enough of the performance is known to build a fingerprint.
  incomplete,
}

/// The outcome of the gate, including what to publish it as.
class SetVideoPublishPlan {
  const SetVideoPublishPlan._(this.decision, {this.slot, this.fingerprint});

  const SetVideoPublishPlan.reject(SetVideoPublishDecision decision)
      : this._(decision);

  final SetVideoPublishDecision decision;

  /// Canonical slot, when the exercise resolved to one.
  final String? slot;

  /// The exact fingerprint the projection confirmed, when it did.
  final String? fingerprint;

  bool get shouldPublish => decision == SetVideoPublishDecision.publish;
}

/// Identity of whoever is driving the app right now.
///
/// Publication requires all three to agree. GoodLift lets a coach act as an
/// athlete, and in that mode the athlete's private footage must stay private:
/// the coach is not the owner, and nothing they do may push the athlete's video
/// onto the athlete's public profile.
class SetVideoActor {
  const SetVideoActor({
    required this.authenticatedUid,
    required this.actingUid,
  });

  /// The signed-in Firebase user.
  final String authenticatedUid;

  /// The profile currently being acted upon (equals [authenticatedUid] unless
  /// a coach is acting as an athlete).
  final String actingUid;

  /// True only when the signed-in user is operating on their own profile.
  bool ownsSelf(String ownerUid) {
    if (ownerUid.isEmpty || authenticatedUid.isEmpty || actingUid.isEmpty) {
      return false;
    }
    return ownerUid == authenticatedUid && ownerUid == actingUid;
  }
}

/// Decides whether one recording may be published, and as what.
///
/// Pure: no clock, no filesystem, no network. Every input is supplied, so the
/// whole policy is testable without a camera, a server, or a signed-in user.
///
/// [showcase] must be the SERVER-sourced projection. Passing a locally computed
/// one would defeat the point of the check.
SetVideoPublishPlan planSetVideoPublication({
  required SetVideoRecord record,
  required String exerciseName,
  required double? weight,
  required int? reps,
  required ProfileShowcase showcase,
  required SetVideoActor actor,
}) {
  // 1. Identity first. This is the check that keeps a coach, or a second
  //    account on a shared device, from publishing footage that is not theirs.
  if (!actor.ownsSelf(record.ownerUid)) {
    return const SetVideoPublishPlan.reject(
        SetVideoPublishDecision.actorMismatch);
  }

  // 2. The user's own explicit choices outrank any later reconciliation. A
  //    deleted or detached clip stays gone until they replace or re-record it.
  if (record.suppressed || record.deletedAtMs != null) {
    return const SetVideoPublishPlan.reject(SetVideoPublishDecision.suppressed);
  }

  // 3. Idempotence. Reconciliation runs on save, on startup, on resume and on
  //    reconnect, so it must be safe to run twice in a row.
  if (record.state != SetVideoState.local) {
    return const SetVideoPublishPlan.reject(
        SetVideoPublishDecision.alreadyHandled);
  }

  // 4. Canonical lift, via the shared matcher. No lift is named here.
  final BigFiveLift? lift =
      matchBigFive(rawId: record.exerciseId, rawName: exerciseName);
  if (lift == null) {
    return const SetVideoPublishPlan.reject(
        SetVideoPublishDecision.notCanonical);
  }

  // 5. A fingerprint needs a real performance behind it. The reducers ignore
  //    non-positive values, so anything they would drop is dropped here too.
  final String setKey = record.setId.trim();
  if (setKey.isEmpty ||
      weight == null ||
      reps == null ||
      !weight.isFinite ||
      weight <= 0 ||
      reps <= 0) {
    return const SetVideoPublishPlan.reject(SetVideoPublishDecision.incomplete);
  }

  // 6. Server confirmation. The fingerprint is built with exactly the same
  //    inputs and helper both reducers use, then looked up in the projection.
  //    Anything less than an exact match — a superseded lift, a rounding
  //    difference, a set that is merely good — is not published.
  final String fingerprint = recordFingerprint(
    slot: lift.slot,
    exerciseId: record.exerciseId,
    dateKey: record.dateKey,
    setKey: setKey,
    weight: weight,
    reps: reps,
  );
  if (!showcase.liveFingerprints.contains(fingerprint)) {
    return const SetVideoPublishPlan.reject(
        SetVideoPublishDecision.notPersonalBest);
  }

  return SetVideoPublishPlan._(
    SetVideoPublishDecision.publish,
    slot: lift.slot,
    fingerprint: fingerprint,
  );
}

/// True when [fingerprint] still stands as a live record in [showcase].
///
/// Called again immediately before an upload commits. A candidate confirmed
/// minutes ago can have been beaten in the meantime, and there is no reason to
/// spend the user's bandwidth or the project's storage on footage that is no
/// longer a record.
bool fingerprintStillLive(ProfileShowcase showcase, String? fingerprint) {
  if (fingerprint == null || fingerprint.isEmpty) return false;
  return showcase.liveFingerprints.contains(fingerprint);
}

/// Every slot in [showcase] whose live record carries [fingerprint].
///
/// One set can own both best-E1RM and heaviest for a lift. Both proofs point at
/// the same fingerprint, so one upload serves both and the media is never
/// uploaded twice — which is also how `MediaStaging.queueProof` already treats
/// a proof and its gallery tile.
List<String> slotsProvenBy(ProfileShowcase showcase, String fingerprint) {
  final List<String> slots = <String>[];
  for (final String slot in BigFiveSlot.ordered) {
    final ShowcaseLiftSnapshot snap = showcase.forSlot(slot);
    final bool matches = snap.bestE1rm?.fingerprint == fingerprint ||
        snap.heaviest?.fingerprint == fingerprint;
    if (matches) slots.add(slot);
  }
  return slots;
}
