/// Resolves a spoken exercise name for an Aurelian action, in this order:
///
///   1. the exact canonical GoodLift name;
///   2. the normalised name (case, punctuation, spacing, word order, plurals —
///      the existing voice matcher's strong tiers);
///   3. the explicit alias map below ("bench press" → "Bench Press, Barbell");
///   4. the athlete's own history, when it clearly favours one candidate;
///   5. the current workout (an exercise already in the day wins over the
///      catalogue);
///   6. otherwise a "which one?".
///
/// A close-spelling guess is allowed only for non-destructive actions and only
/// with a clear margin (the existing matcher's fuzzy tier). Nothing here ever
/// maps a name to a materially different exercise to avoid asking.
library;

import '../aurelian_exercise_match.dart';

/// Spoken (normalised) → canonical names, most usual first. An alias resolves
/// only to names that really exist in the list searched; when it lists several
/// that exist, the user is asked (two Larsen entries stay two choices).
const Map<String, List<String>> kExerciseAliases = <String, List<String>>{
  'bench': <String>['Bench Press, Barbell'],
  'bench press': <String>['Bench Press, Barbell'],
  'barbell bench': <String>['Bench Press, Barbell'],
  'barbell bench press': <String>['Bench Press, Barbell'],
  'flat bench': <String>['Bench Press, Barbell'],
  'flat bench press': <String>['Bench Press, Barbell'],
  'dumbbell bench': <String>['Flat Bench Dumbbell Press'],
  'dumbbell bench press': <String>['Flat Bench Dumbbell Press'],
  'db bench': <String>['Flat Bench Dumbbell Press'],
  'flat dumbbell bench': <String>['Flat Bench Dumbbell Press'],
  'flat dumbbell press': <String>['Flat Bench Dumbbell Press'],
  'larsen press': <String>['Bench Press, Larsen Press', 'Larsen Bench Press'],
  'larson press': <String>['Bench Press, Larsen Press', 'Larsen Bench Press'],
  'larsen bench': <String>['Bench Press, Larsen Press', 'Larsen Bench Press'],
  'larson bench': <String>['Bench Press, Larsen Press', 'Larsen Bench Press'],
  'larson bench press': <String>[
    'Bench Press, Larsen Press',
    'Larsen Bench Press'
  ],
  'incline dumbbell press': <String>['Incline Bench Dumbbell Press'],
  'incline dumbbell bench': <String>['Incline Bench Dumbbell Press'],
  'incline db press': <String>['Incline Bench Dumbbell Press'],
  'incline bench': <String>['Incline Press, Barbell'],
  'incline bench press': <String>['Incline Press, Barbell'],
  'incline barbell press': <String>['Incline Press, Barbell'],
  'close grip bench': <String>['Bench Press, Narrow Grip'],
  'narrow grip bench': <String>['Bench Press, Narrow Grip'],
  'touch and go bench': <String>['Bench Press, Touch n Go'],
  'touch and go': <String>['Bench Press, Touch n Go'],
  'pin press': <String>['Bench Press, Pin Press'],
  'long pause bench': <String>['Bench Press, Long Pause'],
  'squat': <String>['Back Squat, Barbell'],
  'back squat': <String>['Back Squat, Barbell'],
  'barbell squat': <String>['Back Squat, Barbell'],
  'front squat': <String>['Front Squat, Barbell'],
  'deadlift': <String>['Deadlift, Conventional'],
  'conventional deadlift': <String>['Deadlift, Conventional'],
  'barbell row': <String>['Bent Over Row, Barbell'],
  'bent over row': <String>['Bent Over Row, Barbell'],
};

class ExerciseResolution<T> {
  const ExerciseResolution._(this.chosen, this.ask, this.via);

  final T? chosen;
  final List<T> ask;

  /// Which step decided ("exact", "alias", "history", …) — for diagnostics.
  final String? via;

  bool get isNone => chosen == null && ask.isEmpty;
  bool get isAmbiguous => ask.isNotEmpty;
}

