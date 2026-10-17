/// Classifies every way signup can fail into something the member can act on.
///
/// Before this, Page 2 showed "We couldn't check that username right now.
/// Check your connection and try again." for ANY failure of a pre-auth
/// availability read — including the permission-denied that a logged-out
/// device always gets — and for any non-network failure of the username
/// callable. A backend or configuration problem was presented as the
/// member's internet. Only a genuine network failure says "connection" now.
library;

import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../signup_username_guard.dart' show kUsernameTakenMessage;

/// Where in the completion sequence a failure happened.
enum SignupStage { auth, claim, membership, profile, onboarding, seeding, verify }

enum SignupFailureKind {
  /// Another account holds the username (server reservation said so).
  usernameTaken,

  /// The username is not legal (server validation said so).
  usernameInvalid,

  emailInUse,
  invalidEmail,
  weakPassword,

  /// A different, established account is signed in on this device.
  accountMismatch,

  /// The backend refused the request for this session (rules / auth token).
  permission,

  /// App Check rejected the request.
  appCheck,

  /// A provider, function or project setting is unavailable on our side.
  configuration,

  /// The backend did not answer in time. The operation may have completed.
  timeout,

  /// The device could not reach the backend.
  network,

  rateLimited,
  unknown,
}

@immutable
class SignupFailure {
  const SignupFailure(this.kind, {required this.stage, this.code});

  final SignupFailureKind kind;
  final SignupStage stage;

  /// The raw Firebase/platform code, for diagnostics only.
  final String? code;

  /// Whether tapping Finish again with the same answers can succeed.
  bool get retryable => switch (kind) {
        SignupFailureKind.timeout ||
        SignupFailureKind.network ||
        SignupFailureKind.permission ||
        SignupFailureKind.appCheck ||
        SignupFailureKind.configuration ||
        SignupFailureKind.rateLimited ||
        SignupFailureKind.unknown =>
          true,
        _ => false,
      };

  /// True when the member must change something on Page 1.
  bool get returnsToPageOne => switch (kind) {
        SignupFailureKind.usernameTaken ||
        SignupFailureKind.usernameInvalid ||
        SignupFailureKind.emailInUse ||
        SignupFailureKind.invalidEmail ||
        SignupFailureKind.weakPassword =>
          true,
        _ => false,
      };

  String get message => signupFailureMessage(kind);

  @override
  String toString() => 'SignupFailure(${kind.name}, stage=${stage.name}, code=$code)';
}

const String kSignupEmailInUseMessage =
    'That email already has a GoodLift account. Log in instead, or use a different email.';
const String kSignupInvalidEmailMessage =
    "That doesn't look like a valid email address.";
const String kSignupWeakPasswordMessage =
    'Password needs at least 6 characters.';
const String kSignupAccountMismatchMessage =
    'A different GoodLift account is signed in on this device. Log out of it before creating a new account.';
const String kSignupPermissionMessage =
    "GoodLift couldn't confirm your new account's sign-in. Your answers are kept — tap Retry.";
const String kSignupAppCheckMessage =
    "GoodLift couldn't verify this copy of the app. Make sure it's up to date, then tap Retry.";
const String kSignupConfigurationMessage =
    'Account setup is temporarily unavailable on our side. Your answers are kept — please try again shortly.';
const String kSignupTimeoutMessage =
    'GoodLift is taking too long to respond. Your answers are kept — tap Retry.';
const String kSignupNetworkMessage =
    "You're offline or the connection dropped. Your answers are kept — reconnect and tap Retry.";
const String kSignupRateLimitedMessage =
    'Too many attempts. Wait a minute, then tap Retry.';
const String kSignupUnknownMessage =
    'Something went wrong finishing setup. Your answers are kept — tap Retry.';

