import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/data/identity_repository.dart';
import 'package:localtest222/profile/data/username_rules.dart';

void main() {
  group('normalisation', () {
    test('trims and case-folds', () {
      expect(normalizeUsername('  RichArd  '), 'richard');
      expect(normalizeUsername('BENCHKING'), 'benchking');
      expect(normalizeUsername(null), '');
    });

    test('agrees with the toLowerCase() the app has always written', () {
      // Every username already in production was written with .toLowerCase(),
      // so the backfill must not decide any of them normalise differently.
      for (final String name in <String>[
        'Richard',
        'lift_er',
        'a-b-c',
        'Zoe99',
        'MAX',
        'benchking',
      ]) {
        expect(normalizeUsername(name), name.toLowerCase(), reason: name);
      }
    });

    test('the display form keeps casing', () {
      expect(displayUsername('  RichArd '), 'RichArd');
      expect(displayUsername(null), '');
    });
  });

  group('validation', () {
    test('accepts 3 to 22 characters with no whitespace', () {
      expect(validateUsername('abc'), isNull);
      expect(validateUsername('a' * 22), isNull);
      expect(validateUsername('lift_er-99'), isNull);
    });

    test('rejects too short, too long, and whitespace', () {
      expect(validateUsername('ab'), UsernameProblem.invalidFormat);
      expect(validateUsername('a' * 23), UsernameProblem.invalidFormat);
      expect(validateUsername('has space'), UsernameProblem.invalidFormat);
      expect(validateUsername('   '), UsernameProblem.empty);
      expect(validateUsername(''), UsernameProblem.empty);
      expect(validateUsername(null), UsernameProblem.empty);
    });

    test('rejects control characters', () {
      expect(validateUsername('ab${String.fromCharCode(9)}cd'),
          UsernameProblem.invalidCharacters);
      expect(validateUsername('ab${String.fromCharCode(0)}cd'),
          UsernameProblem.invalidCharacters);
    });

    test('every problem has a message that does not claim the name is taken',
        () {
      for (final UsernameProblem p in UsernameProblem.values) {
        final String message = usernameProblemMessage(p);
        expect(message, isNotEmpty);
        expect(message.toLowerCase(), isNot(contains('taken')));
      }
    });
  });

  group('the reservation index key', () {
    test('is a fixed-length hash, so unsafe names cannot become paths', () {
      for (final String name in <String>[
        'a/b',
        '..',
        '.',
        '__proto__',
        'x' * 200,
        'ünïcødé',
      ]) {
        final String key = usernameIndexKey(normalizeUsername(name));
        expect(key, hasLength(64));
        expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue, reason: name);
        expect(key, isNot(contains('/')));
      }
    });

    test('is case-insensitive but distinguishes different names', () {
      String k(String s) => usernameIndexKey(normalizeUsername(s));
      expect(k('Richard'), k('RICHARD'));
      expect(k(' richard '), k('Richard'));
      expect(k('richard'), isNot(k('richardo')));
    });

    test('matches the derivation the backend uses', () {
      // Source-level pin against functions/identity/username_rules.js.
      final String js =
          File('functions/identity/username_rules.js').readAsStringSync();
      expect(js, contains("createHash('sha256')"));
      expect(js, contains("digest('hex')"));
      expect(js, contains(r'/^\S{3,22}$/u'));
    });
  });

  group('messages', () {
    test('the offline message explains WHY, and promises nothing', () {
      expect(kUsernameNeedsConnectionMessage, contains('connection'));
      expect(kUsernameNeedsConnectionMessage.toLowerCase(),
          isNot(contains('saved')));
    });

    test('a failed check never reads as a collision', () {
      expect(
          kUsernameCheckFailedMessage.toLowerCase(), isNot(contains('taken')));
      expect(kUsernameTakenMessage.toLowerCase(), contains('taken'));
    });
  });

  group('identity resolution by uid', () {
    late FakeFirebaseFirestore db;
    late IdentityRepository repo;

    setUp(() async {
      db = FakeFirebaseFirestore();
      repo = IdentityRepository(firestore: db);
      await db.collection('users_public').doc('u1').set(<String, Object?>{
        'username': 'BenchKing',
        'usernameLower': 'benchking',
      });
      await db.collection('users_public').doc('u2').set(<String, Object?>{
        'displayName': 'SquatQueen',
      });
    });

    test('resolves the CURRENT name, not a denormalised historical one',
        () async {
      // A two-year-old comment says the author was "OldName". The live document
      // says otherwise, and the live document wins.
      expect(await repo.displayNameFor('u1', fallback: 'OldName'), 'BenchKing');
    });

    test('falls back to displayName when username is absent', () async {
      expect(await repo.displayNameFor('u2'), 'SquatQueen');
    });

    test('uses the historical value only when nothing authoritative exists',
        () async {
      expect(await repo.displayNameFor('missing', fallback: 'WhoeverThisWas'),
          'WhoeverThisWas');
      expect(await repo.displayNameFor('missing'), isNull);
    });

    test('caches by uid so repeated lookups do not re-read', () async {
      expect(await repo.displayNameFor('u1'), 'BenchKing');
      expect(repo.cachedDisplayName('u1'), 'BenchKing');

      // Change the document behind the cache; a cached read still answers, and
      // the live watcher below is what keeps a screen current.
      await db.collection('users_public').doc('u1').set(
        <String, Object?>{'username': 'Renamed'},
        SetOptions(merge: true),
      );
      expect(await repo.displayNameFor('u1'), 'BenchKing');
    });

    test('the live watcher reflects a rename', () async {
      final Future<String?> first = repo.watchDisplayName('u1').first;
      expect(await first, 'BenchKing');

      await db.collection('users_public').doc('u1').set(
        <String, Object?>{'username': 'Renamed'},
        SetOptions(merge: true),
      );
      expect(
        await repo
            .watchDisplayName('u1')
            .firstWhere((String? n) => n == 'Renamed'),
        'Renamed',
      );
      // ...and the shared cache follows, so other screens see it too.
      expect(repo.cachedDisplayName('u1'), 'Renamed');
    });

    test('a blank username is treated as absent, not as an empty name',
        () async {
      await db.collection('users_public').doc('u3').set(<String, Object?>{
        'username': '   ',
      });
      expect(await repo.displayNameFor('u3', fallback: 'Fallback'), 'Fallback');
    });
  });

  group('changing a username', () {
    test('rejects an invalid name before it can reach the backend', () async {
      final IdentityRepository repo =
          IdentityRepository(firestore: FakeFirebaseFirestore());
      final UsernameChangeResult result = await repo.changeUsername('ab');
      expect(result.outcome, UsernameChangeOutcome.invalid);
      expect(result.isSuccess, isFalse);
      expect(result.message, isNotNull);
    });

    test('a result reports the Auth follow-up rather than assuming it', () {
      const UsernameChangeResult result = UsernameChangeResult(
        UsernameChangeOutcome.changed,
        username: 'NewName',
      );
      expect(result.isSuccess, isTrue);
      expect(result.authDisplayNameUpdated, isFalse,
          reason: 'Auth is outside the Firestore transaction, so it is '
              'reported explicitly and never presumed');
    });

    test('needsConnection is a success-free outcome, not a collision', () {
      const UsernameChangeResult result = UsernameChangeResult(
        UsernameChangeOutcome.needsConnection,
        message: kUsernameNeedsConnectionMessage,
      );
      expect(result.isSuccess, isFalse);
      expect(result.outcome, isNot(UsernameChangeOutcome.taken));
    });
  });
}
