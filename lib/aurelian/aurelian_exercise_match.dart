/// Matches a spoken exercise name to the exercises a screen actually offers.
///
/// Deterministic and conservative. Tiers, first that matches wins:
///   1. the same words: case, punctuation and spacing ignored
///      ("select bench press barbell" = "Bench Press, Barbell");
///   2. the same letters with the spaces removed ("lat pull down" = "Lat Pulldown");
///   3. the same set of words in another order, plurals ignored
///      ("barbell bench press", "back squats" = "Back Squat");
///   4. every spoken word is one of the exercise's words ("bench press" is in
///      "Bench Press, Barbell" and in "Bench Press, Dumbbell": a "which one?");
///   5. a close spelling (a small edit distance, see [_fuzzy]) — only when
///      [allowFuzzy], and only with a clear margin over every other exercise.
/// One match is chosen; several are returned as a "which one?" — never merged
/// or guessed, so two genuinely different exercises with similar names both
/// stay separate choices. Commands that delete or restructure never pass
/// [allowFuzzy]: a misheard name must not remove the wrong exercise.
library;

/// Lower-case letters and digits only, words separated by one space.
String normaliseExerciseName(String name) => name
    .toLowerCase()
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// How a match was found; weaker tiers come later.
enum ExerciseMatchStrength { exact, compact, reordered, subset, fuzzy }

class ExerciseMatch<T> {
  const ExerciseMatch._(this.matches, [this.strength]);

  /// Every candidate of the winning tier (empty = no match).
  final List<T> matches;

  /// The tier that matched; null when nothing did.
  final ExerciseMatchStrength? strength;

  bool get isNone => matches.isEmpty;
  bool get isUnique => matches.length == 1;
  bool get isAmbiguous => matches.length > 1;
  T get single => matches.single;
}

ExerciseMatch<T> matchExercise<T>(
  String spoken,
  Iterable<T> candidates,
  String Function(T) nameOf, {
  bool allowFuzzy = false,
}) {
  final String target = normaliseExerciseName(spoken);
  if (target.isEmpty) return ExerciseMatch<T>._(<T>[]);
  final List<T> all = candidates.toList();
  final List<String> names =
      all.map((T c) => normaliseExerciseName(nameOf(c))).toList();

  ExerciseMatch<T>? tier(ExerciseMatchStrength s, bool Function(String) test) {
    final List<T> hits = <T>[
      for (int i = 0; i < all.length; i++)
        if (test(names[i])) all[i],
    ];
    return hits.isEmpty ? null : ExerciseMatch<T>._(hits, s);
  }

  final String compact = target.replaceAll(' ', '');
  final List<String> words = _singular(target)..sort();
  final Set<String> wordSet = words.toSet();
  return tier(ExerciseMatchStrength.exact, (String n) => n == target) ??
      tier(ExerciseMatchStrength.compact,
          (String n) => n.replaceAll(' ', '') == compact) ??
      tier(ExerciseMatchStrength.reordered, (String n) {
        final List<String> w = _singular(n)..sort();
        return w.length == words.length && _sameList(w, words);
      }) ??
      tier(ExerciseMatchStrength.subset, (String n) {
        final Set<String> w = _singular(n).toSet();
        return w.length > wordSet.length && w.containsAll(wordSet);
      }) ??
      (allowFuzzy ? _fuzzy(target, all, names) : null) ??
      ExerciseMatch<T>._(<T>[]);
}

