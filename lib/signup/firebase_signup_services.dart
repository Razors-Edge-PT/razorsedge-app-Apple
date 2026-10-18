/// Production Firebase implementations of the signup boundaries.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth_diag.dart';
import '../auth_signout.dart';
import '../demographics_cache.dart';
import '../membership_gate.dart' show ensureMembershipDoc;
import '../profile/data/identity_repository.dart';
import 'first_block_seeder.dart';
import 'onboarding_models.dart';
import 'onboarding_writer.dart';
import 'signup_coordinator.dart';
import 'signup_pending_store.dart';

/// Thrown by [FirestoreSignupBackend.verifyComplete] when a required document
/// is missing on the server.
class SignupVerificationException implements Exception {
  SignupVerificationException(this.what);
  final String what;
  @override
  String toString() => 'SignupVerificationException: $what';
}

/// The signup view of a Firebase user (AppRoot uses it for recovery checks).
SignupAuthUser signupUserFromFirebase(User u) => _toSignupUser(u);

/// True when [u] signs in with email/password — the only signup provider.
bool isPasswordAccount(User u) =>
    u.providerData.any((p) => p.providerId == EmailAuthProvider.PROVIDER_ID);

SignupAuthUser _toSignupUser(User u) => SignupAuthUser(
      uid: u.uid,
      isAnonymous: u.isAnonymous,
      email: u.email,
      creationTime: u.metadata.creationTime,
    );

class FirebaseSignupAuthGateway implements SignupAuthGateway {
  FirebaseSignupAuthGateway([FirebaseAuth? auth]) : _injected = auth;

  final FirebaseAuth? _injected;
  FirebaseAuth get _auth => _injected ?? FirebaseAuth.instance;

  @override
  SignupAuthUser? get currentUser {
    final u = _auth.currentUser;
    return u == null ? null : _toSignupUser(u);
  }

  @override
  Future<SignupAuthUser> createAccount(String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(
        email: email, password: password);
    return _toSignupUser(cred.user!);
  }

  @override
  Future<SignupAuthUser> linkAnonymous(String email, String password) async {
    final current = _auth.currentUser;
    if (current == null || !current.isAnonymous) {
      return createAccount(email, password);
    }
    final cred = await current.linkWithCredential(
      EmailAuthProvider.credential(email: email, password: password),
    );
    return _toSignupUser(cred.user!);
  }

  @override
  Future<SignupAuthUser> signIn(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(
        email: email, password: password);
    return _toSignupUser(cred.user!);
  }

  @override
  Future<void> updateDisplayName(String name) async {
    await _auth.currentUser?.updateDisplayName(name);
  }

  @override
  Future<void> signOut() => performSignOut(
        reason: SignOutReason.accountCreationCleanup,
        caller: 'SignupCoordinator.cancel',
        google: false,
      );

  /// Same sequence as the drawer's Logout: flag first, then sign out.
  @override
  Future<void> signOutByChoice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('goodlift_explicit_logout', true);
    await performSignOut(
      reason: SignOutReason.explicitLogoutDrawer,
      caller: 'SignupRecovery.signOut',
    );
  }
}

class FirestoreSignupBackend implements SignupBackend {
  FirestoreSignupBackend({
    required FirebaseFirestore firestore,
    Future<UsernameChangeResult> Function(String username)? claim,
    Future<void> Function(String uid)? ensureMembershipFn,
    Future<void> Function(String uid, {String? sex, String? dob})? cacheDemographicsFn,
    FirstBlockSeeder? seeder,
  })  : _db = firestore,
        _claim = claim ?? IdentityRepository.shared.changeUsername,
        _ensureMembership = ensureMembershipFn ??
            ((uid) => ensureMembershipDoc(uid, throwOnError: true)),
        _cacheDemographics = cacheDemographicsFn ??
            ((uid, {sex, dob}) => DemographicsCache.save(uid: uid, sex: sex, dob: dob)),
        _seeder = seeder ?? FirstBlockSeeder(firestore: firestore);

  final FirebaseFirestore _db;
  final Future<UsernameChangeResult> Function(String username) _claim;
  final Future<void> Function(String uid) _ensureMembership;
  final Future<void> Function(String uid, {String? sex, String? dob})
      _cacheDemographics;
  final FirstBlockSeeder _seeder;

  static const _server = GetOptions(source: Source.server);

  @override
  Future<UsernameChangeResult> claimUsername(String username) => _claim(username);

  @override
  Future<void> ensureMembership(String uid) => _ensureMembership(uid);

  @override
  Future<bool> hasCreatedAt(String uid) async {
    final snap = await _db.collection('users').doc(uid).get(_server);
    return snap.data()?['createdAt'] != null;
  }

