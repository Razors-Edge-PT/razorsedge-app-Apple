// Behavioural coverage of the signup completion sequence (SignupCoordinator)
// through its auth / username-reservation / Firestore boundaries. The backend
// is the production FirestoreSignupBackend over FakeFirebaseFirestore, so the
// assertions are on what is actually persisted.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/signup/firebase_signup_services.dart';
import 'package:localtest222/signup/onboarding_models.dart';
import 'package:localtest222/signup/signup_coordinator.dart';
import 'package:localtest222/signup/signup_errors.dart';
import 'package:localtest222/valid_user_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'signup/signup_test_harness.dart';

Future<void> expectFullyOnboarded(SignupHarness h, String uid,
    {required String usernameLower}) async {
  final user = (await h.doc('users/$uid'))!;
  final pub = (await h.doc('users_public/$uid'))!;
  expect(user['usernameLower'], usernameLower);
  expect(pub['usernameLower'], usernameLower);
  expect(user['fullName'], 'Anna Lift');
  expect(user['sex'], 'F');
  expect(user['dob'], '07-04-1992', reason: 'DOB keeps dd-mm-yyyy storage');
  expect(user['createdAt'], isA<Timestamp>());
  expect(await h.doc('users/$uid/profile/fitness_onboarding'), isNotNull);
  final membership = (await h.doc('users/$uid/profile/membership'))!;
  expect(membership['active'], false,
      reason: 'a new member is never granted paid membership');
  final ptr = (await h.doc('users/$uid/block_planner/current_block'))!;
  expect(await h.doc('users/$uid/planned_blocks/${ptr['blockId']}'), isNotNull);
  expect(await h.blockCount(uid), 3);
}

