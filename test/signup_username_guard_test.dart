import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/signup/signup_coordinator.dart';
import 'package:localtest222/signup/signup_errors.dart';
import 'package:localtest222/signup_username_guard.dart';

import 'signup/signup_test_harness.dart';

/// Username uniqueness in signup.
///
/// This file used to pin a pre-account `users_public` "final guard" that
/// failed closed on any read error. On a logged-out device that read is
/// always permission-denied, so the guard blocked every signup. The intent it
/// protected is kept, now enforced by the server reservation:
///
///  * a definitive collision can never complete a signup or write the name;
///  * a check that cannot reach a verdict never completes either, and is not
///    reported as "taken";
///  * nothing a client reads beforehand can stand in for the reservation.
void main() {
  group('a definitive collision cannot complete', () {
    test('taken → back to the Username field, nothing completed or written',
        () async {
      final h = SignupHarness();
      h.server.reserve('lifter', 'other_uid');
      final a = h.beginFilled(username: 'Lifter');

      final r = await h.coordinator.submit(a);

      expect(r.isSuccess, isFalse);
      expect(r.failure!.kind, SignupFailureKind.usernameTaken);
      expect(r.failure!.returnsToPageOne, isTrue);
      expect(h.coordinator.takeCompletedUid(), isNull);
      final user = await h.doc('users/${a.authUid}');
      expect(user?['usernameLower'], isNull,
          reason: 'a refused name leaves no profile claiming it');
      expect(h.server.holderOf('lifter'), 'other_uid');
    });

    test('an "available" hint cannot override the server verdict', () async {
      final h = SignupHarness();
      final optimistic = SignupCoordinator(
        auth: h.auth,
        backend: h.backend,
        hooks: RecordingHooks(),
        usernameHint: (_) async => true, // stale Page 1 hint
      );
      h.server.reserve('lifter', 'other_uid');
      final a = optimistic.beginAttempt();
      a.draft.identity
        ..username = 'lifter'
        ..email = 'x@example.test'
        ..password = 'secret123';

      final r = await optimistic.submit(a);

      expect(r.failure!.kind, SignupFailureKind.usernameTaken);
    });

    test('case-insensitive: the same name in another case is the same name',
        () async {
      final h = SignupHarness();
      h.server.reserve('Lifter', 'other_uid');
      final r = await h.coordinator.submit(h.beginFilled(username: 'LIFTER'));
      expect(r.failure!.kind, SignupFailureKind.usernameTaken);
    });

    test('the collision is reported with the exact agreed copy', () {
      expect(kUsernameTakenMessage, "That username's already taken — try another.");
      expect(signupFailureMessage(SignupFailureKind.usernameTaken),
          kUsernameTakenMessage);
    });
  });

  group('no verdict never completes, and is never reported as taken', () {
    for (final code in [
      'unavailable',
      'deadline-exceeded',
      'permission-denied',
      'unauthenticated',
      'internal',
    ]) {
      test(code, () async {
        final h = SignupHarness();
        h.server.failNextWith = code;
        final r = await h.coordinator.submit(h.beginFilled());
        expect(r.isSuccess, isFalse);
        expect(r.failure!.kind, isNot(SignupFailureKind.usernameTaken));
        expect(r.failure!.message.toLowerCase(), isNot(contains('taken')));
        expect(r.failure!.retryable, isTrue);
        expect(h.coordinator.takeCompletedUid(), isNull);
      });
    }

    test('only the network case blames the connection', () {
      for (final kind in SignupFailureKind.values) {
        final mentionsConnection =
            signupFailureMessage(kind).toLowerCase().contains('connection');
        expect(mentionsConnection, kind == SignupFailureKind.network,
            reason: kind.name);
      }
    });
  });

  group('no pre-account availability read', () {
    test('signup completes with no session at all before the account exists',
        () async {
      final h = SignupHarness();
      expect(h.auth.currentUser, isNull);
      final r = await h.coordinator.submit(h.beginFilled());
      expect(r.isSuccess, isTrue, reason: '${r.failure}');
    });

    test('the signup sources contain no users_public availability query', () {
      // The query that can never run logged-out must not come back as a
      // signup gate. (Signed-in Settings keeps its own advisory hint.)
      final sources = <File>[
        File('lib/create_new_account_screen.dart'),
        ...Directory('lib/signup').listSync().whereType<File>(),
      ];
      for (final f in sources) {
        expect(f.readAsStringSync(),
            isNot(contains("where('usernameLower', isEqualTo:")),
            reason: f.path);
      }
    });
  });
}
