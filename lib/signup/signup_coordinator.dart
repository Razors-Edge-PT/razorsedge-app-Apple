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
///                session, or resume the SAME uid this attempt created);
///   2. claim     reserve the username through `profileChangeUsername` — the
///                one transactional authority. No name is accepted on
///                "unknown": completion requires a successful reservation;
///   3. membership / profile / onboarding / first block;
///   4. verify    read everything back from the server;
///   5. complete  hand the session to AppRoot.
///
/// While an attempt owns the auth session AppRoot holds its routing, so
/// nothing can interrupt mandatory setup, and it routes to the normal
/// destination only after step 5.
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
  Future<void> signOut();
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
}

/// Device-session side effects of a completed signup (the explicit-logout
/// flag and last-login provider AppRoot consults).
abstract class SignupSessionHooks {
  Future<void> onSignupCompleted(String uid);
}

// ── Attempt ─────────────────────────────────────────────────────────────────

enum SignupAttemptState { editing, submitting, completed, cancelled }

class SignupAttempt {
  SignupAttempt._(this.id, this.startedAt, this.owner);

  /// The coordinator that runs this attempt.
  final SignupCoordinator owner;

  /// Correlation id for diagnostics. Not personal data.
  final String id;
  final DateTime startedAt;
  final SignupDraft draft = SignupDraft();

  SignupAttemptState state = SignupAttemptState.editing;

  /// The account this attempt created or upgraded. Once set, every retry
  /// must resume exactly this uid.
  String? authUid;

  /// An auth call is in flight (its auth event may arrive before it returns).
  bool authInFlight = false;

  /// An account-creation call failed in a way that does not prove the
  /// account was NOT created (timeout / dropped connection).
  bool authCreateUncertain = false;

  /// The canonical reserved username returned by the server, and the exact
  /// raw name it was claimed for.
  String? claimedUsername;
  String? claimedUsernameLower;
  String? claimedFor;

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
    Future<bool?> Function(String raw)? usernameHint,
    this.authTimeout = const Duration(seconds: 30),
    this.stageTimeout = const Duration(seconds: 30),
    this.seedTimeout = const Duration(seconds: 60),
    DateTime Function()? clock,
  })  : _auth = auth,
        _backend = backend,
        _hooks = hooks,
        _usernameHint = usernameHint,
        _clock = clock ?? DateTime.now;

  final SignupAuthGateway _auth;
  final SignupBackend _backend;
  final SignupSessionHooks _hooks;
  final Future<bool?> Function(String raw)? _usernameHint;
  final DateTime Function() _clock;

  final Duration authTimeout;
  final Duration stageTimeout;
  final Duration seedTimeout;

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

  /// The attempt currently in progress, if any.
  SignupAttempt? get current => _current;

  // ── Attempt lifecycle ────────────────────────────────────────────────────

  /// Starts a fresh attempt with an empty draft. Any previous unfinished
  /// attempt is cancelled first, so a new member never inherits a draft.
  SignupAttempt beginAttempt() {
    final previous = _current;
    if (previous != null && previous.isActive) {
      unawaited(cancelAttempt(previous));
    }
    final attempt = SignupAttempt._(_newAttemptId(), _clock(), this);
    _current = attempt;
    _log(attempt, 'begin');
    notifyListeners();
    return attempt;
  }

  /// Genuine cancellation (the member left signup). Wipes the draft. If this
  /// attempt already created an account, that account is signed out — never
  /// deleted, and its reservation is left in place — so it stays recoverable
  /// by logging in.
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

    final uid = attempt.authUid;
    if (uid != null && _auth.currentUser?.uid == uid) {
      _signOutGraceUntil = _clock().add(const Duration(seconds: 3));
      try {
        await _auth.signOut();
      } catch (e) {
        debugPrint('[Signup] cancel sign-out failed: ${e.runtimeType}');
      }
    }
    notifyListeners();
  }

  // ── AppRoot coordination ─────────────────────────────────────────────────

  /// True while a signup owns the auth session for [uid]: AppRoot must not
  /// route, gate or sign out that user until [submit] completes.
  bool holdsAuthRoutingFor(String uid) {
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

      await _stage(a, SignupStage.verify, stageTimeout,
          () => _backend.verifyComplete(uid, usernameLower: usernameLower));

      await _stage(a, SignupStage.verify, stageTimeout,
          () => _hooks.onSignupCompleted(uid));

      a.state = SignupAttemptState.completed;
      a.draft.wipeSecrets();
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
    final current = _auth.currentUser;

    // Resume: this attempt already owns an account.
    final owned = a.authUid;
    if (owned != null) {
      if (current?.uid == owned) return owned;
      if (current != null && !current.isAnonymous) {
        _fail(a, SignupFailureKind.accountMismatch, SignupStage.auth,
            'other-account-signed-in');
      }
      final resumed = await _authCall(a, () => _auth.signIn(email, password));
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

    SignupAuthUser user;
    try {
      user = await _authCall(
        a,
        () => current != null && current.isAnonymous
            ? _auth.linkAnonymous(email, password)
            : _auth.createAccount(email, password),
        markUncertain: true,
      );
    } on _SignupAbort catch (abort) {
      if (abort.failure.kind == SignupFailureKind.emailInUse &&
          a.authCreateUncertain) {
        user = await _recoverUncertainCreate(a, email, password);
      } else {
        rethrow;
      }
    }

    a.authUid = user.uid;
    a.authCreateUncertain = false;
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

  /// A previous create in THIS attempt failed without proving the account
  /// was not created, and now the email is "in use". Sign in with the same
  /// credentials and adopt the account only if it was created during this
  /// attempt; an older account is someone's existing membership and is left
  /// untouched.
  Future<SignupAuthUser> _recoverUncertainCreate(
      SignupAttempt a, String email, String password) async {
    final SignupAuthUser user;
    try {
      user = await _authCall(a, () => _auth.signIn(email, password));
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

  Future<SignupAuthUser> _authCall(
    SignupAttempt a,
    Future<SignupAuthUser> Function() call, {
    bool markUncertain = false,
  }) async {
    a.authInFlight = true;
    try {
      return await call().timeout(authTimeout);
    } catch (e, st) {
      final failure = classifySignupError(e, SignupStage.auth);
      if (markUncertain &&
          (failure.kind == SignupFailureKind.timeout ||
              failure.kind == SignupFailureKind.network ||
              failure.kind == SignupFailureKind.unknown)) {
        a.authCreateUncertain = true;
      }
      _logFailure(a, failure, e, st);
      throw _SignupAbort(failure);
    } finally {
      a.authInFlight = false;
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
