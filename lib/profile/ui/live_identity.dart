/// Widgets that show a person's CURRENT username, wherever a uid is known.
///
/// ── Why a widget and not a string ───────────────────────────────────────────
/// Historical documents carry a denormalised copy of whatever the author was
/// called when the document was written: `comments.username`,
/// `buddyAssignments.athletes[uid].displayName`, `coachAssignments` roster
/// rows, DM conversation headers, leaderboard rows. Those copies are audit
/// data. They record what the name WAS. They are not who the person IS.
///
/// Before this, several of those surfaces preferred the denormalised copy and
/// only fell back to a lookup when it was missing — so a rename left the old
/// name on every comment the person had ever written, forever. The ones that
/// did look the uid up cached the answer in a process-lifetime map
/// (`PostHeader`'s `_UserPublicCache`), so a rename made during the session was
/// invisible until the app was killed and reopened.
///
/// [LiveUserName] inverts both. It subscribes to `users_public/{uid}` through
/// [IdentityRepository.watchPublicIdentity] and rebuilds when the name changes,
/// so a rename propagates to every visible surface within one snapshot — no
/// restart, no cache to invalidate. The denormalised value is passed in as
/// [fallback] and used only for the first frame and for a genuinely cold
/// offline cache.
library;

import 'package:flutter/material.dart';

import '../data/identity_repository.dart';

/// The current username for [uid], live.
class LiveUserName extends StatelessWidget {
  const LiveUserName({
    super.key,
    required this.uid,
    this.fallback,
    this.style,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
    this.textAlign,
    this.builder,
    this.identity,
  });

  final String uid;

  /// The denormalised name carried by the document this appeared in. Shown
  /// only until the authoritative value arrives, and when there is none.
  final String? fallback;

  final TextStyle? style;
  final int maxLines;
  final TextOverflow overflow;
  final TextAlign? textAlign;

  /// Renders the resolved name yourself, when a plain [Text] is not enough.
  final Widget Function(BuildContext context, String name)? builder;

  /// Overrides the shared repository. For tests.
  final IdentityRepository? identity;

  @override
  Widget build(BuildContext context) {
    final IdentityRepository repo = identity ?? IdentityRepository.shared;
    return StreamBuilder<PublicIdentity>(
      stream: repo.watchPublicIdentity(uid),
      initialData: repo.cachedPublicIdentity(uid),
      builder: (BuildContext context, AsyncSnapshot<PublicIdentity> snap) {
        final String name = _resolve(snap.data);
        final Widget Function(BuildContext, String)? custom = builder;
        if (custom != null) return custom(context, name);
        return Text(
          name,
          style: style,
          maxLines: maxLines,
          overflow: overflow,
          textAlign: textAlign,
        );
      },
    );
  }

  String _resolve(PublicIdentity? live) {
    final String? authoritative = live?.displayName;
    if (authoritative != null && authoritative.isNotEmpty) return authoritative;
    final String? fb = fallback?.trim();
    if (fb != null && fb.isNotEmpty) return fb;
    return kUnknownAthleteName;
  }
}

/// The current avatar for [uid], live, with the same fallback rules.
class LiveUserAvatar extends StatelessWidget {
  const LiveUserAvatar({
    super.key,
    required this.uid,
    this.radius = 16,
    this.fallbackPhotoURL,
    this.identity,
  });

  final String uid;
  final double radius;
  final String? fallbackPhotoURL;
  final IdentityRepository? identity;

  @override
  Widget build(BuildContext context) {
    final IdentityRepository repo = identity ?? IdentityRepository.shared;
    return StreamBuilder<PublicIdentity>(
      stream: repo.watchPublicIdentity(uid),
      initialData: repo.cachedPublicIdentity(uid),
      builder: (BuildContext context, AsyncSnapshot<PublicIdentity> snap) {
        final String? url = (snap.data?.photoURL?.isNotEmpty ?? false)
            ? snap.data!.photoURL
            : fallbackPhotoURL;
        return CircleAvatar(
          radius: radius,
          backgroundColor: Colors.grey.shade300,
          backgroundImage:
              (url != null && url.isNotEmpty) ? NetworkImage(url) : null,
          child: (url == null || url.isEmpty)
              ? Icon(Icons.person, size: radius)
              : null,
        );
      },
    );
  }
}
