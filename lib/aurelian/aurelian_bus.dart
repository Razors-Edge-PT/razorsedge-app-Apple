/// Routes Aurelian commands to the GoodLift screen that owns them.
///
/// Screens register a handler while they are mounted and unregister on
/// dispose. A handler returns null for a command it does not handle, so the
/// next one gets it. Order: the more specific scope first (an open exercise
/// picker over the workout over Home over the root), and among equals the most
/// recently mounted (the screen on top).
///
/// A workout command ("set one weight 50", "add exercise", …) that arrives
/// while no workout is mounted first opens the workout the ordinary way (Home's
/// own Enter Workout path, membership gate included), waits for WES2 to mount
/// and register — lifecycle acknowledgement, not a fixed delay — and then
/// delivers the command.
///
/// Readiness: the native bridge holds commands until a root scope
/// ([AurelianBridgeScope]) is mounted, which only happens inside the
/// membership gate, so the bridge can never step around sign-in or the paywall.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'aurelian_command.dart';

enum AurelianScopeKind {
  /// Inside the membership gate (Home or the restored workout root).
  root(0),
  home(10),
  wes2(10),
  analytics(10),

  /// A modal on top: the WES2 Add Exercise picker.
  picker(20);

  const AurelianScopeKind(this.priority);
  final int priority;
}

typedef AurelianHandler = Future<AurelianResult?> Function(
    AurelianCommand command);

class _Registration {
  _Registration(this.kind, this.handler, this.seq);
  final AurelianScopeKind kind;
  final AurelianHandler handler;
  final int seq;
}

class AurelianCommandBus {
  AurelianCommandBus({this.workoutMountTimeout = const Duration(seconds: 10)});

  static final AurelianCommandBus instance = AurelianCommandBus();

  final Duration workoutMountTimeout;
  final List<_Registration> _registrations = <_Registration>[];
  final List<({AurelianScopeKind kind, Completer<void> completer})> _waiters =
      <({AurelianScopeKind kind, Completer<void> completer})>[];
  int _seq = 0;
  bool _ready = false;

  /// Told when the bus becomes ready (a root scope mounted) or stops being.
  void Function(bool ready)? onReadyChanged;

  bool get ready => _ready;

  /// Registers [handler] for [kind]; pass the returned handle to [unregister].
  Object register(AurelianScopeKind kind, AurelianHandler handler) {
    final _Registration r = _Registration(kind, handler, ++_seq);
    _registrations.add(r);
    for (final w in List.of(_waiters)) {
      if (w.kind == kind && !w.completer.isCompleted) {
        _waiters.remove(w);
        w.completer.complete();
      }
    }
    _updateReady();
    return r;
  }

  void unregister(Object? handle) {
    _registrations.remove(handle);
    _updateReady();
  }

  bool hasScope(AurelianScopeKind kind) =>
      _registrations.any((_Registration r) => r.kind == kind);

  /// Completes true once a [kind] scope is registered, false after [timeout].
  Future<bool> waitForScope(AurelianScopeKind kind, Duration timeout) async {
    if (hasScope(kind)) return true;
    final Completer<void> completer = Completer<void>();
    final entry = (kind: kind, completer: completer);
    _waiters.add(entry);
    try {
      await completer.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      _waiters.remove(entry);
    }
  }

  Future<AurelianResult> dispatch(AurelianCommand command) async {
    if (command.kind.needsWorkout && !hasScope(AurelianScopeKind.wes2)) {
      final AurelianResult opened = await _route(
          const AurelianCommand(AurelianCommandKind.openWorkout));
      if (!opened.isOk) return opened;
      if (!await waitForScope(AurelianScopeKind.wes2, workoutMountTimeout)) {
        return const AurelianResult.unavailable('The workout did not open');
      }
    }
    return _route(command);
  }

  Future<AurelianResult> _route(AurelianCommand command) async {
    final List<_Registration> ordered = List.of(_registrations)
      ..sort((_Registration a, _Registration b) {
        final int p = b.kind.priority.compareTo(a.kind.priority);
        return p != 0 ? p : b.seq.compareTo(a.seq);
      });
    for (final _Registration r in ordered) {
      if (!_registrations.contains(r)) continue; // unmounted meanwhile
      AurelianResult? result;
      try {
        result = await r.handler(command);
      } catch (e) {
        debugPrint('[AURELIAN] handler for ${command.kind.wire} failed: $e');
        return const AurelianResult.failed('GoodLift could not do that');
      }
      if (result != null) return result;
    }
    return command.kind == AurelianCommandKind.selectExercise
        ? const AurelianResult.notHandled('Nothing to select from here')
        : const AurelianResult.unavailable('Not available on this screen');
  }

  void _updateReady() {
    final bool now = hasScope(AurelianScopeKind.root);
    if (now == _ready) return;
    _ready = now;
    onReadyChanged?.call(now);
  }

  @visibleForTesting
  void debugReset() {
    _registrations.clear();
    _waiters.clear();
    _ready = false;
    onReadyChanged = null;
  }
}

/// Binds [AurelianCommandBus] to the native bridge's own channel. Android only;
/// on other platforms there is no bridge and nothing is attached.
class AurelianBridgeChannel {
  AurelianBridgeChannel._();

  static const MethodChannel channel = MethodChannel('goodlift/aurelian');

  static void attach({AurelianCommandBus? bus}) {
    if (kIsWeb || !Platform.isAndroid) return;
    bindTo(bus ?? AurelianCommandBus.instance, channel);
  }

  @visibleForTesting
  static void bindTo(AurelianCommandBus bus, MethodChannel channel) {
    channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'command') {
        throw MissingPluginException('Unknown method ${call.method}');
      }
      final AurelianCommand? command = AurelianCommand.fromBridge(call.arguments);
      if (command == null) {
        return const AurelianResult.invalid('Malformed command').toMap();
      }
      final AurelianResult result = await bus.dispatch(command);
      debugPrint('[AURELIAN] ${command.kind.wire} -> ${result.status.wire}');
      return result.toMap();
    });
    bus.onReadyChanged = (bool ready) {
      unawaited(channel
          .invokeMethod<void>(ready ? 'ready' : 'notReady')
          .catchError((Object _) {}));
    };
    if (bus.ready) {
      unawaited(channel.invokeMethod<void>('ready').catchError((Object _) {}));
    }
  }
}
