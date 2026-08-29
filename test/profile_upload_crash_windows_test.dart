import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_uploader.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';

/// An upload is two writes — the Storage object, then the Firestore metadata —
/// and the app can die between them in either direction. These are the two
/// windows, and the supersession rule that keeps a slow upload from winning.
void main() {
  const String owner = 'ownerUid';

  late FakeFirebaseFirestore db;
  late MediaOutbox outbox;
  late MediaUploader uploader;

  setUp(() {
    db = FakeFirebaseFirestore();
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
    final ProfileRepository profiles = ProfileRepository(firestore: db);
    final ShowcaseRepository showcase = ShowcaseRepository(firestore: db);
    final StoryRepository stories =
        StoryRepository(firestore: db, outbox: outbox);
    uploader = MediaUploader(
      firestore: db,
      outbox: outbox,
      profiles: profiles,
      showcase: showcase,
      stories: stories,
    );
  });

  tearDown(() async {
    await outbox.close();
  });

  Future<OutboxItem> queuePost(String id, {String? caption}) => outbox.enqueue(
        mediaId: id,
        ownerUid: owner,
        kind: OutboxKind.post,
        mediaType: MediaType.image,
        storagePath: 'users/$owner/posts/$id/original.jpg',
        localFilePath: '/tmp/$id.jpg',
        caption: caption,
      );

  Future<OutboxItem> queueProof(String id, String fingerprint) =>
      outbox.enqueue(
        mediaId: id,
        ownerUid: owner,
        kind: OutboxKind.proof,
        mediaType: MediaType.video,
        storagePath: 'users/$owner/posts/$id/original.mp4',
        localFilePath: '/tmp/$id.mp4',
        achievementFingerprint: fingerprint,
        achievementSlot: 'bench',
      );

  Future<OutboxItem> queueStory(String id) => outbox.enqueue(
        mediaId: id,
        ownerUid: owner,
        kind: OutboxKind.story,
        mediaType: MediaType.image,
        storagePath: 'users/$owner/stories/$id/original.jpg',
        localFilePath: '/tmp/$id.jpg',
      );

  Future<OutboxItem> queueAvatar(String id) => outbox.enqueue(
        mediaId: id,
        ownerUid: owner,
        kind: OutboxKind.avatar,
        mediaType: MediaType.image,
        storagePath: 'users/$owner/profile/$id.jpg',
        localFilePath: '/tmp/$id.jpg',
        supersessionKey: 'avatar:$owner',
      );

  group('crash window B: Firestore committed, the outbox row survived', () {
    test('an existing post document means finish, do not re-upload', () async {
      final OutboxItem item = await queuePost('m1');
      // The previous run's commit landed; then the app died.
      await db.collection('posts').doc('m1').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': MediaType.image,
        'createdAt': Timestamp.now(),
      });

      expect(await uploader.metadataExists(item), isTrue);
      expect(await uploader.planFor(item), UploadStep.skipAlreadyCommitted);
    });

    test('an existing story document means finish, do not re-publish',
        () async {
      final OutboxItem item = await queueStory('s1');
      await db
          .collection('users')
          .doc(owner)
          .collection('stories')
          .doc('s1')
          .set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': MediaType.image,
        'publishedAt': Timestamp.now(),
      });

      expect(await uploader.metadataExists(item), isTrue);
      expect(await uploader.planFor(item), UploadStep.skipAlreadyCommitted);
    });

    test('republishing a story would restart its 24 hours, so it must not',
        () async {
      final DateTime published =
          DateTime.now().subtract(const Duration(hours: 20));
      final OutboxItem item = await queueStory('s1');
      final DocumentReference<Map<String, dynamic>> ref =
          db.collection('users').doc(owner).collection('stories').doc('s1');
      await ref.set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': MediaType.image,
        'publishedAt': Timestamp.fromDate(published),
      });

      expect(await uploader.planFor(item), UploadStep.skipAlreadyCommitted,
          reason: 'a re-publish would reset the expiry clock');
      final Timestamp after =
          (await ref.get()).data()!['publishedAt'] as Timestamp;
      expect(after.toDate(), published);
    });

    test('a fresh row with no metadata proceeds to upload', () async {
      final OutboxItem item = await queuePost('m1');
      expect(await uploader.metadataExists(item), isFalse);
      expect(await uploader.planFor(item), UploadStep.upload);
    });

    test('an avatar always proceeds: the profile field IS its metadata',
        () async {
      final OutboxItem item = await queueAvatar('a1');
      expect(await uploader.metadataExists(item), isFalse);
      expect(await uploader.planFor(item), UploadStep.upload);
    });
  });

  group('crash window A: Storage succeeded, Firestore did not', () {
    test('committing twice produces ONE post, not a duplicate', () async {
      final OutboxItem item = await queuePost('m1', caption: 'first');

      await uploader.commitMetadata(item, 'https://example.invalid/m1.jpg');
      await uploader.commitMetadata(item, 'https://example.invalid/m1.jpg');

      final QuerySnapshot<Map<String, dynamic>> posts = await db
          .collection('posts')
          .where('ownerUid', isEqualTo: owner)
          .get();
      expect(posts.docs, hasLength(1));
      expect(posts.docs.single.id, 'm1',
          reason: 'the document id is the client-chosen media id, so a retry '
              'overwrites rather than inserting');
      expect(posts.docs.single.data()['caption'], 'first');
    });

    test('the storage path is chosen up front, so a retry overwrites',
        () async {
      final OutboxItem item = await queuePost('m1');
      await outbox.markFailed('m1', 'network died', terminal: false);
      final OutboxItem retried = (await outbox.byId('m1'))!;
      expect(retried.storagePath, item.storagePath);
      expect(retried.storagePath, contains('m1'));
    });

    test('a proof commit writes the post AND the proof pointer to one asset',
        () async {
      final OutboxItem item = await queueProof('p1', 'fp-abc');
      await uploader.commitMetadata(item, 'https://example.invalid/p1.mp4');

      final Map<String, dynamic> post =
          (await db.collection('posts').doc('p1').get()).data()!;
      expect(post['type'], PostKind.proof);
      expect(post['showInGrid'], isTrue,
          reason: 'proof media appears in the grid by default');
      expect((post['achievement'] as Map<Object?, Object?>)['fingerprint'],
          'fp-abc');

      final Map<String, dynamic> proof = (await db
              .collection('users')
              .doc(owner)
              .collection('proofs')
              .doc('fp-abc')
              .get())
          .data()!;
      expect(proof['postId'], 'p1',
          reason: 'the proof points at the SAME asset — one upload, not two');
      expect(proof['storagePath'], item.storagePath);
    });

    test('committing a proof twice leaves one post and one pointer', () async {
      final OutboxItem item = await queueProof('p1', 'fp-abc');
      await uploader.commitMetadata(item, 'https://example.invalid/p1.mp4');
      await uploader.commitMetadata(item, 'https://example.invalid/p1.mp4');

      expect((await db.collection('posts').get()).docs, hasLength(1));
      expect(
        (await db.collection('users').doc(owner).collection('proofs').get())
            .docs,
        hasLength(1),
      );
    });

    test('an avatar commit points the profile at the new object', () async {
      final OutboxItem item = await queueAvatar('a1');
      await uploader.commitMetadata(item, 'https://example.invalid/a1.jpg');

      final Map<String, dynamic> data =
          (await db.collection('users_public').doc(owner).get()).data()!;
      expect(data['photoURL'], 'https://example.invalid/a1.jpg');
      expect(data['photoStoragePath'], item.storagePath);
    });

    test('a story commit records a server publication time', () async {
      final OutboxItem item = await queueStory('s1');
      await uploader.commitMetadata(item, 'https://example.invalid/s1.jpg');

      final Map<String, dynamic> data = (await db
              .collection('users')
              .doc(owner)
              .collection('stories')
              .doc('s1')
              .get())
          .data()!;
      expect(data['publishedAt'], isNotNull);
      expect(data.containsKey('expiresAt'), isFalse,
          reason: 'expiresAt is stamped server-side, never by the client');
    });
  });

  group('supersession', () {
    test('a superseded avatar is refused BEFORE it can commit', () async {
      final OutboxItem slow = await queueAvatar('a1');
      await queueAvatar('a2');

      expect(await uploader.planFor(slow), UploadStep.skipSuperseded,
          reason: 'the 10:00 choice must never overwrite the 10:01 one');
    });

    test('the newest generation is the one that proceeds', () async {
      await queueAvatar('a1');
      final OutboxItem newest = await queueAvatar('a2');
      expect(await uploader.planFor(newest), UploadStep.upload);
    });

    test('append-only media is never superseded by a later upload', () async {
      final OutboxItem first = await queuePost('m1');
      await queuePost('m2');
      expect(await uploader.planFor(first), UploadStep.upload);
    });

    test('a superseded row stays queued for orphan cleanup', () async {
      await queueAvatar('a1');
      await queueAvatar('a2');
      final List<OutboxItem> orphans = await outbox.superseded();
      expect(orphans.map((OutboxItem i) => i.mediaId), <String>['a1']);
      // Its deterministic path is what makes cleaning it up safe: it can only
      // ever be the loser's own object, never the live avatar's.
      expect(orphans.single.storagePath, contains('a1'));
      expect(orphans.single.storagePath, isNot(contains('a2')));
    });

    test('cleanup only ever targets a superseded row own object', () async {
      final OutboxItem loser = await queueAvatar('a1');
      final OutboxItem winner = await queueAvatar('a2');
      expect(loser.storagePath, isNot(winner.storagePath),
          reason: 'generation-stamped paths are what make the loser safely '
              'deletable without touching the winner');
    });
  });

  group('metadata never depends on an unreadable check', () {
    test(
        'an unreadable existence check proceeds, because commits are idempotent',
        () async {
      // metadataExists swallows read failures and returns false. That is safe
      // precisely because every commit is an idempotent set() on a
      // deterministic id — proceeding can duplicate nothing.
      final OutboxItem item = await queuePost('m1');
      expect(await uploader.metadataExists(item), isFalse);
      await uploader.commitMetadata(item, 'https://example.invalid/m1.jpg');
      await uploader.commitMetadata(item, 'https://example.invalid/m1.jpg');
      expect((await db.collection('posts').get()).docs, hasLength(1));
    });
  });
}
