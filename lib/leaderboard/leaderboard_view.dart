/// The RE Points leaderboard: This Month / All Time, ranked by the server.
///
/// Sized to its content with NO scrollable of its own — it sits inside a host
/// scroll view (the home page), so there is no nested scrolling and nothing
/// needs an unbounded height. Further pages come from an explicit
/// "Show more" control rather than a scroll listener.
///
/// Every row always shows its public rank, photo, name and RE Points. Opening
/// a profile is gated by the SIGNED-IN account's relationship (never a coach's
/// selected athlete): the viewer's own row and a confirmed friend's row open
/// the existing read-only profile through [onOpenProfile]; anyone else's row
/// offers Add friend (or shows the pending request) and does not open — their
/// profile is not readable to the viewer, and the leaderboard never loosens
/// that. The one exception is the holder of the support profile + DM override
/// (social/access_grants.dart), whom the rules let read any profile: their
/// rows open, and still show the genuine relationship control.
///
/// Category medals (leaderboard_medals.dart) sit beside the name of the row
/// they were awarded to, matched by uid from the board's server snapshot,
/// inside the row's pre-medal height (medal_row_layout.dart). Tapping a medal
/// opens its detail and never the profile; the rest of the row keeps opening
/// the profile exactly as before.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart' show showAppSnack;
import '../profile/ui/profile_theme.dart';
import '../social/access_grants.dart';
import '../social/buddy_repository.dart';
import '../social/ui/user_row.dart' show BuddyAvatar, kMinTouchTarget;
import 'leaderboard_controller.dart';
import 'leaderboard_medals.dart';
import 'leaderboard_models.dart';
import 'leaderboard_repository.dart';
import 'medal_badge.dart';
import 'medal_row_layout.dart';

class LeaderboardView extends StatefulWidget {
  const LeaderboardView({
    super.key,
    required this.onOpenProfile,
    this.controller,
    this.repository,
    this.buddies,
  });

  final void Function(String uid) onOpenProfile;

  /// The signed-in account's social state and request callables. For tests;
  /// production uses FirebaseAuth's account.
  final BuddyRepository? buddies;

  /// Supplied by a host that keeps the state across rebuilds (the home
  /// section). Without one the view creates and owns its own.
  final LeaderboardController? controller;

  /// Used only when the view creates its own controller. For tests.
  final LeaderboardRepository? repository;

  @override
  State<LeaderboardView> createState() => _LeaderboardViewState();
}

class _LeaderboardViewState extends State<LeaderboardView> {
  late final LeaderboardController _c;
  bool _owns = false;

  late final BuddyRepository _buddies = widget.buddies ?? BuddyRepository();
  StreamSubscription<BuddyState>? _socialSub;

  /// The viewer holds the support override: every row opens its profile.
  bool _override = false;
  StreamSubscription<bool>? _overrideSub;
  BuddyState _social = const BuddyState();
  final Set<String> _busy = <String>{};

  /// The server's answer for a just-made request, shown until the live
  /// state agrees — so Add friend is never offered twice for one person.
  final Map<String, BuddyRelationship> _answered = <String, BuddyRelationship>{};

  @override
  void initState() {
    super.initState();
    final LeaderboardController? given = widget.controller;
    if (given != null) {
      _c = given;
    } else {
      _c = LeaderboardController(
          repository: widget.repository ?? LeaderboardRepository());
      _owns = true;
    }
    _c.start();
    // ONE listener set for the whole board, never one per row.
    _socialSub = _buddies.watchState().listen((BuddyState s) {
      if (!mounted) return;
      setState(() {
        _social = s;
        _answered.removeWhere(
            (String uid, BuddyRelationship r) => s.relationshipWith(uid) == r);
      });
    }, onError: (Object _) {});
    final String? me = _buddies.currentUid;
    if (me != null) {
      _overrideSub = AccessGrantsRepository(firestore: _buddies.firestore)
          .watchHolds(me)
          .listen((bool v) {
        if (mounted && v != _override) setState(() => _override = v);
      }, onError: (Object _) {});
    }
  }

