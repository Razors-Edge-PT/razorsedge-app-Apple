/// Buddy search: two bounded Firestore queries, then local ranking.
///
/// ── What it deliberately does not do ───────────────────────────────────────
/// The legacy search ran three ordered prefix ranges over `users_public` — one
/// of them on `emailLower` — and handed the matched email back to the client.
/// That is an email-enumeration primitive, and it could not tolerate a single
/// typo, because a prefix range cannot. Nothing here reads `users_public`, and
/// nothing here can return a field the projection does not carry.
///
/// ── The two queries ────────────────────────────────────────────────────────
/// Firestore offers equality, range and array membership, and nothing that
/// scores. So candidate selection is array membership over terms the indexer
/// precomputed, and ranking happens locally over a bounded candidate set:
///
///   1. `prefixes array-contains <query>` — everything that starts with what
///      was typed, plus (for a query longer than the stored prefix cap) an
///      exact `terms` match instead.
///   2. `grams array-contains-any <trigrams of query>` — the fuzzy net, which
///      is what makes a misspelling findable at all: `jonh` and `john` share
///      no prefix past `j`.
///
/// Both are limited server-side. Neither can turn into a scan: there is no
/// query here without an equality or membership clause, and no code path that
/// reads the collection unfiltered.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'search_normalize.dart';
import 'user_search_result.dart';

/// What one search attempt produced.
class UserSearchOutcome {
  const UserSearchOutcome({
    required this.query,
    required this.results,
    required this.source,
    this.offline = false,
    this.error,
  });

  final String query;
  final List<UserSearchResult> results;
  final SearchSource source;

  /// True when the network could not be reached. The UI says so rather than
  /// rendering an empty list, which would claim "no such person" on the
  /// strength of a dropped connection.
  final bool offline;

  /// Set when the query failed for a reason that is not simply being offline.
  final Object? error;

  bool get isEmpty => results.isEmpty;
}

/// A bounded, insertion-ordered cache of recent result rows.
///
/// Keyed by uid rather than by query string, so a row fetched for `sam` is
/// still available to `saman` — which is the common case while typing, and
/// what makes an offline search show something sensible instead of nothing.
class _ResultCache {
  /// Bounded so a long session of typing cannot grow the map without limit.
  /// Eviction is oldest-inserted-first, which for a search box is also
  /// least-recently-seen.
  static const int maxEntries = 200;

  final Map<String, UserSearchResult> _entries = <String, UserSearchResult>{};

