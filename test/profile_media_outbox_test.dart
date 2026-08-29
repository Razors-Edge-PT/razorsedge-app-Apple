import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/data/media_outbox.dart';

/// The outbox's whole purpose is to survive process death, so most of these
/// cases open a REAL file-backed database, close it, and open it again — an
/// in-memory database could not tell the difference between "durable" and
/// "happened to still be in RAM".
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gl_outbox_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File dbFile() => File('${tmp.path}/outbox.sqlite');

  MediaOutbox openOnDisk() =>
      MediaOutbox(MediaOutboxDatabase(NativeDatabase(dbFile())));

  MediaOutbox openMemory() => MediaOutbox(MediaOutboxDatabase.memory());

  Future<OutboxItem> enqueuePost(MediaOutbox outbox, String id) =>
      outbox.enqueue(
        mediaId: id,
        ownerUid: 'u1',
        kind: OutboxKind.post,
        mediaType: 'image',
        storagePath: 'users/u1/posts/$id/original.jpg',
        localFilePath: '${tmp.path}/$id.jpg',
        caption: 'a caption',
      );

  Future<OutboxItem> enqueueAvatar(MediaOutbox outbox, String id) =>
      outbox.enqueue(
        mediaId: id,
        ownerUid: 'u1',
        kind: OutboxKind.avatar,
        mediaType: 'image',
        storagePath: 'users/u1/profile/$id.jpg',
        localFilePath: '${tmp.path}/$id.jpg',
        supersessionKey: 'avatar:u1',
      );

  group('durability', () {
    test('a queued upload survives closing and reopening the app', () async {
      final MediaOutbox first = openOnDisk();
      await enqueuePost(first, 'm1');
      await first.close();

      // Process death, cold start.
      final MediaOutbox second = openOnDisk();
      final List<OutboxItem> pending = await second.pendingFor('u1');
      expect(pending, hasLength(1));
      expect(pending.single.mediaId, 'm1');
      expect(pending.single.state, OutboxState.pending);
      expect(pending.single.caption, 'a caption');
      expect(pending.single.storagePath, 'users/u1/posts/m1/original.jpg');
      await second.close();
    });

    test('an in-flight upload comes back claimable, not lost', () async {
      final MediaOutbox first = openOnDisk();
      await enqueuePost(first, 'm1');
      // The app died mid-upload, so the row is still marked uploading.
      await first.markUploading('m1');
      await first.close();

      final MediaOutbox second = openOnDisk();
      final List<OutboxItem> claimable = await second.claimable();
      expect(claimable.map((OutboxItem i) => i.mediaId), <String>['m1']);
      await second.close();
    });

    test('the storage path is decided up front, so a retry is idempotent',
        () async {
      final MediaOutbox outbox = openMemory();
      final OutboxItem a = await enqueuePost(outbox, 'm1');
      await outbox.markUploading('m1');
      await outbox.markFailed('m1', 'network', terminal: false);
      final OutboxItem? b = await outbox.byId('m1');
      expect(b!.storagePath, a.storagePath,
          reason: 'a retry must re-upload to the SAME object, never a new one');
      await outbox.close();
    });
  });

  group('retry accounting', () {
    test('failures are recorded without losing the row', () async {
      final MediaOutbox outbox = openMemory();
      await enqueuePost(outbox, 'm1');
      await outbox.bumpAttempt('m1');
      await outbox.markFailed('m1', 'no network', terminal: false);

      OutboxItem? row = await outbox.byId('m1');
      expect(row!.attemptCount, 1);
      expect(row.lastError, 'no network');
      expect(row.state, OutboxState.pending, reason: 'a soft failure retries');

      await outbox.bumpAttempt('m1');
      await outbox.markFailed('m1', 'still no network', terminal: true);
      row = await outbox.byId('m1');
      expect(row!.state, OutboxState.failed);
      expect(row.attemptCount, 2);

      // The user taps retry.
      await outbox.retry('m1');
      row = await outbox.byId('m1');
      expect(row!.state, OutboxState.pending);
      expect(row.lastError, isNull);
      await outbox.close();
    });

    test('a failed item is still shown to its owner so it can be retried',
        () async {
      final MediaOutbox outbox = openMemory();
      await enqueuePost(outbox, 'm1');
      await outbox.markFailed('m1', 'boom', terminal: true);
      expect(await outbox.pendingFor('u1'), hasLength(1));
      await outbox.close();
    });

    test('the row is only removed once metadata is confirmed', () async {
      final MediaOutbox outbox = openMemory();
      await enqueuePost(outbox, 'm1');
      await outbox.remove('m1');
      expect(await outbox.byId('m1'), isNull);
      expect(await outbox.pendingFor('u1'), isEmpty);
      await outbox.close();
    });
  });

  group('supersession', () {
    test('a newer avatar supersedes every older pending one', () async {
      final MediaOutbox outbox = openMemory();
      final OutboxItem first = await enqueueAvatar(outbox, 'a1');
      final OutboxItem second = await enqueueAvatar(outbox, 'a2');

      expect(second.generation, greaterThan(first.generation));
      expect((await outbox.byId('a1'))!.state, OutboxState.superseded);
      expect((await outbox.byId('a2'))!.state, OutboxState.pending);
      await outbox.close();
    });

    test('a superseded upload can never commit, whatever order it finishes',
        () async {
      final MediaOutbox outbox = openMemory();
      final OutboxItem slow = await enqueueAvatar(outbox, 'a1');
      await enqueueAvatar(outbox, 'a2');

      // The slow 10:00 upload finally finishes AFTER the 10:01 one was chosen.
      expect(await outbox.isSuperseded(slow), isTrue);
      final OutboxItem newest = (await outbox.byId('a2'))!;
      expect(await outbox.isSuperseded(newest), isFalse);
      await outbox.close();
    });

    test('superseded rows are excluded from the queue but kept for cleanup',
        () async {
      final MediaOutbox outbox = openMemory();
      await enqueueAvatar(outbox, 'a1');
      await enqueueAvatar(outbox, 'a2');

      final List<OutboxItem> claimable = await outbox.claimable();
      expect(claimable.map((OutboxItem i) => i.mediaId), <String>['a2']);

      final List<OutboxItem> orphans = await outbox.superseded();
      expect(orphans.map((OutboxItem i) => i.mediaId), <String>['a1'],
          reason: 'the stale object still has to be cleaned up');
      await outbox.close();
    });

    test('supersession survives a restart', () async {
      final MediaOutbox first = openOnDisk();
      await enqueueAvatar(first, 'a1');
      await first.close();

      final MediaOutbox second = openOnDisk();
      await enqueueAvatar(second, 'a2');
      expect((await second.byId('a1'))!.state, OutboxState.superseded);
      final OutboxItem restored = (await second.byId('a2'))!;
      expect(restored.generation, 1,
          reason: 'generations must keep counting up across restarts');
      await second.close();
    });

    test('append-only media is never superseded by a later upload', () async {
      final MediaOutbox outbox = openMemory();
      final OutboxItem a = await enqueuePost(outbox, 'm1');
      await enqueuePost(outbox, 'm2');
      expect((await outbox.byId('m1'))!.state, OutboxState.pending);
      expect(await outbox.isSuperseded(a), isFalse);
      await outbox.close();
    });
  });

  group('proof linkage', () {
    test('a proof upload carries the record fingerprint it belongs to',
        () async {
      final MediaOutbox outbox = openMemory();
      await outbox.enqueue(
        mediaId: 'p1',
        ownerUid: 'u1',
        kind: OutboxKind.proof,
        mediaType: 'video',
        storagePath: 'users/u1/posts/p1/original.mp4',
        localFilePath: '${tmp.path}/p1.mp4',
        achievementFingerprint: 'fp-abc',
        achievementSlot: 'bench',
      );
      final OutboxItem row = (await outbox.byId('p1'))!;
      expect(row.achievementFingerprint, 'fp-abc');
      expect(row.achievementSlot, 'bench');
      expect(row.kind, OutboxKind.proof);
      await outbox.close();
    });
  });

  group('ownership', () {
    test('one account never sees another account pending uploads', () async {
      final MediaOutbox outbox = openMemory();
      await enqueuePost(outbox, 'm1');
      await outbox.enqueue(
        mediaId: 'other',
        ownerUid: 'u2',
        kind: OutboxKind.post,
        mediaType: 'image',
        storagePath: 'users/u2/posts/other/original.jpg',
        localFilePath: '${tmp.path}/other.jpg',
      );
      expect((await outbox.pendingFor('u1')).map((OutboxItem i) => i.mediaId),
          <String>['m1']);
      expect((await outbox.pendingFor('u2')).map((OutboxItem i) => i.mediaId),
          <String>['other']);
      await outbox.close();
    });
  });
}