  @override
  void dispose() {
    unawaited(_socialSub?.cancel());
    unawaited(_overrideSub?.cancel());
    if (_owns) _c.dispose();
    super.dispose();
  }

  /// The signed-in viewer's relationship with [uid]; null until known.
  BuddyRelationship? _relationshipWith(String uid) {
    final String? me = _buddies.currentUid;
    if (me != null && uid == me) return BuddyRelationship.self;
    final BuddyRelationship? answered = _answered[uid];
    if (answered != null) return answered;
    if (!_social.loaded) return null;
    return _social.relationshipWith(uid);
  }

  Future<void> _mutate(
      String uid, Future<BuddyRelationship> Function() action) async {
    if (_busy.contains(uid)) return;
    setState(() => _busy.add(uid));
    try {
      final BuddyRelationship r = await action();
      if (mounted) setState(() => _answered[uid] = r);
    } catch (err) {
      if (mounted) showAppSnack(describeSocialError(err));
    } finally {
      if (mounted) setState(() => _busy.remove(uid));
    }
  }

  Widget _row(LeaderboardEntry e) {
    final BuddyRelationship? rel = _relationshipWith(e.uid);
    final bool opens = rel == BuddyRelationship.self ||
        rel == BuddyRelationship.friends ||
        (_override && rel != null);
    final LeaderboardRowAction action = switch (rel) {
      BuddyRelationship.none => LeaderboardRowAction.add,
      BuddyRelationship.requested => LeaderboardRowAction.requested,
      BuddyRelationship.incoming => LeaderboardRowAction.accept,
      _ => LeaderboardRowAction.none,
    };
    return LeaderboardRow(
      key: ValueKey<String>('leaderboard-row-${e.uid}'),
      entry: e,
      onTap: opens ? () => widget.onOpenProfile(e.uid) : null,
      medals: _c.medalsFor(e.uid),
      onMedalTap: (LeaderboardMedal m) => showMedalDetail(
        context,
        medal: m,
        athleteName: e.displayName,
        recordSource: _c.medalRecordSource,
        contributions: m.isAllTime ? null : e.contributionsFor(m.categoryKey),
      ),
      action: action,
      busy: _busy.contains(e.uid),
      onAction: switch (action) {
        LeaderboardRowAction.add => () {
            if (_relationshipWith(e.uid) != BuddyRelationship.none) return;
            _mutate(e.uid, () => _buddies.sendRequest(e.uid));
          },
        LeaderboardRowAction.accept => () {
            if (_relationshipWith(e.uid) != BuddyRelationship.incoming) return;
            _mutate(e.uid, () => _buddies.acceptRequest(e.uid));
          },
        _ => null,
      },
    );
  }

  String _caption() {
    final String key = _c.periodKey;
    final String when = _c.period == LeaderboardPeriod.allTime
        ? 'All time'
        : describeMonthKey(key);
    return 'Total RE Points · $when';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PeriodSelector(
            period: _c.period,
            onSelected: (LeaderboardPeriod p) => _c.selectPeriod(p),
          ),
          const SizedBox(height: ProfileSpacing.sm),
          Text(
            _caption(),
            key: const ValueKey<String>('leaderboard-caption'),
            style: ProfileText.caption(context),
          ),
          if (_c.isFromCache && _c.status == LeaderboardStatus.ready)
            Text('Offline — showing the last loaded standings.',
                style: ProfileText.caption(context)),
          const SizedBox(height: ProfileSpacing.sm),
          ..._body(context),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    switch (_c.status) {
      case LeaderboardStatus.idle:
      case LeaderboardStatus.loading:
        return const <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(vertical: ProfileSpacing.xl),
            child: Center(
              child: CircularProgressIndicator(
                  key: ValueKey<String>('leaderboard-loading')),
            ),
          ),
        ];
      case LeaderboardStatus.empty:
        return <Widget>[
          _Message(
            key: const ValueKey<String>('leaderboard-empty'),
            text: _c.period == LeaderboardPeriod.thisMonth
                ? 'No RE Points scored this month yet.'
                : 'No RE Points scored yet.',
          ),
        ];
      case LeaderboardStatus.error:
        return <Widget>[
          _Message(
            key: const ValueKey<String>('leaderboard-error'),
            text: "Couldn't load the leaderboard.",
            action: TextButton(
              key: const ValueKey<String>('leaderboard-retry'),
              onPressed: _c.retry,
              child: const Text('Retry'),
            ),
          ),
        ];
      case LeaderboardStatus.ready:
        return <Widget>[
          for (final LeaderboardEntry e in _c.entries) _row(e),
          if (_c.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: ProfileSpacing.sm),
              child: Center(
                child: _c.loadingMore
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator())
                    : TextButton(
                        key: const ValueKey<String>('leaderboard-more'),
                        onPressed: _c.loadMore,
                        child: const Text('Show more'),
                      ),
              ),
            ),
        ];
    }
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.period, required this.onSelected});

  final LeaderboardPeriod period;
  final ValueChanged<LeaderboardPeriod> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<LeaderboardPeriod>(
      key: const ValueKey<String>('leaderboard-period'),
      showSelectedIcon: false,
      segments: <ButtonSegment<LeaderboardPeriod>>[
        for (final LeaderboardPeriod p in LeaderboardPeriod.values)
          ButtonSegment<LeaderboardPeriod>(
            value: p,
            label: Text(p.label,
                key: ValueKey<String>('leaderboard-period-${p.name}')),
          ),
      ],
      selected: <LeaderboardPeriod>{period},
      onSelectionChanged: (Set<LeaderboardPeriod> s) => onSelected(s.first),
    );
  }
}

