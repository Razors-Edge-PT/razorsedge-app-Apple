/// The message icon and its unread badge — one implementation, one account.
///
/// Both Home headers used to count for themselves, and both mixed accounts:
/// they queried with `UserContext.currentUid` (a coach's SELECTED ATHLETE)
/// while reading the per-person unread state with FirebaseAuth's uid, so in
/// Coach Mode the badge counted nothing or the wrong thing — and HomeScreen2's
/// copy queried `users/{uid}/conversations`, which holds no conversations at
/// all, so its badge was always zero.
///
/// This reads [DmUnreadService]: the signed-in account's conversations, one
/// shared subscription for the whole app, the same numbers the Messages list
/// rows show.
library;

import 'package:flutter/material.dart';

import '../../directMessages.dart';
import '../dm_unread_service.dart';

/// Beyond this the exact number stops being useful in a tight app bar.
const int kMaxDmBadgeCount = 99;

class DmBadgeButton extends StatelessWidget {
  const DmBadgeButton({
    super.key,
    this.unreadService,
    this.iconSize = 26,
    this.iconColor,
  });

  /// Injectable for tests; production uses the shared instance.
  final DmUnreadService? unreadService;
  final double iconSize;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final DmUnreadService unread = unreadService ?? DmUnreadService.instance;
    final Color color = iconColor ?? Theme.of(context).colorScheme.secondary;

    return StreamBuilder<DmUnreadSnapshot>(
      stream: unread.watch(),
      // The last known counts, so a rebuild or a reconnect never flashes an
      // empty badge, and an error leaves the previous number alone.
      initialData: unread.snapshot,
      builder: (BuildContext context, AsyncSnapshot<DmUnreadSnapshot> snap) {
        final int count = (snap.data ?? unread.snapshot).total;
        return Stack(
          alignment: Alignment.center,
          children: <Widget>[
            IconButton(
              icon: Icon(Icons.message_outlined, size: iconSize, color: color),
              tooltip: count == 0
                  ? 'Messages'
                  : '$count unread ${count == 1 ? 'message' : 'messages'}',
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => DirectMessages(unreadService: unread),
                ));
              },
            ),
            if (count > 0)
              Positioned(
                right: 6,
                top: 6,
                child: IgnorePointer(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      count > kMaxDmBadgeCount ? '$kMaxDmBadgeCount+' : '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
