/// Owns a GoodLift signup from Page 1 to a fully set-up account.
///
/// ── Why this exists ─────────────────────────────────────────────────────────
/// Signup used to be driven from inside Page 2's State:
///
///  * Finish ran a pre-auth `users_public` availability read. Those reads
///    require a signed-in caller, the anonymous session Page 1 tried to open
///    for them cannot exist (anonymous sign-in is not enabled on the
///    project), so the read was permission-denied on every logged-out device
///    and Finish stopped with "check your connection".
///  * "Has a non-anonymous currentUser" stood in for "signup completed", so a
///    retry after auth succeeded but the username claim failed skipped the
///    claim and the createdAt stamp.
///  * AppRoot switched navigators the moment auth succeeded — destroying
///    Page 2 mid-setup — and, after an explicit logout, signed the brand-new
///    member straight back out because nothing on the Finish path cleared
///    the logout flag.
///  * Page 2 answers lived only in the Page 2 State, so Back lost them.
///
/// ── What it does instead ────────────────────────────────────────────────────
/// A [SignupAttempt] carries the draft and an explicit record of which setup
/// steps have committed. [submit] runs them in order, each idempotent and
/// time-bounded, and is single-flight:
///
///   1. auth      create the account (or upgrade an existing anonymous
///                session, or resume the SAME uid this attempt created), and
///                record it as a pending signup on the server and device;
///   2. claim     reserve the username through `profileChangeUsername` — the
///                one transactional authority. No name is accepted on
///                "unknown": completion requires a successful reservation;
///   3. membership / profile / onboarding / first block;
///   4. verify    read everything back from the server, mark it complete;
///   5. complete  hand the session to AppRoot.
///
/// While an attempt owns the auth session AppRoot holds its routing, so
/// nothing can interrupt mandatory setup, and it routes to the normal
/// destination only after step 5.
///
/// ── Recovery ────────────────────────────────────────────────────────────────
/// An account can exist with setup unfinished: the member cancelled after
/// the account was created, the app was terminated, or an auth request that
/// timed out succeeded later. Such an account is marked pending on the
/// server (users/{uid}/profile/signup_progress) and on the device
/// ([SignupPendingStore]); [evaluateRecovery] finds it at the next launch or
/// login and [beginRecovery] resumes the missing setup on the signed-in
/// session. No password is ever persisted or needed to resume.
///
/// An auth request is tracked until IT settles, not until its timeout:
/// Future.timeout does not cancel the request, so its account may still
/// appear. Until then AppRoot keeps holding, a retry waits for it instead of
/// creating a second account, and a late success is adopted by the attempt
/// (or, if the member already left, signed out and left recoverable).
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../onboarding_identity_payload.dart';
import '../profile/data/identity_repository.dart';
import '../profile/data/username_rules.dart' show normalizeUsername;
import 'first_block_seeder.dart';
import 'onboarding_models.dart';
import 'signup_draft.dart';
import 'signup_errors.dart';
import 'signup_pending_store.dart';

// ── Boundaries ──────────────────────────────────────────────────────────────

@immutable
class SignupAuthUser {
  const SignupAuthUser({
    required this.uid,
    required this.isAnonymous,
    this.email,
    this.creationTime,
  });

  final String uid;
  final bool isAnonymous;
  final String? email;
  final DateTime? creationTime;
}

/// Firebase Auth operations signup needs. Implementations throw
/// FirebaseAuthException on failure.
abstract class SignupAuthGateway {
  SignupAuthUser? get currentUser;
  Future<SignupAuthUser> createAccount(String email, String password);
  Future<SignupAuthUser> linkAnonymous(String email, String password);
  Future<SignupAuthUser> signIn(String email, String password);
  Future<void> updateDisplayName(String name);

  /// Housekeeping sign-out (cancelled signup, orphaned late account).
  Future<void> signOut();

  /// The member chose to sign out: an explicit logout.
  Future<void> signOutByChoice();
}

/// Server record of a signup's setup.
enum SignupServerState { pending, complete, absent }

/// What already exists for an account whose setup is being resumed.
@immutable
class RecoverySnapshot {
  const RecoverySnapshot({
    this.username,
    this.fullName,
    this.dob,
    this.sex,
    this.onboarding,
  });

  final String? username;
  final String? fullName;

  /// `dd-mm-yyyy`, as stored.
  final String? dob;
  final String? sex;

  /// users/{uid}/profile/fitness_onboarding, when present.
  final Map<String, dynamic>? onboarding;
}

