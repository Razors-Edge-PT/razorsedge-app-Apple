/// ACTIVITY — what people did to your posts and your messages.
///
/// ── What marks a row read: nothing here ─────────────────────────────────────
/// This list is a set of POINTERS, not the content. Seeing the line "Sam
/// commented on your post" is not reading Sam's comment, so scrolling a row
/// into view no longer acknowledges anything — an earlier version did that,
/// and it cleared badges and cancelled alerts for comments and reactions the
/// person had still not seen.
///
/// A row is read when its CONTENT is opened and presented: the post with that
/// comment actually on screen (PostActivityScope plus the comments list's own
/// visibility), or the conversation scrolled to the reacted-to message. Tapping
/// a row is what takes you there.
///
/// So opening ACTIVITY, glancing at it and backing out changes nothing, and an
/// interaction that arrives while the list is open stays unread until it too
/// is opened.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../directMessages.dart' show ConversationPage;
import '../../push/foreground_conversation.dart';
import '../../push/foreground_focus.dart';
import '../../push/foreground_post.dart';
import '../../profile/ui/profile_theme.dart';
import '../open_feed_post.dart';
import '../social_activity_service.dart';
import '../user_search_repository.dart';
import '../user_search_result.dart';
import 'feed_card.dart' show formatRelativeTime;
import 'user_row.dart';

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

class _ActivityViewState extends State<ActivityView> {
  SocialActivityService get _service =>
      widget.service ?? SocialActivityService.instance;
  late final UserSearchRepository _search;

  Map<String, UserSearchResult> _people = const <String, UserSearchResult>{};
  final Set<String> _lookedUp = <String>{};

  /// ── One window, grown, rather than two windows stitched together ──────────
  /// This used to be a moving newest-fifty query plus a second query anchored
  /// after whatever record happened to be fiftieth when "show older" was
  /// tapped. The anchor was fixed and the first window was not: one new
  /// interaction pushed the anchor record out of the top query while the
  /// bottom query still began after it, so that record vanished from the list,
  /// and every further arrival widened the hole.
  ///
  /// So there is one live query, and asking for older activity simply asks it
  /// for more. Nothing can fall between two windows when there is only one,
  /// arrivals shift the whole list down together, and every row on screen —
  /// old or new — stays live: read one elsewhere and it shows as read, have
  /// its author withdraw it and it leaves.
  int _limit = SocialActivityService.kListLimit;
  StreamSubscription<List<SocialActivity>>? _sub;
  List<SocialActivity> _items = const <SocialActivity>[];
  bool _loaded = false;
  bool _failed = false;
  bool _loadingOlder = false;

  void _subscribe() {
    _sub?.cancel();
    _sub = _service.watchRecent(limit: _limit).listen(
      (List<SocialActivity> rows) {
        if (!mounted) return;
        setState(() {
          _items = rows;
          _loaded = true;
          _failed = false;
          _loadingOlder = false;
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _loaded = true;
          _failed = true;
          _loadingOlder = false;
        });
      },
    );
  }

  void _loadOlder() {
    if (_loadingOlder) return;
    setState(() {
      _limit += SocialActivityService.kListLimit;
      _loadingOlder = true;
    });
    _subscribe();
  }

  @override
  void initState() {
    super.initState();
    _search = widget.search ?? UserSearchRepository();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant ActivityView old) {
    super.didUpdateWidget(old);
    if (old.service != widget.service) _subscribe();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // No route or lifecycle observers here any more: this list acknowledges
  // nothing, so it has no reason to care whether it is on screen.

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
    // The account that owns this row, captured before any await: a post fetch
    // takes time, and a logout or account switch during it must not land the
    // previous account's content on the new one's screen.
    final String? owner = _service.snapshot.uid ?? widget.viewerUid;
    bool stillValid() =>
        mounted && _service.snapshot.uid == owner && owner != null;

    if (item.isPostInteraction && item.postId != null) {
      // Already looking at that post: move it to this comment instead of
      // stacking another copy.
      if (ForegroundPost.visiblePostId == item.postId &&
          item.commentId != null) {
        ForegroundFocus.request(
          subjectId: item.postId!,
          targetId: item.commentId!,
        );
        return;
      }
      await openPostById(
        context,
        item.postId!,
        viewerUid: widget.viewerUid,
        focusCommentId: item.commentId,
        // The row names its own record, so opening it can acknowledge exactly
        // that interaction however old it is.
        focusActivityId: item.id,
        stillValid: stillValid,
      );
      return;
    }
    if (item.convId != null && item.actorUid.isNotEmpty) {
      if (ForegroundConversation.visibleConvId == item.convId &&
          item.messageId != null) {
        ForegroundFocus.request(
          subjectId: item.convId!,
          targetId: item.messageId!,
        );
        return;
      }
      if (!stillValid()) return;
      // The conversation, with the reacted-to message revealed.
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          convId: item.convId!,
          otherUid: item.actorUid,
          focusMessageId: item.messageId,
          focusActivityId: item.id,
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(
        child: CircularProgressIndicator(color: ProfilePalette.action),
      );
    }
    // One window, newest first. The service already excludes withdrawn
    // records, so anything dropped here is only a kind this build cannot draw.
    final List<SocialActivity> rows = _items;
    final List<SocialActivity> items = rows
        .where((SocialActivity a) => a.isRenderable)
        .toList(growable: false);
    // More was returned than the eye can use? There is more to ask for. A page
    // of records this build cannot render must not become a dead end with real
    // activity stranded behind it, so the decision is made on the RAW count.
    final bool canLoadMore = rows.length >= _limit;
    if (items.isEmpty && !canLoadMore) {
      return _ActivityEmpty(failed: _failed);
    }
    _resolvePeople(items);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: ProfileSpacing.sm),
      itemCount: items.length + (canLoadMore ? 1 : 0),
      itemBuilder: (BuildContext context, int i) {
        if (i == items.length) {
          // Older activity is a tap away rather than lost behind the newest
          // page — an unread interaction from last month is still reachable,
          // and still readable.
          return Padding(
            padding: const EdgeInsets.symmetric(
                vertical: ProfileSpacing.md, horizontal: ProfileSpacing.lg),
            child: Center(
              child: _loadingOlder
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: ProfilePalette.action),
                    )
                  : TextButton(
                      key: const ValueKey<String>('activity-load-older'),
                      onPressed: _loadOlder,
                      child: const Text('Show older activity'),
                    ),
            ),
          );
        }
        final SocialActivity item = items[i];
        return _ActivityRow(
          key: Key('activity-${item.id}'),
          item: item,
          person: _people[item.actorUid],
          now: widget.now,
          onTap: () => _open(item),
          onOpenProfile: widget.onOpenProfile == null
              ? null
              : () => widget.onOpenProfile!(item.actorUid),
        );
      },
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    super.key,
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
