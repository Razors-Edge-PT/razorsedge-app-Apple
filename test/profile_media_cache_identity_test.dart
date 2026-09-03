/// Cache identity: what makes two fetches the same object, and what makes them
/// different ones.
///
/// The rebuilt gallery keyed its disk cache on the whole Firebase download URL.
/// That URL ends in `?alt=media&token=<uuid>` and the token ROTATES, so the same
/// unchanged bytes were treated as a brand new object every time it turned over:
/// the old entry stranded, the image downloaded again, and "still there after a
/// restart with no connection" quietly stopped being true for anything whose
/// token had moved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_identity.dart';
import 'package:localtest222/profile/core/media_models.dart';

void main() {
  const String owner = 'athlete1';
  const String other = 'athlete2';

  String urlFor(String path, String token) =>
      'https://firebasestorage.googleapis.com/v0/b/goodlift-us-storage'
      '.appspot.com/o/${Uri.encodeComponent(path)}?alt=media&token=$token';

  group('a rotated Storage token does not change identity', () {
    test('two tokens over the same object produce the same key', () {
      const String path = 'users/$owner/posts/abc/original.jpg';
      final String before = profileMediaCacheKey(
        ownerUid: owner,
        variant: MediaVariant.small,
        storagePath: path,
        url: urlFor(path, 'token-one'),
      );
      final String after = profileMediaCacheKey(
        ownerUid: owner,
        variant: MediaVariant.small,
        storagePath: path,
        url: urlFor(path, 'token-two-completely-different'),
      );
      expect(after, before);
    });

    test('even with no storage path, the token is stripped from the fallback',
        () {
      const String path = 'users/$owner/posts/abc/original.jpg';
      final String before = profileMediaCacheKey(
        ownerUid: owner,
        variant: MediaVariant.small,
        url: urlFor(path, 'token-one'),
      );
      final String after = profileMediaCacheKey(
        ownerUid: owner,
        variant: MediaVariant.small,
        url: urlFor(path, 'token-two'),
      );
      expect(after, before);
      expect(before, isNot(contains('token')));
    });

    test('a signed-URL expiry and signature are stripped too', () {
      expect(
        stripDownloadToken('https://cdn.invalid/a.jpg?Expires=1&Signature=xy'),
        'https://cdn.invalid/a.jpg',
      );
    });

    test('a genuinely meaningful query parameter is preserved', () {
      expect(
        stripDownloadToken('https://cdn.invalid/a.jpg?w=320&token=abc'),
        'https://cdn.invalid/a.jpg?w=320',
      );
    });
  });

  group('identity separates things that really are different', () {
    const String path = 'users/$owner/posts/abc/original.mp4';

    test('the poster and the original never collide', () {
      expect(
        profileMediaCacheKey(
            ownerUid: owner, variant: MediaVariant.thumb, storagePath: path),
        isNot(profileMediaCacheKey(
            ownerUid: owner,
            variant: MediaVariant.original,
            storagePath: path)),
      );
    });

    test('two owners never collide', () {
      expect(
        profileMediaCacheKey(
            ownerUid: owner, variant: MediaVariant.small, storagePath: path),
        isNot(profileMediaCacheKey(
            ownerUid: other, variant: MediaVariant.small, storagePath: path)),
      );
    });

    test('replacing the content changes the key', () {
      // Replacement is a delete plus a fresh upload: every upload gets a new
      // mediaId from MediaStaging.newMediaId, and therefore a new object path.
      // The path IS the content revision.
      final String original = profileMediaCacheKey(
        ownerUid: owner,
        variant: MediaVariant.original,
        storagePath: 'users/$owner/posts/oldMediaId/original.mp4',
      );
      final String replacement = profileMediaCacheKey(
        ownerUid: owner,
        variant: MediaVariant.original,
        storagePath: 'users/$owner/posts/newMediaId/original.mp4',
      );
      expect(replacement, isNot(original));
    });

    test('an explicit revision changes the key for an in-place overwrite', () {
      expect(
        profileMediaCacheKey(
            ownerUid: owner,
            variant: MediaVariant.original,
            storagePath: path,
            revision: 'gen1'),
        isNot(profileMediaCacheKey(
            ownerUid: owner,
            variant: MediaVariant.original,
            storagePath: path,
            revision: 'gen2')),
      );
    });
  });

  group('a media item derives its own key', () {
    ProfileMediaItem itemWith({
      String storagePath = 'users/$owner/posts/m1/original.jpg',
      String thumbStoragePath = 'users/$owner/posts/m1/thumb.jpg',
    }) =>
        ProfileMediaItem(
          id: 'm1',
          ownerUid: owner,
          mediaType: MediaType.image,
          kind: PostKind.upload,
          storagePath: storagePath,
          thumbStoragePath: thumbStoragePath,
          smallUrl: urlFor(storagePath, 'aaa'),
          thumbUrl: urlFor(thumbStoragePath, 'bbb'),
        );

    test('the thumbnail and the small rendition get distinct keys', () {
      final ProfileMediaItem item = itemWith();
      expect(item.cacheKey(MediaVariant.thumb),
          isNot(item.cacheKey(MediaVariant.small)));
    });

    test('the key is unchanged when only the URLs rotate their tokens', () {
      final ProfileMediaItem before = itemWith();
      final ProfileMediaItem after = ProfileMediaItem(
        id: before.id,
        ownerUid: before.ownerUid,
        mediaType: before.mediaType,
        kind: before.kind,
        storagePath: before.storagePath,
        thumbStoragePath: before.thumbStoragePath,
        smallUrl: urlFor(before.storagePath, 'zzz-rotated'),
        thumbUrl: urlFor(before.thumbStoragePath!, 'yyy-rotated'),
      );
      expect(after.cacheKey(MediaVariant.small),
          before.cacheKey(MediaVariant.small));
      expect(after.cacheKey(MediaVariant.thumb),
          before.cacheKey(MediaVariant.thumb));
    });

    test('a legacy item with no storage path still keys off its document id',
        () {
      final ProfileMediaItem legacy = ProfileMediaItem(
        id: 'legacyDoc',
        ownerUid: owner,
        mediaType: MediaType.image,
        kind: PostKind.upload,
        smallUrl: urlFor('anything/at/all.jpg', 'rotates'),
      );
      expect(legacy.cacheKey(MediaVariant.small), contains('legacyDoc'));
      expect(legacy.cacheKey(MediaVariant.small), isNot(contains('rotates')));
    });
  });
}
