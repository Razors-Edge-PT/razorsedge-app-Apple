import 'dart:async';

import 'package:flutter/widgets.dart';

/// Outcome of a WES2 deliberate-exit attempt. Exposed so production logging and
/// tests can assert which branch ran without reimplementing the logic.
enum Wes2ExitAction {
  /// A route existed beneath WES2 — popped exactly once to the actual previous
  /// route (Home, BB3, or whatever pushed WES2). Used by Back / system Back.
  poppedToPrevious,

  /// A route named [homeRouteName] existed beneath WES2 — popped straight back
  /// to that existing Home route (BB3/WES2 removed from above it, no duplicate
  /// Home created). Used by the direct-Home logo.
  poppedToHome,

  /// WES2 was the restored root route — replaced with the Home route.
  replacedWithHome,

  /// A second exit was already in flight; this call was ignored by the guard.
  skippedAlreadyExiting,

  /// The widget unmounted during the focus-yield window — no navigation.
  skippedUnmounted,

  /// Navigation threw; the guard was reset so the screen is not locked.
  failed,
}

/// Coordinates the single authoritative WES2 deliberate-exit sequence.
///
/// Extracted from `Wes2Screen` so the real guard, ordering, and navigation
/// decision run identically in production and in tests: production
/// `_exitToPreviousRoute` / `_exitDirectlyToHome` delegate straight to
/// [exitToPreviousRoute] / [exitDirectlyToHome], so a test that drives those
/// cannot pass while the real exit path is broken.
///
/// Ordering contract (shared by both intents, owned by [_run]):
///   1. `dropFocus` runs first. In production it unfocuses the primary focus,
///      which fires the still-mounted WES2 field's focus-loss listener (the
///      existing `onFieldUnfocused` save, exactly once) and dismisses the iOS
///      keyboard before the route subtree is torn down.
///   2. One event-loop turn is yielded so that queued focus-loss notification
///      reaches the listener before route navigation begins.
///   3. `awaitDurableWrites`, when supplied, waits for the LOCAL durability
///      write that the focus loss started — SQLite, never the network. This is
///      what makes "type the last RIR, tap Back immediately" safe: the field
///      widgets are not torn down until the intent is on disk. It is bounded,
///      so a stuck write can never trap the athlete on the screen.
///   4. After re-checking mount, Home is marked active and navigation is
///      performed exactly once by the per-intent decision.
///
/// The [_isExiting] guard prevents repeated back/logo taps from double-popping
/// or duplicating Home. It is reset only when navigation throws, so the screen
/// is never permanently locked.
class Wes2ExitCoordinator {
  bool _isExiting = false;

  /// True once an exit is in flight (visible for assertions/testing).
  bool get isExiting => _isExiting;

  /// Exit to the actual previous route (Back / system Back).
  ///
  /// Pops exactly one route when one exists beneath WES2; otherwise (restored
  /// root WES2) replaces it with [homeRouteName] so the app never closes.
  Future<Wes2ExitAction> exitToPreviousRoute({
    required VoidCallback dropFocus,
    required bool Function() isMounted,
    required VoidCallback markHomeActive,
    required NavigatorState? Function() navigatorOf,
    Future<void> Function()? awaitDurableWrites,
    String homeRouteName = '/home',
  }) {
    return _run(
      dropFocus: dropFocus,
      isMounted: isMounted,
      markHomeActive: markHomeActive,
      navigatorOf: navigatorOf,
      awaitDurableWrites: awaitDurableWrites,
      navigate: (navigator) {
        if (navigator.canPop()) {
          navigator.pop();
          return Wes2ExitAction.poppedToPrevious;
        }
        navigator.pushReplacementNamed(homeRouteName);
        return Wes2ExitAction.replacedWithHome;
      },
    );
  }

  /// Exit directly to Home (GoodLift logo).
  ///
  /// In a normal stack, pops back to the existing [homeRouteName] route so its
  /// state is retained and no duplicate Home is created (any BB3/WES2 routes
  /// above it are removed). For a restored root WES2 (nothing beneath) it
  /// replaces WES2 with [homeRouteName].
  Future<Wes2ExitAction> exitDirectlyToHome({
    required VoidCallback dropFocus,
    required bool Function() isMounted,
    required VoidCallback markHomeActive,
    required NavigatorState? Function() navigatorOf,
    Future<void> Function()? awaitDurableWrites,
    String homeRouteName = '/home',
  }) {
    return _run(
      dropFocus: dropFocus,
      isMounted: isMounted,
      markHomeActive: markHomeActive,
      navigatorOf: navigatorOf,
      awaitDurableWrites: awaitDurableWrites,
      navigate: (navigator) {
        if (navigator.canPop()) {
          // Pop back to the existing named Home route, recording whether it was
          // actually found. The `isFirst` clause stops traversal at the root so
          // popUntil never runs past it — but reaching an UNEXPECTED non-Home
          // root must not be reported as poppedToHome. In that case replace the
          // unexpected root with '/home' instead.
          var foundHome = false;
          navigator.popUntil((route) {
            if (route.settings.name == homeRouteName) {
              foundHome = true;
              return true;
            }
            return route.isFirst;
          });
          if (foundHome) {
            return Wes2ExitAction.poppedToHome;
          }
          navigator.pushReplacementNamed(homeRouteName);
          return Wes2ExitAction.replacedWithHome;
        }
        navigator.pushReplacementNamed(homeRouteName);
        return Wes2ExitAction.replacedWithHome;
      },
    );
  }

  /// Shared guard + focus/keyboard sequencing + mount re-check + navigation
  /// exception handling. Only [navigate] differs between the two public intents.
  Future<Wes2ExitAction> _run({
    required VoidCallback dropFocus,
    required bool Function() isMounted,
    required VoidCallback markHomeActive,
    required NavigatorState? Function() navigatorOf,
    required Wes2ExitAction Function(NavigatorState navigator) navigate,
    Future<void> Function()? awaitDurableWrites,
  }) async {
    if (_isExiting) return Wes2ExitAction.skippedAlreadyExiting;
    _isExiting = true;
    try {
      dropFocus();

      // Yield one event-loop turn so the queued focus-loss notification reaches
      // the still-mounted field listener before route navigation begins.
      await Future<void>.delayed(Duration.zero);

      // Wait for the local durability write that focus loss just started —
      // never for the network. Bounded and failure-tolerant: an exit must not
      // be blocked by storage trouble, and the queued row survives regardless.
      if (awaitDurableWrites != null) {
        try {
          await awaitDurableWrites();
        } catch (e) {
          debugPrint('[WES2] durable-write barrier failed on exit: $e');
        }
      }

      if (!isMounted()) return Wes2ExitAction.skippedUnmounted;

      markHomeActive();

      final navigator = navigatorOf();
      if (navigator == null) return Wes2ExitAction.skippedUnmounted;

      return navigate(navigator);
    } catch (e, st) {
      // Never leave the screen permanently locked if navigation throws.
      debugPrint('[WES2] Wes2ExitCoordinator exit failed: $e\n$st');
      _isExiting = false;
      return Wes2ExitAction.failed;
    }
  }
}
