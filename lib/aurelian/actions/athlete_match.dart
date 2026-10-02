/// Matches a spoken athlete reference ("Ruby Cakes", "Mr Walker", "Coded NZ",
/// "r u b y") against the athletes the signed-in coach may act on.
///
/// Conservative by design. Every candidate gets the score of its strongest
/// signal; one clear winner is chosen, several close ones are asked about, and
/// a weak best match is never acted on. The list itself comes only from the
/// coach roster, so no spoken name can reach an athlete outside it.
library;

import '../../athlete_search.dart';
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

List<String> _nameWords(String s) => s
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((String w) => w.isNotEmpty)
    .toList();

/// Trailing digits and separators dropped: "ruby_cakes12" → "rubycakes".
String _stem(String username) =>
    athleteCompact(username).replaceAll(RegExp(r'\d+$'), '');

/// The strength of [spoken] as a reference to [c], strongest signal first:
///
///   100  exact e-mail                 98  exact username
///    99  e-mail, separators ignored   96  exact full name (95 profile name)
///    94  the e-mail's name part       90  username without its trailing digits
///    85  every word of a full name    82  the same e-mail with more digits/_
///    75  one whole name word          70  username prefix (65 e-mail prefix)
///    55  a name word's prefix         50  a near spelling (only ever asked)
int scoreAthlete(String spoken, AthleteCandidate c) {
  final List<String> words = spokenWords(spoken)
      .where((String w) => !_honorifics.contains(w) && !_filler.contains(w))
      .toList();
  if (words.isEmpty) return 0;
  final String said = words.join();
  final String saidCompact = athleteCompact(words.join(' '));
  final String user = athleteCompact(c.username);
  final String email = c.email.trim().toLowerCase();
  final String emailCompact = athleteCompact(email);
  final String emailLocal = email.contains('@')
      ? athleteCompact(email.split('@').first)
      : athleteCompact(email);
  final String emailDomain = email.contains('@') ? email.split('@').last : '';
  final List<String> names = <String>[c.fullName, c.displayName]
      .where((String n) => n.trim().isNotEmpty)
      .toList();

  int best = 0;
  void take(int s) {
    if (s > best) best = s;
  }

  // 1. Exact e-mail (and the same address with its separators ignored).
  if (email.isNotEmpty && email == said) take(100);
  if (said.contains('@') &&
      emailCompact.isNotEmpty &&
      emailCompact == saidCompact) {
    take(99);
  }
  // 2. Exact username.
  if (user.isNotEmpty && user == saidCompact) take(98);
  // 3. Exact full name, then profile name.
  if (c.fullName.trim().isNotEmpty &&
      athleteCompact(c.fullName) == saidCompact) {
    take(96);
  }
  if (c.displayName.trim().isNotEmpty &&
      athleteCompact(c.displayName) == saidCompact) {
    take(95);
  }
  if (emailLocal.isNotEmpty && emailLocal == saidCompact) take(94);
  // Username with its trailing digits omitted ("coded nz" → "codednz7").
  if (user.isNotEmpty &&
      _stem(c.username) == saidCompact &&
      saidCompact.length >= 3) {
    take(90);
  }
  // The same e-mail with extra digits or separators ("chicken911@gmail.com"
  // for "chicken9113@gmail.com").
  if (said.contains('@') && emailDomain.isNotEmpty) {
    final String spokenLocal = athleteCompact(said.split('@').first);
    final String spokenDomain = said.split('@').last;
    if (spokenDomain == emailDomain &&
        spokenLocal.length >= 4 &&
        emailLocal.startsWith(spokenLocal)) {
      take(82);
    }
  }
  // 4. Every spoken word is a whole word of the full or profile/business name.
  for (final String n in names) {
    final List<String> nw = _nameWords(n);
    if (words.every(nw.contains) && words.join().length >= 3) {
      take(words.length >= 2 ? 85 : 75);
    }
  }
  // Username prefix (at least 4 letters spoken), e-mail name prefix.
  if (user.isNotEmpty &&
      saidCompact.length >= 4 &&
      user.startsWith(saidCompact)) {
    take(70);
  }
  if (emailLocal.isNotEmpty &&
      saidCompact.length >= 4 &&
      emailLocal.startsWith(saidCompact)) {
    take(65);
  }
  // Name prefix of a single word ("rub" for "Ruby") — weak.
  for (final String n in names) {
    if (words.length == 1 &&
        saidCompact.length >= 4 &&
        _nameWords(n).any((String w) => w.startsWith(saidCompact))) {
      take(55);
    }
  }
  // 5. A close spelling of the username or a full name (recogniser slips):
  //    never acted on alone — always asked about.
  if (saidCompact.length >= 5) {
    for (final String target in <String>[user, ...names.map(athleteCompact)]) {
      if (target.isEmpty) continue;
      final int limit = saidCompact.length >= 9 ? 2 : 1;
      if ((target.length - saidCompact.length).abs() <= limit &&
          athleteEditDistance(saidCompact, target, limit) <= limit) {
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
    // The label offered, or either name in it ("Michael Helps (Helpzie)").
    final List<AthleteCandidate> picked = <AthleteCandidate>[
      if (labelled[choice] != null)
        labelled[choice]!
      else
        ...close.where((AthleteCandidate c) =>
            c.label == choice || c.voiceLabel == choice),
    ];
    if (picked.length == 1) {
      return AthleteMatch._(picked.single, const <AthleteCandidate>[]);
    }
  }
  // A lone weak match is asked about too ("Did you mean Ruby Cakes?").
  return AthleteMatch._(null, close);
}

/// Distinct labels for a "which one?": the full name with the username
/// ("Michael Helps (Helpzie)", so either can be said in answer), and the e-mail
/// where two candidates would otherwise read the same.
Map<String, AthleteCandidate> athleteLabels(List<AthleteCandidate> candidates) {
  final Map<String, int> counts = <String, int>{};
  for (final AthleteCandidate c in candidates) {
    counts[c.voiceLabel] = (counts[c.voiceLabel] ?? 0) + 1;
  }
  final Map<String, AthleteCandidate> out = <String, AthleteCandidate>{};
  for (final AthleteCandidate c in candidates) {
    String label = c.voiceLabel;
    if ((counts[label] ?? 0) > 1 && c.email.isNotEmpty) {
      label = '$label (${c.email})';
    }
    out.putIfAbsent(label, () => c);
  }
  return out;
}
