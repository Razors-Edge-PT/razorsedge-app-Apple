/// Which direct-message conversation the person is actually looking at.
///
/// ConversationPage reports itself here as it becomes the visible route and
/// as it is covered or popped (RouteAware), so a page that is merely MOUNTED
/// beneath another screen does not count. The app lifecycle is checked at
/// the moment of use, so a conversation left open while the app is in the
/// background does not count either.
///
/// Used for exactly one thing: not showing the in-app banner (or opening a
/// second copy of the page) for a message in the conversation already on
/// screen. Unread counts are untouched by this — they stay the page's own
/// business.
library;

import 'package:flutter/widgets.dart';

class ForegroundConversation {
  ForegroundConversation._();

  // A stack, topmost last, in case the same app ever stacks two threads.
  static final List<String> _visible = <String>[];

  /// [convId] became the visible route.
  static void shown(String convId) {
    _visible.remove(convId);
    _visible.add(convId);
  }

  /// [convId] was covered, popped or disposed.
  static void hidden(String convId) {
    _visible.remove(convId);
  }

  /// The conversation on top, regardless of app lifecycle.
  static String? get visibleConvId => _visible.isEmpty ? null : _visible.last;

  /// True only while the app is resumed AND [convId] is the visible route.
  static bool isForeground(String convId) =>
      visibleConvId == convId &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @visibleForTesting
  static void reset() => _visible.clear();
}
