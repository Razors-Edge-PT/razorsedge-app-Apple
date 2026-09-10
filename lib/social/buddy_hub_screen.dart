/// The Buddy Hub: find people, manage requests, and see what buddies posted.
///
/// Replaces the legacy buddy dialog and the search screen behind it. Two views,
/// because there are two questions — "who is this person?" and "what have my
/// buddies been doing?" — and the old UI answered the first with an alert
/// dialog and never answered the second at all.
///
/// Opened on [BuddyHubTab.people] from the header icon, because that icon means
/// "someone wants to be your buddy" and the requests are what the person came
/// to see.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart' show showAppSnack;
import '../profile/profile_screen.dart';
import '../profile/ui/profile_theme.dart';
import 'buddy_repository.dart';
import 'feed_repository.dart';
import 'feed_view.dart';
import 'open_feed_post.dart';
import 'ui/user_row.dart';
import 'user_search_repository.dart';
import 'user_search_result.dart';

enum BuddyHubTab { people, feed }

/// How long typing settles before a query is sent.
///
/// Long enough that a word typed at speed costs one query rather than one per
/// letter; short enough that it still feels immediate. Every keystroke inside
/// the window cancels the pending send, and [UserSearchRepository.search]
/// separately discards any response that a newer search has overtaken.
const Duration kSearchDebounce = Duration(milliseconds: 300);

class BuddyHubScreen extends StatefulWidget {
  const BuddyHubScreen({
    super.key,
    this.initialTab = BuddyHubTab.people,
    this.buddies,
    this.search,
  });

  final BuddyHubTab initialTab;

  /// Injectable for tests. Production uses the default repositories, which
  /// resolve the AUTHENTICATED account — never a coach's selected athlete.
  final BuddyRepository? buddies;
  final UserSearchRepository? search;

  @override
  State<BuddyHubScreen> createState() => _BuddyHubScreenState();
}

