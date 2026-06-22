import 'dart:async';

import 'package:flutter/widgets.dart';

/// Outcome of a WES2 deliberate-exit attempt. Exposed so production logging and
/// tests can assert which branch ran without reimplementing the logic.
enum Wes2ExitAction {
  /// A route existed beneath WES2 — popped back to it.
  popped,

  /// WES2 was the restored root route — replaced with the Home route.
  replacedWithHome,

  /// A second exit was already in flight; this call was ignored by the guard.
  skippedAlreadyExiting,

  /// The widget unmounted during the focus-yield window — no navigation.
  skippedUnmounted,

  /// Navigation threw; the guard was reset so the screen is not locked.
  failed,
}

/// Coordinates the single authoritative WES2 → Home deliberate-exit sequence.
///
/// Extracted from `Wes2Screen` so the real guard, ordering, and navigation
/// decision run identically in production and in tests: production
/// `_exitToHome` delegates straight to [exit], so a test that drives [exit]
/// cannot pass while the real exit path is broken.
///
/// Ordering contract:
///   1. [dropFocus] runs first. In production it unfocuses the primary focus,
///      which fires the still-mounted WES2 field's focus-loss listener (the
///      existing `onFieldUnfocused` save, exactly once) and dismisses the iOS
///      keyboard before the route subtree is torn down.
///   2. One event-loop turn is yielded so that queued focus-loss notification
///      reaches the listener before route navigation begins.
///   3. After re-checking mount, Home is marked active and navigation is
///      performed exactly once: pop when Home exists beneath, otherwise
///      `pushReplacementNamed(homeRouteName)` for a restored root WES2 route.
///
/// The [_isExiting] guard prevents repeated back actions from double-popping or
/// duplicating Home. It is reset only when navigation throws, so the screen is
/// never permanently locked.
class Wes2ExitCoordinator {
  bool _isExiting = false;

  /// True once an exit is in flight (visible for assertions/testing).
  bool get isExiting => _isExiting;

  Future<Wes2ExitAction> exit({
    required VoidCallback dropFocus,
    required bool Function() isMounted,
    required VoidCallback markHomeActive,
    required NavigatorState? Function() navigatorOf,
    String homeRouteName = '/home',
  }) async {
    if (_isExiting) return Wes2ExitAction.skippedAlreadyExiting;
    _isExiting = true;
    try {
      dropFocus();

      // Yield one event-loop turn so the queued focus-loss notification reaches
      // the still-mounted field listener before route navigation begins.
      await Future<void>.delayed(Duration.zero);

      if (!isMounted()) return Wes2ExitAction.skippedUnmounted;

      markHomeActive();

      final navigator = navigatorOf();
      if (navigator == null) return Wes2ExitAction.skippedUnmounted;

      if (navigator.canPop()) {
        navigator.pop();
        return Wes2ExitAction.popped;
      }
      navigator.pushReplacementNamed(homeRouteName);
      return Wes2ExitAction.replacedWithHome;
    } catch (e, st) {
      // Never leave the screen permanently locked if navigation throws.
      debugPrint('[WES2] Wes2ExitCoordinator.exit failed: $e\n$st');
      _isExiting = false;
      return Wes2ExitAction.failed;
    }
  }
}
