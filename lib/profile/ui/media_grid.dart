/// The three-column profile media grid.
///
/// Dense, square, edge-to-edge — the layout that makes a training gallery
/// scannable — rendered in GoodLift's palette. A tile distinguishes video from
/// image, marks proof media with a small achievement badge, and shows the
/// owner's still-uploading items immediately, including after a restart.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/media_models.dart';
import 'profile_theme.dart';

class MediaGrid extends StatelessWidget {
  const MediaGrid({
    super.key,
    required this.items,
    required this.isOwner,
    required this.onOpen,
    required this.onRetry,
    required this.onDelete,
  });

  final List<ProfileMediaItem> items;
  final bool isOwner;
  final void Function(ProfileMediaItem item) onOpen;
  final void Function(ProfileMediaItem item) onRetry;
  final void Function(ProfileMediaItem item) onDelete;

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
            child: Text(
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
    // A pending item has no remote URL yet, so the locally generated thumbnail
    // is what the owner sees — instantly, and without a network round trip.
    final String? local = item.localThumbPath ?? item.localFilePath;
    if (item.pending && local != null && File(local).existsSync()) {
      return Image.file(File(local), fit: BoxFit.cover);
    }

    final String url = item.thumbUrl.isNotEmpty ? item.thumbUrl : item.smallUrl;
    if (url.isEmpty) return const ColoredBox(color: ProfilePalette.surface);

    return Image.network(
      url,
      fit: BoxFit.cover,
      // Firebase's HTTP cache serves a previously viewed thumbnail without a
      // network round trip, which is what keeps a warm reopen instant.
      loadingBuilder: (BuildContext c, Widget child, ImageChunkEvent? p) =>
          p == null ? child : const ColoredBox(color: ProfilePalette.surface),
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: ProfilePalette.surface,
        child: Icon(Icons.broken_image_outlined,
            size: 18, color: ProfilePalette.textMuted),
      ),
    );
  }
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
