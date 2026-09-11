/// The buddy feed as it sits on the home page: directly beneath the calendar,
/// with no heading, tab or switcher in front of it.
///
/// ── The same feed, not a second one ────────────────────────────────────────
/// This is [BuddyFeedView] — the widget behind the Buddy Hub's FEED tab — with
/// the same repository, cursor paging, de-duplication, fill-up, card renderer,
/// disk-cached media, post opening and empty / offline / error / retry states.
/// The only difference is who owns the scrolling: the home page already has an
/// outer scroll view (quick actions, calendar, feed), so the feed shrink-wraps
/// into it and pages from the host's [scrollController] instead of nesting a
/// second scrollable inside the first.
///
/// ── Whose feed it is ───────────────────────────────────────────────────────
/// The SIGNED-IN account's, always. [BuddyFeedView]'s default repository
/// resolves the account from FirebaseAuth, never from a coach's "acting as"
/// athlete, so the feed does not change when a coach selects somebody. Because
/// everything else on the home page DOES follow the selected athlete, the
/// section says so in that case rather than letting the feed read as theirs.
library;

import 'package:flutter/material.dart';

import '../profile/ui/profile_theme.dart';
import 'feed_repository.dart';
import 'feed_view.dart';
import 'user_search_repository.dart';

/// Shown above the feed while a coach is viewing another account.
const String kHomeOwnFeedNotice =
    'Your own buddy feed — coaching an athlete does not change it.';

class HomeBuddyFeedSection extends StatelessWidget {
  const HomeBuddyFeedSection({
    super.key,
    required this.scrollController,
    required this.onOpenProfile,
    required this.onOpenPost,
    this.actingAsOtherAccount = false,
    this.feed,
    this.search,
  });

  /// The home page's own scroll controller. The feed pages from it.
  final ScrollController scrollController;

  final void Function(String uid) onOpenProfile;
  final void Function(FeedItem item) onOpenPost;

  /// True when the rest of the home page is showing somebody else — a coach
  /// with an athlete selected. Presentation only: it adds a caption and cannot
  /// change which account's feed is read.
  final bool actingAsOtherAccount;

  /// Injectable for tests. Production uses the default repositories, which
  /// resolve the AUTHENTICATED account.
  final FeedRepository? feed;
  final UserSearchRepository? search;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (actingAsOtherAccount) const _OwnFeedNotice(),
        BuddyFeedView(
          scrollController: scrollController,
          feed: feed,
          search: search,
          onOpenProfile: onOpenProfile,
          onOpenPost: onOpenPost,
        ),
      ],
    );
  }
}

class _OwnFeedNotice extends StatelessWidget {
  const _OwnFeedNotice();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: ProfileSpacing.sm),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.person_outline_rounded,
            size: 14,
            color: ProfilePalette.textMuted,
          ),
          const SizedBox(width: ProfileSpacing.xs),
          Expanded(
            child: Text(
              kHomeOwnFeedNotice,
              style: ProfileText.caption(context),
            ),
          ),
        ],
      ),
    );
  }
}