/// What a row offers besides its public standing.
enum LeaderboardRowAction { none, add, requested, accept }

/// One ranked athlete: rank, avatar, name, total — always visible — plus the
/// relationship control for a non-friend.
class LeaderboardRow extends StatelessWidget {
  const LeaderboardRow({
    super.key,
    required this.entry,
    required this.onTap,
    this.action = LeaderboardRowAction.none,
    this.onAction,
    this.busy = false,
    this.medals = const <LeaderboardMedal>[],
    this.onMedalTap,
  });

  final LeaderboardEntry entry;

  /// This athlete's medals on the shown board, in category order.
  final List<LeaderboardMedal> medals;

  /// Opens a medal's detail. Never the profile.
  final void Function(LeaderboardMedal medal)? onMedalTap;

  /// Opens the profile. Null when the viewer may not open it: the row and its
  /// avatar then do nothing on tap.
  final VoidCallback? onTap;

  final LeaderboardRowAction action;
  final VoidCallback? onAction;

  /// A request for this athlete is in flight: no second tap.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final TextStyle name = ProfileText.liftName(context);
    final String actionLabel = switch (action) {
      LeaderboardRowAction.add => ', not a friend',
      LeaderboardRowAction.requested => ', friend request sent',
      LeaderboardRowAction.accept => ', sent you a friend request',
      LeaderboardRowAction.none => '',
    };
    final bool hasMedals = medals.isNotEmpty;
    final String medalLabel = hasMedals
        ? ', ${medals.length} medal${medals.length == 1 ? '' : 's'}'
        : '';
    // With medals, the row's visible texts are left out of the tree (the
    // row label says them) so each medal stays its own reachable button.
    Widget plain(Widget w) => hasMedals ? ExcludeSemantics(child: w) : w;
    final Widget nameText = Text(entry.displayName,
        maxLines: 1, overflow: TextOverflow.ellipsis, style: name);
    // Bounded, and scaled down only when it could not otherwise fit (very
    // large accessibility text on a narrow phone), so the row never
    // overflows; at ordinary sizes it is exactly as before.
    final Widget points = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 112),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(entry.pointsLabel, style: ProfileText.recordValue(context)),
            Text('RE pts', style: ProfileText.caption(context)),
          ],
        ),
      ),
    );
    final Widget rowAction = _RowAction(
        uid: entry.uid, action: action, onPressed: onAction, busy: busy);
    final Widget standing = Semantics(
      button: onTap != null,
      label: 'Rank ${entry.rank}, ${entry.displayName}, '
          '${entry.pointsLabel} RE Points$medalLabel$actionLabel',
      // The row's own label; the relationship control and the medals keep
      // their semantics so they stay reachable with a screen reader.
      excludeSemantics: action == LeaderboardRowAction.none && !hasMedals,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ProfileSpacing.radiusSmall),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTouchTarget + 8),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: ProfileSpacing.xs, vertical: ProfileSpacing.xs),
            child: Row(
              children: <Widget>[
                plain(SizedBox(
                  width: 36,
                  child: Text('${entry.rank}',
                      textAlign: TextAlign.center,
                      style:
                          name.copyWith(color: ProfilePalette.textSecondary)),
                )),
                const SizedBox(width: ProfileSpacing.sm),
                BuddyAvatar(photoURL: entry.photoURL ?? '', size: 40),
                const SizedBox(width: ProfileSpacing.md),
                if (!hasMedals) ...<Widget>[
                  Expanded(
                    child: action == LeaderboardRowAction.none
                        ? nameText
                        // The relationship control sits under the name, so
                        // rank, photo and points keep their full width on
                        // narrow phones.
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[nameText, rowAction],
                          ),
                  ),
                  const SizedBox(width: ProfileSpacing.sm),
                  points,
                ] else
                  // With medals, the row keeps its medal-less height: the
                  // coins take only space already free beside the name or
                  // the relationship control.
                  Expanded(
                    child: MedalRowLayout(
                      key: ValueKey<String>('leaderboard-medals-${entry.uid}'),
                      minContentHeight:
                          kMinTouchTarget + 8 - 2 * ProfileSpacing.xs,
                      nameMinWidth:
                          _firstCharWidth(context, entry.displayName, name),
                      name: plain(nameText),
                      points: plain(points),
                      medals: <Widget>[
                        for (final LeaderboardMedal m in medals)
                          MedalButton(
                              medal: m, onTap: () => onMedalTap?.call(m)),
                      ],
                      action: action == LeaderboardRowAction.none
                          ? null
                          : rowAction,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return standing;
  }
}

/// The width of [name]'s first character and an ellipsis, as drawn: the least
/// of the name a medal row may show.
double _firstCharWidth(BuildContext context, String name, TextStyle style) {
  final Characters chars = name.characters;
  final TextPainter p = TextPainter(
    text: TextSpan(
        text: '${chars.isEmpty ? '' : chars.first}…', style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final double w = p.width.ceilToDouble() + 1;
  p.dispose();
  return w;
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.uid,
    required this.action,
    required this.onPressed,
    required this.busy,
  });

  final String uid;
  final LeaderboardRowAction action;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: kMinTouchTarget,
        height: kMinTouchTarget,
        child: Center(
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    final ButtonStyle compact = TextButton.styleFrom(
      minimumSize: const Size(kMinTouchTarget, kMinTouchTarget),
      padding: const EdgeInsets.symmetric(horizontal: ProfileSpacing.xs),
      visualDensity: VisualDensity.compact,
      alignment: Alignment.centerLeft,
    );
    switch (action) {
      case LeaderboardRowAction.add:
        return TextButton.icon(
          key: ValueKey<String>('leaderboard-add-$uid'),
          style: compact,
          onPressed: onPressed,
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: const Text('Add friend'),
        );
      case LeaderboardRowAction.accept:
        return FilledButton.tonal(
          key: ValueKey<String>('leaderboard-accept-$uid'),
          style: compact,
          onPressed: onPressed,
          child: const Text('Accept'),
        );
      case LeaderboardRowAction.requested:
        // Pending: shown as a state, never another request.
        return Padding(
          key: ValueKey<String>('leaderboard-requested-$uid'),
          padding: const EdgeInsets.symmetric(vertical: ProfileSpacing.xs),
          child: Text('Requested', style: ProfileText.caption(context)),
        );
      case LeaderboardRowAction.none:
        return const SizedBox.shrink();
    }
  }
}

class _Message extends StatelessWidget {
  const _Message({super.key, required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: ProfileSpacing.lg),
      child: Column(
        children: <Widget>[
          Text(text,
              textAlign: TextAlign.center, style: ProfileText.bio(context)),
          if (action != null) action!,
        ],
      ),
    );
  }
}
