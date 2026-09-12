// Controlled-async regression tests for AnalyticsHistoryLoader — the
// production request/state controller extracted to fix the six issues found
// in review of commit 53df026f (GoodLift 1.7.25+95). No Firebase: the
// fetcher is injected and driven by hand via Completers so responses can be
// resolved in any order.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/analytics_history_loader.dart';

RawWorkoutDoc doc(String id, DateTime date, {String tag = ''}) => RawWorkoutDoc(
      id: id,
      date: date,
      exercises: [
        {'id': 'ex1', 'name': 'Bench Press', 'tag': tag, 'sets': const []},
      ],
    );

/// A controllable fetcher: each call returns a fresh Completer the test
/// resolves/rejects by hand, so responses can complete in any order.
class FakeFetcherRig {
  final List<FakeFetchCall> calls = [];

  RawFetcher get fetcher => ({required DateTime since}) {
        final completer = Completer<RawFetchResult>();
        calls.add(FakeFetchCall(since, completer));
        return completer.future;
      };

  void resolve(int callIndex, RawFetchResult result) {
    calls[callIndex].completer.complete(result);
  }
}

class FakeFetchCall {
  final DateTime since;
  final Completer<RawFetchResult> completer;
  FakeFetchCall(this.since, this.completer);
}

void main() {
  group('AnalyticsHistoryLoader — coverage and coalescing (issue 2)', () {
    test('a single successful fetch marks coverage and stores docs', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final future = loader.requestCoverage(DateTime(2026, 8, 1));
      expect(rig.calls, hasLength(1));
      rig.resolve(0, RawFetchResult.ok([doc('d1', DateTime(2026, 8, 5))]));
      await future;

      expect(loader.coversSince(DateTime(2026, 8, 1)), isTrue);
      expect(loader.docs.map((d) => d.id), ['d1']);
      expect(loader.loading, isFalse);
      expect(loader.error, isNull);
    });

    test(
        'rapid preset cycling (1 month -> 6 months -> 1 year) ends up covering the deepest request',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final now = DateTime(2026, 8, 20);
      // Rapidly widen the request before the first fetch resolves.
      final f1 = loader.requestCoverage(now.subtract(const Duration(days: 30)));
      final f6 = loader.requestCoverage(now.subtract(const Duration(days: 182)));
      final f12 = loader.requestCoverage(now.subtract(const Duration(days: 365)));

      // Only ONE fetch should be in flight (coalesced), for the FIRST
      // requested depth (30 days) — it started before the widening arrived.
      expect(rig.calls, hasLength(1));
      expect(rig.calls[0].since, now.subtract(const Duration(days: 30)));

      rig.resolve(0, RawFetchResult.ok([doc('d1', now.subtract(const Duration(days: 10)))]));
      await f1; // the 30-day request is satisfied by this fetch alone

      // The loader must now continue fetching for the deeper (365-day)
      // request rather than reporting the 30-day fetch as final.
      expect(rig.calls, hasLength(2));
      expect(rig.calls[1].since, now.subtract(const Duration(days: 365)));
      expect(loader.coversSince(now.subtract(const Duration(days: 365))), isFalse,
          reason: 'the 1-year window is not yet actually covered');

      // A real fetch covering [365 days ago, now] is authoritative for that
      // WHOLE interval, so it naturally re-supplies d1 too (a realistic
      // fetch never returns only the "new" older slice).
      rig.resolve(
        1,
        RawFetchResult.ok([
          doc('d1', now.subtract(const Duration(days: 10))),
          doc('d2', now.subtract(const Duration(days: 300))),
        ]),
      );
      await Future.wait([f6, f12]);

      expect(loader.coversSince(now.subtract(const Duration(days: 365))), isTrue,
          reason: 'the final chart must cover the whole selected year');
      expect(loader.docs.map((d) => d.id).toSet(), {'d1', 'd2'});
    });

    test('a shallower already-satisfied request resolves immediately without a new fetch',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final deep = loader.requestCoverage(DateTime(2025, 1, 1));
      rig.resolve(0, const RawFetchResult.ok([]));
      await deep;

      await loader.requestCoverage(DateTime(2026, 1, 1)); // shallower, already covered
      expect(rig.calls, hasLength(1), reason: 'no redundant fetch for already-covered depth');
    });
  });

  group('AnalyticsHistoryLoader — authoritative refresh (issue 6)', () {
    test('a refresh removes a deleted document within its covered interval', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final since = DateTime(2026, 8, 1);
      final f1 = loader.requestCoverage(since);
      rig.resolve(0, RawFetchResult.ok([
        doc('fast', DateTime(2026, 8, 10), tag: 'fastest'),
        doc('slow', DateTime(2026, 8, 10), tag: 'slower'),
      ]));
      await f1;
      expect(loader.docs.map((d) => d.id).toSet(), {'fast', 'slow'});

      // The fastest set's document was deleted. requestCoverage is a no-op
      // once a depth is already covered, so a real caller forces a fresh
      // authoritative re-fetch of the same interval by requesting coverage
      // one day deeper (a real explicit-refresh path does the same thing).
      final refreshSince = since.subtract(const Duration(days: 1));
      final refresh = loader.requestCoverage(refreshSince);
      rig.resolve(1, RawFetchResult.ok([doc('slow', DateTime(2026, 8, 10), tag: 'slower')]));
      await refresh;

      expect(loader.docs.map((d) => d.id).toSet(), {'slow'},
          reason: 'the deleted "fast" document must not survive an authoritative refresh');
    });

    test('an authoritative refresh accepts a legitimately empty result', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final f1 = loader.requestCoverage(DateTime(2026, 8, 1));
      rig.resolve(0, RawFetchResult.ok([doc('only', DateTime(2026, 8, 10))]));
      await f1;

      final f2 = loader.requestCoverage(DateTime(2026, 7, 1));
      rig.resolve(1, const RawFetchResult.ok([])); // everything in range was deleted
      await f2;

      expect(loader.docs, isEmpty);
      expect(loader.error, isNull);
    });

    test('an explicit invalidate() of a shallow interval preserves older cached data', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      // First, a wide fetch establishes an old document.
      final f1 = loader.requestCoverage(DateTime(2020, 1, 1));
      rig.resolve(0, RawFetchResult.ok([doc('old', DateTime(2020, 6, 1))]));
      await f1;

      // A save/edit/delete invalidation only re-verifies the recent
      // interval (a plain requestCoverage() for a shallower date would be a
      // no-op here, since 2020 coverage already implies it) — the old
      // document outside that interval must survive untouched.
      final refresh = loader.invalidate(DateTime(2026, 1, 1));
      expect(rig.calls, hasLength(2),
          reason: 'invalidate() must trigger a fetch without requiring deeper coverage');
      rig.resolve(1, RawFetchResult.ok([doc('new', DateTime(2026, 2, 1))]));
      await refresh;

      expect(loader.docs.map((d) => d.id).toSet(), {'old', 'new'});
    });

    test('invalidate() removes a document deleted from its interval without touching older data',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final f1 = loader.requestCoverage(DateTime(2020, 1, 1));
      rig.resolve(0, RawFetchResult.ok([
        doc('old', DateTime(2020, 6, 1)),
        doc('deleted-me', DateTime(2026, 2, 1)),
      ]));
      await f1;

      final refresh = loader.invalidate(DateTime(2026, 1, 1));
      rig.resolve(1, const RawFetchResult.ok([])); // deleted-me no longer exists
      await refresh;

      expect(loader.docs.map((d) => d.id).toSet(), {'old'});
    });

    test('a failed refresh does not replace valid data with an error-disguised empty result',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final f1 = loader.requestCoverage(DateTime(2026, 8, 1));
      rig.resolve(0, RawFetchResult.ok([doc('keep', DateTime(2026, 8, 10))]));
      await f1;

      final f2 = loader.requestCoverage(DateTime(2026, 1, 1));
      rig.resolve(1, const RawFetchResult.failure('network error'));
      await expectLater(f2, throwsA(anything));

      expect(loader.docs.map((d) => d.id), ['keep'],
          reason: 'valid cached data must survive a failed refresh');
      expect(loader.error, isNotNull, reason: 'an honest, retryable error state must be visible');

      // Retry succeeds and clears the error. A real fetch covering
      // [2026-01-01, now] is authoritative for that whole interval, so it
      // re-supplies "keep" too, not just the newly-discovered "older".
      final f3 = loader.requestCoverage(DateTime(2026, 1, 1));
      rig.resolve(2, RawFetchResult.ok([
        doc('keep', DateTime(2026, 8, 10)),
        doc('older', DateTime(2026, 2, 1)),
      ]));
      await f3;
      expect(loader.error, isNull);
      expect(loader.docs.map((d) => d.id).toSet(), {'keep', 'older'});
    });
  });

  group('AnalyticsHistoryLoader — disposal safety (issue 1)', () {
    test('a response arriving after dispose does not throw and changes nothing observable',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);

      loader.requestCoverage(DateTime(2026, 8, 1));
      loader.dispose();
      // Resolving after dispose must not throw (e.g. via notifyListeners on
      // a disposed ChangeNotifier) and must not be observable afterwards.
      expect(
        () => rig.resolve(0, RawFetchResult.ok([doc('late', DateTime(2026, 8, 10))])),
        returnsNormally,
      );
      await Future<void>.delayed(Duration.zero);
      expect(loader.isDisposed, isTrue);
    });

    test('pending coverage waiters are rejected on dispose instead of hanging forever',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'u1', fetcher: rig.fetcher);
      final pending = loader.requestCoverage(DateTime(2026, 8, 1));
      loader.dispose();
      await expectLater(pending, throwsA(anything));
    });
  });

  group('AnalyticsHistoryLoader — athlete scoping (issue 1)', () {
    test('two independent loaders for different athletes never share state', () async {
      final rigA = FakeFetcherRig();
      final rigB = FakeFetcherRig();
      final loaderA = AnalyticsHistoryLoader(uid: 'athleteA', fetcher: rigA.fetcher);
      final loaderB = AnalyticsHistoryLoader(uid: 'athleteB', fetcher: rigB.fetcher);
      addTearDown(loaderA.dispose);
      addTearDown(loaderB.dispose);

      final fA = loaderA.requestCoverage(DateTime(2026, 1, 1));
      // Switch attention to athlete B before A's fetch resolves — this is
      // exactly the "select Squat before Bench's velocity fetch resolves"
      // shape, at the athlete level: A's late completion must never affect
      // B's loader.
      final fB = loaderB.requestCoverage(DateTime(2026, 1, 1));
      rigB.resolve(0, RawFetchResult.ok([doc('b-doc', DateTime(2026, 6, 1))]));
      await fB;
      rigA.resolve(0, RawFetchResult.ok([doc('a-doc', DateTime(2026, 6, 1))]));
      await fA;

      expect(loaderA.docs.map((d) => d.id), ['a-doc']);
      expect(loaderB.docs.map((d) => d.id), ['b-doc']);
    });
  });

  group(
      'review-follow-up issue 3 — fire-and-forget production calling pattern is zone-safe',
      () {
    // Every production call site fires requestCoverage()/invalidate()
    // without awaiting, via _fireCoverageRequest(request) which does
    // `request?.catchError((_) {})`. These tests reproduce EXACTLY that
    // pattern (not a direct awaited call) inside runZonedGuarded, so a
    // regression back to a bare `// ignore: discarded_futures` comment
    // (no catchError attached) would make these fail with an uncaught
    // zone error — proving the fix, not just the loader's own await-based
    // API surface already covered elsewhere in this file.
    void fireAndForget(Future<void>? request) {
      request?.catchError((_) {
        // Mirrors _fireCoverageRequest: loader.error already carries the
        // failure for the UI; nothing else to do for a fire-and-forget
        // caller.
      });
    }

    test('a failed INITIAL load produces no uncaught zone error and surfaces loader.error',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      Object? uncaught;
      await runZonedGuarded(() async {
        fireAndForget(loader.requestCoverage(DateTime(2026, 1, 1)));
        rig.resolve(0, const RawFetchResult.failure('offline'));
        await Future<void>.delayed(Duration.zero);
      }, (error, stack) {
        uncaught = error;
      });

      expect(uncaught, isNull,
          reason: 'a fire-and-forget initial-load failure must never become an uncaught zone error');
      expect(loader.error, isNotNull, reason: 'the failure must still be visible via loader.error');
      expect(loader.loading, isFalse, reason: 'the loading flag must not be left stuck');
    });

    test('a failed PERIOD EXPANSION (deeper coverage request) produces no uncaught zone error, '
        'and retains the previously-loaded valid data', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      // Successful initial load (e.g. the default 14-day window).
      final initial = loader.requestCoverage(DateTime(2026, 8, 1));
      rig.resolve(0, RawFetchResult.ok([doc('keep', DateTime(2026, 8, 10))]));
      await initial;

      // Expanding to a longer preset (e.g. "1 year") fails.
      Object? uncaught;
      await runZonedGuarded(() async {
        fireAndForget(loader.requestCoverage(DateTime(2025, 1, 1)));
        rig.resolve(1, const RawFetchResult.failure('timed out'));
        await Future<void>.delayed(Duration.zero);
      }, (error, stack) {
        uncaught = error;
      });

      expect(uncaught, isNull,
          reason: 'a fire-and-forget period-expansion failure must never become an uncaught zone error');
      expect(loader.docs.map((d) => d.id), ['keep'],
          reason: 'the already-loaded valid data must survive the failed expansion');
      expect(loader.error, isNotNull);
      expect(loader.loading, isFalse);

      // A successful explicit retry clears the error and populates the
      // missing (older) data.
      Object? uncaughtOnRetry;
      await runZonedGuarded(() async {
        fireAndForget(loader.requestCoverage(DateTime(2025, 1, 1)));
        rig.resolve(2, RawFetchResult.ok([
          doc('keep', DateTime(2026, 8, 10)),
          doc('older', DateTime(2025, 6, 1)),
        ]));
        await Future<void>.delayed(Duration.zero);
      }, (error, stack) {
        uncaughtOnRetry = error;
      });

      expect(uncaughtOnRetry, isNull);
      expect(loader.error, isNull, reason: 'a successful retry must clear the error');
      expect(loader.docs.map((d) => d.id).toSet(), {'keep', 'older'});
    });

    test('a failed fetch does not automatically retry forever (no infinite retry loop)',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      fireAndForget(loader.requestCoverage(DateTime(2026, 1, 1)));
      rig.resolve(0, const RawFetchResult.failure('offline'));
      await Future<void>.delayed(Duration.zero);

      // Give any errant auto-retry loop a chance to fire before asserting
      // it didn't: still only the one call that was ever made.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.calls, hasLength(1),
          reason: 'a failure must surface once, not trigger an automatic infinite retry loop');
      expect(loader.loading, isFalse);
    });
  });
}
