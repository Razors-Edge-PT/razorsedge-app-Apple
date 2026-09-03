/// The three-column profile media grid.
///
/// Dense, square, edge-to-edge — the layout that makes a training gallery
/// scannable — rendered in GoodLift's palette. A tile distinguishes video from
/// image, marks proof media with a small achievement badge, and shows the
/// owner's still-uploading items immediately, including after a restart.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/media_identity.dart';
import '../core/media_models.dart';
import '../core/media_urls.dart';
import 'cached_network_image.dart';
import 'profile_theme.dart';

class MediaGrid extends StatelessWidget {
  const MediaGrid({
    super.key,
    required this.items,
    required this.isOwner,
    required this.onOpen,
    required this.onRetry,
    required this.onDelete,
    this.failed = false,
    this.onRetryGallery,
  });

  final List<ProfileMediaItem> items;
  final bool isOwner;
  final void Function(ProfileMediaItem item) onOpen;
  final void Function(ProfileMediaItem item) onRetry;
  final void Function(ProfileMediaItem item) onDelete;

  /// True when the gallery listener FAILED, as opposed to answering with
  /// nothing. The two look identical without this and they mean opposite
  /// things: one is a profile with no media yet, the other is media that exists
  /// and could not be read.
  final bool failed;

  /// Re-establishes the gallery listener. Non-blocking: whatever was already
  /// loaded stays on screen above it.
  final VoidCallback? onRetryGallery;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ProfileSpacing.lg,
            vertical: ProfileSpacing.xxl,
          ),
          child: Center(
            child: failed
                ? _GalleryError(onRetry: onRetryGallery)
                : Text(
                    isOwner
                        ? 'Add a photo or video from your training.'
                        : 'Nothing shared yet.',
                    style: ProfileText.recordDetail(context)
                        .copyWith(color: ProfilePalette.textMuted),
                    textAlign: TextAlign.center,
                  ),
          ),
        ),
      );
    }

    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: ProfileSpacing.gridGap,
        crossAxisSpacing: ProfileSpacing.gridGap,
      ),
      delegate: SliverChildBuilderDelegate(
        (BuildContext context, int index) => MediaTile(
          item: items[index],
          isOwner: isOwner,
          onOpen: onOpen,
          onRetry: onRetry,
          onDelete: onDelete,
        ),
        childCount: items.length,
      ),
    );
  }
}

