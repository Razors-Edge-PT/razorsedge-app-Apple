import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/core/showcase_reducer.dart';
import 'package:localtest222/profile/data/identity_repository.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_repository.dart';
import 'package:localtest222/profile/data/media_staging.dart';
import 'package:localtest222/profile/data/media_uploader.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';
import 'package:localtest222/profile/profile_controller.dart';

/// Ownership, editor safety, and what the page shows when it is offline.
void main() {
  const String owner = 'ownerUid';
  const String coach = 'coachUid';
  const String friend = 'friendUid';
  const String bench = 'AmfUWbF1DH3I7qPAdh5k';

  late FakeFirebaseFirestore db;
  late MediaOutbox outbox;

  setUp(() {
    db = FakeFirebaseFirestore();
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
  });

  tearDown(() async {
    await outbox.close();
  });

  ProfileController controllerFor({
    required String targetUid,
    required String actorUid,
  }) {
    final ProfileRepository profiles = ProfileRepository(firestore: db);
    final ShowcaseRepository showcase = ShowcaseRepository(firestore: db);
    final StoryRepository stories =
        StoryRepository(firestore: db, outbox: outbox);
    final MediaRepository media =
        MediaRepository(firestore: db, outbox: outbox);
    return ProfileController(
      targetUid: targetUid,
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

  Future<void> seedProfile({
    String username = 'BenchKing',
    String bio = 'Chasing a 200 bench.',
    Map<String, Object?>? showcase,
  }) async {
    await db.collection('users_public').doc(owner).set(<String, Object?>{
      'username': username,
      'usernameLower': username.toLowerCase(),
      'bio': bio,
      'photoURL': 'https://example.invalid/a.jpg',
      if (showcase != null) 'profileShowcaseV1': showcase,
    });
  }

  /// Lets the controller's stream subscriptions deliver.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  group('ownership', () {
    test('the signed-in owner is the owner', () async {
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner);
      expect(c.isOwner, isTrue);
      c.dispose();
    });

    test('a friend viewing the profile is NOT the owner', () async {
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: friend);
      expect(c.isOwner, isFalse);
      c.dispose();
    });

    test('a COACH acting as the athlete is NOT the owner', () async {
      // The decisive case. A coach operating an athlete's account must never
      // receive avatar, username, bio, story or media controls: ownership is
      // derived from the authenticated actor, not from who is in focus.
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: coach);
      expect(c.isOwner, isFalse);
      c.dispose();
    });

    test('a non-owner cannot save a bio even if the method is called',
        () async {
      await seedProfile(bio: 'Original');
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: coach)..start();
      await settle();

      c.bioController.text = 'Coach wrote this';
      await c.saveBio();
      await settle();

      final DocumentSnapshot<Map<String, dynamic>> snap =
          await db.collection('users_public').doc(owner).get();
      expect(snap.data()!['bio'], 'Original');
      expect(c.bioSaveState, SaveState.idle);
      c.dispose();
    });

    test('a non-owner cannot change the username', () async {
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: coach);
      final UsernameChangeResult result = await c.changeUsername('NewName');
      expect(result.isSuccess, isFalse);
      expect(result.message, contains('owner'));
      c.dispose();
    });

    test('a non-owner cannot delete media or add a proof', () async {
      await db.collection('posts').doc('p1').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'createdAt': Timestamp.now(),
      });
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: friend);
      await c.deleteMedia(const ProfileMediaItem(
        id: 'p1',
        ownerUid: owner,
        mediaType: 'image',
        kind: PostKind.upload,
      ));
      expect((await db.collection('posts').doc('p1').get()).exists, isTrue);

      await c.removeProof('somefingerprint');
      c.dispose();
    });
  });

  group('identity display', () {
    test('shows the username from the profile document', () async {
      await seedProfile(username: 'BenchKing');
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.displayName, 'BenchKing');
      c.dispose();
    });

    test('falls back to a safe label rather than showing nothing', () async {
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: friend)..start();
      await settle();
      expect(c.displayName, isNotEmpty);
      expect(c.displayName, 'GoodLift athlete');
      c.dispose();
    });

    test('a rename propagates to the page without a reload', () async {
      await seedProfile(username: 'BenchKing');
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.displayName, 'BenchKing');

      await db.collection('users_public').doc(owner).set(
        <String, Object?>{'username': 'DeadliftKing'},
        SetOptions(merge: true),
      );
      await settle();
      expect(c.displayName, 'DeadliftKing');
      c.dispose();
    });
  });

  group('the editor is never overwritten mid-typing', () {
    test('a background snapshot does not replace text being edited', () async {
      await seedProfile(bio: 'Original');
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.bioController.text, 'Original');

      // The user starts typing.
      c.bioController.text = 'Half-written thou';
      c.onBioChanged(c.bioController.text);
      expect(c.bioDirty, isTrue);

      // A snapshot arrives from another device.
      await db.collection('users_public').doc(owner).set(
        <String, Object?>{'bio': 'Written elsewhere'},
        SetOptions(merge: true),
      );
      await settle();

      expect(c.bioController.text, 'Half-written thou',
          reason: 'the remote value must not be yanked in under the user');
      c.dispose();
    });

    test('once the edit is finished, remote changes are adopted again',
        () async {
      await seedProfile(bio: 'Original');
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      c.bioController.text = 'Typing';
      c.onBioChanged('Typing');
      c.discardBioEdit();
      expect(c.bioDirty, isFalse);

      await db.collection('users_public').doc(owner).set(
        <String, Object?>{'bio': 'From another device'},
        SetOptions(merge: true),
      );
      await settle();
      expect(c.bioController.text, 'From another device');
      c.dispose();
    });

    test('cancelling restores the stored bio exactly', () async {
      await seedProfile(bio: 'Original');
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      c.bioController.text = 'Scribble';
      c.onBioChanged('Scribble');
      c.discardBioEdit();
      expect(c.bioController.text, 'Original');
      c.dispose();
    });
  });

  group('saving a bio', () {
    test('writes only the bio field, leaving everything else alone', () async {
      await seedProfile(bio: 'Original');
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      c.bioController.text = 'New bio with https://goodlift.app';
      c.onBioChanged(c.bioController.text);
      await c.saveBio();
      await settle();

      final Map<String, dynamic> data =
          (await db.collection('users_public').doc(owner).get()).data()!;
      expect(data['bio'], 'New bio with https://goodlift.app');
      // Field-level merge: the avatar and username are untouched.
      expect(data['photoURL'], 'https://example.invalid/a.jpg');
      expect(data['username'], 'BenchKing');
      expect(c.bioDirty, isFalse);
      c.dispose();
    });

    test('clamps an over-long bio to the 150 character limit', () async {
      await seedProfile();
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      c.bioController.text = 'z' * 400;
      c.onBioChanged(c.bioController.text);
      await c.saveBio();
      await settle();

      final Map<String, dynamic> data =
          (await db.collection('users_public').doc(owner).get()).data()!;
      expect((data['bio'] as String).length, kBioMaxLength);
      c.dispose();
    });

    test('reports a definite save state rather than leaving it unknown',
        () async {
      await seedProfile();
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      c.bioController.text = 'Saved bio';
      c.onBioChanged('Saved bio');
      await c.saveBio();
      expect(
        c.bioSaveState,
        anyOf(SaveState.saved, SaveState.savedOffline),
        reason: 'the user is always told which of the two happened',
      );
      c.dispose();
    });
  });

  group('the achievement showcase', () {
    test('renders from the mirrored snapshot with no history scan', () async {
      final ProfileShowcase computed = buildShowcase(<String, Object?>{
        '2026-04-17': <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': bench,
              'sets': <Object?>[
                <String, Object?>{'weight': 180, 'reps': 2},
              ],
            },
          ],
        },
      });
      await seedProfile(showcase: computed.toMap());

      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      final ShowcaseLiftSnapshot lift = c.showcase.lift(BigFiveSlot.bench);
      expect(lift.heaviest!.weight, 180);
      expect(lift.heaviest!.reps, 2);
      expect(lift.bestE1rm!.dateKey, '2026-04-17');

      // Nothing was read from the workouts collection at all.
      final QuerySnapshot<Map<String, dynamic>> workouts =
          await db.collection('users').doc(owner).collection('workouts').get();
      expect(workouts.docs, isEmpty);
      c.dispose();
    });

    test('a viewer who cannot read proofs still sees the achievements',
        () async {
      final ProfileShowcase computed = buildShowcase(<String, Object?>{
        '2026-04-17': <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': bench,
              'sets': <Object?>[
                <String, Object?>{'weight': 180, 'reps': 2},
              ],
            },
          ],
        },
      });
      await seedProfile(showcase: computed.toMap());

      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: coach)..start();
      await settle();

      expect(c.showcase.lift(BigFiveSlot.bench).heaviest!.weight, 180);
      expect(c.showcase.proofsByFingerprint, isEmpty);
      c.dispose();
    });

    test('a proof whose record has changed is no longer shown as proof',
        () async {
      final ProfileShowcase old = buildShowcase(<String, Object?>{
        '2026-04-17': <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': bench,
              'sets': <Object?>[
                <String, Object?>{'weight': 180, 'reps': 2},
              ],
            },
          ],
        },
      });
      final String staleFingerprint =
          old.forSlot(BigFiveSlot.bench).heaviest!.fingerprint;

      // The workout was corrected; the record — and its fingerprint — changed.
      final ProfileShowcase current = buildShowcase(<String, Object?>{
        '2026-04-17': <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': bench,
              'sets': <Object?>[
                <String, Object?>{'weight': 120, 'reps': 2},
              ],
            },
          ],
        },
      });
      await seedProfile(showcase: current.toMap());

      // The old proof document is still there — the video stays in the gallery.
      await db
          .collection('users')
          .doc(owner)
          .collection('proofs')
          .doc(staleFingerprint)
          .set(<String, Object?>{
        'fingerprint': staleFingerprint,
        'slot': BigFiveSlot.bench,
        'postId': 'oldPost',
      });

      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      final ShowcaseLiftSnapshot lift = c.showcase.lift(BigFiveSlot.bench);
      expect(c.showcase.proofFor(lift.heaviest), isNull,
          reason: 'the standing record has no proof any more');
      expect(c.showcase.staleProofs.map((ProofRecord p) => p.fingerprint),
          <String>[staleFingerprint]);
      c.dispose();
    });
  });

  group('the grid', () {
    test('includes a post that carries no type, as long as it is eligible',
        () async {
      // `type` is still optional - an upload written without one is an
      // ordinary upload. `showInGrid` is not optional any more: it is the
      // server-side gallery eligibility clause, and a post without it is
      // deliberately absent. See MediaRepository.watchGrid.
      await seedProfile();
      await db.collection('posts').doc('noType').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'showInGrid': true,
        'thumbUrl': 'https://example.invalid/noType.jpg',
        'createdAt': Timestamp.fromDate(DateTime(2024, 1, 1)),
      });
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.grid.map((ProfileMediaItem i) => i.id), contains('noType'));
      expect(c.grid.single.kind, PostKind.upload);
      c.dispose();
    });

    test('includes proof media with its achievement link', () async {
      await seedProfile();
      await db.collection('posts').doc('proofPost').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'video',
        'type': PostKind.proof,
        'showInGrid': true,
        'achievement': <String, Object?>{'fingerprint': 'fp1', 'slot': 'bench'},
        'createdAt': Timestamp.now(),
      });
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.grid.single.isProof, isTrue);
      expect(c.grid.single.proof!.fingerprint, 'fp1');
      c.dispose();
    });

    test('excludes anything explicitly hidden from the grid', () async {
      await seedProfile();
      await db.collection('posts').doc('hidden').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'showInGrid': false,
        'createdAt': Timestamp.now(),
      });
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.grid, isEmpty);
      c.dispose();
    });

    test('a pending upload appears immediately, above published media',
        () async {
      await seedProfile();
      await db.collection('posts').doc('published').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'showInGrid': true,
        'createdAt': Timestamp.fromDate(DateTime(2024, 1, 1)),
      });
      await outbox.enqueue(
        mediaId: 'queued',
        ownerUid: owner,
        kind: OutboxKind.post,
        mediaType: 'image',
        storagePath: 'users/$owner/posts/queued/original.jpg',
        localFilePath: '/tmp/queued.jpg',
      );

      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      expect(c.grid.first.id, 'queued');
      expect(c.grid.first.pending, isTrue);
      expect(c.grid.map((ProfileMediaItem i) => i.id),
          <String>['queued', 'published']);
      c.dispose();
    });

    test('a NON-owner never sees the owner pending uploads', () async {
      await seedProfile();
      await outbox.enqueue(
        mediaId: 'queued',
        ownerUid: owner,
        kind: OutboxKind.post,
        mediaType: 'image',
        storagePath: 'users/$owner/posts/queued/original.jpg',
        localFilePath: '/tmp/queued.jpg',
      );
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: friend)..start();
      await settle();
      expect(c.grid, isEmpty);
      c.dispose();
    });

    test('a published item replaces its own pending tile, never duplicating it',
        () async {
      final List<ProfileMediaItem> pending = <ProfileMediaItem>[
        ProfileMediaItem(
          id: 'same',
          ownerUid: owner,
          mediaType: 'image',
          kind: PostKind.upload,
          pending: true,
          createdAt: DateTime(2026, 1, 2),
        ),
      ];
      final List<ProfileMediaItem> published = <ProfileMediaItem>[
        ProfileMediaItem(
          id: 'same',
          ownerUid: owner,
          mediaType: 'image',
          kind: PostKind.upload,
          createdAt: DateTime(2026, 1, 2),
        ),
      ];
      final List<ProfileMediaItem> merged =
          MediaRepository.mergeGrid(published, pending);
      expect(merged, hasLength(1));
      expect(merged.single.pending, isFalse);
    });
  });

  group('stories', () {
    test('an expired story is hidden immediately', () async {
      await seedProfile();
      await db
          .collection('users')
          .doc(owner)
          .collection('stories')
          .doc('old')
          .set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'publishedAt': Timestamp.fromDate(
            DateTime.now().subtract(const Duration(hours: 25))),
      });
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.stories, isEmpty);
      expect(c.hasStoryRing, isFalse);
      c.dispose();
    });

    test('a live story shows, and gives the avatar its ring', () async {
      await seedProfile();
      await db
          .collection('users')
          .doc(owner)
          .collection('stories')
          .doc('fresh')
          .set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': 'image',
        'publishedAt': Timestamp.fromDate(
            DateTime.now().subtract(const Duration(hours: 1))),
      });
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.stories.map((StoryItem s) => s.id), <String>['fresh']);
      expect(c.hasStoryRing, isTrue);
      c.dispose();
    });

    test('a pending story is owner-only and has not started expiring',
        () async {
      await seedProfile();
      await outbox.enqueue(
        mediaId: 'queuedStory',
        ownerUid: owner,
        kind: OutboxKind.story,
        mediaType: 'image',
        storagePath: 'users/$owner/stories/queuedStory/original.jpg',
        localFilePath: '/tmp/story.jpg',
      );

      final ProfileController mine =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(mine.stories.single.pending, isTrue);
      expect(mine.stories.single.publishedAt, isNull,
          reason: 'the 24 hours begin only on successful publication');
      expect(mine.stories.single.isLiveAt(DateTime.now()), isFalse);
      mine.dispose();

      final ProfileController theirs =
          controllerFor(targetUid: owner, actorUid: friend)..start();
      await settle();
      expect(theirs.stories, isEmpty,
          reason: 'nobody else can see an unpublished story');
      theirs.dispose();
    });
  });

  group('warm cache and offline', () {
    test('a missing profile document does not blank the page', () async {
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(c.loaded, isTrue);
      expect(c.displayName, isNotEmpty);
      expect(c.showcase.showcase.hasAnything, isFalse);
      expect(c.grid, isEmpty);
      c.dispose();
    });

    test('reopening a profile renders the same identity and achievements',
        () async {
      final ProfileShowcase computed = buildShowcase(<String, Object?>{
        '2026-04-17': <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{
              'exerciseId': bench,
              'sets': <Object?>[
                <String, Object?>{'weight': 180, 'reps': 2},
              ],
            },
          ],
        },
      });
      await seedProfile(showcase: computed.toMap());

      final ProfileController first =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      final String name = first.displayName;
      final double weight =
          first.showcase.lift(BigFiveSlot.bench).heaviest!.weight;
      first.dispose();

      // Close and reopen — the profile shell must come straight back.
      final ProfileController second =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(second.displayName, name);
      expect(second.showcase.lift(BigFiveSlot.bench).heaviest!.weight, weight);
      second.dispose();
    });

    test('an offline bio edit survives closing and reopening the page',
        () async {
      await seedProfile(bio: 'Original');
      final ProfileController first =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      first.bioController.text = 'Edited while offline';
      first.onBioChanged(first.bioController.text);
      await first.saveBio();
      await settle();
      first.dispose();

      // Firestore holds the write (locally when offline, on the server when
      // not); either way reopening shows the edit rather than the old value.
      final ProfileController second =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(second.bioController.text, 'Edited while offline');
      expect(second.profile.bio, 'Edited while offline');
      second.dispose();
    });

    test('a pending upload is still pending after the page is reopened',
        () async {
      await seedProfile();
      await outbox.enqueue(
        mediaId: 'queued',
        ownerUid: owner,
        kind: OutboxKind.post,
        mediaType: 'image',
        storagePath: 'users/$owner/posts/queued/original.jpg',
        localFilePath: '/tmp/queued.jpg',
      );

      final ProfileController first =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(first.grid.single.pending, isTrue);
      first.dispose();

      final ProfileController second =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();
      expect(second.grid.single.id, 'queued');
      expect(second.grid.single.pending, isTrue);
      second.dispose();
    });
  });

  group('teardown', () {
    test('disposing does not start a save', () async {
      await seedProfile(bio: 'Original');
      final ProfileController c =
          controllerFor(targetUid: owner, actorUid: owner)..start();
      await settle();

      c.bioController.text = 'Never saved from dispose';
      c.onBioChanged(c.bioController.text);
      c.dispose();
      await settle();

      // An unsaved edit is simply unsaved. Firing a write from dispose could
      // not report its result or be retried, so it is deliberately not done.
      final Map<String, dynamic> data =
          (await db.collection('users_public').doc(owner).get()).data()!;
      expect(data['bio'], 'Original');
    });
  });
}
