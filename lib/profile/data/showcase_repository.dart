/// Reads the Big Five achievement showcase and the proof videos attached to it.
///
/// The achievements themselves arrive on `users_public/{uid}` as
/// `profileShowcaseV1` (see ProfileRepository) — a compact, presentation-ready
/// snapshot maintained server-side. The profile NEVER rescans workout history
/// to draw this; opening it is one document read, usually served from cache.
///
/// Proof pointers live separately, at `users/{uid}/proofs/{fingerprint}`,
/// because they are social-gated: an assigned coach who is not a friend can see
/// the achievements and not the videos. Keeping them out of the public snapshot
/// is what makes that gate real rather than cosmetic.
///
/// ── Staleness ───────────────────────────────────────────────────────────────
/// A proof is keyed by the RECORD FINGERPRINT. When a workout is edited or
/// deleted and the record changes, the new record has a new fingerprint, so the
/// old proof simply stops matching. It is not deleted — it stays in the media
/// gallery — it just no longer stands as proof of a record it did not produce.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../core/big_five.dart';
import '../core/showcase_models.dart';

/// A proof video attached to one record fingerprint.
@immutable
class ProofRecord {
  const ProofRecord({
    required this.fingerprint,
    required this.slot,
    required this.postId,
    this.mediaType = 'video',
    this.thumbUrl = '',
    this.storagePath = '',
    this.createdAt,
    this.pending = false,
  });

  final String fingerprint;
  final String slot;

  /// The post document holding the actual media. One asset, one upload — the
  /// proof and the grid tile are the same file.
  final String postId;

  final String mediaType;
  final String thumbUrl;
  final String storagePath;
  final DateTime? createdAt;

  /// True while the upload is still in the outbox.
  final bool pending;

  static ProofRecord? fromSnapshot(
      DocumentSnapshot<Map<String, dynamic>> snap) {
    final Map<String, dynamic>? d = snap.data();
    if (d == null) return null;
    final Object? postId = d['postId'];
    if (postId is! String || postId.isEmpty) return null;
    final Object? created = d['createdAt'];
    return ProofRecord(
      fingerprint: snap.id,
      slot: (d['slot'] as String?) ?? '',
      postId: postId,
      mediaType: (d['mediaType'] as String?) ?? 'video',
      thumbUrl: (d['thumbUrl'] as String?) ?? '',
      storagePath: (d['storagePath'] as String?) ?? '',
      createdAt: created is Timestamp ? created.toDate() : null,
    );
  }
}

/// The showcase as the UI needs it: achievements plus whichever proofs are
/// still valid for the records currently standing.
@immutable
class ShowcaseView {
  const ShowcaseView({
    required this.showcase,
    this.proofsByFingerprint = const <String, ProofRecord>{},
  });

  final ProfileShowcase showcase;
  final Map<String, ProofRecord> proofsByFingerprint;

  static const ShowcaseView empty =
      ShowcaseView(showcase: ProfileShowcase.empty);

  ShowcaseLiftSnapshot lift(String slot) => showcase.forSlot(slot);

  /// The proof standing for a record, or null. Returns null for a proof whose
  /// record has since changed — that is the whole point of fingerprinting.
  ProofRecord? proofFor(ShowcaseRecord? record) {
    if (record == null) return null;
    return proofsByFingerprint[record.fingerprint];
  }

  /// True when one video covers BOTH achievements for a lift, because both
  /// came from the same set.
  bool oneVideoCoversBoth(String slot) =>
      showcase.forSlot(slot).sharesOneSource;

  /// Proofs whose records no longer exist. Their media stays in the gallery;
  /// this is only used to stop displaying them as proof.
  Iterable<ProofRecord> get staleProofs {
    final Set<String> live = showcase.liveFingerprints;
    return proofsByFingerprint.values
        .where((ProofRecord p) => !live.contains(p.fingerprint));
  }
}

class ShowcaseRepository {
  ShowcaseRepository({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _proofs(String uid) =>
      _db.collection('users').doc(uid).collection('proofs');

  /// Live proof pointers for [ownerUid]. Fails soft: a viewer who is not
  /// allowed to see proofs (a coach who is not a friend, a non-friend) gets an
  /// empty map and the achievements still render.
  Stream<Map<String, ProofRecord>> watchProofs(String ownerUid) {
    return _proofs(ownerUid).snapshots().map(
      (QuerySnapshot<Map<String, dynamic>> q) {
        final Map<String, ProofRecord> out = <String, ProofRecord>{};
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in q.docs) {
          final ProofRecord? p = ProofRecord.fromSnapshot(doc);
          if (p != null) out[p.fingerprint] = p;
        }
        return out;
      },
    ).handleError((Object _) {});
  }

  /// Attaches an already-uploaded post as proof of a record.
  ///
  /// Idempotent: the document id IS the fingerprint, so re-running replaces
  /// rather than duplicating. Attaching a new proof to a fingerprint that
  /// already has one simply repoints it; the previous media stays in the
  /// gallery.
  Future<void> attachProof({
    required String ownerUid,
    required ShowcaseRecord record,
    required String postId,
    required String storagePath,
    String mediaType = 'video',
    String thumbUrl = '',
  }) {
    return _proofs(ownerUid).doc(record.fingerprint).set(<String, Object?>{
      'fingerprint': record.fingerprint,
      'slot': record.slot,
      'postId': postId,
      'storagePath': storagePath,
      'mediaType': mediaType,
      'thumbUrl': thumbUrl,
      // Provenance, so a proof can be audited against the record it claims.
      'recordDateKey': record.dateKey,
      'recordSetKey': record.setKey,
      'recordWeight': record.weight,
      'recordReps': record.reps,
      'formulaVersion': record.formulaVersion,
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Detaches a proof. The MEDIA is untouched and stays in the gallery — this
  /// only removes the claim that it proves a record.
  Future<void> detachProof(String ownerUid, String fingerprint) =>
      _proofs(ownerUid).doc(fingerprint).delete();

  /// Relinks an existing gallery item as proof of a record, without
  /// re-uploading anything.
  ///
  /// This is the explicit, safe path for legacy lift videos, which predate
  /// record provenance: they are never claimed automatically, because nothing
  /// about an old video says WHICH performance it shows.
  Future<void> relinkExistingMedia({
    required String ownerUid,
    required ShowcaseRecord record,
    required String postId,
    required String storagePath,
    String mediaType = 'video',
    String thumbUrl = '',
  }) =>
      attachProof(
        ownerUid: ownerUid,
        record: record,
        postId: postId,
        storagePath: storagePath,
        mediaType: mediaType,
        thumbUrl: thumbUrl,
      );

  /// Ordered lift snapshots for display, including lifts with no result yet so
  /// the showcase always presents all five.
  static List<ShowcaseLiftSnapshot> orderedLifts(ProfileShowcase showcase) =>
      BigFiveSlot.ordered
          .map((String slot) => showcase.forSlot(slot))
          .toList(growable: false);
}
