/// Pure, testable explicit-logout gate for the valid-user auth path.
///
/// Protects against a stale / unexpected Firebase user arriving AFTER an
/// explicit logout — e.g. an older silent credential exchange whose
/// `authStateChanges(user)` side-effect lands in `_handleValidUser` after the
/// user has deliberately logged out. Extracted so the state-machine transition
/// is unit-testable without Firebase singletons.

/// Decides whether a valid (non-anonymous) Firebase user event may authenticate.
///
/// Reads the explicit-logout flag FIRST (before any clear/authenticate). If a
/// logout is in effect:
///   • [signOutUnexpected] is invoked to sign the unexpected user back out so
///     the Firebase session matches the logged-out UI;
///   • the explicit-logout flag is PRESERVED (this gate never clears it);
///   • returns `false` → the caller must route unauthenticated.
/// Otherwise returns `true` → the caller may proceed (and clear the flag).
Future<bool> passesExplicitLogoutGate({
  required Future<bool> Function() isExplicitLogout,
  required Future<void> Function() signOutUnexpected,
}) async {
  if (await isExplicitLogout()) {
    await signOutUnexpected();
    return false;
  }
  return true;
}
