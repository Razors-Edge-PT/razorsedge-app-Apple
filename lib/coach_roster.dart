// Single source of truth for "which athletes can this coach act on?".
//
// Both the Coach Dashboard (CoachHomeScreen) and the Coach Check-ins screens
// load their roster through here so they can never diverge again. The rules
// implemented match firestore.rules `isCoachFor()` and the backend
// functions/coach/authz.js exactly:
//
//   • super-admin  → every user document (effectively coach for all athletes;
//                    no assignment document required)
//   • ordinary coach → athleteAssignments where coaches.{uid}.approved == true
//                      PLUS admin-seeded coachAssignments/{uid}.athletes
//
// Ordinary-coach authorisation is NOT widened by this file. Reporting is
// never enabled here — the roster is only a list of candidates.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

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

  /// The authorised athlete UIDs for an ordinary coach, from the two
  /// assignment sources. Pure so the authorisation shape stays unit-testable.
  static Set<String> assignedUids({
    required Iterable<String> approvedAthleteUids,
    required Map<String, dynamic> seededAthletes,
  }) {
    return <String>{...approvedAthleteUids, ...seededAthletes.keys};
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

  /// Loads the roster this coach may act on. Super-admin gets every user;
  /// everyone else gets exactly their approved + seeded assignments.
  Future<List<CoachAthlete>> loadRoster(UserContext ctx) async {
    if (ctx.isSuperAdmin) return _loadAllUsers();
    return _loadAssignedAthletes(ctx.actorUid);
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
    Map<String, dynamic> seeded = {};

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

    final uids = CoachRoster.assignedUids(
      approvedAthleteUids: approved,
      seededAthletes: seeded,
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
