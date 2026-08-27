/// Pure validation rules and DOB formatting for the GoodLift signup form.
///
/// `CreateNewAccountScreen` is a large production widget that talks to Firebase
/// and Firestore directly, so its rules cannot be exercised in a widget test
/// without a live backend. The *rules* themselves are pure, so they live here
/// and the screen delegates to them.
///
/// IMPORTANT — persisted format: date of birth is stored as **`dd-mm-yyyy`**
/// (see [formatDobForStorage]). Several comments in the codebase historically
/// claimed `yyyy-mm-dd`; that was never what was written. `user_settings.dart`
/// reads it back as `dd-mm-yyyy`, and Page 2's `_isDobBefore1995Flexible`
/// parses `dd-mm-yyyy` first. Do not change this format.
library;

/// Field identifiers used to key inline errors on the signup form.
class SignupField {
  static const username = 'username';
  static const fullName = 'fullName';
  static const dob = 'dob';
  static const sex = 'sex';
  static const email = 'email';
  static const password = 'password';
  static const confirmPassword = 'confirmPassword';
}

/// Username: 3–22 characters, no spaces. Length rule preserved from the
/// original `_usernameRe` (`^.{3,22}$`).
const int kUsernameMinLength = 3;
const int kUsernameMaxLength = 22;

/// Password minimum length, preserved from the original rule.
const int kPasswordMinLength = 6;

/// Oldest plausible age, preserved from the original `_normalizeDob` window.
const int kMaxPlausibleAgeYears = 120;

/// Validates the username's *format* only. Availability is a separate,
/// asynchronous concern — see [usernameAvailabilityError].
String? validateUsername(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return 'Choose a username.';
  // Spaces are reported specifically so the user is never told to "use 3–22
  // characters" when the real problem is a space.
  if (v.contains(' ')) return "Usernames can't contain spaces.";
  if (v.length < kUsernameMinLength || v.length > kUsernameMaxLength) {
    return 'Use 3–22 characters.';
  }
  return null;
}

/// Error for a username whose availability check came back negative.
///
/// [available] is null when the check has not run or could not complete. That
/// is deliberately not an error here: this check is a *convenience*, and
/// blocking Continue because a Firestore read failed would be needlessly
/// hostile. The authoritative check runs immediately before the account is
/// committed — see `checkUsernameStillAvailable()` in
/// signup_username_guard.dart, which fails closed rather than write an
/// unverified name.
String? usernameAvailabilityError(bool? available) =>
    available == false ? "That username's already taken — try another." : null;

String? validateFullName(String? raw) {
  final v = (raw ?? '').trim();
  // Deliberately just non-empty: nothing else in the codebase requires a
  // first/last-name split, so imposing one would reject legitimate names.
  if (v.isEmpty) return 'Enter your name.';
  return null;
}

/// Matches the original signup regex exactly, so no address that used to be
/// accepted is now rejected.
final RegExp kEmailRe = RegExp(r'^[^@]+@[^@]+\.[^@]+');

String? validateEmail(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return 'Enter your email.';
  if (!kEmailRe.hasMatch(v)) {
    return "That doesn't look like a valid email address.";
  }
  return null;
}

String? validatePassword(String? raw) {
  final v = raw ?? '';
  if (v.isEmpty) return 'Enter a password.';
  if (v.length < kPasswordMinLength) {
    return 'Password needs at least $kPasswordMinLength characters.';
  }
  return null;
}

