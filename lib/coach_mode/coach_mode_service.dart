// Coach Mode data access: the callable wrappers and the read streams.
//
// Every state change goes through a Cloud Function — nothing here writes to
// coachApplications, accountEntitlements, coachProfiles or coachAthleteLinks,
// because firestore.rules makes all four client-unwritable. Reads are plain
// Firestore streams so the UI updates the moment the server commits.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'coach_mode_models.dart';

/// Thrown for a failed callable, carrying the field the server rejected so the
/// form can highlight it.
class CoachModeException implements Exception {
  final String message;
  final String? field;
  final String? code;
  CoachModeException(this.message, {this.field, this.code});

  @override
  String toString() => message;
}

DateTime? _toDate(Object? v) {
  if (v is Timestamp) return v.toDate();
  if (v is DateTime) return v;
  return null;
}

class CoachModeService {
  final FirebaseFirestore _db;
  final FirebaseFunctions _fns;

  CoachModeService({FirebaseFirestore? firestore, FirebaseFunctions? functions})
      : _db = firestore ?? FirebaseFirestore.instance,
        _fns = functions ?? FirebaseFunctions.instance;

  // ── Callable plumbing ─────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _call(
    String name, [
    Map<String, dynamic>? payload,
  ]) async {
    try {
      final res = await _fns
          .httpsCallable(name)
          .call<Map<String, dynamic>>(payload ?? const <String, dynamic>{});
      final data = res.data;
      return Map<String, dynamic>.from(data);
    } on FirebaseFunctionsException catch (e) {
      final details = e.details;
      final field = (details is Map && details['field'] != null)
          ? details['field'].toString()
          : null;
      debugPrint('❌ [CoachMode] $name failed: ${e.code} ${e.message}');
      throw CoachModeException(
        e.message ?? 'Something went wrong. Please try again.',
        field: field,
        code: e.code,
      );
    } catch (e) {
      debugPrint('❌ [CoachMode] $name failed: $e');
      throw CoachModeException('Something went wrong. Please try again.');
    }
  }

  // ── Applicant ─────────────────────────────────────────────────────────────

  Future<void> submitApplication(CoachApplicationDraft draft) =>
      _call('coachModeSubmitApplication', draft.toCallablePayload());

  Future<void> withdrawApplication() => _call('coachModeWithdrawApplication');

  /// The caller's own application. Readable only by the applicant and the
  /// super admin (firestore.rules), so this can never leak someone else's.
  Stream<CoachApplication> watchMyApplication(String uid) {
    return _db
        .collection(kColCoachApplications)
        .doc(uid)
        .snapshots()
        .map((s) => CoachApplication.fromMap(uid, s.data(), toDate: _toDate));
  }

  /// The caller's own entitlement — the authoritative Coach Mode state.
  Stream<CoachEntitlement> watchMyEntitlement(String uid) {
    return _db
        .collection(kColAccountEntitlements)
        .doc(uid)
        .snapshots()
        .map((s) => CoachEntitlement.fromMap(s.data()));
  }

  /// Reads accountEntitlements/{uid} once.
  ///
  /// A SUCCESSFUL read with no document is a valid [CoachEntitlement.none] —
  /// the account genuinely holds no Coach Mode.
  ///
  /// A read/network/App Check FAILURE throws [CoachModeException]. It must not
  /// be flattened into `none`: doing so made the caller's error handler
  /// unreachable, overwrote the last known authoritative state, and let a
  /// stale `isCoach` claim take over routing (because `none` re-enables the
  /// claim fallback in [resolveCoachRole]). Callers keep their last known
  /// entitlement on failure — see `_attachCoachEntitlement` in main.dart.
  Future<CoachEntitlement> fetchEntitlement(String uid) async {
    try {
      final s = await _db.collection(kColAccountEntitlements).doc(uid).get();
      return CoachEntitlement.fromMap(s.data());
    } catch (e) {
      debugPrint('⚠️ [CoachMode] entitlement read failed for $uid: $e');
      throw CoachModeException(
        'Could not verify Coach Mode status.',
        code: 'entitlement-read-failed',
      );
    }
  }

  // ── Coach: roster + invitations ───────────────────────────────────────────

  /// Every canonical link where this account is the coach. Terminated links
  /// are included so the UI can decide what to show; splitCoachRoster() keeps
  /// only active and pending.
  Stream<List<CoachAthleteLink>> watchCoachLinks(String coachUid) {
    return _db
        .collection(kColCoachAthleteLinks)
        .where('coachUid', isEqualTo: coachUid)
        .snapshots()
        .map((q) => q.docs
            .map((d) => CoachAthleteLink.fromMap(d.id, d.data(), toDate: _toDate))
            .toList());
  }

  /// Every canonical link where this account is the athlete.
  Stream<List<CoachAthleteLink>> watchAthleteLinks(String athleteUid) {
    return _db
        .collection(kColCoachAthleteLinks)
        .where('athleteUid', isEqualTo: athleteUid)
        .snapshots()
        .map((q) => q.docs
            .map((d) => CoachAthleteLink.fromMap(d.id, d.data(), toDate: _toDate))
            .toList());
  }

  Future<Map<String, dynamic>> inviteAthlete(String athleteEmail) =>
      _call('coachModeInviteAthlete', {'athleteEmail': athleteEmail});

  Future<void> cancelInvite(String athleteUid) =>
      _call('coachModeCancelInvite', {'athleteUid': athleteUid});

  Future<void> releaseAthlete(String athleteUid, {String reason = ''}) =>
      _call('coachModeReleaseAthlete', {
        'athleteUid': athleteUid,
        'reason': reason,
      });

  /// LEGACY: removal-only drop of a super-admin-seeded assignment. There is
  /// deliberately no "add" counterpart — only the super admin seeds.
  Future<void> removeSeededAthlete(String athleteUid, {String? coachUid}) =>
      _call('coachModeRemoveSeededAthlete', {
        'athleteUid': athleteUid,
        if (coachUid != null) 'coachUid': coachUid,
      });

  /// SOURCE-AWARE roster removal — what the Coach Dashboard uses.
  ///
  /// A pair can be authorised by several sources at once after migration. The
  /// server removes every source this coach may remove, then re-evaluates and
  /// returns the truth:
  ///   removedSources, failedSources, previousSources, remainingSources,
  ///   stillAuthorized
  /// so the UI never reports success while access remains.
  Future<Map<String, dynamic>> removeAthleteFromRoster(
    String athleteUid, {
    String reason = '',
  }) =>
      _call('coachModeRemoveAthleteFromRoster', {
        'athleteUid': athleteUid,
        'reason': reason,
      });

  // ── Athlete: respond / revoke ─────────────────────────────────────────────

  Future<void> acceptInvite(String coachUid) => _call(
        'coachModeRespondToInvite',
        {'coachUid': coachUid, 'action': 'accept'},
      );

  Future<void> declineInvite(String coachUid) => _call(
        'coachModeRespondToInvite',
        {'coachUid': coachUid, 'action': 'decline'},
      );

  Future<void> revokeCoach(String coachUid, {String reason = ''}) => _call(
        'coachModeRevokeCoach',
        {'coachUid': coachUid, 'reason': reason},
      );

  // ── Super admin ───────────────────────────────────────────────────────────

  /// Applications awaiting review, newest first. Readable only by the super
  /// admin (and each applicant's own document).
  Stream<List<CoachApplication>> watchApplicationsByStatus(String status) {
    return _db
        .collection(kColCoachApplications)
        .where('status', isEqualTo: status)
        .orderBy('submittedAt', descending: true)
        .snapshots()
        .map((q) => q.docs
            .map((d) => CoachApplication.fromMap(d.id, d.data(), toDate: _toDate))
            .toList());
  }

  /// Coaches with an entitlement in the given state, enriched with the
  /// invitation-safe display name/email from coachProfiles so the super-admin
  /// list is searchable by person rather than only by UID.
  ///
  /// The profile lookup is best-effort: a coach with no profile document still
  /// appears, identified by UID.
  Stream<List<CoachProfileSummary>> watchCoachesByState(String state) {
    return _db
        .collection(kColAccountEntitlements)
        .where('coach.state', isEqualTo: state)
        .snapshots()
        .asyncMap((q) async {
      final summaries = q.docs.map((d) {
        final data = d.data();
        final coach = data['coach'] is Map
            ? Map<String, dynamic>.from(data['coach'] as Map)
            : const <String, dynamic>{};
        return CoachProfileSummary(
          uid: d.id,
          entitlement: CoachEntitlement.fromMap(data),
          source: coachEntitlementSourceFrom(coach['source']),
        );
      }).toList();

      final profiles = await Future.wait(
        summaries.map((s) => fetchCoachProfile(s.uid)),
      );

      final enriched = <CoachProfileSummary>[];
      for (var i = 0; i < summaries.length; i++) {
        final p = profiles[i];
        enriched.add(summaries[i].withProfile(
          displayName: p?.displayName ?? '',
          email: p?.email ?? '',
        ));
      }
      enriched.sort((a, b) =>
          a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return enriched;
    });
  }

  /// Limited, invitation-safe coach identity. Returns null when unreadable.
  Future<CoachProfileInfo?> fetchCoachProfile(String coachUid) async {
    try {
      final s = await _db.collection(kColCoachProfiles).doc(coachUid).get();
      final d = s.data();
      if (d == null) return null;
      return CoachProfileInfo(
        uid: coachUid,
        displayName: (d['displayName'] ?? '').toString(),
        email: (d['email'] ?? '').toString(),
        photoUrl: (d['photoUrl'] ?? '').toString(),
      );
    } catch (e) {
      debugPrint('⚠️ [CoachMode] coach profile read failed for $coachUid: $e');
      return null;
    }
  }

  Future<void> approveApplication(String applicantUid, {String reason = ''}) =>
      _call('coachModeReviewApplication', {
        'applicantUid': applicantUid,
        'action': 'approve',
        'reason': reason,
      });

  Future<void> declineApplication(String applicantUid, {required String reason}) =>
      _call('coachModeReviewApplication', {
        'applicantUid': applicantUid,
        'action': 'decline',
        'reason': reason,
      });

  Future<void> requestMoreInfo(String applicantUid, {required String reason}) =>
      _call('coachModeReviewApplication', {
        'applicantUid': applicantUid,
        'action': 'request_info',
        'reason': reason,
      });

  Future<Map<String, dynamic>> lookupAccount(String email) =>
      _call('coachModeAdminLookupAccount', {'email': email});

  Future<void> grantCoach({String? targetUid, String? email, String reason = ''}) =>
      _call('coachModeGrantCoach', {
        if (targetUid != null) 'targetUid': targetUid,
        if (email != null) 'email': email,
        'reason': reason,
      });

  Future<void> suspendCoach(String targetUid, {required String reason}) =>
      _call('coachModeSetCoachState', {
        'targetUid': targetUid,
        'action': 'suspend',
        'reason': reason,
      });

  Future<void> revokeCoachMode(String targetUid, {required String reason}) =>
      _call('coachModeSetCoachState', {
        'targetUid': targetUid,
        'action': 'revoke',
        'reason': reason,
      });

  Future<void> restoreCoach(String targetUid, {String reason = ''}) =>
      _call('coachModeSetCoachState', {
        'targetUid': targetUid,
        'action': 'restore',
        'reason': reason,
      });
}

