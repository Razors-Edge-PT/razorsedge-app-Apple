/// The two native notification calls the app needs, over one method channel
/// implemented in MainActivity.kt (Android) and AppDelegate.swift (iOS):
///
///   openSettings    this app's notification settings in the OS, for someone
///                   who denied the permission and wants it back
///   clearDelivered  remove GoodLift's notifications from the tray/Notification
///                   Centre, on explicit logout
///
/// Both are best effort: a missing implementation (tests, desktop) is a no-op.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NotificationPlatform {
  NotificationPlatform({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('goodlift/notifications');

  final MethodChannel _channel;

  Future<void> openSystemSettings() => _invoke('openSettings');

  Future<void> clearDelivered() => _invoke('clearDelivered');

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Not available on this platform.
    } catch (e) {
      debugPrint('[push] $method failed: $e');
    }
  }
}