String signupFailureMessage(SignupFailureKind kind) => switch (kind) {
      SignupFailureKind.usernameTaken => kUsernameTakenMessage,
      SignupFailureKind.usernameInvalid =>
        'That username can’t be used. Usernames are 3–22 characters with no spaces.',
      SignupFailureKind.emailInUse => kSignupEmailInUseMessage,
      SignupFailureKind.invalidEmail => kSignupInvalidEmailMessage,
      SignupFailureKind.weakPassword => kSignupWeakPasswordMessage,
      SignupFailureKind.accountMismatch => kSignupAccountMismatchMessage,
      SignupFailureKind.permission => kSignupPermissionMessage,
      SignupFailureKind.appCheck => kSignupAppCheckMessage,
      SignupFailureKind.configuration => kSignupConfigurationMessage,
      SignupFailureKind.timeout => kSignupTimeoutMessage,
      SignupFailureKind.network => kSignupNetworkMessage,
      SignupFailureKind.rateLimited => kSignupRateLimitedMessage,
      SignupFailureKind.unknown => kSignupUnknownMessage,
    };

/// Maps a raw Firebase Auth / Functions / Firestore code to a failure kind.
SignupFailureKind kindForCode(String code) {
  final c = code.toLowerCase();
  if (c.contains('app-check') || c.contains('appcheck')) {
    return SignupFailureKind.appCheck;
  }
  switch (c) {
    // Auth
    case 'email-already-in-use':
    case 'credential-already-in-use':
      return SignupFailureKind.emailInUse;
    case 'invalid-email':
      return SignupFailureKind.invalidEmail;
    case 'weak-password':
      return SignupFailureKind.weakPassword;
    case 'network-request-failed':
      return SignupFailureKind.network;
    case 'too-many-requests':
    case 'resource-exhausted':
      return SignupFailureKind.rateLimited;
    case 'operation-not-allowed':
    case 'admin-restricted-operation':
    case 'app-not-authorized':
    case 'invalid-api-key':
    case 'configuration-not-found':
    case 'not-found': // callable not deployed / wrong region
    case 'unimplemented':
    case 'internal':
    case 'internal-error':
      return SignupFailureKind.configuration;
    case 'permission-denied':
    case 'unauthenticated':
    case 'user-token-expired':
    case 'invalid-user-token':
    case 'user-disabled':
    case 'requires-recent-login':
    case 'user-mismatch':
    case 'wrong-password':
    case 'invalid-credential':
      return SignupFailureKind.permission;
    case 'failed-precondition':
      // Firestore uses this for a missing index; callables for App Check
      // when enforcement rejects a token. Either way it is not the network.
      return SignupFailureKind.configuration;
    // Functions / Firestore transport
    case 'unavailable':
      return SignupFailureKind.network;
    case 'deadline-exceeded':
    case 'timeout':
      return SignupFailureKind.timeout;
    case 'already-exists':
      return SignupFailureKind.usernameTaken;
    case 'invalid-argument':
      return SignupFailureKind.usernameInvalid;
    default:
      return SignupFailureKind.unknown;
  }
}

/// Classifies an exception thrown at [stage].
SignupFailure classifySignupError(Object error, SignupStage stage) {
  if (error is TimeoutException) {
    return SignupFailure(SignupFailureKind.timeout, stage: stage, code: 'timeout');
  }
  if (error is FirebaseAuthException) {
    return SignupFailure(kindForCode(error.code), stage: stage, code: error.code);
  }
  if (error is FirebaseFunctionsException) {
    return SignupFailure(kindForCode(error.code), stage: stage, code: error.code);
  }
  if (error is FirebaseException) {
    // Firestore 'already-exists' / 'invalid-argument' are not username
    // verdicts; only the claim stage may produce those kinds.
    final kind = kindForCode(error.code);
    final safe = (kind == SignupFailureKind.usernameTaken ||
            kind == SignupFailureKind.usernameInvalid ||
            kind == SignupFailureKind.emailInUse)
        ? SignupFailureKind.unknown
        : kind;
    return SignupFailure(safe, stage: stage, code: error.code);
  }
  return SignupFailure(SignupFailureKind.unknown,
      stage: stage, code: error.runtimeType.toString());
}
