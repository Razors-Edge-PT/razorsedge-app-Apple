import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// TEMPORARY diagnostics flag.
///
/// Controls ALL startup tracing (Logcat + persisted summary). It is fine to
/// leave this `true` for a Play **Internal Testing** build so timings can be
/// inspected, but it MUST be set to `false` before any public production
/// rollout. When `false`, every StartupTrace call is a cheap no-op and nothing
/// is written to Logcat or SharedPreferences.
const bool kEnableStartupTrace = true;

/// Lightweight, non-blocking startup timing instrumentation.
///
/// Design (Internal-Testing/production safe):
///   • Marks are kept in memory; nothing is written per mark.
///   • Persistence to SharedPreferences is **debounced** (coalesced) and also
///     flushed at useful completion points (Home/WES2 reaching first build /
///     load complete).
///   • A monotonically-growing mark count guards every write so a concurrent
///     flush can never overwrite a newer summary with an older one.
///   • Raw Firebase UIDs are never logged or persisted — only redacted
///     presence/absence. Block document ids (not user identifiers) are kept.
///
/// All gated behind [kEnableStartupTrace].
class StartupTrace {
  StartupTrace._();

  static const String prefsKey = 'goodlift_last_startup_trace';
  static const Duration _debounce = Duration(milliseconds: 500);

  static final Stopwatch _sw = Stopwatch()..start();
  static final List<String> _marks = <String>[];

  // Persistence bookkeeping — guards against stale overwrites + concurrency.
  static int _persistedCount = 0;
  static bool _persisting = false;
  static Timer? _debounceTimer;

  /// Records a named event with its offset (ms). Stays in memory; schedules a
  /// debounced persist. No SharedPreferences write is started per mark.
  static void mark(String event) {
    if (!kEnableStartupTrace) return;
    final line = '+${_sw.elapsedMilliseconds}ms  $event';
    _marks.add(line);
    debugPrint('[StartupTrace] $line');
    _scheduleFlush();
  }

  static void _scheduleFlush() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => unawaited(_flush()));
  }

  /// Persists immediately (still guarded). Call at completion points so the
  /// final summary is durable even if the process is about to be backgrounded.
  static void flush() {
    if (!kEnableStartupTrace) return;
    _debounceTimer?.cancel();
    unawaited(_flush());
  }

  static Future<void> _flush() async {
    if (!kEnableStartupTrace) return;
    if (_persisting) return; // a write is already in flight
    final snapshotCount = _marks.length;
    if (snapshotCount <= _persistedCount) return; // nothing newer to write
    _persisting = true;
    final summary = _marks.join('\n');
    try {
      final prefs = await SharedPreferences.getInstance();
      // Re-check under the in-flight guard: only advance if still newest.
      if (snapshotCount > _persistedCount) {
        await prefs.setString(prefsKey, summary);
        _persistedCount = snapshotCount;
      }
    } catch (_) {
      // Diagnostics only — swallow everything.
    } finally {
      _persisting = false;
    }
  }

  /// Returns the most recent persisted startup summary (for an on-device
  /// diagnostics view), or null if disabled/none/failure.
  static Future<String?> lastSummary() async {
    if (!kEnableStartupTrace) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(prefsKey);
    } catch (_) {
      return null;
    }
  }

  // ── Convenience named marks (UIDs redacted) ────────────────────────────────
  static void processStart() => mark('process_start');
  static void firebaseInitialized() => mark('firebase_initialized');
  static void appCheckInvoked() => mark('appcheck_activate_invoked');
  static void appCheckSettled() => mark('appcheck_ready_settled');
  static void appCheckDisabled() => mark('appcheck_disabled');

  // ── Cold-auth restoration race (Google graceful degradation) ───────────────
  static void nativeRestoreStarted() => mark('native_restore_started');
  static void silentGoogleStarted() => mark('silent_google_started');
  static void nativeRestoreWon() => mark('native_restore_won');
  static void silentGoogleWon() => mark('silent_google_won');
  static void restoreFailedOrTimedOut() => mark('restore_failed_or_timed_out');
  static void runAppCalled() => mark('runApp_called');
  static void firstFrame() => mark('first_flutter_frame');
  static void cachedUserRead(String? uid) =>
      mark('cached_currentUser=${uid == null ? "none" : "present"}');
  static void userContextCreated() => mark('usercontext_created');
  static void blockMetaHydrateStart() => mark('blockmeta_hydrate_start');
  // blockId is a Firestore block document id, not a Firebase user UID.
  static void blockMetaHydrateDone(String? blockId) =>
      mark('blockmeta_hydrate_done activeBlockId=${blockId ?? "none"}');
  static void authenticatedSelected() => mark('authenticated_ui_selected');
  static void restoredDestination(String dest) =>
      mark('restored_destination=$dest');
  static void membershipUiSelected(String state) => mark('membership_ui=$state');

  static void homeFirstBuild() {
    mark('home_first_build');
    flush(); // useful completion point
  }

  static void homeStartupDecision(bool existingUser) {
    mark('home_decision=${existingUser ? "existing_user" : "new_user"}');
    flush();
  }

  static void firstTimeSetupEntered() {
    mark('⚠️ first_time_setup_entered');
    flush();
  }

  static void wes2FirstBuild() => mark('wes2_first_build');
  static void wes2LoadStart() => mark('wes2_loadDay_start');

  static void wes2LoadComplete() {
    mark('wes2_loadDay_complete');
    flush();
  }

  /// Fires only if the full Home screen initializes beneath a restored WES2
  /// root. Expected to be ABSENT in the restore-to-WES2 path.
  static void homeInitUnderWes2() => mark('⚠️ home_init_under_wes2');
}
