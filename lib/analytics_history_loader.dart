// Athlete-scoped raw workout-document loader for the analytics screen
// (lib/exercise_details_screen.dart). Fixes six issues found in review of
// commit 53df026f (GoodLift 1.7.25+95):
//
//   1. Request ownership — this loader is scoped to ONE athlete (uid) and
//      knows nothing about "which exercise" a fetch was for. Raw workout
//      documents belong to the athlete, not to whichever exercise triggered
//      the fetch that happened to retrieve them, so switching the selected
//      exercise mid-fetch cannot corrupt anything: the fetch's result is
//      just more of the athlete's history, merged in regardless of what's
//      currently selected. Every exercise/metric view is derived from
//      [docs] at render time, never cached per-exercise.
//   2. Coverage tracking — [coveredSince] is the depth we've CONFIRMED
//      complete; [requestCoverage] coalesces rapid, deepening requests so
//      the final desired depth is what actually gets fetched, without
//      reporting a shallower fetch as satisfying a deeper one.
//   3/4. Callers decide how much coverage to request and when (bounded
//      initial windows, explicit "load older" extension, or a background
//      deep request once Velocity is selected) — this loader only tracks
//      coverage and merges results; it never decides to scan everything.
//   5. [RawFetcher] implementations query Timestamp- and String-typed
//      `date` values as two separate bounded streams (see
//      fetchRawWorkoutDocsFromFirestore) instead of the unsafe
//      single-`orderBy` "stop when a page looks old" pattern, which breaks
//      under Firestore's cross-type value ordering
//      (https://firebase.google.com/docs/firestore/manage-data/data-types#value_type_ordering).
//   6. Authoritative merge — a successful fetch REPLACES every previously
//      cached document whose date falls inside the just-fetched interval,
//      including removing one that no longer comes back (deleted), rather
//      than accepting/rejecting the whole response by comparing list
//      lengths.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// One raw `users/{uid}/workouts` document, parsed just enough to be reused
/// by every exercise/metric derivation (E1RM, rep-target, velocity, and the
/// exercise picker) without re-fetching.
@immutable
class RawWorkoutDoc {
  final String id;

  /// The document's `date`, exactly as stored (Timestamp or String),
  /// resolved to a DateTime. May carry a time-of-day for legacy
  /// `toIso8601String()` documents.
  final DateTime date;

  /// The raw `exercises` array content, untouched.
  final List<Map<String, dynamic>> exercises;

  const RawWorkoutDoc(
      {required this.id, required this.date, required this.exercises});
}

/// The result of one coverage fetch: either the complete, authoritative set
/// of documents in the requested interval, or a failure that must not be
/// mistaken for "nothing there."
@immutable
class RawFetchResult {
  final bool success;
  final List<RawWorkoutDoc> docs;
  final String? error;

  const RawFetchResult.ok(this.docs)
      : success = true,
        error = null;
  const RawFetchResult.failure(this.error)
      : success = false,
        docs = const [];
}

/// Fetches every workout document dated on or after [since] (inclusive,
/// calendar-day boundary) for one athlete. Implementations must return the
/// COMPLETE set for that interval — see [fetchRawWorkoutDocsFromFirestore]
/// for the production implementation and why a naive single-query scan is
/// unsafe.
typedef RawFetcher = Future<RawFetchResult> Function({required DateTime since});

class _CoverageWaiter {
  final DateTime since;
  final Completer<void> completer;
  _CoverageWaiter(this.since, this.completer);
}

/// Loads and caches one athlete's raw workout documents, deduplicated by
/// document id, with authoritative-refresh semantics and coalesced
/// coverage requests. Firebase-free at this interface — [fetcher] is
/// injected, so this class can be unit-tested with a controlled fake.
///
/// Lifecycle: create ONE instance per athlete (uid). Never reuse an
/// instance across a different uid — create a new one and [dispose] the
/// old one instead, so any work still in flight for the previous athlete
/// can only ever mutate an object nothing reads anymore.
class AnalyticsHistoryLoader extends ChangeNotifier {
  AnalyticsHistoryLoader({required this.uid, required this.fetcher});

  final String uid;
  final RawFetcher fetcher;

  bool _disposed = false;
  bool get isDisposed => _disposed;

  final Map<String, RawWorkoutDoc> _byId = {};
  DateTime? _coveredSince;
  DateTime? _requestedSince; // deepest lazily-desired coverage
  DateTime? _forcedSince; // a forced-refresh target (issue 6), independent of coverage
  bool _loading = false;
  String? _error;
  final List<_CoverageWaiter> _waiters = [];
  final List<Completer<void>> _forceWaiters = [];

  /// Every cached document, newest first.
  List<RawWorkoutDoc> get docs {
    final list = _byId.values.toList()..sort((a, b) => b.date.compareTo(a.date));
    return List.unmodifiable(list);
  }

  /// The deepest confirmed-complete coverage boundary, or null if nothing
  /// has been successfully fetched yet.
  DateTime? get coveredSince => _coveredSince;

  bool get loading => _loading;