/// Tier 5: names at most 2 edits (and at most a fifth of the spoken length)
/// away, compared without spaces or plural "s". The best is chosen only when
/// every other exercise is at least 2 edits further; anything within 1 edit of
/// the best is asked about instead.
ExerciseMatch<T>? _fuzzy<T>(String target, List<T> all, List<String> names) {
  final String t = _singular(target).join();
  final int limit = (t.length ~/ 5).clamp(0, 2);
  if (limit < 1) return null;
  final List<({T c, int d})> near = <({T c, int d})>[];
  for (int i = 0; i < all.length; i++) {
    final String n = _singular(names[i]).join();
    if ((n.length - t.length).abs() > limit) continue;
    final int d = editDistance(t, n, limit);
    if (d <= limit) near.add((c: all[i], d: d));
  }
  if (near.isEmpty) return null;
  near.sort((a, b) => a.d.compareTo(b.d));
  final int best = near.first.d;
  return ExerciseMatch<T>._(
    <T>[for (final e in near) if (e.d <= best + 1) e.c],
    ExerciseMatchStrength.fuzzy,
  );
}

/// Words with a plural "s" dropped ("squats" → "squat"; "press" is kept).
List<String> _singular(String normalised) => normalised
    .split(' ')
    .where((String w) => w.isNotEmpty)
    .map((String w) => w.length > 3 && w.endsWith('s') && !w.endsWith('ss')
        ? w.substring(0, w.length - 1)
        : w)
    .toList();

/// Levenshtein distance; stops early (returning [cap] + 1) once it exceeds [cap].
int editDistance(String a, String b, [int cap = 1 << 30]) {
  List<int> prev = List<int>.generate(b.length + 1, (int i) => i);
  for (int i = 1; i <= a.length; i++) {
    final List<int> cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    int rowMin = i;
    for (int j = 1; j <= b.length; j++) {
      final int cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      int v = prev[j] + 1;
      if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1;
      if (prev[j - 1] + cost < v) v = prev[j - 1] + cost;
      cur[j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > cap) return cap + 1;
    prev = cur;
  }
  return prev[b.length];
}

/// Resolves an answer to an earlier "which one?": [choice] must be exactly one
/// of the candidate labels this screen would offer for [spoken] right now, or
/// the list has changed and nothing is chosen.
T? resolveChoice<T>(
  String spoken,
  String choice,
  Iterable<T> candidates,
  String Function(T) nameOf,
  String Function(T) labelOf, {
  bool allowFuzzy = false,
}) {
  final ExerciseMatch<T> m =
      matchExercise<T>(spoken, candidates, nameOf, allowFuzzy: allowFuzzy);
  final List<T> chosen = m.matches.where((T c) => labelOf(c) == choice).toList();
  return chosen.length == 1 ? chosen.single : null;
}

/// The outcome of resolving one spoken name for a command.
class NamedResolution<T> {
  const NamedResolution._(this.chosen, this.ask);

  /// The exercise meant; null when nothing matched or it is still unclear.
  final T? chosen;

  /// When unclear: the candidates to ask about ("Which Bench Press?").
  final List<T> ask;

  bool get isNone => chosen == null && ask.isEmpty;
  bool get isAmbiguous => ask.isNotEmpty;
}

/// Resolves [spoken] for a command that may already carry answers ([choices])
/// to its earlier "which one?" questions. Any answer that is one of the
/// candidates found now settles it; a stale answer (the list changed) does not,
/// and the question is asked again. Several names in one command ask about one
/// name at a time, so each answer only ever fits one of them.
NamedResolution<T> resolveNamed<T>(
  String spoken,
  Iterable<T> candidates,
  String Function(T) nameOf,
  String Function(T) labelOf, {
  List<String> choices = const <String>[],
  bool allowFuzzy = false,
}) {
  final ExerciseMatch<T> m =
      matchExercise<T>(spoken, candidates, nameOf, allowFuzzy: allowFuzzy);
  if (m.isUnique) return NamedResolution<T>._(m.single, <T>[]);
  if (m.isNone) return NamedResolution<T>._(null, <T>[]);
  for (final String choice in choices) {
    final List<T> picked =
        m.matches.where((T c) => labelOf(c) == choice).toList();
    if (picked.length == 1) return NamedResolution<T>._(picked.single, <T>[]);
  }
  return NamedResolution<T>._(null, m.matches);
}

bool _sameList(List<String> a, List<String> b) {
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
