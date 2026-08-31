import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/wes2_video/set_video_files.dart';
import 'package:localtest222/wes2_video/set_video_store.dart';
import 'package:path/path.dart' as p;

/// The durable local record of set footage, and the on-disk lifetime of the
/// files behind it.
///
/// The properties that matter here are loss-safety and identity: a replacement
/// must never unlink the old clip before the new one is committed, deletion
/// must be idempotent, and nothing may be keyed on a set INDEX, which is
/// renumbered whenever a set is removed.

const String _uid = 'owner-1';
const String _other = 'owner-2';
const String _dateKey = '2026-08-31';

void main() {
  late SetVideoDatabase db;
  late SetVideoStore store;

  setUp(() {
    db = SetVideoDatabase.memory();
    store = SetVideoStore(db);
  });

  tearDown(() => db.close());

  Future<SetVideoRecord> put({
    String ownerUid = _uid,
    String exerciseId = 'ex1',
    String setId = 'sid-1',
    String path = '/clips/a.mp4',
    String? poster = '/clips/a.jpg',
    int setIndex = 0,
    String? slot,
  }) =>
      store.put(
        ownerUid: ownerUid,
        dateKey: _dateKey,
        exerciseId: exerciseId,
        setId: setId,
        localVideoPath: path,
        localPosterPath: poster,
        setIndex: setIndex,
        liftSlot: slot,
        durationMs: 4200,
        sizeBytes: 1024,
      );

  group('identity and association', () {
    test('a record is found by stable set id, not by index', () async {
      await put(setIndex: 2);
      // The set is renumbered by a removal elsewhere in the row.
      final SetVideoRecord? found = await store.forSet(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: 'ex1',
        setId: 'sid-1',
      );
      expect(found, isNotNull);
      expect(found!.localVideoPath, '/clips/a.mp4');
    });

    test('the id is deterministic, so re-attaching updates one row', () async {
      await put(path: '/clips/a.mp4');
      await put(path: '/clips/b.mp4');
      expect((await store.allFor(_uid)).length, 1);
    });

    test('refreshing the display index never moves the record', () async {
      final SetVideoRecord r = await put(setIndex: 2);
      await store.touchSetIndex(r.id, 0);
      final SetVideoRecord? found = await store.byId(r.id);
      expect(found!.setIndex, 0);
      expect(found.setId, 'sid-1');
      expect(found.localVideoPath, '/clips/a.mp4');
    });

    test('two sets of the same exercise keep separate footage', () async {
      await put(setId: 'sid-1', path: '/clips/one.mp4');
      await put(setId: 'sid-2', path: '/clips/two.mp4');
      final List<SetVideoRecord> day =
          await store.forDay(ownerUid: _uid, dateKey: _dateKey);
      expect(day.length, 2);
      expect(day.map((r) => r.localVideoPath),
          containsAll(<String>['/clips/one.mp4', '/clips/two.mp4']));
    });
  });

  group('account isolation', () {
    test("a day query never returns another account's footage", () async {
      await put(ownerUid: _uid, path: '/clips/mine.mp4');
      await put(ownerUid: _other, setId: 'sid-9', path: '/clips/theirs.mp4');

      final List<SetVideoRecord> mine =
          await store.forDay(ownerUid: _uid, dateKey: _dateKey);
      expect(mine.single.localVideoPath, '/clips/mine.mp4');
    });

    test('publish candidates are scoped to one owner', () async {
      await put(ownerUid: _uid);
      await put(ownerUid: _other, setId: 'sid-9');
      expect((await store.publishCandidates(_uid)).length, 1);
    });

    test('the same set id under two owners is two records', () async {
      await put(ownerUid: _uid, setId: 'same');
      await put(ownerUid: _other, setId: 'same');
      expect((await store.allFor(_uid)).length, 1);
      expect((await store.allFor(_other)).length, 1);
    });
  });

  group('replacement is loss-safe', () {
    test('the superseded file is reported, not deleted', () async {
      await put(path: '/clips/old.mp4', poster: '/clips/old.jpg');
      final SetVideoRecord r =
          await put(path: '/clips/new.mp4', poster: '/clips/new.jpg');

      expect(r.localVideoPath, '/clips/new.mp4');
      expect(r.supersededVideoPath, '/clips/old.mp4',
          reason: 'the caller unlinks the old file only after this commits');
      expect(r.supersededPosterPath, '/clips/old.jpg');
    });

    test('re-saving the same path does not schedule its own deletion',
        () async {
      await put(path: '/clips/a.mp4');
      final SetVideoRecord r = await put(path: '/clips/a.mp4');
      expect(r.supersededVideoPath, isNull);
    });

    test('generation increases on every replacement', () async {
      expect((await put(path: '/clips/a.mp4')).generation, 0);
      expect((await put(path: '/clips/b.mp4')).generation, 1);
      expect((await put(path: '/clips/c.mp4')).generation, 2);
    });

    test('clearing superseded paths is separate from committing', () async {
      await put(path: '/clips/old.mp4');
      final SetVideoRecord r = await put(path: '/clips/new.mp4');
      await store.clearSuperseded(r.id);
      final SetVideoRecord? after = await store.byId(r.id);
      expect(after!.supersededVideoPath, isNull);
      expect(after.localVideoPath, '/clips/new.mp4');
    });

    test('a replacement resets publication state and clears suppression',
        () async {
      final SetVideoRecord first = await put(path: '/clips/a.mp4');
      await store.markQueued(
        id: first.id,
        mediaId: 'm1',
        fingerprint: 'fp1',
        liftSlot: 'bench',
        generation: first.generation,
      );
      await store.markPublished(
          id: first.id, postId: 'post1', generation: first.generation);
      await store.softDelete(first.id);

      final SetVideoRecord replaced = await put(path: '/clips/b.mp4');
      expect(replaced.state, SetVideoState.local);
      expect(replaced.suppressed, isFalse);
      expect(replaced.postId, isNull);
      expect(replaced.mediaId, isNull);
      expect(replaced.fingerprint, isNull);
      expect(replaced.deletedAtMs, isNull);
    });

    test('createdAt is preserved across a replacement', () async {
      final SetVideoRecord first = await put(path: '/clips/a.mp4');
      final SetVideoRecord second = await put(path: '/clips/b.mp4');
      expect(second.createdAtMs, first.createdAtMs);
    });
  });

  group('out-of-order completion cannot restore an older video', () {
    test('a stale generation cannot mark queued', () async {
      final SetVideoRecord first = await put(path: '/clips/a.mp4');
      await put(path: '/clips/b.mp4'); // user replaces while upload in flight

      final bool accepted = await store.markQueued(
        id: first.id,
        mediaId: 'm-old',
        fingerprint: 'fp-old',
        liftSlot: 'bench',
        generation: first.generation,
      );
      expect(accepted, isFalse);
      expect((await store.byId(first.id))!.mediaId, isNull);
    });

    test('a stale generation cannot mark published', () async {
      final SetVideoRecord first = await put(path: '/clips/a.mp4');
      await put(path: '/clips/b.mp4');

      final bool accepted = await store.markPublished(
          id: first.id, postId: 'stale-post', generation: first.generation);
      expect(accepted, isFalse);
      expect((await store.byId(first.id))!.postId, isNull);
    });

    test('the current generation is accepted', () async {
      final SetVideoRecord r = await put(path: '/clips/a.mp4');
      expect(
        await store.markQueued(
          id: r.id,
          mediaId: 'm1',
          fingerprint: 'fp1',
          liftSlot: 'bench',
          generation: r.generation,
        ),
        isTrue,
      );
    });
  });

  group('deletion and suppression', () {
    test('a soft delete hides the record but keeps the files', () async {
      final SetVideoRecord r = await put();
      await store.softDelete(r.id);

      expect(await store.forDay(ownerUid: _uid, dateKey: _dateKey), isEmpty);
      final SetVideoRecord? row = await store.byId(r.id);
      expect(row!.localVideoPath, '/clips/a.mp4',
          reason: 'files survive until the undo window closes');
      expect(row.deletedAtMs, isNotNull);
    });

    test('an explicit delete suppresses automatic resurrection', () async {
      final SetVideoRecord r = await put();
      await store.softDelete(r.id);
      expect((await store.byId(r.id))!.suppressed, isTrue);
      expect(await store.publishCandidates(_uid), isEmpty);
    });

    test('undo restores the record and clears suppression', () async {
      final SetVideoRecord r = await put();
      await store.softDelete(r.id);
      await store.undoDelete(r.id);

      final SetVideoRecord? row = await store.byId(r.id);
      expect(row!.state, SetVideoState.local);
      expect(row.deletedAtMs, isNull);
      expect(row.suppressed, isFalse);
      expect((await store.forDay(ownerUid: _uid, dateKey: _dateKey)).length, 1);
    });

    test('detach keeps the footage but stops re-attachment', () async {
      final SetVideoRecord r = await put(slot: 'bench');
      await store.markQueued(
        id: r.id,
        mediaId: 'm1',
        fingerprint: 'fp1',
        liftSlot: 'bench',
        generation: r.generation,
      );
      await store.detach(r.id);

      final SetVideoRecord? row = await store.byId(r.id);
      expect(row!.fingerprint, isNull);
      expect(row.liftSlot, isNull);
      expect(row.suppressed, isTrue);
      expect(row.deletedAtMs, isNull, reason: 'detach is not deletion');
      expect((await store.forDay(ownerUid: _uid, dateKey: _dateKey)).length, 1);
    });

    test('purge is idempotent', () async {
      final SetVideoRecord r = await put();
      await store.purge(r.id);
      await store.purge(r.id);
      await store.purge('never-existed');
      expect(await store.byId(r.id), isNull);
    });

    test('only elapsed soft deletes become finalizable', () async {
      final SetVideoRecord r = await put();
      await store.softDelete(r.id);

      expect(
        await store.finalizable(
          ownerUid: _uid,
          before: DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        isEmpty,
      );
      expect(
        (await store.finalizable(
          ownerUid: _uid,
          before: DateTime.now().add(const Duration(minutes: 1)),
        ))
            .length,
        1,
      );
    });

    test('finalisation is scoped to one owner', () async {
      final SetVideoRecord mine = await put(ownerUid: _uid);
      final SetVideoRecord theirs = await put(ownerUid: _other, setId: 'sid-9');
      await store.softDelete(mine.id);
      await store.softDelete(theirs.id);

      final List<SetVideoRecord> due = await store.finalizable(
        ownerUid: _uid,
        before: DateTime.now().add(const Duration(minutes: 1)),
      );

      expect(due.map((r) => r.id), <String>[mine.id],
          reason: "one account's pass must never unlink another account's "
              'files on a shared device');
    });
  });

  group('publish candidates', () {
    test('a queued or published record is not a candidate again', () async {
      final SetVideoRecord r = await put();
      await store.markQueued(
        id: r.id,
        mediaId: 'm1',
        fingerprint: 'fp1',
        liftSlot: 'bench',
        generation: r.generation,
      );
      expect(await store.publishCandidates(_uid), isEmpty);

      await store.markPublished(
          id: r.id, postId: 'p1', generation: r.generation);
      expect(await store.publishCandidates(_uid), isEmpty);
    });

    test('returning to local-only makes it a candidate again', () async {
      final SetVideoRecord r = await put();
      await store.markQueued(
        id: r.id,
        mediaId: 'm1',
        fingerprint: 'fp1',
        liftSlot: 'bench',
        generation: r.generation,
      );
      await store.markLocalOnly(r.id);

      final List<SetVideoRecord> c = await store.publishCandidates(_uid);
      expect(c.length, 1);
      expect(c.single.mediaId, isNull);
    });
  });

  group('durable files', () {
    late Directory root;
    late AppSupportSetVideoFiles files;

    setUp(() {
      root = Directory.systemTemp.createTempSync('gl_setvideo_test');
      files = AppSupportSetVideoFiles(supportDirectory: () async => root);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File source(String name, {String bytes = 'video-bytes'}) {
      final File f = File(p.join(root.path, name));
      f.writeAsStringSync(bytes);
      return f;
    }

    test('a clip lands in durable storage, not a cache directory', () async {
      final File out = await files.adopt(
        ownerUid: _uid,
        recordId: 'rec-1',
        generation: 0,
        source: source('raw.mp4'),
      );
      expect(out.existsSync(), isTrue);
      expect(out.path, contains('set_videos'));
      expect(out.path, isNot(contains('tmp')));
      expect(out.readAsStringSync(), 'video-bytes');
    });

    test('a MOV keeps its real container rather than being renamed', () async {
      final File out = await files.adopt(
        ownerUid: _uid,
        recordId: 'rec-1',
        generation: 0,
        source: source('raw.MOV'),
      );
      expect(p.extension(out.path).toLowerCase(), '.mov',
          reason: 'renaming a MOV to .mp4 transcodes nothing and lies');
    });

    test('no .part file survives a successful adopt', () async {
      await files.adopt(
        ownerUid: _uid,
        recordId: 'rec-1',
        generation: 0,
        source: source('raw.mp4'),
      );
      final Directory dir = await files.videoDir(_uid);
      expect(dir.listSync().where((e) => e.path.endsWith('.part')), isEmpty);
    });

    test('a replacement does not overwrite the file it replaces', () async {
      final File first = await files.adopt(
        ownerUid: _uid,
        recordId: 'rec-1',
        generation: 0,
        source: source('a.mp4', bytes: 'first'),
      );
      final File second = await files.adopt(
        ownerUid: _uid,
        recordId: 'rec-1',
        generation: 1,
        source: source('b.mp4', bytes: 'second'),
      );

      expect(first.path, isNot(second.path));
      expect(first.existsSync(), isTrue,
          reason: 'the old clip stays readable until explicitly deleted');
      expect(first.readAsStringSync(), 'first');
      expect(second.readAsStringSync(), 'second');
    });

    test('deleteQuietly is idempotent and tolerates absence', () async {
      final File f = source('gone.mp4');
      await files.deleteQuietly(f.path);
      await files.deleteQuietly(f.path);
      await files.deleteQuietly(null);
      await files.deleteQuietly('   ');
      expect(f.existsSync(), isFalse);
    });

    test('sweeping removes raw captures and part files, keeping clips',
        () async {
      final File clip = await files.adopt(
        ownerUid: _uid,
        recordId: 'rec-1',
        generation: 0,
        source: source('raw.mp4'),
      );
      final Directory tmp = await files.tempDir(_uid);
      File(p.join(tmp.path, 'abandoned.mp4')).writeAsStringSync('raw');
      final Directory clips = await files.videoDir(_uid);
      File(p.join(clips.path, 'half.mp4.part')).writeAsStringSync('partial');

      final int removed = await files.sweepTemp(_uid);

      expect(removed, 2);
      expect(clip.existsSync(), isTrue,
          reason: 'a finished clip is not temporary');
      expect(File(p.join(tmp.path, 'abandoned.mp4')).existsSync(), isFalse);
      expect(File(p.join(clips.path, 'half.mp4.part')).existsSync(), isFalse);
    });

    test('owners get separate subtrees', () async {
      final Directory a = await files.videoDir(_uid);
      final Directory b = await files.videoDir(_other);
      expect(a.path, isNot(b.path));
    });

    test('usage counts finished clips only', () async {
      await files.adopt(
        ownerUid: _uid,
        recordId: 'rec-1',
        generation: 0,
        source: source('raw.mp4', bytes: '12345'),
      );
      final Directory clips = await files.videoDir(_uid);
      File(p.join(clips.path, 'half.mp4.part')).writeAsStringSync('9999999');

      expect(await files.usageBytes(_uid), 5);
    });
  });
}
