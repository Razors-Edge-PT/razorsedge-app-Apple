// Single source of truth for "which athletes can this coach act on?".
//
// Both the Coach Dashboard (CoachHomeScreen) and the Coach Check-ins screens
// load their roster through here so they can never diverge again. The rules
// implemented match firestore.rules `isCoachFor()` and the backend
// functions/coach/authz.js exactly:
//
//   • super-admin    → every user document (effectively coach for all
//                      athletes; no assignment document required)
//   • ordinary coach → CANONICAL: coachAthleteLinks where coachUid == {uid}
//                      and status == 'active'
//                      PLUS LEGACY: athleteAssignments where
//                      coaches.{uid}.approved == true, and super-admin-seeded
//                      coachAssignments/{uid}.athletes
//
// The canonical source is what all new UI and Cloud Functions write; the two
// legacy sources are kept for the compatibility release only (see
// docs/coach_mode.md for the retirement sequence).
//
// Ordinary-coach authorisation is NOT widened by this file. Reporting is
// never enabled here — the roster is only a list of candidates.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'coach_mode/coach_mode_models.dart';
import 'user_context.dart';

@immutable
class CoachAthlete {
  final String uid;
  final String username;
  final String displayName;
  final String fullName;
  final String email;

  const CoachAthlete({
    required this.uid,
    this.username = '',
    this.displayName = '',
    this.fullName = '',
    this.email = '',
  });

  /// Best human label, falling back through the same order the Coach
  /// Dashboard has always used.
  String get label {
    for (final v in [username, displayName, fullName, email]) {
      if (v.trim().isNotEmpty) return v.trim();
    }
    return uid;
  }

  String get sortKey => label.toLowerCase();

  Map<String, dynamic> toLegacyMap() => {
        'username': username,
        'displayName': displayName,
        'fullName': fullName,
        'email': email,
      };
}

class CoachRoster {
  CoachRoster._();

  /// Coerces any Firestore value to a String without ever throwing.
  ///
  /// Legacy/malformed user documents in production hold non-string values in
  /// these fields (numbers, maps, null). The previous `as String` casts threw,
  /// which discarded the ENTIRE roster; a single bad record must only affect
  /// its own entry.
  static String safeString(dynamic v) {
    if (v == null) return '';
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return ''; // maps/lists/anything else are not a usable name
  }

  /// Builds one athlete from a users/{uid} document, tolerating bad data.
  static CoachAthlete fromUserDoc(String uid, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    return CoachAthlete(
      uid: uid,
      username: safeString(d['username']),
      displayName: safeString(d['displayName']),
      fullName: safeString(d['fullName']),
      email: safeString(d['email']),
    );
  }

  /// Merges a seeded coachAssignments entry with an optional user document.
  /// User-document values win; the seeded entry (usually just an email) fills
  /// gaps so a seeded athlete is never shown as a bare UID.
  static CoachAthlete mergeSeeded(
    String uid,
    Map<String, dynamic>? seededEntry,
    Map<String, dynamic>? userData,
  ) {
    final fromUser = fromUserDoc(uid, userData);
    final seeded = seededEntry ?? const <String, dynamic>{};
    String pick(String a, dynamic b) => a.isNotEmpty ? a : safeString(b);
    return CoachAthlete(
      uid: uid,
      username: pick(fromUser.username, seeded['username']),
      displayName: pick(fromUser.displayName, seeded['displayName']),
      fullName: pick(fromUser.fullName, seeded['fullName']),
      email: pick(fromUser.email, seeded['email']),
    );
  }

  /// The authorised athlete UIDs for an ordinary coach, across every
  /// authorisation source. Pure so the authorisation shape stays unit-testable.
  ///
  /// Delegates to [composeAuthorisedAthleteUids] so the client uses the SAME
  /// rule as firestore.rules `isCoachFor()` and functions/coach/authz.js
  /// `evaluateAssignmentDetail()` — there is one implementation, not two.
  ///
  /// [terminalLinkAthleteUids] is what makes an athlete revocation or a coach
  /// release actually disappear from the dashboard: without it, a stale legacy
  /// approval kept the athlete listed even though the server denied every read
  /// (leaving a bare-UID row with an unusable Remove action).
  static Set<String> assignedUids({
    required Iterable<String> approvedAthleteUids,
    required Map<String, dynamic> seededAthletes,
    Iterable<String> activeLinkAthleteUids = const [],
    Iterable<String> terminalLinkAthleteUids = const [],
  }) {
    final links = <CoachAthleteLink>[
      for (final uid in activeLinkAthleteUids)
        CoachAthleteLink(
            id: uid, coachUid: '', athleteUid: uid,
            status: CoachLinkStatus.active),
      for (final uid in terminalLinkAthleteUids)
        CoachAthleteLink(
            id: uid, coachUid: '', athleteUid: uid,
            status: CoachLinkStatus.releasedByCoach),
    ];
    return composeAuthorisedAthleteUids(
      canonicalLinks: links,
      legacyApprovedUids: approvedAthleteUids,
      legacySeededUids: seededAthletes.keys,
    );
  }