  /// Set only when the most recent fetch failed; cleared on the next
  /// successful one. A caller must not report "no history" while this is
  /// set — it means discovery didn't complete, not that there's nothing.
  String? get error => _error;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// True once we've CONFIRMED there is nothing missing back to [since].
  bool coversSince(DateTime since) {
    final target = _day(since);
    return _coveredSince != null && !target.isBefore(_coveredSince!);
  }

  /// Requests coverage back to [since] (inclusive). Coalesces with any
  /// in-flight or already-queued request: the deepest requested depth wins,
  /// and only one fetch runs at a time per athlete. The returned future
  /// resolves once coverage actually reaches [since] (or rejects on
  /// failure) — awaiting it is optional; callers that only care about the
  /// eventually-consistent [docs]/[coveredSince] state can fire-and-forget.
  Future<void> requestCoverage(DateTime since) {
    if (_disposed) return Future<void>.value();
    final target = _day(since);
    if (coversSince(target)) return Future<void>.value();

    if (_requestedSince == null || target.isBefore(_requestedSince!)) {
      _requestedSince = target;
    }
    final completer = Completer<void>();
    _waiters.add(_CoverageWaiter(target, completer));
    _maybeFetch();
    return completer.future;
  }

  /// Forces a fresh, authoritative re-fetch of `[since, now]` regardless of
  /// current coverage — for save/edit/delete invalidation or an explicit
  /// refresh (issue 6), which must work without requiring an unrelated
  /// deeper coverage request to actually run a fetch.
  Future<void> invalidate(DateTime since) {
    if (_disposed) return Future<void>.value();
    final target = _day(since);
    if (_forcedSince == null || target.isBefore(_forcedSince!)) {
      _forcedSince = target;
    }
    final completer = Completer<void>();
    _forceWaiters.add(completer);
    _maybeFetch();
    return completer.future;
  }

  /// The interval any pending work actually needs fetched: the deeper of a
  /// forced refresh and an unmet coverage request (fetching the deeper one
  /// always satisfies the shallower one too).
  DateTime? _pendingTarget() {
    DateTime? target = _forcedSince;
    if (_requestedSince != null && !coversSince(_requestedSince!)) {
      if (target == null || _requestedSince!.isBefore(target)) {
        target = _requestedSince;
      }
    }
    return target;
  }

  void _maybeFetch() {
    if (_disposed || _loading) return;
    final target = _pendingTarget();
    if (target == null) return;

    // A fetch covering [target, now] satisfies any pending forced refresh,
    // since target is always at or before _forcedSince here — consume it
    // now so a mid-flight invalidate() call starts a fresh one instead of
    // being silently absorbed into this fetch's completion.
    final satisfiesForce = _forcedSince != null && !target.isAfter(_forcedSince!);
    final pendingForceWaiters =
        satisfiesForce ? List<Completer<void>>.from(_forceWaiters) : const <Completer<void>>[];
    if (satisfiesForce) {
      _forceWaiters.clear();
      _forcedSince = null;
    }

    _loading = true;
    _error = null;
    notifyListeners();

    fetcher(since: target).then((result) {
      if (_disposed) return;
      _loading = false;
      if (result.success) {
        _mergeAuthoritative(target, result.docs);
        _error = null;
        if (_coveredSince == null || target.isBefore(_coveredSince!)) {
          _coveredSince = target;
        }
        for (final c in pendingForceWaiters) {
          if (!c.isCompleted) c.complete();
        }
      } else {
        // A failed fetch never claims coverage and never touches cached
        // data — a retryable error, not a disguised empty success.
        _error = result.error ?? 'Could not load history.';
        for (final c in pendingForceWaiters) {
          if (!c.isCompleted) c.completeError(_error!);
        }
      }
      _resolveWaiters();
      notifyListeners();

      // Coalescing: only continue automatically after a SUCCESSFUL fetch
      // that still leaves something deeper pending. Never auto-retry after
      // a failure — that would also clear the just-surfaced error before
      // any caller can observe it, and retry silently forever.
      if (result.success && _pendingTarget() != null) {
        _maybeFetch();
      }
    });
  }

  /// A successful fetch for [since] is authoritative for [since, now]:
  /// every previously cached document in that interval is either replaced
  /// (edited), left as-is (unchanged, re-supplied identically), or removed
  /// (deleted) — never kept around just because a shorter response arrived.
  void _mergeAuthoritative(DateTime since, List<RawWorkoutDoc> freshDocs) {
    final staleIds = _byId.entries
        .where((e) => !e.value.date.isBefore(since))
        .map((e) => e.key)
        .toSet();
    for (final d in freshDocs) {
      staleIds.remove(d.id);
      _byId[d.id] = d;
    }
    for (final id in staleIds) {
      _byId.remove(id);
    }
  }