/// Backend operations signup needs. Every write must be idempotent.
abstract class SignupBackend {
  Future<UsernameChangeResult> claimUsername(String username);
  Future<void> ensureMembership(String uid);
  Future<bool> hasCreatedAt(String uid);
  Future<void> writeProfile(String uid, Map<String, dynamic> payload);
  Future<void> cacheDemographics(String uid, {String? sex, String? dob});
  Future<void> writeOnboarding(String uid, OnboardingSubmission submission);
  Future<void> ensureFirstBlock(String uid, SeedProgress progress,
      {String? fallbackName});
  Future<void> writeBestEfforts(String uid, List<BestEffort> bestEfforts);

  /// Throws unless identity, onboarding, membership and the current block are
  /// all present on the server.
  Future<void> verifyComplete(String uid, {required String usernameLower});

  Future<SignupServerState> signupState(String uid);
  Future<void> markSignupPending(String uid, {required String attemptId});
  Future<void> markSignupComplete(String uid);
  Future<RecoverySnapshot> loadExisting(String uid);
}

/// Device-session side effects of a completed signup (the explicit-logout
/// flag and last-login provider AppRoot consults).
abstract class SignupSessionHooks {
  Future<void> onSignupCompleted(String uid);
}

/// AppRoot's answer for a signed-in account.
@immutable
class SignupRecoveryDecision {
  const SignupRecoveryDecision.none()
      : resume = false,
        trustedDevice = false;
  const SignupRecoveryDecision.resume({required this.trustedDevice})
      : resume = true;

  /// The account's signup setup is unfinished: route to recovery.
  final bool resume;

  /// This device's own signup created the account (local marker), so an
  /// earlier explicit logout on this device does not apply to it.
  final bool trustedDevice;
}

/// How long after creation an account without a local marker is still
/// checked for a pending signup. Older accounts are never read at all, so
/// established members' login costs nothing extra.
const Duration kSignupRecoveryWindow = Duration(days: 45);

// ── Attempt ─────────────────────────────────────────────────────────────────

enum SignupAttemptState { editing, submitting, completed, cancelled }

/// What an auth request is for, which decides what a late success means.
enum _AuthPurpose { create, resumeOwned, probe }

class SignupAttempt {
  SignupAttempt._(this.id, this.startedAt, this.owner, {this.isRecovery = false});

  /// The coordinator that runs this attempt.
  final SignupCoordinator owner;

  /// Correlation id for diagnostics. Not personal data.
  final String id;
  final DateTime startedAt;
  final SignupDraft draft = SignupDraft();

  /// Resuming setup for an existing, signed-in account (no credentials).
  final bool isRecovery;

  SignupAttemptState state = SignupAttemptState.editing;

  /// The account this attempt created or upgraded. Once set, every retry
  /// must resume exactly this uid.
  String? authUid;

  int _authBusy = 0;
  Future<SignupAuthUser>? _pendingAuth;

  /// An auth decision is running, or an auth request has not settled (its
  /// account and auth event may still arrive, even after its timeout).
  bool get authInFlight => _authBusy > 0 || _pendingAuth != null;

  /// An account-creation call failed in a way that does not prove the
  /// account was NOT created (timeout / dropped connection).
  bool authCreateUncertain = false;

  /// The canonical reserved username returned by the server, and the exact
  /// raw name it was claimed for.
  String? claimedUsername;
  String? claimedUsernameLower;
  String? claimedFor;

  bool serverMarkerWritten = false;
  bool membershipEnsured = false;
  bool createdAtCommitted = false;
  final SeedProgress seed = SeedProgress();

  SignupFailure? lastFailure;
  Future<SignupResult>? _inFlight;

  bool get isActive =>
      state == SignupAttemptState.editing ||
      state == SignupAttemptState.submitting;
  bool get isSubmitting => state == SignupAttemptState.submitting;
  bool get accountCreated => authUid != null;
}

@immutable
class SignupResult {
  const SignupResult.success(this.uid) : failure = null;
  const SignupResult.failed(SignupFailure this.failure) : uid = null;

  final String? uid;
  final SignupFailure? failure;
  bool get isSuccess => failure == null;
}

class _SignupAbort implements Exception {
  _SignupAbort(this.failure);
  final SignupFailure failure;
}

// ── Coordinator ─────────────────────────────────────────────────────────────

