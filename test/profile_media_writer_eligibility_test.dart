/// Every current writer records gallery eligibility explicitly.
///
/// The gallery query filters SERVER-SIDE now, so a writer that forgets a field
/// no longer produces a slightly wrong tile — it produces media that never
/// appears at all. These tests pin that contract to the writers themselves, so
/// a new publication path cannot quietly ship media the gallery will not show.
///
/// The three current writers of grid media are the post, proof and story
/// branches of `MediaUploader.commitMetadata`. Stories are checked too, for the
/// opposite reason: they must stay OUT of the permanent gallery.
library;

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_identity.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_repository.dart';
import 'package:localtest222/profile/data/media_uploader.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';

void main() {
  const String owner = 'ownerUid';

  late FakeFirebaseFirestore db;
  late MediaOutbox outbox;
  late MediaUploader uploader;
  late MediaRepository media;

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
      ownerUidOverride: () => owner,
    );
    media = MediaRepository(firestore: db, outbox: outbox);
  });

  tearDown(() async => outbox.close());

  Future<OutboxItem> queue({
    required String id,
    required String kind,
    required String mediaType,
    String? fingerprint,
  }) =>
      outbox.enqueue(
        mediaId: id,
        ownerUid: owner,
        kind: kind,
        mediaType: mediaType,
        storagePath: kind == OutboxKind.story
            ? 'users/$owner/stories/$id/original.jpg'
            : 'users/$owner/posts/$id/original.'
                '${mediaType == MediaType.video ? 'mov' : 'jpg'}',
        localFilePath: '/tmp/$id',
        achievementFingerprint: fingerprint,
        achievementSlot: fingerprint == null ? null : 'bench',
      );

  Future<Map<String, dynamic>> postDoc(String id) async =>
      (await db.collection('posts').doc(id).get()).data()!;

  group('every current gallery writer sets eligibility', () {
    test('an image post is written with mediaType and showInGrid', () async {
      final OutboxItem item = await queue(
        id: 'img1',
        kind: OutboxKind.post,
        mediaType: MediaType.image,
      );
      await uploader.commitMetadata(item, 'https://example.invalid/img1.jpg');

      final Map<String, dynamic> d = await postDoc('img1');
      expect(d['mediaType'], MediaType.image);
      expect(isSupportedMediaType(d['mediaType']), isTrue);
      expect(d['showInGrid'], isTrue);
      expect(d['ownerUid'], owner);
      expect(d['createdAt'], isNotNull);
    });

    test('a video post is written with mediaType and showInGrid', () async {
      final OutboxItem item = await queue(
        id: 'vid1',
        kind: OutboxKind.post,
        mediaType: MediaType.video,
      );
      await uploader.commitMetadata(
        item,
        'https://example.invalid/vid1.mov',
        thumbUrl: 'https://example.invalid/vid1-thumb.jpg',
      );

      final Map<String, dynamic> d = await postDoc('vid1');
      expect(d['mediaType'], MediaType.video);
      expect(d['showInGrid'], isTrue);
    });

    test('a proof video is written with mediaType and showInGrid', () async {
      final OutboxItem item = await queue(
        id: 'proof1',
        kind: OutboxKind.proof,
        mediaType: MediaType.video,
        fingerprint: 'fp-1',
      );
      await uploader.commitMetadata(
        item,
        'https://example.invalid/proof1.mov',
        thumbUrl: 'https://example.invalid/proof1-thumb.jpg',
      );

      final Map<String, dynamic> d = await postDoc('proof1');
      expect(d['mediaType'], MediaType.video);
      expect(d['showInGrid'], isTrue);
      expect(d['type'], PostKind.proof);
    });

    test('everything a current writer publishes reaches the grid', () async {
      await uploader.commitMetadata(
        await queue(
            id: 'a', kind: OutboxKind.post, mediaType: MediaType.image),
        'https://example.invalid/a.jpg',
      );
      await uploader.commitMetadata(
        await queue(
            id: 'b', kind: OutboxKind.post, mediaType: MediaType.video),
        'https://example.invalid/b.mov',
        thumbUrl: 'https://example.invalid/b.jpg',
      );
      await uploader.commitMetadata(
        await queue(
          id: 'c',
          kind: OutboxKind.proof,
          mediaType: MediaType.video,
          fingerprint: 'fp-2',
        ),
        'https://example.invalid/c.mov',
        thumbUrl: 'https://example.invalid/c.jpg',
      );

      final List<ProfileMediaItem> grid = await media.watchGrid(owner).first;
      expect(
        grid.map((ProfileMediaItem i) => i.id).toSet(),
        <String>{'a', 'b', 'c'},
        reason: 'the server-side filter must not exclude anything the app '
            'itself writes',
      );
      expect(grid.every((ProfileMediaItem i) => i.isSupported), isTrue);
    });
  });

  group('stories stay out of the permanent gallery', () {
    test('publishing a story writes no post document at all', () async {
      final OutboxItem item = await queue(
        id: 'story1',
        kind: OutboxKind.story,
        mediaType: MediaType.image,
      );
      await uploader.commitMetadata(item, 'https://example.invalid/s.jpg');

      expect((await db.collection('posts').get()).docs, isEmpty);
      expect(await media.watchGrid(owner).first, isEmpty);
    });

    test('the story it does write lives under the user and starts its clock',
        () async {
      final OutboxItem item = await queue(
        id: 'story2',
        kind: OutboxKind.story,
        mediaType: MediaType.image,
      );
      await uploader.commitMetadata(item, 'https://example.invalid/s2.jpg');

      final Map<String, dynamic> d = (await db
              .collection('users')
              .doc(owner)
              .collection('stories')
              .doc('story2')
              .get())
          .data()!;
      expect(d['ownerUid'], owner);
      expect(d['publishedAt'], isNotNull);
    });
  });

  group('the avatar is not gallery media', () {
    test('replacing an avatar creates no post', () async {
      final OutboxItem item = await queue(
        id: 'avatar1',
        kind: OutboxKind.avatar,
        mediaType: MediaType.image,
      );
      await uploader.commitMetadata(item, 'https://example.invalid/av.jpg');

      expect((await db.collection('posts').get()).docs, isEmpty);
      final Map<String, dynamic> d =
          (await db.collection('users_public').doc(owner).get()).data()!;
      expect(d['photoURL'], 'https://example.invalid/av.jpg');
    });
  });
}
