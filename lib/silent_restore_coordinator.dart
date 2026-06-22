import 'dart:async';

/// Pure, Firebase-agnostic concurrency utilities for cold-start silent auth
/// restoration.
///
/// Extracted from `_AppRootState` so the concurrency-critical behaviour is
/// unit-testable without Firebase singletons. AppRoot supplies the
/// Firebase-typed callbacks; these helpers own the shared-attempt / race /
/// abandonment semantics that the tests exercise directly.

/// Shares a single in-flight restoration attempt across concurrent callers.
///
/// The FIRST caller's future is stored and returned to every later caller while
/// it runs, so a concurrent caller never receives a synchronous null that a
/// race would misread as "restoration failed". The handle is cleared only after
/// the underlying attempt genuinely settles.
class SharedRestoreAttempt<T> {
  Future<T?>? _inFlight;

  /// Returns the in-flight attempt if one is running, otherwise starts a new
  /// one via [start] and shares it.
  Future<T?> run(Future<T?> Function() start) {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = start();
    _inFlight = future;
    // Clear the stored handle ONLY after the underlying attempt genuinely
    // settles. identical() guard so a newer attempt stored meanwhile is never
    // cleared by an older whenComplete.
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  bool get isRunning => _inFlight != null;

  /// Invalidates the shared handle (e.g. on explicit logout) so a later attempt
  /// starts fresh. Any in-flight attempt continues but must self-abandon via its
  /// own post-exchange logout re-check (see [runAbandonAwareRestore]).
  void invalidate() => _inFlight = null;
}

/// Races a native and an optional google restoration lane.
///
/// Completes with the FIRST valid (non-null) value. Completes null only when
/// every started lane has settled as failure. [budget] is a backstop, but it
/// NEVER completes null while the google lane is still unsettled — the google
/// credential exchange cannot be cancelled, so a late success must be allowed to
/// win rather than letting a premature null route to Login.
Future<T?> raceRestore<T>({
  required Future<T?> native,
  Future<T?>? google,
  required Duration budget,
  void Function()? onNativeWon,
  void Function()? onGoogleWon,
}) {
  final completer = Completer<T?>();
  var remaining = 1 + (google != null ? 1 : 0);
  // True while the google lane has not yet genuinely settled. Because the google
  // lane awaits its credential exchange to genuine completion, "unsettled"
  // includes an in-flight (uncancellable) native credential exchange.
  var googlePending = google != null;
  Timer? budgetTimer;

  void settle(T? value, {required bool fromGoogle}) {
    if (fromGoogle) googlePending = false;
    if (completer.isCompleted) return;
    if (value != null) {
      (fromGoogle ? onGoogleWon : onNativeWon)?.call();
      budgetTimer?.cancel();
      completer.complete(value);
      return;
    }
    remaining--;
    if (remaining <= 0) {
      budgetTimer?.cancel();
      completer.complete(null);
    }
  }

  unawaited(native
      .then((u) => settle(u, fromGoogle: false))
      .catchError((_) => settle(null, fromGoogle: false)));
  if (google != null) {
    unawaited(google
        .then((u) => settle(u, fromGoogle: true))
        .catchError((_) => settle(null, fromGoogle: true)));
  }

  budgetTimer = Timer(budget, () {
    if (completer.isCompleted) return;
    // Never route to failure (Login) while the google lane is still unsettled:
    // a native credential exchange may be in flight and cannot be cancelled, and
    // a late success would otherwise flip Login→Home.
    if (googlePending) return;
    completer.complete(null);
  });

  return completer.future;
}

/// Runs an abandonment-aware silent restoration sequence:
///   (1) abort if explicit logout BEFORE starting;
///   (2) bounded [acquire] (the caller bounds it with timeouts);
///   (3) abort if explicit logout immediately BEFORE the credential exchange;
///   (4) GENUINE [exchange] (the caller MUST NOT timeout-bound it — a Dart
///       `.timeout()` cannot cancel the native sign-in, and abandoning it while
///       it later succeeds would flip Login→Home);
///   (5) if an explicit logout landed DURING the exchange, [signOutLateCompletion]
///       and report failure — the user is never silently signed back in.
///
/// Returns the restored value, or null on any abort/failure/abandonment.
Future<T?> runAbandonAwareRestore<T, A>({
  required Future<bool> Function() isExplicitLogout,
  required Future<A?> Function() acquire,
  required Future<T?> Function(A acquired) exchange,
  required Future<void> Function() signOutLateCompletion,
}) async {
  if (await isExplicitLogout()) return null; // (1)
  final acquired = await acquire(); // (2) bounded by caller
  if (acquired == null) return null;
  if (await isExplicitLogout()) return null; // (3)
  final value = await exchange(acquired); // (4) genuine — not timeout-bounded
  if (value == null) return null;
  if (await isExplicitLogout()) {
    // (5) stale success landed after an explicit logout → sign back out.
    await signOutLateCompletion();
    return null;
  }
  return value;
}
