import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/media_deletion.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_uploader.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';

/// Publishing a proof writes TWO documents: the post that carries the media,
/// and the pointer at `users/{uid}/proofs/{fingerprint}` that claims it proves
/// a record. They used to be two sequential awaits, so the process could die
/// between them — and the retry could not repair the result, because its
/// "already committed?" check looked only at the post. Finding the post, it
/// declared the work done and deleted the outbox row, making a proof video
/// with no achievement permanent.
void main() {
  const String owner = 'ownerUid';
  const String fingerprint = 'fp-bench-1';

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
      ownerUidOverride: () => owner,
    );
  });

  tearDown(() async {
    await outbox.close();
  });

  Future<OutboxItem> queueProof(String id) => outbox.enqueue(
        mediaId: id,
        ownerUid: owner,
        kind: OutboxKind.proof,
        mediaType: MediaType.video,
        storagePath: 'users/$owner/posts/$id/original.mov',
        localFilePath: '/tmp/$id.mov',
        achievementFingerprint: fingerprint,
        achievementSlot: 'bench',
      );

  Future<OutboxItem> queuePost(String id) => outbox.enqueue(
        mediaId: id,
        ownerUid: owner,
        kind: OutboxKind.post,
        mediaType: MediaType.image,
        storagePath: 'users/$owner/posts/$id/original.jpg',
        localFilePath: '/tmp/$id.jpg',
      );

  DocumentReference<Map<String, dynamic>> proofRef(String fp) =>
      db.collection('users').doc(owner).collection('proofs').doc(fp);

  group('a proof publishes atomically', () {
    test('the post and the pointer both exist after one commit', () async {
      final OutboxItem item = await queueProof('m1');
      await uploader.commitMetadata(
        item,
        'https://example.invalid/m1.mov',
        thumbUrl: 'https://example.invalid/m1-thumb.jpg',
      );

      final DocumentSnapshot<Map<String, dynamic>> post =
          await db.collection('posts').doc('m1').get();
      final DocumentSnapshot<Map<String, dynamic>> proof =
          await proofRef(fingerprint).get();

      expect(post.exists, isTrue);
      expect(proof.exists, isTrue);
      expect(proof.data()!['postId'], 'm1');
      expect(post.data()!['achievement']['fingerprint'], fingerprint);
    });

    test('the pointer carries the same media the post does', () async {
      final OutboxItem item = await queueProof('m1');
      await uploader.commitMetadata(
        item,
        'https://example.invalid/m1.mov',
        thumbUrl: 'https://example.invalid/m1-thumb.jpg',
      );
      final Map<String, dynamic> proof =
          (await proofRef(fingerprint).get()).data()!;
      expect(proof['storagePath'], 'users/$owner/posts/m1/original.mov');
      expect(proof['mediaType'], MediaType.video);
      // The POSTER FRAME, not the video — a proof tile renders this as an
      // image.
      expect(proof['thumbUrl'], 'https://example.invalid/m1-thumb.jpg');
    });

    test('an ordinary post writes no proof pointer at all', () async {
      final OutboxItem item = await queuePost('m2');
      await uploader.commitMetadata(item, 'https://example.invalid/m2.jpg');
      final QuerySnapshot<Map<String, dynamic>> proofs =
          await db.collection('users').doc(owner).collection('proofs').get();
      expect(proofs.docs, isEmpty);
    });

    test('re-committing the same item changes nothing', () async {
      final OutboxItem item = await queueProof('m1');
      const String url = 'https://example.invalid/m1.mov';
      await uploader.commitMetadata(item, url, thumbUrl: 'https://t/1.jpg');
      await uploader.commitMetadata(item, url, thumbUrl: 'https://t/1.jpg');
      await uploader.commitMetadata(item, url, thumbUrl: 'https://t/1.jpg');

      expect((await db.collection('posts').get()).docs, hasLength(1));
      expect(
        (await db.collection('users').doc(owner).collection('proofs').get())
            .docs,
        hasLength(1),
      );
    });
  });

  group('process death after the post but before the proof pointer', () {
    /// Reproduces the half-published state the old two-write code could leave.
    Future<OutboxItem> halfPublished(String id) async {
      final OutboxItem item = await queueProof(id);
      await db.collection('posts').doc(id).set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': MediaType.video,
        'type': PostKind.proof,
        'storagePathOriginal': 'users/$owner/posts/$id/original.mov',
        'smallUrl': 'https://example.invalid/$id.mov',
        'thumbUrl': 'https://example.invalid/$id-thumb.jpg',
        'achievement': <String, Object?>{
          'fingerprint': fingerprint,
          'slot': 'bench',
        },
        'createdAt': Timestamp.now(),
      });
      return item;
    }

    test('the half-published state is DETECTED, not mistaken for finished',
        () async {
      final OutboxItem item = await halfPublished('m1');

      final CommitState state = await uploader.inspectCommit(item);
      expect(state.postExists, isTrue);
      expect(state.proofExists, isFalse);

      // The old check looked only at the post and returned
      // skipAlreadyCommitted, which deleted the row and stranded the proof.
      expect(await uploader.planFor(item), UploadStep.repairProofPointer);
    });

    test('the missing pointer is repaired from the post itself', () async {
      final OutboxItem item = await halfPublished('m1');
      await uploader.repairProofPointer(item);

      final Map<String, dynamic> proof =
          (await proofRef(fingerprint).get()).data()!;
      expect(proof['postId'], 'm1');
      expect(proof['slot'], 'bench');
      // Taken from the published post, so no re-upload was needed to learn it.
      expect(proof['thumbUrl'], 'https://example.invalid/m1-thumb.jpg');
      expect(proof['storagePath'], 'users/$owner/posts/m1/original.mov');
    });

    test('after the repair the item is finished, not repaired again', () async {
      final OutboxItem item = await halfPublished('m1');
      await uploader.repairProofPointer(item);
      expect(await uploader.planFor(item), UploadStep.skipAlreadyCommitted);
    });

    test('a pointer aimed at a DIFFERENT post does not count as ours',
        () async {
      // The fingerprint already has a proof, but it is some other video. This
      // item's own publication is still only half done.
      final OutboxItem item = await halfPublished('m1');
      await proofRef(fingerprint).set(<String, Object?>{
        'fingerprint': fingerprint,
        'postId': 'someOtherPost',
      });
      final CommitState state = await uploader.inspectCommit(item);
      expect(state.proofExists, isFalse);
      expect(await uploader.planFor(item), UploadStep.repairProofPointer);
    });
  });

  group('process death BEFORE the post', () {
    test('nothing exists, so the whole publication is retried', () async {
      final OutboxItem item = await queueProof('m1');
      final CommitState state = await uploader.inspectCommit(item);
      expect(state.postExists, isFalse);
      expect(await uploader.planFor(item), UploadStep.upload);
    });

    test('a pointer with no post is repaired by the full commit', () async {
      // The reverse half-write. Committing writes BOTH, so the post appears
      // and the pointer is overwritten with identical content.
      final OutboxItem item = await queueProof('m1');
      await proofRef(fingerprint).set(<String, Object?>{
        'fingerprint': fingerprint,
        'postId': 'm1',
      });
      expect(await uploader.planFor(item), UploadStep.upload);

      await uploader.commitMetadata(item, 'https://example.invalid/m1.mov',
          thumbUrl: 'https://t/1.jpg');
      expect((await db.collection('posts').doc('m1').get()).exists, isTrue);
      expect((await proofRef(fingerprint).get()).data()!['postId'], 'm1');
    });
  });

  group('deletion clears every pointer that names the post', () {
    test('one post proving TWO records loses both pointers', () async {
      // A single set that is both the best E1RM and the heaviest single is two
      // fingerprints served by one video. The grid only ever knew about one of
      // them, so deleting from the tile left the other claiming a video that
      // no longer existed.
      await db.collection('posts').doc('m1').set(<String, Object?>{
        'ownerUid': owner,
        'mediaType': MediaType.video,
        'storagePathOriginal': 'users/$owner/posts/m1/original.mov',
      });
      for (final String fp in <String>['fp-e1rm', 'fp-heaviest']) {
        await proofRef(fp).set(<String, Object?>{
          'fingerprint': fp,
          'postId': 'm1',
        });
      }
      // And one belonging to a different post, which must survive.
      await proofRef('fp-other').set(<String, Object?>{
        'fingerprint': 'fp-other',
        'postId': 'm9',
      });

      final int removed = await deleteProofPointersForPost(
        firestore: db,
        ownerUid: owner,
        postId: 'm1',
      );

      expect(removed, 2);
      final List<String> left =
          (await db.collection('users').doc(owner).collection('proofs').get())
              .docs
              .map((QueryDocumentSnapshot<Map<String, dynamic>> d) => d.id)
              .toList();
      expect(left, <String>['fp-other']);
    });

    test('clearing pointers for a post with none is a no-op', () async {
      expect(
        await deleteProofPointersForPost(
          firestore: db,
          ownerUid: owner,
          postId: 'nothing',
        ),
        0,
      );
    });
  });
}
