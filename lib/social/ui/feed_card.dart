/// One post in the buddy feed.
///
/// ── What a card costs when it scrolls past ────────────────────────────────
/// One image: the photo, or the POSTER for a video. Never the video itself.
/// A feed card entering the viewport must not start downloading a clip — on a
/// phone feed that is the difference between a few hundred kilobytes and tens
/// of megabytes for content the person never stopped on. The video is fetched
/// only when the card is opened, by the existing detail page and player.
///
/// There is deliberately no autoplay. The app has never autoplayed video
/// anywhere else, and adding it here would be a new behaviour, a new battery
/// cost and a new data cost that nothing asked for.
///
/// The image is drawn by [CachedProfileImage] under the SAME cache key the
/// profile grid uses for the same object, so a photo already seen on someone's
/// profile is already on disk here — no second download, no second copy.
library;

import 'package:flutter/material.dart';

import '../../profile/ui/cached_network_image.dart';
import '../../profile/ui/profile_theme.dart';
import '../feed_repository.dart';
import '../user_search_result.dart';
import 'user_row.dart';

/// A concise relative time: `now`, `4m`, `3h`, `2d`, then a date.
///
/// Short because it sits beside a name on one line, and a feed reads better
/// when the timestamp is a glance rather than a sentence.
String formatRelativeTime(DateTime? when, {DateTime? now}) {
  if (when == null) return '';
  final DateTime reference = now ?? DateTime.now();
  final Duration d = reference.difference(when);
  if (d.isNegative) return 'now';
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  if (d.inDays < 365) return '${(d.inDays / 7).floor()}w';
  return '${(d.inDays / 365).floor()}y';
}

class FeedCard extends StatelessWidget {
  const FeedCard({
    super.key,
    required this.item,
    this.owner,
    this.onOpen,
    this.onOpenProfile,
    this.now,
  });

  final FeedItem item;

  /// The poster's identity, resolved once per DISTINCT account per page.
  /// Null while that lookup is in flight, or when it failed offline.
  final UserSearchResult? owner;

  final VoidCallback? onOpen;
  final VoidCallback? onOpenProfile;

  /// Injectable clock, so the relative time is testable.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final String name = owner?.bestName ?? 'GoodLift member';
    final String handle = owner?.handle ?? '';
    final String age = formatRelativeTime(item.createdAt, now: now);

    return Padding(
      padding: const EdgeInsets.only(bottom: ProfileSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Header(
            name: name,
            handle: handle,
            age: age,
            photoURL: owner?.photoURL ?? '',
            onOpenProfile: onOpenProfile,
          ),
          const SizedBox(height: ProfileSpacing.sm),
          _Media(item: item, onOpen: onOpen, authorName: name),
          if (item.caption.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: ProfileSpacing.sm),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: ProfileSpacing.lg),
              child: Text(
                item.caption.trim(),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: ProfileText.bio(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.handle,
    required this.age,
    required this.photoURL,
    this.onOpenProfile,
  });

  final String name;
  final String handle;
  final String age;
  final String photoURL;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onOpenProfile != null,
      label: 'Open $name\'s profile',
      child: InkWell(
        onTap: onOpenProfile,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ProfileSpacing.lg,
            vertical: ProfileSpacing.xs,
          ),
          child: Row(
            children: <Widget>[
              BuddyAvatar(photoURL: photoURL, size: 34),
              const SizedBox(width: ProfileSpacing.sm + 2),
              Expanded(
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProfileText.liftName(context),
                      ),
                    ),
                    if (handle.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          handle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ProfileText.caption(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (age.isNotEmpty) ...<Widget>[
                const SizedBox(width: ProfileSpacing.sm),
                Text(age, style: ProfileText.caption(context)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Media extends StatelessWidget {
  const _Media({required this.item, required this.authorName, this.onOpen});

  final FeedItem item;
  final String authorName;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onOpen != null,
      label: item.isVideo
          ? 'Play $authorName\'s video'
          : 'Open $authorName\'s photo',
      child: GestureDetector(
        onTap: onOpen,
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CachedProfileImage(
                url: item.displayUrl,
                // The profile grid's key for the same object. Sharing it is
                // what makes an already-seen photo appear with no download.
                cacheKey: item.displayCacheKey,
                storagePath: item.displayStoragePath,
                fit: BoxFit.cover,
                placeholder: const _MediaPlaceholder(),
                errorBuilder: (
                  BuildContext context,
                  MediaLoadFailure failure,
                  VoidCallback retry,
                ) =>
                    _MediaFailure(failure: failure, onRetry: retry),
              ),
              if (item.isVideo)
                const Positioned(
                  right: ProfileSpacing.sm,
                  bottom: ProfileSpacing.sm,
                  child: _VideoBadge(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder();

  @override
  Widget build(BuildContext context) =>
      Container(color: ProfilePalette.surface);
}

/// A failed image, with a way out.
///
/// Never an indefinite spinner: a card that cannot load its picture says so
/// and offers Retry, because a spinner that never resolves is indistinguishable
/// from an app that has stopped working.
class _MediaFailure extends StatelessWidget {
  const _MediaFailure({required this.failure, required this.onRetry});

  final MediaLoadFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool offline = failure == MediaLoadFailure.offline;
    return Container(
      color: ProfilePalette.surface,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            offline ? Icons.cloud_off_rounded : Icons.broken_image_outlined,
            color: ProfilePalette.textMuted,
            size: 28,
          ),
          const SizedBox(height: ProfileSpacing.sm),
          Text(
            offline ? "Not downloaded yet" : "Couldn't load",
            style: ProfileText.caption(context),
          ),
          const SizedBox(height: ProfileSpacing.sm),
          TextButton(
            onPressed: onRetry,
            child: Text(
              'Retry',
              style: ProfileText.button(context)
                  .copyWith(color: ProfilePalette.action),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoBadge extends StatelessWidget {
  const _VideoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: 18,
      ),
    );
  }
}