class SignupCoordinator extends ChangeNotifier {
  SignupCoordinator({
    required SignupAuthGateway auth,
    required SignupBackend backend,
    required SignupSessionHooks hooks,
    SignupPendingStore? pendingStore,
    Future<bool?> Function(String raw)? usernameHint,
    this.authTimeout = const Duration(seconds: 30),
    this.stageTimeout = const Duration(seconds: 30),
    this.seedTimeout = const Duration(seconds: 60),
    this.recoveryCheckTimeout = const Duration(seconds: 5),
    DateTime Function()? clock,
  })  : _auth = auth,
        _backend = backend,
        _hooks = hooks,
        _store = pendingStore ?? MemorySignupPendingStore(),
        _usernameHint = usernameHint,
        _clock = clock ?? DateTime.now;

  final SignupAuthGateway _auth;
  final SignupBackend _backend;
  final SignupSessionHooks _hooks;
  final SignupPendingStore _store;
  final Future<bool?> Function(String raw)? _usernameHint;
  final DateTime Function() _clock;

  final Duration authTimeout;
  final Duration stageTimeout;
  final Duration seedTimeout;
  final Duration recoveryCheckTimeout;

  static SignupCoordinator? _instance;

  /// The app-wide coordinator, installed by main() before runApp.
  static SignupCoordinator get instance {
    final c = _instance;
    if (c == null) {
      throw StateError('SignupCoordinator.install() has not been called');
    }
    return c;
  }

  static bool get isInstalled => _instance != null;

  static void install(SignupCoordinator coordinator) => _instance = coordinator;

  @visibleForTesting
  static void debugReset() => _instance = null;

  SignupAttempt? _current;
  String? _completedUid;
  DateTime? _signOutGraceUntil;

  /// Cancelled attempts whose auth request has not settled yet.
  final Set<SignupAttempt> _draining = <SignupAttempt>{};

  /// Late accounts nobody owns, being signed out.
  final Set<String> _orphanSignOuts = <String>{};

  /// The attempt currently in progress, if any.
  SignupAttempt? get current => _current;

  // ── Attempt lifecycle ────────────────────────────────────────────────────

  /// Starts a fresh attempt with an empty draft. Any previous unfinished
  /// attempt is cancelled first, so a new member never inherits a draft.
  SignupAttempt beginAttempt() {
    _retireCurrent();
    final attempt = SignupAttempt._(_newAttemptId(), _clock(), this);
    _current = attempt;
    _log(attempt, 'begin');
    notifyListeners();
    return attempt;
  }

  /// Resumes setup for the signed-in account [uid], whose signup was left
  /// unfinished. The draft starts empty; [loadRecovery] fills it from what
  /// the server already holds.
  SignupAttempt beginRecovery(String uid) {
    _retireCurrent();
    final attempt =
        SignupAttempt._(_newAttemptId(), _clock(), this, isRecovery: true)
          ..authUid = uid;
    final email = _auth.currentUser?.uid == uid ? _auth.currentUser?.email : null;
    attempt.draft.identity.email = email ?? '';
    _current = attempt;
    _log(attempt, 'begin recovery');
    notifyListeners();
    return attempt;
  }

  void _retireCurrent() {
    final previous = _current;
    if (previous != null && previous.isActive) {
      unawaited(cancelAttempt(previous));
    }
  }

  /// Fills a recovery attempt's draft from the server. Returns false when
  /// the existing data could not be read (the member can still fill it in).
  Future<bool> loadRecovery(SignupAttempt attempt) async {
    final uid = attempt.authUid;
    if (uid == null) return false;
    final RecoverySnapshot snap;
    try {
      snap = await _backend.loadExisting(uid).timeout(stageTimeout);
    } catch (e) {
      debugPrint('[Signup ${attempt.id}] recovery load failed: ${e.runtimeType}');
      return false;
    }
    final identity = attempt.draft.identity;
    identity
      ..username = snap.username ?? identity.username
      ..fullName = snap.fullName ?? identity.fullName
      ..sex = snap.sex ?? identity.sex
      ..dob = _parseStoredDob(snap.dob) ?? identity.dob;
    final onboarding = snap.onboarding;
    if (onboarding != null) attempt.draft.onboarding.loadFromFirestore(onboarding);
    notifyListeners();
    return true;
  }

  static DateTime? _parseStoredDob(String? dob) {
    if (dob == null) return null;
    final m = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$').firstMatch(dob.trim());
    if (m == null) return null;
    return DateTime(int.parse(m.group(3)!), int.parse(m.group(2)!),
        int.parse(m.group(1)!));
  }

