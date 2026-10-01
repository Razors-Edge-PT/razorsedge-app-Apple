/// Matches a spoken athlete reference ("Ruby Cakes", "Mr Walker", "Coded NZ",
/// "r u b y") against the athletes the signed-in coach may act on.
///
/// Conservative by design. Every candidate gets the score of its strongest
/// signal; one clear winner is chosen, several close ones are asked about, and
/// a weak best match is never acted on. The list itself comes only from the
/// coach roster, so no spoken name can reach an athlete outside it.
library;

import '../aurelian_exercise_match.dart' show editDistance;
import 'action_ports.dart';

/// Minimum score to act without asking.
const int kAthleteActScore = 60;

/// A runner-up within this many points of the best is asked about.
const int kAthleteMargin = 15;

class AthleteMatch {
  const AthleteMatch._(this.chosen, this.ask);

  final AthleteCandidate? chosen;
  final List<AthleteCandidate> ask;

  bool get isNone => chosen == null && ask.isEmpty;
  bool get isAmbiguous => ask.isNotEmpty;
}

const Set<String> _honorifics = <String>{
  'mr',
  'mrs',
  'ms',
  'miss',
  'mx',
  'dr',
  'coach',
  'sir'
};
const Set<String> _selfWords = <String>{
  'me',
  'myself',
  'my account',
  'my own account',
  'my profile',
  'self'
};
const Set<String> _filler = <String>{
  'the',
  'athlete',
  'user',
  'account',
  'called',
  'named',
  'goodlift',
  'good',
  'lift'
};

/// Lower-case words; spelled-out letters ("r u b y") are joined into one word.
List<String> spokenWords(String spoken) {
  final List<String> raw = spoken
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9@.\s]"), ' ')
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .toList();
  final List<String> out = <String>[];
  final StringBuffer letters = StringBuffer();
  void flush() {
    if (letters.isNotEmpty) {
      out.add(letters.toString());
      letters.clear();
    }
  }

  for (final String w in raw) {
    final String bare = w.replaceAll('.', '');
    if (bare.length == 1 && RegExp(r'[a-z0-9]').hasMatch(bare)) {
      letters.write(bare);
    } else {
      flush();
      out.add(w);
    }
  }
  flush();
  return out;
}

String _compact(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

List<String> _nameWords(String s) => s
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((String w) => w.isNotEmpty)
    .toList();

/// Trailing digits and separators dropped: "ruby_cakes12" → "rubycakes".
String _stem(String username) =>
    _compact(username).replaceAll(RegExp(r'\d+$'), '');

int scoreAthlete(String spoken, AthleteCandidate c) {
  final List<String> words = spokenWords(spoken)
      .where((String w) => !_honorifics.contains(w) && !_filler.contains(w))
      .toList();
  if (words.isEmpty) return 0;
  final String said = words.join();
  final String saidSpaced = words.join(' ');
  final String user = _compact(c.username);
  final String email = c.email.trim().toLowerCase();
  final String emailLocal =
      email.contains('@') ? _compact(email.split('@').first) : _compact(email);
  final List<String> names = <String>[c.fullName, c.displayName]
      .where((String n) => n.trim().isNotEmpty)
      .toList();

  int best = 0;
  void take(int s) {
    if (s > best) best = s;
  }

  // Exact.
  if (user.isNotEmpty && user == said) take(100);
  if (email.isNotEmpty &&
      (email == saidSpaced.replaceAll(' ', '') || emailLocal == said)) {
    take(100);
  }
  for (final String n in names) {
    if (_compact(n) == said) take(100);
  }
  // Username with its trailing digits omitted ("coded nz" → "codednz7").
  if (user.isNotEmpty && _stem(c.username) == said && said.length >= 3) {
    take(90);
  }
  // Every spoken word is a whole word of the full or profile/business name.
  for (final String n in names) {
    final List<String> nw = _nameWords(n);
    if (words.every(nw.contains) && words.join().length >= 3) {
      take(words.length >= 2 ? 85 : 75);
    }
  }
  // Username prefix (≥ 4 letters spoken).
  if (user.isNotEmpty && said.length >= 4 && user.startsWith(said)) take(70);
  if (emailLocal.isNotEmpty &&
      said.length >= 4 &&
      emailLocal.startsWith(said)) {
    take(65);
  }
  // Name prefix of a single word ("rub" for "Ruby") — weak.
  for (final String n in names) {
    if (words.length == 1 &&
        said.length >= 4 &&
        _nameWords(n).any((String w) => w.startsWith(said))) {
      take(55);
    }
  }
  // A close spelling of the username or a full name (recogniser slips).
  if (said.length >= 5) {
    for (final String target in <String>[user, ...names.map(_compact)]) {
      if (target.isEmpty) continue;
      final int limit = said.length >= 9 ? 2 : 1;
      if ((target.length - said.length).abs() <= limit &&
          editDistance(said, target, limit) <= limit) {
        take(50);
      }
    }
  }
  return best;
}

bool isSelfReference(String spoken) {
  final String s = spokenWords(spoken).join(' ');
  return _selfWords.contains(s);
}

/// Resolves [spoken] among [roster]. [choices] are labels picked in answer to
/// an earlier "which one?"; one is accepted only if it is among the close
/// candidates found now.
AthleteMatch matchAthlete(String spoken, List<AthleteCandidate> roster,
    {List<String> choices = const <String>[]}) {
  if (isSelfReference(spoken)) {
    final List<AthleteCandidate> self =
        roster.where((AthleteCandidate c) => c.isSelf).toList();
    return self.length == 1
        ? AthleteMatch._(self.single, const <AthleteCandidate>[])
        : const AthleteMatch._(null, <AthleteCandidate>[]);
  }
  final List<({AthleteCandidate c, int s})> scored =
      <({AthleteCandidate c, int s})>[
    for (final AthleteCandidate c in roster) (c: c, s: scoreAthlete(spoken, c)),
  ]..removeWhere((e) => e.s < 50);
  if (scored.isEmpty) return const AthleteMatch._(null, <AthleteCandidate>[]);
  scored.sort((a, b) => b.s.compareTo(a.s));
  final int best = scored.first.s;
  final List<AthleteCandidate> close = <AthleteCandidate>[
    for (final e in scored)
      if (e.s >= best - kAthleteMargin) e.c,
  ];
  if (close.length == 1 && best >= kAthleteActScore) {
    return AthleteMatch._(close.single, const <AthleteCandidate>[]);
  }
  final Map<String, AthleteCandidate> labelled = athleteLabels(close);
  for (final String choice in choices) {
    final AthleteCandidate? picked = labelled[choice];
    if (picked != null) {
      return AthleteMatch._(picked, const <AthleteCandidate>[]);
    }
  }
  // A lone weak match is asked about too ("Did you mean Ruby Cakes?").
  return AthleteMatch._(null, close);
}

/// Distinct labels for a "which one?": the usual label, and the email where
/// two candidates would otherwise read the same.
Map<String, AthleteCandidate> athleteLabels(List<AthleteCandidate> candidates) {
  final Map<String, int> counts = <String, int>{};
  for (final AthleteCandidate c in candidates) {
    counts[c.label] = (counts[c.label] ?? 0) + 1;
  }
  final Map<String, AthleteCandidate> out = <String, AthleteCandidate>{};
  for (final AthleteCandidate c in candidates) {
    String label = c.label;
    if ((counts[label] ?? 0) > 1 && c.email.isNotEmpty) {
      label = '$label (${c.email})';
    }
    out.putIfAbsent(label, () => c);
  }
  return out;
}
