/// The WES2 app-bar greeting from the athlete's profile gender
/// (`users/{uid}.profile.gender`), never from the separate scoring `sex`.
///
/// Stored values are free-form strings; production holds 'male' and
/// 'female'. Matching is trimmed and case-insensitive:
///   * male and its existing aliases (man, boy)       → 'Welcome king'
///   * female and its existing aliases (woman, girl)  → 'Welcome queen'
///   * any other explicit selection (non-binary, other, a custom value, …)
///                                                     → 'Welcome sovereign'
///   * null, missing, blank or a non-string value      → 'Welcome' (unchanged)
///   * an explicit "prefer not to say" is no selection → 'Welcome'
/// An unrecognised value is therefore never assumed to be king or queen.
library;

const String kWes2GreetingDefault = 'Welcome';
const String kWes2GreetingKing = 'Welcome king';
const String kWes2GreetingQueen = 'Welcome queen';
const String kWes2GreetingSovereign = 'Welcome sovereign';

const Set<String> _male = <String>{'male', 'man', 'boy'};
const Set<String> _female = <String>{'female', 'woman', 'girl'};
const Set<String> _noSelection = <String>{
  'prefer not to say',
  'prefer not to answer',
  'rather not say',
};

/// The greeting for a raw `profile.gender` value.
String wes2GreetingForGender(Object? rawGender) {
  if (rawGender is! String) return kWes2GreetingDefault;
  final String gender = rawGender.trim().toLowerCase();
  if (gender.isEmpty || _noSelection.contains(gender)) {
    return kWes2GreetingDefault;
  }
  if (_male.contains(gender)) return kWes2GreetingKing;
  if (_female.contains(gender)) return kWes2GreetingQueen;
  return kWes2GreetingSovereign;
}
