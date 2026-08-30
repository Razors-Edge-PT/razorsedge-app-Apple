/// A network image that survives a process restart while offline.
///
/// ── Why not Image.network ───────────────────────────────────────────────────
/// `Image.network` caches decoded frames in Flutter's in-memory `ImageCache`
/// and delegates the bytes to the platform HTTP stack. Both are process-scoped
/// in the way that matters here: kill the app and reopen it with no connection
/// and every avatar, grid tile, story frame and previously viewed photo is a
/// broken-image icon, because nothing wrote those bytes anywhere that outlives
/// the process.
///
/// `flutter_cache_manager` writes them to a real file in the application
/// documents directory and remembers them in its own SQLite index, so the
/// second launch reads them off disk with no network at all. The app already
/// depends on it — the home feed and the post detail page use it — so this
/// reuses the mechanism the rest of the app already trusts rather than adding
/// one.
///
/// ── The two-stage build ─────────────────────────────────────────────────────
/// The disk is asked FIRST (one index read, no network), so a warm image
/// appears without a placeholder flash. Only a miss falls through to a
/// download, which persists the bytes for next time — including next launch.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../core/media_urls.dart';

/// The two operations the profile needs from a persistent image store.
///
/// A narrow interface rather than [BaseCacheManager] directly, for two
/// reasons. It says exactly what is required of the store — read from disk
/// without touching the network, and download-and-persist — so "does an image
/// survive a restart?" becomes a testable question instead of an assumption.
/// And it keeps `package:file`'s `File` (which flutter_cache_manager returns)
/// out of every call site.
abstract class ProfileImageStore {
  /// The already-persisted file for [url], or null. MUST NOT hit the network:
  /// this is what has to work on a cold start with no connection.
  Future<File?> cached(String url);

  /// Downloads [url] and persists it to disk. Throws when it cannot.
  Future<File> download(String url);
}

/// The production store, backed by flutter_cache_manager.
class CacheManagerImageStore implements ProfileImageStore {
  CacheManagerImageStore([this._injected]);

  final BaseCacheManager? _injected;

  // Resolved LAZILY. Constructing a DefaultCacheManager calls path_provider,
  // which has no implementation under the test binding — so building one
  // eagerly would make merely REFERENCING this class fail in a widget test,
  // including from the reset used in tearDown.
  BaseCacheManager? _resolved;

  BaseCacheManager get _manager =>
      _injected ?? (_resolved ??= DefaultCacheManager());

  @override
  Future<File?> cached(String url) async {
    final FileInfo? hit = await _manager.getFileFromCache(url);
    // package:file's File implements dart:io's File, so this widens cleanly.
    return hit?.file;
  }

  @override
  Future<File> download(String url) => _manager.getSingleFile(url);
}

/// The store profile media is persisted in.
///
/// Injectable so a test can point it at a temporary directory and then prove a
/// *new* store over the *same* directory still serves the file — which is what
/// a process restart is.
ProfileImageStore profileImageStore = CacheManagerImageStore();

/// Resets [profileImageStore] to the app-wide default. For tests.
void resetProfileImageCache() => profileImageStore = CacheManagerImageStore();

/// An image loaded from [url], persisted to disk so it renders after a restart
/// with no connection.
///
/// [url] is passed through [safeThumbnailUrl], so a URL that actually names a
/// video container never reaches the image decoder; [fallback] is drawn
/// instead.
class CachedProfileImage extends StatefulWidget {
  const CachedProfileImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.fallback,
    this.store,
  });

  final String? url;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// Shown while the bytes are being fetched for the first time.
  final Widget? placeholder;

  /// Shown when there is no usable URL, or the fetch failed and nothing is on
  /// disk.
  final Widget? fallback;

  /// Overrides [profileImageStore] for this widget. For tests.
  final ProfileImageStore? store;

  @override
  State<CachedProfileImage> createState() => _CachedProfileImageState();
}

class _CachedProfileImageState extends State<CachedProfileImage> {
  File? _file;
  bool _failed = false;
  String? _resolvedFor;

  ProfileImageStore get _store => widget.store ?? profileImageStore;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CachedProfileImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.store != widget.store) _resolve();
  }

  Future<void> _resolve() async {
    final String? url = safeThumbnailUrl(widget.url);
    _resolvedFor = url;
    if (url == null) {
      if (mounted) {
        setState(() {
          _file = null;
          _failed = true;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _file = null;
        _failed = false;
      });
    }

    // 1. Disk first. A previously viewed image is available with no network,
    //    which is the whole point.
    try {
      final File? hit = await _store.cached(url);
      if (hit != null && hit.existsSync()) {
        if (!mounted || _resolvedFor != url) return;
        setState(() => _file = hit);
        return;
      }
    } catch (_) {
      // A corrupt index entry is not worth failing over; fall through to the
      // download, which rewrites it.
    }

    // 2. Miss: download, and persist for next time — including next launch.
    try {
      final File downloaded = await _store.download(url);
      if (!mounted || _resolvedFor != url) return;
      setState(() => _file = downloaded);
    } catch (_) {
      if (!mounted || _resolvedFor != url) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final File? file = _file;
    if (file != null) {
      return Image.file(
        file,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        errorBuilder: (_, __, ___) => _fallback(),
      );
    }
    if (_failed) return _fallback();
    // Still resolving, or the very first frame.
    return widget.placeholder ?? const SizedBox.shrink();
  }

  Widget _fallback() =>
      widget.fallback ?? widget.placeholder ?? const SizedBox.shrink();
}
