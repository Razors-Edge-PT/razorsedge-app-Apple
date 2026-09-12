/// ACTIVITY — what people did to your posts and your messages.
///
/// ── What marks a row read ───────────────────────────────────────────────────
/// Being SEEN. Not opening the tab, not opening Home, not having the list
/// mounted under another screen: a row is acknowledged when it is actually on
/// screen, while this tab is the selected one, its route is visible and the app
/// is in front. Rows further down the list — the ones that would need
/// scrolling to reach — stay unread, along with their phone alerts, until they
/// are scrolled to.
///
/// That is deliberately stricter than "you opened the list". Someone glancing
/// at a badge and backing out has not read anything, and an interaction that
/// arrives while they are looking is not in the set that was on screen, so it
/// stays unread too.
///
/// Tapping a row opens the thing it is about — the post, with the comment
/// revealed, or the conversation with the reacted-to message — which is also
/// where the rest of that post's interactions get read.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../directMessages.dart' show ConversationPage;
import '../../main.dart' show routeObserver;
import '../../profile/ui/profile_theme.dart';
import '../open_feed_post.dart';
import '../social_activity_service.dart';
import '../user_search_repository.dart';
import '../user_search_result.dart';
import 'feed_card.dart' show formatRelativeTime;
import 'user_row.dart';

/// How much of a row must be on screen before it counts as seen.
const double kActivitySeenFraction = 0.6;

class ActivityView extends StatefulWidget {
  const ActivityView({
    super.key,
    required this.active,
    this.service,
    this.search,
    this.viewerUid,
    this.onOpenProfile,
    this.now,
  });

  /// True while this is the selected tab. A tab that is built but not shown
  /// presents nothing.
  final bool active;

  /// Injectable for tests.
  final SocialActivityService? service;
  final UserSearchRepository? search;

  /// The signed-in account, for opening a post with the right permissions.
  final String? viewerUid;

  final void Function(String uid)? onOpenProfile;
  final DateTime? now;

