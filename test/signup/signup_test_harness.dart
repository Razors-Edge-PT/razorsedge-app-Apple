// Test doubles for the signup boundaries.
//
// The backend under test is the PRODUCTION FirestoreSignupBackend writing to a
// FakeFirebaseFirestore, so persisted shapes are the real ones. Only the true
// external edges are faked:
//
//  * FakeSignupAuth        — Firebase Auth (accounts, sessions, failures);
//  * FakeReservationServer — the profileChangeUsername callable, implementing
//                            the same decision rules as
//                            functions/identity/reservation.js and writing
//                            username/usernameLower onto both user documents
//                            exactly as the callable's transaction does;
//  * FlakySignupBackend    — injects failures at chosen stages.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:localtest222/profile/data/identity_repository.dart';
import 'package:localtest222/signup/first_block_seeder.dart';
import 'package:localtest222/signup/firebase_signup_services.dart';
import 'package:localtest222/signup/onboarding_models.dart';
import 'package:localtest222/signup/signup_coordinator.dart';
import 'package:localtest222/signup/signup_pending_store.dart';

class FakeAccount {
  FakeAccount(this.uid, this.password, this.creationTime);
  final String uid;
  final String password;
  final DateTime creationTime;
}

class FakeSignupAuth implements SignupAuthGateway {
  FakeSignupAuth({DateTime Function()? clock, this.uidPrefix = 'uid'})
      : _clock = clock ?? DateTime.now;

  final String uidPrefix;

  final DateTime Function() _clock;
  final Map<String, FakeAccount> accounts = <String, FakeAccount>{};
  SignupAuthUser? _current;
  int _seq = 0;

  final List<String> calls = <String>[];

  /// Called synchronously when an auth call changes the signed-in user,
  /// BEFORE the call returns — like authStateChanges racing the future.
  void Function(SignupAuthUser? user)? onAuthEvent;

  /// Next createAccount throws this instead of creating.
  FirebaseAuthException? failNextCreate;

  /// Next createAccount creates the account, then loses the response.
  bool createCommitsThenDropsResponse = false;

  /// When set, createAccount waits for this before completing.
  Completer<void>? holdCreate;

  /// Pre-existing account (another member, or an earlier signup).
  String seedAccount(String email, String password, {DateTime? createdAt}) {
    final uid = 'existing_${++_seq}';
    accounts[email] = FakeAccount(uid, password, createdAt ?? DateTime(2025, 1, 1));
    return uid;
  }

  void signInAsAnonymous() {
    _current = SignupAuthUser(uid: 'anon_${++_seq}', isAnonymous: true);
  }

  void signInAs(String email) {
    final a = accounts[email]!;
    _current = SignupAuthUser(
        uid: a.uid, isAnonymous: false, email: email, creationTime: a.creationTime);
  }

  /// Simulates something outside signup signing the device out.
  void externalSignOut() => _current = null;

  @override
  SignupAuthUser? get currentUser => _current;

  void _setCurrent(SignupAuthUser? u) {
    _current = u;
    onAuthEvent?.call(u);
  }

  @override
  Future<SignupAuthUser> createAccount(String email, String password) async {
    calls.add('create');
    final hold = holdCreate;
    if (hold != null) await hold.future;
    final fail = failNextCreate;
    if (fail != null) {
      failNextCreate = null;
      throw fail;
    }
    if (accounts.containsKey(email)) {
      throw FirebaseAuthException(code: 'email-already-in-use');
    }
    final uid = '${uidPrefix}_${++_seq}';
    final created = _clock();
    accounts[email] = FakeAccount(uid, password, created);
    if (createCommitsThenDropsResponse) {
      createCommitsThenDropsResponse = false;
      throw FirebaseAuthException(code: 'network-request-failed');
    }
    final u = SignupAuthUser(
        uid: uid, isAnonymous: false, email: email, creationTime: created);
    _setCurrent(u);
    return u;
  }

  @override
  Future<SignupAuthUser> linkAnonymous(String email, String password) async {
    calls.add('link');
    final anon = _current;
    if (anon == null || !anon.isAnonymous) return createAccount(email, password);
    if (accounts.containsKey(email)) {
      throw FirebaseAuthException(code: 'credential-already-in-use');
    }
    final created = _clock();
    accounts[email] = FakeAccount(anon.uid, password, created);
    final u = SignupAuthUser(
        uid: anon.uid, isAnonymous: false, email: email, creationTime: created);
    _current = u; // linking does not emit authStateChanges
    return u;
  }

  @override
  Future<SignupAuthUser> signIn(String email, String password) async {
    calls.add('signIn');
    final a = accounts[email];
    if (a == null) throw FirebaseAuthException(code: 'user-not-found');
    if (a.password != password) {
      throw FirebaseAuthException(code: 'wrong-password');
    }
    final u = SignupAuthUser(
        uid: a.uid, isAnonymous: false, email: email, creationTime: a.creationTime);
    _setCurrent(u);
    return u;
  }

