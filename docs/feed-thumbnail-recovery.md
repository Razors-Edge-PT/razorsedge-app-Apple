# Feed thumbnail recovery

Reported 9 October 2026: accepted mutual friend coded_nz's home-feed video
captioned `85x3` shows the movie-icon placeholder; opening the video works.
The screenshot matches the no-usable-poster branch, not a playback failure.
Production post metadata and Storage objects have not been inspected here.

## Source fix

Home and Buddy Hub share FeedCard. When a video's saved thumbnail URL is empty
or names a video container, FeedThumbnail checks the existing image cache and
then makes one bounded lookup for the canonical sibling thumb.jpg. The same
stable key is used across normal and recovered previews. Recovery is viewport
gated and never downloads the video. A genuinely absent poster displays
`Video · Tap to watch` and retains the existing play action.

MediaUploader now lets thumbnail upload errors reach the existing outbox retry
policy instead of publishing the post with an empty preview and deleting its
local thumbnail. A video whose codec produced no local still remains playable.
No schemas, security rules, function exports, dependencies or version changed.

## Existing-post repair

The repair script uses existing Application Default Credentials, firebase-admin
and a local ffmpeg executable. It is dry-run by default and explicitly scoped
to one public username. In the canonical desktop checkout, after syncing main:

```powershell
Set-Location -LiteralPath 'C:\Projects\goodlift_app\GoodLift_production\functions'
npm ci
node scripts/repair_post_thumbnails.js --username coded_nz
# Once the dry run identifies the reported post, target its printed post ID:
node scripts/repair_post_thumbnails.js --username coded_nz --post-id REPORTED_POST_ID --apply
```

Each exit code must be checked before proceeding. ffmpeg must be on PATH for
a missing preview; an existing JPEG can be reused without it. Default scans
inspect at most 200 of the owner's posts and select at most 10 videos from
that page; use --post-id for the exact reported post. The script refuses
noncanonical objects, oversized videos, changed/deleted posts and concurrent
preview edits. Original videos are read only; a JPEG is created only when
absent and only with an ifGenerationMatch=0 precondition. Only thumbUrl and
thumbStoragePath are changed on the post. The existing feedOnPostWritten
trigger updates viewers' projections without a new backend deployment.

This live repair has NOT been run: there are no Firebase credentials available
in the implementation session. It can improve existing app versions after a
server refresh; the client recovery changes require a new installed build.

## Validation

10 repair tests passed, including real ffmpeg video-to-JPEG extraction,
dry-run no-writes, original preservation, concurrent object creation,
idempotence and changed/deleted-post protection. The real-render test is
skipped when ffmpeg is absent; it ran and passed in this environment.

Flutter regression tests were added for thumbnail URL recovery, offline cache
use, readable playable fallback and disposal during lookup. Flutter is not
installed here: analysis, widget tests, Android/iOS builds and phone behavior
remain unverified. Before an app release, run flutter analyze and flutter test,
including feed_media_recovery_test.dart, social_feed_repository_test.dart and
profile_media_outbox_test.dart. Choose the next unused Play versionCode only
after checking which earlier desktop release completed.