  @override
  Future<void> writeProfile(String uid, Map<String, dynamic> payload) async {
    await _db.collection('users').doc(uid).set(payload, SetOptions(merge: true));
    await _db
        .collection('users_public')
        .doc(uid)
        .set(payload, SetOptions(merge: true));
  }

  @override
  Future<void> cacheDemographics(String uid, {String? sex, String? dob}) =>
      _cacheDemographics(uid, sex: sex, dob: dob);

  @override
  Future<void> writeOnboarding(String uid, OnboardingSubmission submission) =>
      writeFitnessOnboarding(_db, uid, submission);

  @override
  Future<void> ensureFirstBlock(String uid, SeedProgress progress,
          {String? fallbackName}) =>
      _seeder.ensureForSignup(uid, progress, authFallbackName: fallbackName);

  @override
  Future<void> writeBestEfforts(String uid, List<BestEffort> bestEfforts) =>
      writeBestEffortsToCurrentBlock(_db, uid, bestEfforts);

  DocumentReference<Map<String, dynamic>> _progress(String uid) =>
      _db.collection('users').doc(uid).collection('profile').doc('signup_progress');

  @override
  Future<SignupServerState> signupState(String uid) async {
    final snap = await _progress(uid).get();
    final state = snap.data()?['state'];
    if (state == 'complete') return SignupServerState.complete;
    if (state == 'pending') return SignupServerState.pending;
    return SignupServerState.absent;
  }

  @override
  Future<void> markSignupPending(String uid, {required String attemptId}) =>
      _progress(uid).set({
        'state': 'pending',
        'attemptId': attemptId,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  @override
  Future<void> markSignupComplete(String uid) => _progress(uid).set({
        'state': 'complete',
        'completedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  @override
  Future<RecoverySnapshot> loadExisting(String uid) async {
    final user = (await _db.collection('users').doc(uid).get(_server)).data();
    final onb = (await _db
            .collection('users')
            .doc(uid)
            .collection('profile')
            .doc('fitness_onboarding')
            .get(_server))
        .data();
    String? str(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    return RecoverySnapshot(
      username: str(user?['username']),
      fullName: str(user?['fullName']),
      dob: str(user?['dob']),
      sex: str(user?['sex']),
      onboarding: onb,
    );
  }

  @override
  Future<void> verifyComplete(String uid, {required String usernameLower}) async {
    final user = await _db.collection('users').doc(uid).get(_server);
    final pub = await _db.collection('users_public').doc(uid).get(_server);
    if (user.data()?['usernameLower'] != usernameLower ||
        pub.data()?['usernameLower'] != usernameLower) {
      throw SignupVerificationException('reserved username not on profile');
    }
    if (user.data()?['fullName'] == null || user.data()?['createdAt'] == null) {
      throw SignupVerificationException('profile incomplete');
    }
    final profile = _db.collection('users').doc(uid).collection('profile');
    if (!(await profile.doc('fitness_onboarding').get(_server)).exists) {
      throw SignupVerificationException('fitness_onboarding missing');
    }
    if (!(await profile.doc('membership').get(_server)).exists) {
      throw SignupVerificationException('membership missing');
    }
    await _seeder.verifyPointer(uid);
  }
}

/// Clears the explicit-logout flag and records the password provider once a
/// signup has COMPLETED — the same thing an interactive login does before it
/// signs in. Doing it only now means a failed or abandoned signup never
/// weakens an earlier explicit logout, and Google silent restore is never
/// enabled for this account.
class PrefsSignupSessionHooks implements SignupSessionHooks {
  @override
  Future<void> onSignupCompleted(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('goodlift_explicit_logout', false);
    await prefs.setString('goodlift_last_login_provider', 'password');
    try {
      AuthDiag.afterLogin(provider: 'password(create)', uid: uid);
    } catch (_) {
      // Diagnostic only; never fails a completed signup.
    }
  }
}

/// The app-wide coordinator wired to Firebase.
SignupCoordinator createFirebaseSignupCoordinator() => SignupCoordinator(
      auth: FirebaseSignupAuthGateway(),
      backend: FirestoreSignupBackend(firestore: FirebaseFirestore.instance),
      hooks: PrefsSignupSessionHooks(),
      pendingStore: PrefsSignupPendingStore(),
      usernameHint: (raw) async {
        // The reservation index needs a signed-in caller. With no session the
        // honest answer is "unknown" — completion still requires the server
        // reservation, so nothing is lost by not guessing.
        if (FirebaseAuth.instance.currentUser == null) return null;
        return IdentityRepository.shared.isProbablyAvailable(raw);
      },
    );