  static List<CoachAthlete> sorted(Iterable<CoachAthlete> athletes) {
    final list = athletes.toList()
      ..sort((a, b) {
        final c = a.sortKey.compareTo(b.sortKey);
        return c != 0 ? c : a.uid.compareTo(b.uid);
      });
    return list;
  }
}

class CoachRosterService {
  final FirebaseFirestore _db;
  CoachRosterService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  /// Loads the roster this coach may act on.
  ///
  /// Resolved through [CoachRole], so the client mirrors the same precedence
  /// the server enforces in firestore.rules isCoachFor() and
  /// functions/coach/authz.js evaluateAssignmentDetail():
  ///
  ///   • super admin              → every user
  ///   • ACTIVE entitlement       → the assigned athletes
  ///   • suspended / revoked      → EMPTY, even when legacy assignments exist
  ///   • entitlement not yet loaded → provisionally the claim's answer
  ///
  /// The provisional case exists only so a real coach does not see an empty
  /// dashboard for the moment before the entitlement stream resolves; it is
  /// never a grant, because every underlying read is still gated by the rules.
  Future<List<CoachAthlete>> loadRoster(UserContext ctx) async {
    switch (ctx.coachRole) {
      case CoachRole.superAdmin:
        return _loadAllUsers();
      case CoachRole.coach:
        return _loadAssignedAthletes(ctx.actorUid);
      case CoachRole.athlete:
        debugPrint('ℹ️ [CoachRoster] no active Coach Mode — empty roster');
        return const <CoachAthlete>[];
    }
  }

  Future<List<CoachAthlete>> _loadAllUsers() async {
    final snap = await _db.collection('users').get();
    final out = <CoachAthlete>[];
    for (final doc in snap.docs) {
      try {
        out.add(CoachRoster.fromUserDoc(doc.id, doc.data()));
      } catch (e) {
        // One malformed record must never discard the whole roster.
        debugPrint('⚠️ [CoachRoster] skipping malformed user ${doc.id}: $e');
      }
    }
    return CoachRoster.sorted(out);
  }

  Future<List<CoachAthlete>> _loadAssignedAthletes(String coachUid) async {
    final approved = <String>{};
    final canonicalLinks = <CoachAthleteLink>[];
    Map<String, dynamic> seeded = {};

    // CANONICAL: ALL of this coach's links, not only the active ones.
    //
    // The terminal ones matter: a declined / cancelled / revoked_by_athlete /
    // released_by_coach link cancels a stale legacy approval, exactly as the
    // server does. Querying only status == 'active' left released athletes in
    // the roster whenever an old athleteAssignments approval survived the
    // migration — a row the coach could see but not read or remove.
    try {
      final q = await _db
          .collection(kColCoachAthleteLinks)
          .where('coachUid', isEqualTo: coachUid)
          .get();
      canonicalLinks.addAll(q.docs.map(
        (d) => CoachAthleteLink.fromMap(d.id, d.data()),
      ));
    } catch (e) {
      debugPrint('⚠️ [CoachRoster] coachAthleteLinks query failed: $e');
    }

    try {
      final q = await _db
          .collection('athleteAssignments')
          .where('coaches.$coachUid.approved', isEqualTo: true)
          .get();
      approved.addAll(q.docs.map((d) => d.id));
    } catch (e) {
      debugPrint('⚠️ [CoachRoster] athleteAssignments query failed: $e');
    }

    try {
      final doc = await _db.collection('coachAssignments').doc(coachUid).get();
      if (doc.exists) {
        seeded = Map<String, dynamic>.from(doc.data()?['athletes'] ?? {});
      }
    } catch (e) {
      debugPrint('⚠️ [CoachRoster] coachAssignments read failed: $e');
    }

    // One rule, shared with the server (see composeAuthorisedAthleteUids).
    final uids = composeAuthorisedAthleteUids(
      canonicalLinks: canonicalLinks,
      legacyApprovedUids: approved,
      legacySeededUids: seeded.keys,
    );

    final out = <CoachAthlete>[];
    await Future.wait(uids.map((uid) async {
      Map<String, dynamic>? userData;
      try {
        final u = await _db.collection('users').doc(uid).get();
        userData = u.data();
      } catch (e) {
        debugPrint('⚠️ [CoachRoster] user read failed for $uid: $e');
      }
      final seededEntry = seeded[uid];
      out.add(CoachRoster.mergeSeeded(
        uid,
        seededEntry is Map ? Map<String, dynamic>.from(seededEntry) : null,
        userData,
      ));
    }));

    return CoachRoster.sorted(out);
  }
}