  @override
  Future<void> updateDisplayName(String name) async => calls.add('displayName');

  @override
  Future<void> signOut() async {
    calls.add('signOut');
    _setCurrent(null);
  }

  @override
  Future<void> signOutByChoice() async {
    calls.add('signOutByChoice');
    _setCurrent(null);
  }
}

/// The profileChangeUsername transaction, in memory. Decision rules mirror
/// functions/identity/reservation.js; writes mirror functions/identity/index.js.
class FakeReservationServer {
  FakeReservationServer(this.db);

  final FakeFirebaseFirestore db;

  /// The server's display normalisation (NFKC in production). Tests can
  /// substitute a mapping to prove the client keeps the canonical value.
  String Function(String raw) canonicalize = (raw) => raw.trim();

  /// usernameLower → holder uid.
  final Map<String, String> holders = <String, String>{};
  final Map<String, String> displayFor = <String, String>{};
  final Map<String, String> currentLowerByUid = <String, String>{};
  int calls = 0;

  /// Next call fails with this callable code without committing.
  String? failNextWith;

  /// Next call commits, then the client loses the response (deadline).
  bool commitThenLoseResponse = false;

  String _norm(String raw) => canonicalize(raw).toLowerCase();

  /// Another member holding [name] already.
  void reserve(String name, String uid) {
    holders[_norm(name)] = uid;
    displayFor[_norm(name)] = name.trim();
  }

  String? holderOf(String name) => holders[_norm(name)];

  Future<UsernameChangeResult> claim(String? callerUid, String raw) async {
    calls++;
    final fail = failNextWith;
    if (fail != null) {
      failNextWith = null;
      return UsernameChangeResult(UsernameChangeOutcome.failed, errorCode: fail);
    }
    if (callerUid == null) {
      return const UsernameChangeResult(UsernameChangeOutcome.failed,
          errorCode: 'unauthenticated');
    }
    final display = canonicalize(raw);
    final lower = _norm(raw);
    if (display.length < 3 || display.length > 22 || display.contains(' ')) {
      return const UsernameChangeResult(UsernameChangeOutcome.invalid,
          errorCode: 'invalid-argument');
    }
    final holder = holders[lower];
    if (holder != null && holder != callerUid) {
      return const UsernameChangeResult(UsernameChangeOutcome.taken,
          errorCode: 'already-exists');
    }
    // Decide and reserve with no await in between: the real callable does
    // this inside one Firestore transaction, so it is atomic.
    final currentLower = currentLowerByUid[callerUid];
    final exact = holder == callerUid &&
        currentLower == lower &&
        displayFor[lower] == display;
    if (!exact) {
      // Release the caller's previous name when genuinely theirs.
      if (currentLower != null &&
          currentLower != lower &&
          holders[currentLower] == callerUid) {
        holders.remove(currentLower);
      }
      holders[lower] = callerUid;
      displayFor[lower] = display;
      currentLowerByUid[callerUid] = lower;
      final ids = {'username': display, 'usernameLower': lower};
      await db.collection('users').doc(callerUid).set(ids, SetOptions(merge: true));
      await db.collection('users_public').doc(callerUid).set(
          {...ids, 'displayName': display}, SetOptions(merge: true));
    }
    if (commitThenLoseResponse) {
      commitThenLoseResponse = false;
      return const UsernameChangeResult(UsernameChangeOutcome.needsConnection,
          errorCode: 'deadline-exceeded');
    }
    return UsernameChangeResult(
      exact ? UsernameChangeOutcome.unchanged : UsernameChangeOutcome.changed,
      username: display,
      usernameLower: lower,
    );
  }
}

/// Decorates a backend so chosen stages fail a set number of times.
class FlakySignupBackend implements SignupBackend {
  FlakySignupBackend(this.inner);

  final SignupBackend inner;
  final Map<String, List<Object>> _failures = <String, List<Object>>{};
  final Map<String, int> calls = <String, int>{};

  /// The next call to [stage] throws [error] (queue several to fail repeatedly).
  void failNext(String stage, Object error) =>
      (_failures[stage] ??= <Object>[]).add(error);

  Future<T> _run<T>(String stage, Future<T> Function() body) async {
    calls[stage] = (calls[stage] ?? 0) + 1;
    final queue = _failures[stage];
    if (queue != null && queue.isNotEmpty) throw queue.removeAt(0);
    return body();
  }

