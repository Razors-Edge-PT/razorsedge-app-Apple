/// Which post the person is actually looking at.
///
/// The post detail page reports itself here as it becomes the visible route
/// and as it is covered or popped (RouteAware), so a page merely MOUNTED
/// beneath another screen does not count. The app lifecycle is checked at the
/// moment of use, so a post left open while the app is in the background does
/// not count either.
///
/// Used for exactly one thing: not showing the in-app banner for an
/// interaction with the post already on screen. An interaction with a
/// DIFFERENT post still shows one — being in one post does not mean having
/// seen another. Read state is not decided here; that belongs to the
/// acknowledgement, which knows which comments were actually shown.
library;

import 'package:flutter/widgets.dart';

class ForegroundPost {
  ForegroundPost._();

  // A stack, topmost last: opening a post from a post is possible.
  static final List<String> _visible = <String>[];

  static void shown(String postId) {
    _visible.remove(postId);
    _visible.add(postId);
  }

  static void hidden(String postId) {
    _visible.remove(postId);
  }

  /// The post on top, regardless of app lifecycle.
  static String? get visiblePostId => _visible.isEmpty ? null : _visible.last;

  /// True only while the app is resumed AND [postId] is the visible route.
  static bool isForeground(String postId) =>
      visiblePostId == postId &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @visibleForTesting
  static void reset() => _visible.clear();
}
