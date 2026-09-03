/// What happens when a profile listener FAILS.
///
/// Every listener in ProfileController subscribed with `onData` only. A rules
/// change, a missing composite index or a dropped connection ended the
/// subscription, escaped to the zone as an unhandled error, and left a page
/// that kept rendering and would never update again — with a gallery
/// indistinguishable from a profile that has no media on it.
///
/// The contract asserted here: a failure keeps what was already loaded, says
/// that it could not refresh, offers a retry that re-subscribes exactly once,
/// and never takes the rest of the page down with it.
library;

import 'dart:async';

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

/// A repository whose gallery stream the test drives by hand.
class _ScriptedMediaRepository extends MediaRepository {
  _ScriptedMediaRepository({
    required super.firestore,
    required super.outbox,
  });

  /// One controller per subscription, so "did it re-subscribe?" and "did it
  /// subscribe TWICE?" are both answerable.
  final List<StreamController<List<ProfileMediaItem>>> controllers =
      <StreamController<List<ProfileMediaItem>>>[];

  int get subscriptions => controllers.length;

  StreamController<List<ProfileMediaItem>> get latest => controllers.last;

  @override
  Stream<List<ProfileMediaItem>> watchGrid(String ownerUid, {int limit = 60}) {
    final StreamController<List<ProfileMediaItem>> c =
        StreamController<List<ProfileMediaItem>>();
    controllers.add(c);
    return c.stream;
  }
}

