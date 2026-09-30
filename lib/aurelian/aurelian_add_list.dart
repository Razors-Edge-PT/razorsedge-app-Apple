/// Splits a spoken list of exercises ("bench press, suspended high row and back
/// squats") into the names it contains, using the catalogue itself to decide
/// where the joins are: "and" separates two exercises, but it is also part of
/// names like "Clean and Jerk". Every way of grouping the pieces between the
/// separators is scored by how well each group matches the catalogue, and the
/// best grouping wins (ties → fewer, longer names). Pure; no I/O.
library;

import 'aurelian_command.dart';
import 'aurelian_exercise_match.dart';

/// The separators a spoken list uses between names.
const Set<String> _separators = <String>{',', 'and', 'plus', '&', 'then'};

/// Groups spanning more pieces than this are not considered (no exercise name
/// has four separators in it).
const int _maxPiecesPerName = 4;

/// Scores for one group: lower is better.
const int _unique = 0;
const int _subsetUnique = 1;
const int _fuzzyUnique = 2;
const int _ambiguous = 3;
const int _none = 100;

class SpokenList {
  const SpokenList(this.names, {this.error});

  /// The names, in spoken order (as said, not yet resolved).
  final List<String> names;

  /// Why the phrase can't be used (too many names, nothing in it).
  final String? error;
}

/// Splits [phrase] into names, scored against [candidates].
SpokenList splitSpokenList<T>(
  String phrase,
  Iterable<T> candidates,
  String Function(T) nameOf,
) {
  final List<String> pieces = _pieces(phrase);
  if (pieces.isEmpty) return const SpokenList(<String>[], error: 'No exercise named');
  final List<T> all = candidates.toList();

  final Map<String, int> scoreCache = <String, int>{};
  int score(String name) => scoreCache.putIfAbsent(name, () {
        final ExerciseMatch<T> m =
            matchExercise<T>(name, all, nameOf, allowFuzzy: true);
        if (m.isNone) return _none;
        if (m.isAmbiguous) return _ambiguous;
        switch (m.strength!) {
          case ExerciseMatchStrength.subset:
            return _subsetUnique;
          case ExerciseMatchStrength.fuzzy:
            return _fuzzyUnique;
          case ExerciseMatchStrength.exact:
          case ExerciseMatchStrength.compact:
          case ExerciseMatchStrength.reordered:
            return _unique;
        }
      });

  // best[i]: the best grouping of pieces[0..i) as (total score, group count, groups).
  final int n = pieces.length;
  final List<({int score, int count, List<String> names})?> best =
      List<({int score, int count, List<String> names})?>.filled(n + 1, null);
  best[0] = (score: 0, count: 0, names: const <String>[]);
  for (int end = 1; end <= n; end++) {
    for (int start = end - 1; start >= 0 && end - start <= _maxPiecesPerName; start--) {
      final prev = best[start];
      if (prev == null) continue;
      final String name = _join(pieces, start, end);
      final int total = prev.score + score(name);
      final int count = prev.count + 1;
      final cur = best[end];
      if (cur == null ||
          total < cur.score ||
          (total == cur.score && count < cur.count)) {
        best[end] = (score: total, count: count, names: <String>[...prev.names, name]);
      }
    }
  }
  final List<String> names = best[n]!.names;
  if (names.length > kAurelianMaxAdd) {
    return SpokenList(names,
        error: 'Add up to $kAurelianMaxAdd exercises at a time');
  }
  return SpokenList(names);
}

/// The pieces between separators, each with the separator that followed it
/// kept so a group can be rejoined as spoken ("clean and jerk").
List<String> _pieces(String phrase) {
  final String spaced = phrase.replaceAll(',', ' , ').replaceAll('&', ' & ');
  final List<String> tokens = spaced
      .split(RegExp(r'\s+'))
      .map((String t) => t.trim())
      .where((String t) => t.isNotEmpty)
      .toList();
  final List<String> out = <String>[];
  final StringBuffer current = StringBuffer();
  String? pendingSeparator;
  for (final String t in tokens) {
    if (_separators.contains(t.toLowerCase())) {
      if (current.isNotEmpty) {
        out.add(current.toString());
        current.clear();
      }
      // "bench press, and rows": the comma and the "and" are one separator.
      pendingSeparator = t;
      continue;
    }
    if (current.isEmpty && out.isNotEmpty) {
      out[out.length - 1] = '${out.last}\u0000${pendingSeparator ?? ','}';
    }
    if (current.isNotEmpty) current.write(' ');
    current.write(t);
  }
  if (current.isNotEmpty) out.add(current.toString());
  return out;
}

/// Rejoins pieces[start..end) with the separators they were spoken with.
String _join(List<String> pieces, int start, int end) {
  final StringBuffer b = StringBuffer();
  for (int i = start; i < end; i++) {
    final List<String> parts = pieces[i].split('\u0000');
    b.write(parts.first);
    if (i < end - 1) b.write(' ${parts.length > 1 ? parts[1] : 'and'} ');
  }
  return b.toString();
}
