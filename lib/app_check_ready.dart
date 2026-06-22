/// Central App Check readiness helper.
///
/// Firebase requires App Check to be *activated* before any Firebase service is
/// used. [initAppCheck] invokes `FirebaseAppCheck.instance.activate(...)`
/// synchronously (the provider is registered before [initAppCheck] returns and
/// — because it is called before `runApp` — before any widget builds or any
/// Firestore request/stream can start). The Firestore SDK then attaches App
/// Check tokens to all subsequent reads/writes/listeners, fetching the token
/// asynchronously and holding the request until it is available.
///
/// [appCheckReady] is a *retained* future that additionally lets awaitable
/// startup operations make the first-token ordering explicit. It:
///   • never throws — all activation errors/timeouts are caught and logged,
///   • never hangs — activation is bounded (see [_activationTimeout]),
///   • always *settles*, so any `await appCheckReady` unblocks.
///
/// Guarantee: protected ops that `await appCheckReady` wait for activation to
/// **settle** (succeed, fail, or time out) — NOT for it to succeed. On a failed
/// or timed-out activation the op proceeds without a guaranteed token; if
/// server-side enforcement rejects it, that op's existing error handling
/// (retry / error state / silent failure) applies. The app never deadlocks on
/// a stalled Play Integrity / DeviceCheck attestation.
///
/// Local SharedPreferences and Isar operations MUST NOT await this future.
library;

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

import 'startup_trace.dart';

/// TEMPORARY kill-switch for Firebase App Check.
///
/// Set to `false` to skip `FirebaseAppCheck.instance.activate()` entirely:
/// [appCheckReady] then resolves immediately so no `await appCheckReady` caller
/// waits on Play Integrity / DeviceCheck attestation. The full Android Play
/// Integrity + iOS DeviceCheck/App Attest implementation below is preserved and
/// re-enabled simply by flipping this back to `true`.
///
/// Currently disabled because Play Integrity returns `API_NOT_AVAILABLE` on some
/// devices, adding seconds to cold start. App Check *enforcement* is off
/// server-side, so disabled activation changes nothing functionally — Firestore
/// reads/writes already succeed without a token.
const bool kEnableAppCheck = false;

/// Bound on activation so a stalled attestation can never strand startup.
const Duration _activationTimeout = Duration(seconds: 15);

Future<void>? _appCheckReady;

/// Resolves when App Check activation has settled. Defaults to an immediately
/// completed future if [initAppCheck] was never called (defensive — tests,
/// hot-reload edge cases) so callers never hang.
Future<void> get appCheckReady => _appCheckReady ?? Future<void>.value();

/// Invokes App Check activation and retains the readiness future.
///
/// Call ONCE from `main()` BEFORE `runApp` and do NOT await it: the synchronous
/// `activate()` call registers the provider; the returned future only completes
/// when the first token attempt settles.
Future<void> initAppCheck() {
  // Kill-switch: skip activation and resolve readiness immediately. Every
  // `await appCheckReady` caller proceeds without waiting on attestation. No
  // error is surfaced; Firebase Auth / Firestore / routing are untouched.
  if (!kEnableAppCheck) {
    debugPrint('⏭️ [AppCheck] disabled via kEnableAppCheck — skipping activate()');
    StartupTrace.appCheckDisabled();
    final ready = Future<void>.value();
    _appCheckReady = ready;
    return ready;
  }

  // Activation is genuinely being attempted — emit the invoked mark here (NOT
  // in main) so it is never emitted when activation was skipped above.
  StartupTrace.appCheckInvoked();
  final future = () async {
    try {
      await FirebaseAppCheck.instance
          .activate(
            androidProvider:
                kReleaseMode ? AndroidProvider.playIntegrity : AndroidProvider.debug,
            appleProvider:
                kReleaseMode ? AppleProvider.deviceCheck : AppleProvider.debug,
          )
          .timeout(_activationTimeout);
      debugPrint('✅ [AppCheck] activation settled');
    } catch (e) {
      // Swallowed — never rethrown. A bare try/catch around a non-awaited
      // future would NOT catch async rejections; this wrapper does.
      debugPrint('❌ [AppCheck] activate failed/timed out: $e');
    } finally {
      StartupTrace.appCheckSettled();
    }
  }();
  _appCheckReady = future;
  return future;
}
