/// Marks where Aurelian voice commands may run, like [PushReadyScope] does for
/// notification taps: it sits INSIDE the membership gate of the gated Home
/// route and of the restored WES2 route (main.dart), so while one is mounted a
/// user is signed in, membership is confirmed and a navigator exists. While
/// none is mounted, the native bridge keeps commands queued (and refuses them
/// after its timeout), so voice can never step around sign-in or the paywall.
///
/// It is also the lowest-priority handler: "open analytics" and "enter
/// workout" when no more specific screen (Home, WES2, Analytics) handles them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../home_screen_2.dart' show pushExerciseAnalytics;
import '../membership_gate.dart' show gatedWes2;
import '../user_context.dart';
import 'aurelian_bus.dart';
import 'aurelian_command.dart';

class AurelianBridgeScope extends StatefulWidget {
  const AurelianBridgeScope({super.key, required this.child});

  final Widget child;

  @override
  State<AurelianBridgeScope> createState() => _AurelianBridgeScopeState();
}

class _AurelianBridgeScopeState extends State<AurelianBridgeScope> {
  Object? _handle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handle = AurelianCommandBus.instance
          .register(AurelianScopeKind.root, _onCommand);
    });
  }

  @override
  void dispose() {
    AurelianCommandBus.instance.unregister(_handle);
    super.dispose();
  }

  Future<AurelianResult?> _onCommand(AurelianCommand command) async {
    if (!mounted) return null;
    switch (command.kind) {
      case AurelianCommandKind.openAnalytics:
        pushExerciseAnalytics(context);
        return const AurelianResult.ok('Analytics opened');
      case AurelianCommandKind.openWorkout:
        final UserContext uc = UserContext.of(context, listen: false);
        if (uc.activeBlockId?.isNotEmpty != true) {
          return const AurelianResult.unavailable(
              'Training data is still loading — try again in a moment');
        }
        unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ChangeNotifierProvider<UserContext>.value(
            value: uc,
            child: gatedWes2(),
          ),
        )));
        return const AurelianResult.ok('Workout opened');
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