  /// Genuine cancellation (the member left signup). Wipes the draft. If this
  /// attempt already created an account, that account is signed out — never
  /// deleted, and its reservation is left in place — and stays marked
  /// pending, so its setup resumes at the next login.
  Future<void> cancelAttempt(SignupAttempt attempt) async {
    if (attempt.isSubmitting) {
      try {
        await attempt._inFlight;
      } catch (_) {}
    }
    if (attempt.state == SignupAttemptState.completed) {
      if (identical(_current, attempt)) _current = null;
      return;
    }
    if (attempt.state == SignupAttemptState.cancelled) return;

    attempt.state = SignupAttemptState.cancelled;
    attempt.draft.wipeSecrets();
    if (identical(_current, attempt)) _current = null;
    _log(attempt, 'cancel accountCreated=${attempt.accountCreated}');

    if (attempt._pendingAuth != null) {
      // Its account may still appear; keep holding until the request settles.
      _draining.add(attempt);
    } else if (attempt.authUid == null && !attempt.authCreateUncertain) {
      // No account can exist for this attempt: nothing to recover.
      await _clearMarkerFor(attempt);
    }

    final uid = attempt.authUid;
    if (!attempt.isRecovery && uid != null && _auth.currentUser?.uid == uid) {
      await _housekeepingSignOut();
    }
    notifyListeners();
  }

  // ── AppRoot coordination ─────────────────────────────────────────────────

  /// True while a signup owns the auth session for [uid]: AppRoot must not
  /// route, gate or sign out that user. This includes an auth request that
  /// timed out but has not settled — its account may still appear.
  bool holdsAuthRoutingFor(String uid) {
    if (_orphanSignOuts.contains(uid)) return true;
    for (final a in _draining) {
      if (a.authInFlight) return true;
    }
    final a = _current;
    if (a == null || !a.isActive) return false;
    return a.authInFlight || a.authUid == uid;
  }

  /// True while signed-out/anonymous auth events must not tear down the
  /// signup navigator (an attempt is active, or a cancel just signed out).
  bool get suppressesSignedOutEvents {
    if (_current?.isActive == true) return true;
    final until = _signOutGraceUntil;
    return until != null && _clock().isBefore(until);
  }

  /// The uid of a signup that has just completed, once. AppRoot routes it.
  String? takeCompletedUid() {
    final uid = _completedUid;
    _completedUid = null;
    return uid;
  }

  /// Decides whether [user]'s signup setup is unfinished. Established
  /// members (no local marker, account older than [kSignupRecoveryWindow],
  /// or not a password account) are answered without any network read.
  Future<SignupRecoveryDecision> evaluateRecovery(
    SignupAuthUser user, {
    required bool passwordProvider,
  }) async {
    if (user.isAnonymous) return const SignupRecoveryDecision.none();
    try {
      if (await _store.isSettled(user.uid)) {
        return const SignupRecoveryDecision.none();
      }
    } catch (_) {}

    LocalSignupMarker? local;
    try {
      local = await _store.read();
    } catch (_) {}
    final localMatch = _markerMatches(local, user);
    final created = user.creationTime;
    final young = passwordProvider &&
        created != null &&
        _clock().difference(created) < kSignupRecoveryWindow;
    if (!localMatch && !young) return const SignupRecoveryDecision.none();

    if (localMatch && local!.uid == null) {
      await _writeMarker(local.withUid(user.uid));
    }

    SignupServerState? state;
    try {
      state = await _backend.signupState(user.uid).timeout(recoveryCheckTimeout);
    } catch (e) {
      debugPrint('[Signup] recovery check failed: ${e.runtimeType}');
    }

    switch (state) {
      case SignupServerState.complete:
        await _settle(user.uid);
        return const SignupRecoveryDecision.none();
      case SignupServerState.pending:
        return SignupRecoveryDecision.resume(trustedDevice: localMatch);
      case SignupServerState.absent:
        if (localMatch) return const SignupRecoveryDecision.resume(trustedDevice: true);
        // Not a signup this app version started: an ordinary account.
        await _settle(user.uid);
        return const SignupRecoveryDecision.none();
      case null:
        // Unknown. Only this device's own unfinished signup is resumed on
        // that basis; anything else is let through and re-checked next time.
        return localMatch
            ? const SignupRecoveryDecision.resume(trustedDevice: true)
            : const SignupRecoveryDecision.none();
    }
  }

