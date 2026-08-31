import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/wes2_video/set_video_files.dart';
import 'package:localtest222/wes2_video/set_video_pipeline.dart';
import 'package:localtest222/wes2_video/set_video_store.dart';
import 'package:path/path.dart' as p;

/// The record → trim → keep pipeline.
///
/// What matters here is ORDER. Every device boundary is faked, so these assert
/// the sequence that makes the flow loss-safe: adopt, then commit, then delete
/// — never delete first.

const String _uid = 'owner-1';
const String _dateKey = '2026-08-31';

/// Records what it was asked to do, and can be told to fail.
class _FakeTrimmer implements SetVideoTrimEngine {
  _FakeTrimmer(this.root);

  final Directory root;
  bool fail = false;
  bool returnMissingFile = false;
  int clearCacheCalls = 0;
  TrimSelection? lastSelection;
  bool? lastIncludeAudio;

  @override
  Future<File?> trim({
    required File source,
    required TrimSelection selection,
    bool includeAudio = true,
  }) async {
    lastSelection = selection;
    lastIncludeAudio = includeAudio;
    if (fail) return null;
    // The real engines always write a genuine .mp4 export.
    final File out =
        File(p.join(root.path, 'trimmed_${selection.startMs}.mp4'));
    if (!returnMissingFile) {
      out.writeAsStringSync('trimmed-bytes');
    }
    return out;
  }

  @override
  Future<void> clearCache() async => clearCacheCalls++;
}

class _FakePosters implements SetVideoPosterEngine {
  bool fail = false;

  @override
  Future<File?> poster({required File video, required File target}) async {
    if (fail) return null;
    target.writeAsStringSync('poster-bytes');
    return target;
  }
}