  void _resolveWaiters() {
    _waiters.removeWhere((w) {
      if (coversSince(w.since)) {
        if (!w.completer.isCompleted) w.completer.complete();
        return true;
      }
      if (_error != null) {
        if (!w.completer.isCompleted) w.completer.completeError(_error!);
        return true;
      }
      return false;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    final disposedError = StateError('AnalyticsHistoryLoader disposed');
    for (final w in _waiters) {
      if (!w.completer.isCompleted) {
        // Many callers fire-and-forget requestCoverage()/invalidate() — an
        // unhandled Future rejection would crash zone-guarded code even
        // though nobody is actually listening, so guarantee at least one
        // (silent) listener before completing with an error. A caller that
        // DOES await the same future still receives the error normally.
        w.completer.future.catchError((_) {});
        w.completer.completeError(disposedError);
      }
    }
    _waiters.clear();
    for (final c in _forceWaiters) {
      if (!c.isCompleted) {
        c.future.catchError((_) {});
        c.completeError(disposedError);
      }
    }
    _forceWaiters.clear();
    super.dispose();
  }
}

// ─────────────────────── Production Firestore fetcher ───────────────────────

String _yyyyMMdd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime? _parseDate(dynamic raw) {
  if (raw is Timestamp) return raw.toDate();
  if (raw is String) return DateTime.tryParse(raw);
  return null;
}

RawWorkoutDoc? _parseRawDoc(String id, Map<String, dynamic> data) {
  final date = _parseDate(data['date']);
  if (date == null) return null;
  final rawEx = data['exercises'];
  if (rawEx is! List) return null;
  return RawWorkoutDoc(
    id: id,
    date: date,
    exercises: rawEx.whereType<Map<String, dynamic>>().toList(),
  );
}

/// Pages through one homogeneously-typed query stream (all Timestamp, or
/// all String, `date` values) until exhausted. Safe to stop on a
/// short/empty page here — unlike the old single-stream scan, this query
/// is already bounded by a `where` clause matching only same-typed values,
/// so a short page genuinely means "no more of this type", not "no more
/// recent data of any type".
///
/// Exposed (not private) so tests can exercise pagination directly against
/// a single, homogeneously-typed query — see analytics_raw_fetch_test.dart
/// for why: the only Firestore test double available in this project
/// cannot host mixed-type data in one collection.
@visibleForTesting
Future<List<RawWorkoutDoc>> fetchAllPagesForQuery(
  Query<Map<String, dynamic>> query, {
  int batchSize = 200,
}) async {
  final out = <RawWorkoutDoc>[];
  DocumentSnapshot<Map<String, dynamic>>? lastDoc;
  while (true) {
    Query<Map<String, dynamic>> q = query.limit(batchSize);
    if (lastDoc != null) q = q.startAfterDocument(lastDoc);
    final snap = await q.get();
    if (snap.docs.isEmpty) break;
    for (final doc in snap.docs) {
      final parsed = _parseRawDoc(doc.id, doc.data());
      if (parsed != null) out.add(parsed);
    }
    lastDoc = snap.docs.last;
    if (snap.docs.length < batchSize) break;
  }
  return out;
}

/// Production [RawFetcher]: every workout document for [uid] dated on or
/// after [since] (local calendar-day boundary), across both storage
/// formats actually in use — Firestore `Timestamp` and legacy `String`
/// (`yyyy-MM-dd` from WES2's `_dateDocId`, or `DateTime.toIso8601String()`
/// from older screens).
///
/// A single `orderBy('date', descending: true)` cannot safely paginate
/// this: Firestore sorts by VALUE TYPE first, so with mixed types in one
/// field, EVERY string-dated document sorts before EVERY timestamp-dated
/// one regardless of the actual calendar dates involved, making "the last
/// item on this page is older than the cutoff" meaningless as a stopping
/// rule — recent Timestamp-dated documents could sit entirely unread past
/// a page of old String-dated ones. Instead, this runs two independently
/// bounded, single-typed query streams (a range filter's bound value type
/// excludes documents whose field is a different type, per
/// https://firebase.google.com/docs/firestore/manage-data/data-types#value_type_ordering)
/// and merges them client-side, deduplicated by document id.
Future<RawFetchResult> fetchRawWorkoutDocsFromFirestore({
  required String uid,
  required DateTime since,
  FirebaseFirestore? firestore,
}) async {
  try {
    final cutoffDay = DateTime(since.year, since.month, since.day);
    final col = (firestore ?? FirebaseFirestore.instance)
        .collection('users')
        .doc(uid)
        .collection('workouts');

    final results = await Future.wait([
      fetchAllPagesForQuery(
        col
            .where('date',
                isGreaterThanOrEqualTo: Timestamp.fromDate(cutoffDay))
            .orderBy('date', descending: true),
      ),
      fetchAllPagesForQuery(
        col
            .where('date', isGreaterThanOrEqualTo: _yyyyMMdd(cutoffDay))
            .orderBy('date', descending: true),
      ),
    ]);

    final byId = <String, RawWorkoutDoc>{};
    for (final page in results) {
      for (final doc in page) {
        byId[doc.id] = doc;
      }
    }
    return RawFetchResult.ok(byId.values.toList());
  } catch (e) {
    return RawFetchResult.failure('$e');
  }
}
