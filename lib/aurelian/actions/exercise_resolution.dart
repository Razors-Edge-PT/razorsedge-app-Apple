/// Resolves a spoken exercise name for an Aurelian action, in this order:
///
///   1. the exact canonical GoodLift name;
///   2. the normalised name (case, punctuation, spacing, word order, plurals -
///      the existing voice matcher's strong tiers);
///   3. the explicit alias map below ("bench" -> "Bench Press, Barbell",
///      "pulldowns" -> the lat pulldowns); several aliased exercises are narrowed
///      by the open workout, then the athlete's history, then - for a
///      non-destructive action - the alias's usual variant (listed first);
///   4. an exercise already in the current workout;
///   5. the athlete's own history, when it clearly favours one candidate;
///   6. a close spelling, word by word or whole (non-destructive actions only,
///      with a clear margin);
///   7. otherwise a "which one?".
///
/// The exercise an earlier step of the same request added is named by its
/// canonical name (Aurelian binds it), so it is found at step 1. Nothing here
/// ever maps a name to a materially different exercise to avoid asking.
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
  'larsen': <String>['Bench Press, Larsen Press', 'Larsen Bench Press'],
  'larson': <String>['Bench Press, Larsen Press', 'Larsen Bench Press'],
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
  'barbell rows': <String>['Bent Over Row, Barbell'],
  'bent over row': <String>['Bent Over Row, Barbell'],
  'bent over rows': <String>['Bent Over Row, Barbell'],
  'row': <String>['Bent Over Row, Barbell'],
  'rows': <String>['Bent Over Row, Barbell'],
  'squats': <String>['Back Squat, Barbell'],
  'back squats': <String>['Back Squat, Barbell'],
  'deadlifts': <String>['Deadlift, Conventional'],
  'pulldown': _pulldowns,
  'pulldowns': _pulldowns,
  'pull down': _pulldowns,
  'pull downs': _pulldowns,
  'lat pulldown': _pulldowns,
  'lat pulldowns': _pulldowns,
  'lat pull down': _pulldowns,
  'lat pull downs': _pulldowns,
  'lat pull': _pulldowns,
  'lats': _pulldowns,
  'bulgarian': _bulgarians,
  'bulgarians': _bulgarians,
  'bulgarian split squat': _bulgarians,
  'bulgarian split squats': _bulgarians,
  'bulgarian squat': _bulgarians,
  'bulgarian squats': _bulgarians,
  'split squat': _bulgarians,
  'split squats': _bulgarians,
};

/// The lat pulldowns, the usual one first.
const List<String> _pulldowns = <String>[
  'Lat Pull Down, Wide Arm',
  'Lat Pull Down',
  'Lat Pull Down, Supinated',
  'Machine Lat Pull Down',
  'Lat Pull Down, Unilateral',
];

