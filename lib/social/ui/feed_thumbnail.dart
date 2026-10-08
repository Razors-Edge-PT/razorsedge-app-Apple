/// Loads only an image. A missing feed URL may still have a poster in Storage.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../profile/core/media_timeouts.dart';
import '../../profile/core/media_urls.dart';
import '../../profile/data/media_url_refresh.dart';
import '../../profile/ui/cached_network_image.dart';
import '../feed_repository.dart';

class FeedThumbnail extends StatefulWidget {
  const FeedThumbnail({
    super.key,
    required this.item,
    required this.placeholder,
    required this.fallback,
    required this.errorBuilder,
  });

  final FeedItem item;
  final Widget placeholder;
  final Widget fallback;
  final Widget Function(BuildContext, MediaLoadFailure, VoidCallback) errorBuilder;

  @override
  State<FeedThumbnail> createState() => _FeedThumbnailState();
}

class _FeedThumbnailState extends State<FeedThumbnail> {
  String? _url;
  File? _file;
  bool _loading = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant FeedThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.displayUrl != widget.item.displayUrl ||
        oldWidget.item.displayCacheKey != widget.item.displayCacheKey ||
        oldWidget.item.displayStoragePath != widget.item.displayStoragePath) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final int attempt = ++_attempt;
    final FeedItem item = widget.item;
    _url = safeThumbnailUrl(item.displayUrl);
    _file = null;
    _loading = false;
    // Normal posts retain the existing cache/download/retry behavior.
    if (_url != null || !item.isVideo || item.displayStoragePath.isEmpty) return;
    _loading = true;

    // A previously recovered poster must also work after an offline restart.
    try {
      final File? cached = await profileImageStore
          .cached('', key: item.displayCacheKey)
          .timeout(kMediaCacheReadTimeout);
      if (!mounted || attempt != _attempt) return;
      if (isUsableCacheFile(cached)) {
        setState(() {
          _file = cached;
          _loading = false;
        });
        return;
      }
    } catch (_) {
      // A cache miss is not a reason to give up on the Storage poster.
    }
    if (!mounted || attempt != _attempt) return;

    String? fresh;
    try {
      fresh = safeThumbnailUrl(await profileUrlRefresher
          .freshUrl(item.displayStoragePath)
          .timeout(kMediaUrlRefreshTimeout));
    } catch (_) {
      // Bounded, one lookup per mount. A genuinely missing poster stays playable.
    }
    if (!mounted || attempt != _attempt) return;
    setState(() {
      _url = fresh;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _attempt++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_file != null) {
      return Image.file(
        _file!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => widget.fallback,
      );
    }
    if (_loading) return widget.placeholder;
    if (_url == null) return widget.fallback;
    return CachedProfileImage(
      url: _url,
      cacheKey: widget.item.displayCacheKey,
      storagePath: widget.item.displayStoragePath,
      fit: BoxFit.cover,
      placeholder: widget.placeholder,
      errorBuilder: widget.errorBuilder,
    );
  }
}