  void putAll(Iterable<UserSearchResult> users) {
    for (final UserSearchResult u in users) {
      _entries.remove(u.uid);
      _entries[u.uid] = u;
    }
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  Iterable<UserSearchResult> get all => _entries.values;

  int get length => _entries.length;

  void clear() => _entries.clear();
}

/// Runs one prepared query. The seam the offline tests replace.
///
/// Only the transport is injectable — the queries themselves are built by
/// [UserSearchRepository] and are what the tests exercise. Substituting a
/// runner that throws is how "the device has no connection" is reproduced
/// without a test double for `Query`, which is sealed and cannot be
/// implemented.
typedef SearchQueryRunner = Future<QuerySnapshot<Map<String, dynamic>>>
    Function(Query<Map<String, dynamic>> query);

Future<QuerySnapshot<Map<String, dynamic>>> _defaultRunner(
  Query<Map<String, dynamic>> query,
) =>
    query.get();

class UserSearchRepository {
  UserSearchRepository({
    FirebaseFirestore? firestore,
    int pageLimit = 20,
    SearchQueryRunner? runQuery,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _pageLimit = pageLimit,
        _runQuery = runQuery ?? _defaultRunner;

  final FirebaseFirestore _db;
  final int _pageLimit;
  final SearchQueryRunner _runQuery;
  final _ResultCache _cache = _ResultCache();

  /// Monotonic id of the most recently STARTED search.
  ///
  /// Two queries run in parallel and the network reorders freely, so an
  /// earlier, slower search can land after a later one. Without this the list
  /// flickers back to results for a prefix the user has already typed past —
  /// and, worse, the row they are reaching for moves under their finger. Every
  /// completed search compares its own id against this before being returned.
  int _generation = 0;

  CollectionReference<Map<String, dynamic>> get _index =>
      _db.collection('userSearchIndex');

  /// The number of rows currently remembered. For tests and diagnostics.
  int get cachedCount => _cache.length;

  void clearCache() => _cache.clear();

  /// True when [raw] is worth sending to the server.
  ///
  /// One character matches a large fraction of any user base, which is a scan
  /// wearing a query's clothes — and it is a keystroke the user is always
  /// about to type past anyway.
  static bool isQueryLongEnough(String raw) =>
      normalizeText(raw).replaceAll(' ', '').length >= kMinQuery;

  /// Searches for [rawQuery], excluding [excludeUid] (the signed-in account).
  ///
  /// Returns null when a NEWER search started while this one was in flight, so
  /// the caller can drop the result rather than render it. Returning a sentinel
  /// rather than throwing keeps the cancellation explicit at the call site.
  Future<UserSearchOutcome?> search({
    required String rawQuery,
    required String? excludeUid,
  }) async {
    final int generation = ++_generation;
    final String normalized = normalizeText(rawQuery);

    if (!isQueryLongEnough(rawQuery)) {
      return UserSearchOutcome(
        query: rawQuery,
        results: const <UserSearchResult>[],
        source: SearchSource.network,
      );
    }

    try {
      final List<QuerySnapshot<Map<String, dynamic>>> snaps =
          await Future.wait(<Future<QuerySnapshot<Map<String, dynamic>>>>[
        _runQuery(_candidateQuery(normalized)),
        _runQuery(_fuzzyQuery(rawQuery)),
      ]);

      if (generation != _generation) return null;

      final List<UserSearchResult> candidates = <UserSearchResult>[
        for (final QuerySnapshot<Map<String, dynamic>> snap in snaps)
          for (final QueryDocumentSnapshot<Map<String, dynamic>> d in snap.docs)
            UserSearchResult.fromSnapshot(d),
      ];
      _cache.putAll(candidates);

      // `isFromCache` on every snapshot means Firestore answered from its own
      // persistence rather than the server. The rows are real, so they are
      // shown — but the search is reported as cached so the UI does not claim
      // a live result.
      final bool servedLocally =
          snaps.every((QuerySnapshot<Map<String, dynamic>> s) =>
              s.metadata.isFromCache);

      return UserSearchOutcome(
        query: rawQuery,
        results: rankSearchResults(
          rawQuery: rawQuery,
          candidates: candidates,
          excludeUid: excludeUid,
        ),
        source: servedLocally ? SearchSource.cache : SearchSource.network,
        offline: servedLocally && candidates.isEmpty,
      );
    } catch (err) {
      if (generation != _generation) return null;
      // Fall back to what has already been seen this session, and say plainly
      // that this is what happened. An empty list with no explanation reads as
      // "no such person", which is a different and wrong answer.
      return UserSearchOutcome(
        query: rawQuery,
        results: rankSearchResults(
          rawQuery: rawQuery,
          candidates: _cache.all,
          excludeUid: excludeUid,
        ),
        source: SearchSource.cache,
        offline: true,
        error: err,
      );
    }
  }

  /// Prefix match, or exact-term match for a query past the stored prefix cap.
  Query<Map<String, dynamic>> _candidateQuery(String normalized) {
    final int length = normalized.runes.length;
    if (length > kMaxPrefix) {
      return _index
          .where('terms', arrayContains: normalized)
          .limit(_pageLimit);
    }
    return _index
        .where('prefixes', arrayContains: normalized)
        .limit(_pageLimit);
  }

  /// Trigram match, bounded by `arrayContainsAny`'s 30-disjunct ceiling.
  Query<Map<String, dynamic>> _fuzzyQuery(String rawQuery) {
    final List<String> grams = queryGrams(rawQuery);
    if (grams.isEmpty) {
      // No trigrams means a query shorter than three characters, which the
      // prefix query already covers exactly. Ask for something that cannot
      // match rather than issuing an unfiltered read.
      return _index.where('grams', arrayContains: ' ').limit(1);
    }
    return _index.where('grams', arrayContainsAny: grams).limit(_pageLimit);
  }

  /// One account's discoverable profile, for a row the search did not produce
  /// (an incoming request, an existing buddy).
  ///
  /// Reads are batched by the caller and memoised in [_cache], so a feed or a
  /// request list resolves one document per DISTINCT account rather than one
  /// per row.
  Future<Map<String, UserSearchResult>> lookupUsers(
    Iterable<String> uids,
  ) async {
    final List<String> wanted = uids
        .map((String u) => u.trim())
        .where((String u) => u.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (wanted.isEmpty) return const <String, UserSearchResult>{};

    final Map<String, UserSearchResult> out = <String, UserSearchResult>{};
    final List<String> missing = <String>[];
    for (final UserSearchResult cached in _cache.all) {
      if (wanted.contains(cached.uid)) out[cached.uid] = cached;
    }
    for (final String uid in wanted) {
      if (!out.containsKey(uid)) missing.add(uid);
    }
    if (missing.isEmpty) return out;

    // `whereIn` takes at most 30 values, so the lookup is chunked. Each chunk
    // is one query, never one query per row.
    const int chunkSize = 30;
    for (int i = 0; i < missing.length; i += chunkSize) {
      final List<String> chunk = missing.sublist(
        i,
        i + chunkSize > missing.length ? missing.length : i + chunkSize,
      );
      try {
        final QuerySnapshot<Map<String, dynamic>> snap = await _runQuery(
          _index.where(FieldPath.documentId, whereIn: chunk),
        );
        final List<UserSearchResult> found = snap.docs
            .map(UserSearchResult.fromSnapshot)
            .toList(growable: false);
        _cache.putAll(found);
        for (final UserSearchResult u in found) {
          out[u.uid] = u;
        }
      } catch (_) {
        // Offline, or a chunk that failed. The rows already resolved are still
        // returned; the caller renders a placeholder for the rest rather than
        // failing the whole list.
      }
    }
    return out;
  }
}
