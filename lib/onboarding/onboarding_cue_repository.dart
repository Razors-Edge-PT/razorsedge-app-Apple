import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'onboarding_cue.dart';

/// Result of a durable load: the cue map plus whether it came from the
/// authoritative server (true) or only the local cache / nothing (false).
class CueLoadResult {
  final Map<String, CueRecord> cues;
  final bool fromServer;
  const CueLoadResult({required this.cues, required this.fromServer});
}

/// Durable + cached storage contract for onboarding cue state.
/// Implemented by [FirestoreOnboardingCueRepository]; faked in tests.
abstract class OnboardingCueGateway {
  Future<CueLoadResult> load(String actorUid);

  Future<void> writeCueComplete({
    required String actorUid,
    required String cueId,
    required CueRecord record,
  });
}

/// Firestore-backed durable store with a SharedPreferences fast mirror.
///
/// Durable doc: `users/{actorUid}/onboarding/cue_state`, shape:
///   `{ cues: { cueId: { done: true, build: "40", completedAt: ts }, ... } }`
///
/// Writes are sibling-safe and idempotent: a transaction either creates the doc
/// (when missing) or updates ONLY the dotted field path `cues.<cueId>`, which
/// Firestore guarantees never touches other `cues.*` entries.
///
/// Local cache namespace is NEW (`obcue.v1.cues.<actorUid>`) — old
/// SharedPreferences onboarding keys are never read or migrated.
class FirestoreOnboardingCueRepository implements OnboardingCueGateway {
  final FirebaseFirestore _firestore;

  FirestoreOnboardingCueRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const String _cachePrefix = 'obcue.v1.cues.';
  String _cacheKey(String actorUid) => '$_cachePrefix$actorUid';

  DocumentReference<Map<String, dynamic>> _docRef(String actorUid) => _firestore
      .collection('users')
      .doc(actorUid)
      .collection('onboarding')
      .doc('cue_state');

  @override
  Future<CueLoadResult> load(String actorUid) async {
    // Seed from the local cache first so an offline launch still has state.
    final cached = await _readCache(actorUid);
    try {
      final snap = await _docRef(actorUid).get();
      final data = snap.data();
      final serverCues = _parseCues(data);
      // Server is authoritative on success — overwrite the cache (even if empty,
      // e.g. a deliberate reset), so stale local "done" flags cannot win.
      await _writeCache(actorUid, serverCues);
      return CueLoadResult(cues: serverCues, fromServer: true);
    } catch (_) {
      // Offline / transient error: fall back to cache, marked non-authoritative.
      return CueLoadResult(cues: cached, fromServer: false);
    }
  }

  @override
  Future<void> writeCueComplete({
    required String actorUid,
    required String cueId,
    required CueRecord record,
  }) async {
    // Update the local mirror first so the cue stays suppressed this session
    // even if the network write fails.
    await _mergeCache(actorUid, cueId, record);

    final ref = _docRef(actorUid);
    final value = <String, dynamic>{
      'done': record.done,
      if (record.build != null) 'build': record.build,
      'completedAt': FieldValue.serverTimestamp(),
    };

    // Transaction guarantees sibling safety + missing-doc handling:
    //  - missing doc  → create with just this cue.
    //  - existing doc → dotted-path update touches ONLY cues.<cueId>.
    await _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      if (!snap.exists) {
        txn.set(ref, {
          'cues': {cueId: value}
        });
      } else {
        txn.update(ref, {'cues.$cueId': value});
      }
    });
  }

  // ── Parsing ────────────────────────────────────────────────────────────────

  static Map<String, CueRecord> _parseCues(Map<String, dynamic>? data) {
    final raw = data?['cues'];
    if (raw is! Map) return {};
    final out = <String, CueRecord>{};
    raw.forEach((key, value) {
      if (value is Map) out['$key'] = CueRecord.fromMap(value);
    });
    return out;
  }

  // ── Local cache (SharedPreferences) ─────────────────────────────────────────

  Future<Map<String, CueRecord>> _readCache(String actorUid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString(_cacheKey(actorUid));
      if (str == null || str.isEmpty) return {};
      final decoded = jsonDecode(str);
      if (decoded is! Map) return {};
      final out = <String, CueRecord>{};
      decoded.forEach((key, value) {
        if (value is Map) {
          out['$key'] =
              CueRecord.fromCacheJson(Map<String, dynamic>.from(value));
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeCache(String actorUid, Map<String, CueRecord> cues) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = {for (final e in cues.entries) e.key: e.value.toCacheJson()};
      await prefs.setString(_cacheKey(actorUid), jsonEncode(map));
    } catch (_) {
      // Cache is best-effort; durability is Firestore's job.
    }
  }

  Future<void> _mergeCache(
      String actorUid, String cueId, CueRecord record) async {
    final current = await _readCache(actorUid);
    current[cueId] = record;
    await _writeCache(actorUid, current);
  }
}
