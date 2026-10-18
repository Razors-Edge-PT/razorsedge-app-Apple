// An account created during signup must finish its setup however the signup
// was interrupted: cancellation, app termination/relaunch, or a later login
// (on this or another device). Established members must log in exactly as
// before, and no password is ever persisted.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/signup/onboarding_models.dart';
import 'package:localtest222/signup/signup_coordinator.dart';
import 'package:localtest222/signup/signup_errors.dart';
import 'package:localtest222/signup/signup_pending_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'signup/signup_test_harness.dart';

const _email = 'anna@example.test';
const _password = 'secret123';

/// Signup that creates the account, then fails at [stage].
Future<SignupAttempt> _interruptedSignup(SignupHarness h, String stage) async {
  h.backend.failNext(stage,
      FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'));
  final a = h.beginFilled(email: _email, password: _password);
  a.draft.onboarding.injuries.add('Knees');
  a.draft.onboarding.painSlider['Knees'] = 6;
  final r = await h.coordinator.submit(a);
  expect(r.isSuccess, isFalse);
  expect(a.accountCreated, isTrue);
  return a;
}

/// Completes a recovery for the signed-in account without any password.
Future<SignupResult> _recover(SignupCoordinator c, String uid,
    {void Function(SignupAttempt)? edit}) async {
  final r = c.beginRecovery(uid);
  expect(r.draft.identity.password, isEmpty, reason: 'no credentials needed');
  await c.loadRecovery(r);
  edit?.call(r);
  return c.submit(r);
}

Future<void> _expectComplete(SignupHarness h, String uid) async {
  final user = (await h.doc('users/$uid'))!;
  expect(user['usernameLower'], 'ironanna');
  expect(user['fullName'], 'Anna Lift');
  expect(user['createdAt'], isA<Timestamp>());
  expect(await h.doc('users/$uid/profile/fitness_onboarding'), isNotNull);
  expect((await h.doc('users/$uid/profile/membership'))!['active'], false);
  expect(await h.doc('users/$uid/block_planner/current_block'), isNotNull);
  expect(await h.blockCount(uid), 3);
  expect((await h.doc('users/$uid/profile/signup_progress'))!['state'], 'complete');
}

void main() {
  group('cancellation, then a later login', () {
    test('same device: setup resumes without a password and completes', () async {
      final h = SignupHarness();
      final a = await _interruptedSignup(h, 'onboarding');
      final uid = a.authUid!;
      final createdAt = (await h.doc('users/$uid'))!['createdAt'];

      await h.coordinator.cancelAttempt(a);
      expect(h.auth.currentUser, isNull);
      expect((await h.doc('users/$uid/profile/signup_progress'))!['state'], 'pending');

      h.auth.signInAs(_email); // the login screen
      final d = await h.coordinator.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);
      expect(d.resume, isTrue);
      expect(d.trustedDevice, isTrue);

      final r = await _recover(h.coordinator, uid);
      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      await _expectComplete(h, uid);
      expect((await h.doc('users/$uid'))!['createdAt'], createdAt,
          reason: 'createdAt committed once, never re-stamped');
      expect(h.auth.calls.where((c) => c == 'create'), hasLength(1));
      expect(h.coordinator.takeCompletedUid(), uid);

      final again = await h.coordinator.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);
      expect(again.resume, isFalse);
    });

    test('another device: the server marker resumes it (gate still applies)',
        () async {
      final h = SignupHarness();
      final a = await _interruptedSignup(h, 'membership');
      await h.coordinator.cancelAttempt(a);

      final otherDevice = SignupHarness(); // fresh device store
      // Same backend + auth, different device storage.
      final c = SignupCoordinator(
        auth: h.auth,
        backend: h.backend,
        hooks: RecordingHooks(),
        pendingStore: otherDevice.pendingStore,
      );
      h.auth.signInAs(_email);
      final d = await c.evaluateRecovery(h.auth.currentUser!, passwordProvider: true);
      expect(d.resume, isTrue);
      expect(d.trustedDevice, isFalse,
          reason: 'only this device\'s own signup bypasses an explicit logout');

      final r = await _recover(c, a.authUid!, edit: (r) {
        // Failed before the profile was written: Page 1 asks for it again.
        expect(r.draft.identity.fullName, isEmpty);
        r.draft.identity
          ..fullName = 'Anna Lift'
          ..sex = 'F'
          ..dob = DateTime(1992, 4, 7);
      });
      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      await _expectComplete(h, a.authUid!);
    });

    test('the recovered draft is pre-filled from what was already saved',
        () async {
      final h = SignupHarness();
      final a = await _interruptedSignup(h, 'seed'); // onboarding written
      await h.coordinator.cancelAttempt(a);
      h.auth.signInAs(_email);

      final r = h.coordinator.beginRecovery(a.authUid!);
      expect(await h.coordinator.loadRecovery(r), isTrue);

      expect(r.draft.identity.username, 'IronAnna');
      expect(r.draft.identity.fullName, 'Anna Lift');
      expect(r.draft.identity.sex, 'F');
      expect(r.draft.identity.dob, DateTime(1992, 4, 7));
      expect(r.draft.onboarding.injuries, {'Knees'});
      expect(r.draft.onboarding.painSlider['Knees'], 6);
      expect(r.draft.onboarding.experience, TrainingExperience.oneYear);
      expect(r.draft.onboarding.env, 'home');
    });
  });

  group('app termination and relaunch', () {
    test('after the account exists: the persisted session resumes setup',
        () async {
      final h = SignupHarness();
      final a = await _interruptedSignup(h, 'profile');
      final uid = a.authUid!;

      // Process dies: no cancel, the Auth session persists.
      final relaunched = h.relaunch();
      final d = await relaunched.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);
      expect(d.resume, isTrue);
      expect(d.trustedDevice, isTrue,
          reason: 'an explicit logout before this signup must not sign it out');

      final r = await _recover(relaunched, uid, edit: (r) {
        // Profile never got written, so the member re-enters it.
        expect(r.draft.identity.fullName, isEmpty);
        r.draft.identity
          ..fullName = 'Anna Lift'
          ..sex = 'F'
          ..dob = DateTime(1992, 4, 7);
      });
      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      await _expectComplete(h, uid);
    });

    test('before the uid reached the app: recognised by the device marker',
        () async {
      final h = SignupHarness();
      h.auth.createCommitsThenDropsResponse = true;
      final a = h.beginFilled(email: _email, password: _password);
      expect((await h.coordinator.submit(a)).failure!.kind, SignupFailureKind.network);
      expect(a.authUid, isNull);
      expect((await h.pendingStore.read())!.uid, isNull);

      // Terminated. Later the member logs in with the same credentials.
      h.auth.signInAs(_email);
      final relaunched = h.relaunch();
      final d = await relaunched.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);
      expect(d.resume, isTrue);

      final uid = h.auth.currentUser!.uid;
      final r = await _recover(relaunched, uid, edit: (r) {
        r.draft.identity
          ..username = 'IronAnna'
          ..fullName = 'Anna Lift'
          ..sex = 'F'
          ..dob = DateTime(1992, 4, 7);
        r.draft.onboarding.env = 'home';
      });
      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      await _expectComplete(h, uid);
    });
  });

  group('re-signup with the same email', () {
    test('an unfinished account is continued with the typed password', () async {
      final h = SignupHarness();
      final first = await _interruptedSignup(h, 'onboarding');
      await h.coordinator.cancelAttempt(first);

      final again = h.beginFilled(email: _email, password: _password);
      final r = await h.coordinator.submit(again);

      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      expect(r.uid, first.authUid);
      expect(h.auth.calls.where((c) => c == 'create'), hasLength(2),
          reason: 'second create refused as in-use, then the account adopted');
      await _expectComplete(h, r.uid!);
    });

    test('a completed member\'s email is refused even with the right password',
        () async {
      final h = SignupHarness();
      final done = await h.coordinator.submit(h.beginFilled(email: _email));
      expect(done.isSuccess, isTrue);
      final before = await h.doc('users/${done.uid}');
      h.auth.externalSignOut();

      final c = h.relaunch();
      final a = c.beginAttempt();
      a.draft.identity
        ..username = 'Impostor'
        ..fullName = 'Someone Else'
        ..dob = DateTime(2000, 1, 1)
        ..sex = 'M'
        ..email = _email
        ..password = _password;
      final r = await c.submit(a);

      expect(r.failure!.kind, SignupFailureKind.emailInUse);
      expect(h.auth.currentUser, isNull, reason: 'signed back out');
      expect(await h.doc('users/${done.uid}'), before, reason: 'untouched');
    });
  });

  group('established members log in exactly as before', () {
    test('an old account is answered with no network read', () async {
      final h = SignupHarness();
      h.auth.seedAccount('member@example.test', 'pw', createdAt: DateTime(2025, 2, 1));
      h.auth.signInAs('member@example.test');

      final d = await h.coordinator.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);

      expect(d.resume, isFalse);
      expect(h.backend.calls['signupState'], isNull);
    });

    test('a recent account with no signup marker is ordinary, and cached',
        () async {
      final h = SignupHarness();
      h.auth.seedAccount('new@example.test', 'pw', createdAt: DateTime.now());
      h.auth.signInAs('new@example.test');

      final d1 = await h.coordinator.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);
      final d2 = await h.coordinator.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);

      expect(d1.resume, isFalse);
      expect(d2.resume, isFalse);
      expect(h.backend.calls['signupState'], 1, reason: 'checked once, then cached');
    });

    test('a Google (non-password) account is never checked', () async {
      final h = SignupHarness();
      h.auth.seedAccount('g@example.test', 'x', createdAt: DateTime.now());
      h.auth.signInAs('g@example.test');
      final d = await h.coordinator.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: false);
      expect(d.resume, isFalse);
      expect(h.backend.calls['signupState'], isNull);
    });

    test('a completed signup is never resumed again', () async {
      final h = SignupHarness();
      final done = await h.coordinator.submit(h.beginFilled());
      final relaunched = h.relaunch();
      final d = await relaunched.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);
      expect(d.resume, isFalse);
      expect(done.isSuccess, isTrue);
    });

    test('a failed recovery check never blocks an ordinary login', () async {
      final h = SignupHarness();
      h.auth.seedAccount('new@example.test', 'pw', createdAt: DateTime.now());
      h.auth.signInAs('new@example.test');
      h.backend.failNext('signupState',
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'));
      final d = await h.coordinator.evaluateRecovery(h.auth.currentUser!,
          passwordProvider: true);
      expect(d.resume, isFalse);
    });
  });

  group('recovery safety', () {
    test('recovery without a signed-in session fails, never completes', () async {
      final h = SignupHarness();
      final a = await _interruptedSignup(h, 'onboarding');
      await h.coordinator.cancelAttempt(a); // signed out
      final r = h.coordinator.beginRecovery(a.authUid!);
      final res = await h.coordinator.submit(r);
      expect(res.failure!.kind, SignupFailureKind.permission);
      expect(h.coordinator.takeCompletedUid(), isNull);
    });

    test('signing out of recovery is an explicit logout; it stays resumable',
        () async {
      final h = SignupHarness();
      final a = await _interruptedSignup(h, 'onboarding');
      final r = h.relaunch()..beginRecovery(a.authUid!);
      await r.signOutByChoice(r.current!);
      expect(h.auth.calls, contains('signOutByChoice'));
      expect((await h.doc('users/${a.authUid}/profile/signup_progress'))!['state'],
          'pending');
    });

    test('no password or plain email ever reaches device storage', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final h = SignupHarness(store: PrefsSignupPendingStore());
      h.auth.createCommitsThenDropsResponse = true;
      final a = h.beginFilled(email: _email, password: _password);
      await h.coordinator.submit(a); // account created, response lost
      await h.coordinator.cancelAttempt(a); // marker kept: account may exist

      final prefs = await SharedPreferences.getInstance();
      final everything =
          prefs.getKeys().map((k) => '$k=${prefs.get(k)}').join('\n');
      expect(everything, isNot(contains(_password)));
      expect(everything, isNot(contains(_email)));
      expect(everything, contains(signupEmailHash(_email)));
    });
  });
}
