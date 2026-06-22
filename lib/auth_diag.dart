import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_debug.dart';

/// TEMPORARY auth-persistence diagnostics for Internal Testing / TestFlight.
///
/// Proves WHERE the native Firebase session is lost across cold start by logging
/// presence/identity-of-project — never secrets. Set to `false` before any
/// public production rollout (then every call is a cheap no-op).
///
/// NEVER logs: passwords, access/ID/refresh tokens, Apple authorization codes,
/// private keys, or full email addresses. Firebase UIDs are reduced to
/// presence. Project/app IDs are compiled into the binary and are not secrets.
const bool kEnableAuthDiag = true;

const String _kExplicitLogout = 'goodlift_explicit_logout';
const String _kLastLoginProvider = 'goodlift_last_login_provider';

String _redactUid(String? uid) => uid == null ? 'none' : 'present';

void _log(String msg) {
  if (!kEnableAuthDiag) return;
  debugPrint('[AUTHDIAG] $msg');
  // ignore: discarded_futures
  writeAuthBreadcrumb('AUTHDIAG $msg');
}

class AuthDiag {
  AuthDiag._();

  /// Immediately after `Firebase.initializeApp()` on a (possibly new) process:
  /// project id, app id, currentUser presence, last provider, explicit-logout.
  /// Fire-and-forget — must never block startup.
  static Future<void> afterFirebaseInit() async {
    if (!kEnableAuthDiag) return;
    String projectId = 'unknown';
    String appId = 'unknown';
    try {
      final opts = Firebase.app().options;
      projectId = opts.projectId;
      appId = opts.appId;
    } catch (_) {}
    final user = FirebaseAuth.instance.currentUser;
    String lastProvider = 'unknown';
    bool explicitLogout = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      lastProvider = prefs.getString(_kLastLoginProvider) ?? 'none';
      explicitLogout = prefs.getBool(_kExplicitLogout) ?? false;
    } catch (_) {}
    _log('postInit projectId=$projectId appId=$appId '
        'currentUser=${_redactUid(user?.uid)} lastProvider=$lastProvider '
        'explicitLogout=$explicitLogout');
  }

  /// Immediately after a successful interactive login.
  static void afterLogin({required String provider, required String? uid}) {
    if (!kEnableAuthDiag) return;
    String projectId = 'unknown';
    String appId = 'unknown';
    try {
      final opts = Firebase.app().options;
      projectId = opts.projectId;
      appId = opts.appId;
    } catch (_) {}
    _log('login provider=$provider uid=${_redactUid(uid)} '
        'currentUserNonNull=${FirebaseAuth.instance.currentUser != null} '
        'projectId=$projectId appId=$appId');
  }

  /// App lifecycle transition with the current Firebase UID presence.
  static void lifecycle(String state) {
    if (!kEnableAuthDiag) return;
    _log('lifecycle=$state '
        'currentUser=${_redactUid(FirebaseAuth.instance.currentUser?.uid)}');
  }
}
