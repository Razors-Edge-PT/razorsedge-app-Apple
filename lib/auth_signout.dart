import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_debug.dart';

/// Fixed reason codes for every INTENTIONAL sign-out. Centralizing all sign-out
/// calls behind [performSignOut] guarantees no sign-out path is silent — each
/// one is logged with its reason + caller, so an Internal-Testing build can
/// prove that a logged-out password/Apple user was NOT signed out by app code.
enum SignOutReason {
  /// User tapped Logout in the app drawer.
  explicitLogoutDrawer,

  /// User tapped Logout on the membership/paywall screen.
  explicitLogoutPaywall,

  /// Account deletion flow (after `currentUser.delete()`).
  accountDeletion,

  /// New-account creation failed; rolling back the half-created user.
  accountCreationCleanup,

  /// A stale/unexpected Firebase user arrived AFTER an explicit logout
  /// (valid_user_gate) and is being signed back out.
  staleUserAfterExplicitLogout,

  /// A silent-restore credential exchange completed AFTER an explicit logout
  /// and is being abandoned (signed back out).
  lateSilentRestoreAbandon,

  /// Google-only sign-out to force the account picker on the next interactive
  /// Google sign-in (does NOT touch the Firebase session).
  forceAccountPicker,
}

const String _kExplicitLogout = 'goodlift_explicit_logout';

String _redactUid(String? uid) => uid == null ? 'none' : 'present';

/// Centralized, instrumented sign-out. Logs reason/caller/provider-scope/
/// redacted-UID/explicit-logout state, then performs the requested sign-out(s).
///
/// NEVER logs passwords, tokens, Apple codes, or emails.
///
/// [google] / [firebase] select the provider scope so each call site keeps its
/// exact original behaviour (e.g. force-picker is Google-only; account deletion
/// is Firebase-only).
Future<void> performSignOut({
  required SignOutReason reason,
  required String caller,
  bool google = true,
  bool firebase = true,
}) async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  bool explicitLogout = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    explicitLogout = prefs.getBool(_kExplicitLogout) ?? false;
  } catch (_) {}

  final line = 'SIGNOUT reason=${reason.name} caller=$caller '
      'google=$google firebase=$firebase uid=${_redactUid(uid)} '
      'explicitLogout=$explicitLogout';
  debugPrint('[AUTHSIGNOUT] $line');
  unawaited(writeAuthBreadcrumb(line));

  if (google) {
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
  }
  if (firebase) {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
  }
}
