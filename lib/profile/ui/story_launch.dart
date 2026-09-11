/// Opening a profile's stories from its avatar.
///
/// One entry point for the owner's own profile and a friend's, so both go
/// through the existing [StoryViewer] with the same ordering (oldest first,
/// the order they were published), the same expiry handling and the same
/// disk-cached media. There is no second viewer for friends.
library;

import 'package:flutter/material.dart';

import '../core/media_models.dart';
import '../profile_controller.dart';
import 'story_viewer.dart';

/// Shown when the ring was on screen but nothing is live any more by the time
/// of the tap — a story crossed its 24 hours, or was deleted, in between.
const String kStoryGoneMessage = 'That story is no longer available.';

/// Opens [c]'s live stories in the existing viewer. Returns true when the
/// viewer was opened.
///
/// Liveness is decided AT THE TAP, from the controller's clock, not from what
/// the ring showed when it was last painted. A story that expired in between
/// therefore never opens an empty viewer; the person is told instead.
Future<bool> openProfileStories(
  BuildContext context,
  ProfileController c, {
  void Function(StoryItem story)? onDelete,
}) async {
  final List<StoryItem> live = c.stories;
  if (live.isEmpty) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(const SnackBar(content: Text(kStoryGoneMessage)));
    return false;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => StoryViewer(
      stories: live,
      username: c.displayName,
      isOwner: c.isOwner,
      onDelete: c.isOwner ? onDelete : null,
    ),
  ));
  return true;
}
