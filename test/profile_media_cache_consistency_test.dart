/// Keeping the disk sweep and the cache manager's own records consistent.
///
/// [ProfileMediaCacheSweeper] reclaims bytes by deleting FILES from the store's
/// directory. The cache manager's index lives somewhere else entirely — its
/// database is written under `getApplicationSupportDirectory()`, while the
/// files it describes live under `getTemporaryDirectory()/<cacheKey>` — so a
/// sweep can never damage the index, but it can certainly outlive it: a record
/// stays valid for the store's stale period whether or not its bytes are still
/// there.
///
/// That matters because `CacheManager.getSingleFile` returns the recorded file
/// whenever the record is inside `validTill` and does NOT check that the file
/// exists. Left alone, a swept entry would be handed back as a path to nothing
/// and the image would fail instead of being re-fetched. These tests pin the
/// recovery: a record that outlived its bytes is forgotten, and the fetch is
/// real.
library;

import 'dart:async';
import 'dart:io';

import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/data/media_cache_sweeper.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';

/// A cache manager whose index and bytes the test can desynchronise on purpose.
///
/// Only the four members [CacheManagerImageStore] uses are implemented;
/// everything else on the very wide [BaseCacheManager] surface would be noise.
class _FakeManager implements BaseCacheManager {
  _FakeManager(this.dir);

  final Directory dir;

  /// key -> the file the INDEX believes is on disk. Deliberately allowed to
  /// disagree with reality, which is exactly what a sweep produces.
  final Map<String, fs.File> records = <String, fs.File>{};

  final List<String> singleFileCalls = <String>[];
  final List<String> removed = <String>[];

  /// Keys whose next getSingleFile should actually write bytes.
  final Set<String> downloadable = <String>{};

  /// Set to make removeFile throw, modelling an unavailable index.
  bool removeThrows = false;

  /// package:file's File, which is what BaseCacheManager deals in. It implements
  /// dart:io's File, which is why the store can hand it straight to callers.
  fs.File _fileFor(String key) => const LocalFileSystem()
      .file('${dir.path}/${key.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}.bin');

