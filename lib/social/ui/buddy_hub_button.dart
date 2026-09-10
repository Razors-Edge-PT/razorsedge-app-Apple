/// The header entry point to the Buddy Hub: one icon, one subtle badge.
///
/// ── What replaced what ─────────────────────────────────────────────────────
/// The legacy header icon opened an AlertDialog listing raw invite documents,
/// and when there were none it showed a snackbar saying "No buddy requests."
/// Tapping a control and being told nothing happened is a dead end — there was
/// no way to reach a buddy list, find a person, or open a friend's profile from
/// the header at all. This opens the Buddy Hub in every case; the badge is what
/// says whether anything is waiting.
///
/// ── Whose requests these are ───────────────────────────────────────────────
/// The AUTHENTICATED account's, always. The legacy badge streamed
/// `UserContext.actingAsUid`, so a coach with an athlete selected saw that
/// athlete's incoming buddy requests in their own header and could accept or
/// decline them — a social action on somebody else's account, taken from a
/// permission granted for training. [BuddyRepository] derives the account from
/// FirebaseAuth and never reads UserContext, which is why nothing here does
/// either.
library;

import 'package:flutter/material.dart';

import '../buddy_hub_screen.dart';
import '../buddy_repository.dart';

/// The largest number the badge spells out. Beyond it the exact count stops
/// being information and starts being a wide pill in a tight app bar.
const int kMaxBadgeCount = 9;

class BuddyHubButton extends StatefulWidget {
  const BuddyHubButton({
    super.key,
    this.buddies,
    this.iconColor,
    this.iconSize = 24,
  });

  /// Injectable for tests. Production uses the default repository.
  final BuddyRepository? buddies;

  final Color? iconColor;
  final double iconSize;

  @override
  State<BuddyHubButton> createState() => _BuddyHubButtonState();
}

class _BuddyHubButtonState extends State<BuddyHubButton> {
  late final BuddyRepository _buddies;

  /// Created once and reused for the life of the widget. Building the stream
  /// inside `build` would open a new Firestore listener on every rebuild of
  /// the app bar, and the app bar rebuilds constantly.
  late final Stream<int> _pending;

  @override
  void initState() {
    super.initState();
    _buddies = widget.buddies ?? BuddyRepository();
    _pending = _buddies.watchPendingCount();
  }

  void _openHub() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BuddyHubScreen(buddies: _buddies),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final Color color =
        widget.iconColor ?? Theme.of(context).colorScheme.secondary;

    return StreamBuilder<int>(
      stream: _pending,
      builder: (BuildContext context, AsyncSnapshot<int> snap) {
        // A stream error is not a reason to hide the way into the Hub — the
        // icon still works, it just cannot say whether anything is waiting.
        final int count = snap.data ?? 0;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: <Widget>[
            IconButton(
              onPressed: _openHub,
              tooltip: count > 0
                  ? '$count buddy ${count == 1 ? 'request' : 'requests'}'
                  : 'Buddies',
              icon: Icon(
                Icons.person_add_alt_1,
                size: widget.iconSize,
                color: color,
              ),
            ),
            if (count > 0)
              Positioned(
                right: 6,
                top: 6,
                child: _PendingBadge(count: count),
              ),
          ],
        );
      },
    );
  }
}

/// A small count, or a dot when the exact number stops mattering.
class _PendingBadge extends StatelessWidget {
  const _PendingBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final String label = count > kMaxBadgeCount ? '$kMaxBadgeCount+' : '$count';
    return IgnorePointer(
      // Purely decorative: the tap belongs to the icon underneath, and a badge
      // that swallowed it would make the control fail exactly when there IS
      // something to look at.
      child: Semantics(
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          constraints: const BoxConstraints(minWidth: 16),
          decoration: BoxDecoration(
            color: Colors.redAccent,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              height: 1.1,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
