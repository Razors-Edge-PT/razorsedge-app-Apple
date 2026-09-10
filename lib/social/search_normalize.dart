/// Normalisation and candidate-term generation for buddy discovery.
///
/// The query side of `functions/social/search_normalize.js`. The index is
/// written by trusted backend code and read here, so both sides must answer
/// "what string is this text, really?" identically — if the writer folds
/// accents and the reader does not, `renee` never finds `Renée` and the index
/// looks broken rather than mismatched. The two files are pinned together by a
/// shared vector table (see `test/social_search_normalize_test.dart` and
/// `functions/test/social_search_normalize.test.js`, which assert the SAME
/// inputs produce the SAME outputs).
///
/// ── Why the folding table is written out ───────────────────────────────────
/// JavaScript gets this for free: `'é'.normalize('NFD')` splits the character
/// into `e` + a combining acute, and stripping the combining range finishes the
/// job. Dart has no Unicode normalisation in its core or in any dependency this
/// project carries, and adding one for a search box is not a trade worth
/// making. So COMPOSED characters are folded by an explicit table, and
/// DECOMPOSED input — which does arrive, from iOS dictation and from pasted
/// text — is handled by stripping the combining range directly.
///
/// The table covers Latin-1 Supplement and Latin Extended-A, which is every
/// accented Latin letter a European name is written with. Scripts outside it
/// (Cyrillic, Greek, CJK) pass through unchanged on BOTH sides, so they still
/// match themselves exactly; they are simply not accent-folded. That is a
/// stated limit, not an accident.
library;

/// Longest prefix stored by the indexer. A longer query falls back to exact
/// `terms` matching. Must equal `MAX_PREFIX` in search_normalize.js.
const int kMaxPrefix = 15;

/// Shortest query the app will send. One character matches a large fraction of
/// any user base, so it is a collection scan wearing a query's clothes.
const int kMinQuery = 2;

/// Combining diacritical marks (U+0300–U+036F), as they arrive in already
/// decomposed input.
bool _isCombiningMark(int rune) => rune >= 0x0300 && rune <= 0x036F;

/// Source characters grouped by the ASCII they fold to.
///
/// Grouped rather than written as a map literal so the table stays readable
/// and a missing character is visible at a glance.
const List<List<String>> _foldingGroups = <List<String>>[
  <String>['àáâãäåāăą', 'a'],
  <String>['ÀÁÂÃÄÅĀĂĄ', 'a'],
  <String>['çćĉċč', 'c'],
  <String>['ÇĆĈĊČ', 'c'],
  <String>['ðďđ', 'd'],
  <String>['ÐĎĐ', 'd'],
  <String>['èéêëēĕėęě', 'e'],
  <String>['ÈÉÊËĒĔĖĘĚ', 'e'],
  <String>['ĝğġģ', 'g'],
  <String>['ĜĞĠĢ', 'g'],
  <String>['ĥħ', 'h'],
  <String>['ĤĦ', 'h'],
  <String>['ìíîïĩīĭįı', 'i'],
  <String>['ÌÍÎÏĨĪĬĮİ', 'i'],
  <String>['ĵ', 'j'],
  <String>['Ĵ', 'j'],
  <String>['ķĸ', 'k'],
  <String>['Ķ', 'k'],
  <String>['ĺļľŀł', 'l'],
  <String>['ĹĻĽĿŁ', 'l'],
  <String>['ñńņňŉ', 'n'],
  <String>['ÑŃŅŇ', 'n'],
  <String>['òóôõöøōŏő', 'o'],
  <String>['ÒÓÔÕÖØŌŎŐ', 'o'],
  <String>['ŕŗř', 'r'],
  <String>['ŔŖŘ', 'r'],
  <String>['śŝşš', 's'],
  <String>['ŚŜŞŠ', 's'],
  <String>['ţťŧ', 't'],
  <String>['ŢŤŦ', 't'],
  <String>['ùúûüũūŭůűų', 'u'],
  <String>['ÙÚÛÜŨŪŬŮŰŲ', 'u'],
  <String>['ŵ', 'w'],
  <String>['Ŵ', 'w'],
  <String>['ýÿŷ', 'y'],
  <String>['ÝŶŸ', 'y'],
  <String>['źżž', 'z'],
  <String>['ŹŻŽ', 'z'],
  // Multi-character expansions. NFD does not produce these on the JS side
  // either, so both files special-case them identically.
  <String>['æ', 'ae'],
  <String>['Æ', 'ae'],
  <String>['œ', 'oe'],
  <String>['Œ', 'oe'],
  <String>['ß', 'ss'],
  <String>['þ', 'th'],
  <String>['Þ', 'th'],
  <String>['ŋ', 'n'],
  <String>['Ŋ', 'n'],
];