void main() {
  group('fresh signup', () {
    test('from null auth: creates the account, reserves the name, sets up everything',
        () async {
      final h = SignupHarness();
      final a = h.beginFilled();

      final r = await h.coordinator.submit(a);

      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      expect(h.auth.calls.where((c) => c == 'create'), hasLength(1));
      expect(h.server.holderOf('IronAnna'), r.uid);
      await expectFullyOnboarded(h, r.uid!, usernameLower: 'ironanna');
      expect((h.hooks as RecordingHooks).completed, [r.uid]);
      expect(a.state, SignupAttemptState.completed);
      expect(a.draft.identity.password, isEmpty,
          reason: 'credentials are wiped once signup completes');
      expect(h.coordinator.takeCompletedUid(), r.uid);
      expect(h.coordinator.takeCompletedUid(), isNull, reason: 'routed once');
    });

    test('anonymous auth unavailable: no anonymous session is needed at all',
        () async {
      // Production has no anonymous provider. The old flow's pre-auth read
      // was permission-denied here; nothing in the new flow depends on it.
      final h = SignupHarness();
      final a = h.beginFilled();
      expect(await h.coordinator.usernameHint('IronAnna'), isNull,
          reason: 'logged out: availability is honestly unknown');

      final r = await h.coordinator.submit(a);

      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      expect(h.auth.calls, isNot(contains('anonymous')));
    });

    test('a failed advisory read cannot prevent server-authoritative completion',
        () async {
      final h = SignupHarness();
      final throwing = SignupCoordinator(
        auth: h.auth,
        backend: h.backend,
        hooks: RecordingHooks(),
        usernameHint: (_) async => throw FirebaseException(
            plugin: 'cloud_firestore', code: 'permission-denied'),
      );
      final a = throwing.beginAttempt();
      a.draft.identity
        ..username = 'IronAnna'
        ..fullName = 'Anna Lift'
        ..dob = DateTime(1992, 4, 7)
        ..sex = 'F'
        ..email = 'anna@example.test'
        ..password = 'secret123';

      expect(await throwing.usernameHint('IronAnna'), isNull);
      final r = await throwing.submit(a);

      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      expect(h.server.holderOf('IronAnna'), r.uid);
    });

    test('delayed anonymous initialisation is upgraded, keeping its uid', () async {
      final h = SignupHarness();
      final a = h.beginFilled();
      h.auth.signInAsAnonymous(); // surfaces after Page 1 opened
      final anonUid = h.auth.currentUser!.uid;

      final r = await h.coordinator.submit(a);

      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      expect(r.uid, anonUid);
      expect(h.auth.calls, contains('link'));
      expect(h.auth.calls, isNot(contains('create')));
    });

    test('anonymous-to-email upgrade from the start', () async {
      final h = SignupHarness();
      h.auth.signInAsAnonymous();
      final anonUid = h.auth.currentUser!.uid;
      final a = h.beginFilled();

      final r = await h.coordinator.submit(a);

      expect(r.uid, anonUid);
      await expectFullyOnboarded(h, anonUid, usernameLower: 'ironanna');
    });
  });

  group('explicit logout, then a different member signs up', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'goodlift_explicit_logout': true,
        'goodlift_last_login_provider': 'google',
      });
    });

    test('AppRoot holds the new account, then the gate passes after completion',
        () async {
      final h = SignupHarness(hooks: PrefsSignupSessionHooks());
      final prefs = await SharedPreferences.getInstance();
      var signedOutByGate = false;

      // What AppRoot._handleValidUser does with the auth event raised by
      // account creation (before createAccount even returns).
      final gateResults = <bool>[];
      h.auth.onAuthEvent = (user) {
        if (user == null || user.isAnonymous) return;
        if (h.coordinator.holdsAuthRoutingFor(user.uid)) return; // held
        unawaited(passesExplicitLogoutGate(
          isExplicitLogout: () async =>
              prefs.getBool('goodlift_explicit_logout') ?? false,
          signOutUnexpected: () async => signedOutByGate = true,
        ).then(gateResults.add));
      };

      final a = h.beginFilled();
      final r = await h.coordinator.submit(a);

      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      expect(signedOutByGate, isFalse,
          reason: 'the old flow signed the new member straight back out');
      expect(gateResults, isEmpty, reason: 'held during setup');
      expect(prefs.getBool('goodlift_explicit_logout'), isFalse);
      expect(prefs.getString('goodlift_last_login_provider'), 'password',
          reason: 'an old Google account must not be silently restored');

      // AppRoot's completion routing now passes the gate.
      expect(h.coordinator.holdsAuthRoutingFor(r.uid!), isFalse);
      final allowed = await passesExplicitLogoutGate(
        isExplicitLogout: () async =>
            prefs.getBool('goodlift_explicit_logout') ?? false,
        signOutUnexpected: () async => signedOutByGate = true,
      );
      expect(allowed, isTrue);
      expect(signedOutByGate, isFalse);
    });

    test('a failed signup does not weaken the earlier explicit logout', () async {
      final h = SignupHarness(hooks: PrefsSignupSessionHooks());
      h.server.failNextWith = 'internal';
      final r = await h.coordinator.submit(h.beginFilled());

      expect(r.isSuccess, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('goodlift_explicit_logout'), isTrue);
      expect(prefs.getString('goodlift_last_login_provider'), 'google');
    });
  });

  group('username uniqueness', () {
    test('a taken name returns to Page 1 with both pages retained, then succeeds',
        () async {
      final h = SignupHarness();
      h.server.reserve('IronAnna', 'someone_else');
      final a = h.beginFilled();
      a.draft.onboarding
        ..injuries.add('Knees')
        ..painSlider['Knees'] = 7;

      final first = await h.coordinator.submit(a);

      expect(first.failure!.kind, SignupFailureKind.usernameTaken);
      expect(first.failure!.returnsToPageOne, isTrue);
      expect(first.failure!.message, contains('taken'));
      expect(a.accountCreated, isTrue, reason: 'auth committed before the claim');
      expect((h.hooks as RecordingHooks).completed, isEmpty);
      expect(h.coordinator.takeCompletedUid(), isNull);
      expect(a.draft.onboarding.painSlider['Knees'], 7);
      expect(a.draft.identity.password, 'secret123');

      a.draft.identity.username = 'IronAnna2';
      final second = await h.coordinator.submit(a);

      expect(second.isSuccess, isTrue, reason: '${second.failure}');
      expect(second.uid, a.authUid, reason: 'same intended account');
      expect(h.auth.calls.where((c) => c == 'create'), hasLength(1));
      expect(h.server.holderOf('IronAnna'), 'someone_else');
      final onb = (await h.doc('users/${second.uid}/profile/fitness_onboarding'))!;
      expect(onb['painNow'], {'Knees': 7});
    });

    test('concurrent claimants for one name produce exactly one holder', () async {
      final h = SignupHarness();
      final authB = FakeSignupAuth(uidPrefix: 'uidB');
      final coordinatorB = SignupCoordinator(
        auth: authB,
        backend: FirestoreSignupBackend(
          firestore: h.db,
          claim: (n) => h.server.claim(authB.currentUser?.uid, n),
          ensureMembershipFn: (_) async {},
          cacheDemographicsFn: (uid, {sex, dob}) async {},
          seeder: h.seeder,
        ),
        hooks: RecordingHooks(),
      );
      final a = h.beginFilled(email: 'a@example.test');
      final b = coordinatorB.beginAttempt();
      b.draft.identity
        ..username = 'ironanna' // same name, different case
        ..fullName = 'Anna Lift'
        ..dob = DateTime(1992, 4, 7)
        ..sex = 'F'
        ..email = 'b@example.test'
        ..password = 'secret123';

      final results = await Future.wait([
        h.coordinator.submit(a),
        coordinatorB.submit(b),
      ]);

      final winners = results.where((r) => r.isSuccess).toList();
      final losers = results.where((r) => !r.isSuccess).toList();
      expect(winners, hasLength(1));
      expect(losers.single.failure!.kind, SignupFailureKind.usernameTaken);
      expect(h.server.holderOf('IRONANNA'), winners.single.uid);
    });

    test('the canonical reserved name is never overwritten by the raw input',
        () async {
      final h = SignupHarness();
      // Production normalises with NFKC (e.g. full-width → ASCII).
      h.server.canonicalize = (raw) => raw.trim() == 'ＩｒｏｎＡｎｎａ' ? 'IronAnna' : raw.trim();
      final a = h.beginFilled(username: 'ＩｒｏｎＡｎｎａ');

      final r = await h.coordinator.submit(a);

      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      final user = (await h.doc('users/${r.uid}'))!;
      expect(user['username'], 'IronAnna');
      expect(user['usernameLower'], 'ironanna');
      expect((await h.doc('users_public/${r.uid}'))!['username'], 'IronAnna');
    });
  });

  group('failures are classified, keep inputs and never report success', () {
    Future<SignupFailure> failWithClaimCode(String code) async {
      final h = SignupHarness();
      h.server.failNextWith = code;
      final a = h.beginFilled();
      final r = await h.coordinator.submit(a);
      expect(r.isSuccess, isFalse);
      expect(a.state, SignupAttemptState.editing, reason: 'busy state reset');
      expect(a.draft.identity.username, 'IronAnna');
      expect(a.draft.onboarding.env, 'home');
      expect((h.hooks as RecordingHooks).completed, isEmpty);
      return r.failure!;
    }

    test('permission / unauthenticated', () async {
      for (final code in ['permission-denied', 'unauthenticated']) {
        final f = await failWithClaimCode(code);
        expect(f.kind, SignupFailureKind.permission, reason: code);
        expect(f.retryable, isTrue);
        expect(f.message.toLowerCase(), isNot(contains('connection')));
      }
    });

    test('App Check', () async {
      final f = await failWithClaimCode('app-check-token-invalid');
      expect(f.kind, SignupFailureKind.appCheck);
      expect(f.message.toLowerCase(), isNot(contains('connection')));
    });

    test('backend / configuration (internal, function missing)', () async {
      for (final code in ['internal', 'not-found']) {
        final f = await failWithClaimCode(code);
        expect(f.kind, SignupFailureKind.configuration, reason: code);
        expect(f.message.toLowerCase(), isNot(contains('connection')));
      }
    });

    test('only a genuine network failure mentions the connection', () async {
      final f = await failWithClaimCode('unavailable');
      expect(f.kind, SignupFailureKind.network);
      expect(f.message.toLowerCase(), contains('connection'));
    });

    test('duplicate email returns to Page 1', () async {
      final h = SignupHarness();
      h.auth.seedAccount('anna@example.test', 'other-pass');
      final r = await h.coordinator.submit(h.beginFilled());
      expect(r.failure!.kind, SignupFailureKind.emailInUse);
      expect(r.failure!.returnsToPageOne, isTrue);
    });

    test('a Firestore permission failure at the profile stage', () async {
      final h = SignupHarness();
      h.backend.failNext('profile',
          FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'));
      final r = await h.coordinator.submit(h.beginFilled());
      expect(r.failure!.kind, SignupFailureKind.permission);
      expect(r.failure!.stage, SignupStage.profile);
      expect(h.coordinator.takeCompletedUid(), isNull);
    });

    test('a hung stage times out and resets busy state', () async {
      final h = SignupHarness();
      final c = SignupCoordinator(
        auth: h.auth,
        backend: h.backend,
        hooks: RecordingHooks(),
        authTimeout: const Duration(milliseconds: 50),
      );
      h.auth.holdCreate = Completer<void>(); // never completes
      final a = c.beginAttempt()..draft.identity.email = 'x@example.test';
      final r = await c.submit(a);
      expect(r.failure!.kind, SignupFailureKind.timeout);
      expect(a.isSubmitting, isFalse);
      expect(a.authInFlight, isFalse);
    });
  });

  group('retry safety', () {
    test('auth succeeded, claim failed: retry resumes the same uid and claims',
        () async {
      final h = SignupHarness();
      h.server.failNextWith = 'internal';
      final a = h.beginFilled();

      final first = await h.coordinator.submit(a);
      expect(first.isSuccess, isFalse);
      final uid = a.authUid!;

      final second = await h.coordinator.submit(a);
      expect(second.uid, uid);
      expect(h.auth.calls.where((c) => c == 'create'), hasLength(1));
      await expectFullyOnboarded(h, uid, usernameLower: 'ironanna');
    });

    test('claim committed but the response was lost: own reservation accepted',
        () async {
      final h = SignupHarness();
      h.server.commitThenLoseResponse = true;
      final a = h.beginFilled();

      final first = await h.coordinator.submit(a);
      expect(first.failure!.kind, SignupFailureKind.timeout);
      expect(h.server.holderOf('IronAnna'), a.authUid,
          reason: 'the transaction did commit');

      final second = await h.coordinator.submit(a);
      expect(second.isSuccess, isTrue, reason: '${second.failure}');
      expect(h.server.holderOf('IronAnna'), second.uid);
    });

    test('partial onboarding failure: retry keeps the first createdAt', () async {
      final h = SignupHarness();
      h.backend.failNext('onboarding',
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'));
      final a = h.beginFilled();

      expect((await h.coordinator.submit(a)).isSuccess, isFalse);
      final uid = a.authUid!;
      final firstCreatedAt = (await h.doc('users/$uid'))!['createdAt'];
      expect(firstCreatedAt, isA<Timestamp>());

      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect((await h.coordinator.submit(a)).isSuccess, isTrue);
      expect((await h.doc('users/$uid'))!['createdAt'], firstCreatedAt);
    });

    test('createdAt already on the server is never re-stamped', () async {
      final h = SignupHarness();
      final a = h.beginFilled();
      h.auth.signInAsAnonymous();
      final uid = h.auth.currentUser!.uid;
      final original = Timestamp.fromDate(DateTime(2026, 1, 2));
      await h.db.doc('users/$uid').set({'createdAt': original});

      expect((await h.coordinator.submit(a)).isSuccess, isTrue);
      expect((await h.doc('users/$uid'))!['createdAt'], original);
    });

    test('seeding failed mid-way: retry finishes without duplicate blocks',
        () async {
      final h = SignupHarness();
      h.failSeedDefaultsOnce = true; // Block 1 created, its defaults fail
      final a = h.beginFilled();

      final first = await h.coordinator.submit(a);
      expect(first.failure!.stage, SignupStage.seeding);
      final uid = a.authUid!;
      expect(await h.blockCount(uid), 1);

      final second = await h.coordinator.submit(a);
      expect(second.isSuccess, isTrue, reason: '${second.failure}');
      expect(await h.blockCount(uid), 3);
      final ptr = (await h.doc('users/$uid/block_planner/current_block'))!;
      expect(ptr['blockId'], a.seed.block1Id);
      expect(h.seededBlocks.first, a.seed.block1Id);
    });

    test('blocks left by an unknown earlier attempt are adopted, not duplicated',
        () async {
      final h = SignupHarness();
      h.auth.signInAsAnonymous();
      final uid = h.auth.currentUser!.uid;
      await h.db.collection('users').doc(uid).collection('planned_blocks').doc('b1').set({
        'name': "IronAnna's First Block",
        'isActive': true,
        'startDate': Timestamp.fromDate(DateTime(2026, 10, 12)),
        'endDate': Timestamp.fromDate(DateTime(2027, 4, 11)),
        'templateCandidateExerciseIds': <String>['x'],
      });

      final r = await h.coordinator.submit(h.beginFilled());

      expect(r.isSuccess, isTrue, reason: '${r.failure}');
      expect(await h.blockCount(uid), 1);
      expect((await h.doc('users/$uid/block_planner/current_block'))!['blockId'], 'b1');
    });

    test('a verification miss never reports completion', () async {
      final h = SignupHarness();
      h.backend.failNext('verify', StateError('fitness_onboarding missing'));
      final a = h.beginFilled();
      final r = await h.coordinator.submit(a);
      expect(r.isSuccess, isFalse);
      expect(h.coordinator.takeCompletedUid(), isNull);
      expect((h.hooks as RecordingHooks).completed, isEmpty);
      expect(h.coordinator.holdsAuthRoutingFor(a.authUid!), isTrue,
          reason: 'AppRoot keeps holding an incomplete signup');
    });

    test('duplicate Finish taps share one submission', () async {
      final h = SignupHarness();
      final a = h.beginFilled();
      final f1 = h.coordinator.submit(a);
      final f2 = h.coordinator.submit(a);
      expect(identical(f1, f2), isTrue);
      final rs = await Future.wait([f1, f2]);
      expect(rs.every((r) => r.isSuccess), isTrue);
      expect(h.auth.calls.where((c) => c == 'create'), hasLength(1));
      expect(h.server.calls, 1);
      expect(await h.blockCount(rs.first.uid!), 3);
    });

    test('create committed but its response was lost: the same account is adopted',
        () async {
      final h = SignupHarness();
      h.auth.createCommitsThenDropsResponse = true;
      final a = h.beginFilled();

      final first = await h.coordinator.submit(a);
      expect(first.failure!.kind, SignupFailureKind.network);
      expect(a.authCreateUncertain, isTrue);

      final second = await h.coordinator.submit(a);
      expect(second.isSuccess, isTrue, reason: '${second.failure}');
      expect(h.auth.accounts['anna@example.test']!.uid, second.uid);
    });

    test('an uncertain create never adopts an older existing account', () async {
      final h = SignupHarness();
      final oldUid = h.auth.seedAccount('anna@example.test', 'secret123',
          createdAt: DateTime(2024, 5, 1));
      h.auth.failNextCreate = FirebaseAuthException(code: 'network-request-failed');
      final a = h.beginFilled();

      expect((await h.coordinator.submit(a)).isSuccess, isFalse);
      final second = await h.coordinator.submit(a);

      expect(second.failure!.kind, SignupFailureKind.emailInUse);
      expect(h.auth.currentUser, isNull, reason: 'signed back out');
      expect(await h.doc('users/$oldUid'), isNull,
          reason: 'nothing written to the existing member');
    });

    test('signed out after auth: retry signs back into the SAME account', () async {
      final h = SignupHarness();
      h.server.failNextWith = 'internal';
      final a = h.beginFilled();
      await h.coordinator.submit(a);
      final uid = a.authUid!;
      h.auth.externalSignOut();

      final r = await h.coordinator.submit(a);
      expect(r.uid, uid);
      expect(h.auth.calls, contains('signIn'));
    });

    test('never overwrites an unrelated signed-in account', () async {
      final h = SignupHarness();
      h.auth.seedAccount('member@example.test', 'pw');
      h.auth.signInAs('member@example.test');
      final memberUid = h.auth.currentUser!.uid;

      final r = await h.coordinator.submit(h.beginFilled());

      expect(r.failure!.kind, SignupFailureKind.accountMismatch);
      expect(await h.doc('users/$memberUid'), isNull);
      expect(h.auth.currentUser!.uid, memberUid, reason: 'not signed out');
    });
  });

  group('attempt lifecycle', () {
    test('a new attempt never inherits the previous draft', () async {
      final h = SignupHarness();
      final first = h.beginFilled();
      first.draft.onboarding.injuries.add('Neck');

      final second = h.coordinator.beginAttempt();

      expect(first.state, SignupAttemptState.cancelled);
      expect(first.draft.identity.password, isEmpty);
      expect(second.draft.identity.username, isEmpty);
      expect(second.draft.onboarding.injuries, isEmpty);
      expect(second.draft.onboarding.goals, kDefaultOnboardingGoals);
    });

    test('cancelling after the account exists signs out but deletes nothing',
        () async {
      final h = SignupHarness();
      h.backend.failNext('onboarding', TimeoutException('x'));
      final a = h.beginFilled();
      await h.coordinator.submit(a);
      final uid = a.authUid!;

      await h.coordinator.cancelAttempt(a);

      expect(h.auth.currentUser, isNull);
      expect(h.auth.accounts['anna@example.test']!.uid, uid,
          reason: 'account kept: recoverable by logging in');
      expect(h.server.holderOf('IronAnna'), uid, reason: 'reservation kept');
      expect(a.draft.identity.password, isEmpty);
      expect(h.coordinator.current, isNull);
      expect(h.coordinator.suppressesSignedOutEvents, isTrue,
          reason: 'AppRoot must not swap in the restore spinner');
    });

    test('AppRoot hold applies while creating, and only to this signup', () async {
      final h = SignupHarness();
      final heldDuringCreate = <bool>[];
      h.auth.onAuthEvent = (u) {
        if (u != null) heldDuringCreate.add(h.coordinator.holdsAuthRoutingFor(u.uid));
      };
      final a = h.beginFilled();
      expect(h.coordinator.holdsAuthRoutingFor('someone'), isFalse);

      await h.coordinator.submit(a);

      expect(heldDuringCreate, [true]);
      expect(h.coordinator.holdsAuthRoutingFor(a.authUid!), isFalse,
          reason: 'released on completion');
    });
  });
}