  fs.File writeBytes(String key, {int bytes = 64}) {
    final fs.File f = _fileFor(key)..createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 1));
    records[key] = f;
    return f;
  }

  @override
  Future<FileInfo?> getFileFromCache(String key,
      {bool ignoreMemCache = false}) async {
    final fs.File? f = records[key];
    if (f == null) return null;
    // Exactly what the real store does: it hands back the record without ever
    // asking the filesystem whether the file is still there.
    return FileInfo(
      f,
      FileSource.Cache,
      DateTime.now().add(const Duration(days: 30)),
      'https://example.invalid/$key',
    );
  }

  @override
  Future<fs.File> getSingleFile(String url,
      {String? key, Map<String, String>? headers}) async {
    final String id = key ?? url;
    singleFileCalls.add(id);
    final fs.File? recorded = records[id];
    if (recorded != null) return recorded;
    if (downloadable.contains(id)) return writeBytes(id);
    throw const HttpException('no bytes and no record');
  }

  @override
  Future<void> removeFile(String key) async {
    if (removeThrows) throw StateError('index unavailable');
    removed.add(key);
    records.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

void main() {
  late Directory tmp;
  late _FakeManager manager;
  late CacheManagerImageStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gl_cache_consistency');
    manager = _FakeManager(tmp);
    store = CacheManagerImageStore(manager);
    MediaCachePins.reset();
  });

  tearDown(() async {
    MediaCachePins.reset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('a record that outlived its bytes recovers cleanly', () {
    test('a cache read reports a miss and forgets the dead record', () async {
      final fs.File f = manager.writeBytes('k1');
      f.deleteSync(); // the sweep took the bytes; the record survives

      final File? hit = await store.cached('https://x/1.jpg', key: 'k1');

      expect(hit, isNull, reason: 'a record is not bytes');
      expect(manager.removed, <String>['k1'],
          reason: 'the dead record must stop shadowing a real fetch');
    });

    test('a live record is returned untouched', () async {
      manager.writeBytes('k1');
      final File? hit = await store.cached('https://x/1.jpg', key: 'k1');
      expect(hit, isNotNull);
      expect(manager.removed, isEmpty);
    });

    test('a download through a stale record forces a REAL fetch', () async {
      // This is the defect the sweeper would otherwise create: getSingleFile
      // hands back the recorded path without checking it, so the caller gets a
      // File that is not there.
      final fs.File f = manager.writeBytes('k1');
      f.deleteSync();
      manager.downloadable.add('k1');

      final File got = await store.download('https://x/1.jpg', key: 'k1');

      expect(got.existsSync(), isTrue);
      expect(got.lengthSync(), greaterThan(0));
      expect(manager.removed, <String>['k1']);
      expect(manager.singleFileCalls, <String>['k1', 'k1'],
          reason: 'exactly one retry, never a loop');
    });

    test('a zero-length entry is treated as missing', () async {
      final fs.File empty = manager._fileFor('k1')..createSync(recursive: true);
      manager.records['k1'] = empty;
      manager.downloadable.add('k1');

      final File got = await store.download('https://x/1.jpg', key: 'k1');

      expect(got.lengthSync(), greaterThan(0));
      expect(manager.removed, <String>['k1']);
    });

    test('a healthy download does not retry or forget anything', () async {
      manager.writeBytes('k1');
      await store.download('https://x/1.jpg', key: 'k1');
      expect(manager.singleFileCalls, <String>['k1']);
      expect(manager.removed, isEmpty);
    });

    test('an index that will not forget still surfaces the real failure',
        () async {
      final fs.File f = manager.writeBytes('k1');
      f.deleteSync();
      manager.removeThrows = true;

      // Forgetting is best-effort, so the second attempt still meets the same
      // stale record. What must NOT happen is handing back a path to nothing
      // and leaving the image decoder to discover it: the caller gets a plain
      // failure and shows its error state.
      await expectLater(
        store.download('https://x/1.jpg', key: 'k1'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('an index that will not forget still answers the cache read',
        () async {
      final fs.File f = manager.writeBytes('k1');
      f.deleteSync();
      manager.removeThrows = true;

      // Forgetting is best-effort. A record that cannot be dropped costs one
      // wasted fetch later; it must never turn a cache lookup into a throw.
      expect(await store.cached('https://x/1.jpg', key: 'k1'), isNull);
    });
  });

  group('the sweep cannot corrupt a fill in progress', () {
    CacheFileStat at(String path, int bytes, Duration ago) => CacheFileStat(
          path: path,
          sizeBytes: bytes,
          lastAccess: DateTime(2026, 9, 1).subtract(ago),
        );

    test('a file being written right now is left alone', () async {
      // A background fill writes straight to the entry's final path. A sweep
      // firing mid-download must not delete the file underneath it.
      final _Volume v = _Volume(<CacheFileStat>[
        at('/c/downloading.mp4', 300 * 1024 * 1024, const Duration(seconds: 5)),
        at('/c/stale.mp4', 300 * 1024 * 1024, const Duration(days: 30)),
      ]);

      final SweepResult r = await ProfileMediaCacheSweeper(
        volume: v,
        ceilingBytes: 100 * 1024 * 1024,
        clock: () => DateTime(2026, 9, 1),
      ).sweep();

      expect(v.removed, <String>['/c/stale.mp4']);
      expect(r.skippedPinned, 1, reason: 'the in-flight write was skipped');
    });

    test('once the write is old enough it becomes evictable again', () async {
      final _Volume v = _Volume(<CacheFileStat>[
        at('/c/finished.mp4', 300 * 1024 * 1024, const Duration(minutes: 10)),
      ]);

      await ProfileMediaCacheSweeper(
        volume: v,
        ceilingBytes: 100 * 1024 * 1024,
        clock: () => DateTime(2026, 9, 1),
      ).sweep();

      expect(v.removed, <String>['/c/finished.mp4']);
    });

    test('a store made entirely of in-flight writes is left completely alone',
        () async {
      final _Volume v = _Volume(<CacheFileStat>[
        for (int i = 0; i < 5; i++)
          at('/c/w$i.mp4', 200 * 1024 * 1024, const Duration(seconds: 10)),
      ]);

      final SweepResult r = await ProfileMediaCacheSweeper(
        volume: v,
        ceilingBytes: 100 * 1024 * 1024,
        clock: () => DateTime(2026, 9, 1),
      ).sweep();

      expect(v.removed, isEmpty);
      expect(r.evicted, 0);
      // Deliberately still over. Truncating five downloads to hit a number on
      // this pass would be the worse outcome; the next sweep takes them.
      expect(r.bytesAfter, greaterThan(100 * 1024 * 1024));
    });
  });

  group('the sweeper only ever looks inside its own store', () {
    test('it is constructed against the ProfileMediaCache directory alone', () {
      // The store's files live under getTemporaryDirectory()/<cacheKey>. Its
      // SQLite index lives under getApplicationSupportDirectory(), and staged
      // uploads live under getApplicationSupportDirectory()/media_outbox — so
      // neither is reachable from the directory the sweeper walks.
      expect(ProfileMediaCache.kCacheKey, 'goodliftProfileMedia');
    });

    test('a missing directory sweeps to a clean no-op', () async {
      final DirectoryCacheVolume v = DirectoryCacheVolume(
        () async => Directory('${tmp.path}/does-not-exist'),
      );
      expect(await v.list(), isEmpty);

      final SweepResult r =
          await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 1).sweep();
      expect(r.evicted, 0);
    });

    test('a real directory is measured by real file sizes', () async {
      final Directory cacheDir = Directory('${tmp.path}/store')
        ..createSync(recursive: true);
      File('${cacheDir.path}/a.bin')
          .writeAsBytesSync(List<int>.filled(1000, 0));
      File('${cacheDir.path}/b.bin')
          .writeAsBytesSync(List<int>.filled(2000, 0));

      final List<CacheFileStat> listed =
          await DirectoryCacheVolume(() async => cacheDir).list();

      expect(listed, hasLength(2));
      expect(
        listed
            .map((CacheFileStat e) => e.sizeBytes)
            .reduce((int a, int b) => a + b),
        3000,
      );
    });
  });
}

class _Volume implements CacheVolume {
  _Volume(this.entries);

  List<CacheFileStat> entries;
  final List<String> removed = <String>[];

  @override
  Future<List<CacheFileStat>> list() async => entries;

  @override
  Future<void> remove(CacheFileStat entry) async {
    removed.add(entry.path);
    entries = entries
        .where((CacheFileStat e) => e.path != entry.path)
        .toList(growable: false);
  }
}
