/// The scrolling buddy feed, shared by the Buddy Hub's FEED tab and the home
/// page's section below the calendar.
///
/// ── One widget, two hosts ──────────────────────────────────────────────────
/// The Buddy Hub gives it a whole tab and lets it own the scroll. The home page
/// has its own outer scroll view — the calendar, the quick-action cards and the
/// feed switcher all live in it — and a nested scrollable inside that would be
/// two scroll gestures fighting over one finger. So [BuddyFeedView] renders as
/// a sliver-free, shrink-wrapped column when [scrollController] is supplied by
/// the host, and pages from THAT controller instead of its own.
///
/// ── What paging costs ──────────────────────────────────────────────────────
/// One ordered query per page against `users/{uid}/feed`, already filtered to
/// what this viewer may see, plus ONE batched identity lookup for the distinct
/// owners on that page. A page of twelve posts by three people is two reads and
/// a lookup of three, not twelve profile reads. See [FeedRepository] for why
/// the projection makes that possible.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../profile/ui/profile_theme.dart';
import 'feed_repository.dart';
import 'ui/feed_card.dart';
import 'user_search_repository.dart';
import 'user_search_result.dart';

/// How close to the end of the list a scroll gets before the next page starts.
///
/// Far enough that the page usually lands before the reader arrives, so the
/// feed does not visibly stall; near enough that a reader who stops after one
/// screen has not paid for three.
const double kFeedPrefetchExtent = 600;

/// What the feed is currently doing, so the footer can say so honestly.
enum FeedStatus { idle, loadingFirst, loadingMore, error, offline }

class BuddyFeedView extends StatefulWidget {
  const BuddyFeedView({
    super.key,
    this.feed,
    this.search,
    this.onOpenProfile,
    this.onOpenPost,
    this.scrollController,
    this.shrinkWrap = false,
    this.now,
  });

  /// Injectable for tests. Production uses the default repositories, which
  /// resolve the AUTHENTICATED account.
  final FeedRepository? feed;
  final UserSearchRepository? search;

  final void Function(String uid)? onOpenProfile;
  final void Function(FeedItem item)? onOpenPost;

  /// The host's scroll controller. When supplied the view does not scroll on
  /// its own — it shrink-wraps into the host's scroll view and watches this
  /// controller for the end-of-list prefetch.
  final ScrollController? scrollController;

  /// True when embedded in a host scroll view. Implied by [scrollController]
  /// but stated separately so a host can shrink-wrap without paging.
  final bool shrinkWrap;

  /// Injectable clock for the relative timestamps. For tests.
  final DateTime? now;

  @override
  State<BuddyFeedView> createState() => _BuddyFeedViewState();
}

class _BuddyFeedViewState extends State<BuddyFeedView> {
  late final FeedRepository _feed;
  late final UserSearchRepository _search;
  late final ScrollController _scroll;
  bool _ownsScrollController = false;

  List<FeedItem> _items = const <FeedItem>[];
  Map<String, UserSearchResult> _owners = const <String, UserSearchResult>{};
  DocumentSnapshot<Map<String, dynamic>>? _cursor;
  bool _hasMore = true;
  FeedStatus _status = FeedStatus.loadingFirst;
  Object? _error;

