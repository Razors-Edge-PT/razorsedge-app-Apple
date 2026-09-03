/// A hard byte ceiling on the profile-media disk cache.
///
/// ── Why the object count was not a bound ────────────────────────────────────
/// `flutter_cache_manager` bounds a store by AGE and by OBJECT COUNT, and
/// neither says anything about bytes. Six hundred objects sounds modest until
/// the objects are training videos: a set clip can be tens of megabytes, and an
/// upload is capped near 100 MB, so the same "bounded" store is equally
/// happy holding 600 thumbnails (a few MB) or 600 clips (tens of GB). On a
/// phone that is not a cache, it is a slow disk leak.
///
/// So bytes are bounded here, in addition to — not instead of — the age and
/// count limits the package already applies.
///
/// ── How it decides what to drop ─────────────────────────────────────────────
/// Least-recently-used first, by the file's own access time, with two
/// deliberate refinements:
///
///   * A file that is being PLAYED or READ right now is never evicted. Deleting
///     the file under a running `VideoPlayerController` is the one way this
///     could break playback, so pinned paths are skipped outright — even if
///     that means finishing a sweep still over the ceiling. See [MediaCachePins].
///   * Large entries are taken before small ones. Thumbnails and stills are
///     what make the gallery render at all, they are numerous, and hundreds of
///     them together are a rounding error next to one video. Evicting a 40 MB
///     clip reclaims more than every thumbnail on the device, so small entries
///     are only touched when nothing large is left and the store is still over.
///
/// ── Why it works on the directory, not on an index ──────────────────────────
/// An in-memory index of what this process cached would be empty after a
/// restart, and a cache that only bounds what it remembers is not bounded. The
/// sweeper stats the store's own directory instead, so the ceiling holds on the
/// first launch after an upgrade, after a crash, and for bytes written by a
/// build that is no longer installed.
///
/// Deleting a file out from under the package's index is safe: every read here
/// checks `existsSync()` before trusting a hit (see `CachedProfileImage` and
/// `VideoSourceResolver`), so a swept entry simply becomes a miss and is
/// fetched again. Nothing about owner scoping changes — entries are keyed by
/// [profileMediaCacheKey], and evicting one never lets another account read it.
///
/// ── It never blocks anything ────────────────────────────────────────────────
/// A sweep is started with `unawaited` after media is already on screen, is
/// throttled to one run per [minimumInterval], and swallows every error per
/// entry and overall. A cache that cannot be tidied is a disk-space problem;
/// it is never a reason for a photo not to appear.
library;

import 'dart:async';
import 'dart:io';

/// One file in the cache directory.
class CacheFileStat {
  const CacheFileStat({
    required this.path,
    required this.sizeBytes,
    required this.lastAccess,
  });

  final String path;
  final int sizeBytes;
  final DateTime lastAccess;
}

/// The cache directory, as the sweeper needs to see it.
///
/// An interface so eviction can be tested with controlled sizes and access
/// times rather than by writing hundreds of megabytes to a real disk.
abstract class CacheVolume {
  /// Every cached file, with its real size. Implementations MUST tolerate a
  /// missing directory and skip entries they cannot stat.
  Future<List<CacheFileStat>> list();

  /// Removes one entry. Failure is the caller's to absorb.
  Future<void> remove(CacheFileStat entry);
}

/// The production volume: the store's own directory on disk.
class DirectoryCacheVolume implements CacheVolume {
  DirectoryCacheVolume(this.directory);

  /// Resolved lazily by the caller — path_provider has no implementation under
  /// the test binding, so nothing here may resolve a directory eagerly.
  final Future<Directory?> Function() directory;

  @override
  Future<List<CacheFileStat>> list() async {
    final Directory? dir = await directory();
    if (dir == null || !dir.existsSync()) return const <CacheFileStat>[];

    final List<CacheFileStat> out = <CacheFileStat>[];
    // A synchronous listing so a file vanishing mid-walk (the package's own
    // maintenance, another sweep) throws once, here, rather than half way
    // through eviction.
    late final List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(recursive: true, followLinks: false);
    } catch (_) {
      return const <CacheFileStat>[];
    }

    for (final FileSystemEntity e in entities) {
      if (e is! File) continue;
      try {
        final FileStat st = e.statSync();
        if (st.type == FileSystemEntityType.notFound) continue;
        out.add(CacheFileStat(
          path: e.path,
          sizeBytes: st.size,
          // `accessed` is the honest LRU signal. Some filesystems report it
          // lazily or not at all, in which case it equals `modified`, which is
          // still a reasonable ordering and never worse than nothing.
          lastAccess:
              st.accessed.isAfter(st.modified) ? st.accessed : st.modified,
        ));
      } catch (_) {
        // A file that cannot be stat'ed is left alone rather than guessed at.
      }
    }
    return out;
  }

  @override
  Future<void> remove(CacheFileStat entry) async {
    final File f = File(entry.path);
    if (f.existsSync()) await f.delete();
  }
}

/// Files that must not be evicted because something is reading them now.
///
/// A player holds its file open for as long as it is on screen. Deleting it
/// mid-playback is the one thing a cache sweep could do that a user would
/// actually notice, so the pin is taken before the controller is built and
/// released in `dispose`.
class MediaCachePins {
  MediaCachePins._();

  static final Map<String, int> _pins = <String, int>{};

  /// Paths currently in use.
  static Set<String> get pinned => _pins.keys.toSet();

