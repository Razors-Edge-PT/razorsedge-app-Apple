// FROZEN BASELINE — do not edit.
//
// LeaderboardRow and its relationship control exactly as they were in the
// parent of the category-medal commit (git show 7e016c89^:lib/leaderboard/
// leaderboard_view.dart), renamed only. The medal-row regression tests measure
// the delivered row against this one, so the pre-medal vertical footprint is
// taken from the real implementation, never estimated.

import 'package:flutter/material.dart';
import 'package:localtest222/leaderboard/leaderboard_models.dart';
import 'package:localtest222/leaderboard/leaderboard_view.dart'
    show LeaderboardRowAction;
import 'package:localtest222/profile/ui/profile_theme.dart';
import 'package:localtest222/social/ui/user_row.dart'
    show BuddyAvatar, kMinTouchTarget;

class PreMedalLeaderboardRow extends StatelessWidget {
  const PreMedalLeaderboardRow({
    super.key,
    required this.entry,
    required this.onTap,
    this.action = LeaderboardRowAction.none,
    this.onAction,
    this.busy = false,
  });

  final LeaderboardEntry entry;

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
    final Widget standing = Semantics(
      button: onTap != null,
      label: 'Rank ${entry.rank}, ${entry.displayName}, '
          '${entry.pointsLabel} RE Points$actionLabel',
      // The row's own label; the relationship control keeps its semantics so
      // it stays reachable with a screen reader.
      excludeSemantics: action == LeaderboardRowAction.none,
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
                  child: action == LeaderboardRowAction.none
                      ? Text(entry.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: name)
                      // The relationship control sits under the name, so
                      // rank, photo and points keep their full width on
                      // narrow phones.
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(entry.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: name),
                            _PreMedalRowAction(
                                uid: entry.uid,
                                action: action,
                                onPressed: onAction,
                                busy: busy),
                          ],
                        ),
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
    return standing;
  }
}

class _PreMedalRowAction extends StatelessWidget {
  const _PreMedalRowAction({
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
