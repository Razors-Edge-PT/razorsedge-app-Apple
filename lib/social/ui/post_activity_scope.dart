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

  /// Unread interactions for THIS post as the server has them.
  ///
  /// The live subscription only tracks the newest unread records overall, so a
  /// notification about a comment with fifty newer interactions behind it
  /// would not be in it — and would then never be read or have its alert
  /// cancelled, however plainly it is on screen. This is that post's own
  /// unread list, fetched when the page presents something the local view does
  /// not cover.
  List<SocialActivity> _subjectUnread = const <SocialActivity>[];
  bool _fetchingSubject = false;

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

  /// The comments list says which comments are ON SCREEN right now — not
  /// which ones it loaded. Called from a visibility callback, so it must stay
  /// cheap and must not set state.
  void reportDisplayedComments(Iterable<String> commentIds) {
    final int before = _displayedComments.length;
    _displayedComments.addAll(commentIds);
    if (_displayedComments.length == before) return;
    // A banner for a comment already on screen would be noise; one for a
    // comment further up the thread is not.
    ForegroundPost.reportVisibleComments(widget.postId, _displayedComments);
    _maybeAcknowledge();
  }

  /// The unread interactions for this post, from both the live view and this
  /// post's own list, without duplicates.
  List<SocialActivity> _knownUnread() {
    final Map<String, SocialActivity> byId = <String, SocialActivity>{
      for (final SocialActivity a in _service.snapshot.unread) a.id: a,
      for (final SocialActivity a in _subjectUnread) a.id: a,
    };
    return byId.values.toList(growable: false);
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
      unread: _knownUnread(),
      postId: widget.postId,
      displayedCommentIds: _displayedComments,
    );
    if (presented.isNotEmpty) unawaited(_service.acknowledge(presented));
    // Something on screen that the live window does not explain is the sign of
    // an older interaction: ask this post directly, once at a time.
    if (_needsSubjectLookup(presented)) unawaited(_refreshSubjectUnread());
  }

  /// True when a comment is on screen that nothing known accounts for.
  bool _needsSubjectLookup(List<SocialActivity> presented) {
    if (_fetchingSubject || _displayedComments.isEmpty) return false;
    final Set<String> explained = <String>{
      for (final SocialActivity a in _knownUnread())
        if (a.commentId != null) a.commentId!,
      for (final SocialActivity a in presented)
        if (a.commentId != null) a.commentId!,
      // Already asked about: most comments have no unread interaction behind
      // them at all, and scrolling past them must not re-query the post.
      ..._askedAbout,
    };
    return _displayedComments.any((String id) => !explained.contains(id));
  }

  /// Comments a subject lookup has already covered.
  final Set<String> _askedAbout = <String>{};

  Future<void> _refreshSubjectUnread() async {
    if (_fetchingSubject) return;
    _fetchingSubject = true;
    final Set<String> asked = <String>{..._displayedComments};
    try {
      final List<SocialActivity> found = await _service
          .unreadForSubjectFromServer(postSubject(widget.postId));
      if (!mounted) return;
      _askedAbout.addAll(asked);
      final bool changed = found.length != _subjectUnread.length ||
          found.any((SocialActivity a) =>
              !_subjectUnread.any((SocialActivity b) => b.id == a.id));
      _subjectUnread = found;
      if (changed && found.isNotEmpty) _maybeAcknowledge();
    } catch (_) {
      // Offline: the live view still covers everything recent.
    } finally {
      _fetchingSubject = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
