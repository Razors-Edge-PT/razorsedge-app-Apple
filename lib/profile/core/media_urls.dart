/// Media container formats, content types, and the one question the grid and
/// the feed both have to be able to answer: *is this URL actually an image?*
///
/// ── Why a thumbnail URL has to be checked ───────────────────────────────────
/// `thumbUrl` is rendered with `Image.network`. Until 1.7.13 the uploader
/// stored the SAME download URL in `thumbUrl` and `smallUrl`, so for a video
/// post `thumbUrl` was the URL of the .mp4 itself. An image decoder handed an
/// MP4 produces a broken-image icon, not a poster frame, so every video tile
/// in the profile grid and every video card in the home feed rendered empty.
///
/// Posts written by earlier builds still carry that value, so detecting it is
/// not only a guard against writing a bad one — it is what makes the tens of
/// thousands of already-published posts render correctly without a migration.
///
/// ── Why the extension and not the content type ──────────────────────────────
/// The URL is all the client has before it fetches. A Firebase Storage
/// download URL percent-encodes the object path into its own path segment
/// (`/o/users%2Fu1%2Fposts%2Fp1%2Foriginal.mp4?alt=media&token=…`), so the real
/// object name — and its extension — is recoverable from the URL alone.
library;

/// Container extensions we treat as video, without the leading dot.
const Set<String> kVideoExtensions = <String>{
  'mp4',
  'mov',
  'm4v',
  'webm',
  '3gp',
  '3gpp',
  'avi',
  'mkv',
  'mpeg',
  'mpg',
  'qt',
};

/// Container extensions we treat as still images, without the leading dot.
const Set<String> kImageExtensions = <String>{
  'jpg',
  'jpeg',
  'png',
  'webp',
  'heic',
  'heif',
  'gif',
  'bmp',
};

/// The extension a video is stored under when the real one cannot be told.
const String kDefaultVideoExtension = 'mp4';

/// The extension every generated thumbnail is stored under.
const String kThumbnailExtension = 'jpg';

/// The extension a picked still image is staged and stored under. Images are
/// re-encoded by the compressor, so unlike a video this is a real statement
/// about the bytes rather than a rename.
const String kStagedImageExtension = 'jpg';

/// The lower-cased extension of the object [url] or path points at, or null.
///
/// Handles a bare path (`users/u1/posts/p1/original.MOV`), a plain URL, and a
/// Firebase Storage download URL whose object path is percent-encoded into a
/// single segment.
String? mediaExtensionOf(String? urlOrPath) {
  if (urlOrPath == null) return null;
  String value = urlOrPath.trim();
  if (value.isEmpty) return null;

  // Drop the query and fragment: `?alt=media&token=…` is not part of the name.
  final int query = value.indexOf('?');
  if (query >= 0) value = value.substring(0, query);
  final int fragment = value.indexOf('#');
  if (fragment >= 0) value = value.substring(0, fragment);

  // A Storage download URL carries the object path percent-encoded, so `%2F`
  // has to become a real separator before the last segment means anything.
  try {
    value = Uri.decodeComponent(value);
  } catch (_) {
    // A malformed escape is not worth failing over; the raw value still has an
    // extension often enough to be useful.
  }

  final int lastSlash = value.lastIndexOf('/');
  final String name = lastSlash >= 0 ? value.substring(lastSlash + 1) : value;
  final int dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final String ext = name.substring(dot + 1).toLowerCase();
  // An "extension" with a slash or a space in it is not one.
  if (ext.isEmpty || ext.length > 5 || ext.contains(RegExp(r'[^a-z0-9]'))) {
    return null;
  }
  return ext;
}

/// True when [url] names a video container.
bool isVideoUrl(String? url) {
  final String? ext = mediaExtensionOf(url);
  return ext != null && kVideoExtensions.contains(ext);
}

/// True when [url] names a still-image format.
bool isImageUrl(String? url) {
  final String? ext = mediaExtensionOf(url);
  return ext != null && kImageExtensions.contains(ext);
}

/// The URL to hand an image decoder, or null when there is nothing safe to
/// show.
///
/// A URL that names a video container is REJECTED rather than passed through:
/// that is the value pre-1.7.13 builds stored in `thumbUrl`, and rendering it
/// produces a broken-image icon on every video tile. Returning null lets the
/// caller draw a proper video placeholder instead.
///
/// A URL with no recognisable extension is ACCEPTED. Plenty of legitimate
/// image URLs have none (a signed CDN URL, an older Storage path written
/// without one), and refusing those would blank tiles that render perfectly
/// well today.
String? safeThumbnailUrl(String? url) {
  final String? value = url?.trim();
  if (value == null || value.isEmpty) return null;
  if (isVideoUrl(value)) return null;
  return value;
}

/// The extension a picked video should be STORED under.
///
/// The source extension is preserved when we recognise it. Renaming a
/// QuickTime file to `.mp4` does not transcode it: the bytes are still a MOV,
/// and the only thing the rename changes is that everything downstream — the
/// Storage content type, the browser, and any consumer that trusts the name —
/// is now told something false about them. Preserving the real container is
/// the honest option, and every format in [kVideoExtensions] plays in the
/// app's video_player on both platforms.
String storedVideoExtension(String? sourcePath) {
  final String? ext = mediaExtensionOf(sourcePath);
  if (ext != null && kVideoExtensions.contains(ext)) return ext;
  return kDefaultVideoExtension;
}

/// The Content-Type to upload an object with, from its extension.
///
/// Storage rules gate on `request.resource.contentType`, so an honest value
/// here is what keeps a `.mov` upload passing the `isVideo()` check.
String contentTypeForExtension(String? extension) {
  switch ((extension ?? '').toLowerCase()) {
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    case 'mov':
    case 'qt':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case '3gp':
    case '3gpp':
      return 'video/3gpp';
    case 'avi':
      return 'video/x-msvideo';
    case 'mkv':
      return 'video/x-matroska';
    case 'mpeg':
    case 'mpg':
      return 'video/mpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'heic':
      return 'image/heic';
    case 'heif':
      return 'image/heif';
    case 'gif':
      return 'image/gif';
    case 'bmp':
      return 'image/bmp';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    default:
      return 'application/octet-stream';
  }
}

/// The Content-Type for an object at [storagePath].
String contentTypeForPath(String storagePath) =>
    contentTypeForExtension(mediaExtensionOf(storagePath));

/// The deterministic Storage path of the thumbnail that belongs beside the
/// media object at [mediaStoragePath].
///
/// Derived rather than stored: post, proof and story media all live in their
/// own per-item folder (`users/{uid}/posts/{mediaId}/original.mov`), so the
/// thumbnail's path is a pure function of the media path and needs no extra
/// outbox column — and therefore no local database migration on a release
/// whose whole point is to be safe to ship.
///
/// Returns null for a path with no folder of its own (the avatar, which is one
/// flat object and is its own thumbnail).
String? thumbnailStoragePathFor(String mediaStoragePath) {
  final String path = mediaStoragePath.trim();
  if (path.isEmpty) return null;
  final int lastSlash = path.lastIndexOf('/');
  if (lastSlash <= 0) return null;
  final String folder = path.substring(0, lastSlash);
  // Only the per-item folders get a sibling thumbnail.
  if (!folder.contains('/posts/') && !folder.contains('/stories/')) return null;
  return '$folder/thumb.$kThumbnailExtension';
}