class _BuddyHubScreenState extends State<BuddyHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final BuddyRepository _buddies;
  late final UserSearchRepository _search;
  final TextEditingController _queryController = TextEditingController();

  Timer? _debounce;
  String _query = '';
  bool _searching = false;
  UserSearchOutcome? _outcome;

  /// Accounts with a mutation in flight, so a row cannot be double-submitted
  /// and the rest of the list stays usable while one row works.
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab == BuddyHubTab.feed ? 1 : 0,
    );
    _buddies = widget.buddies ?? BuddyRepository();
    _search = widget.search ?? UserSearchRepository();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _onQueryChanged(String raw) {
    _debounce?.cancel();
    setState(() => _query = raw);
    if (!UserSearchRepository.isQueryLongEnough(raw)) {
      setState(() {
        _outcome = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(kSearchDebounce, () => _runSearch(raw));
  }

  Future<void> _runSearch(String raw) async {
    final UserSearchOutcome? outcome = await _search.search(
      rawQuery: raw,
      excludeUid: _buddies.currentUid,
    );
    if (!mounted) return;
    // Null means a newer search overtook this one. Rendering it would replace
    // the current results with results for a prefix already typed past.
    if (outcome == null) return;
    setState(() {
      _outcome = outcome;
      _searching = false;
    });
  }

  void _clearQuery() {
    _debounce?.cancel();
    _queryController.clear();
    setState(() {
      _query = '';
      _outcome = null;
      _searching = false;
    });
  }

  /// Runs a relationship mutation, keeping the row honest about what happened.
  ///
  /// There is no optimistic success here. These are two-account transactions
  /// with no durable outbox behind them, so showing "Requested" for something
  /// that never left the device would be a state the UI never corrects.
  Future<void> _mutate(String uid, Future<BuddyRelationship> Function() action) async {
    if (_busy.contains(uid)) return;
    setState(() => _busy.add(uid));
    try {
      await action();
    } catch (err) {
      if (mounted) showAppSnack(describeSocialError(err));
    } finally {
      if (mounted) {
        setState(() => _busy.remove(uid));
      }
    }
  }

  void _openProfile(String uid) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      // The existing rebuilt profile page, in visitor mode. Not a second,
      // feed-specific profile screen: ownership — and therefore every edit
      // control — is decided by ProfileController.isOwner, so a visitor gets a
      // read-only page without this caller having to enforce anything.
      builder: (_) => ProfileScreen(viewedUid: uid, readOnly: true),
    ));
  }

  void _openPost(FeedItem item) {
    unawaited(openFeedPost(context, item, viewerUid: _buddies.currentUid));
  }

  Future<void> _confirmRemove(String uid, String name) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: ProfilePalette.surface,
        title: Text('Remove $name?', style: ProfileText.liftName(ctx)),
        content: Text(
          "You'll both stop seeing each other's posts.",
          style: ProfileText.bio(ctx),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: ProfilePalette.danger),
            ),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _mutate(uid, () => _buddies.removeFriend(uid));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ProfilePalette.navy,
      appBar: AppBar(
        backgroundColor: ProfilePalette.navy,
        elevation: 0,
        title: Text('Buddies', style: ProfileText.username(context)),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: ProfilePalette.action,
          labelColor: ProfilePalette.textPrimary,
          unselectedLabelColor: ProfilePalette.textMuted,
          labelStyle: ProfileText.sectionTitle(context),
          tabs: const <Widget>[
            Tab(text: 'PEOPLE'),
            Tab(text: 'FEED'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: <Widget>[
          _buildPeople(),
          BuddyFeedView(
            search: _search,
            onOpenProfile: _openProfile,
            onOpenPost: _openPost,
          ),
        ],
      ),
    );
  }

  // ── People ────────────────────────────────────────────────────────────────

  Widget _buildPeople() {
    return Column(
      children: <Widget>[
        _SearchField(
          controller: _queryController,
          onChanged: _onQueryChanged,
          onClear: _clearQuery,
          hasText: _query.isNotEmpty,
        ),
        Expanded(
          child: StreamBuilder<BuddyState>(
            // ONE listener for the whole screen, not one per row.
            stream: _buddies.watchState(),
            builder: (BuildContext context, AsyncSnapshot<BuddyState> snap) {
              final BuddyState state = snap.data ?? const BuddyState();
              if (_query.isNotEmpty) return _buildSearchResults(state);
              return _buildRelationships(state, snap);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSearchResults(BuddyState state) {
    if (!UserSearchRepository.isQueryLongEnough(_query)) {
      return const _Hint(
        icon: Icons.search_rounded,
        title: 'Keep typing',
        body: 'Enter at least two characters to search.',
      );
    }
    if (_searching && _outcome == null) {
      return const Center(
        child: CircularProgressIndicator(color: ProfilePalette.action),
      );
    }
    final UserSearchOutcome? outcome = _outcome;
    if (outcome == null) {
      return const SizedBox.shrink();
    }
    if (outcome.isEmpty) {
      return _Hint(
        icon: outcome.offline ? Icons.cloud_off_rounded : Icons.person_search_outlined,
        title: outcome.offline ? "You're offline" : 'No one found',
        body: outcome.offline
            // Not "no such person": an empty list because the connection
            // dropped is a different answer, and claiming the first would be a
            // lie about somebody's account.
            ? 'Reconnect to search for new people.'
            : 'Check the spelling, or try their username.',
      );
    }

    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: outcome.results.length + (outcome.offline ? 1 : 0),
      itemBuilder: (BuildContext context, int i) {
        if (outcome.offline && i == 0) {
          return const _OfflineBanner(
            message: 'Offline — showing people you looked at recently.',
          );
        }
        final UserSearchResult user =
            outcome.results[outcome.offline ? i - 1 : i];
        return _resultRow(user, state);
      },
    );
  }

  Widget _resultRow(UserSearchResult user, BuddyState state) {
    final BuddyRelationship rel = state.relationshipWith(user.uid);
    return BuddyUserRow(
      displayName: user.bestName,
      handle: user.handle,
      photoURL: user.photoURL,
      action: actionForRelationship(rel),
      busy: _busy.contains(user.uid),
      // Only a confirmed buddy's profile is reachable. Offering the tap to
      // anyone else would open a page the rules deny.
      onTap: rel == BuddyRelationship.friends
          ? () => _openProfile(user.uid)
          : null,
      onPrimary: () {
        switch (rel) {
          case BuddyRelationship.none:
            _mutate(user.uid, () => _buddies.sendRequest(user.uid));
          case BuddyRelationship.requested:
            _mutate(user.uid, () => _buddies.cancelRequest(user.uid));
          case BuddyRelationship.incoming:
            _mutate(user.uid, () => _buddies.acceptRequest(user.uid));
          case BuddyRelationship.friends:
            _confirmRemove(user.uid, user.bestName);
          case BuddyRelationship.self:
            break;
        }
      },
      onSecondary: rel == BuddyRelationship.incoming
          ? () => _mutate(user.uid, () => _buddies.declineRequest(user.uid))
          : null,
    );
  }

  Widget _buildRelationships(BuddyState state, AsyncSnapshot<BuddyState> snap) {
    if (!state.loaded && snap.connectionState == ConnectionState.waiting) {
      return const Center(
        child: CircularProgressIndicator(color: ProfilePalette.action),
      );
    }
    if (state.incoming.isEmpty &&
        state.outgoing.isEmpty &&
        state.friends.isEmpty) {
      return const _Hint(
        icon: Icons.group_add_outlined,
        title: 'No buddies yet',
        body: 'Search for a training partner by name or username.',
      );
    }

    final List<String> uids = <String>{
      ...state.incoming.map((IncomingRequest r) => r.fromUid),
      ...state.outgoing.map((OutgoingRequest r) => r.toUid),
      ...state.friends,
    }.toList(growable: false);

    return FutureBuilder<Map<String, UserSearchResult>>(
      // One batched lookup for every distinct account on the screen — never
      // one read per row.
      future: _search.lookupUsers(uids),
      builder: (
        BuildContext context,
        AsyncSnapshot<Map<String, UserSearchResult>> people,
      ) {
        final Map<String, UserSearchResult> byUid =
            people.data ?? const <String, UserSearchResult>{};
        return ListView(
          children: <Widget>[
            if (state.incoming.isNotEmpty) ...<Widget>[
              const _SectionHeader('REQUESTS'),
              for (final IncomingRequest r in state.incoming)
                _row(
                  uid: r.fromUid,
                  fallbackName: r.fromDisplayName,
                  people: byUid,
                  action: BuddyRowAction.respond,
                  onPrimary: () =>
                      _mutate(r.fromUid, () => _buddies.acceptRequest(r.fromUid)),
                  onSecondary: () =>
                      _mutate(r.fromUid, () => _buddies.declineRequest(r.fromUid)),
                ),
            ],
            if (state.outgoing.isNotEmpty) ...<Widget>[
              const _SectionHeader('SENT'),
              for (final OutgoingRequest r in state.outgoing)
                _row(
                  uid: r.toUid,
                  fallbackName: r.displayName,
                  people: byUid,
                  action: BuddyRowAction.requested,
                  subtitle: 'Waiting for a reply',
                  onPrimary: () =>
                      _mutate(r.toUid, () => _buddies.cancelRequest(r.toUid)),
                ),
            ],
            if (state.friends.isNotEmpty) ...<Widget>[
              _SectionHeader('BUDDIES · ${state.friends.length}'),
              for (final String uid in state.friends)
                _row(
                  uid: uid,
                  fallbackName: '',
                  people: byUid,
                  action: BuddyRowAction.friends,
                  onTap: () => _openProfile(uid),
                  onPrimary: () => _confirmRemove(
                    uid,
                    byUid[uid]?.bestName ?? 'this buddy',
                  ),
                ),
            ],
            const SizedBox(height: ProfileSpacing.xl),
          ],
        );
      },
    );
  }

  Widget _row({
    required String uid,
    required String fallbackName,
    required Map<String, UserSearchResult> people,
    required BuddyRowAction action,
    String? subtitle,
    VoidCallback? onTap,
    VoidCallback? onPrimary,
    VoidCallback? onSecondary,
  }) {
    final UserSearchResult? user = people[uid];
    return BuddyUserRow(
      // The denormalised name on the invite is the fallback, so a request row
      // still names someone when the lookup has not landed or failed offline.
      displayName: user?.bestName ??
          (fallbackName.trim().isEmpty ? 'GoodLift member' : fallbackName),
      handle: user?.handle ?? '',
      photoURL: user?.photoURL ?? '',
      action: action,
      busy: _busy.contains(uid),
      subtitle: subtitle,
      onTap: onTap,
      onPrimary: onPrimary,
      onSecondary: onSecondary,
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.hasText,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool hasText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ProfileSpacing.lg,
        ProfileSpacing.md,
        ProfileSpacing.lg,
        ProfileSpacing.sm,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        autocorrect: false,
        enableSuggestions: false,
        style: ProfileText.bio(context)
            .copyWith(color: ProfilePalette.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          hintText: 'Search by name or username',
          hintStyle: ProfileText.bio(context),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: ProfilePalette.textMuted,
          ),
          suffixIcon: hasText
              ? IconButton(
                  onPressed: onClear,
                  tooltip: 'Clear search',
                  icon: const Icon(
                    Icons.close_rounded,
                    color: ProfilePalette.textMuted,
                  ),
                )
              : null,
          filled: true,
          fillColor: ProfilePalette.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ProfileSpacing.radius),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ProfileSpacing.radius),
            borderSide: const BorderSide(color: ProfilePalette.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(ProfileSpacing.radius),
            borderSide: const BorderSide(color: ProfilePalette.action),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ProfileSpacing.lg,
        ProfileSpacing.lg,
        ProfileSpacing.lg,
        ProfileSpacing.xs,
      ),
      child: Text(label, style: ProfileText.recordLabel(context)),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        ProfileSpacing.lg,
        ProfileSpacing.xs,
        ProfileSpacing.lg,
        ProfileSpacing.sm,
      ),
      padding: const EdgeInsets.all(ProfileSpacing.md),
      decoration: BoxDecoration(
        color: ProfilePalette.surface,
        borderRadius: BorderRadius.circular(ProfileSpacing.radiusSmall),
        border: Border.all(color: ProfilePalette.outline),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.cloud_off_rounded,
            size: 16,
            color: ProfilePalette.textMuted,
          ),
          const SizedBox(width: ProfileSpacing.sm),
          Expanded(
            child: Text(message, style: ProfileText.caption(context)),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

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
          ],
        ),
      ),
    );
  }
}
