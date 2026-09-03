/// Stable identity for a piece of profile media, and the one honest answer to
/// "what kind of media is this?".
///
/// ── Why the download URL is not an identity ─────────────────────────────────
/// A Firebase Storage download URL ends in `?alt=media&token=<uuid>`. That
/// token ROTATES: it changes when the object's metadata is rewritten, when a
/// token is revoked from the console, and whenever a fresh `getDownloadURL()`
/// is served a new one. Keying a disk cache on the whole URL therefore treats
/// the same bytes as a different object every time the token turns over — the
/// old entry is stranded, the image is downloaded again, and the "offline after
/// a restart" guarantee quietly stops holding for anything whose token moved.
///
/// ── What is stable, and what genuinely changes ──────────────────────────────
/// Every upload gets a FRESH random `mediaId` ([MediaStaging.newMediaId]) and
/// therefore a fresh per-item Storage folder
/// (`users/{uid}/posts/{mediaId}/original.mp4`). Media is never rewritten in
/// place: "replacing" a photo is a delete plus a new upload under a new path.
/// So the owner + object path + variant triple is exactly the identity we want
/// — it survives token rotation, and it changes the moment the content is
/// genuinely replaced.
///
/// [revision] is offered for the one case where a caller DOES know a content
/// generation (a Storage generation number, an `updatedAt`), so that if a
/// future writer ever does overwrite an object in place the key follows it.
library;

import 'media_models.dart';

/// Which rendition of one piece of media a cache entry holds.
///
/// Part of the key because the thumbnail and the original live at different
/// paths but are the same logical media: without this a poster JPEG and the
/// video it posters could collide.
class MediaVariant {
  static const String thumb = 'thumb';
  static const String small = 'small';
  static const String original = 'original';
  static const String avatar = 'avatar';
}

/// The media types the gallery can actually render.
///
/// Anything else is malformed as far as the current schema is concerned. This
/// is deliberately a closed set: silently treating an unknown value as an image
/// is what puts a video URL into an image decoder.
const Set<String> kSupportedMediaTypes = <String>{
  MediaType.image,
  MediaType.video,
};

/// [raw] as a supported media type, or null when it is absent or unknown.
///
/// Note the missing default. `mediaType ?? 'image'` is how a video with a
/// dropped field ends up rendered as a broken still, and how an RE Daily record
/// — which has no media at all — ends up claiming a gallery slot as an image.
String? normalizedMediaType(Object? raw) {
  if (raw is! String) return null;
  final String value = raw.trim().toLowerCase();
  return kSupportedMediaTypes.contains(value) ? value : null;
}

/// True when [raw] names a media type the gallery can render.
bool isSupportedMediaType(Object? raw) => normalizedMediaType(raw) != null;

/// A Storage download URL with its rotating access token removed.
///
/// Used only as the LAST fallback identity, for a legacy document that carries
/// neither a storage path nor a usable id. Everything else about the URL — the
/// bucket and the percent-encoded object path — is stable, so this is still a
/// far better key than the raw URL.
String stripDownloadToken(String url) {
  final int q = url.indexOf('?');
  if (q < 0) return url;
  final String base = url.substring(0, q);
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null) return base;
  // Keep every parameter EXCEPT the rotating ones, so a URL that legitimately
  // varies by query (a resize parameter, say) still keys distinctly.
  final Map<String, String> keep = <String, String>{
    for (final MapEntry<String, String> e in parsed.queryParameters.entries)
      if (e.key != 'token' && e.key != 'Expires' && e.key != 'Signature')
        e.key: e.value,
  };
  if (keep.isEmpty) return base;
  final List<String> parts = keep.keys.toList()..sort();
  return '$base?${parts.map((String k) => '$k=${keep[k]}').join('&')}';
}

/// The cache key for one rendition of one piece of media.
///
/// Composed rather than hashed so a cache directory stays legible when
/// something goes wrong, and so a test can state the expected key exactly.
///
/// [ownerUid] is included so two accounts can never share an entry, which is
/// what stops one signed-in user's cached photo appearing on another's profile
/// after a switch.
String profileMediaCacheKey({
  required String ownerUid,
  required String variant,
  String storagePath = '',
  String mediaId = '',
  String url = '',
  String revision = '',
}) {
  final String path = storagePath.trim();
  final String id = mediaId.trim();
  final String subject = path.isNotEmpty
      ? path
      : id.isNotEmpty
          ? id
          : stripDownloadToken(url.trim());
  final String rev = revision.trim();
  return <String>[
    'glmedia',
    ownerUid.trim(),
    variant,
    subject,
    if (rev.isNotEmpty) rev,
  ].join('|');
}
