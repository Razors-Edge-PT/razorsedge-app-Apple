/// Device-local record of a signup whose account may exist but whose setup
/// has not been verified complete.
///
/// It lets setup resume after the app is terminated — including in the
/// window where account creation was requested but its uid never reached the
/// app — and lets AppRoot trust that account on this device despite an
/// earlier explicit logout (the marker was written by this device's own
/// signup after that logout).
///
/// Stored: an attempt id, the start time, a SHA-256 hash of the lower-cased
/// email (never the email itself) and, once known, the uid. NEVER the
/// password or any answer.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

String signupEmailHash(String email) =>
    sha256.convert(utf8.encode(email.trim().toLowerCase())).toString();

class LocalSignupMarker {
  const LocalSignupMarker({
    required this.attemptId,
    required this.startedAt,
    required this.emailHash,
    this.uid,
  });

  final String attemptId;
  final DateTime startedAt;
  final String emailHash;
  final String? uid;

  LocalSignupMarker withUid(String uid) => LocalSignupMarker(
      attemptId: attemptId, startedAt: startedAt, emailHash: emailHash, uid: uid);

  Map<String, Object?> toJson() => {
        'attemptId': attemptId,
        'startedAt': startedAt.toUtc().millisecondsSinceEpoch,
        'emailHash': emailHash,
        if (uid != null) 'uid': uid,
      };

  static LocalSignupMarker? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['attemptId'];
    final at = raw['startedAt'];
    final hash = raw['emailHash'];
    if (id is! String || at is! int || hash is! String) return null;
    final uid = raw['uid'];
    return LocalSignupMarker(
      attemptId: id,
      startedAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      emailHash: hash,
      uid: uid is String ? uid : null,
    );
  }
}

abstract class SignupPendingStore {
  Future<LocalSignupMarker?> read();
  Future<void> write(LocalSignupMarker marker);
  Future<void> clear();

  /// Accounts known not to need signup recovery (completed, or verified as
  /// not a pending signup), so AppRoot never re-checks them.
  Future<bool> isSettled(String uid);
  Future<void> markSettled(String uid);
}

class PrefsSignupPendingStore implements SignupPendingStore {
  static const _kMarker = 'goodlift_signup_pending';
  static const _kSettledPrefix = 'goodlift_signup_settled_';

  @override
  Future<LocalSignupMarker?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kMarker);
    if (raw == null) return null;
    try {
      return LocalSignupMarker.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(LocalSignupMarker marker) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMarker, jsonEncode(marker.toJson()));
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kMarker);
  }

  @override
  Future<bool> isSettled(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_kSettledPrefix$uid') ?? false;
  }

  @override
  Future<void> markSettled(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_kSettledPrefix$uid', true);
  }
}

/// In-memory store for coordinators built without persistence (tests).
class MemorySignupPendingStore implements SignupPendingStore {
  LocalSignupMarker? marker;
  final Set<String> settled = <String>{};

  @override
  Future<LocalSignupMarker?> read() async => marker;
  @override
  Future<void> write(LocalSignupMarker m) async => marker = m;
  @override
  Future<void> clear() async => marker = null;
  @override
  Future<bool> isSettled(String uid) async => settled.contains(uid);
  @override
  Future<void> markSettled(String uid) async => settled.add(uid);
}
