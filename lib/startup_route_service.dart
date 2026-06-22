import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The major screen the app should reopen into after a genuine cold restart.
enum StartupDestination { home, wes2 }

/// Persists which major route was last active, so a cold relaunch (process
/// death) can reopen directly into WES2 instead of forcing the user back to
/// Home and re-tapping into their half-finished workout.
///
/// Design:
///   • ONE UID-specific key (`goodlift_last_route_<uid>`) — a single atomic
///     write per update, naturally isolating accounts (no paired-write race).
///   • Only the marker value is stored ('home' | 'wes2'); never a Navigator
///     stack. Restored WES2 always opens today (the caller uses
///     `const Wes2Screen()`), never a remembered calendar date.
///   • Reads default to [StartupDestination.home] on any miss / parse error /
///     UID mismatch. SharedPreferences failures degrade to Home, never crash.
///
/// Lifecycle of the marker:
///   • 'wes2'  written when WES2 becomes the active route (WES2
///              didChangeDependencies, after UserContext is available).
///   • 'home'  written when the user deliberately leaves WES2 back to Home
///              (WES2 PopScope onPopInvoked) — NOT from dispose(), so process
///              death / OS termination never clears the WES2 marker.
///   • cleared on explicit logout and account deletion (current UID only).
class StartupRouteService {
  StartupRouteService._();

  static const String _prefix = 'goodlift_last_route_';
  static const String _home = 'home';
  static const String _wes2 = 'wes2';

  static String _key(String uid) => '$_prefix$uid';

  /// Marks Home as the last active major route for [uid]. Fire-and-forget.
  static Future<void> markHomeActive(String uid) => _write(uid, _home);

  /// Marks WES2 as the last active major route for [uid]. Fire-and-forget.
  static Future<void> markWes2Active(String uid) => _write(uid, _wes2);

  static Future<void> _write(String uid, String value) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(uid), value);
    } catch (e) {
      debugPrint('[StartupRoute] write failed: $e');
    }
  }

  /// Returns the destination to restore for [uid]. Account-isolated: only the
  /// matching UID's key is consulted. Defaults to Home on any miss/error.
  static Future<StartupDestination> readStartupDestination(String uid) async {
    if (uid.isEmpty) return StartupDestination.home;
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key(uid));
      return value == _wes2 ? StartupDestination.wes2 : StartupDestination.home;
    } catch (e) {
      debugPrint('[StartupRoute] read failed: $e');
      return StartupDestination.home;
    }
  }

  /// Clears the stored marker for [uid] (explicit logout / account deletion).
  static Future<void> clearForLogout(String uid) async {
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(uid));
    } catch (e) {
      debugPrint('[StartupRoute] clear failed: $e');
    }
  }
}