@immutable
class CoachProfileInfo {
  final String uid;
  final String displayName;
  final String email;
  final String photoUrl;
  const CoachProfileInfo({
    required this.uid,
    this.displayName = '',
    this.email = '',
    this.photoUrl = '',
  });

  String get label {
    if (displayName.trim().isNotEmpty) return displayName.trim();
    if (email.trim().isNotEmpty) return email.trim();
    return uid;
  }
}

@immutable
class CoachProfileSummary {
  final String uid;
  final CoachEntitlement entitlement;
  final CoachEntitlementSource source;
  final String displayName;
  final String email;

  const CoachProfileSummary({
    required this.uid,
    required this.entitlement,
    required this.source,
    this.displayName = '',
    this.email = '',
  });

  CoachProfileSummary withProfile({
    required String displayName,
    required String email,
  }) =>
      CoachProfileSummary(
        uid: uid,
        entitlement: entitlement,
        source: source,
        displayName: displayName,
        email: email,
      );

  /// Best human label, falling back to the UID.
  String get label {
    if (displayName.trim().isNotEmpty) return displayName.trim();
    if (email.trim().isNotEmpty) return email.trim();
    return uid;
  }

  /// Does this coach match a free-text super-admin search?
  /// Matches name, email or UID, case-insensitively.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return displayName.toLowerCase().contains(q) ||
        email.toLowerCase().contains(q) ||
        uid.toLowerCase().contains(q);
  }
}
