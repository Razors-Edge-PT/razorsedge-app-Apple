/// On-disk lifetime of set footage.
///
/// Three rules this exists to enforce:
///
///  1. **Durable, not cached.** Finished clips live in application support.
///     A cache or temp directory is swept by the OS whenever it likes, and the
///     camera's own output path on iOS can be invalidated the moment the
///     capture UI closes.
///
///  2. **Atomic.** A clip is written to a `.part` sibling and renamed into
///     place. A rename within one directory is atomic, so a reader either sees
///     the whole file or no file — never a half-written one left by a crash
///     mid-copy.
///
///  3. **Truthful containers.** The real extension is preserved. Renaming a
///     QuickTime file to `.mp4` transcodes nothing; it only makes the name, the
///     Content-Type and every downstream consumer disagree with the bytes.
///     [storedVideoExtension] is the same helper the profile media staging
///     uses, so both paths tell the same truth.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../profile/core/media_urls.dart';

/// Filesystem operations, injectable so tests never touch a real device path.
abstract class SetVideoFiles {
  /// Directory holding one owner's durable clips, created if absent.
  Future<Directory> videoDir(String ownerUid);

  /// Directory for in-progress captures. Swept on startup.
  Future<Directory> tempDir(String ownerUid);

  /// Moves [source] into durable storage under [recordId], preserving the real
  /// container, and returns the finished file.
  ///
  /// Atomic: the bytes land on a `.part` sibling and are renamed into place
  /// only once complete. [generation] keeps a replacement from colliding with
  /// the file it replaces, so the old clip stays readable until the caller
  /// deletes it.
  Future<File> adopt({
    required String ownerUid,
    required String recordId,
    required int generation,
    required File source,
  });

  /// Deletes a path, ignoring absence. Idempotent by design: deletion runs from
  /// retries and cleanup passes, and must never fail because it already ran.
  Future<void> deleteQuietly(String? path);

  /// Removes leftover raw captures and `.part` files.
  ///
  /// A raw recording is TEMPORARY — only the trimmed result is kept — so
  /// anything still here belongs to a capture that was cancelled or killed.
  Future<int> sweepTemp(String ownerUid);

  /// Total bytes of one owner's durable clips.
  Future<int> usageBytes(String ownerUid);
}

class AppSupportSetVideoFiles implements SetVideoFiles {
  AppSupportSetVideoFiles({Future<Directory> Function()? supportDirectory})
      : _support = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _support;

  Future<Directory> _ensure(String ownerUid, String leaf) async {
    final Directory support = await _support();
    // Per-owner subtree: a second account on the same device cannot read the
    // first one's footage, and signing out can drop one subtree cleanly.
    final Directory dir =
        Directory(p.join(support.path, 'set_videos', _safe(ownerUid), leaf));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// A uid is opaque, so it is sanitised rather than trusted as a path segment.
  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  @override
  Future<Directory> videoDir(String ownerUid) => _ensure(ownerUid, 'clips');

  @override
  Future<Directory> tempDir(String ownerUid) => _ensure(ownerUid, 'tmp');

  @override
  Future<File> adopt({
    required String ownerUid,
    required String recordId,
    required int generation,
    required File source,
  }) async {
    final Directory dir = await videoDir(ownerUid);
    final String ext = storedVideoExtension(source.path);
    final String base = '${_safe(recordId)}_g$generation';
    final File target = File(p.join(dir.path, '$base.$ext'));
    final File part = File(p.join(dir.path, '$base.$ext.part'));

    if (part.existsSync()) await part.delete();
    await source.copy(part.path);
    // Atomic within the directory: readers see all of it or none of it.
    final File finished = await part.rename(target.path);
    return finished;
  }

  @override
  Future<void> deleteQuietly(String? path) async {
    if (path == null || path.trim().isEmpty) return;
    try {
      final File f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // Deletion is best-effort cleanup. A locked or already-removed file must
      // never fail the operation that asked for it.
    }
  }

  @override
  Future<int> sweepTemp(String ownerUid) async {
    int removed = 0;
    for (final Directory dir in <Directory>[
      await tempDir(ownerUid),
      await videoDir(ownerUid),
    ]) {
      if (!dir.existsSync()) continue;
      for (final FileSystemEntity e in dir.listSync()) {
        if (e is! File) continue;
        final bool isPart = e.path.endsWith('.part');
        final bool isRawCapture =
            p.dirname(e.path) == dir.path && dir.path.endsWith('tmp');
        if (isPart || isRawCapture) {
          await deleteQuietly(e.path);
          removed++;
        }
      }
    }
    return removed;
  }

  @override
  Future<int> usageBytes(String ownerUid) async {
    final Directory dir = await videoDir(ownerUid);
    if (!dir.existsSync()) return 0;
    int total = 0;
    for (final FileSystemEntity e in dir.listSync()) {
      if (e is File && !e.path.endsWith('.part')) {
        try {
          total += e.lengthSync();
        } catch (_) {
          // A file removed between listing and measuring contributes nothing.
        }
      }
    }
    return total;
  }
}