String? validateConfirmPassword(String? confirm, String? password) {
  final c = confirm ?? '';
  if (c.isEmpty) return 'Re-enter your password.';
  if (c != (password ?? '')) return "Those passwords don't match yet.";
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Page 2 (OnboardingPageTwo) required-answer rules.
//
// These live here, next to the Page 1 rules, for the same reason: the screen
// itself cannot be exercised without a live Firebase backend, but the rules and
// the user-facing copy are pure and must not drift.
// ─────────────────────────────────────────────────────────────────────────────

/// Ids for the required sections on Page 2. Used to key both the missing-
/// requirement messages and the screen's scroll anchors.
class OnboardingSection {
  static const goals = 'goals';
  static const bodyFocus = 'bodyFocus';
  static const injuries = 'injuries';
  static const experience = 'experience';
  static const env = 'env';
}

/// Exact user-facing copy for the Page 2 requirements. These strings are
/// specified verbatim by the product owner — do not paraphrase them.
const String kGoalsMissingMessage = 'Pick at least one training goal.';
const String kBodyFocusMissingMessage =
    "Pick at least one area you'd like to focus on.";
const String kInjuryPainMissingMessage =
    'Give this a pain rating out of 10 so we can account for it.';
const String kExperienceMissingMessage =
    'Select your training experience level.';
const String kEnvironmentMissingMessage =
    'Tell us what kind of gym you will usually train at.';

/// Lists what Page 2 is still missing, in the order the questions appear, each
/// paired with the section that owns it. Empty means valid.
///
/// Pure by design: the screen computes these booleans from its own state and
/// delegates, so the rules and copy can be tested without a backend.
List<({String section, String message})> missingOnboardingRequirements({
  required bool hasGoal,
  required bool muscleOrTonedChosen,
  required bool hasAnyBodyFocus,
  required bool everyInjuryRated,
  required bool hasExperience,
  required bool hasEnvironment,
}) {
  final missing = <({String section, String message})>[];

  // Required: goals (ordered by default, so this is a defensive check).
  if (!hasGoal) {
    missing.add((
      section: OnboardingSection.goals,
      message: kGoalsMissingMessage,
    ));
  }

  // Conditional: if muscle/toned was chosen, at least one body focus.
  if (muscleOrTonedChosen && !hasAnyBodyFocus) {
    missing.add((
      section: OnboardingSection.bodyFocus,
      message: kBodyFocusMissingMessage,
    ));
  }

  // Injuries may be empty, but any selected injury needs a pain level 1–10.
  if (!everyInjuryRated) {
    missing.add((
      section: OnboardingSection.injuries,
      message: kInjuryPainMissingMessage,
    ));
  }

  // Required: experience.
  if (!hasExperience) {
    missing.add((
      section: OnboardingSection.experience,
      message: kExperienceMissingMessage,
    ));
  }

  // Required: training environment.
  if (!hasEnvironment) {
    missing.add((
      section: OnboardingSection.env,
      message: kEnvironmentMissingMessage,
    ));
  }

  return missing;
}

/// Sex is genuinely required: `home_bootstrap_service`, `home_screen` and
/// `planned_blocks_screen` all gate their "demographics complete" check on
/// `users/{uid}.sex != null`. Option values ('M' | 'F' | 'N') are unchanged.
String? validateSex(String? selected) {
  if (selected == null || selected.isEmpty) return 'Select an option.';
  return null;
}

/// Validates a date of birth that a calendar picker has already guaranteed to
/// be a real date. The picker makes impossible dates (31 February)
/// unreachable; these remain as defensive business rules.
///
/// [now] is injectable so the rules are testable without wall-clock coupling.
String? validateDob(DateTime? dob, {DateTime? now}) {
  if (dob == null) return 'Select your date of birth.';
  final today = now ?? DateTime.now();
  final endOfToday = DateTime(today.year, today.month, today.day, 23, 59, 59);
  if (dob.isAfter(endOfToday)) return 'No time travelers yet 😉';

  final oldest = DateTime(today.year - kMaxPlausibleAgeYears, today.month, today.day);
  if (dob.isBefore(oldest) || dob.year < 1900) {
    return 'I call BS! you are not that old.';
  }
  return null;
}

/// The persisted representation: `dd-mm-yyyy`. Unchanged from the original
/// `_normalizeDob` output, so stored data semantics are identical.
String formatDobForStorage(DateTime dob) {
  final dd = dob.day.toString().padLeft(2, '0');
  final mm = dob.month.toString().padLeft(2, '0');
  return '$dd-$mm-${dob.year}';
}

const List<String> _monthAbbreviations = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Unambiguous display form, e.g. `25 Aug 1991`. Day-first for NZ users, with
/// a named month so 03-04 can never be misread as March or April.
String formatDobForDisplay(DateTime dob) =>
    '${dob.day} ${_monthAbbreviations[dob.month - 1]} ${dob.year}';

/// Parses the persisted `dd-mm-yyyy` form back into a date, tolerating the
/// legacy ISO `yyyy-mm-dd` shape that older records may carry. Returns null if
/// the string is not a real calendar date.
DateTime? parseStoredDob(String? stored) {
  final s = (stored ?? '').trim();
  if (s.isEmpty) return null;

  final ddmm = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$').firstMatch(s);
  final ymd = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);

  int y, m, d;
  if (ddmm != null) {
    d = int.parse(ddmm.group(1)!);
    m = int.parse(ddmm.group(2)!);
    y = int.parse(ddmm.group(3)!);
  } else if (ymd != null) {
    y = int.parse(ymd.group(1)!);
    m = int.parse(ymd.group(2)!);
    d = int.parse(ymd.group(3)!);
  } else {
    return null;
  }

  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  final dt = DateTime(y, m, d);
  // Rejects rolled-over impossible dates such as 31-02-1990.
  if (dt.year != y || dt.month != m || dt.day != d) return null;
  return dt;
}
