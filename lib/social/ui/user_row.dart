/// One person, as a single compact row: avatar, name, handle, action.
///
/// Used by every list in the Buddy Hub — search results, incoming requests,
/// outgoing requests and confirmed buddies — so that the same person looks the
/// same wherever they appear, and so the action is always in the same place.
///
/// ── Avatar caching ────────────────────────────────────────────────────────
/// [BuddyAvatar] passes no explicit `cacheKey`, which means [CachedProfileImage]
/// falls back to the URL. That is deliberate: the profile header
/// (lib/profile/ui/profile_header.dart) does exactly the same, so both surfaces
/// resolve one avatar to ONE cache entry. Passing a composed key here instead
/// would be a better key in the abstract and a worse outcome in practice — the
/// same bytes would be stored twice, once under each scheme, which is the
/// duplication this feature is supposed to avoid. Post media, where the profile
/// grid already uses a composed key, is keyed to match it exactly; see
/// FeedItem.displayCacheKey.
library;

import 'package:flutter/material.dart';

import '../../profile/data/identity_repository.dart';
import '../../profile/ui/cached_network_image.dart';
import '../../profile/ui/profile_theme.dart';
import '../buddy_repository.dart';

/// Minimum tappable size. Below this a control is a target people miss.
const double kMinTouchTarget = 48;

/// A small circular profile photo.
class BuddyAvatar extends StatelessWidget {
  const BuddyAvatar({
    super.key,
    required this.photoURL,
    this.size = 44,
    this.ringColor,
  });

  final String photoURL;
  final double size;

  /// An optional accent ring, used to mark a confirmed buddy.
  final Color? ringColor;

  @override
  Widget build(BuildContext context) {
    final Widget image = ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: photoURL.trim().isEmpty
            ? const _AvatarFallback()
            : CachedProfileImage(
                url: photoURL,
                fit: BoxFit.cover,
                width: size,
                height: size,
                placeholder: const _AvatarFallback(),
                fallback: const _AvatarFallback(),
              ),
      ),
    );

    final Color? ring = ringColor;
    if (ring == null) return image;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 1.5),
      ),
      child: image,
    );
  }
}

/// [BuddyAvatar] for a uid, kept current by the identity stream.
///
/// The picture comes from `users_public/{uid}.photoURL` through
/// [IdentityRepository.watchPublicIdentity], the same live flow as
/// [LiveUserName], so changing a profile picture updates every visible row
/// without a restart. The cached image layer underneath ([CachedProfileImage])
/// keeps scrolling free of repeated fetches, serves the picture offline once
/// seen, and falls back to the neutral avatar when there is no photo or the
/// image cannot be loaded.
class LiveBuddyAvatar extends StatelessWidget {
  const LiveBuddyAvatar({
    super.key,
    required this.uid,
    this.size = 44,
    this.fallbackPhotoURL,
    this.ringColor,
    this.identity,
  });

  final String uid;
  final double size;
  final String? fallbackPhotoURL;
  final Color? ringColor;

  /// Overrides the shared repository. For tests.
  final IdentityRepository? identity;

  @override
  Widget build(BuildContext context) {
    final IdentityRepository repo = identity ?? IdentityRepository.shared;
    return StreamBuilder<PublicIdentity>(
      stream: repo.watchPublicIdentity(uid),
      initialData: repo.cachedPublicIdentity(uid),
      builder: (BuildContext context, AsyncSnapshot<PublicIdentity> snap) {
        final String? live = snap.data?.photoURL;
        final String url = (live != null && live.isNotEmpty)
            ? live
            : (fallbackPhotoURL ?? '');
        return BuddyAvatar(photoURL: url, size: size, ringColor: ringColor);
      },
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ProfilePalette.outline,
      child: const Icon(
        Icons.person,
        color: ProfilePalette.textMuted,
        size: 20,
      ),
    );
  }
}

/// What the row's trailing control should offer.
enum BuddyRowAction { add, requested, respond, friends, none }

BuddyRowAction actionForRelationship(BuddyRelationship r) {
  switch (r) {
    case BuddyRelationship.none:
      return BuddyRowAction.add;
    case BuddyRelationship.requested:
      return BuddyRowAction.requested;
    case BuddyRelationship.incoming:
      return BuddyRowAction.respond;
    case BuddyRelationship.friends:
      return BuddyRowAction.friends;
    case BuddyRelationship.self:
      return BuddyRowAction.none;
  }
}