  /// True while a page request is in flight. Separate from [_status] because
  /// the guard must hold even during the frame in which the status has not yet
  /// been painted — without it a fast scroll fires several page loads for the
  /// same cursor and the same rows arrive three times.
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _feed = widget.feed ?? FeedRepository();
    _search = widget.search ?? UserSearchRepository();
    final ScrollController? host = widget.scrollController;
    if (host != null) {
      _scroll = host;
    } else {
      _scroll = ScrollController();
      _ownsScrollController = true;
    }
    _scroll.addListener(_onScroll);
    unawaited(_loadFirstPage());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    // Only a controller this widget created may be disposed here. Disposing
    // the host's would break every other section of their scroll view.
    if (_ownsScrollController) _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    final ScrollPosition pos = _scroll.position;
    if (pos.maxScrollExtent - pos.pixels < kFeedPrefetchExtent) {
      unawaited(_loadNextPage());
    }
  }

  /// Fetches another page when the one just loaded did not fill the screen.
  ///
  /// Paging is driven by scrolling, and a list shorter than its viewport never
  /// scrolls — so without this a short first page is the LAST page as far as
  /// the reader is concerned, however much more there is. It shows up on a
  /// tall screen, and on a feed whose first page is mostly ineligible rows
  /// that were filtered out after the fetch.
  ///
  /// Bounded by the same `_hasMore` and `_loading` guards as every other page
  /// load, so it stops as soon as the feed is exhausted or the viewport fills.
  void _fillViewportIfNeeded() {
    if (!mounted || _loading || !_hasMore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || !_hasMore) return;
      if (!_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent > 0) return;
      unawaited(_loadNextPage());
    });
  }

  Future<void> _loadFirstPage() async {
    if (_loading) return;
    _loading = true;
    if (mounted) setState(() => _status = FeedStatus.loadingFirst);
    await _load(cursor: null, replace: true, fromServer: false);
  }

  Future<void> _loadNextPage() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    if (mounted) setState(() => _status = FeedStatus.loadingMore);
    await _load(cursor: _cursor, replace: false, fromServer: false);
  }

  /// Pull-to-refresh, and the Retry affordance.
  ///
  /// Deliberately does NOT clear [_items] first. Emptying the list to show a
  /// spinner throws away content the reader is looking at — and if the refresh
  /// fails they are left with nothing where a moment ago there was a feed. New
  /// rows are merged in instead, so the view only ever gains.
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    if (mounted) {
      setState(() {
        _status = _items.isEmpty ? FeedStatus.loadingFirst : FeedStatus.idle;
      });
    }
    await _load(cursor: null, replace: false, fromServer: true);
  }

  Future<void> _load({
    required DocumentSnapshot<Map<String, dynamic>>? cursor,
    required bool replace,
    required bool fromServer,
  }) async {
    try {
      final FeedPage page = await _feed.loadPage(
        cursor: cursor,
        fromServer: fromServer,
      );
      // Identity for the DISTINCT owners of this page only, batched and
      // memoised by the search repository — never one read per card.
      final Map<String, UserSearchResult> people = await _search.lookupUsers(
        FeedRepository.distinctOwners(page.items),
      );
      if (!mounted) return;
      setState(() {
        _items = replace
            ? FeedRepository.merge(const <FeedItem>[], page.items)
            : FeedRepository.merge(_items, page.items);
        _owners = <String, UserSearchResult>{..._owners, ...people};
        // A refresh restarts from the top, so it must not move the paging
        // cursor backwards — that would re-fetch page one forever.
        if (cursor != null || _cursor == null) _cursor = page.cursor;
        _hasMore = page.hasMore;
        _status = page.fromCache && page.items.isEmpty
            ? FeedStatus.offline
            : FeedStatus.idle;
        _error = null;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err;
        // An error while rows are already on screen is a footer message, not a
        // reason to replace a readable feed with an error page.
        _status = FeedStatus.error;
        _hasMore = false;
      });
    } finally {
      _loading = false;
      _fillViewportIfNeeded();
    }
  }

  void _openProfile(String uid) => widget.onOpenProfile?.call(uid);

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      final Widget state = _emptyState();
      return widget.shrinkWrap || widget.scrollController != null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: ProfileSpacing.xl),
              child: state,
            )
          : RefreshIndicator(
              onRefresh: refresh,
              color: ProfilePalette.action,
              backgroundColor: ProfilePalette.surface,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: state,
                  ),
                ],
              ),
            );
    }

    final List<Widget> children = <Widget>[
      for (final FeedItem item in _items)
        FeedCard(
          key: ValueKey<String>(item.id),
          item: item,
          owner: _owners[item.ownerUid],
          now: widget.now,
          onOpen: widget.onOpenPost == null
              ? null
              : () => widget.onOpenPost!(item),
          onOpenProfile: widget.onOpenProfile == null
              ? null
              : () => _openProfile(item.ownerUid),
        ),
      _Footer(status: _status, hasMore: _hasMore, error: _error, onRetry: refresh),
    ];

    if (widget.shrinkWrap || widget.scrollController != null) {
      // Embedded: the host owns the scrolling, so this is a plain column —
      // which means every card of every loaded page is BUILT, on screen or
      // not. Cheap for a header and a caption; not cheap for media, so each
      // card loads its picture only as it approaches the viewport. See
      // kFeedMediaLookAhead in ui/feed_card.dart.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    return RefreshIndicator(
      onRefresh: refresh,
      color: ProfilePalette.action,
      backgroundColor: ProfilePalette.surface,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: children.length,
        itemBuilder: (BuildContext context, int i) => children[i],
      ),
    );
  }

  Widget _emptyState() {
    switch (_status) {
      case FeedStatus.loadingFirst:
        return const Center(
          child: CircularProgressIndicator(color: ProfilePalette.action),
        );
      case FeedStatus.offline:
        return _FeedMessage(
          icon: Icons.cloud_off_rounded,
          title: "You're offline",
          body: 'Your buddies\' recent posts will appear when you reconnect.',
          onRetry: refresh,
        );
      case FeedStatus.error:
        return _FeedMessage(
          icon: Icons.error_outline_rounded,
          title: "Couldn't load the feed",
          body: 'Something went wrong on the way to the server.',
          onRetry: refresh,
        );
      case FeedStatus.idle:
      case FeedStatus.loadingMore:
        return const _FeedMessage(
          icon: Icons.photo_library_outlined,
          title: 'Nothing here yet',
          body: 'Posts from you and your buddies show up here.',
        );
    }
  }
}

