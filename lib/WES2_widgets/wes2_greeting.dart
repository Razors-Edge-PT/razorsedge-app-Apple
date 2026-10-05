/// The WES2 app-bar greeting, resolved from the athlete's onboarding `sex`
/// (`users/{uid}.sex`, 'M'|'F'|'N') and optional profile gender
/// (`users/{uid}.profile.gender`, free-form). Display only: points keep
/// reading `sex` alone and never see this file.
///
/// Matching is trimmed and case-insensitive. In order:
///   1. an explicit answer other than male/female in EITHER field (N — shown
///      as "Yes." —, prefer not to say, other, non-binary, a custom
///      or unrecognised value, …)                      → 'Welcome sovereign'
///   2. an explicit male/female profile.gender         → 'Welcome king/queen'
///   3. an onboarding sex of M/F                        → 'Welcome king/queen'
///   4. neither field supplies a selection              → 'Welcome'
/// Null, missing, blank and non-string values are not selections.
library;

const String kWes2GreetingDefault = 'Welcome';
const String kWes2GreetingKing = 'Welcome king';
const String kWes2GreetingQueen = 'Welcome queen';
const String kWes2GreetingSovereign = 'Welcome sovereign';

const Set<String> _male = <String>{'m', 'male', 'man', 'boy'};
const Set<String> _female = <String>{'f', 'female', 'woman', 'girl'};

enum _Selection { none, male, female, other }

_Selection _selectionOf(Object? raw) {
  if (raw is! String) return _Selection.none;
  final String value = raw.trim().toLowerCase();
  if (value.isEmpty) return _Selection.none;
  if (_male.contains(value)) return _Selection.male;
  if (_female.contains(value)) return _Selection.female;
  return _Selection.other;
}

/// The greeting for the raw `sex` and `profile.gender` values.
String wes2GreetingFor({Object? sex, Object? gender}) {
  final _Selection bySex = _selectionOf(sex);
  final _Selection byGender = _selectionOf(gender);
  if (bySex == _Selection.other || byGender == _Selection.other) {
    return kWes2GreetingSovereign;
  }
  final _Selection chosen = byGender != _Selection.none ? byGender : bySex;
  if (chosen == _Selection.male) return kWes2GreetingKing;
  if (chosen == _Selection.female) return kWes2GreetingQueen;
  return kWes2GreetingDefault;
}

/// The greeting for an already-fetched `users/{uid}` document.
String wes2GreetingForUserDoc(Map<String, dynamic> data) {
  final Object? profile = data['profile'];
  return wes2GreetingFor(
    sex: data['sex'],
    gender: profile is Map ? profile['gender'] : null,
  );
}
