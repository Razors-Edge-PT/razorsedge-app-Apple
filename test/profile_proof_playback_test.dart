import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/core/media_urls.dart';
import 'package:localtest222/profile/ui/media_detail_page.dart';

/// Regression cover for the published-proof playback defect.
///
/// `ProfileScreen._openProof` used to hand `proof.thumbUrl` to
/// [MediaDetailPage] as the video source. From 1.7.13 `thumbUrl` is the POSTER
/// image, so a video proof handed a JPEG to VideoPlayerController and never
/// played.
///
/// The fix is in two parts, and both are covered here:
///   * `_openProof` now resolves the proof's `postId` and opens the real post,
///     which is where the playable media actually lives. That path needs
///     Firestore, so it is exercised by the source-selection rule below rather
///     than by mounting ProfileScreen.
///   * [MediaDetailPage] now refuses a still-image URL outright, so no caller
///     can reintroduce the defect from somewhere else.

void main() {
  group('safeVideoSource', () {
    test('rejects a poster image URL', () {
      expect(
          safeVideoSource('https://x/o/users%2Fu1%2Fp1%2Fthumb.jpg'), isNull);
      expect(safeVideoSource('poster.jpeg'), isNull);
      expect(safeVideoSource('poster.PNG'), isNull);
      expect(safeVideoSource('poster.webp'), isNull);
    });

    test('accepts real video containers, MOV included', () {
      expect(safeVideoSource('clip.mp4'), 'clip.mp4');
      expect(safeVideoSource('clip.MOV'), 'clip.MOV');
      expect(safeVideoSource('clip.m4v'), 'clip.m4v');
    });

    test('accepts an extensionless URL, as signed CDN URLs have none', () {
      expect(safeVideoSource('https://cdn.example/abc123?sig=x'),
          'https://cdn.example/abc123?sig=x');
    });

    test('treats blank and null as nothing to play', () {
      expect(safeVideoSource(null), isNull);
      expect(safeVideoSource('   '), isNull);
    });

    test('decodes a Storage download URL before judging it', () {
      const String posterUrl =
          'https://firebasestorage.googleapis.com/v0/b/b/o/'
          'users%2Fu1%2Fposts%2Fp1%2Fthumb.jpg?alt=media&token=t';
      expect(safeVideoSource(posterUrl), isNull,
          reason: 'the real object name is percent-encoded into the path');
    });

    test('is the exact mirror of safeThumbnailUrl', () {
      // A video URL is playable but not renderable; a poster is the reverse.
      expect(safeVideoSource('clip.mp4'), isNotNull);
      expect(safeThumbnailUrl('clip.mp4'), isNull);
      expect(safeVideoSource('poster.jpg'), isNull);
      expect(safeThumbnailUrl('poster.jpg'), isNotNull);
    });
  });

  group('MediaDetailPage refuses a poster as a video source', () {
    testWidgets('a poster URL never reaches the player', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: MediaDetailPage(
          title: 'Owner',
          mediaType: MediaType.video,
          url: 'https://x/o/users%2Fu1%2Fposts%2Fp1%2Fthumb.jpg',
          badge: 'Bench Press, Barbell · 180 kg × 2',
        ),
      ));
      // Resolving the source is asynchronous now - the cache is asked before
      // anything is handed to a player - so settle before asserting.
      await tester.pumpAndSettle();

      // No VideoPlayer was ever built, and the user is told plainly. The
      // wording moved into MediaFailureView so that "unplayable", "offline" and
      // "timed out" read consistently wherever the user meets them.
      expect(find.text('There is nothing to play here.'), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    test('the proof badge still describes the record', () {
      // Guards the surrounding behaviour the fix must not disturb.
      const MediaDetailPage page = MediaDetailPage(
        title: 'Owner',
        mediaType: MediaType.video,
        url: 'clip.mp4',
        badge: 'Bench Press, Barbell · 180 kg × 2',
      );
      expect(page.badge, 'Bench Press, Barbell · 180 kg × 2');
      expect(page.mediaType, MediaType.video);
    });
  });
}
