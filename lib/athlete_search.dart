/// Athlete search shared by the Coach Dashboard's search box and Aurelian's
/// voice athlete switching, so a typed search and a spoken one find the same
/// people.
///
/// Matches on full name, username, display name and e-mail; case, spacing and
/// punctuation never matter ("chicken911" finds "chicken_911@gmail.com",
/// "michael helps" finds "Michael  Helps"); every typed word may be the start
/// of a name word ("mic hel"); a near spelling of a whole name or username
/// is found too. It only ever searches the list it is given — the coach's
/// own roster — so it cannot widen who is reachable.
library;

/// The searchable fields of one athlete.
class AthleteSearchFields {
  const AthleteSearchFields({
    this.username = '',
    this.displayName = '',
    this.fullName = '',
    this.email = '',
  });

  final String username;
  final String displayName;
  final String fullName;
  final String email;
}

/// Lower case, letters and digits only, single spaces.
String athleteSearchText(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// Lower case letters and digits only (no spaces): "Chicken_911" → "chicken911".
String athleteCompact(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Levenshtein distance; stops early (returning [cap] + 1) once it exceeds [cap].
int athleteEditDistance(String a, String b, [int cap = 1 << 30]) {
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

/// How well [query] finds [f] for a typed search (0 = not at all). Higher is
/// better: exact (100) > whole-field or word prefixes (80–90) > substring (60)
/// > near spelling (40).
int athleteSearchScore(String query, AthleteSearchFields f) {
  final String q = athleteSearchText(query);
  final String qc = athleteCompact(query);
  if (q.isEmpty) return 0;
  final List<String> fields = <String>[
    f.fullName,
    f.username,
    f.displayName,
    f.email
  ].where((String v) => v.trim().isNotEmpty).toList();
  int best = 0;
  void take(int s) {
    if (s > best) best = s;
  }

  final String emailLower = f.email.trim().toLowerCase();
  if (emailLower.isNotEmpty && emailLower == query.trim().toLowerCase())
    take(100);
  for (final String v in fields) {
    final String vt = athleteSearchText(v);
    final String vc = athleteCompact(v);
    if (vt == q || vc == qc) take(95);
    if (vc.startsWith(qc) && qc.length >= 2) take(85);
    // Every typed word starts a word of the field ("mic hel" → Michael Helps).
    final List<String> qw = q.split(' ');
    final List<String> vw = vt.split(' ');
    if (qw.every((String w) => vw.any((String x) => x.startsWith(w)))) take(80);
    if (qc.length >= 3 && vc.contains(qc)) take(60);
  }
  // A near spelling of a whole name word, username or e-mail name.
  if (best == 0 && qc.length >= 5) {
    // Two edits from six letters (a swapped pair, "micheal"), else one.
    final int limit = qc.length >= 6 ? 2 : 1;
    for (final String v in fields) {
      final List<String> targets = <String>[
        athleteCompact(v.split('@').first),
        ...athleteSearchText(v).split(' '),
      ];
      for (final String t in targets) {
        if (t.isNotEmpty &&
            (t.length - qc.length).abs() <= limit &&
            athleteEditDistance(qc, t, limit) <= limit) {
          take(40);
        }
      }
    }
  }
  return best;
}

/// Whether the typed [query] finds [f] (an empty query finds everyone).
bool athleteMatchesSearch(String query, AthleteSearchFields f) =>
    athleteSearchText(query).isEmpty || athleteSearchScore(query, f) > 0;