Map<int, String>? _foldingTable;

Map<int, String> get _folding {
  final Map<int, String>? built = _foldingTable;
  if (built != null) return built;
  final Map<int, String> table = <int, String>{};
  for (final List<String> group in _foldingGroups) {
    for (final int rune in group[0].runes) {
      table[rune] = group[1];
    }
  }
  return _foldingTable = table;
}

/// True for a character that survives normalisation as itself.
///
/// Letters and digits only. Everything else — punctuation, symbols, emoji —
/// becomes a space, so `O'Brien-Smith` and `obrien smith` agree.
bool _isAlphanumeric(int rune) {
  if (rune >= 0x30 && rune <= 0x39) return true; // 0-9
  if (rune >= 0x61 && rune <= 0x7A) return true; // a-z
  if (rune >= 0x41 && rune <= 0x5A) return true; // A-Z
  if (rune < 0x80) return false;
  // Beyond ASCII there is no general-category table available here, so the
  // ranges excluded are the ones that actually appear in names as separators
  // or decoration. Everything else is treated as a letter. The JS side tests
  // the identical ranges rather than `\p{L}`, so the two agree by construction.
  if (rune >= 0x80 && rune <= 0xBF) return false; // Latin-1 punctuation
  if (rune == 0xD7 || rune == 0xF7) return false; // × ÷
  if (rune >= 0x2000 && rune <= 0x206F) return false; // general punctuation
  if (rune >= 0x2190 && rune <= 0x2BFF) return false; // arrows and symbols
  // Invisible formatting. A variation selector rides along behind an emoji
  // (🏋️ is U+1F3CB U+FE0F), so dropping only the pictograph leaves an
  // untypeable character in the middle of the normalised string and nothing
  // ever matches that account again.
  if (rune >= 0xFE00 && rune <= 0xFE0F) return false; // variation selectors
  if (rune >= 0xE000 && rune <= 0xF8FF) return false; // private use
  if (rune >= 0xFFF0 && rune <= 0xFFFF) return false; // specials
  if (rune >= 0x1F000) return false; // emoji and pictographs
  return true;
}

/// The canonical form of a piece of user-supplied text.
///
/// Accents folded, case dropped, punctuation reduced to spaces and runs of
/// whitespace collapsed. Mirrors `normalizeText` in search_normalize.js.
String normalizeText(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final StringBuffer out = StringBuffer();
  bool pendingSpace = false;
  bool wroteAny = false;

  void writeText(String text) {
    if (text.isEmpty) return;
    if (pendingSpace) {
      out.write(' ');
      pendingSpace = false;
    }
    out.write(text);
    wroteAny = true;
  }

  for (final int rune in raw.runes) {
    if (_isCombiningMark(rune)) continue;
    final String? folded = _folding[rune];
    if (folded != null) {
      writeText(folded);
      continue;
    }
    if (_isAlphanumeric(rune)) {
      writeText(String.fromCharCode(rune).toLowerCase());
      continue;
    }
    if (wroteAny) pendingSpace = true;
  }
  return out.toString();
}

