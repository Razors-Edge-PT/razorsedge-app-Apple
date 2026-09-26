/// The lower half of the home page: the buddy Feed or the RE Points
/// Leaderboard, chosen by a switch directly beneath the calendar.
///
/// ── Selection ───────────────────────────────────────────────────────────────
/// Feed is selected whenever the section is created (every launch, every new
/// home page). The choice lives only in this widget's state: it is never
/// persisted, so Leaderboard is never the next session's default — but it
/// survives for as long as the home page does, including a trip into a
/// profile opened from a leaderboard row and back.
///
/// ── Keeping both alive ─────────────────────────────────────────────────────
/// The feed stays mounted while the leaderboard is shown (Offstage), so its
/// loaded rows, cursor and cached cards are all still there on the way back
/// and nothing is fetched twice. While hidden it is told not to page, since
/// the home page's scroll controller keeps moving under the leaderboard. The
/// leaderboard is created the first time it is selected and kept thereafter.
///
/// Neither Feed nor Leaderboard networking lives in the home page: the feed
/// is [HomeBuddyFeedSection], the leaderboard its controller and repository.
library;

import 'package:flutter/material.dart';

import '../leaderboard/leaderboard_controller.dart';
import '../leaderboard/leaderboard_repository.dart';
import '../leaderboard/leaderboard_view.dart';
import '../profile/ui/profile_theme.dart';
import '../social/buddy_repository.dart';
import '../social/feed_repository.dart';
import '../social/home_feed_section.dart';
import '../social/user_search_repository.dart';

enum HomeCommunityTab { feed, leaderboard }

class HomeCommunitySection extends StatefulWidget {
  const HomeCommunitySection({
    super.key,
    required this.scrollController,
    required this.onOpenProfile,
    required this.onOpenPost,
    this.actingAsOtherAccount = false,
    this.feed,
    this.search,
    this.leaderboard,
    this.buddies,
  });

  /// The home page's scroll controller. The feed pages from it.
  final ScrollController scrollController;
  final void Function(String uid) onOpenProfile;
  final void Function(FeedItem item) onOpenPost;
  final bool actingAsOtherAccount;

  /// Injectable for tests; production uses the default repositories.
  final FeedRepository? feed;
  final UserSearchRepository? search;
  final LeaderboardRepository? leaderboard;

  /// The signed-in account's social state, for the leaderboard's friend
  /// gating. For tests; production uses FirebaseAuth's account.
  final BuddyRepository? buddies;

  @override
  State<HomeCommunitySection> createState() => _HomeCommunitySectionState();
}

class _HomeCommunitySectionState extends State<HomeCommunitySection> {
  HomeCommunityTab _tab = HomeCommunityTab.feed;
  LeaderboardController? _leaderboard;

  void _select(HomeCommunityTab next) {
    if (next == _tab) return;
    setState(() {
      _tab = next;
      if (next == HomeCommunityTab.leaderboard) {
        _leaderboard ??= LeaderboardController(
          repository: widget.leaderboard ?? LeaderboardRepository(),
        );
      }
    });
  }

  @override
  void dispose() {
    _leaderboard?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool feedShown = _tab == HomeCommunityTab.feed;
    final LeaderboardController? board = _leaderboard;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _CommunitySwitch(tab: _tab, onSelected: _select),
        const SizedBox(height: ProfileSpacing.md),
        Offstage(
          offstage: !feedShown,
          child: TickerMode(
            enabled: feedShown,
            child: HomeBuddyFeedSection(
              scrollController: widget.scrollController,
              actingAsOtherAccount: widget.actingAsOtherAccount,
              pagingActive: feedShown,
              feed: widget.feed,
              search: widget.search,
              onOpenProfile: widget.onOpenProfile,
              onOpenPost: widget.onOpenPost,
            ),
          ),
        ),
        if (board != null)
          Offstage(
            offstage: feedShown,
            child: TickerMode(
              enabled: !feedShown,
              child: LeaderboardView(
                controller: board,
                onOpenProfile: widget.onOpenProfile,
                buddies: widget.buddies,
              ),
            ),
          ),
      ],
    );
  }
}

/// Feed | Leaderboard — full width, each half a large tap target.
class _CommunitySwitch extends StatelessWidget {
  const _CommunitySwitch({required this.tab, required this.onSelected});

  final HomeCommunityTab tab;
  final ValueChanged<HomeCommunityTab> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: SegmentedButton<HomeCommunityTab>(
        key: const ValueKey<String>('home-community-switch'),
        showSelectedIcon: false,
        style: const ButtonStyle(
          minimumSize: WidgetStatePropertyAll<Size>(Size.fromHeight(48)),
        ),
        segments: const <ButtonSegment<HomeCommunityTab>>[
          ButtonSegment<HomeCommunityTab>(
            value: HomeCommunityTab.feed,
            icon: Icon(Icons.dynamic_feed_outlined, size: 18),
            label: Text('Feed', key: ValueKey<String>('home-tab-feed')),
          ),
          ButtonSegment<HomeCommunityTab>(
            value: HomeCommunityTab.leaderboard,
            icon: Icon(Icons.emoji_events_outlined, size: 18),
            label: Text('Leaderboard',
                key: ValueKey<String>('home-tab-leaderboard')),
          ),
        ],
        selected: <HomeCommunityTab>{tab},
        onSelectionChanged: (Set<HomeCommunityTab> s) => onSelected(s.first),
      ),
    );
  }
}