  bool _markerMatches(LocalSignupMarker? m, SignupAuthUser user) {
    if (m == null) return false;
    if (m.uid != null) return m.uid == user.uid;
    final email = user.email;
    final created = user.creationTime;
    return email != null &&
        created != null &&
        m.emailHash == signupEmailHash(email) &&
        !created.isBefore(m.startedAt.subtract(const Duration(minutes: 2)));
  }

  // ── Page 1 advisory availability ─────────────────────────────────────────

  /// Advisory only: true/false from the reservation index, or null when it
  /// cannot be known (no session, offline, timeout). Never a gate on
  /// completion — [submit] always requires a successful server reservation.
  Future<bool?> usernameHint(String raw) async {
    final hint = _usernameHint;
    if (hint == null) return null;
    try {
      return await hint(raw).timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  /// The member chose to sign out of an unfinished account. It stays pending
  /// and resumes at the next login.
  Future<void> signOutByChoice(SignupAttempt attempt) async {
    attempt.draft.wipeSecrets();
    await _auth.signOutByChoice();
  }

  // ── Completion ───────────────────────────────────────────────────────────

  /// Runs (or resumes) setup for [attempt]. Concurrent calls share one run.
  Future<SignupResult> submit(SignupAttempt attempt) {
    final running = attempt._inFlight;
    if (running != null) return running;
    if (!attempt.isActive || !identical(_current, attempt)) {
      return Future<SignupResult>.value(const SignupResult.failed(
          SignupFailure(SignupFailureKind.unknown,
              stage: SignupStage.auth, code: 'attempt-not-active')));
    }
    attempt.state = SignupAttemptState.submitting;
    attempt.lastFailure = null;
    notifyListeners();
    final future = _run(attempt).whenComplete(() {
      attempt._inFlight = null;
      notifyListeners();
    });
    attempt._inFlight = future;
    return future;
  }

  Future<SignupResult> _run(SignupAttempt a) async {
    final identity = a.draft.identity;
    final email = identity.email.trim();
    final password = identity.password;
    final username = identity.username.trim();
    final fullName = identity.fullName.trim();
    final sex = identity.sex;
    final dob = identity.dobStorage;
    final submission = OnboardingSubmission.fromForm(a.draft.onboarding);

    try {
      final uid = await _ensureAuth(a, email, password, username);

      if (!a.serverMarkerWritten) {
        await _stage(a, SignupStage.auth, stageTimeout,
            () => _backend.markSignupPending(uid, attemptId: a.id));
        a.serverMarkerWritten = true;
      }

      await _claim(a, username);
      final usernameLower = a.claimedUsernameLower!;

      if (!a.membershipEnsured) {
        await _stage(a, SignupStage.membership, stageTimeout,
            () => _backend.ensureMembership(uid));
        a.membershipEnsured = true;
      }

      await _stage(a, SignupStage.profile, stageTimeout, () async {
        if (!a.createdAtCommitted && await _backend.hasCreatedAt(uid)) {
          a.createdAtCommitted = true;
        }
        final stamp = !a.createdAtCommitted;
        // username / usernameLower / displayName are deliberately absent:
        // the callable wrote the canonical reserved values, and rewriting
        // them from the raw input could only disagree with the reservation
        // (the rules also refuse a differing identity write).
        final payload = <String, dynamic>{
          'email': _auth.currentUser?.email ?? email,
          ...buildIdentityPayloadFields(fullName: fullName, sex: sex, dob: dob),
          ...buildCreatedAtField(isNewAccount: stamp),
        };
        await _backend.writeProfile(uid, payload);
        if (stamp) a.createdAtCommitted = true;
        await _backend.cacheDemographics(uid, sex: sex, dob: dob);
      });

      await _stage(a, SignupStage.onboarding, stageTimeout,
          () => _backend.writeOnboarding(uid, submission));

      await _stage(a, SignupStage.seeding, seedTimeout, () async {
        await _backend.ensureFirstBlock(uid, a.seed,
            fallbackName: a.claimedUsername);
        await _backend.writeBestEfforts(uid, submission.bestEfforts);
      });

      await _stage(a, SignupStage.verify, stageTimeout, () async {
        await _backend.verifyComplete(uid, usernameLower: usernameLower);
        await _backend.markSignupComplete(uid);
        await _hooks.onSignupCompleted(uid);
      });

      a.state = SignupAttemptState.completed;
      a.draft.wipeSecrets();
      await _settle(uid);
      await _clearMarkerFor(a, uid: uid);
      _completedUid = uid;
      _log(a, 'complete');
      return SignupResult.success(uid);
    } on _SignupAbort catch (abort) {
      if (a.state == SignupAttemptState.submitting) {
        a.state = SignupAttemptState.editing;
      }
      a.lastFailure = abort.failure;
      return SignupResult.failed(abort.failure);
    }
  }

  Future<String> _ensureAuth(
    SignupAttempt a,
    String email,
    String password,
    String username,
  ) async {
    a._authBusy++;
    try {
      return await _ensureAuthInner(a, email, password, username);
    } finally {
      a._authBusy--;
    }
  }

  Future<String> _ensureAuthInner(
    SignupAttempt a,
    String email,
    String password,
    String username,
  ) async {
    // An earlier request (timed out, not cancelled) may still produce the
    // account. Never race it with a second create: wait for it.
    final pending = a._pendingAuth;
    if (pending != null) {
      try {
        await pending.timeout(authTimeout);
      } catch (_) {
        if (a._pendingAuth != null) {
          _fail(a, SignupFailureKind.timeout, SignupStage.auth, 'auth-still-pending');
        }
      }
    }

    final current = _auth.currentUser;

    // Resume: this attempt already owns an account.
    final owned = a.authUid;
    if (owned != null) {
      if (current?.uid == owned) return owned;
      if (current != null && !current.isAnonymous) {
        _fail(a, SignupFailureKind.accountMismatch, SignupStage.auth,
            'other-account-signed-in');
      }
      if (a.isRecovery || password.isEmpty) {
        // Recovery runs on the signed-in session; it has no password.
        _fail(a, SignupFailureKind.permission, SignupStage.auth, 'signed-out');
      }
      final resumed = await _authCall(a, _AuthPurpose.resumeOwned,
          () => _auth.signIn(email, password));
      if (resumed.uid != owned) {
        await _auth.signOut();
        _fail(a, SignupFailureKind.accountMismatch, SignupStage.auth,
            'resumed-different-uid');
      }
      return owned;
    }

    // Never adopt an established account that happens to be signed in.
    if (current != null && !current.isAnonymous) {
      _fail(a, SignupFailureKind.accountMismatch, SignupStage.auth,
          'other-account-signed-in');
    }

    // Recorded BEFORE the request, so an account whose uid never reaches the
    // app (termination, lost response) is still recognised on this device.
    await _writeMarker(LocalSignupMarker(
      attemptId: a.id,
      startedAt: a.startedAt,
      emailHash: signupEmailHash(email),
    ));

    SignupAuthUser user;
    try {
      user = await _authCall(
        a,
        _AuthPurpose.create,
        () => current != null && current.isAnonymous
            ? _auth.linkAnonymous(email, password)
            : _auth.createAccount(email, password),
      );
    } on _SignupAbort catch (abort) {
      if (abort.failure.kind != SignupFailureKind.emailInUse) rethrow;
      user = a.authCreateUncertain
          ? await _recoverUncertainCreate(a, email, password)
          : await _adoptUnfinishedAccount(a, email, password);
    }

    await _adopt(a, user.uid);
    _log(a, 'auth ok anon=${current?.isAnonymous == true}');
    if (username.isNotEmpty) {
      try {
        await _auth.updateDisplayName(username).timeout(stageTimeout);
      } catch (_) {
        // Best effort: Firestore identity is authoritative and the callable
        // updates Auth displayName itself.
      }
    }
    return user.uid;
  }

  Future<void> _adopt(SignupAttempt a, String uid) async {
    if (a.authUid == uid && !a.authCreateUncertain) return;
    a.authUid = uid;
    a.authCreateUncertain = false;
    final m = await _readMarker();
    if (m != null && m.attemptId == a.id) await _writeMarker(m.withUid(uid));
  }

  /// A previous create in THIS attempt failed without proving the account
  /// was not created, and now the email is "in use". Sign in with the same
  /// credentials and adopt the account only if it was created during this
  /// attempt; an older account is someone's existing membership and is left
  /// untouched.
  Future<SignupAuthUser> _recoverUncertainCreate(
      SignupAttempt a, String email, String password) async {
    final SignupAuthUser user;
    try {
      user = await _authCall(a, _AuthPurpose.probe, () => _auth.signIn(email, password));
    } on _SignupAbort {
      _fail(a, SignupFailureKind.emailInUse, SignupStage.auth,
          'email-already-in-use');
    }
    final created = user.creationTime;
    final windowStart = a.startedAt.subtract(const Duration(minutes: 2));
    if (created == null || created.isBefore(windowStart)) {
      await _auth.signOut();
      _fail(a, SignupFailureKind.emailInUse, SignupStage.auth,
          'email-already-in-use');
    }
    _log(a, 'auth recovered uncertain create');
    return user;
  }

  /// The email belongs to an account. If it is an UNFINISHED signup (marked
  /// pending on the server, or this device's own) and the member knows its
  /// password, continue that account's setup instead of refusing. A completed
  /// or ordinary account is someone's membership: signed back out, untouched.
  Future<SignupAuthUser> _adoptUnfinishedAccount(
      SignupAttempt a, String email, String password) async {
    final SignupAuthUser user;
    try {
      user = await _authCall(a, _AuthPurpose.probe, () => _auth.signIn(email, password));
    } on _SignupAbort {
      _fail(a, SignupFailureKind.emailInUse, SignupStage.auth, 'email-already-in-use');
    }
    SignupServerState? state;
    try {
      state = await _backend.signupState(user.uid).timeout(stageTimeout);
    } catch (_) {}
    final local = await _readMarker();
    final ownDevice = local?.uid == user.uid;
    final unfinished = state == SignupServerState.pending ||
        (ownDevice && state != SignupServerState.complete);
    if (!unfinished) {
      await _auth.signOut();
      _fail(a, SignupFailureKind.emailInUse, SignupStage.auth, 'email-already-in-use');
    }
    _log(a, 'auth adopted unfinished signup');
    return user;
  }

  /// Runs an auth request, bounded by [authTimeout] for the caller while the
  /// request itself is tracked until it settles.
  Future<SignupAuthUser> _authCall(
    SignupAttempt a,
    _AuthPurpose purpose,
    Future<SignupAuthUser> Function() call,
  ) async {
    final Future<SignupAuthUser> underlying;
    try {
      underlying = call();
    } catch (e, st) {
      final failure = classifySignupError(e, SignupStage.auth);
      _logFailure(a, failure, e, st);
      throw _SignupAbort(failure);
    }
    a._pendingAuth = underlying;
    var timedOut = false;
    underlying.then(
      (u) => _onAuthSettled(a, underlying, purpose, u, timedOut: timedOut),
      onError: (Object _) =>
          _onAuthSettled(a, underlying, purpose, null, timedOut: timedOut),
    );
    try {
      return await underlying.timeout(authTimeout);
    } catch (e, st) {
      if (e is TimeoutException) timedOut = true;
      final failure = classifySignupError(e, SignupStage.auth);
      if (purpose == _AuthPurpose.create &&
          (failure.kind == SignupFailureKind.timeout ||
              failure.kind == SignupFailureKind.network ||
              failure.kind == SignupFailureKind.unknown)) {
        a.authCreateUncertain = true;
      }
      _logFailure(a, failure, e, st);
      throw _SignupAbort(failure);
    }
  }

  /// A request settled. An in-time result is handled by its caller; only a
  /// request that outlived its timeout is decided here.
  void _onAuthSettled(SignupAttempt a, Future<SignupAuthUser> request,
      _AuthPurpose purpose, SignupAuthUser? user, {required bool timedOut}) {
    if (!identical(a._pendingAuth, request)) return;
    a._pendingAuth = null;
    _draining.remove(a);

    if (user != null && timedOut) {
      final owns = a.isActive &&
          ((purpose == _AuthPurpose.create && (a.authUid == null || a.authUid == user.uid)) ||
              (purpose == _AuthPurpose.resumeOwned && a.authUid == user.uid));
      if (owns) {
        if (a.authUid == null) {
          // The create outlived its timeout and succeeded: this attempt's own
          // account. Adopt it; a retry resumes it.
          _log(a, 'late auth success adopted');
          unawaited(_adopt(a, user.uid));
        }
      } else if (_auth.currentUser?.uid == user.uid) {
        // Nobody owns this account now (member left, or an unvalidated
        // probe). Sign it out — never delete — and keep it recoverable.
        _log(a, 'late auth success orphaned → sign out');
        unawaited(_orphanSignOut(a, user.uid, recordUid: purpose == _AuthPurpose.create));
      }
    }
    notifyListeners();
  }

  Future<void> _orphanSignOut(SignupAttempt a, String uid, {required bool recordUid}) async {
    _orphanSignOuts.add(uid);
    try {
      if (recordUid) {
        final m = await _readMarker();
        if (m != null && m.attemptId == a.id) await _writeMarker(m.withUid(uid));
      }
      await _housekeepingSignOut();
    } finally {
      _orphanSignOuts.remove(uid);
      notifyListeners();
    }
  }

  Future<void> _housekeepingSignOut() async {
    _signOutGraceUntil = _clock().add(const Duration(seconds: 3));
    try {
      await _auth.signOut();
    } catch (e) {
      debugPrint('[Signup] sign-out failed: ${e.runtimeType}');
    }
  }

  Future<void> _claim(SignupAttempt a, String username) async {
    final UsernameChangeResult result;
    try {
      result = await _backend.claimUsername(username).timeout(stageTimeout);
    } catch (e, st) {
      // A timeout does not prove the transaction did not commit; the retry
      // recognises the reservation as ours.
      final failure = classifySignupError(e, SignupStage.claim);
      _logFailure(a, failure, e, st);
      throw _SignupAbort(failure);
    }

    if (result.isSuccess) {
      final canonical = result.username ?? username;
      a
        ..claimedUsername = canonical
        ..claimedUsernameLower =
            result.usernameLower ?? normalizeUsername(canonical)
        ..claimedFor = username;
      _log(a, 'claim ok changed=${result.outcome == UsernameChangeOutcome.changed}');
      return;
    }

    final SignupFailureKind kind;
    switch (result.outcome) {
      case UsernameChangeOutcome.taken:
        kind = SignupFailureKind.usernameTaken;
        break;
      case UsernameChangeOutcome.invalid:
        kind = SignupFailureKind.usernameInvalid;
        break;
      default:
        final k = kindForCode(result.errorCode ?? 'unknown');
        kind = (k == SignupFailureKind.usernameTaken ||
                k == SignupFailureKind.usernameInvalid ||
                k == SignupFailureKind.emailInUse)
            ? SignupFailureKind.unknown
            : k;
    }
    _fail(a, kind, SignupStage.claim, result.errorCode);
  }

  Future<void> _stage(
    SignupAttempt a,
    SignupStage stage,
    Duration timeout,
    Future<void> Function() body,
  ) async {
    try {
      await body().timeout(timeout);
    } catch (e, st) {
      final failure = classifySignupError(e, stage);
      _logFailure(a, failure, e, st);
      throw _SignupAbort(failure);
    }
  }

  Never _fail(
      SignupAttempt a, SignupFailureKind kind, SignupStage stage, String? code) {
    final failure = SignupFailure(kind, stage: stage, code: code);
    _logFailure(a, failure, null, null);
    throw _SignupAbort(failure);
  }

  // ── Local marker (best effort: storage failure never blocks signup) ──────

  Future<LocalSignupMarker?> _readMarker() async {
    try {
      return await _store.read();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeMarker(LocalSignupMarker m) async {
    try {
      await _store.write(m);
    } catch (e) {
      debugPrint('[Signup] marker write failed: ${e.runtimeType}');
    }
  }

  Future<void> _clearMarkerFor(SignupAttempt a, {String? uid}) async {
    final m = await _readMarker();
    if (m == null) return;
    if (m.attemptId == a.id || (uid != null && m.uid == uid)) {
      try {
        await _store.clear();
      } catch (_) {}
    }
  }

  Future<void> _settle(String uid) async {
    try {
      await _store.markSettled(uid);
    } catch (_) {}
  }

  // ── Diagnostics (no credentials, answers, DOB or email) ──────────────────

  void _log(SignupAttempt a, String event) {
    debugPrint('[Signup ${a.id}] $event '
        'uid=${a.authUid == null ? 'none' : 'present'} '
        'session=${_sessionLabel()}');
  }

  void _logFailure(
      SignupAttempt a, SignupFailure f, Object? error, StackTrace? st) {
    final top = st?.toString().split('\n').take(4).join(' | ');
    debugPrint('[Signup ${a.id}] FAILED stage=${f.stage.name} '
        'kind=${f.kind.name} code=${f.code} '
        'error=${error?.runtimeType} '
        'uid=${a.authUid == null ? 'none' : 'present'} '
        'session=${_sessionLabel()}'
        '${top == null ? '' : ' stack=$top'}');
  }

  String _sessionLabel() {
    final u = _auth.currentUser;
    if (u == null) return 'signedOut';
    return u.isAnonymous ? 'anonymous' : 'account';
  }

  static final Random _rng = Random();
  static String _newAttemptId() =>
      List<String>.generate(8, (_) => _rng.nextInt(16).toRadixString(16)).join();
}