  /// Reference-counted: the same clip open in two places is unpinned only when
  /// the last of them lets go.
  static void pin(String path) {
    if (path.isEmpty) return;
    _pins[path] = (_pins[path] ?? 0) + 1;
  }

  static void unpin(String path) {
    if (path.isEmpty) return;
    final int? n = _pins[path];
    if (n == null) return;
    if (n <= 1) {
      _pins.remove(path);
    } else {
      _pins[path] = n - 1;
    }
  }

  /// For tests.
  static void reset() => _pins.clear();
}

/// The outcome of one sweep. Returned for tests and logging; nothing branches
/// on it in production.
class SweepResult {
  const SweepResult({
    required this.bytesBefore,
    required this.bytesAfter,
    required this.evicted,
    required this.skippedPinned,
  });

  final int bytesBefore;
  final int bytesAfter;
  final int evicted;
  final int skippedPinned;

  bool get didAnything => evicted > 0;
}

/// Keeps the profile-media cache under a byte ceiling.
class ProfileMediaCacheSweeper {
  ProfileMediaCacheSweeper({
    required this.volume,
    this.ceilingBytes = kDefaultCeilingBytes,
    this.smallEntryBytes = kSmallEntryBytes,
    this.minimumInterval = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// 512 MiB.
  ///
  /// Chosen against the shape of the data rather than as a round number: a
  /// three-column gallery of poster JPEGs is single-digit megabytes even for a
  /// prolific user, so the ceiling is effectively all video. At 512 MiB a
  /// user keeps roughly a dozen recent clips available offline — enough for the
  /// sessions they are actually working through — while the app's own footprint
  /// stays inside what a phone with a nearly full disk can give back. It is
  /// also small enough that iOS is unlikely to purge the whole container under
  /// storage pressure, which would cost the user every thumbnail at once.
  static const int kDefaultCeilingBytes = 512 * 1024 * 1024;

  /// At or below this, an entry is a thumbnail or a still and is evicted only
  /// as a last resort.
  static const int kSmallEntryBytes = 512 * 1024;

  final CacheVolume volume;
  final int ceilingBytes;
  final int smallEntryBytes;
  final Duration minimumInterval;
  final DateTime Function() _now;

  DateTime? _lastSweep;
  Future<SweepResult>? _inFlight;

  /// Runs a sweep unless one ran recently or is already running.
  ///
  /// This is the entry point every caller uses. Two screens opening at once
  /// share one sweep rather than racing each other over the same files.
  Future<SweepResult?> maybeSweep({Set<String>? pinned}) {
    final Future<SweepResult>? running = _inFlight;
    if (running != null) return running;
    final DateTime? last = _lastSweep;
    if (last != null && _now().difference(last) < minimumInterval) {
      return Future<SweepResult?>.value(null);
    }
    return sweep(pinned: pinned);
  }

  /// Evicts until the store is under [ceilingBytes], or until only pinned
  /// entries remain.
  Future<SweepResult> sweep({Set<String>? pinned}) {
    final Future<SweepResult>? running = _inFlight;
    if (running != null) return running;
    final Future<SweepResult> run = _sweep(pinned ?? MediaCachePins.pinned);
    _inFlight = run;
    return run.whenComplete(() {
      _inFlight = null;
      _lastSweep = _now();
    });
  }

  Future<SweepResult> _sweep(Set<String> pinned) async {
    List<CacheFileStat> entries;
    try {
      entries = await volume.list();
    } catch (_) {
      // An unreadable or corrupt cache directory is not an error the user can
      // do anything about, and certainly not one worth failing a screen over.
      return const SweepResult(
          bytesBefore: 0, bytesAfter: 0, evicted: 0, skippedPinned: 0);
    }

    int total = 0;
    for (final CacheFileStat e in entries) {
      total += e.sizeBytes;
    }
    final int before = total;
    if (total <= ceilingBytes) {
      return SweepResult(
        bytesBefore: before,
        bytesAfter: before,
        evicted: 0,
        skippedPinned: 0,
      );
    }

    // Large entries first, each group least-recently-used first. One stale
    // video reclaims more than every thumbnail on the device, so the gallery
    // keeps rendering while the disk comes back under the ceiling.
    final List<CacheFileStat> large = <CacheFileStat>[];
    final List<CacheFileStat> small = <CacheFileStat>[];
    int skippedPinned = 0;
    for (final CacheFileStat e in entries) {
      if (pinned.contains(e.path)) {
        skippedPinned++;
        continue;
      }
      (e.sizeBytes > smallEntryBytes ? large : small).add(e);
    }
    int byAge(CacheFileStat a, CacheFileStat b) =>
        a.lastAccess.compareTo(b.lastAccess);
    large.sort(byAge);
    small.sort(byAge);

    int evicted = 0;
    for (final CacheFileStat e in <CacheFileStat>[...large, ...small]) {
      if (total <= ceilingBytes) break;
      try {
        await volume.remove(e);
        total -= e.sizeBytes;
        evicted++;
      } catch (_) {
        // A file that will not delete is skipped; the sweep keeps going and
        // the next one tries again. One stubborn entry must not strand the
        // rest of the store above the ceiling.
      }
    }

    return SweepResult(
      bytesBefore: before,
      bytesAfter: total,
      evicted: evicted,
      skippedPinned: skippedPinned,
    );
  }
}
