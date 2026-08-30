import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_urls.dart';
import 'package:localtest222/profile/data/media_staging.dart';

/// Thumbnails and container formats.
///
/// Two defects live here, and both come from the same shortcut — treating a
/// video's own URL as if it were a picture of the video:
///
///   * `thumbUrl` was set to the SAME download URL as the media, so for a
///     video it was an .mp4. An image decoder handed an .mp4 renders a
///     broken-image icon, which is what every video tile in the profile grid
///     and the home feed showed.
///   * a picked video was COPIED to a `.mp4` filename regardless of what it
///     actually was. That does not transcode anything: an iPhone QuickTime
///     file staged that way is still MOV bytes with a lying name and a lying
///     Content-Type.
void main() {
  group('extension detection', () {
    test('reads a plain path', () {
      expect(mediaExtensionOf('users/u1/posts/p1/original.mp4'), 'mp4');
      expect(mediaExtensionOf('users/u1/posts/p1/original.MOV'), 'mov');
      expect(mediaExtensionOf('photo.JPEG'), 'jpeg');
    });

    test('reads a Firebase Storage download URL', () {
      // The object path is percent-encoded into ONE URL path segment, so the
      // real name is only recoverable after decoding.
      const String url =
          'https://firebasestorage.googleapis.com/v0/b/goodlift-us-storage.appspot.com/o/'
          'users%2Fu1%2Fposts%2Fp1%2Foriginal.mp4?alt=media&token=abc-123';
      expect(mediaExtensionOf(url), 'mp4');
    });

    test('ignores the query string and the fragment', () {
      expect(mediaExtensionOf('https://x/y/a.jpg?alt=media&token=z'), 'jpg');
      expect(mediaExtensionOf('https://x/y/a.png#frag'), 'png');
    });

    test('returns null when there is no usable extension', () {
      expect(mediaExtensionOf('https://cdn.example/abcdef'), isNull);
      expect(mediaExtensionOf('https://cdn.example/a.'), isNull);
      expect(mediaExtensionOf(''), isNull);
      expect(mediaExtensionOf(null), isNull);
      // Not an extension: too long, and not alphanumeric.
      expect(mediaExtensionOf('https://x/a.verylongthing'), isNull);
    });
  });

  group('a video URL is never a thumbnail', () {
    test('safeThumbnailUrl REJECTS an mp4 URL', () {
      const String mp4 =
          'https://example.invalid/users/u1/posts/p1/original.mp4';
      expect(isVideoUrl(mp4), isTrue);
      expect(safeThumbnailUrl(mp4), isNull,
          reason: 'an image decoder handed an mp4 renders a broken image');
    });

    test('safeThumbnailUrl rejects a Storage download URL for an mp4', () {
      const String url =
          'https://firebasestorage.googleapis.com/v0/b/b.appspot.com/o/'
          'users%2Fu1%2Fposts%2Fp1%2Foriginal.mp4?alt=media&token=t';
      expect(safeThumbnailUrl(url), isNull);
    });

    test('safeThumbnailUrl rejects every video container we accept', () {
      for (final String ext in kVideoExtensions) {
        final String url = 'https://example.invalid/clip.$ext';
        expect(safeThumbnailUrl(url), isNull, reason: ext);
      }
    });

    test('safeThumbnailUrl ACCEPTS a real image URL', () {
      const String jpg = 'https://example.invalid/users/u1/posts/p1/thumb.jpg';
      expect(safeThumbnailUrl(jpg), jpg);
      for (final String ext in kImageExtensions) {
        expect(safeThumbnailUrl('https://example.invalid/a.$ext'), isNotNull,
            reason: ext);
      }
    });

    test('safeThumbnailUrl accepts a URL with no extension at all', () {
      // A signed CDN URL, or an older Storage object written without one.
      // Refusing these would blank tiles that render perfectly well today.
      const String url = 'https://cdn.example.invalid/abc123?sig=xyz';
      expect(safeThumbnailUrl(url), url);
    });

    test('safeThumbnailUrl rejects nothing at all', () {
      expect(safeThumbnailUrl(''), isNull);
      expect(safeThumbnailUrl('   '), isNull);
      expect(safeThumbnailUrl(null), isNull);
    });
  });

  group('the real container is preserved', () {
    test('a QuickTime file stays QuickTime', () {
      // Copying it to a .mp4 name does not transcode it. The bytes are still
      // MOV; only the name and the declared type would become untrue.
      expect(storedVideoExtension('/private/var/tmp/IMG_4021.MOV'), 'mov');
      expect(storedVideoExtension('/tmp/clip.mov'), 'mov');
    });

    test('every container we accept is kept as it is', () {
      for (final String ext in kVideoExtensions) {
        expect(storedVideoExtension('/tmp/clip.$ext'), ext, reason: ext);
      }
    });

    test('an unknown or missing extension falls back to mp4', () {
      expect(storedVideoExtension('/tmp/clip.xyz'), kDefaultVideoExtension);
      expect(storedVideoExtension('/tmp/clip'), kDefaultVideoExtension);
      expect(storedVideoExtension(null), kDefaultVideoExtension);
    });

    test('the object name matches what was staged', () {
      expect(
          MediaStaging.objectNameFor('video', '/tmp/abc.mov'), 'original.mov');
      expect(
          MediaStaging.objectNameFor('video', '/tmp/abc.mp4'), 'original.mp4');
      expect(
          MediaStaging.objectNameFor('image', '/tmp/abc.jpg'), 'original.jpg');
    });
  });

  group('the declared Content-Type tells the truth', () {
    test('a .mov is video/quicktime, not video/mp4', () {
      // Storage rules gate uploads on request.resource.contentType, and the
      // player, the browser and any future transcoder all trust it.
      expect(contentTypeForPath('users/u1/posts/p1/original.mov'),
          'video/quicktime');
      expect(contentTypeForPath('users/u1/posts/p1/original.mp4'), 'video/mp4');
      expect(
          contentTypeForPath('users/u1/posts/p1/original.webm'), 'video/webm');
    });

    test('every video container still declares a video/* type', () {
      // storage.rules isVideo() matches ^video/.*, so a container that
      // declared something else would be rejected at upload.
      for (final String ext in kVideoExtensions) {
        expect(contentTypeForExtension(ext), startsWith('video/'), reason: ext);
      }
    });

    test('images declare an image/* type', () {
      for (final String ext in kImageExtensions) {
        expect(contentTypeForExtension(ext), startsWith('image/'), reason: ext);
      }
    });
  });

  group('the thumbnail has a deterministic path of its own', () {
    test('it is a sibling of the media object', () {
      expect(
        thumbnailStoragePathFor('users/u1/posts/p1/original.mov'),
        'users/u1/posts/p1/thumb.jpg',
      );
      expect(
        thumbnailStoragePathFor('users/u1/stories/s1/original.mp4'),
        'users/u1/stories/s1/thumb.jpg',
      );
    });

    test('it does not depend on the media container', () {
      // A retry that re-derived a different thumbnail path would orphan the
      // first one, and the folder sweep on deletion would still catch it — but
      // the grid would be pointing at whichever URL was committed last.
      for (final String ext in kVideoExtensions) {
        expect(thumbnailStoragePathFor('users/u1/posts/p1/original.$ext'),
            'users/u1/posts/p1/thumb.jpg');
      }
    });

    test('the avatar has none: it is one flat object and is its own thumbnail',
        () {
      expect(thumbnailStoragePathFor('users/u1/profile/abc.jpg'), isNull);
    });

    test('an empty or rootless path has none', () {
      expect(thumbnailStoragePathFor(''), isNull);
      expect(thumbnailStoragePathFor('original.mp4'), isNull);
    });
  });
}
