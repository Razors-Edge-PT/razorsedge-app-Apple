/// Keeping the disk sweep and the cache manager's own records consistent.
///
/// [ProfileMediaCacheSweeper] reclaims bytes by deleting FILES from the store's
/// directory. The cache manager's index lives somewhere else entirely — its
/// database is written under `getApplicationSupportDirectory()`, while the
/// files it describes live under `getTemporaryDirectory()/<cacheKey>`, and
/// staged uploads live under `getApplicationSupportDirectory()/media_outbox`.
/// So a sweep can never damage the index, the staging area, or anything else
/// the app owns — but the index can certainly OUTLIVE the bytes it describes.
///
/// That matters because `CacheManager.getSingleFile` returns the recorded file
/// whenever the record is inside `validTill` and does not check that the file
/// exists. Left alone, a swept entry would be handed back as a path to nothing:
/// no re-fetch, and the failure surfacing later inside an image decoder as
/// though the media were corrupt. These tests pin the recovery.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/data/media_cache_sweeper.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gl_cache_consistency');
    MediaCachePins.reset();
  });

  tearDown(() async {
    MediaCachePins.reset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  File withBytes(String name, {int bytes = 64}) {
    final File f = File('${tmp.path}/$name')..createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 1));
    return f;
  }

  group('a record is not bytes', () {
    test('a file that exists with content is usable', () {
      expect(isUsableCacheFile(withBytes('good.bin')), isTrue);
    });

    test('a file the sweep deleted is not', () {
      final File f = withBytes('gone.bin')..deleteSync();
      expect(isUsableCacheFile(f), isFalse);
    });

    test('a zero-length file is not', () {
      final File empty = File('${tmp.path}/empty.bin')..createSync();
      expect(isUsableCacheFile(empty), isFalse);
    });

    test('null is not', () {
      expect(isUsableCacheFile(null), isFalse);
    });
  });

  group('a record that outlived its bytes recovers cleanly', () {
    test('a stale record is forgotten and the fetch is made real', () async {
      // The first call models CacheManager returning its stale record: a path
      // to a file the sweep already deleted. The second models the real
      // download that happens once the record is gone.
      final File ghost = File('${tmp.path}/ghost.bin');
      int fetches = 0;
      int forgets = 0;

      final File got = await fetchWithStaleRecovery(
        key: 'k1',
        fetch: () async {
          fetches++;
          return fetches == 1 ? ghost : withBytes('real.bin');
        },
        forget: () async => forgets++,
      );

      expect(got.existsSync(), isTrue);
      expect(got.lengthSync(), greaterThan(0));
      expect(forgets, 1, reason: 'the dead record must stop shadowing a fetch');
      expect(fetches, 2, reason: 'exactly one retry, never a loop');
    });

    test('a healthy first fetch neither retries nor forgets anything',
        () async {
      int fetches = 0;
      int forgets = 0;

      await fetchWithStaleRecovery(
        key: 'k1',
        fetch: () async {
          fetches++;
          return withBytes('fine.bin');
        },
        forget: () async => forgets++,
      );

      expect(fetches, 1);
      expect(forgets, 0);
    });

    test('an empty result is treated as stale, not as success', () async {
      int fetches = 0;
      final File got = await fetchWithStaleRecovery(
        key: 'k1',
        fetch: () async {
          fetches++;
          return fetches == 1
              ? (File('${tmp.path}/empty.bin')..createSync())
              : withBytes('real.bin');
        },
        forget: () async {},
      );

      expect(got.lengthSync(), greaterThan(0));
      expect(fetches, 2);
    });

    test('a second unusable result throws rather than returning a dead path',
        () async {
      // The record could not be forgotten, so the retry meets it again. What
      // must NOT happen is handing back a path to nothing and leaving an image
      // decoder to discover it: the caller gets a plain failure and shows its
      // own error state.
      int fetches = 0;
      await expectLater(
        fetchWithStaleRecovery(
          key: 'k1',
          fetch: () async {
            fetches++;
            return File('${tmp.path}/never.bin');
          },
          forget: () async {},
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(fetches, 2, reason: 'bounded: two attempts and no more');
    });

    test('a genuine fetch failure propagates unchanged', () async {
      await expectLater(
        fetchWithStaleRecovery(
          key: 'k1',
          fetch: () async => throw const SocketException('offline'),
          forget: () async {},
        ),
        throwsA(isA<SocketException>()),
      );
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

    test('once the write has settled it becomes evictable again', () async {
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
    test('the store it sweeps is the profile-media cache', () {
      // Its files live under getTemporaryDirectory()/<kCacheKey>. The cache
      // index lives under getApplicationSupportDirectory(), and staged uploads
      // under getApplicationSupportDirectory()/media_outbox — neither is
      // reachable from the directory the sweeper walks.
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

    test('a null directory sweeps to a clean no-op', () async {
      final DirectoryCacheVolume v = DirectoryCacheVolume(() async => null);
      expect(await v.list(), isEmpty);
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

    test('only files are listed, and a real one really is deleted', () async {
      final Directory cacheDir = Directory('${tmp.path}/store2')
        ..createSync(recursive: true);
      Directory('${cacheDir.path}/nested').createSync();
      final File f = File('${cacheDir.path}/nested/c.bin')
        ..writeAsBytesSync(List<int>.filled(50, 0));

      final DirectoryCacheVolume v = DirectoryCacheVolume(() async => cacheDir);
      final List<CacheFileStat> listed = await v.list();

      // Compared by basename: the listing reports platform-native separators.
      expect(listed, hasLength(1), reason: 'directories are not entries');
      expect(listed.single.path, endsWith('c.bin'));

      await v.remove(listed.single);
      expect(f.existsSync(), isFalse);
      // Removing something already gone is not an error.
      await v.remove(listed.single);
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
