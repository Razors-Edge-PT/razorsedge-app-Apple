import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/onboarding_identity_payload.dart';

/// Regression coverage for the Page 2 (`OnboardingPageTwo._finish()`) identity
/// overwrite bug.
///
/// `OnboardingPageTwo` is shared by two very different callers:
///  * new-account creation, which always supplies every identity field;
///  * editing an existing user's onboarding answers (Templates / the drawer),
///    which passes `null` for whichever identity field it isn't editing.
///
/// `SetOptions(merge: true)` only protects a Firestore field whose key is
/// ABSENT from the written map — an explicit `null`/`''` still overwrites it.
/// These tests pin that unsupplied identity fields are OMITTED, not written
/// as empty/null/fallback values, so an onboarding-only edit can never wipe a
/// user's existing username, full name, sex, or date of birth.
void main() {
  group('new-account creation supplies every identity field', () {
    test('a valid username still yields both username and usernameLower', () {
      final fields = buildIdentityPayloadFields(username: 'RazorEdge');

      expect(fields['username'], 'RazorEdge');
      expect(fields['usernameLower'], 'razoredge');
    });

    test('usernameLower uses the same normalisation as the app-wide index', () {
      // Matches isUsernameAvailableInPublicIndex()'s trim().toLowerCase().
      final fields = buildIdentityPayloadFields(username: '  Mixed Case  ');

      expect(fields['username'], 'Mixed Case');
      expect(fields['usernameLower'], 'mixed case');
    });

    test('a valid full name still yields fullName', () {
      final fields = buildIdentityPayloadFields(fullName: 'Jane Lifter');

      expect(fields['fullName'], 'Jane Lifter');
    });

    test('a valid sex still yields sex', () {
      final fields = buildIdentityPayloadFields(sex: 'F');

      expect(fields['sex'], 'F');
    });

    test('a valid dob still yields dob', () {
      final fields = buildIdentityPayloadFields(dob: '25-08-1991');

      expect(fields['dob'], '25-08-1991');
    });

    test('a full creation-mode call yields every identity key', () {
      final fields = buildIdentityPayloadFields(
        username: 'razoredge',
        fullName: 'Jane Lifter',
        sex: 'F',
        dob: '25-08-1991',
      );

      expect(fields.keys.toSet(), {
        'username',
        'usernameLower',
        'fullName',
        'sex',
        'dob',
      });
    });
  });

  group('edit mode omits the identity fields it was not given', () {
    test('username == null omits BOTH username and usernameLower', () {
      final fields = buildIdentityPayloadFields(username: null);

      expect(fields.containsKey('username'), isFalse);
      expect(fields.containsKey('usernameLower'), isFalse);
    });

    test('fullName == null omits fullName', () {
      final fields = buildIdentityPayloadFields(fullName: null);

      expect(fields.containsKey('fullName'), isFalse);
    });

    test('sex == null omits sex (Templates/drawer prefetch can fail)', () {
      final fields = buildIdentityPayloadFields(sex: null);

      expect(fields.containsKey('sex'), isFalse);
    });

    test('dob == null omits dob (Templates/drawer prefetch can fail)', () {
      final fields = buildIdentityPayloadFields(dob: null);

      expect(fields.containsKey('dob'), isFalse);
    });

    test('omission is real absence, never null/empty-string fallback values',
        () {
      final fields = buildIdentityPayloadFields();

      expect(fields, isEmpty);
      // Guard against a regression that "fixes" this by writing null/''
      // instead of omitting the key — merge() would still overwrite either.
      for (final key in [
        'username',
        'usernameLower',
        'fullName',
        'sex',
        'dob',
      ]) {
        expect(fields.containsKey(key), isFalse, reason: '"$key" must be absent, not null/empty');
      }
    });

    test(
        "the exact edit-mode shape from app_drawer.dart / templates.dart "
        "(username: null, fullName: null, real sex/dob) preserves identity",
        () {
      final fields = buildIdentityPayloadFields(
        username: null,
        fullName: null,
        sex: 'M',
        dob: '01-01-1990',
      );

      expect(fields.containsKey('username'), isFalse);
      expect(fields.containsKey('usernameLower'), isFalse);
      expect(fields.containsKey('fullName'), isFalse);
      // Fields the edit screen DID fetch successfully still get written.
      expect(fields['sex'], 'M');
      expect(fields['dob'], '01-01-1990');
    });

    test('a failed sex/dob prefetch (both null) writes neither field', () {
      // Mirrors app_drawer.dart / templates.dart's catch block, where sex and
      // dob stay null if the Firestore prefetch throws.
      final fields = buildIdentityPayloadFields(
        username: null,
        fullName: null,
        sex: null,
        dob: null,
      );

      expect(fields, isEmpty);
    });
  });

  group('existing Firestore identity data survives a merge-style edit', () {
    test('merging an edit-mode payload leaves untouched keys unchanged', () {
      // Simulates SetOptions(merge: true): only keys present in the update
      // are touched; everything else in the existing document is untouched.
      final existing = <String, dynamic>{
        'username': 'OriginalName',
        'usernameLower': 'originalname',
        'fullName': 'Original Person',
        'sex': 'F',
        'dob': '25-08-1991',
      };

      final update = buildIdentityPayloadFields(
        username: null,
        fullName: null,
        sex: 'F',
        dob: '25-08-1991',
      );
      final merged = {...existing, ...update};

      expect(merged['username'], 'OriginalName');
      expect(merged['usernameLower'], 'originalname');
      expect(merged['fullName'], 'Original Person');
    });

    test(
        'the pre-fix shape (explicit empty/null identity keys) DID overwrite —'
        ' documents the exact regression this guards against', () {
      final existing = <String, dynamic>{
        'username': 'OriginalName',
        'usernameLower': 'originalname',
        'fullName': 'Original Person',
      };

      // What _finish() used to build, unconditionally, before this fix.
      const buggyPayload = {
        'username': '',
        'usernameLower': '',
        'fullName': null,
      };
      final merged = {...existing, ...buggyPayload};

      expect(merged['username'], '',
          reason: 'demonstrates merge() does NOT protect an explicitly '
              'written empty/null value — this is the bug, not the fix');
      expect(merged['fullName'], isNull);
    });
  });
}
