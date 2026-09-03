/// The disk cache has a hard byte ceiling, not just an object count.
///
/// `flutter_cache_manager` bounds a store by AGE and by OBJECT COUNT. Neither
/// says anything about bytes, and a count is not a bound when the objects are
/// training videos: the same "600 objects, 90 days" configuration is equally
/// happy holding a few megabytes of thumbnails or tens of gigabytes of clips.
/// On a phone that is a slow disk leak, not a cache.
///
/// Sizes here are controlled fakes rather than real files, so eviction can be
/// proven against a 40 MB clip without writing 40 MB to disk.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/data/media_cache_sweeper.dart';

const int kMiB = 1024 * 1024;

/// A cache directory whose contents the test dictates.
class _FakeVolume implements CacheVolume {
  _FakeVolume(this.entries);

  List<CacheFileStat> entries;
  final List<String> removed = <String>[];

  /// Set to throw from [list], modelling an unreadable or corrupt directory.
  Object? listError;

  /// Paths whose deletion fails, modelling a locked or already-gone file.
  Set<String> undeletable = <String>{};

  int listCalls = 0;

  @override
  Future<List<CacheFileStat>> list() async {
    listCalls++;
    final Object? err = listError;
    if (err != null) throw err;
    return entries;
  }

  @override
  Future<void> remove(CacheFileStat entry) async {
    if (undeletable.contains(entry.path)) {
      throw const FileSystemExceptionStub('locked');
    }
    removed.add(entry.path);
    entries = entries
        .where((CacheFileStat e) => e.path != entry.path)
        .toList(growable: false);
  }
}

class FileSystemExceptionStub implements Exception {
  const FileSystemExceptionStub(this.message);
  final String message;
  @override
  String toString() => 'FileSystemExceptionStub: $message';
}

CacheFileStat entry(String path, int bytes, int ageDays) => CacheFileStat(
      path: path,
      sizeBytes: bytes,
      lastAccess: DateTime(2026, 9, 1).subtract(Duration(days: ageDays)),
    );