/// [normalizeText] with spaces removed, for "firstlast" style matching.
String compactText(String? raw) => normalizeText(raw).replaceAll(' ', '');

/// Every prefix of [value] from [kMinQuery] to [kMaxPrefix] characters.
List<String> prefixesOf(String value) {
  final List<String> chars =
      value.runes.map(String.fromCharCode).toList(growable: false);
  final int limit = chars.length < kMaxPrefix ? chars.length : kMaxPrefix;
  final List<String> out = <String>[];
  for (int n = kMinQuery; n <= limit; n += 1) {
    out.add(chars.sublist(0, n).join());
  }
  return out;
}

/// Padded trigrams of [value].
///
/// The padding character is what makes the START of a string matter: without
/// it `john` and `ohnj` produce the same gram set.
List<String> trigramsOf(String value) {
  const String pad = r'$';
  final String compact = value.replaceAll(' ', '');
  if (compact.isEmpty) return const <String>[];
  final List<String> chars =
      compact.runes.map(String.fromCharCode).toList(growable: false);
  if (chars.length < 3) return <String>[pad + chars.join()];
  final List<String> padded = <String>[pad, ...chars, pad];
  final List<String> out = <String>[];
  for (int i = 0; i + 3 <= padded.length; i += 1) {
    out.add(padded.sublist(i, i + 3).join());
  }
  return out;
}

/// The trigrams a query should be matched by, most selective first.
///
/// Capped because `arrayContainsAny` accepts at most 30 disjuncts, and every
/// extra disjunct is index cost for a fallback that only has to SURFACE
/// candidates — local ranking does the judging.
List<String> queryGrams(String raw, {int max = 10}) {
  final List<String> grams = trigramsOf(normalizeText(raw));
  return grams.length <= max ? grams : grams.sublist(0, max);
}

/// Damerau–Levenshtein distance between [a] and [b].
///
/// Damerau rather than plain Levenshtein because ADJACENT TRANSPOSITION is the
/// most common typing error — `jhon` for `john` — and plain Levenshtein scores
/// it 2, the same as two unrelated substitutions. That difference is exactly
/// what decides whether the person you meant ranks first or fifth.
///
/// Bounded by [maxDistance]: once every cell in a row exceeds the bound the
/// answer cannot come back under it, so the remaining rows are not computed.
int damerauLevenshtein(String a, String b, {int maxDistance = 4}) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  if ((a.length - b.length).abs() > maxDistance) return maxDistance + 1;

  final List<int> aCodes = a.runes.toList(growable: false);
  final List<int> bCodes = b.runes.toList(growable: false);
  final int n = aCodes.length;
  final int m = bCodes.length;

  List<int> prev2 = List<int>.filled(m + 1, 0);
  List<int> prev = List<int>.generate(m + 1, (int i) => i);
  List<int> curr = List<int>.filled(m + 1, 0);

  for (int i = 1; i <= n; i += 1) {
    curr[0] = i;
    int rowMin = curr[0];
    for (int j = 1; j <= m; j += 1) {
      final int cost = aCodes[i - 1] == bCodes[j - 1] ? 0 : 1;
      int value = curr[j - 1] + 1;
      final int deletion = prev[j] + 1;
      if (deletion < value) value = deletion;
      final int substitution = prev[j - 1] + cost;
      if (substitution < value) value = substitution;
      if (i > 1 &&
          j > 1 &&
          aCodes[i - 1] == bCodes[j - 2] &&
          aCodes[i - 2] == bCodes[j - 1]) {
        final int transposition = prev2[j - 2] + 1;
        if (transposition < value) value = transposition;
      }
      curr[j] = value;
      if (value < rowMin) rowMin = value;
    }
    if (rowMin > maxDistance) return maxDistance + 1;
    final List<int> spare = prev2;
    prev2 = prev;
    prev = curr;
    curr = spare;
  }
  return prev[m];
}
