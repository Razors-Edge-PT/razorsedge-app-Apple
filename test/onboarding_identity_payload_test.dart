import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/onboarding_identity_payload.dart';

/// Regression coverage for the Page 2 (`OnboardingPageTwo._finish()`) identity
/// and createdAt overwrite bugs.
///
/// `OnboardingPageTwo` is shared by two very different callers:
///  * new-account creation, which always supplies every identity field and
///    is stamping the account's creation time for the first time;
///  * editing an existing user's onboarding answers (Templates / the drawer),
///    which passes `null` for whichever identity field it isn't editing, and
///    must never re-stamp the account's real creation time.
///
/// `SetOptions(merge: true)` only protects a Firestore field whose key is
/// ABSENT from the written map — an explicit `null`/`''`/re-stamped value
/// still overwrites it. These tests pin that unsupplied identity fields, and
/// createdAt outside of real account creation, are OMITTED — not written as
/// empty/null/fallback/re-stamped values — so an onboarding-only edit can
/// never wipe a user's existing username, full name, sex, date of birth, or
/// original account creation time.
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
        expect(fields.containsKey(key), isFalse,
            reason: '"$key" must be absent, not null/empty');
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

  group('createdAt: new-account creation still stamps it', () {
    test('isNewAccount: true includes createdAt', () {
      final fields = buildCreatedAtField(isNewAccount: true);

      expect(fields.containsKey('createdAt'), isTrue);
      expect(fields['createdAt'], isA<FieldValue>());
    });
  });

  group('createdAt: edit mode does NOT contain it', () {
    test('isNewAccount: false omits createdAt entirely', () {
      final fields = buildCreatedAtField(isNewAccount: false);

      expect(fields, isEmpty);
      expect(fields.containsKey('createdAt'), isFalse,
          reason: 'must be absent, not written as null — merge() would still '
              'overwrite an explicit null');
    });
  });

  group('a merge-style edit preserves a historical createdAt value', () {
    // fake_cloud_firestore models SetOptions(merge: true) the same way real
    // Firestore does: a key absent from the update map leaves the existing
    // document field untouched. This is the actual regression scenario —
    // an existing user with a real historical createdAt runs an onboarding
    // edit — reproduced end to end rather than just asserted on the map.
    test('editing onboarding answers leaves the original createdAt alone',
        () async {
      final firestore = FakeFirebaseFirestore();
      final ref = firestore.collection('users').doc('existing-uid');

      final originalCreatedAt = Timestamp.fromDate(DateTime.utc(2022, 3, 1));
      await ref.set({
        'createdAt': originalCreatedAt,
        'username': 'OriginalName',
        'usernameLower': 'originalname',
        'fullName': 'Original Person',
      });

      // The exact shape _finish() builds for an onboarding-only edit: no
      // identity fields supplied, isNewAccount: false.
      final editPayload = {
        'email': 'user@example.com',
        ...buildIdentityPayloadFields(sex: 'F', dob: '25-08-1991'),
        ...buildCreatedAtField(isNewAccount: false),
      };
      await ref.set(editPayload, SetOptions(merge: true));

      final after = (await ref.get()).data()!;
      expect(after['createdAt'], originalCreatedAt,
          reason: "the account's true creation time must survive an onboarding "
              'edit unchanged');
      expect(after['username'], 'OriginalName');
      expect(after['usernameLower'], 'originalname');
      expect(after['fullName'], 'Original Person');
      // Fields the edit screen DID supply are still written.
      expect(after['sex'], 'F');
      expect(after['dob'], '25-08-1991');
    });

    test('new-account creation stamps createdAt on a fresh document', () async {
      final firestore = FakeFirebaseFirestore();
      final ref = firestore.collection('users').doc('new-uid');

      // buildCreatedAtField(isNewAccount: true) is what _finish() actually
      // calls, and the plain unit test above already pins that its value IS
      // a FieldValue. fake_cloud_firestore's own FieldValue.serverTimestamp()
      // support needs platform-channel mocking outside this suite's scope, so
      // this integration test substitutes a concrete Timestamp for it here —
      // only to exercise the SAME merge behaviour: the key is present, so it
      // gets written to a document that had none.
      expect(buildCreatedAtField(isNewAccount: true).containsKey('createdAt'),
          isTrue);
      final creationPayload = {
        'email': 'new@example.com',
        ...buildIdentityPayloadFields(
          username: 'newuser',
          fullName: 'New User',
          sex: 'M',
          dob: '01-01-2000',
        ),
        'createdAt': Timestamp.now(),
      };
      await ref.set(creationPayload, SetOptions(merge: true));

      final after = (await ref.get()).data()!;
      expect(after.containsKey('createdAt'), isTrue);
      expect(after['createdAt'], isA<Timestamp>());
      expect(after['username'], 'newuser');
      expect(after['usernameLower'], 'newuser');
    });

    test(
        'the pre-fix shape (createdAt re-stamped unconditionally) DID '
        'overwrite the original — documents the exact regression this '
        'guards against', () async {
      final firestore = FakeFirebaseFirestore();
      final ref = firestore.collection('users').doc('existing-uid-2');

      final originalCreatedAt = Timestamp.fromDate(DateTime.utc(2020, 6, 15));
      await ref.set({'createdAt': originalCreatedAt});

      // What _finish() used to write, unconditionally, before this fix. A
      // concrete re-stamp stands in for FieldValue.serverTimestamp() here —
      // see the comment above — but the point is identical: an explicitly
      // present createdAt key is not protected by merge(), old value or new.
      await ref.set({
        'createdAt': Timestamp.now(),
      }, SetOptions(merge: true));

      final after = (await ref.get()).data()!;
      expect(after['createdAt'], isNot(originalCreatedAt),
          reason: 'demonstrates merge() does NOT protect an explicitly '
              'written createdAt key — this is the bug, not the fix');
    });
  });
}
