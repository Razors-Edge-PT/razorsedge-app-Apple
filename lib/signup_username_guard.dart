/// Final, authoritative username uniqueness guard for the GoodLift signup flow.
///
/// Page 1's live/debounced availability check is a *convenience* only: it can
/// go stale between the moment the user leaves the Username field and the
/// moment the account is actually committed, and it deliberately does not block
/// Continue when the read fails. This module is the last line of defence — it
/// runs immediately before the signup flow writes `usernameLower`.
///
/// The backend read is injected so the rules here stay pure and testable. The
/// production caller passes the same `users_public` / `usernameLower` query the
/// rest of the app uses, so the normalisation semantics are identical.
library;

/// Result of the final availability read.
enum UsernameGuardOutcome {
  /// The index has no other holder of this name.
  available,

  /// The index definitively reports the name as taken.
  taken,

  /// The read itself did not complete (offline, permission denied, timeout).
  /// This is NOT the same as "taken" and must never be reported as such.
  checkFailed,
}

/// What the signup flow must do once [checkUsernameStillAvailable] has run.
enum SignupCommitAction {
  /// Safe to create/link the account and write the profile.
  proceed,

  /// Definitive collision — send the user back to the Page 1 Username field.
  returnToUsernameField,

  /// The check could not complete. Fail closed and let the user retry.
  showRetryableError,
}

/// Shown inline on the Page 1 Username field after a definitive collision.
/// Identical to the string `usernameAvailabilityError()` produces, so the user
/// sees one consistent message wherever the collision is detected.
const String kUsernameTakenMessage =
    "That username's already taken — try another.";

/// Shown when the final check could not complete. Deliberately does not claim
/// the name is taken, and is phrased so the user knows retrying is worthwhile.
const String kUsernameCheckFailedMessage =
    "We couldn't check that username right now. Check your connection and try again.";

/// Pop result used by Page 2 to tell Page 1 "your username collided — fix it".
const String kSignupUsernameTakenResult = 'signup.usernameTaken';

/// Runs the final availability read for [username].
///
/// [isAvailable] receives the *normalised lowercase* name and returns true when
/// no other account holds it. Any throw is converted to
/// [UsernameGuardOutcome.checkFailed] — the caller must fail closed rather than
/// write an unverified name.
Future<UsernameGuardOutcome> checkUsernameStillAvailable(
  String username,
  Future<bool> Function(String usernameLower) isAvailable,
) async {
  final lower = username.trim().toLowerCase();
  try {
    final ok = await isAvailable(lower);
    return ok ? UsernameGuardOutcome.available : UsernameGuardOutcome.taken;
  } catch (_) {
    // Fail closed: an unreadable index proves nothing about uniqueness.
    return UsernameGuardOutcome.checkFailed;
  }
}

/// Maps a guard outcome onto the action the signup flow must take. Only
/// [UsernameGuardOutcome.available] may ever proceed to a write.
SignupCommitAction actionForGuardOutcome(UsernameGuardOutcome outcome) {
  switch (outcome) {
    case UsernameGuardOutcome.available:
      return SignupCommitAction.proceed;
    case UsernameGuardOutcome.taken:
      return SignupCommitAction.returnToUsernameField;
    case UsernameGuardOutcome.checkFailed:
      return SignupCommitAction.showRetryableError;
  }
}

/// True when the Finish action is about to CREATE an account, which is exactly
/// the two live auth branches the guard must cover:
///
///  * `hasCurrentUser == false` → `createUserWithEmailAndPassword`
///  * `isAnonymous == true`     → `linkWithCredential` on the anonymous session
///
/// False for an established, non-anonymous user, i.e. Page 2 opened in edit
/// mode from Templates / the drawer. That path creates nothing and must not be
/// blocked by a uniqueness check against the user's own record.
bool isAccountCreationPath({
  required bool hasCurrentUser,
  required bool isAnonymous,
}) =>
    !hasCurrentUser || isAnonymous;
