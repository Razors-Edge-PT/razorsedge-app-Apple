/// The profile header: avatar with story ring, username, and bio.
///
/// Every editing affordance in here is gated on [ProfileController.isOwner],
/// which is derived from the AUTHENTICATED actor — so a coach viewing an
/// athlete, or a friend viewing a friend, sees the same clean read-only header
/// with no owner controls anywhere in the tree.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../data/profile_repository.dart';
import '../profile_controller.dart';
import 'bio_text.dart';
import 'cached_network_image.dart';
import 'profile_theme.dart';

class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.controller,
    required this.onChangePhoto,
    required this.onAddStory,
    required this.onEditUsername,
    required this.onViewStories,
  });

  final ProfileController controller;
  final VoidCallback onChangePhoto;
  final VoidCallback onAddStory;
  final VoidCallback onEditUsername;
  final VoidCallback onViewStories;

  @override
  Widget build(BuildContext context) {
    final bool owner = controller.isOwner;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ProfileSpacing.lg,
        ProfileSpacing.lg,
        ProfileSpacing.lg,
        ProfileSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _Avatar(
                controller: controller,
                onTap: controller.hasStoryRing ? onViewStories : null,
                onChangePhoto: owner ? onChangePhoto : null,
                onAddStory: owner ? onAddStory : null,
              ),
              const SizedBox(width: ProfileSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _UsernameRow(
                      name: controller.displayName,
                      canEdit: owner,
                      onEdit: onEditUsername,
                    ),
                    const SizedBox(height: ProfileSpacing.xs),
                    _SyncBadge(controller: controller),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: ProfileSpacing.md),
          _BioBlock(controller: controller),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.controller,
    this.onTap,
    this.onChangePhoto,
    this.onAddStory,
  });

  final ProfileController controller;
  final VoidCallback? onTap;
  final VoidCallback? onChangePhoto;
  final VoidCallback? onAddStory;

  static const double _size = 96;
  static const double _ring = 3;

  @override
  Widget build(BuildContext context) {
    final bool hasStories = controller.hasStoryRing;
    final ProfileIdentity profile = controller.profile;

    return SizedBox(
      width: _size + 16,
      height: _size + 16,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            top: 0,
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                width: _size,
                height: _size,
                padding: const EdgeInsets.all(_ring),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // The ring is the ONLY place the accent appears in the
                  // header, so an unwatched story is impossible to miss and
                  // nothing else competes with it.
                  gradient: hasStories
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[
                            ProfilePalette.accent,
                            ProfilePalette.action,
                          ],
                        )
                      : null,
                  border: hasStories
                      ? null
                      : Border.all(color: ProfilePalette.outline, width: 1.5),
                ),
                child: Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: ProfilePalette.navy,
                  ),
                  padding: EdgeInsets.all(hasStories ? 2.5 : 0),
                  child: ClipOval(
                    child: _photo(profile, controller.pendingAvatarPath),
                  ),
                ),
              ),
            ),
          ),
          if (onChangePhoto != null)
            Positioned(
              left: _size - 26,
              top: _size - 26,
              child: _RoundAction(
                icon: Icons.photo_camera_rounded,
                tooltip: 'Change profile photo',
                onTap: onChangePhoto!,
                background: ProfilePalette.action,
              ),
            ),
          if (onAddStory != null)
            Positioned(
              left: _size - 26,
              top: -2,
              child: _RoundAction(
                icon: Icons.add_rounded,
                tooltip: 'Add to your story',
                onTap: onAddStory!,
                background: ProfilePalette.surface,
                border: ProfilePalette.accent,
                iconColor: ProfilePalette.accent,
              ),
            ),
        ],
      ),
    );
  }

  Widget _photo(ProfileIdentity profile, String? pendingPath) {
    // A locally staged avatar that has not finished uploading is shown to its
    // owner immediately, so replacing a photo feels instant — and correct —
    // even offline. It is replaced by the network image once the upload
    // commits and the row leaves the outbox.
    if (pendingPath != null && File(pendingPath).existsSync()) {
      return Image.file(File(pendingPath), fit: BoxFit.cover);
    }
    final String? url = profile.photoURL;
    if (url == null || url.isEmpty) return const _AvatarPlaceholder();

    // Persisted to disk, not just to the process's image cache: an avatar seen
    // once still renders after the app is killed and reopened with no
    // connection.
    return CachedProfileImage(
      url: url,
      fit: BoxFit.cover,
      placeholder: const _AvatarPlaceholder(),
      fallback: const _AvatarPlaceholder(),
    );
  }
}

