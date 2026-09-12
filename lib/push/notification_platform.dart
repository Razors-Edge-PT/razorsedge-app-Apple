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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NotificationPlatform {
  NotificationPlatform({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('goodlift/notifications');

  final MethodChannel _channel;

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
