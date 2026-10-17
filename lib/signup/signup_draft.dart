/// The in-memory draft for ONE signup attempt, spanning both pages.
///
/// Owned by the signup attempt in [SignupCoordinator], not by any route, so
/// destroying and recreating either page — Back, system/predictive Back, a
/// username collision, an auth-driven rebuild — never loses what the member
/// entered. Page 2 binds its controls directly to [onboarding]; Page 1
/// mirrors every field into [identity] as it changes.
///
/// Memory only. Nothing here, and in particular never the password, is
/// written to SharedPreferences, disk, logs or analytics. The draft is wiped
/// on verified completion and on cancellation, and a new attempt always
/// starts from a fresh draft, so one member's answers cannot leak into
/// another's signup.
library;

import '../signup_validation.dart' show formatDobForStorage;
import 'onboarding_models.dart';

/// Page 1 values.
class SignupIdentityDraft {
  String username = '';
  String fullName = '';

  /// The picked calendar day. Persisted as `dd-mm-yyyy` via [dobStorage].
  DateTime? dob;

  /// 'M' | 'F' | 'N', or null when not chosen.
  String? sex;

  String email = '';
  String password = '';
  String confirmPassword = '';

  /// DOB in the persisted `dd-mm-yyyy` format, or null when not picked.
  String? get dobStorage => dob == null ? null : formatDobForStorage(dob!);
}

class SignupDraft {
  final SignupIdentityDraft identity = SignupIdentityDraft();
  final OnboardingFormData onboarding = OnboardingFormData();

  /// Clears the credentials. Called once the draft is no longer needed.
  void wipeSecrets() {
    identity.password = '';
    identity.confirmPassword = '';
  }
}
