import 'package:flutter/foundation.dart';

/// Lightweight, non-blocking startup timing instrumentation.
///
/// Records named millisecond offsets from process start and debugPrints each
/// stamp. Pure in-memory + debugPrint — no awaits, no disk, no Firestore — so
/// it can never delay startup. Active only in debug/profile; in release every
/// call is a cheap no-op guard.
///
/// Distinguishes:
///   • "time to first Flutter frame"  (mark `firstFrame`)
///   • "time to correct page"         (mark `wes2FirstBuild` / `homeFirstBuild`)
///
/// Issue 5 (Home-under-WES2 competition): when WES2 is the restored root,
/// [homeInitUnderWes2] should NOT fire — if it does, the full Home screen is
/// being constructed beneath WES2 and materially competing with WES2 startup.
class StartupTrace {
  StartupTrace._();

  static final Stopwatch _sw = Stopwatch()..start();
  static bool get _enabled => kDebugMode || kProfileMode;

  /// Records a named event with its offset (ms) since first reference.
  static void mark(String event) {
    if (!_enabled) return;
    debugPrint('[StartupTrace] +${_sw.elapsedMilliseconds}ms  $event');
  }

  // Convenience named marks (call sites stay self-documenting).
  static void processStart() => mark('process_start');
  static void firebaseInitialized() => mark('firebase_initialized');
  static void appCheckInvoked() => mark('appcheck_activate_invoked');
  static void appCheckSettled() => mark('appcheck_ready_settled');
  static void runAppCalled() => mark('runApp_called');
  static void firstFrame() => mark('first_flutter_frame');
  static void cachedUserRead(String? uid) => mark('cached_currentUser=$uid');
  static void authenticatedSelected() => mark('authenticated_ui_selected');
  static void restoredDestination(String dest) =>
      mark('restored_destination=$dest');
  static void membershipUiSelected(String state) =>
      mark('membership_ui=$state');
  static void wes2FirstBuild() => mark('wes2_first_build');
  static void wes2LoadStart() => mark('wes2_loadDay_start');
  static void wes2LoadComplete() => mark('wes2_loadDay_complete');
  static void homeFirstBuild() => mark('home_first_build');

  /// Fires only if the full Home screen initializes beneath a restored WES2
  /// root. Expected to be ABSENT in the restore-to-WES2 path (Issue 5).
  static void homeInitUnderWes2() => mark('⚠️ home_init_under_wes2');
}
