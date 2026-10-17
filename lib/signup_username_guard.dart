/// Username uniqueness in the GoodLift signup flow.
///
/// ── The rule ────────────────────────────────────────────────────────────────
/// A signup completes only after the `profileChangeUsername` callable has
/// reserved the name for the new account inside its transaction
/// (usernames/{sha256(normalisedName)}). That is the single authority:
///
///  * a definitive collision ("already-exists") sends the member back to the
///    Page 1 Username field with both pages' answers intact;
///  * any failure to reach a verdict (timeout, network, permission,
///    configuration) is reported as what it is and the member retries —
///    the name is never treated as accepted on "unknown";
///  * a retry by the same account is recognised as that account's own
///    reservation, so a response lost after commit cannot block completion.
///
/// ── What was removed, and why ───────────────────────────────────────────────
/// This file used to hold a pre-account "final guard": a `users_public`
/// query run before the account existed, failing closed on any error. Those
/// reads require a signed-in caller and a logged-out device has none
/// (anonymous sign-in is not enabled on the project), so the guard was
/// permission-denied on every new signup and stopped Finish with "check your
/// connection" — while adding no uniqueness the transaction did not already
/// guarantee. Page 1's availability hint remains, advisory only.
///
/// See signup/signup_coordinator.dart for the completion sequence.
library;

/// Shown on the Page 1 Username field after a definitive collision. Identical
/// to the string `usernameAvailabilityError()` produces, so the member sees
/// one consistent message wherever the collision is detected.
const String kUsernameTakenMessage =
    "That username's already taken — try another.";
