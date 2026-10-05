/// The choices of the Sex / Gender selector, shared by onboarding and
/// Settings so their wording cannot drift apart.
///
/// Keys are the values stored in `users/{uid}.sex` and read by scoring; they
/// must not change. Values are only what the user sees, in display order.
library;

const Map<String, String> kSexOptionLabels = <String, String>{
  'M': 'Male',
  'F': 'Female',
  'N': 'Yes.',
};
