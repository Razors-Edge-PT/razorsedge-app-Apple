// createUserWithEmailAndPassword outlives authTimeout, then the ORIGINAL
// request succeeds and emits an auth event. Future.timeout does not cancel
// the request, so the coordinator must still own that account: AppRoot must
// hold it (no Home, no explicit-logout sign-out), the attempt must adopt the
// uid, and a retry must resume it without creating a second account.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/signup/signup_coordinator.dart';
import 'package:localtest222/signup/signup_errors.dart';
import 'package:localtest222/valid_user_gate.dart';

import 'signup/signup_test_harness.dart';

void main() {
  SignupCoordinator coordinatorWithShortAuthTimeout(SignupHarness h) =>
      SignupCoordinator(
        auth: h.auth,
        backend: h.backend,
        hooks: RecordingHooks(),
        pendingStore: h.pendingStore,
        authTimeout: const Duration(milliseconds: 40),
      );

  SignupAttempt fill(SignupCoordinator c) {
    final a = c.beginAttempt();
    a.draft.identity
      ..username = 'IronAnna'
      ..fullName = 'Anna Lift'
      ..dob = DateTime(1992, 4, 7)
      ..sex = 'F'
      ..email = 'anna@example.test'
      ..password = 'secret123';
    return a;
  }

  test('late success after the timeout is held, adopted and resumed', () async {
    final h = SignupHarness();
    final c = coordinatorWithShortAuthTimeout(h);
    final a = fill(c);

    // AppRoot's _handleValidUser, with an explicit logout in effect.
    var gateSignedOut = false;
    var routedHome = false;
    final heldAtEvent = <bool>[];
    h.auth.onAuthEvent = (u) {
      if (u == null || u.isAnonymous) return;
      final held = c.holdsAuthRoutingFor(u.uid);
      heldAtEvent.add(held);
      if (held) return;
      unawaited(passesExplicitLogoutGate(
        isExplicitLogout: () async => true,
        signOutUnexpected: () async => gateSignedOut = true,
      ).then((ok) => routedHome = ok));
    };

    h.auth.holdCreate = Completer<void>();
    final first = await c.submit(a);
    expect(first.failure!.kind, SignupFailureKind.timeout);
    expect(h.auth.calls.where((x) => x == 'create'), hasLength(1));

    // The original request now succeeds and emits its auth event.
    h.auth.holdCreate!.complete();
    await pumpEventQueue();

    expect(heldAtEvent, [true], reason: 'AppRoot must hold the late account');
    expect(gateSignedOut, isFalse);
    expect(routedHome, isFalse);
    final lateUid = h.auth.currentUser!.uid;
    expect(a.authUid, lateUid, reason: 'the attempt adopts its own account');

    h.auth.holdCreate = null;
    final second = await c.submit(a);
    expect(second.isSuccess, isTrue, reason: '${second.failure}');
    expect(second.uid, lateUid);
    expect(h.auth.calls.where((x) => x == 'create'), hasLength(1),
        reason: 'no second account');
  });

  test('a retry while the original request is still pending does not create twice',
      () async {
    final h = SignupHarness();
    final c = coordinatorWithShortAuthTimeout(h);
    final a = fill(c);
    h.auth.holdCreate = Completer<void>();

    expect((await c.submit(a)).failure!.kind, SignupFailureKind.timeout);
    final retry = await c.submit(a); // original still pending
    expect(retry.failure!.kind, SignupFailureKind.timeout);
    expect(h.auth.calls.where((x) => x == 'create'), hasLength(1));
    expect(c.holdsAuthRoutingFor('anything-the-request-creates'), isTrue);

    h.auth.holdCreate!.complete();
    await pumpEventQueue();
    h.auth.holdCreate = null;
    final done = await c.submit(a);
    expect(done.isSuccess, isTrue, reason: '${done.failure}');
    expect(h.auth.calls.where((x) => x == 'create'), hasLength(1));
  });

  test('late success after the member cancelled: held, signed out, recoverable',
      () async {
    final h = SignupHarness();
    final c = coordinatorWithShortAuthTimeout(h);
    final a = fill(c);
    final heldAtEvent = <bool>[];
    h.auth.onAuthEvent = (u) {
      if (u != null) heldAtEvent.add(c.holdsAuthRoutingFor(u.uid));
    };
    h.auth.holdCreate = Completer<void>();
    await c.submit(a);

    await c.cancelAttempt(a);
    h.auth.holdCreate!.complete();
    await pumpEventQueue();

    expect(heldAtEvent.first, isTrue, reason: 'no Home for an orphaned account');
    expect(h.auth.currentUser, isNull, reason: 'nobody owns it now: signed out');
    expect(h.auth.accounts['anna@example.test'], isNotNull,
        reason: 'never deleted');
    expect(c.suppressesSignedOutEvents, isTrue);

    // Later login on this device resumes setup.
    h.auth.signInAs('anna@example.test');
    final decision = await c.evaluateRecovery(h.auth.currentUser!,
        passwordProvider: true);
    expect(decision.resume, isTrue);
  });
}
