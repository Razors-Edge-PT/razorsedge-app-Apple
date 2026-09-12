/// Marks a post's interactions read — but only the ones actually shown.
///
/// ── Why a scope, and not "opening the post clears it" ───────────────────────
/// Opening a post is not the same as seeing everything about it. The comments
/// list shows a window; a comment older than that window has not been read,
/// however long the page stays open. Likes and Good Lifts ARE presented by the
/// post itself — their counts are on screen — so those are acknowledged when
/// the post is genuinely in front of the person.
///
/// So this scope collects what the page is displaying (the comments list
/// reports itself through [PostActivityScope.of]) and acknowledges exactly
/// that, and only while:
///
///   * this route is the visible one — a post underneath another screen, or
///     underneath the Activity list that opened it, presents nothing;
///   * the app is resumed — a page open behind a locked phone reads nothing;
///   * somebody is signed in.
///
/// An interaction that arrives while all of that is true is acknowledged on
/// the next update; one that arrives after the page is covered is not, and
/// stays unread with its alert intact.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart' show routeObserver;
import '../../push/foreground_post.dart';
import '../social_activity_service.dart';

class PostActivityScope extends StatefulWidget {
  const PostActivityScope({
    super.key,
    required this.postId,
    required this.child,
    this.service,
  });

  final String postId;
  final Widget child;

  /// Injectable for tests. Production uses the shared service.
  final SocialActivityService? service;

  /// The nearest scope, for a widget reporting what it is displaying.
  static PostActivityScopeState? of(BuildContext context) =>
      context.findAncestorStateOfType<PostActivityScopeState>();

  @override
  State<PostActivityScope> createState() => PostActivityScopeState();
}

class PostActivityScopeState extends State<PostActivityScope>
    with WidgetsBindingObserver, RouteAware {
  SocialActivityService get _service =>
      widget.service ?? SocialActivityService.instance;

  final Set<String> _displayedComments = <String>{};
  StreamSubscription<SocialActivitySnapshot>? _sub;
  bool _routeVisible = true;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ForegroundPost.shown(widget.postId);
    _sub = _service.watch().listen((_) => _maybeAcknowledge());
    // The page may open onto interactions that are already waiting.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAcknowledge());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && route != _route) {
      if (_route != null) routeObserver.unsubscribe(this);
      _route = route;
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    ForegroundPost.hidden(widget.postId);
    if (_route != null) routeObserver.unsubscribe(this);
    _sub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── Visibility ─────────────────────────────────────────────────────────────

  @override
  void didPush() => _setVisible(true);

  @override
  void didPopNext() => _setVisible(true);

  @override
  void didPushNext() => _setVisible(false);

  @override
  void didPop() => _setVisible(false);

  void _setVisible(bool visible) {
    _routeVisible = visible;
    if (visible) {
      ForegroundPost.shown(widget.postId);
      _maybeAcknowledge();
    } else {
      ForegroundPost.hidden(widget.postId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _maybeAcknowledge();
  }

  /// The comments list says which comments it is showing. Called as the list
  /// builds, so it must stay cheap and must not set state.
  void reportDisplayedComments(Iterable<String> commentIds) {
    final int before = _displayedComments.length;
    _displayedComments.addAll(commentIds);
    if (_displayedComments.length != before) _maybeAcknowledge();
  }

  void _maybeAcknowledge() {
    if (!mounted) return;
    final bool resumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!shouldAcknowledgeActivity(
      routeVisible: _routeVisible,
      appResumed: resumed,
      signedIn: _service.snapshot.uid != null,
    )) {
      return;
    }
    final List<SocialActivity> presented = presentedOnPost(
      unread: _service.snapshot.unread,
      postId: widget.postId,
      displayedCommentIds: _displayedComments,
    );
    if (presented.isEmpty) return;
    unawaited(_service.acknowledge(presented));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
