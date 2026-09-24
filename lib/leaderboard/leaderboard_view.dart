/// The RE Points leaderboard: This Month / All Time, ranked by the server.
///
/// Sized to its content with NO scrollable of its own — it sits inside a host
/// scroll view (the home page), so there is no nested scrolling and nothing
/// needs an unbounded height. Further pages come from an explicit
/// "Show more" control rather than a scroll listener.
///
/// Tapping a row opens that athlete's existing read-only profile through
/// [onOpenProfile]; there is no separate leaderboard profile screen.
library;

import 'package:flutter/material.dart';

import '../profile/ui/profile_theme.dart';
import '../social/ui/user_row.dart' show BuddyAvatar, kMinTouchTarget;
import 'leaderboard_controller.dart';
import 'leaderboard_models.dart';
import 'leaderboard_repository.dart';

class LeaderboardView extends StatefulWidget {
  const LeaderboardView({
    super.key,
    required this.onOpenProfile,
    this.controller,
    this.repository,
  });

  final void Function(String uid) onOpenProfile;

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
  }

  @override
  void dispose() {
    if (_owns) _c.dispose();
    super.dispose();
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
          for (final LeaderboardEntry e in _c.entries)
            LeaderboardRow(
              key: ValueKey<String>('leaderboard-row-${e.uid}'),
              entry: e,
              onTap: () => widget.onOpenProfile(e.uid),
            ),
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

/// One ranked athlete: rank, avatar, name, total.
class LeaderboardRow extends StatelessWidget {
  const LeaderboardRow({super.key, required this.entry, required this.onTap});

  final LeaderboardEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextStyle name = ProfileText.liftName(context);
    return Semantics(
      button: true,
      label: 'Rank ${entry.rank}, ${entry.displayName}, '
          '${entry.pointsLabel} RE Points',
      excludeSemantics: true,
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
                SizedBox(
                  width: 36,
                  child: Text('${entry.rank}',
                      textAlign: TextAlign.center,
                      style:
                          name.copyWith(color: ProfilePalette.textSecondary)),
                ),
                const SizedBox(width: ProfileSpacing.sm),
                BuddyAvatar(photoURL: entry.photoURL ?? '', size: 40),
                const SizedBox(width: ProfileSpacing.md),
                Expanded(
                  child: Text(entry.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: name),
                ),
                const SizedBox(width: ProfileSpacing.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(entry.pointsLabel,
                        style: ProfileText.recordValue(context)),
                    Text('RE pts', style: ProfileText.caption(context)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
