import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/progression_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the hydration policy: one authoritative load per athlete,
/// deduplicated across callers, with a Firestore cache that is trusted only
/// when a previously recorded COMPLETE server hydration vouches for it.

Map<String, dynamic> doc(String ymd, {double weight = 100.0}) => {
      'date': ymd,
      'exercises': [
        {
          'exerciseId': 'ex-1',
          'name': 'Bench Press, Barbell',
          'sets': [
            {'setIndex': 0, 'weight': weight, 'reps': 5, 'rir': 1.0}
          ],
        }
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ProgressionHistoryStore.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store.debugReset();
    store.debugServerFetch = null;
    store.debugCacheFetch = null;
    store.debugDayFetch = null;
    PeriodizationModelUtils.clearHistorySnapshot();
  });

  tearDown(() {
    store.debugReset();
    store.debugServerFetch = null;
    store.debugCacheFetch = null;
    store.debugDayFetch = null;
    PeriodizationModelUtils.clearHistorySnapshot();
  });

  // ── TEST 9 — partial cache must never be labelled complete ───────────────
  group('TEST 9 — Firestore cache completeness', () {
    test('a non-empty cache with no completeness marker is NOT authoritative',
        () async {
      store.debugServerFetch = (_) async => throw StateError('offline');
      // The Firestore local cache happens to hold 2 of the athlete's workouts
      // (e.g. left behind by an unrelated prefetch).
      store.debugCacheFetch =
          (_) async => [doc('2026-08-01'), doc('2026-08-08')];

      await store.ensureHydrated(uid: 'u1');

      final snap = store.snapshotFor('u1')!;
      expect(snap.workoutCount, 2);
      expect(snap.authoritative, isFalse,
          reason: 'a partial cache must never masquerade as complete history');
    });

    test('a cache smaller than the recorded complete hydration is NOT trusted',
        () async {
      // A previous session recorded a complete hydration of 10 documents.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.progression_history_complete:u1':
            '{"count":10,"at":"2026-08-01T00:00:00.000"}',
      });

      store.debugServerFetch = (_) async => throw StateError('offline');
      store.debugCacheFetch =
          (_) async => [doc('2026-08-01'), doc('2026-08-08')];

      await store.ensureHydrated(uid: 'u1');
      expect(store.snapshotFor('u1')!.authoritative, isFalse);
    });

    test('a cache matching a recorded complete hydration IS trusted offline',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.progression_history_complete:u1':
            '{"count":2,"at":"2026-08-01T00:00:00.000"}',
      });

      store.debugServerFetch = (_) async => throw StateError('offline');
      store.debugCacheFetch =
          (_) async => [doc('2026-08-01'), doc('2026-08-08')];

      await store.ensureHydrated(uid: 'u1');
      expect(store.snapshotFor('u1')!.authoritative, isTrue);
    });

    test('a non-authoritative snapshot is retried on the next call', () async {
      var serverCalls = 0;
      store.debugServerFetch = (_) async {
        serverCalls++;
        if (serverCalls == 1) throw StateError('offline');
        return [doc('2026-08-01'), doc('2026-08-08'), doc('2026-08-15')];
      };
      store.debugCacheFetch = (_) async => const <Map<String, dynamic>>[];

      await store.ensureHydrated(uid: 'u1');
      expect(store.snapshotFor('u1')!.authoritative, isFalse);

      await store.ensureHydrated(uid: 'u1');
      expect(serverCalls, 2);
      expect(store.snapshotFor('u1')!.authoritative, isTrue);
      expect(store.snapshotFor('u1')!.workoutCount, 3);
    });

    test('a successful hydration records the completeness marker', () async {
      store.debugServerFetch =
          (_) async => [doc('2026-08-01'), doc('2026-08-08')];
      await store.ensureHydrated(uid: 'u1');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('progression_history_complete:u1'),
          contains('"count":2'));
    });
  });

  // ── TEST 10b — one hydration per athlete, shared by every caller ─────────
  group('TEST 10b — hydration is deduplicated and reused', () {
    test('concurrent callers share ONE in-flight hydration', () async {
      var serverCalls = 0;
      final gate = Completer<void>();
      store.debugServerFetch = (_) async {
        serverCalls++;
        await gate.future;
        return [doc('2026-08-01')];
      };

      // Warmup and WES2 both ask at the same time.
      final warmup = store.ensureHydrated(uid: 'u1');
      final wes2 = store.ensureHydrated(uid: 'u1');
      expect(identical(warmup, wes2), isTrue,
          reason: 'the second caller must join the in-flight operation');

      gate.complete();
      await Future.wait([warmup, wes2]);

      expect(serverCalls, 1);
      expect(store.fullHydrationCount, 1);
    });

    test('reopening for the same athlete performs zero network work', () async {
      var serverCalls = 0;
      store.debugServerFetch = (_) async {
        serverCalls++;
        return [doc('2026-08-01')];
      };

      await store.ensureHydrated(uid: 'u1');
      for (int i = 0; i < 10; i++) {
        await store.ensureHydrated(uid: 'u1');
      }

      expect(serverCalls, 1);
      expect(store.hydrationCount, 1);
      expect(store.pendingRefresh('u1'), isNull);
    });

    test('the published snapshot builds the index exactly once', () async {
      store.debugServerFetch =
          (_) async => [doc('2026-08-01'), doc('2026-08-08')];

      await store.ensureHydrated(uid: 'u1');
      final builds = PeriodizationModelUtils.historyIndexBuilds;

      for (int i = 0; i < 10; i++) {
        await store.ensureHydrated(uid: 'u1');
        PeriodizationModelUtils.resolveTopSetHistory(
          exerciseId: 'ex-1',
          exerciseName: 'Bench Press, Barbell',
          asOfDate: DateTime(2026, 8, 23),
        );
      }

      expect(PeriodizationModelUtils.historyIndexBuilds, builds);
    });
  });

  // ── Athlete isolation ────────────────────────────────────────────────────
  test('switching athletes never reuses the other athlete history', () async {
    store.debugServerFetch = (uid) async => uid == 'coach-athlete-A'
        ? [doc('2026-08-01', weight: 100)]
        : [
            doc('2026-08-02', weight: 60),
            doc('2026-08-09', weight: 62.5),
          ];

    await store.ensureHydrated(uid: 'coach-athlete-A');
    expect(PeriodizationModelUtils.historyUid, 'coach-athlete-A');
    expect(PeriodizationModelUtils.savedWorkoutsList, hasLength(1));

    await store.ensureHydrated(uid: 'coach-athlete-B');
    expect(PeriodizationModelUtils.historyUid, 'coach-athlete-B');
    expect(PeriodizationModelUtils.savedWorkoutsList, hasLength(2));

    final routed = PeriodizationModelUtils.resolveTopSetHistory(
      exerciseId: 'ex-1',
      exerciseName: 'Bench Press, Barbell',
      asOfDate: DateTime(2026, 8, 23),
    );
    expect(routed.every((s) => (s['weight'] as num) < 100), isTrue);

    // Switching back re-publishes A's snapshot without another network call.
    await store.ensureHydrated(uid: 'coach-athlete-A');
    expect(PeriodizationModelUtils.historyUid, 'coach-athlete-A');
    expect(store.fullHydrationCount, 2);
  });

  // ── Invalidation ─────────────────────────────────────────────────────────
  group('invalidation', () {
    test('an edited day re-reads ONE document, not the whole collection',
        () async {
      var serverCalls = 0;
      var dayCalls = 0;
      store.debugServerFetch = (_) async {
        serverCalls++;
        return [doc('2026-08-01', weight: 100)];
      };
      store.debugDayFetch = (_, ymd) async {
        dayCalls++;
        return doc(ymd, weight: 140);
      };

      await store.ensureHydrated(uid: 'u1');
      store.markDayDirty(uid: 'u1', date: DateTime(2026, 8, 23));

      // ensureHydrated returns the current snapshot immediately and kicks the
      // patch off synchronously, so the pending future is observable before
      // any microtask runs.
      final ready = store.ensureHydrated(uid: 'u1');
      final pending = store.pendingRefresh('u1');
      expect(pending, isNotNull,
          reason: 'a background patch should be running');
      await ready;
      await pending;

      expect(serverCalls, 1, reason: 'no second full collection read');
      expect(dayCalls, 1);
      expect(store.snapshotFor('u1')!.workoutCount, 2);
      expect(PeriodizationModelUtils.savedWorkoutsList, hasLength(2));
    });

    test('a deleted day is removed from the snapshot', () async {
      store.debugServerFetch =
          (_) async => [doc('2026-08-01'), doc('2026-08-08')];
      store.debugDayFetch = (_, __) async => null;

      await store.ensureHydrated(uid: 'u1');
      store.markDayDirty(uid: 'u1', date: DateTime(2026, 8, 8));
      final ready = store.ensureHydrated(uid: 'u1');
      final pending = store.pendingRefresh('u1');
      await ready;
      await pending;

      expect(store.snapshotFor('u1')!.workoutCount, 1);
    });

    test('markStale forces one full refresh, then settles again', () async {
      var serverCalls = 0;
      store.debugServerFetch = (_) async {
        serverCalls++;
        return [doc('2026-08-01')];
      };

      await store.ensureHydrated(uid: 'u1');
      store.markStale('u1');
      final ready = store.ensureHydrated(uid: 'u1');
      final pending = store.pendingRefresh('u1');
      await ready;
      await pending;
      expect(serverCalls, 2);

      await store.ensureHydrated(uid: 'u1');
      expect(serverCalls, 2, reason: 'staleness must not latch on');
    });

    test('a failed day patch keeps the previous snapshot and retries',
        () async {
      store.debugServerFetch = (_) async => [doc('2026-08-01')];
      store.debugDayFetch = (_, __) async => throw StateError('offline');

      await store.ensureHydrated(uid: 'u1');
      store.markDayDirty(uid: 'u1', date: DateTime(2026, 8, 23));
      final ready = store.ensureHydrated(uid: 'u1');
      final pending = store.pendingRefresh('u1');
      await ready;
      await pending;

      expect(store.snapshotFor('u1')!.workoutCount, 1,
          reason: 'the previous valid history must survive a failed patch');

      // Still dirty → still retried.
      final retryReady = store.ensureHydrated(uid: 'u1');
      final retry = store.pendingRefresh('u1');
      expect(retry, isNotNull, reason: 'a failed patch must stay pending');
      await retryReady;
      await retry;
    });
  });
}
