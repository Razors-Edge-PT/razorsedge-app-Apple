/// Marks a point in the widget tree where notification navigation is safe.
///
/// Placed INSIDE the MembershipGate of the gated Home route and of the
/// restored WES2 route (main.dart). The gate builds its child only once it has
/// let the person through, so this widget existing means: a user is signed
/// in, membership (or its trial/coach equivalent) is confirmed, and there is a
/// navigator above it. PushRouter opens a pending tap only while one of these
/// is mounted; if the gate demotes to the paywall the scope unmounts and taps
/// wait again.
///
/// The Home instance also offers the one-time notification explanation, a few
/// seconds after Home has settled — never over WES2, so a workout in progress
/// is never interrupted by a dialog.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'push_notification_service.dart';
import 'push_router.dart';

class PushReadyScope extends StatefulWidget {
  const PushReadyScope({
    super.key,
    required this.child,
    this.offerPermissionPrimer = false,
  });

  final Widget child;
  final bool offerPermissionPrimer;

  @override
  State<PushReadyScope> createState() => _PushReadyScopeState();
}

class _PushReadyScopeState extends State<PushReadyScope> {
  Object? _handle;
  Timer? _primerTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handle = PushRouter.instance.attachScope(() => mounted ? context : null);
      if (widget.offerPermissionPrimer) {
        _primerTimer = Timer(const Duration(seconds: 3), () {
          if (!mounted) return;
          if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
          unawaited(PushNotificationService.instance.maybeOfferPermission(context));
        });
      }
    });
  }

  @override
  void dispose() {
    _primerTimer?.cancel();
    PushRouter.instance.detachScope(_handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