/// A compact person row.
class BuddyUserRow extends StatelessWidget {
  const BuddyUserRow({
    super.key,
    required this.displayName,
    required this.handle,
    required this.photoURL,
    this.action = BuddyRowAction.none,
    this.busy = false,
    this.onTap,
    this.onPrimary,
    this.onSecondary,
    this.subtitle,
  });

  final String displayName;

  /// `@username`, or empty.
  final String handle;

  final String photoURL;
  final BuddyRowAction action;

  /// True while a mutation for this row is in flight. The control shows a
  /// spinner and stops accepting taps, so a double tap cannot send twice.
  final bool busy;

  /// Opens the person's profile. Null for a row that should not be openable —
  /// a non-friend's profile is not reachable, and offering it would lead to a
  /// permission error rather than a page.
  final VoidCallback? onTap;

  /// Add / Accept / (tap-to-manage for a friend).
  final VoidCallback? onPrimary;

  /// Decline, for an incoming request.
  final VoidCallback? onSecondary;

  /// Replaces the handle line when there is something more useful to say.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final String secondLine = subtitle ?? handle;
    return Semantics(
      button: onTap != null,
      label: handle.isEmpty ? displayName : '$displayName, $handle',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          splashColor: ProfilePalette.action.withValues(alpha: 0.10),
          highlightColor: ProfilePalette.action.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ProfileSpacing.lg,
              vertical: ProfileSpacing.sm + 2,
            ),
            child: Row(
              children: <Widget>[
                BuddyAvatar(
                  photoURL: photoURL,
                  ringColor: action == BuddyRowAction.friends
                      ? ProfilePalette.action
                      : null,
                ),
                const SizedBox(width: ProfileSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProfileText.liftName(context),
                      ),
                      if (secondLine.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          secondLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ProfileText.recordDetail(context),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: ProfileSpacing.sm),
                _RowAction(
                  action: action,
                  busy: busy,
                  displayName: displayName,
                  onPrimary: onPrimary,
                  onSecondary: onSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.action,
    required this.busy,
    required this.displayName,
    this.onPrimary,
    this.onSecondary,
  });

  final BuddyRowAction action;
  final bool busy;
  final String displayName;
  final VoidCallback? onPrimary;
  final VoidCallback? onSecondary;

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
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: ProfilePalette.action,
            ),
          ),
        ),
      );
    }

    switch (action) {
      case BuddyRowAction.add:
        return _PillButton(
          label: 'Add',
          semanticLabel: 'Send a buddy request to $displayName',
          filled: true,
          onPressed: onPrimary,
        );
      case BuddyRowAction.requested:
        return _PillButton(
          label: 'Requested',
          semanticLabel: 'Cancel the buddy request to $displayName',
          filled: false,
          muted: true,
          onPressed: onPrimary,
        );
      case BuddyRowAction.respond:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _PillButton(
              label: 'Accept',
              semanticLabel: 'Accept the buddy request from $displayName',
              filled: true,
              onPressed: onPrimary,
            ),
            const SizedBox(width: ProfileSpacing.xs),
            _IconAction(
              icon: Icons.close_rounded,
              semanticLabel: 'Decline the buddy request from $displayName',
              onPressed: onSecondary,
            ),
          ],
        );
      case BuddyRowAction.friends:
        return _IconAction(
          icon: Icons.more_horiz_rounded,
          semanticLabel: 'Manage your buddy $displayName',
          onPressed: onPrimary,
        );
      case BuddyRowAction.none:
        return const SizedBox(width: ProfileSpacing.xs);
    }
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.semanticLabel,
    required this.filled,
    this.muted = false,
    this.onPressed,
  });

  final String label;
  final String semanticLabel;
  final bool filled;
  final bool muted;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final Color foreground = filled
        ? Colors.white
        : (muted ? ProfilePalette.textSecondary : ProfilePalette.action);
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: ConstrainedBox(
        // Height, not width: a pill should hug its label, but it must never
        // be shorter than a finger.
        constraints: const BoxConstraints(minHeight: kMinTouchTarget),
        child: Center(
          child: Material(
            color: filled
                ? ProfilePalette.action
                : ProfilePalette.action.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(ProfileSpacing.radiusSmall + 2),
            child: InkWell(
              onTap: onPressed,
              borderRadius:
                  BorderRadius.circular(ProfileSpacing.radiusSmall + 2),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(
                  label,
                  style: ProfileText.button(context).copyWith(color: foreground),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: ProfilePalette.textSecondary, size: 20),
      tooltip: semanticLabel,
      constraints: const BoxConstraints(
        minWidth: kMinTouchTarget,
        minHeight: kMinTouchTarget,
      ),
    );
  }
}
