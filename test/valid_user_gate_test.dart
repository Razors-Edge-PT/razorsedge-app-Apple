import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/valid_user_gate.dart';

/// Integration-style state-machine tests for the explicit-logout gate that
/// `_handleValidUser` delegates to. Models the exact production sequence —
/// explicit logout → late Firebase user auth event → decision — using the REAL
/// [passesExplicitLogoutGate], with in-memory fakes for the flag and sign-out.
class _FakeAuthEnv {
  /// Mirrors the `goodlift_explicit_logout` SharedPreferences flag.
  bool explicitLogout = false;

  /// Whether Firebase currently holds a (stale or real) user session.
  bool firebaseSignedIn = false;

  int signOutCalls = 0;

  Future<bool> isExplicitLogout() async => explicitLogout;

  Future<void> signOutUnexpected() async {
    signOutCalls++;
    firebaseSignedIn = false; // session cleared, like FirebaseAuth.signOut()
  }
}

enum _Phase { authenticated, unauthenticated }

/// Mirrors the relevant branch of `_handleValidUser`: run the gate, and on
/// `true` clear the flag + authenticate, on `false` route unauthenticated with
/// the flag preserved.
Future<_Phase> handleValidUser(_FakeAuthEnv env) async {
  final allowed = await passesExplicitLogoutGate(
    isExplicitLogout: env.isExplicitLogout,
    signOutUnexpected: env.signOutUnexpected,
  );
  if (allowed) {
    env.explicitLogout = false; // clear only on a confirmed legitimate user
    return _Phase.authenticated;
  }
  return _Phase.unauthenticated;
}

void main() {
  test('explicit logout → late Firebase user auth event → remains logged out',
      () async {
    final env = _FakeAuthEnv();

    // 1) Explicit logout writes the flag true (and signs the user out).
    env.explicitLogout = true;
    env.firebaseSignedIn = false;

    // 2) An OLDER silent credential exchange completes post-logout: its
    //    authStateChanges(user) supplies a stale Firebase user.
    env.firebaseSignedIn = true;

    // 3) The valid-user path runs — it must gate BEFORE clearing/authenticating.
    final phase = await handleValidUser(env);

    expect(phase, _Phase.unauthenticated,
        reason: 'stale user must not authenticate the UI');
    expect(env.signOutCalls, 1,
        reason: 'the unexpected Firebase user is signed back out');
    expect(env.firebaseSignedIn, isFalse,
        reason: 'Firebase session cleared to match the logged-out UI');
    expect(env.explicitLogout, isTrue,
        reason: 'explicit-logout flag preserved (never cleared by the gate)');
  });

  test('stays logged out across a reopen: the preserved flag still rejects',
      () async {
    final env = _FakeAuthEnv()..explicitLogout = true;

    // First late user event: rejected + signed out, flag preserved.
    env.firebaseSignedIn = true;
    expect(await handleValidUser(env), _Phase.unauthenticated);
    expect(env.explicitLogout, isTrue);

    // Simulate a later cold start where Firebase again surfaces a cached user
    // (e.g. the fast path). The preserved flag must keep rejecting it.
    env.firebaseSignedIn = true;
    expect(await handleValidUser(env), _Phase.unauthenticated);
    expect(env.signOutCalls, 2);
    expect(env.explicitLogout, isTrue);
  });

  test('legitimate interactive login (flag pre-cleared) authenticates, no sign-out',
      () async {
    final env = _FakeAuthEnv();
    // login_screen / create_new_account_screen set the flag false BEFORE
    // calling Firebase sign-in.
    env.explicitLogout = false;
    env.firebaseSignedIn = true;

    final phase = await handleValidUser(env);

    expect(phase, _Phase.authenticated);
    expect(env.signOutCalls, 0, reason: 'a legitimate user is never signed out');
    expect(env.firebaseSignedIn, isTrue);
    expect(env.explicitLogout, isFalse);
  });

  test('gate does not clear the flag itself (only the caller may, on allow)',
      () async {
    final env = _FakeAuthEnv()..explicitLogout = true;
    final allowed = await passesExplicitLogoutGate(
      isExplicitLogout: env.isExplicitLogout,
      signOutUnexpected: env.signOutUnexpected,
    );
    expect(allowed, isFalse);
    expect(env.explicitLogout, isTrue, reason: 'gate must preserve the flag');
  });
}
