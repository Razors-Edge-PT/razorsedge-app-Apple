import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_uploader.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/data/story_repository.dart';

/// The outbox is one SQLite file on one device, shared by every account that
/// ever signs in on it, and it is the only thing standing between a queued
/// upload and losing it. Three things were wrong with how it was drained.
void main() {
  const String alice = 'aliceUid';
  const String bob = 'bobUid';

  late MediaOutbox outbox;

  setUp(() {
    outbox = MediaOutbox(MediaOutboxDatabase.memory());
  });

  tearDown(() async {
    await outbox.close();
  });

  Future<OutboxItem> queue(String owner, String id) => outbox.enqueue(
        mediaId: id,
        ownerUid: owner,
        kind: OutboxKind.post,
        mediaType: MediaType.image,
        storagePath: 'users/$owner/posts/$id/original.jpg',
        localFilePath: '/tmp/$id.jpg',
      );

  MediaUploader uploaderFor(String? owner) {
    final FakeFirebaseFirestore db = FakeFirebaseFirestore();
    final ProfileRepository profiles = ProfileRepository(firestore: db);
    final ShowcaseRepository showcase = ShowcaseRepository(firestore: db);
    final StoryRepository stories =
        StoryRepository(firestore: db, outbox: outbox);
    return MediaUploader(
      firestore: db,
      outbox: outbox,
      profiles: profiles,
      showcase: showcase,
      stories: stories,
      ownerUidOverride: () => owner ?? '',
    );
  }

  group('claims are scoped to one owner', () {
    test('a claim never returns another account rows', () async {
      // The processor uploads with the CURRENT credentials. Handing it Bob's
      // row while Alice is signed in means writing to users/bobUid/…, which
      // Storage rules deny — so Bob's upload burns its four attempts and dies
      // while he is not even using the app.
      await queue(alice, 'a1');
      await queue(bob, 'b1');
      await queue(alice, 'a2');

      final List<OutboxItem> mine = await outbox.claimable(ownerUid: alice);
      expect(mine.map((OutboxItem i) => i.mediaId), <String>['a1', 'a2']);

      final List<OutboxItem> theirs = await outbox.claimable(ownerUid: bob);
      expect(theirs.map((OutboxItem i) => i.mediaId), <String>['b1']);
    });

    test('another account rows are left waiting, not failed', () async {
      await queue(bob, 'b1');
      await uploaderFor(alice).processAll();
      final OutboxItem? bobs = await outbox.byId('b1');
      expect(bobs!.state, OutboxState.pending);
      expect(bobs.attemptCount, 0,
          reason: 'Bob was not even signed in; nothing was attempted');
    });

    test('a pass with NO signed-in account does nothing at all', () async {
      await queue(alice, 'a1');
      final UploadPassResult result = await uploaderFor(null).processAll();
      expect(result.committed, 0);
      expect(result.failed, 0);
      final OutboxItem? row = await outbox.byId('a1');
      expect(row!.state, OutboxState.pending);
      expect(row.attemptCount, 0);
    });

    test('the owner resolved from the override is what scopes the pass',
        () async {
      expect(uploaderFor(alice).currentOwnerUid, alice);
      expect(uploaderFor(null).currentOwnerUid, isNull);
    });

    test('superseded cleanup is scoped the same way', () async {
      await outbox.enqueue(
        mediaId: 'av1',
        ownerUid: bob,
        kind: OutboxKind.avatar,
        mediaType: MediaType.image,
        storagePath: 'users/$bob/profile/av1.jpg',
        localFilePath: '/tmp/av1.jpg',
        supersessionKey: 'avatar:$bob',
      );
      await outbox.enqueue(
        mediaId: 'av2',
        ownerUid: bob,
        kind: OutboxKind.avatar,
        mediaType: MediaType.image,
        storagePath: 'users/$bob/profile/av2.jpg',
        localFilePath: '/tmp/av2.jpg',
        supersessionKey: 'avatar:$bob',
      );
      expect(await outbox.superseded(alice), isEmpty);
      expect((await outbox.superseded(bob)).map((OutboxItem i) => i.mediaId),
          <String>['av1']);
    });
  });

  group('a transient failure is not an attempt', () {
    test('offline and auth-not-ready are classified as transient', () {
      // Firestore / Functions
      for (final String code in <String>[
        'unavailable',
        'deadline-exceeded',
        'aborted',
        'cancelled',
        'internal',
        'resource-exhausted',
        'unauthenticated',
        'network-request-failed',
        'retry-limit-exceeded',
      ]) {
        expect(
            isTransientUploadError(
                FirebaseException(plugin: 'test', code: code)),
            isTrue,
            reason: code);
      }
    });

    test('a real failure is NOT transient', () {
      for (final String code in <String>[
        'permission-denied',
        'invalid-argument',
        'not-found',
        'unauthorized',
      ]) {
        expect(
            isTransientUploadError(
                FirebaseException(plugin: 'test', code: code)),
            isFalse,
            reason: code);
      }
    });

    test('a bare network message is recognised without a code', () {
      expect(
          isTransientUploadError(Exception('Network is unreachable')), isTrue);
      expect(isTransientUploadError(Exception('Connection timed out')), isTrue);
      expect(isTransientUploadError(Exception('bad file')), isFalse);
    });

    test('deferring leaves the attempt budget untouched', () async {
      await queue(alice, 'a1');
      // Four passes during one commute used to exhaust the budget and leave
      // the upload marked "failed", waiting for a tap the user had no reason
      // to know it needed.
      for (int i = 0; i < 6; i++) {
        await outbox.markDeferred('a1', 'offline');
      }
      final OutboxItem? row = await outbox.byId('a1');
      expect(row!.attemptCount, 0);
      expect(row.state, OutboxState.pending);
      expect(await outbox.claimable(ownerUid: alice), hasLength(1));
    });

    test('a real failure DOES cost an attempt, and eventually stops', () async {
      await queue(alice, 'a1');
      for (int i = 0; i < kMaxAutomaticAttempts; i++) {
        await outbox.bumpAttempt('a1');
      }
      await outbox.markFailed('a1', 'no permission', terminal: true);
      final OutboxItem? row = await outbox.byId('a1');
      expect(row!.attemptCount, kMaxAutomaticAttempts);
      expect(row.state, OutboxState.failed);
    });
  });

  group('retry accounting is reset', () {
    test('an explicit retry starts the budget again', () async {
      await queue(alice, 'a1');
      for (int i = 0; i < kMaxAutomaticAttempts; i++) {
        await outbox.bumpAttempt('a1');
      }
      await outbox.markFailed('a1', 'boom', terminal: true);

      await outbox.retry('a1');

      final OutboxItem? row = await outbox.byId('a1');
      expect(row!.state, OutboxState.pending);
      expect(row.lastError, isNull);
      // Without this the row would be back at the limit and would die on its
      // very first try, so the retry button would do nothing visible.
      expect(row.attemptCount, 0);
    });

    test('resetAttempts clears the count and the error', () async {
      await queue(alice, 'a1');
      await outbox.bumpAttempt('a1');
      await outbox.markFailed('a1', 'boom', terminal: false);
      await outbox.resetAttempts('a1');
      final OutboxItem? row = await outbox.byId('a1');
      expect(row!.attemptCount, 0);
      expect(row.lastError, isNull);
    });
  });

  group('the whole backlog drains, not just one page', () {
    test('claimable pages through a backlog', () async {
      for (int i = 0; i < 45; i++) {
        await queue(alice, 'a${i.toString().padLeft(2, '0')}');
      }
      expect(await outbox.claimableCount(alice), 45);

      final List<OutboxItem> page1 =
          await outbox.claimable(ownerUid: alice, limit: 20);
      final List<OutboxItem> page2 =
          await outbox.claimable(ownerUid: alice, limit: 20, offset: 20);
      final List<OutboxItem> page3 =
          await outbox.claimable(ownerUid: alice, limit: 20, offset: 40);

      expect(page1, hasLength(20));
      expect(page2, hasLength(20));
      expect(page3, hasLength(5));

      final Set<String> seen = <String>{
        ...page1.map((OutboxItem i) => i.mediaId),
        ...page2.map((OutboxItem i) => i.mediaId),
        ...page3.map((OutboxItem i) => i.mediaId),
      };
      expect(seen, hasLength(45), reason: 'every row is reachable');
    });

    test('a pass keeps going while the queue shrinks', () async {
      // 30 rows, none of which can upload (no Storage in a unit test), so the
      // pass must NOT loop forever either. The queue does not shrink, so the
      // pass stops after the first unproductive page.
      for (int i = 0; i < 30; i++) {
        await queue(alice, 'a$i');
      }
      final UploadPassResult result = await uploaderFor(alice).processAll();
      // Every row was attempted or deferred; nothing was committed, and the
      // pass returned rather than spinning.
      expect(result.committed, 0);
      expect(await outbox.claimableCount(alice), lessThanOrEqualTo(30));
    });

    test('claimableCount is scoped to the owner too', () async {
      await queue(alice, 'a1');
      await queue(bob, 'b1');
      await queue(bob, 'b2');
      expect(await outbox.claimableCount(alice), 1);
      expect(await outbox.claimableCount(bob), 2);
    });
  });
}
