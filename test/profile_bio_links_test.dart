import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/data/profile_repository.dart';
import 'package:localtest222/profile/ui/bio_text.dart';

/// A bio is user-supplied text shown to OTHER people, so what becomes tappable
/// matters. Only http and https ever do.
void main() {
  List<String> links(String bio) => parseBio(bio)
      .where((BioSpan s) => s.isLink)
      .map((BioSpan s) => s.url!)
      .toList();

  List<String> plain(String bio) => parseBio(bio)
      .where((BioSpan s) => !s.isLink)
      .map((BioSpan s) => s.text)
      .toList();

  group('safe links', () {
    test('https and http are linkified', () {
      expect(links('see https://goodlift.app for more'),
          <String>['https://goodlift.app']);
      expect(links('http://example.com'), <String>['http://example.com']);
    });

    test('a bare www host is promoted to https, never http', () {
      expect(links('www.goodlift.app'), <String>['https://www.goodlift.app']);
    });

    test('paths, queries and ports survive', () {
      expect(links('https://goodlift.app/u/rich?tab=lifts'),
          <String>['https://goodlift.app/u/rich?tab=lifts']);
      expect(links('https://goodlift.app:8443/x'),
          <String>['https://goodlift.app:8443/x']);
    });

    test('several links in one bio are all found', () {
      expect(
        links('https://a.example and https://b.example'),
        <String>['https://a.example', 'https://b.example'],
      );
    });

    test('trailing sentence punctuation is not swallowed into the link', () {
      expect(
          links('see https://goodlift.app.'), <String>['https://goodlift.app']);
      expect(plain('see https://goodlift.app.').last, '.');
      expect(links('(https://goodlift.app)'), <String>['https://goodlift.app']);
    });
  });

  group('unsafe schemes stay inert text', () {
    test('javascript, file, data and intent are never linkified', () {
      for (final String bio in <String>[
        'javascript:alert(1)',
        'JavaScript:alert(1)',
        'file:///etc/passwd',
        'data:text/html;base64,PHNjcmlwdD4=',
        'intent://scan/#Intent;scheme=zxing;end',
        'mailto:someone@example.com',
        'tel:+441234567890',
        'app://deep/link',
      ]) {
        expect(links(bio), isEmpty, reason: bio);
      }
    });

    test('the text is still shown, just not tappable', () {
      const String bio = 'javascript:alert(1)';
      expect(parseBio(bio).map((BioSpan s) => s.text).join(), bio);
    });

    test('safeLinkUrl is the single gate, and it refuses everything else', () {
      expect(safeLinkUrl('https://goodlift.app'), 'https://goodlift.app');
      expect(safeLinkUrl('javascript:alert(1)'), isNull);
      expect(safeLinkUrl('data:text/html,x'), isNull);
      expect(safeLinkUrl('not a url'), isNull);
      // No authority — nothing to navigate to.
      expect(safeLinkUrl('https:///'), isNull);
    });
  });

  group('plain bios', () {
    test('text with no links round-trips unchanged', () {
      const String bio = 'Chasing a 200 kg bench. Coached by nobody.';
      expect(links(bio), isEmpty);
      expect(parseBio(bio).single.text, bio);
    });

    test('an empty bio produces nothing', () {
      expect(parseBio(''), isEmpty);
    });
  });

  group('the 150 character limit', () {
    test('is 150', () {
      expect(kBioMaxLength, 150);
    });

    test('clamps an over-long bio and trims', () {
      final String long = 'x' * 200;
      expect(ProfileRepository.clampBio(long).length, 150);
      expect(ProfileRepository.clampBio('  hello  '), 'hello');
    });

    test('leaves an in-limit bio exactly as written', () {
      const String bio = 'Chasing a 200 kg bench.';
      expect(ProfileRepository.clampBio(bio), bio);
      expect(ProfileRepository.clampBio('x' * 150).length, 150);
    });

    test('an over-long legacy bio still renders rather than being dropped', () {
      // Written by an older build with no limit. It must display (clamped),
      // never blank.
      final String legacy = 'https://goodlift.app ${'y' * 300}';
      expect(ProfileRepository.clampBio(legacy).length, 150);
      expect(links(ProfileRepository.clampBio(legacy)),
          <String>['https://goodlift.app']);
    });
  });
}
