import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/wes2_video/set_video_store.dart';

/// Suppression — the bridge that stops a removal made on the PROFILE from
/// being undone by the next WES2 reconciliation pass.
///
/// Without it, detaching or deleting a PB video on the profile would leave the
/// clip local, still a live personal best, and the very next pass would queue
/// it again. That is the resurrection the user explicitly asked not to happen.

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

  Future<SetVideoRecord> published({
    String ownerUid = _uid,
    String setId = 'sid-1',
    String fingerprint = 'fp-1',
    String postId = 'post-1',
    String mediaId = 'media-1',
  }) async {
    final SetVideoRecord r = await store.put(
      ownerUid: ownerUid,
      dateKey: _dateKey,
      exerciseId: 'ex1',
      setId: setId,
      localVideoPath: '/clips/$setId.mp4',
    );
    await store.markQueued(
      id: r.id,
      mediaId: mediaId,
      fingerprint: fingerprint,
      liftSlot: 'bench',
      generation: r.generation,
    );
    await store.markPublished(
        id: r.id, postId: postId, generation: r.generation);
    return (await store.byId(r.id))!;
  }

  group('suppressing by fingerprint', () {
    test('detaching a proof suppresses the local record', () async {
      final SetVideoRecord r = await published();
      expect(r.suppressed, isFalse);

      final int n = await store.suppressByFingerprint(
          ownerUid: _uid, fingerprint: 'fp-1');

      expect(n, 1);
      expect((await store.byId(r.id))!.suppressed, isTrue);
    });

    test('a suppressed record is no longer a publish candidate', () async {
      final SetVideoRecord r = await published();
      await store.markLocalOnly(r.id);
      expect(await store.publishCandidates(_uid), hasLength(1));

      await store.suppressByFingerprint(ownerUid: _uid, fingerprint: 'fp-1');

      expect(await store.publishCandidates(_uid), isEmpty,
          reason: 'reconciliation must not resurrect an explicit removal');
    });

    test('it is idempotent', () async {
      await published();
      await store.suppressByFingerprint(ownerUid: _uid, fingerprint: 'fp-1');
      final int second = await store.suppressByFingerprint(
          ownerUid: _uid, fingerprint: 'fp-1');
      expect(second, 1, reason: 'writing the same value again is harmless');
    });

    test('a blank fingerprint suppresses nothing', () async {
      await published();
      expect(
          await store.suppressByFingerprint(ownerUid: _uid, fingerprint: '   '),
          0);
      expect((await store.allFor(_uid)).single.suppressed, isFalse);
    });

    test("it never touches another account's footage", () async {
      final SetVideoRecord mine = await published(ownerUid: _uid);
      final SetVideoRecord theirs =
          await published(ownerUid: _other, setId: 'sid-9');

      await store.suppressByFingerprint(ownerUid: _uid, fingerprint: 'fp-1');

      expect((await store.byId(mine.id))!.suppressed, isTrue);
      expect((await store.byId(theirs.id))!.suppressed, isFalse);
    });

    test('an unrelated fingerprint is left alone', () async {
      final SetVideoRecord r = await published(fingerprint: 'fp-1');
      await store.suppressByFingerprint(
          ownerUid: _uid, fingerprint: 'fp-other');
      expect((await store.byId(r.id))!.suppressed, isFalse);
    });
  });

  group('suppressing by post', () {
    test('deleting the media suppresses the local record', () async {
      final SetVideoRecord r = await published(postId: 'post-7');
      final int n =
          await store.suppressByPostId(ownerUid: _uid, postId: 'post-7');

      expect(n, 1);
      expect((await store.byId(r.id))!.suppressed, isTrue);
    });

    test('a blank post id suppresses nothing', () async {
      await published();
      expect(await store.suppressByPostId(ownerUid: _uid, postId: ''), 0);
    });
  });

  group('suppressing by media id', () {
    test('a deletion before the post exists still suppresses', () async {
      final SetVideoRecord r = await published(mediaId: 'media-42');
      final int n =
          await store.suppressByMediaId(ownerUid: _uid, mediaId: 'media-42');

      expect(n, 1);
      expect((await store.byId(r.id))!.suppressed, isTrue);
    });
  });

  group('only a deliberate new recording clears suppression', () {
    test('replacing the clip lifts suppression', () async {
      final SetVideoRecord r = await published();
      await store.suppressByFingerprint(ownerUid: _uid, fingerprint: 'fp-1');
      expect((await store.byId(r.id))!.suppressed, isTrue);

      final SetVideoRecord replaced = await store.put(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: 'ex1',
        setId: 'sid-1',
        localVideoPath: '/clips/new.mp4',
      );

      expect(replaced.suppressed, isFalse,
          reason: 'new footage is a fresh candidate on its own merits');
      expect(await store.publishCandidates(_uid), hasLength(1));
    });

    test('undoing a delete lifts suppression', () async {
      final SetVideoRecord r = await published();
      await store.softDelete(r.id);
      expect((await store.byId(r.id))!.suppressed, isTrue);

      await store.undoDelete(r.id);
      expect((await store.byId(r.id))!.suppressed, isFalse);
    });

    test('merely reconciling does not lift it', () async {
      final SetVideoRecord r = await published();
      await store.markLocalOnly(r.id);
      await store.suppressByFingerprint(ownerUid: _uid, fingerprint: 'fp-1');

      // Several passes later, still suppressed.
      expect(await store.publishCandidates(_uid), isEmpty);
      expect(await store.publishCandidates(_uid), isEmpty);
      expect((await store.byId(r.id))!.suppressed, isTrue);
    });
  });
}