class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder();

  @override
  Widget build(BuildContext context) => Container(
        color: ProfilePalette.surface,
        alignment: Alignment.center,
        child: const Icon(Icons.person_rounded,
            size: 44, color: ProfilePalette.textMuted),
      );
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.background,
    this.border,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color background;
  final Color? border;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
              border: Border.all(
                color: border ?? ProfilePalette.navy,
                width: 2,
              ),
            ),
            child: Icon(icon, size: 16, color: iconColor),
          ),
        ),
      ),
    );
  }
}

class _UsernameRow extends StatelessWidget {
  const _UsernameRow({
    required this.name,
    required this.canEdit,
    required this.onEdit,
  });

  final String name;
  final bool canEdit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Flexible(
          child: Text(
            name,
            style: ProfileText.username(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (canEdit) ...<Widget>[
          const SizedBox(width: ProfileSpacing.sm),
          Semantics(
            button: true,
            label: 'Edit username',
            child: InkResponse(
              onTap: onEdit,
              radius: 20,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.edit_rounded,
                    size: 16, color: ProfilePalette.textSecondary),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Subtle offline / sync state. Deliberately quiet: it is reassurance, not a
/// warning, and it never claims something was saved to the server when it was
/// only queued.
class _SyncBadge extends StatelessWidget {
  const _SyncBadge({required this.controller});

  final ProfileController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.bioSaveState) {
      case SaveState.syncing:
        return const ProfilePill(label: 'SYNCING', icon: Icons.sync_rounded);
      case SaveState.saved:
        return const ProfilePill(
          label: 'SAVED',
          icon: Icons.check_rounded,
          color: ProfilePalette.success,
        );
      case SaveState.savedOffline:
        return const ProfilePill(
          label: 'SAVED OFFLINE',
          icon: Icons.cloud_off_rounded,
        );
      case SaveState.failed:
        return const ProfilePill(
          label: "COULDN'T SYNC",
          icon: Icons.error_outline_rounded,
          color: ProfilePalette.danger,
        );
      case SaveState.idle:
        if (controller.isOffline) {
          return const ProfilePill(
            label: 'OFFLINE',
            icon: Icons.cloud_off_rounded,
          );
        }
        return const SizedBox.shrink();
    }
  }
}

/// The bio, directly below the username. Read-only for visitors; an inline,
/// explicitly-saved editor for the owner.
class _BioBlock extends StatefulWidget {
  const _BioBlock({required this.controller});

  final ProfileController controller;

  @override
  State<_BioBlock> createState() => _BioBlockState();
}

class _BioBlockState extends State<_BioBlock> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final ProfileController c = widget.controller;
    final String bio = c.profile.bio ?? '';

    if (!c.isOwner) {
      if (bio.isEmpty) return const SizedBox.shrink();
      return BioText(bio);
    }

    if (!_editing) {
      return InkWell(
        onTap: () => setState(() => _editing = true),
        borderRadius: BorderRadius.circular(ProfileSpacing.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: bio.isEmpty
              ? Row(
                  children: <Widget>[
                    const Icon(Icons.add_rounded,
                        size: 14, color: ProfilePalette.action),
                    const SizedBox(width: 4),
                    Text('Add a bio', style: ProfileText.link(context)),
                  ],
                )
              : BioText(bio),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: c.bioController,
          focusNode: c.bioFocus,
          onChanged: c.onBioChanged,
          maxLines: 3,
          minLines: 2,
          // Enforced here AND clamped in the repository, so an over-long value
          // from an older build cannot slip through either path.
          maxLength: kBioMaxLength,
          style: ProfileText.bio(context),
          decoration: InputDecoration(
            isDense: true,
            counterStyle: ProfileText.caption(context),
            hintText: 'Say something about your training.',
            hintStyle: ProfileText.bio(context)
                .copyWith(color: ProfilePalette.textMuted),
            filled: true,
            fillColor: ProfilePalette.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ProfileSpacing.radiusSmall),
              borderSide: const BorderSide(color: ProfilePalette.outline),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ProfileSpacing.radiusSmall),
              borderSide: const BorderSide(color: ProfilePalette.outline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ProfileSpacing.radiusSmall),
              borderSide: const BorderSide(color: ProfilePalette.action),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
              onPressed: () {
                c.discardBioEdit();
                setState(() => _editing = false);
              },
              child: Text('Cancel',
                  style: ProfileText.button(context)
                      .copyWith(color: ProfilePalette.textSecondary)),
            ),
            const SizedBox(width: ProfileSpacing.sm),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: ProfilePalette.action,
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              onPressed: () async {
                await c.saveBio();
                if (!context.mounted) return;
                setState(() => _editing = false);
              },
              child: Text('Save', style: ProfileText.button(context)),
            ),
          ],
        ),
      ],
    );
  }
}
