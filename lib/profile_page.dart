/// Compatibility shim for the rebuilt profile page.
///
/// The 4,191-line `_ProfilePageState` that used to live here is gone. It has
/// been replaced by `lib/profile/`:
///
///   profile_screen.dart          thin screen - navigation and pickers only
///   profile_controller.dart      state, ownership, edit controllers
///   core/big_five.dart           which lifts count, and how a row claims one
///   core/e1rm_spec.dart          the canonical E1RM curve
///   core/showcase_reducer.dart   pure lifetime record reducer
///   data/identity_repository     usernames, everywhere in the app
///   data/showcase_repository     achievements + proof videos
///   data/media_repository        the grid
///   data/story_repository        24-hour stories
///   data/media_outbox            durable upload queue (Drift)
///   ui/...                       header, showcase, grid, detail, stories
///
/// The post, comment and video-player components the feed also uses moved to
/// `post_media.dart` unchanged, and are re-exported here so existing importers
/// keep working.
///
/// `ProfilePage` remains as the public name so the four call sites
/// (home_screen, home_screen_2, home_v2_app_bar, approve_requests_screen) and
/// their navigation semantics - self, friend, coach-selected - are untouched.
library;

import 'package:flutter/material.dart';

import 'profile/profile_screen.dart';

export 'post_media.dart';

/// The profile page.
///
/// [viewedUid] null shows the athlete currently in focus; a value shows that
/// person's profile. [readOnly] is honoured, but owner-only controls are
/// decided independently by the authenticated actor's UID, so a coach acting
/// as an athlete never receives them regardless of what this is set to.
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, this.viewedUid, this.readOnly = false});

  final String? viewedUid;
  final bool readOnly;

  @override
  Widget build(BuildContext context) =>
      ProfileScreen(viewedUid: viewedUid, readOnly: readOnly);
}
