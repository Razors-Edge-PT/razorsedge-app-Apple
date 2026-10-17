/// Builds the identity portion of the Firestore profile payload written by
/// `OnboardingPageTwo._finish()`.
///
/// Page 2 serves two very different callers:
///  * new-account creation (`CreateNewAccountScreen`), which always supplies
///    every identity field it collected on Page 1;
///  * editing an existing user's onboarding answers, opened from the drawer
///    or Templates (`app_drawer.dart` / `templates.dart`), which passes
///    `null` for whichever identity field it isn't letting the user change —
///    including `sex`/`dob` when their Firestore prefetch fails or the field
///    was never set.
///
/// `SetOptions(merge: true)` only protects an existing Firestore field when
/// its key is ABSENT from the written map — an explicit `null` or `''` still
/// overwrites it. So a field must only ever be added here when the caller
/// actually supplied a value; omitting an unsupplied field is what lets the
/// user's existing value survive an onboarding-only edit.
///
/// `createdAt` is the same class of bug, just gated on "is this real account
/// creation" rather than "was this field supplied" — see
/// [buildCreatedAtField] below.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

/// Returns just the identity keys that should be merged into `users` /
/// `users_public`. A `null` input omits its key(s) entirely rather than
/// writing `null` or `''` — the caller's base payload (email, createdAt, …)
/// is unaffected and should be spread alongside this.
Map<String, dynamic> buildIdentityPayloadFields({
  String? username,
  String? fullName,
  String? sex,
  String? dob,
}) {
  final fields = <String, dynamic>{};

  if (username != null) {
    final trimmed = username.trim();
    fields['username'] = trimmed;
    // Legacy shape (trim + lowercase). Signup no longer passes a username
    // here: the profileChangeUsername callable writes the canonical reserved
    // username/usernameLower, and a raw rewrite could disagree with it.
    fields['usernameLower'] = trimmed.toLowerCase();
  }

  if (fullName != null) {
    fields['fullName'] = fullName;
  }

  if (sex != null) {
    fields['sex'] = sex;
  }

  if (dob != null) {
    fields['dob'] = dob;
  }

  return fields;
}

/// Returns the `createdAt` key that should be merged into `users` /
/// `users_public`, or nothing at all.
///
/// [isNewAccount] comes from the signup attempt's own record, never from the
/// auth state: the signup coordinator passes true until the stamp has been
/// committed for that account (and only if the server has none yet), so a
/// retry after a partial failure stamps it exactly once; edit mode
/// (Templates / drawer) always passes false.
///
/// True → `createdAt` is (re-)stamped, exactly once, at real account
/// creation. False → the key is omitted entirely (never written as `null` or
/// re-stamped), so an onboarding-only edit can never overwrite the account's
/// true creation time.
Map<String, dynamic> buildCreatedAtField({required bool isNewAccount}) =>
    isNewAccount ? {'createdAt': FieldValue.serverTimestamp()} : {};