void main() {
  late Directory root;
  late SetVideoDatabase db;
  late SetVideoStore store;
  late AppSupportSetVideoFiles files;
  late _FakeTrimmer trimmer;
  late _FakePosters posters;
  late SetVideoPipeline pipeline;

  setUp(() {
    root = Directory.systemTemp.createTempSync('gl_pipeline_test');
    db = SetVideoDatabase.memory();
    store = SetVideoStore(db);
    files = AppSupportSetVideoFiles(supportDirectory: () async => root);
    trimmer = _FakeTrimmer(root);
    posters = _FakePosters();
    pipeline = SetVideoPipeline(
      store: store,
      files: files,
      trimmer: trimmer,
      posters: posters,
    );
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  RawCapture capture({String name = 'raw.mp4'}) {
    final File f = File(p.join(root.path, name));
    f.writeAsStringSync('raw-camera-bytes');
    return RawCapture(file: f, durationMs: 30000);
  }

  Future<SetVideoRecord> keep({
    RawCapture? raw,
    TrimSelection selection = const TrimSelection(startMs: 4000, endMs: 12000),
    String setId = 'sid-1',
    String? slot,
    bool includeAudio = true,
  }) =>
      pipeline.keepTrimmed(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: 'ex1',
        setId: setId,
        setIndex: 0,
        raw: raw ?? capture(),
        selection: selection,
        liftSlot: slot,
        includeAudio: includeAudio,
      );

  group('only the trimmed clip is kept', () {
    test('the raw recording is deleted after a successful save', () async {
      final RawCapture raw = capture();
      await keep(raw: raw);
      expect(raw.file.existsSync(), isFalse,
          reason: 'setup footage is the whole thing trimming exists to drop');
    });

    test('the saved clip is the trimmed one, in durable storage', () async {
      final SetVideoRecord r = await keep();
      expect(File(r.localVideoPath).existsSync(), isTrue);
      expect(File(r.localVideoPath).readAsStringSync(), 'trimmed-bytes');
      expect(r.localVideoPath, contains('set_videos'));
    });

    test('the recorded duration is the trimmed duration, not the raw one',
        () async {
      final SetVideoRecord r = await keep(
        raw: capture(),
        selection: const TrimSelection(startMs: 4000, endMs: 12000),
      );
      expect(r.durationMs, 8000);
    });

    test('the trim selection is passed through verbatim', () async {
      await keep(selection: const TrimSelection(startMs: 1500, endMs: 9000));
      expect(trimmer.lastSelection!.startMs, 1500);
      expect(trimmer.lastSelection!.endMs, 9000);
    });

    test('audio is recorded by default and can be dropped', () async {
      await keep();
      expect(trimmer.lastIncludeAudio, isTrue);
      await keep(setId: 'sid-2', includeAudio: false);
      expect(trimmer.lastIncludeAudio, isFalse);
    });

    test('scratch files are cleared on success', () async {
      await keep();
      expect(trimmer.clearCacheCalls, 1);
    });
  });

  group('failure leaves nothing behind and loses nothing', () {
    test('a failed trim saves no record and cleans up the raw file', () async {
      trimmer.fail = true;
      final RawCapture raw = capture();

      await expectLater(() => keep(raw: raw), throwsA(isA<SetVideoFailure>()));

      expect(raw.file.existsSync(), isFalse);
      expect(await store.allFor(_uid), isEmpty);
      expect(trimmer.clearCacheCalls, 1);
    });

    test('an engine returning a missing file is treated as a failure',
        () async {
      trimmer.returnMissingFile = true;
      await expectLater(() => keep(), throwsA(isA<SetVideoFailure>()));
      expect(await store.allFor(_uid), isEmpty);
    });

    test('a failed trim does not disturb the clip already attached', () async {
      final SetVideoRecord first = await keep();
      final String keptPath = first.localVideoPath;

      trimmer.fail = true;
      await expectLater(
        () => keep(raw: capture(name: 'raw2.mp4')),
        throwsA(isA<SetVideoFailure>()),
      );

      final SetVideoRecord? after = await store.byId(first.id);
      expect(after!.localVideoPath, keptPath);
      expect(File(keptPath).existsSync(), isTrue,
          reason: 'the previous video must survive a failed replacement');
      expect(File(keptPath).readAsStringSync(), 'trimmed-bytes');
    });

    test('too short a selection is refused before any work is done', () async {
      final RawCapture raw = capture();
      await expectLater(
        () => keep(
            raw: raw, selection: const TrimSelection(startMs: 0, endMs: 500)),
        throwsA(isA<SetVideoFailure>()),
      );
      expect(raw.file.existsSync(), isFalse);
      expect(await store.allFor(_uid), isEmpty);
    });

    test('a poster failure does not cost the user the clip', () async {
      posters.fail = true;
      final SetVideoRecord r = await keep();
      expect(File(r.localVideoPath).existsSync(), isTrue);
      expect(r.localPosterPath, isNull);
    });
  });

  group('replacement deletes the old file only after committing', () {
    test('the old file is gone and the new one is live', () async {
      final SetVideoRecord first = await keep();
      final String oldPath = first.localVideoPath;

      final SetVideoRecord second = await keep(
          raw: capture(name: 'raw2.mp4'),
          selection: const TrimSelection(startMs: 0, endMs: 5000));

      expect(second.localVideoPath, isNot(oldPath));
      expect(File(second.localVideoPath).existsSync(), isTrue);
      expect(File(oldPath).existsSync(), isFalse,
          reason: 'the superseded file is removed last, but it is removed');
    });

    test('the superseded bookkeeping is cleared after cleanup', () async {
      await keep();
      final SetVideoRecord second = await keep(raw: capture(name: 'raw2.mp4'));
      final SetVideoRecord? row = await store.byId(second.id);
      expect(row!.supersededVideoPath, isNull);
      expect(row.supersededPosterPath, isNull);
    });

    test('a replacement bumps the generation', () async {
      expect((await keep()).generation, 0);
      expect((await keep(raw: capture(name: 'r2.mp4'))).generation, 1);
    });

    test('only one record exists for a set however often it is replaced',
        () async {
      await keep();
      await keep(raw: capture(name: 'r2.mp4'));
      await keep(raw: capture(name: 'r3.mp4'));
      expect((await store.allFor(_uid)).length, 1);
    });
  });

  group('cancellation', () {
    test('discarding removes the raw recording', () async {
      final RawCapture raw = capture();
      await pipeline.discard(raw);
      expect(raw.file.existsSync(), isFalse);
      expect(await store.allFor(_uid), isEmpty);
    });

    test('discarding twice is harmless', () async {
      final RawCapture raw = capture();
      await pipeline.discard(raw);
      await pipeline.discard(raw);
      expect(raw.file.existsSync(), isFalse);
    });
  });

  group('deletion lifecycle', () {
    test('a soft delete keeps the files until the window closes', () async {
      final SetVideoRecord r = await keep();
      await pipeline.deleteForSet(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: 'ex1',
        setId: 'sid-1',
      );

      expect(File(r.localVideoPath).existsSync(), isTrue);
      expect(await store.forDay(ownerUid: _uid, dateKey: _dateKey), isEmpty);
    });

    test('finalising after the window removes the files and the row', () async {
      final SetVideoRecord r = await keep();
      await pipeline.deleteForSet(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: 'ex1',
        setId: 'sid-1',
      );

      final int finalised =
          await pipeline.finalizeExpiredDeletions(undoWindow: Duration.zero);

      expect(finalised, 1);
      expect(File(r.localVideoPath).existsSync(), isFalse);
      expect(await store.byId(r.id), isNull);
    });

    test('finalising is idempotent', () async {
      await keep();
      await pipeline.deleteForSet(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: 'ex1',
        setId: 'sid-1',
      );
      expect(await pipeline.finalizeExpiredDeletions(undoWindow: Duration.zero),
          1);
      expect(await pipeline.finalizeExpiredDeletions(undoWindow: Duration.zero),
          0);
    });

    test('deleting a set with no footage is a no-op', () async {
      await pipeline.deleteForSet(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: 'ex1',
        setId: 'never-filmed',
      );
      expect(await store.allFor(_uid), isEmpty);
    });

    test('an undoable delete can be reversed with the files intact', () async {
      final SetVideoRecord r = await keep();
      await pipeline.deleteForSet(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: 'ex1',
        setId: 'sid-1',
      );
      await store.undoDelete(r.id);

      expect(File(r.localVideoPath).existsSync(), isTrue);
      expect((await store.forDay(ownerUid: _uid, dateKey: _dateKey)).length, 1);
    });
  });

  group('startup housekeeping', () {
    test('abandoned raw captures are swept', () async {
      final Directory tmp = await files.tempDir(_uid);
      File(p.join(tmp.path, 'killed_mid_capture.mp4')).writeAsStringSync('raw');

      expect(await pipeline.sweepTemporary(_uid), 1);
      expect(File(p.join(tmp.path, 'killed_mid_capture.mp4')).existsSync(),
          isFalse);
    });

    test('a saved clip survives the sweep', () async {
      final SetVideoRecord r = await keep();
      await pipeline.sweepTemporary(_uid);
      expect(File(r.localVideoPath).existsSync(), isTrue);
    });
  });

  group('reopening a workout offline', () {
    test('footage is found again by date with no network involved', () async {
      await keep(setId: 'sid-1');
      await keep(setId: 'sid-2', raw: capture(name: 'r2.mp4'));

      final List<SetVideoRecord> day =
          await store.forDay(ownerUid: _uid, dateKey: _dateKey);
      expect(day.length, 2);
      for (final SetVideoRecord r in day) {
        expect(File(r.localVideoPath).existsSync(), isTrue);
      }
    });
  });
}
