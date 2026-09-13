/// The native notification calls the app needs, over one method channel
/// implemented in MainActivity.kt (Android) and AppDelegate.swift (iOS):
///
///   openSettings        this app's notification settings in the OS, for
///                       someone who denied the permission and wants it back
///   clearDelivered      remove ALL of GoodLift's notifications from the
///                       tray/Notification Centre, on explicit logout
///   clearNotifications  remove only the alerts a read/seen acknowledgement
///                       covers — one conversation, or one person's social
///                       alerts — and nothing else
///
/// ── Why the native side has to search ───────────────────────────────────────
/// Most of these alerts were posted by the system from an FCM message while
/// Dart was not running, so the app never saw them and cannot hold a registry
/// of them. What the OS does keep is each delivered alert's tag (Android
/// `getActiveNotifications`) / identifier (iOS `getDeliveredNotifications`),
/// which the server sets to `dm|<conversation>|<message>`, `fr_<uid>` or
/// `fa_<uid>`. Matching on those is what makes cancellation targeted rather
/// than "clear everything".
///
/// Only this app's own notifications are ever read or cancelled; nothing here
/// asks for notification-listener access to other apps.
///
/// All calls are best effort: a missing implementation (tests, desktop) is a
/// no-op.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NotificationPlatform {
  NotificationPlatform({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('goodlift/notifications');

  final MethodChannel _channel;

  // Keyed by channel NAME rather than instance: production constructs one
  // NotificationPlatform per owner (the push service, DmUnreadService), all
  // wrapping the same platform channel, and the native side has exactly one
  // handler either way. Keying by name means whichever instance first asks
  // for taps wires the single underlying method-call handler, and every
  // instance sharing that channel gets the same broadcast stream.
  static final Map<String, StreamController<Map<String, String>>>
      _tapControllers = <String, StreamController<Map<String, String>>>{};

  /// A tap on a notification GoodLift posted itself while the app was
  /// running — see [postNotification]. Fires only while this process is
  /// alive; a cold start reads [takePendingTap] instead. FCM's own
  /// background/killed notifications are unaffected: those still arrive
  /// through firebase_messaging's onMessageOpenedApp / getInitialMessage.
  Stream<Map<String, String>> get onNotificationTapped {
    final StreamController<Map<String, String>> controller =
        _tapControllers.putIfAbsent(_channel.name, () {
      final StreamController<Map<String, String>> c =
          StreamController<Map<String, String>>.broadcast();
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'notificationTapped') {
          final Object? args = call.arguments;
          if (args is Map) {
            c.add(<String, String>{
              for (final MapEntry<Object?, Object?> e in args.entries)
                e.key.toString(): e.value?.toString() ?? '',
            });
          }
        }
        return null;
      });
      return c;
    });
    return controller.stream;
  }

  Future<void> openSystemSettings() => _invoke('openSettings');

  /// Explicit logout only.
  Future<void> clearDelivered() => _invoke('clearDelivered');

  /// Removes delivered alerts whose tag/identifier starts with one of
  /// [tagPrefixes] or exactly matches one of [tags]. [convIds] additionally
  /// matches iOS payloads by their `convId`, which covers alerts sent by
  /// builds before the conversation-scoped tag existed.
  ///
  /// Returns the number the platform reports as removed (0 when unsupported).
  Future<int> clearNotifications({
    List<String> tagPrefixes = const <String>[],
    List<String> tags = const <String>[],
    List<String> convIds = const <String>[],
  }) async {
    if (tagPrefixes.isEmpty && tags.isEmpty && convIds.isEmpty) return 0;
    final Object? removed = await _invokeWithResult('clearNotifications', <String, Object?>{
      'tagPrefixes': tagPrefixes,
      'tags': tags,
      'convIds': convIds,
    });
    return removed is int ? removed : 0;
  }

  /// The tags/identifiers of THIS app's alerts currently in the tray.
  ///
  /// Reconciliation needs to start from what is actually delivered: most of
  /// those alerts were posted by the system from FCM while Dart was not
  /// running, so the app has no record of them, and their tag is the only
  /// thing naming the interaction each one is about. Empty when the platform
  /// cannot answer (older native build, desktop, tests) — callers fall back.
  Future<List<String>> deliveredTags() async {
    // Bounded on purpose. This runs on startup and on resume, before the
    // badge and the tray agree, and the answer comes from the OS: on iOS
    // through a completion handler, on Android through a system service that
    // can refuse. A call that never comes back would leave reconciliation —
    // and anything waiting on it — hanging for the life of the session, so a
    // slow platform is treated exactly like one that cannot answer.
    final Object? tags = await _invokeWithResult('deliveredTags', null)
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (tags is! List) return const <String>[];
    return <String>[
      for (final Object? t in tags)
        if (t is String && t.isNotEmpty) t,
    ];
  }

  /// Posts a system notification for an interaction received while the app is
  /// in the foreground — the counterpart to what FCM posts itself in the
  /// background or killed. [tag]/[channelId] MUST be the same values the
  /// server would have used (see push_intent.dart's tag builders and
  /// androidChannelFor), so a background alert and a foreground one for the
  /// same interaction collapse to one, and existing cancellation still finds
  /// it. [data] is the same routing payload a tap would carry from the tray.
  ///
  /// Best effort: false when unsupported (desktop, tests) or refused by the
  /// OS (permission not actually granted despite the app's own state).
  Future<bool> postNotification({
    required String tag,
    required String channelId,
    required String title,
    required String body,
    required Map<String, String> data,
  }) async {
    final Object? ok = await _invokeWithResult('postNotification', <String, Object?>{
      'tag': tag,
      'channelId': channelId,
      'title': title,
      'body': body,
      'data': data,
    });
    return ok == true;
  }

  /// A tap on a self-posted notification (see [postNotification]) that
  /// launched this process fresh. Consumed once; null when this launch was
  /// not one, or the platform cannot answer.
  Future<Map<String, String>?> takePendingTap() async {
    final Object? data = await _invokeWithResult('takePendingTap', null);
    if (data is! Map) return null;
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in data.entries)
        e.key.toString(): e.value?.toString() ?? '',
    };
  }

  Future<void> _invoke(String method) async {
    await _invokeWithResult(method, null);
  }

  Future<Object?> _invokeWithResult(String method, Map<String, Object?>? args) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      // Not available on this platform.
      return null;
    } catch (e) {
      debugPrint('[push] $method failed: $e');
      return null;
    }
  }
}
