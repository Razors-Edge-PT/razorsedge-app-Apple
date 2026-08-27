import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/signup_username_guard.dart';

/// The final username uniqueness guard that runs immediately before the live
/// signup flow commits `usernameLower`.
///
/// Page 1's live/debounced check is convenience only — it can go stale, and it
/// deliberately does not block Continue when the read fails. These tests pin
/// the behaviour of the last line of defence.
void main() {
  group('final username re-check', () {
    test('a name that became taken after Page 1 is caught', () async {
      // Page 1 saw this as available; by the time Finish runs, it is not.
      final outcome = await checkUsernameStillAvailable(
        'lifter',
        (lower) async => false,
      );

      expect(outcome, UsernameGuardOutcome.taken);
      expect(
        actionForGuardOutcome(outcome),
        SignupCommitAction.returnToUsernameField,
      );
    });

    test('a still-free name proceeds', () async {
      final outcome = await checkUsernameStillAvailable(
        'lifter',
        (lower) async => true,
      );

      expect(outcome, UsernameGuardOutcome.available);
      expect(actionForGuardOutcome(outcome), SignupCommitAction.proceed);
    });

    test('uses the same normalised lowercase semantics as the rest of the app',
        () async {
      final seen = <String>[];
      await checkUsernameStillAvailable('  MiXeD Case  ', (lower) async {
        seen.add(lower);
        return true;
      });

      expect(seen, ['mixed case']);
    });
  });

  group('a definitive collision cannot be written', () {
    test('taken never yields proceed', () async {
      final outcome = await checkUsernameStillAvailable(
        'taken',
        (lower) async => false,
      );

      expect(
        actionForGuardOutcome(outcome),
        isNot(SignupCommitAction.proceed),
        reason: 'a definitive collision must never reach the profile write',
      );
    });

    test('the collision is reported with the exact agreed copy', () {
      expect(kUsernameTakenMessage, "That username's already taken — try another.");
    });
  });

  group('a failed availability read fails closed', () {
    test('a throwing read is checkFailed, not taken', () async {
      final outcome = await checkUsernameStillAvailable(
        'lifter',
        (lower) async => throw Exception('permission-denied'),
      );

      expect(
        outcome,
        UsernameGuardOutcome.checkFailed,
        reason: 'an unreadable index must never be reported as "taken"',
      );
      expect(outcome, isNot(UsernameGuardOutcome.taken));
    });

    test('a failed read does NOT silently allow signup to continue', () async {
      final outcome = await checkUsernameStillAvailable(
        'lifter',
        (lower) async => throw Exception('offline'),
      );

      expect(
        actionForGuardOutcome(outcome),
        SignupCommitAction.showRetryableError,
      );
      expect(
        actionForGuardOutcome(outcome),
        isNot(SignupCommitAction.proceed),
        reason: 'failing open here is exactly the duplicate-username bug',
      );
    });

    test('a synchronous throw is caught too', () async {
      final outcome = await checkUsernameStillAvailable(
        'lifter',
        (lower) => throw StateError('boom'),
      );

      expect(outcome, UsernameGuardOutcome.checkFailed);
    });

    test('the failure message is friendly, retryable, and does not claim "taken"',
        () {
      expect(
        kUsernameCheckFailedMessage,
        "We couldn't check that username right now. Check your connection and try again.",
      );
      expect(kUsernameCheckFailedMessage.toLowerCase(), isNot(contains('taken')));
    });

    test('every outcome maps to exactly one action', () {
      for (final outcome in UsernameGuardOutcome.values) {
        expect(() => actionForGuardOutcome(outcome), returnsNormally);
      }
      expect(
        UsernameGuardOutcome.values
            .map(actionForGuardOutcome)
            .where((a) => a == SignupCommitAction.proceed)
            .length,
        1,
        reason: 'only "available" may proceed to a write',
      );
    });
  });

  group('both account-creation branches are guarded', () {
    test('createUserWithEmailAndPassword branch (no current user)', () {
      expect(
        isAccountCreationPath(hasCurrentUser: false, isAnonymous: false),
        isTrue,
      );
    });

    test('anonymous credential-linking branch', () {
      expect(
        isAccountCreationPath(hasCurrentUser: true, isAnonymous: true),
        isTrue,
      );
    });

    test('an established non-anonymous user is not a creation path', () {
      // Page 2 opened in edit mode from Templates / the drawer: nothing is
      // created, and the user's own record must not read as a collision.
      expect(
        isAccountCreationPath(hasCurrentUser: true, isAnonymous: false),
        isFalse,
      );
    });
  });

  group('the guard is wired ahead of both branches in the live flow', () {
    // The guard's placement is the thing that makes "both branches" true. A
    // unit test cannot reach _finish() (it needs a live Firebase), so this
    // pins the ordering in the source instead: if someone later moves the
    // check inside one branch, or below the profile write, this fails.
    late String finishBody;

    setUpAll(() {
      final source =
          File('lib/create_new_account_screen.dart').readAsStringSync();
      final start = source.indexOf('Future<void> _finish() async {');
      expect(start, greaterThan(-1), reason: '_finish() not found');
      final end = source.indexOf('Future<void> _recomputeTemplateCandidates');
      expect(end, greaterThan(start));
      finishBody = source.substring(start, end);
    });

    test('_finish calls the guard exactly once', () {
      expect('checkUsernameStillAvailable('.allMatches(finishBody).length, 1);
    });

    test('the guard runs before the anonymous-link branch', () {
      final guard = finishBody.indexOf('checkUsernameStillAvailable(');
      final link = finishBody.indexOf('linkWithCredential(');
      expect(link, greaterThan(-1));
      expect(guard, lessThan(link));
    });

    test('the guard runs before the create-new branch', () {
      final guard = finishBody.indexOf('checkUsernameStillAvailable(');
      final create = finishBody.indexOf('createUserWithEmailAndPassword(');
      expect(create, greaterThan(-1));
      expect(guard, lessThan(create));
    });

    test('the guard runs before username/usernameLower are written', () {
      // username/usernameLower are written via buildIdentityPayloadFields()
      // (see onboarding_identity_payload.dart) rather than inline — that
      // call site is where the write actually happens.
      final guard = finishBody.indexOf('checkUsernameStillAvailable(');
      final write = finishBody.indexOf('buildIdentityPayloadFields(');
      expect(write, greaterThan(-1));
      expect(guard, lessThan(write));
    });

    test('the guard sits outside the auth if/else, covering both branches', () {
      final guard = finishBody.indexOf('checkUsernameStillAvailable(');
      final branch = finishBody.indexOf("if (current?.isAnonymous == true) {");
      expect(branch, greaterThan(-1));
      expect(
        guard,
        lessThan(branch),
        reason: 'a guard inside one branch would miss the other',
      );
    });

    test('a collision pops back to Page 1 instead of writing', () {
      final guard = finishBody.indexOf('checkUsernameStillAvailable(');
      final pop = finishBody.indexOf('pop(kSignupUsernameTakenResult)');
      final write = finishBody.indexOf('buildIdentityPayloadFields(');
      expect(pop, greaterThan(guard));
      expect(pop, lessThan(write));
    });

    test('Page 1 handles the collision result by invalidating the field', () {
      final source =
          File('lib/create_new_account_screen.dart').readAsStringSync();
      expect(source, contains('result != kSignupUsernameTakenResult'));
      expect(source, contains('_usernameAvailableFlag = false'));
    });
  });
}
