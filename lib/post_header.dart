/// The author line on a feed post: avatar, current username, and how long ago.
///
/// ── Why this no longer has a cache of its own ───────────────────────────────
/// It used to hold a `static Map<String, Future<_UserPublicData>>` and a
/// comment explaining that `putIfAbsent` guaranteed "exactly one Firestore read
/// per uid per process lifetime". That was true, and it was the bug: once a
/// name had been read it was never read again, so renaming yourself left every
/// post header in the feed — including your own — showing the old name until
/// the app was killed and reopened.
///
/// [LiveUserName] and [LiveUserAvatar] subscribe to `users_public/{uid}`
/// through the shared IdentityRepository instead. That still costs one
/// listener per uid however many cards are on screen, Firestore still serves
/// the first event straight from its persistent cache, and a rename now
/// reaches every visible header within one snapshot.
library;

import 'package:flutter/material.dart';

import 'profile/ui/live_identity.dart';

class PostHeader extends StatelessWidget {
  final String ownerUid;
  final DateTime createdAt;

  /// The name denormalised onto the document this header belongs to, if any.
  /// Used for the first frame and for a genuinely cold offline cache — never
  /// in preference to the live value.
  final String? fallbackName;

  const PostHeader({
    super.key,
    required this.ownerUid,
    required this.createdAt,
    this.fallbackName,
  });

  String _timeAgo(Duration d) {
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final ago = _timeAgo(now.difference(createdAt));

    return Row(
      children: [
        LiveUserAvatar(uid: ownerUid, radius: 16),
        const SizedBox(width: 8),
        Expanded(
          child: LiveUserName(
            uid: ownerUid,
            fallback: fallbackName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Text('· $ago',
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
