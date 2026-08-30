import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/identity_repository.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_repository.dart';
import 'package:localtest222/profile/data/media_staging.dart';
import 'package:localtest222/profile/data/media_uploader.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';
import 'package:localtest222/profile/profile_controller.dart';

/// The story ring and the viewer have to disappear at the EXACT moment the
/// story expires.
///
/// Nothing else makes that happen. The Firestore listener only fires when a
/// document CHANGES, and an expiring story does not change — it just gets
/// older. The hourly server sweep eventually deletes it, but until then a ring
/// left open on screen kept offering a story that was already over, for up to
/// an hour, and any unrelated rebuild would make it vanish at some arbitrary
/// moment instead.
void main() {
  const String owner = 'ownerUid';

  late FakeFirebaseFirestore db;
  late MediaOutbox outbox;

  /// A controllable clock, so the boundary is crossed deterministically
  /// instead of by waiting 24 hours.
  late DateTime now;
  DateTime clock() => now;

  setUp(() {
    db = FakeFirebaseFirestore();
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
    now = DateTime.utc(2026, 8, 30, 12);
  });

  tearDown(() async {
    await outbox.close();
  });

  ProfileController controllerFor() {
    final ProfileRepository profiles = ProfileRepository(firestore: db);
    final ShowcaseRepository showcase = ShowcaseRepository(firestore: db);
    final StoryRepository stories =
        StoryRepository(firestore: db, outbox: outbox);
    final MediaRepository media =
        MediaRepository(firestore: db, outbox: outbox);
    return ProfileController(
      targetUid: owner,
      actorUid: owner,
      profiles: profiles,
      identity: IdentityRepository(firestore: db),
      showcase: showcase,
      media: media,
      stories: stories,
      staging: MediaStaging(outbox: outbox),
      uploader: MediaUploader(
        firestore: db,
        outbox: outbox,
        profiles: profiles,
        showcase: showcase,
        stories: stories,
        ownerUidOverride: () => owner,
      ),
      clock: clock,
    );
  }

  Future<void> seedStory(String id, {required Duration ago}) =>
      db.collection('users').doc(owner).collection('stories').doc(id).set(
        <String, Object?>{
          'ownerUid': owner,
          'mediaType': MediaType.image,
          'url': 'https://example.invalid/$id.jpg',
          'publishedAt': Timestamp.fromDate(now.subtract(ago)),
        },
      );

  testWidgets('the ring disappears at the exact expiry, with no new snapshot',
      (WidgetTester t) async {
    // Two minutes of life left, comfortably outside the query's clock-skew
    // margin so it is genuinely listed.
    await seedStory('s1', ago: StoryItem.ttl - const Duration(minutes: 2));

    final ProfileController c = controllerFor()..start();
    addTearDown(c.dispose);
    await t.pump(const Duration(milliseconds: 10));

    expect(c.hasStoryRing, isTrue);
    expect(c.stories.map((StoryItem s) => s.id), <String>['s1']);

    // Advance the app's clock past the boundary and let the scheduled timer
    // fire. NOTHING is written to Firestore, so the listener does not fire —
    // the timer is the only thing that can notice.
    int notifications = 0;
    c.addListener(() => notifications++);
    now = now.add(const Duration(minutes: 2, seconds: 1));
    await t.pump(const Duration(minutes: 2, seconds: 1));

    expect(c.hasStoryRing, isFalse,
        reason: 'the ring is gone the moment the story expires');
    expect(c.stories, isEmpty);
    expect(notifications, greaterThan(0),
        reason:
            'the UI was told to repaint, rather than waiting for a rebuild');
  });

  testWidgets('the EARLIEST expiry is what the timer is set to',
      (WidgetTester t) async {
    // Three stories expiring 2, 5 and 9 minutes from now. One timer at a time,
    // rearmed each time it fires.
    await seedStory('late', ago: StoryItem.ttl - const Duration(minutes: 9));
    await seedStory('mid', ago: StoryItem.ttl - const Duration(minutes: 5));
    await seedStory('soon', ago: StoryItem.ttl - const Duration(minutes: 2));

    final ProfileController c = controllerFor()..start();
    addTearDown(c.dispose);
    await t.pump(const Duration(milliseconds: 10));
    expect(c.stories.map((StoryItem s) => s.id).toSet(),
        <String>{'soon', 'mid', 'late'});

    now = now.add(const Duration(minutes: 2, seconds: 1));
    await t.pump(const Duration(minutes: 2, seconds: 1));
    expect(
        c.stories.map((StoryItem s) => s.id).toSet(), <String>{'mid', 'late'},
        reason: 'only the one that actually expired is dropped');

    now = now.add(const Duration(minutes: 3));
    await t.pump(const Duration(minutes: 3));
    expect(c.stories.map((StoryItem s) => s.id).toSet(), <String>{'late'});

    now = now.add(const Duration(minutes: 4));
    await t.pump(const Duration(minutes: 4));
    expect(c.stories, isEmpty);
  });

  testWidgets('a pending upload has no expiry and is never timed out',
      (WidgetTester t) async {
    // Its 24 hours have not begun: there is no publishedAt at all.
    await outbox.enqueue(
      mediaId: 'p1',
      ownerUid: owner,
      kind: OutboxKind.story,
      mediaType: MediaType.image,
      storagePath: 'users/$owner/stories/p1/original.jpg',
      localFilePath: '/tmp/p1.jpg',
    );

    final ProfileController c = controllerFor()..start();
    addTearDown(c.dispose);
    await t.pump(const Duration(milliseconds: 10));
    expect(c.stories.map((StoryItem s) => s.id), <String>['p1']);

    now = now.add(const Duration(days: 3));
    await t.pump(const Duration(days: 3));
    expect(c.stories.map((StoryItem s) => s.id), <String>['p1'],
        reason: 'a story that never published cannot have expired');
  });

  testWidgets('an already-expired story is never shown in the first place',
      (WidgetTester t) async {
    await seedStory('old', ago: StoryItem.ttl + const Duration(hours: 1));

    final ProfileController c = controllerFor()..start();
    addTearDown(c.dispose);
    await t.pump(const Duration(milliseconds: 10));
    expect(c.hasStoryRing, isFalse);
  });

  testWidgets('disposing cancels the timer', (WidgetTester t) async {
    await seedStory('s1', ago: StoryItem.ttl - const Duration(minutes: 2));
    final ProfileController c = controllerFor()..start();
    await t.pump(const Duration(milliseconds: 10));
    c.dispose();
    // A pending timer firing after dispose would notify a disposed
    // ChangeNotifier, which throws. Advancing past the boundary must be quiet.
    now = now.add(const Duration(minutes: 5));
    await t.pump(const Duration(minutes: 5));
  });
}
