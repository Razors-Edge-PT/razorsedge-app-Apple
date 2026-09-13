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
///   * the same account is still signed in — including after an await.
///
/// An interaction that arrives while all of that is true is acknowledged on
/// the next update; one that arrives after the page is covered is not, and
/// stays unread with its alert intact.
///
/// ── Two different sets ──────────────────────────────────────────────────────
/// [_visibleComments] is what is on screen NOW: comments leave it when they
/// scroll away, because that set also decides whether an incoming alert would
/// be telling the person something they can already see. [_everShown] is the
/// history, kept separately so that acknowledging never depends on a comment
/// still happening to be in the viewport when a lookup returns.
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
    this.focusActivityId,
    this.service,
  });

  final String postId;
  final Widget child;

  /// The interaction this screen was opened FOR, when a notification or an
  /// Activity row named it. Resolved by id, so it can be acknowledged however
  /// far outside any query window its record sits.
  final String? focusActivityId;

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

  /// On screen right now.
  final Set<String> _visibleComments = <String>{};

  /// Shown at some point during this visit, whether or not still on screen.
  final Set<String> _everShown = <String>{};

  StreamSubscription<SocialActivitySnapshot>? _sub;
  bool _routeVisible = true;
  ModalRoute<dynamic>? _route;

  /// Unread interactions for THIS post as the server has them.
  ///
  /// The live subscription only tracks the newest unread records overall, so a
  /// notification about a comment with fifty newer interactions behind it
  /// would not be in it — and would then never be read or have its alert
  /// cancelled, however plainly it is on screen. This is that post's own
  /// unread list, fetched when the page opens and again when it presents
  /// something the local view does not cover.
  List<SocialActivity> _subjectUnread = const <SocialActivity>[];
  bool _fetchingSubject = false;
  bool _askedOnOpen = false;

  /// The records named by taps that have reached this page, resolved by id.
  ///
  /// A map rather than one value: a second tap while the post is open does not
  /// undo the first, and both interactions still have to be acknowledged.
  final Map<String, SocialActivity> _focusRecords = <String, SocialActivity>{};
  final Set<String> _focusAsked = <String>{};

  /// Rises with every focus this page is given, so a lookup that returns after
  /// a newer one has arrived cannot put the older answer back.
  int _focusGeneration = 0;

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
  void didUpdateWidget(covariant PostActivityScope old) {
    super.didUpdateWidget(old);
    if (old.focusActivityId != widget.focusActivityId) {
      _focusGeneration++;
      _maybeAcknowledge();
    }
  }

  @override
  void dispose() {
    ForegroundPost.hidden(widget.postId);
    ForegroundPost.reportVisibleComments(widget.postId, const <String>{});
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

  /// The comments list says whether a comment is ON SCREEN right now — not
  /// which ones it loaded. Called from a visibility callback, so it must stay
  /// cheap and must not set state.
  void reportCommentVisibility(String commentId, bool visible) {
    final bool changed =
        visible ? _visibleComments.add(commentId) : _visibleComments.remove(commentId);
    if (visible) _everShown.add(commentId);
    if (!changed) return;
    // A banner for a comment on screen would be noise; one for a comment
    // scrolled away, or never reached, is not.
    ForegroundPost.reportVisibleComments(widget.postId, _visibleComments);
    _maybeAcknowledge();
  }

  /// Kept for callers that report a batch of comments as displayed.
  void reportDisplayedComments(Iterable<String> commentIds) {
    for (final String id in commentIds) {
      reportCommentVisibility(id, true);
    }
  }

  /// Everything unread known for this post, without duplicates: the live
  /// window, this post's own list, and the record the alert named.
  List<SocialActivity> _knownUnread() {
    final Map<String, SocialActivity> byId = <String, SocialActivity>{
      for (final SocialActivity a in _service.snapshot.unread) a.id: a,
      for (final SocialActivity a in _subjectUnread) a.id: a,
      ..._focusRecords,
    };
    return byId.values.toList(growable: false);
  }

  /// The account this scope is acknowledging for, captured before any await.
  String? get _owner => _service.snapshot.uid;

  bool _canAcknowledge() =>
      mounted &&
      shouldAcknowledgeActivity(
        routeVisible: _routeVisible,
        appResumed:
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
        signedIn: _service.snapshot.uid != null,
      );

  void _maybeAcknowledge() {
    if (!_canAcknowledge()) return;
    final List<SocialActivity> presented = presentedOnPost(
      unread: _knownUnread(),
      postId: widget.postId,
      // History, not the current viewport: a comment seen a moment ago has
      // been read, even if the reply box has since scrolled it off.
      displayedCommentIds: _everShown,
    );
    if (presented.isNotEmpty) unawaited(_service.acknowledge(presented));

    // The post itself presents its likes and Good Lifts, so opening it is
    // enough to have to ask about them — a like older than the live window on
    // a post with no comments at all would otherwise stay unread for ever.
    if (!_askedOnOpen) {
      _askedOnOpen = true;
      unawaited(_refreshSubjectUnread());
    } else if (_needsSubjectLookup(presented)) {
      unawaited(_refreshSubjectUnread());
    }
    unawaited(_resolveFocus());
  }

  /// True when a comment is on screen that nothing known accounts for.
  bool _needsSubjectLookup(List<SocialActivity> presented) {
    if (_fetchingSubject || _everShown.isEmpty) return false;
    final Set<String> explained = <String>{
      for (final SocialActivity a in _knownUnread())
        if (a.commentId != null) a.commentId!,
      for (final SocialActivity a in presented)
        if (a.commentId != null) a.commentId!,
      // Already asked about: most comments have no unread interaction behind
      // them at all, and scrolling past them must not re-query the post.
      ..._askedAbout,
    };
    return _everShown.any((String id) => !explained.contains(id));
  }

  /// Comments a subject lookup has already covered.
  final Set<String> _askedAbout = <String>{};

  Future<void> _refreshSubjectUnread() async {
    if (_fetchingSubject) return;
    _fetchingSubject = true;
    final String? owner = _owner;
    final Set<String> asked = <String>{..._everShown};
    try {
      final List<SocialActivity> found = await _service
          .unreadForSubjectFromServer(postSubject(widget.postId));
      // The route may have been covered, the app backgrounded or the account
      // switched while that was in flight. Any of those means this page is no
      // longer presenting anything, and none of it may be acknowledged.
      if (!mounted || _service.snapshot.uid != owner) return;
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

  /// The interaction the alert named, read by id.
  ///
  /// Independent of every window: neither the newest-fifty unread view nor the
  /// per-post list has to contain it for the thing the person tapped to be
  /// acknowledgeable.
  Future<void> _resolveFocus() async {
    final String? id = widget.focusActivityId;
    if (id == null || !_focusAsked.add(id)) return;
    final String? owner = _owner;
    final int generation = _focusGeneration;
    try {
      final SocialActivity? found = await _service.activityById(id);
      // A lookup outlives what asked for it. If the account changed, the page
      // went, or a NEWER focus has arrived since, this answer is no longer the
      // one to act on.
      if (!mounted ||
          found == null ||
          _service.snapshot.uid != owner ||
          generation != _focusGeneration) {
        if (generation != _focusGeneration) _focusAsked.remove(id);
        return;
      }
      if (found.subject != postSubject(widget.postId)) return;
      _focusRecords[found.id] = found;
      _maybeAcknowledge();
    } catch (_) {
      // Offline: the ordinary paths still cover anything recent, and a later
      // attempt may succeed.
      _focusAsked.remove(id);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
