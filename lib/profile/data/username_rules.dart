/// Client mirror of `functions/identity/username_rules.js`.
///
/// The SERVER is authoritative for uniqueness. Everything here is either
/// (a) input validation, so the user gets an instant, honest message instead of
/// a round-trip, or (b) an optional availability hint. Neither is ever allowed
/// to decide that a name is free — only the callable's transaction can do that,
/// and it fails closed.
///
/// ── One deliberate difference from the server ───────────────────────────────
/// The server normalises with trim → Unicode NFKC → lowercase. Dart has no
/// built-in NFKC and this app does not carry a Unicode normalisation package,
/// so [normalizeUsername] here is trim → lowercase. NFKC is the identity on
/// ASCII, which is every username the app has ever written, so the two agree in
/// practice. For a hypothetical non-ASCII name they could disagree — and that
/// is safe precisely because this function never authorises anything: a wrong
/// local hint is corrected by the server, which refuses the name.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The app's long-standing rule: 3–22 characters, no whitespace.
final RegExp kUsernamePattern = RegExp(r'^\S{3,22}$');

const int kUsernameMinLength = 3;
const int kUsernameMaxLength = 22;

/// Why a username was rejected.
enum UsernameProblem { empty, invalidCharacters, invalidFormat }

/// Normalised, case-insensitive form. See the library note on NFKC.
String normalizeUsername(String? raw) {
  if (raw == null) return '';
  return raw.trim().toLowerCase();
}

/// Display form: trimmed, casing preserved.
String displayUsername(String? raw) => raw == null ? '' : raw.trim();

/// Returns null when the name is acceptable.
UsernameProblem? validateUsername(String? raw) {
  final String display = displayUsername(raw);
  if (display.isEmpty) return UsernameProblem.empty;
  for (final int unit in display.codeUnits) {
    if (unit <= 0x1f || unit == 0x7f) return UsernameProblem.invalidCharacters;
  }
  if (!kUsernamePattern.hasMatch(display)) return UsernameProblem.invalidFormat;
  return null;
}

/// User-facing text for a validation problem.
String usernameProblemMessage(UsernameProblem problem) {
  switch (problem) {
    case UsernameProblem.empty:
      return 'Enter a username.';
    case UsernameProblem.invalidCharacters:
      return 'That username contains characters we can’t use.';
    case UsernameProblem.invalidFormat:
      return 'Usernames are $kUsernameMinLength–$kUsernameMaxLength characters '
          'with no spaces.';
  }
}

/// Path-safe reservation document id, matching the server's derivation.
String usernameIndexKey(String normalized) =>
    sha256.convert(utf8.encode(normalized)).toString();

/// Shown when a name is definitively taken. Matches the signup flow's wording
/// so a collision reads the same wherever it is detected.
const String kUsernameTakenMessage =
    "That username's already taken — try another.";

/// Shown when uniqueness could not be confirmed. Deliberately does NOT claim
/// the name is taken.
const String kUsernameCheckFailedMessage =
    "We couldn't check that username right now. Check your connection and try again.";

/// Shown when the device is offline.
///
/// Uniqueness needs a transaction, and Firestore transactions — unlike batched
/// writes — cannot queue offline. There is no honest way to accept a username
/// change without a connection, so the UI says so rather than pretending.
const String kUsernameNeedsConnectionMessage =
    'Changing your username needs a connection — we have to check nobody else '
    'has taken it.';