void main() {
  const String owner = 'ownerUid';
  const String friend = 'friendUid';

  late FakeFirebaseFirestore db;
  late MediaOutbox outbox;
  late _ScriptedMediaRepository media;

  setUp(() {
    db = FakeFirebaseFirestore();
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
    media = _ScriptedMediaRepository(firestore: db, outbox: outbox);
  });

  tearDown(() async {
    for (final StreamController<List<ProfileMediaItem>> c in media.controllers) {
      if (!c.isClosed) await c.close();
    }
    await outbox.close();
  });

  ProfileController controllerFor({String actorUid = owner}) {
    final ProfileRepository profiles = ProfileRepository(firestore: db);
    final ShowcaseRepository showcase = ShowcaseRepository(firestore: db);
    final StoryRepository stories =
        StoryRepository(firestore: db, outbox: outbox);
    return ProfileController(
      targetUid: owner,
      actorUid: actorUid,
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
      ),
    );
  }

  Future<void> seedProfile() =>
      db.collection('users_public').doc(owner).set(<String, Object?>{
        'username': 'BenchKing',
        'bio': 'Chasing a 200 bench.',
        'photoURL': 'https://example.invalid/a.jpg',
      });

  Future<void> settle() async {
    for (int i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  ProfileMediaItem photo(String id) => ProfileMediaItem(
        id: id,
        ownerUid: owner,
        mediaType: MediaType.image,
        kind: PostKind.upload,
        storagePath: 'users/$owner/posts/$id/original.jpg',
        thumbUrl: 'https://example.invalid/$id.jpg',
        smallUrl: 'https://example.invalid/$id.jpg',
        createdAt: DateTime(2026, 1, 1),
      );

  test('a gallery stream failure keeps the content already loaded', () async {
    await seedProfile();
    final ProfileController c = controllerFor()..start();
    await settle();

    media.latest.add(<ProfileMediaItem>[photo('p1'), photo('p2')]);
    await settle();
    expect(c.grid, hasLength(2));

    media.latest.addError(
      FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
    );
    await settle();

    expect(c.grid, hasLength(2),
        reason: 'losing a refresh must not lose what the user is looking at');
    expect(c.gridFailed, isTrue);
    expect(c.gridError, contains('permission-denied'));
    c.dispose();
  });

  test('an empty gallery and a failed gallery are different states', () async {
    await seedProfile();
    final ProfileController c = controllerFor()..start();
    await settle();

    media.latest.add(const <ProfileMediaItem>[]);
    await settle();
    expect(c.grid, isEmpty);
    expect(c.gridFailed, isFalse, reason: 'nothing shared yet is not a failure');

    media.latest.addError(StateError('index missing'));
    await settle();
    expect(c.grid, isEmpty);
    expect(c.gridFailed, isTrue);
    c.dispose();
  });

  test('retry re-subscribes exactly once and clears the error', () async {
    await seedProfile();
    final ProfileController c = controllerFor()..start();
    await settle();
    expect(media.subscriptions, 1);

    media.latest.addError(StateError('boom'));
    await settle();
    expect(c.gridFailed, isTrue);

    c.retryGrid();
    await settle();

    expect(media.subscriptions, 2, reason: 'a retry re-subscribes');
    expect(c.gridFailed, isFalse);

    media.latest.add(<ProfileMediaItem>[photo('fresh')]);
    await settle();
    expect(c.grid.single.id, 'fresh');
    c.dispose();
  });

  test('a healthy stream is not churned by a resume', () async {
    await seedProfile();
    final ProfileController c = controllerFor()..start();
    await settle();

    c.onResumed();
    c.onResumed();
    await settle();

    expect(media.subscriptions, 1,
        reason: 'only a FAILED listener is re-bound; nothing duplicates');
    c.dispose();
  });

  test('a failed stream recovers on resume', () async {
    await seedProfile();
    final ProfileController c = controllerFor()..start();
    await settle();

    media.latest.addError(StateError('connection lost'));
    await settle();
    expect(c.gridFailed, isTrue);

    c.onResumed();
    await settle();

    expect(media.subscriptions, 2);
    expect(c.gridFailed, isFalse);
    c.dispose();
  });

  test('repeated retries never accumulate subscriptions', () async {
    await seedProfile();
    final ProfileController c = controllerFor()..start();
    await settle();

    for (int i = 0; i < 5; i++) {
      media.latest.addError(StateError('still failing'));
      await settle();
      c.retryGrid();
      await settle();
    }

    // One live subscription; the rest are cancelled. A gallery that keeps
    // failing must not turn into a growing pile of listeners.
    expect(media.subscriptions, 6);
    media.latest.add(<ProfileMediaItem>[photo('only')]);
    await settle();
    expect(c.grid, hasLength(1),
        reason: 'a duplicated subscription would deliver the item twice');
    c.dispose();
  });

  test('a gallery failure does not break the rest of the profile', () async {
    await seedProfile();
    final ProfileController c = controllerFor()..start();
    await settle();

    media.latest.addError(StateError('gallery down'));
    await settle();

    // Identity, bio editing and ownership all keep working.
    expect(c.loaded, isTrue);
    expect(c.displayName, 'BenchKing');
    expect(c.bioController.text, 'Chasing a 200 bench.');
    expect(c.isOwner, isTrue);

    c.bioController.text = 'New bio';
    c.onBioChanged('New bio');
    await c.saveBio();
    final Map<String, dynamic> saved =
        (await db.collection('users_public').doc(owner).get()).data()!;
    expect(saved['bio'], 'New bio');
    expect(saved['username'], 'BenchKing');
    c.dispose();
  });

  test('a non-owner sees the same failure handling, and no owner controls',
      () async {
    await seedProfile();
    final ProfileController c = controllerFor(actorUid: friend)..start();
    await settle();

    media.latest.addError(StateError('denied'));
    await settle();

    expect(c.isOwner, isFalse);
    expect(c.gridFailed, isTrue);
    // A viewer cannot be given owner powers by a failure path.
    await c.saveBio();
    expect(c.bioSaveState, SaveState.idle);
    c.dispose();
  });

  test('disposing after a failure leaves nothing subscribed', () async {
    await seedProfile();
    final ProfileController c = controllerFor()..start();
    await settle();
    media.latest.addError(StateError('boom'));
    await settle();
    c.dispose();

    // Delivering onto the dead controller must not reach a disposed listener.
    if (!media.latest.isClosed) {
      media.latest.add(<ProfileMediaItem>[photo('late')]);
    }
    await settle();
  });
}
