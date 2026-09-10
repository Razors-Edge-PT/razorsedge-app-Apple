/// One row of buddy search, and the rule that decides what comes first.
///
/// ── Why ranking is done here and not by Firestore ──────────────────────────
/// Firestore has no scoring. The queries in [UserSearchRepository] can only
/// select CANDIDATES — accounts that share a prefix or a trigram with what was
/// typed — and every candidate comes back equally weighted, in whatever order
/// the index happens to produce. Left like that, typing `sam` puts whoever the
/// index reached first at the top, which for a search box is indistinguishable
/// from broken.
///
/// So selection is bounded and server-side; judging is local, over at most a
/// few dozen candidates. That is cheap, and it is the only place with enough
/// information to do it: the query, the candidate's every name field, and an
/// edit distance between them.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'search_normalize.dart';

/// How well a candidate matched, best first.
///
/// The order is the product decision, stated once: an exact username beats
/// everything (it is unique and unambiguous, and the person typing it knows
/// exactly who they want), a username prefix beats a name match (usernames are
/// what people share), and a fuzzy match is last because it is a guess.
enum MatchTier {
  exactUsername,
  usernamePrefix,
  exactFullName,
  exactGivenOrFamilyName,
  namePrefix,
  fuzzy,
  none,
}

/// Where a search result came from, so the UI can be honest about it.
enum SearchSource {
  /// A live query answered by the server.
  network,

  /// Previously fetched rows replayed while offline or before a query lands.
  cache,
}

/// A safe, discoverable account, as stored in `userSearchIndex/{uid}`.
///
/// Every field here is one a signed-in stranger may already see. There is
/// deliberately no email, phone, date of birth, entitlement or coach field —
/// see functions/social/search_index.js for why the projection exists.
class UserSearchResult {
  const UserSearchResult({
    required this.uid,
    required this.username,
    required this.displayName,
    this.fullName = '',
    this.firstName = '',
    this.lastName = '',
    this.photoURL = '',
  });

  final String uid;
  final String username;
  final String displayName;
  final String fullName;
  final String firstName;
  final String lastName;
  final String photoURL;

  /// The name to show on the row, never empty if anything at all is known.
  String get bestName {
    if (displayName.trim().isNotEmpty) return displayName.trim();
    if (fullName.trim().isNotEmpty) return fullName.trim();
    if (username.trim().isNotEmpty) return username.trim();
    return 'GoodLift member';
  }

  /// `@handle`, or empty when the account has no username.
  String get handle => username.trim().isEmpty ? '' : '@${username.trim()}';

  static UserSearchResult fromMap(String uid, Map<String, dynamic> d) {
    String s(String key) {
      final Object? v = d[key];
      return v is String ? v.trim() : '';
    }

    return UserSearchResult(
      uid: uid,
      username: s('username'),
      displayName: s('displayName'),
      fullName: s('fullName'),
      firstName: s('firstName'),
      lastName: s('lastName'),
      photoURL: s('photoURL'),
    );
  }

  static UserSearchResult fromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) =>
      fromMap(snap.id, snap.data() ?? const <String, dynamic>{});

  Map<String, Object?> toCacheMap() => <String, Object?>{
        'username': username,
        'displayName': displayName,
        'fullName': fullName,
        'firstName': firstName,
        'lastName': lastName,
        'photoURL': photoURL,
      };

  @override
  bool operator ==(Object other) =>
      other is UserSearchResult &&
      other.uid == uid &&
      other.username == username &&
      other.displayName == displayName &&
      other.photoURL == photoURL;

  @override
  int get hashCode => Object.hash(uid, username, displayName, photoURL);

  @override
  String toString() => 'UserSearchResult($uid, $username)';
}

/// A candidate together with why it matched, so the sort is explainable.
class ScoredUser implements Comparable<ScoredUser> {
  const ScoredUser({
    required this.user,
    required this.tier,
    required this.distance,
  });

  final UserSearchResult user;
  final MatchTier tier;

  /// Edit distance between the query and the field that matched. Used only to
  /// order within a tier: two equally-good kinds of match are separated by how
  /// close the spelling actually was.
  final int distance;

  bool get matched => tier != MatchTier.none;

  @override
  int compareTo(ScoredUser other) {
    final int byTier = tier.index.compareTo(other.tier.index);
    if (byTier != 0) return byTier;
    final int byDistance = distance.compareTo(other.distance);
    if (byDistance != 0) return byDistance;
    // A stable, meaningful last resort. Two accounts with the same name are
    // distinguished by their username, which is unique — so the order never
    // flickers between rebuilds for the same query.
    final int byUsername = user.username
        .toLowerCase()
        .compareTo(other.user.username.toLowerCase());
    if (byUsername != 0) return byUsername;
    return user.uid.compareTo(other.user.uid);
  }
}

