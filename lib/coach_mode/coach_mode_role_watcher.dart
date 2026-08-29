// Keeps a screen bound to the LIVE UserContext's Coach Mode role.
//
// AppRoot rebuilds UserContext after token resolution and re-provides it, so a
// screen that subscribes once in initState ends up listening to a DISCARDED
// instance: a suspension or revocation delivered to the replacement is never
// observed, and the screen keeps showing coach data it is no longer authorised
// to see.
//
// This mixin rebinds on every Provider value change, always detaching from the
// old instance before attaching to the new one.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../user_context.dart';

mixin CoachModeRoleWatcher<T extends StatefulWidget> on State<T> {
  UserContext? _watchedContext;
  bool _revoked = false;

  /// The UserContext currently being watched (null before the first bind).
  UserContext? get watchedContext => _watchedContext;

  /// True once Coach Mode has been observed as inactive for this screen.
  bool get coachModeRevoked => _revoked;

  /// Called when this screen binds to a context that HAS Coach Mode.
  /// Fires again when the provided instance is replaced, so per-context work
  /// (loading a roster, say) is redone against the live context.
  void onCoachModeBound(UserContext context) {}

  /// Called when the bound context has no Coach Mode — on first bind, on a
  /// rebind, or when a live suspension/revocation arrives.
  ///
  /// [duringBind] is true when it happened while binding (so the caller must
  /// defer any Navigator/ScaffoldMessenger work to after the frame).
  void onCoachModeRevoked({required bool duringBind}) {}

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindRoleWatcher();
  }

  void _bindRoleWatcher() {
    final next = Provider.of<UserContext?>(context, listen: false);
    if (next == null) return;
    if (identical(next, _watchedContext)) return;

    // Detach from the old instance BEFORE attaching to the new one, so a
    // discarded context can never call back into this screen.
    _watchedContext?.removeListener(_handleRoleChanged);
    _watchedContext = next;
    next.addListener(_handleRoleChanged);

    // The replacement context may already carry a suspension, so the role is
    // re-evaluated on every rebind rather than only on the first bind.
    if (!next.hasCoachMode) {
      _revoked = true;
      onCoachModeRevoked(duringBind: true);
      return;
    }
    _revoked = false;
    onCoachModeBound(next);
  }

  void _handleRoleChanged() {
    final ctx = _watchedContext;
    if (!mounted || ctx == null) return;
    if (ctx.hasCoachMode) return;
    if (_revoked) return;
    _revoked = true;
    onCoachModeRevoked(duringBind: false);
  }

  /// Detaches the listener. Call from the State's dispose().
  void disposeRoleWatcher() {
    _watchedContext?.removeListener(_handleRoleChanged);
    _watchedContext = null;
  }
}
