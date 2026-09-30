/// Matches a spoken exercise name to the exercises a screen actually offers.
///
/// Deterministic and conservative. Tiers, first that matches wins:
///   1. the same words: case, punctuation and spacing ignored
///      ("select bench press barbell" = "Bench Press, Barbell");
///   2. the same letters with the spaces removed ("lat pull down" = "Lat Pulldown");
///   3. the same set of words in another order ("barbell bench press").
/// One match is chosen; several are returned as a "which one?" — never merged
/// or guessed, so two genuinely different exercises with similar names both
/// stay separate choices. No similarity scores, no fuzzy distance.
library;

/// Lower-case letters and digits only, words separated by one space.
String normaliseExerciseName(String name) => name
    .toLowerCase()
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

class ExerciseMatch<T> {
  const ExerciseMatch._(this.matches);

  /// Every candidate of the winning tier (empty = no match).
  final List<T> matches;

  bool get isNone => matches.isEmpty;
  bool get isUnique => matches.length == 1;
  bool get isAmbiguous => matches.length > 1;
  T get single => matches.single;
}

ExerciseMatch<T> matchExercise<T>(
  String spoken,
  Iterable<T> candidates,
  String Function(T) nameOf,
) {
  final String target = normaliseExerciseName(spoken);
  if (target.isEmpty) return ExerciseMatch<T>._(<T>[]);
  final List<T> all = candidates.toList();

  final List<T> exact =
      all.where((T c) => normaliseExerciseName(nameOf(c)) == target).toList();
  if (exact.isNotEmpty) return ExerciseMatch<T>._(exact);

  final String compact = target.replaceAll(' ', '');
  final List<T> joined = all
      .where((T c) =>
          normaliseExerciseName(nameOf(c)).replaceAll(' ', '') == compact)
      .toList();
  if (joined.isNotEmpty) return ExerciseMatch<T>._(joined);

  final List<String> words = target.split(' ')..sort();
  final List<T> reordered = all.where((T c) {
    final List<String> w = normaliseExerciseName(nameOf(c)).split(' ')..sort();
    return w.length == words.length && _sameList(w, words);
  }).toList();
  return ExerciseMatch<T>._(reordered);
}

/// Resolves an answer to an earlier "which one?": [choice] must be exactly one
/// of the candidate labels this screen would offer for [spoken] right now, or
/// the list has changed and nothing is chosen.
T? resolveChoice<T>(
  String spoken,
  String choice,
  Iterable<T> candidates,
  String Function(T) nameOf,
  String Function(T) labelOf,
) {
  final ExerciseMatch<T> m = matchExercise<T>(spoken, candidates, nameOf);
  final List<T> chosen = m.matches.where((T c) => labelOf(c) == choice).toList();
  return chosen.length == 1 ? chosen.single : null;
}

bool _sameList(List<String> a, List<String> b) {
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