/// The largest edit distance still considered a match.
///
/// Two covers the realistic slips — one wrong letter, one missing letter, one
/// extra letter, one transposition, or two of those in a long name. Beyond it
/// the "match" stops being a typo and starts being a different word, and
/// showing it costs more trust than the occasional recovered search wins.
const int kMaxFuzzyDistance = 2;

/// Scores [user] against [rawQuery].
///
/// Returns [MatchTier.none] when nothing matched — the candidate came back
/// from the trigram query but is not close enough to show. The server cannot
/// make that judgement, so some of what it returns is expected to be discarded
/// here.
ScoredUser scoreUser(String rawQuery, UserSearchResult user) {
  final String q = normalizeText(rawQuery);
  if (q.isEmpty) {
    return ScoredUser(user: user, tier: MatchTier.none, distance: 999);
  }

  final String username = normalizeText(user.username);
  final String first = normalizeText(user.firstName);
  final String last = normalizeText(user.lastName);
  final String full = normalizeText(user.fullName);
  final String fullCompact = compactText(user.fullName);
  final String display = normalizeText(user.displayName);
  final String displayCompact = compactText(user.displayName);

  if (username.isNotEmpty && username == q) {
    return ScoredUser(user: user, tier: MatchTier.exactUsername, distance: 0);
  }
  if (username.isNotEmpty && username.startsWith(q)) {
    // Shorter usernames rank first within the tier: typing `sam` should reach
    // `sam` before `samanthaunderscore1994`.
    return ScoredUser(
      user: user,
      tier: MatchTier.usernamePrefix,
      distance: username.length - q.length,
    );
  }
  if ((full.isNotEmpty && full == q) ||
      (fullCompact.isNotEmpty && fullCompact == q) ||
      (display.isNotEmpty && display == q) ||
      (displayCompact.isNotEmpty && displayCompact == q)) {
    return ScoredUser(user: user, tier: MatchTier.exactFullName, distance: 0);
  }
  if ((first.isNotEmpty && first == q) || (last.isNotEmpty && last == q)) {
    return ScoredUser(
      user: user,
      tier: MatchTier.exactGivenOrFamilyName,
      distance: 0,
    );
  }
  for (final String field in <String>[first, last, full, fullCompact, display]) {
    if (field.isNotEmpty && field.startsWith(q)) {
      return ScoredUser(
        user: user,
        tier: MatchTier.namePrefix,
        distance: field.length - q.length,
      );
    }
  }

  // Fuzzy. Compared against every field the account is indexed under, taking
  // the closest — a misspelling of a surname should not be judged against the
  // username it has nothing to do with.
  int best = kMaxFuzzyDistance + 1;
  for (final String field in <String>[
    username,
    first,
    last,
    full,
    fullCompact,
    display,
    displayCompact,
  ]) {
    if (field.isEmpty) continue;
    final int d = damerauLevenshtein(q, field, maxDistance: kMaxFuzzyDistance);
    if (d < best) best = d;
  }
  if (best <= kMaxFuzzyDistance) {
    return ScoredUser(user: user, tier: MatchTier.fuzzy, distance: best);
  }
  return ScoredUser(user: user, tier: MatchTier.none, distance: 999);
}

/// Ranks [candidates] for [rawQuery], dropping non-matches and [excludeUid].
///
/// [excludeUid] is the signed-in account. Offering to send yourself a buddy
/// request is a dead end the server rejects anyway, so it never reaches the
/// list.
List<UserSearchResult> rankSearchResults({
  required String rawQuery,
  required Iterable<UserSearchResult> candidates,
  String? excludeUid,
  int limit = 25,
}) {
  final Map<String, ScoredUser> byUid = <String, ScoredUser>{};
  for (final UserSearchResult user in candidates) {
    if (user.uid.isEmpty) continue;
    if (excludeUid != null && user.uid == excludeUid) continue;
    final ScoredUser scored = scoreUser(rawQuery, user);
    if (!scored.matched) continue;
    // The same account can arrive from both the prefix and the trigram query.
    final ScoredUser? existing = byUid[user.uid];
    if (existing == null || scored.compareTo(existing) < 0) {
      byUid[user.uid] = scored;
    }
  }
  final List<ScoredUser> ranked = byUid.values.toList()..sort();
  return ranked
      .take(limit)
      .map((ScoredUser s) => s.user)
      .toList(growable: false);
}