void main() {
  setUp(MediaCachePins.reset);
  tearDown(MediaCachePins.reset);

  group('the ceiling is a real byte budget', () {
    test('the default ceiling is 512 MiB', () {
      expect(ProfileMediaCacheSweeper.kDefaultCeilingBytes, 512 * kMiB);
    });

    test('a store under the ceiling is left completely alone', () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        entry('/c/a.mp4', 40 * kMiB, 10),
        entry('/c/b.jpg', 40 * 1024, 1),
      ]);
      final SweepResult r = await ProfileMediaCacheSweeper(
        volume: v,
        ceilingBytes: 512 * kMiB,
      ).sweep();

      expect(v.removed, isEmpty);
      expect(r.evicted, 0);
      expect(r.bytesAfter, r.bytesBefore);
    });

    test('eviction runs until the store is under the ceiling', () async {
      // 10 clips of 30 MiB = 300 MiB, against a 100 MiB ceiling.
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        for (int i = 0; i < 10; i++) entry('/c/clip$i.mp4', 30 * kMiB, i),
      ]);
      final SweepResult r = await ProfileMediaCacheSweeper(
        volume: v,
        ceilingBytes: 100 * kMiB,
      ).sweep();

      expect(r.bytesBefore, 300 * kMiB);
      expect(r.bytesAfter, lessThanOrEqualTo(100 * kMiB));
      expect(v.removed, hasLength(r.evicted));
    });

    test('eviction is least-recently-used first', () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        entry('/c/newest.mp4', 30 * kMiB, 1),
        entry('/c/middle.mp4', 30 * kMiB, 20),
        entry('/c/oldest.mp4', 30 * kMiB, 90),
      ]);
      await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 70 * kMiB)
          .sweep();

      expect(v.removed, <String>['/c/oldest.mp4']);
    });

    test('it keeps taking the oldest until it is under, in order', () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        entry('/c/newest.mp4', 30 * kMiB, 1),
        entry('/c/middle.mp4', 30 * kMiB, 20),
        entry('/c/oldest.mp4', 30 * kMiB, 90),
      ]);
      await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 35 * kMiB)
          .sweep();

      expect(v.removed, <String>['/c/oldest.mp4', '/c/middle.mp4']);
    });
  });

  group('one unusually large file cannot cause unbounded growth', () {
    test('a single 100 MB clip beyond the ceiling is evicted on its own',
        () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        entry('/c/huge.mp4', 100 * kMiB, 5),
        entry('/c/small.jpg', 20 * 1024, 1),
      ]);
      final SweepResult r =
          await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 64 * kMiB)
              .sweep();

      expect(v.removed, contains('/c/huge.mp4'));
      expect(r.bytesAfter, lessThanOrEqualTo(64 * kMiB));
    });

    test('a stream of large clips can never exceed the ceiling', () async {
      // Twenty successive 100 MiB videos: 2 GiB written over a session. After
      // each arrival the sweeper runs, and the store never ends up over.
      List<CacheFileStat> current = <CacheFileStat>[];
      final _FakeVolume v = _FakeVolume(current);
      // A fixed clock, and arrivals that are already older than the write
      // grace: this test is about the ceiling, not about protecting a download
      // still in flight (which profile_media_cache_consistency_test covers).
      final ProfileMediaCacheSweeper sweeper = ProfileMediaCacheSweeper(
        volume: v,
        ceilingBytes: 512 * kMiB,
        clock: () => DateTime(2026, 9, 1),
      );

      int peak = 0;
      for (int i = 0; i < 20; i++) {
        current = <CacheFileStat>[
          ...v.entries,
          // Newest arrival last, but every one settled: 20 days ago down to 1.
          entry('/c/clip$i.mp4', 100 * kMiB, 20 - i),
        ];
        v.entries = current;
        final SweepResult r = await sweeper.sweep();
        peak = r.bytesBefore > peak ? r.bytesBefore : peak;
        int total = 0;
        for (final CacheFileStat e in v.entries) {
          total += e.sizeBytes;
        }
        expect(total, lessThanOrEqualTo(512 * kMiB),
            reason: 'the store must be under the ceiling after every arrival');
      }
      expect(peak, greaterThan(512 * kMiB),
          reason: 'the test must actually have pushed it over at some point');
    });
  });

  group('what it refuses to evict', () {
    test('a file being played right now is never deleted', () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        entry('/c/playing.mp4', 400 * kMiB, 99), // oldest AND largest
        entry('/c/other.mp4', 200 * kMiB, 1),
      ]);
      MediaCachePins.pin('/c/playing.mp4');

      final SweepResult r =
          await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 100 * kMiB)
              .sweep();

      expect(v.removed, <String>['/c/other.mp4']);
      expect(r.skippedPinned, 1);
      // Deliberately still over: keeping playback alive beats hitting the
      // number on this pass. The next sweep, after dispose, takes it.
      expect(r.bytesAfter, greaterThan(100 * kMiB));
    });

    test('a pin held twice survives one release', () async {
      MediaCachePins.pin('/c/a.mp4');
      MediaCachePins.pin('/c/a.mp4');
      MediaCachePins.unpin('/c/a.mp4');
      expect(MediaCachePins.pinned, contains('/c/a.mp4'));
      MediaCachePins.unpin('/c/a.mp4');
      expect(MediaCachePins.pinned, isEmpty);
    });

    test('unpinning something never pinned is harmless', () {
      MediaCachePins.unpin('/c/nothing.mp4');
      MediaCachePins.unpin('');
      expect(MediaCachePins.pinned, isEmpty);
    });

    test('thumbnails are preserved while any large entry remains', () async {
      // Ten stale thumbnails and one recent video. Strict LRU by age alone
      // would eat every thumbnail first and still be over; taking the clip
      // reclaims more than all of them together.
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        for (int i = 0; i < 10; i++) entry('/c/thumb$i.jpg', 60 * 1024, 80 + i),
        entry('/c/clip.mp4', 300 * kMiB, 1),
      ]);
      await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 100 * kMiB)
          .sweep();

      expect(v.removed, <String>['/c/clip.mp4']);
      expect(v.entries, hasLength(10));
    });

    test('small entries ARE taken when nothing large is left', () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        for (int i = 0; i < 10; i++)
          entry('/c/thumb$i.jpg', 100 * 1024, 100 - i),
      ]);
      await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 500 * 1024)
          .sweep();

      // Oldest first, and only as many as needed.
      expect(v.removed.first, '/c/thumb0.jpg');
      int total = 0;
      for (final CacheFileStat e in v.entries) {
        total += e.sizeBytes;
      }
      expect(total, lessThanOrEqualTo(500 * 1024));
    });
  });

  group('failures are isolated and non-fatal', () {
    test('an unreadable cache directory sweeps to a no-op', () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[])
        ..listError = const FileSystemExceptionStub('corrupt metadata');

      final SweepResult r =
          await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 1).sweep();

      expect(r.evicted, 0);
      expect(r.bytesBefore, 0);
    });

    test('one undeletable file does not strand the rest above the ceiling',
        () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        entry('/c/locked.mp4', 100 * kMiB, 90),
        entry('/c/a.mp4', 100 * kMiB, 50),
        entry('/c/b.mp4', 100 * kMiB, 40),
      ])
        ..undeletable = <String>{'/c/locked.mp4'};

      final SweepResult r =
          await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 150 * kMiB)
              .sweep();

      expect(v.removed, <String>['/c/a.mp4', '/c/b.mp4']);
      expect(r.bytesAfter, lessThanOrEqualTo(150 * kMiB));
    });

    test('an empty store is fine', () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[]);
      final SweepResult r =
          await ProfileMediaCacheSweeper(volume: v, ceilingBytes: 1).sweep();
      expect(r.evicted, 0);
    });
  });

  group('sweeping never blocks or storms', () {
    test('two concurrent sweeps share one pass over the directory', () async {
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[
        entry('/c/a.mp4', 200 * kMiB, 5),
      ]);
      final ProfileMediaCacheSweeper s =
          ProfileMediaCacheSweeper(volume: v, ceilingBytes: 100 * kMiB);

      final List<SweepResult> both =
          await Future.wait(<Future<SweepResult>>[s.sweep(), s.sweep()]);

      expect(v.listCalls, 1);
      expect(both.first.evicted, both.last.evicted);
    });

    test('maybeSweep is throttled to one run per interval', () async {
      DateTime now = DateTime(2026, 9, 1, 12);
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[]);
      final ProfileMediaCacheSweeper s = ProfileMediaCacheSweeper(
        volume: v,
        ceilingBytes: 1,
        minimumInterval: const Duration(minutes: 5),
        clock: () => now,
      );

      await s.maybeSweep();
      expect(v.listCalls, 1);

      now = now.add(const Duration(minutes: 1));
      await s.maybeSweep();
      expect(v.listCalls, 1, reason: 'still inside the interval');

      now = now.add(const Duration(minutes: 10));
      await s.maybeSweep();
      expect(v.listCalls, 2);
    });

    test('a hundred rapid triggers do not become a hundred passes', () async {
      DateTime now = DateTime(2026, 9, 1, 12);
      final _FakeVolume v = _FakeVolume(<CacheFileStat>[]);
      final ProfileMediaCacheSweeper s = ProfileMediaCacheSweeper(
        volume: v,
        ceilingBytes: 1,
        clock: () => now,
      );

      for (int i = 0; i < 100; i++) {
        await s.maybeSweep();
      }
      expect(v.listCalls, 1);
    });
  });
}