/// The end of the list: a spinner, a retry, or nothing at all.
///
/// Never an indefinite spinner. When there is no more to fetch the footer
/// disappears, so a reader who has reached the end sees the end rather than
/// something that looks permanently busy.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.status,
    required this.hasMore,
    required this.error,
    required this.onRetry,
  });

  final FeedStatus status;
  final bool hasMore;
  final Object? error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (status == FeedStatus.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: ProfileSpacing.lg),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: ProfilePalette.action,
            ),
          ),
        ),
      );
    }
    if (status == FeedStatus.error) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: ProfileSpacing.md),
        child: Center(
          child: TextButton.icon(
            onPressed: () => onRetry(),
            icon: const Icon(
              Icons.refresh_rounded,
              size: 18,
              color: ProfilePalette.action,
            ),
            label: Text(
              'Retry',
              style: ProfileText.button(context)
                  .copyWith(color: ProfilePalette.action),
            ),
          ),
        ),
      );
    }
    if (!hasMore) {
      return const SizedBox(height: ProfileSpacing.xl);
    }
    return const SizedBox(height: ProfileSpacing.xl);
  }
}

class _FeedMessage extends StatelessWidget {
  const _FeedMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.onRetry,
  });

  final IconData icon;
  final String title;
  final String body;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ProfileSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: ProfilePalette.textMuted),
            const SizedBox(height: ProfileSpacing.md),
            Text(title, style: ProfileText.liftName(context)),
            const SizedBox(height: ProfileSpacing.xs),
            Text(
              body,
              textAlign: TextAlign.center,
              style: ProfileText.bio(context),
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: ProfileSpacing.sm),
              TextButton(
                onPressed: () => onRetry!(),
                child: Text(
                  'Try again',
                  style: ProfileText.button(context)
                      .copyWith(color: ProfilePalette.action),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