/// [candidates] is what the action may pick from (the day's exercises, or the
/// catalogue for adding). [usage] counts the athlete's past sessions per
/// exercise id; [inWorkout] the ids already in the day. [choices] are earlier
/// "which one?" answers (labels); one counts only if among today's candidates.
/// Destructive actions pass neither [allowFuzzy] nor [useHistory]: a removal
/// never acts on a guess.
ExerciseResolution<T> resolveExercise<T>(
  String spoken,
  List<T> candidates, {
  required String Function(T) nameOf,
  required String Function(T) idOf,
  String Function(T)? labelOf,
  Map<String, int> usage = const <String, int>{},
  Set<String> inWorkout = const <String>{},
  List<String> choices = const <String>[],
  bool allowFuzzy = false,
  bool useHistory = true,
}) {
  final String Function(T) label = labelOf ?? nameOf;
  ExerciseResolution<T> settle(List<T> hits, String via) {
    if (hits.length == 1) {
      return ExerciseResolution<T>._(hits.single, <T>[], via);
    }
    for (final String choice in choices) {
      final List<T> picked = hits.where((T c) => label(c) == choice).toList();
      if (picked.length == 1) {
        return ExerciseResolution<T>._(picked.single, <T>[], 'choice');
      }
    }
    return ExerciseResolution<T>._(null, hits, via);
  }

  final String target = normaliseExerciseName(spoken);
  if (target.isEmpty) return ExerciseResolution<T>._(null, <T>[], null);

  // 1. Exact canonical name.
  final List<T> exact = candidates
      .where((T c) =>
          nameOf(c).trim().toLowerCase() == spoken.trim().toLowerCase())
      .toList();
  if (exact.isNotEmpty) return settle(exact, 'exact');

  // 2. Normalised (exact words, compact, reordered).
  final ExerciseMatch<T> m = matchExercise<T>(spoken, candidates, nameOf);
  if (!m.isNone && m.strength != ExerciseMatchStrength.subset) {
    return settle(m.matches, 'normalised');
  }

  // 3. Alias.
  final List<String>? alias = kExerciseAliases[target];
  if (alias != null) {
    final Set<String> wanted = alias.map(normaliseExerciseName).toSet();
    final List<T> hits = candidates
        .where((T c) => wanted.contains(normaliseExerciseName(nameOf(c))))
        .toList();
    if (hits.isNotEmpty) return settle(hits, 'alias');
  }

  // The weaker tiers propose a list; history and context may then narrow it.
  List<T> pool = m.isNone ? <T>[] : m.matches;
  String via = 'subset';
  if (pool.isEmpty && allowFuzzy) {
    final ExerciseMatch<T> fuzzy =
        matchExercise<T>(spoken, candidates, nameOf, allowFuzzy: true);
    if (fuzzy.strength == ExerciseMatchStrength.fuzzy) {
      pool = fuzzy.matches;
      via = 'fuzzy';
    }
  }
  if (pool.isEmpty) return ExerciseResolution<T>._(null, <T>[], null);
  if (pool.length == 1) return ExerciseResolution<T>._(pool.single, <T>[], via);

  // 4. History: only a clear favourite (≥ 3 sessions and ≥ twice the next).
  final List<T> byUse = List<T>.of(pool)
    ..sort((T a, T b) => (usage[idOf(b)] ?? 0).compareTo(usage[idOf(a)] ?? 0));
  final int top = usage[idOf(byUse[0])] ?? 0;
  final int next = usage[idOf(byUse[1])] ?? 0;
  if (useHistory && top >= 3 && top >= 2 * next) {
    return ExerciseResolution<T>._(byUse[0], <T>[], 'history');
  }

  // 5. Context: exactly one candidate is already in today's workout.
  final List<T> here =
      pool.where((T c) => inWorkout.contains(idOf(c))).toList();
  if (here.length == 1) {
    return ExerciseResolution<T>._(here.single, <T>[], 'workout');
  }

  // 6. Ask.
  return settle(pool, via);
}