class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.item,
    required this.isOwner,
    required this.onOpen,
    required this.onRetry,
    required this.onDelete,
  });

  final ProfileMediaItem item;
  final bool isOwner;
  final void Function(ProfileMediaItem item) onOpen;
  final void Function(ProfileMediaItem item) onRetry;
  final void Function(ProfileMediaItem item) onDelete;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        if (item.failed) {
          onRetry(item);
          return;
        }
        if (!item.pending) onOpen(item);
      },
      onLongPress: isOwner ? () => _confirmDelete(context) : null,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _Thumbnail(item: item),
          if (item.pending) const _PendingScrim(),
          if (item.pending)
            Positioned(
              left: 6,
              bottom: 6,
              child: ProfilePill(
                label: item.failed ? 'TAP TO RETRY' : 'UPLOADING',
                icon: item.failed
                    ? Icons.refresh_rounded
                    : Icons.cloud_upload_rounded,
                color: item.failed
                    ? ProfilePalette.danger
                    : ProfilePalette.textPrimary,
                background: ProfilePalette.navy.withValues(alpha: 0.72),
              ),
            ),
          if (item.isVideo)
            const Positioned(
              right: 6,
              top: 6,
              child:
                  Icon(Icons.play_arrow_rounded, size: 18, color: Colors.white),
            ),
          if (item.isProof)
            const Positioned(
              left: 6,
              top: 6,
              child: _ProofBadge(),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: ProfilePalette.surface,
        title: Text(
          item.pending ? 'Cancel this upload?' : 'Delete this media?',
          style: ProfileText.liftName(ctx),
        ),
        content: Text(
          item.isProof
              ? 'It will be removed from your gallery, and it will no longer '
                  'stand as proof of that record.'
              : 'This removes it from your profile for everyone.',
          style: ProfileText.recordDetail(ctx),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Keep', style: ProfileText.button(ctx)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              item.pending ? 'Cancel upload' : 'Delete',
              style: ProfileText.button(ctx)
                  .copyWith(color: ProfilePalette.danger),
            ),
          ),
        ],
      ),
    );
    if (ok == true) onDelete(item);
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.item});

  final ProfileMediaItem item;

  @override
  Widget build(BuildContext context) {
    // A record whose `mediaType` is missing or unknown is not an image with a
    // broken URL — it is a record this build cannot render. Saying so is what
    // keeps a video out of the image decoder, and it isolates the malformed
    // record: this tile shows a placeholder, every neighbouring tile renders
    // exactly as it did.
    if (!item.isSupported) return const _UnsupportedMediaPlaceholder();

    // A pending item has no remote URL yet, so the locally generated thumbnail
    // is what the owner sees — instantly, and without a network round trip.
    final String? local = item.localThumbPath ?? item.localFilePath;
    if (item.pending && local != null && File(local).existsSync()) {
      return Image.file(File(local), fit: BoxFit.cover);
    }

    // `thumbUrl` is only trusted when it names an image. Posts written before
    // 1.7.13 stored the video's own URL there, and an .mp4 handed to an image
    // decoder is a broken-image icon, not a poster frame. `smallUrl` is the
    // playable media, so for a video it is never a fallback thumbnail either —
    // an honest video placeholder is better than a broken one.
    final bool usesPoster = item.isVideo || item.thumbUrl.isNotEmpty;
    final String? url = item.isVideo
        ? safeThumbnailUrl(item.thumbUrl)
        : safeThumbnailUrl(usesPoster ? item.thumbUrl : item.smallUrl);
    if (url == null) return _MediaPlaceholder(isVideo: item.isVideo);

    // Disk-persisted, so a previously seen tile still renders after the app is
    // killed and reopened with no connection. Keyed by the item's stable
    // identity rather than the URL, so a rotated Storage token does not orphan
    // the entry and re-download bytes that are already on disk.
    //
    // No error affordance on a tile on purpose: a quiet placeholder is right
    // for a dense three-column grid, and the retry that matters lives on the
    // detail page the tile opens.
    return CachedProfileImage(
      url: url,
      cacheKey:
          item.cacheKey(usesPoster ? MediaVariant.thumb : MediaVariant.small),
      fit: BoxFit.cover,
      placeholder: const ColoredBox(color: ProfilePalette.surface),
      fallback: _MediaPlaceholder(isVideo: item.isVideo),
    );
  }
}

/// Drawn when a tile has no image to show: a video with no poster frame, or a
/// thumbnail that could not be fetched.
class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.isVideo});

  final bool isVideo;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: ProfilePalette.surface,
        child: Center(
          child: Icon(
            isVideo ? Icons.movie_outlined : Icons.image_outlined,
            size: 20,
            color: ProfilePalette.textMuted,
          ),
        ),
      );
}

class _PendingScrim extends StatelessWidget {
  const _PendingScrim();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: ProfilePalette.navy.withValues(alpha: 0.45),
      );
}

/// The subtle achievement treatment on proof media. Small on purpose: it marks
/// the tile without turning the grid into a scoreboard.
class _ProofBadge extends StatelessWidget {
  const _ProofBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ProfilePalette.navy.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ProfilePalette.accent, width: 1),
      ),
      child: const Icon(Icons.military_tech_rounded,
          size: 13, color: ProfilePalette.accent),
    );
  }
}

/// Drawn for a record whose media type the app does not recognise.
///
/// Deliberately distinct from [_MediaPlaceholder]: "we could not fetch this
/// picture" and "this record is not media we can render" are different
/// problems, and a support conversation goes better when the screen says which.
class _UnsupportedMediaPlaceholder extends StatelessWidget {
  const _UnsupportedMediaPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: ProfilePalette.surface,
        child: Center(
          child: Icon(
            Icons.help_outline_rounded,
            size: 20,
            color: ProfilePalette.textMuted,
          ),
        ),
      );
}

/// Shown in place of the empty-gallery message when the listener FAILED.
class _GalleryError extends StatelessWidget {
  const _GalleryError({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Your gallery could not be loaded.',
            style: ProfileText.recordDetail(context)
                .copyWith(color: ProfilePalette.textMuted),
            textAlign: TextAlign.center,
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: ProfileSpacing.sm),
            TextButton(
              onPressed: onRetry,
              child: Text('Try again', style: ProfileText.button(context)),
            ),
          ],
        ],
      );
}