  @override
  Future<UsernameChangeResult> claimUsername(String username) =>
      _run('claim', () => inner.claimUsername(username));
  @override
  Future<void> ensureMembership(String uid) =>
      _run('membership', () => inner.ensureMembership(uid));
  @override
  Future<bool> hasCreatedAt(String uid) =>
      _run('hasCreatedAt', () => inner.hasCreatedAt(uid));
  @override
  Future<void> writeProfile(String uid, Map<String, dynamic> payload) =>
      _run('profile', () => inner.writeProfile(uid, payload));
  @override
  Future<void> cacheDemographics(String uid, {String? sex, String? dob}) =>
      _run('demographics', () => inner.cacheDemographics(uid, sex: sex, dob: dob));
  @override
  Future<void> writeOnboarding(String uid, OnboardingSubmission submission) =>
      _run('onboarding', () => inner.writeOnboarding(uid, submission));
  @override
  Future<void> ensureFirstBlock(String uid, SeedProgress progress,
          {String? fallbackName}) =>
      _run('seed',
          () => inner.ensureFirstBlock(uid, progress, fallbackName: fallbackName));
  @override
  Future<void> writeBestEfforts(String uid, List<BestEffort> bestEfforts) =>
      _run('bestEfforts', () => inner.writeBestEfforts(uid, bestEfforts));
  @override
  Future<void> verifyComplete(String uid, {required String usernameLower}) =>
      _run('verify', () => inner.verifyComplete(uid, usernameLower: usernameLower));
  @override
  Future<SignupServerState> signupState(String uid) =>
      _run('signupState', () => inner.signupState(uid));
  @override
  Future<void> markSignupPending(String uid, {required String attemptId}) =>
      _run('markPending', () => inner.markSignupPending(uid, attemptId: attemptId));
  @override
  Future<void> markSignupComplete(String uid) =>
      _run('markComplete', () => inner.markSignupComplete(uid));
  @override
  Future<RecoverySnapshot> loadExisting(String uid) =>
      _run('loadExisting', () => inner.loadExisting(uid));
}

class RecordingHooks implements SignupSessionHooks {
  final List<String> completed = <String>[];
  @override
  Future<void> onSignupCompleted(String uid) async => completed.add(uid);
}

/// A complete signup stack over fakes, using the production backend.
class SignupHarness {
  SignupHarness({SignupSessionHooks? hooks, SignupPendingStore? store}) {
    pendingStore = store ?? MemorySignupPendingStore();
    db = FakeFirebaseFirestore();
    auth = FakeSignupAuth();
    server = FakeReservationServer(db);
    this.hooks = hooks ?? RecordingHooks();
    seeder = FirstBlockSeeder(
      firestore: db,
      seedDefaults: ({required uid, required blockId, required exerciseIds}) async {
        if (failSeedDefaultsOnce) {
          failSeedDefaultsOnce = false;
          throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
        }
        seededBlocks.add(blockId);
      },
      scaffold: (ref, start, {startWeek = 0}) async {},
    );
    backend = FlakySignupBackend(FirestoreSignupBackend(
      firestore: db,
      claim: (name) => server.claim(auth.currentUser?.uid, name),
      ensureMembershipFn: (uid) async {
        final ref = db.collection('users').doc(uid).collection('profile').doc('membership');
        if (!(await ref.get()).exists) {
          await ref.set({
            'active': false,
            'status': 'inactive',
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      },
      cacheDemographicsFn: (uid, {sex, dob}) async {},
      seeder: seeder,
    ));
    coordinator = relaunch();
  }

  /// A fresh coordinator over the same persisted state (Firestore, Auth
  /// session, device store) — what the app has after termination/relaunch.
  SignupCoordinator relaunch() {
    return SignupCoordinator(
      auth: auth,
      backend: backend,
      hooks: hooks,
      pendingStore: pendingStore,
      usernameHint: (raw) async {
        if (auth.currentUser == null) return null; // logged out: unknown
        final holder = server.holderOf(raw);
        return holder == null || holder == auth.currentUser!.uid;
      },
    );
  }

  late final SignupPendingStore pendingStore;

  late final FakeFirebaseFirestore db;
  late final FakeSignupAuth auth;
  late final FakeReservationServer server;
  late final SignupSessionHooks hooks;
  late final FirstBlockSeeder seeder;
  late final FlakySignupBackend backend;
  late SignupCoordinator coordinator;
  final List<String> seededBlocks = <String>[];

  /// The next defaults seed throws (after its block document was created).
  bool failSeedDefaultsOnce = false;

  /// Fills the draft with a complete, valid signup.
  SignupAttempt beginFilled({
    String username = 'IronAnna',
    String email = 'anna@example.test',
    String password = 'secret123',
  }) {
    final a = coordinator.beginAttempt();
    a.draft.identity
      ..username = username
      ..fullName = 'Anna Lift'
      ..dob = DateTime(1992, 4, 7)
      ..sex = 'F'
      ..email = email
      ..password = password
      ..confirmPassword = password;
    a.draft.onboarding
      ..experience = TrainingExperience.oneYear
      ..env = 'home'
      ..minTrainingDays = 4;
    return a;
  }

  Future<Map<String, dynamic>?> doc(String path) async =>
      (await db.doc(path).get()).data();

  Future<int> blockCount(String uid) async =>
      (await db.collection('users').doc(uid).collection('planned_blocks').get())
          .docs
          .length;
}