/// The Bulgarian split squats, the usual one first.
const List<String> _bulgarians = <String>[
  'Bulgarian Split Squat',
  'Bulgarian Split Squat, Deficit',
];

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
/// never acts on a guess (nor on an alias's usual variant).
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

  /// Several candidates: the one in today's workout, else a clear favourite in
  /// the athlete's history, else null.
  ExerciseResolution<T>? narrow(List<T> pool) {
    final List<T> here =
        pool.where((T c) => inWorkout.contains(idOf(c))).toList();
    if (here.length == 1) {
      return ExerciseResolution<T>._(here.single, <T>[], 'workout');
    }
    if (useHistory && pool.length > 1) {
      // Only a clear favourite (at least 3 sessions and twice the next).
      final List<T> byUse = List<T>.of(pool)
        ..sort(
            (T a, T b) => (usage[idOf(b)] ?? 0).compareTo(usage[idOf(a)] ?? 0));
      final int top = usage[idOf(byUse[0])] ?? 0;
      final int next = usage[idOf(byUse[1])] ?? 0;
      if (top >= 3 && top >= 2 * next) {
        return ExerciseResolution<T>._(byUse[0], <T>[], 'history');
      }
    }
    return null;
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

  // 3. Alias: narrowed by the workout and history; a non-destructive action
  //    may then take the usual variant (listed first).
  final List<String>? alias = kExerciseAliases[target];
  if (alias != null) {
    final List<String> wanted = alias.map(normaliseExerciseName).toList();
    final List<T> hits = candidates
        .where((T c) => wanted.contains(normaliseExerciseName(nameOf(c))))
        .toList();
    if (hits.length == 1) return settle(hits, 'alias');
    if (hits.length > 1) {
      for (final String choice in choices) {
        final List<T> picked = hits.where((T c) => label(c) == choice).toList();
        if (picked.length == 1) {
          return ExerciseResolution<T>._(picked.single, <T>[], 'choice');
        }
      }
      final ExerciseResolution<T>? narrowed = narrow(hits);
      if (narrowed != null) return narrowed;
      if (allowFuzzy) {
        hits.sort((T a, T b) => wanted
            .indexOf(normaliseExerciseName(nameOf(a)))
            .compareTo(wanted.indexOf(normaliseExerciseName(nameOf(b)))));
        return ExerciseResolution<T>._(hits.first, <T>[], 'alias default');
      }
      return settle(hits, 'alias');
    }
  }

  // The weaker tiers propose a list; the workout and history may narrow it.
  List<T> pool = m.isNone ? <T>[] : m.matches;
  String via = 'subset';
  if (pool.isEmpty && allowFuzzy) {
    final ExerciseMatch<T> fuzzy =
        matchExercise<T>(spoken, candidates, nameOf, allowFuzzy: true);
    if (fuzzy.strength == ExerciseMatchStrength.fuzzy) {
      pool = fuzzy.matches;
      via = 'fuzzy';
    } else {
      pool = _wordFuzzy<T>(target, candidates, nameOf);
      via = 'fuzzy words';
    }
  }
  if (pool.isEmpty) return ExerciseResolution<T>._(null, <T>[], null);
  if (pool.length == 1) return ExerciseResolution<T>._(pool.single, <T>[], via);

  // 4. and 5. The workout, then history.
  final ExerciseResolution<T>? narrowed = narrow(pool);
  if (narrowed != null) return narrowed;

  // 6. Ask.
  return settle(pool, via);
}

/// Every spoken word is the same word or a close spelling (one edit, words of
/// four or more letters) of a different word of the name: "bulgarain split
/// squat", "romainian deadlift". Only the candidates with the fewest edits.
List<T> _wordFuzzy<T>(
    String target, List<T> candidates, String Function(T) nameOf) {
  String single(String w) =>
      w.length > 3 && w.endsWith('s') && !w.endsWith('ss')
          ? w.substring(0, w.length - 1)
          : w;
  final List<String> said = target.split(' ').map(single).toList();
  if (said.isEmpty || said.every((String w) => w.length < 4)) return <T>[];
  final List<({T c, int edits})> hits = <({T c, int edits})>[];
  for (final T c in candidates) {
    final List<String> words =
        normaliseExerciseName(nameOf(c)).split(' ').map(single).toList();
    final Set<int> used = <int>{};
    int edits = 0;
    bool all = true;
    for (final String w in said) {
      int found = -1;
      int cost = 2;
      for (int i = 0; i < words.length; i++) {
        if (used.contains(i)) continue;
        if (words[i] == w) {
          found = i;
          cost = 0;
          break;
        }
        if (cost > 1 &&
            w.length >= 4 &&
            (words[i].length - w.length).abs() <= 1 &&
            editDistance(w, words[i], 1) <= 1) {
          found = i;
          cost = 1;
        }
      }
      if (found < 0) {
        all = false;
        break;
      }
      used.add(found);
      edits += cost;
    }
    if (all && edits > 0) hits.add((c: c, edits: edits));
  }
  if (hits.isEmpty) return <T>[];
  int best = hits.first.edits;
  for (final ({T c, int edits}) h in hits) {
    if (h.edits < best) best = h.edits;
  }
  return <T>[
    for (final ({T c, int edits}) h in hits)
      if (h.edits == best) h.c,
  ];
}