  @override
  State<ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends State<ActivityView>
    with WidgetsBindingObserver, RouteAware {
  SocialActivityService get _service =>
      widget.service ?? SocialActivityService.instance;
  late final UserSearchRepository _search;

  Map<String, UserSearchResult> _people = const <String, UserSearchResult>{};
  final Set<String> _lookedUp = <String>{};
  final Set<String> _onScreen = <String>{};
  bool _routeVisible = true;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _search = widget.search ?? UserSearchRepository();
    WidgetsBinding.instance.addObserver(this);
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
  void didUpdateWidget(covariant ActivityView old) {
    super.didUpdateWidget(old);
    // Switching TO this tab presents whatever is already on screen.
    if (widget.active && !old.active) _acknowledgeVisible();
  }

  @override
  void dispose() {
    if (_route != null) routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

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
    if (visible) _acknowledgeVisible();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _acknowledgeVisible();
  }

  bool get _presenting =>
      widget.active &&
      shouldAcknowledgeActivity(
        routeVisible: _routeVisible,
        appResumed:
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
        signedIn: _service.snapshot.uid != null,
      );

  void _onRowVisibility(SocialActivity item, VisibilityInfo info) {
    final bool seen = info.visibleFraction >= kActivitySeenFraction;
    if (seen) {
      _onScreen.add(item.id);
    } else {
      _onScreen.remove(item.id);
      return;
    }
    if (!_presenting) return;
    _acknowledgeVisible();
  }

  void _acknowledgeVisible() {
    if (!mounted || !_presenting) return;
    final List<SocialActivity> presented = _service.snapshot.unread
        .where((SocialActivity a) => _onScreen.contains(a.id))
        .toList(growable: false);
    if (presented.isEmpty) return;
    unawaited(_service.acknowledge(presented));
  }

  /// One batched identity lookup per page of rows, memoised by the repository —
  /// never one read per row, and a rename or a new avatar appears at once.
  void _resolvePeople(List<SocialActivity> items) {
    final List<String> missing = items
        .map((SocialActivity a) => a.actorUid)
        .where((String uid) => uid.isNotEmpty && _lookedUp.add(uid))
        .toList(growable: false);
    if (missing.isEmpty) return;
    unawaited(() async {
      try {
        final Map<String, UserSearchResult> found =
            await _search.lookupUsers(missing);
        if (!mounted || found.isEmpty) return;
        setState(() => _people = <String, UserSearchResult>{..._people, ...found});
      } catch (_) {
        // Offline: the rows still render with their fallback name, and the
        // lookup is allowed to be tried again later.
        _lookedUp.removeAll(missing);
      }
    }());
  }

  Future<void> _open(SocialActivity item) async {
    if (item.isPostInteraction && item.postId != null) {
      await openPostById(
        context,
        item.postId!,
        viewerUid: widget.viewerUid,
        focusCommentId: item.commentId,
      );
      return;
    }
    if (item.convId != null && item.actorUid.isNotEmpty) {
      // The conversation, with the reacted-to message revealed.
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          convId: item.convId!,
          otherUid: item.actorUid,
          focusMessageId: item.messageId,
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SocialActivity>>(
      stream: _service.watchRecent(),
      builder: (BuildContext context, AsyncSnapshot<List<SocialActivity>> snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Center(
            child: CircularProgressIndicator(color: ProfilePalette.action),
          );
        }
        final List<SocialActivity> items = (snap.data ?? const <SocialActivity>[])
            .where((SocialActivity a) => a.isRenderable)
            .toList(growable: false);
        if (items.isEmpty) {
          return _ActivityEmpty(failed: snap.hasError);
        }
        _resolvePeople(items);

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: ProfileSpacing.sm),
          itemCount: items.length,
          itemBuilder: (BuildContext context, int i) {
            final SocialActivity item = items[i];
            return VisibilityDetector(
              key: Key('activity-${item.id}'),
              onVisibilityChanged: (VisibilityInfo info) =>
                  _onRowVisibility(item, info),
              child: _ActivityRow(
                item: item,
                person: _people[item.actorUid],
                now: widget.now,
                onTap: () => _open(item),
                onOpenProfile: widget.onOpenProfile == null
                    ? null
                    : () => widget.onOpenProfile!(item.actorUid),
              ),
            );
          },
        );
      },
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.item,
    required this.onTap,
    this.person,
    this.onOpenProfile,
    this.now,
  });

  final SocialActivity item;
  final UserSearchResult? person;
  final VoidCallback onTap;
  final VoidCallback? onOpenProfile;
  final DateTime? now;

  String get _name => person?.bestName ?? 'A GoodLift member';

  String get _what {
    switch (item.type) {
      case 'postComment':
        return '$_name commented on your post';
      case 'postLike':
        return '$_name liked your post';
      case 'postGoodLift':
        return '$_name gave your video a Good Lift';
      case 'dmReaction':
        final String emoji = item.emoji ?? '';
        return emoji.isEmpty
            ? '$_name reacted to your message'
            : '$_name reacted $emoji to your message';
      default:
        return _name;
    }
  }

  IconData get _icon {
    switch (item.type) {
      case 'postComment':
        return Icons.mode_comment_outlined;
      case 'postGoodLift':
        return Icons.military_tech_outlined;
      case 'dmReaction':
        return Icons.emoji_emotions_outlined;
      default:
        return Icons.favorite_border;
    }
  }

  @override
  Widget build(BuildContext context) {
    final String age = formatRelativeTime(item.createdAt, now: now);
    final String? preview = item.preview;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: item.read ? null : ProfilePalette.action.withValues(alpha: 0.06),
        padding: const EdgeInsets.symmetric(
          horizontal: ProfileSpacing.lg,
          vertical: ProfileSpacing.sm + 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            GestureDetector(
              onTap: onOpenProfile,
              child: BuddyAvatar(photoURL: person?.photoURL ?? '', size: 38),
            ),
            const SizedBox(width: ProfileSpacing.sm + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(_icon, size: 14, color: ProfilePalette.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _what,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ProfileText.bio(context),
                        ),
                      ),
                      if (age.isNotEmpty) ...<Widget>[
                        const SizedBox(width: ProfileSpacing.sm),
                        Text(age, style: ProfileText.caption(context)),
                      ],
                    ],
                  ),
                  if (preview != null && preview.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Padding(
                      padding: const EdgeInsets.only(left: 20),
                      child: Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ProfileText.caption(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!item.read) ...<Widget>[
              const SizedBox(width: ProfileSpacing.sm),
              Container(
                margin: const EdgeInsets.only(top: 6),
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: ProfilePalette.action,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActivityEmpty extends StatelessWidget {
  const _ActivityEmpty({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ProfileSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              failed ? Icons.cloud_off_rounded : Icons.notifications_none_rounded,
              size: 40,
              color: ProfilePalette.textMuted,
            ),
            const SizedBox(height: ProfileSpacing.md),
            Text(
              failed ? "Couldn't load your activity" : 'Nothing yet',
              style: ProfileText.liftName(context),
            ),
            const SizedBox(height: ProfileSpacing.xs),
            Text(
              failed
                  ? 'Check your connection and try again.'
                  : 'Comments, likes, Good Lifts and reactions to your posts '
                      'and messages show up here.',
              textAlign: TextAlign.center,
              style: ProfileText.bio(context),
            ),
          ],
        ),
      ),
    );
  }
}
