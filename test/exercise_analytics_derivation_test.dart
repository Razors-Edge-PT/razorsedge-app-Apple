// Integration-style regression coverage combining AnalyticsHistoryLoader
// (the production request/state controller) with the pure derivation
// functions it feeds (deriveWorkoutsForExercise, deriveVelocitySamplesForExercise,
// dailyMaxVelocity). No Firebase, no widget mounting — a controlled fake
// fetcher drives the loader exactly as the real screen would.
//
// These specifically exercise the review scenarios from commit 53df026f
// that a purely unit-level test of either half alone wouldn't prove:
//   * issue 1 — switching the selected exercise while a fetch is in flight,
//     in both completion orders, must never show the wrong exercise's data,
//   * issue 6 — deleting the fastest/only matching set and re-deriving from
//     an authoritative refresh must be reflected correctly.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/analytics_history_loader.dart';
import 'package:localtest222/exercise_details_screen.dart';

Map<String, dynamic> setMap({int? reps, double? weight, double? velocity, double? rir}) => {
      if (reps != null) 'reps': reps,
      if (weight != null) 'weight': weight,
      if (velocity != null) 'velocity': velocity,
      if (rir != null) 'rir': rir,
    };

RawWorkoutDoc doc(
  String id,
  DateTime date, {
  required String exerciseId,
  required String exerciseName,
  required List<Map<String, dynamic>> sets,
}) =>
    RawWorkoutDoc(id: id, date: date, exercises: [
      {'id': exerciseId, 'name': exerciseName, 'sets': sets},
    ]);

class FakeFetcherRig {
  final List<FakeFetchCall> calls = [];
  RawFetcher get fetcher => ({required DateTime since}) {
        final c = Completer<RawFetchResult>();
        calls.add(FakeFetchCall(since, c));
        return c.future;
      };
  void resolve(int i, RawFetchResult r) => calls[i].completer.complete(r);
}

class FakeFetchCall {
  final DateTime since;
  final Completer<RawFetchResult> completer;
  FakeFetchCall(this.since, this.completer);
}

void main() {
  group('review-follow-up issue 1 — E1RM daily-winner selection restored', () {
    test(
        'two workouts the same day: E1RM/rep-target charts use only the winning '
        'workout, but velocity still sees the losing workout\'s faster set', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);
      final day = DateTime(2026, 8, 10);

      final f = loader.requestCoverage(DateTime(2026, 8, 1));
      rig.resolve(0, RawFetchResult.ok([
        // Loses the E1RM comparison (Brzycki: 60 * 36/(37-11) ≈ 83.1) but
        // carries the day's FASTEST velocity set.
        doc('losing-workout', day,
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 10, weight: 60, rir: 1, velocity: 0.90)]),
        // Wins the E1RM comparison (Brzycki: 100 * 36/(37-3) ≈ 105.9) with a
        // slower recorded velocity.
        doc('winning-workout', day,
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 3, weight: 100, rir: 0, velocity: 0.30)]),
      ]));
      await f;

      // E1RM / rep-target chart source: only the winning workout's sets —
      // restoring the pre-loader-refactor day-winner selection.
      final workouts = deriveWorkoutsForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(workouts, hasLength(1),
          reason: 'two same-day workouts must collapse to one day-winner, not plot both');
      final winnerSets = workouts.single.exercises.single.sets;
      expect(winnerSets, hasLength(1));
      expect(winnerSets.single.reps, 3);
      expect(winnerSets.single.weight, 100,
          reason: 'the higher-E1RM workout (3 reps @ 100kg) must be the day\'s representative, '
              'not the 10-rep @ 60kg workout');

      // A rep-target filter for "10 reps" (the LOSING workout's rep count)
      // must find nothing that day, since the winner was 3 reps.
      expect(winnerSets.any((s) => s.reps == 10), isFalse);

      // Velocity: must still see BOTH workouts' sets and pick the fastest
      // regardless of which one won the E1RM comparison.
      final velocitySamples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(velocitySamples, hasLength(2),
          reason: 'velocity must consider every matching set from every workout that day');
      final fastestAt3reps100kg = dailyMaxVelocity(samples: velocitySamples, reps: 3, weight: 100);
      final fastestAt10reps60kg = dailyMaxVelocity(samples: velocitySamples, reps: 10, weight: 60);
      expect(fastestAt3reps100kg.single.velocity, 0.30);
      expect(fastestAt10reps60kg.single.velocity, 0.90,
          reason: 'the losing workout\'s faster set must remain visible to velocity');
    });

    test('when the E1RM comparison ties in reverse order, the later-seen document does not '
        'spuriously override an already-better one', () async {
      // Guards against an off-by-comparison bug (e.g. `>=` instead of `>`)
      // silently letting a later, equal-or-worse document win.
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);
      final day = DateTime(2026, 8, 10);

      final f = loader.requestCoverage(DateTime(2026, 8, 1));
      rig.resolve(0, RawFetchResult.ok([
        doc('a', day, exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 5, weight: 100, rir: 1)]), // higher E1RM
        doc('b', day, exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 5, weight: 90, rir: 1)]), // strictly lower E1RM
      ]));
      await f;

      final workouts = deriveWorkoutsForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(workouts, hasLength(1));
      expect(workouts.single.exercises.single.sets.single.weight, 100);
    });
  });

  group('issue 1 — switching exercises while a fetch is in flight', () {
    test('Bench velocity loading, then select Squat: Squat shows only Squat data '
        '(fetch resolves AFTER the switch)', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      // User is viewing Bench velocity; this triggers a coverage fetch.
      final pending = loader.requestCoverage(DateTime(2026, 1, 1));

      // Before it resolves, the user switches to Squat — represented here
      // simply as a different targetId/targetName passed to the pure
      // derivation, exactly as the screen's _activeExerciseId would change.
      String activeId = 'squat-id';
      String activeName = 'Squat';

      // The fetch (triggered by Bench's selection) now resolves, carrying
      // history for BOTH exercises, as a real Firestore query naturally
      // would (it's athlete-scoped, not exercise-scoped).
      rig.resolve(0, RawFetchResult.ok([
        doc('d1', DateTime(2026, 8, 1),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.4)]),
        doc('d2', DateTime(2026, 8, 1),
            exerciseId: 'squat-id', exerciseName: 'Squat',
            sets: [setMap(reps: 1, weight: 140, velocity: 0.3)]),
      ]));
      await pending;

      final squatSamples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: activeId, targetName: activeName);
      expect(squatSamples, hasLength(1));
      expect(squatSamples.single.weight, 140,
          reason: 'the currently-selected exercise (Squat) must show only its own data, '
              'never the Bench selection that happened to trigger the fetch');

      final benchSamples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(benchSamples, hasLength(1));
      expect(benchSamples.single.weight, 100);
    });

    test('the same scenario with the fetch resolving BEFORE the switch (other completion order)',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final pending = loader.requestCoverage(DateTime(2026, 1, 1));
      rig.resolve(0, RawFetchResult.ok([
        doc('d1', DateTime(2026, 8, 1),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.4)]),
        doc('d2', DateTime(2026, 8, 1),
            exerciseId: 'squat-id', exerciseName: 'Squat',
            sets: [setMap(reps: 1, weight: 140, velocity: 0.3)]),
      ]));
      await pending; // resolves first, THEN the user switches

      final squatSamples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'squat-id', targetName: 'Squat');
      expect(squatSamples, hasLength(1));
      expect(squatSamples.single.weight, 140);
    });

    test('equivalent E1RM coverage: switching exercises never shows the wrong workouts', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final pending = loader.requestCoverage(DateTime(2026, 1, 1));
      rig.resolve(0, RawFetchResult.ok([
        doc('d1', DateTime(2026, 8, 1),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 5, weight: 100, rir: 1)]),
        doc('d2', DateTime(2026, 8, 1),
            exerciseId: 'squat-id', exerciseName: 'Squat',
            sets: [setMap(reps: 5, weight: 140, rir: 1)]),
      ]));
      await pending;

      final squatWorkouts = deriveWorkoutsForExercise(
          docs: loader.docs, targetId: 'squat-id', targetName: 'Squat');
      expect(squatWorkouts, hasLength(1));
      expect(squatWorkouts.single.exercises.single.sets.single.weight, 140);
    });

    test('athlete change: a stale loader for the previous athlete cannot affect the new one',
        () async {
      final rigA = FakeFetcherRig();
      final rigB = FakeFetcherRig();
      final loaderA = AnalyticsHistoryLoader(uid: 'athleteA', fetcher: rigA.fetcher);

      final pendingA = loaderA.requestCoverage(DateTime(2026, 1, 1));
      pendingA.catchError((_) {}); // production also fires this and forgets

      // Coach switches to a different athlete before A's fetch resolves.
      loaderA.dispose();
      final loaderB = AnalyticsHistoryLoader(uid: 'athleteB', fetcher: rigB.fetcher);
      addTearDown(loaderB.dispose);

      final pendingB = loaderB.requestCoverage(DateTime(2026, 1, 1));
      rigB.resolve(0, RawFetchResult.ok([
        doc('b1', DateTime(2026, 8, 1),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 5, weight: 60, rir: 1)]),
      ]));
      await pendingB;

      // A's late completion (if it ever arrived) would land on a disposed,
      // unreferenced object — it cannot reach loaderB's docs.
      rigA.resolve(0, RawFetchResult.ok([
        doc('a1', DateTime(2026, 8, 1),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 5, weight: 999, rir: 1)]),
      ]));
      await Future<void>.delayed(Duration.zero);

      final workouts = deriveWorkoutsForExercise(
          docs: loaderB.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(workouts.single.exercises.single.sets.single.weight, 60,
          reason: "athlete A's late 999kg response must never contaminate athlete B's data");
    });
  });

  group('issue 6 — authoritative refresh reflects deletions correctly', () {
    test('deleting the fastest matching velocity set promotes the next-fastest', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final since = DateTime(2026, 8, 1);
      final f1 = loader.requestCoverage(since);
      rig.resolve(0, RawFetchResult.ok([
        doc('fast', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.42)]),
        doc('slow', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.30)]),
      ]));
      await f1;

      var samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      var points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100);
      expect(points.single.velocity, 0.42);

      // The fastest set's document is deleted; an explicit refresh (as a
      // save/edit/delete invalidation path would trigger) re-verifies the
      // interval.
      final refresh = loader.invalidate(since);
      rig.resolve(1, RawFetchResult.ok([
        doc('slow', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.30)]),
      ]));
      await refresh;

      samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100);
      expect(points.single.velocity, 0.30,
          reason: 'the next-fastest recorded set must become the daily point');
    });

    test('deleting the last matching set makes the point disappear', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final since = DateTime(2026, 8, 1);
      final f1 = loader.requestCoverage(since);
      rig.resolve(0, RawFetchResult.ok([
        doc('only', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.42)]),
      ]));
      await f1;

      final refresh = loader.invalidate(since);
      rig.resolve(1, const RawFetchResult.ok([])); // deleted
      await refresh;

      final samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100);
      expect(points, isEmpty);
    });

    test('an edit that changes reps/load makes a set ineligible for its old combination',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final since = DateTime(2026, 8, 1);
      final f1 = loader.requestCoverage(since);
      rig.resolve(0, RawFetchResult.ok([
        doc('set1', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.42)]),
      ]));
      await f1;

      // Edited: same document id, now 3 reps at 80kg instead of 1 at 100kg.
      final refresh = loader.invalidate(since);
      rig.resolve(1, RawFetchResult.ok([
        doc('set1', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 3, weight: 80, velocity: 0.55)]),
      ]));
      await refresh;

      final samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(dailyMaxVelocity(samples: samples, reps: 1, weight: 100), isEmpty,
          reason: 'the old combination no longer has any backing data');
      expect(dailyMaxVelocity(samples: samples, reps: 3, weight: 80).single.velocity, 0.55);
    });

    test('a failed refresh retains valid E1RM/velocity data with an error indication', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final f1 = loader.requestCoverage(DateTime(2026, 8, 1));
      rig.resolve(0, RawFetchResult.ok([
        doc('keep', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 5, weight: 100, rir: 1, velocity: 0.4)]),
      ]));
      await f1;

      final refresh = loader.invalidate(DateTime(2026, 8, 1));
      rig.resolve(1, const RawFetchResult.failure('offline'));
      await expectLater(refresh, throwsA(anything));

      expect(loader.error, isNotNull);
      final workouts = deriveWorkoutsForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(workouts, hasLength(1), reason: 'valid data must survive a failed refresh');
    });
  });

  group('issue 4 — older combinations discoverable, missing history vs empty window', () {
    test('a combination recorded six weeks ago is exposed once coverage reaches that far back',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final sixWeeksAgo = DateTime.now().subtract(const Duration(days: 42));

      // The chart's own short window (last 14 days) has nothing for this
      // exercise — discovery must reach further back to find the combo.
      final shortWindow = loader.requestCoverage(DateTime.now().subtract(const Duration(days: 14)));
      rig.resolve(0, const RawFetchResult.ok([]));
      await shortWindow;

      var samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(VelocityCombinations.fromSamples(samples).reps, isEmpty,
          reason: 'not yet discoverable within only the short window');

      // Velocity mode's progressive discovery reaches back further.
      final deeper = loader.requestCoverage(DateTime.now().subtract(const Duration(days: 365)));
      rig.resolve(1, RawFetchResult.ok([
        doc('old-session', sixWeeksAgo,
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 3, weight: 90, velocity: 0.5)]),
      ]));
      await deeper;

      samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      final combos = VelocityCombinations.fromSamples(samples);
      expect(combos.isEligible(3, 90), isTrue,
          reason: 'the six-week-old combination must now be exposed');

      // Selecting the appropriate older period plots it.
      final points = dailyMaxVelocity(samples: samples, reps: 3, weight: 90);
      expect(points.single.date, DateTime(sixWeeksAgo.year, sixWeeksAgo.month, sixWeeksAgo.day));
    });

    test('genuinely empty history: discovery completing with nothing is a confirmed empty state',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final f = loader.requestCoverage(DateTime(2000, 1, 1));
      rig.resolve(0, const RawFetchResult.ok([]));
      await f;

      expect(loader.coversSince(DateTime(2000, 1, 1)), isTrue,
          reason: 'discovery has genuinely completed back to the supported minimum');
      final samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(samples, isEmpty);
    });

    test('discovery failure leaves coverage incomplete rather than a false "no history" state',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final f = loader.requestCoverage(DateTime(2000, 1, 1));
      rig.resolve(0, const RawFetchResult.failure('network error'));
      await expectLater(f, throwsA(anything));

      expect(loader.coversSince(DateTime(2000, 1, 1)), isFalse,
          reason: 'a failed fetch must never be mistaken for confirmed-empty history');
      expect(loader.error, isNotNull);
    });

    test('a previously-selected valid combination remains eligible as more (unrelated) data arrives',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final f1 = loader.requestCoverage(DateTime(2026, 8, 1));
      rig.resolve(0, RawFetchResult.ok([
        doc('d1', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.4)]),
      ]));
      await f1;

      var samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(VelocityCombinations.fromSamples(samples).isEligible(1, 100), isTrue);

      // More (older, unrelated) history arrives — the earlier selection
      // must remain valid, not be reset by the arrival of new options.
      final f2 = loader.requestCoverage(DateTime(2025, 1, 1));
      rig.resolve(1, RawFetchResult.ok([
        doc('d1', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.4)]),
        doc('d2', DateTime(2025, 3, 1),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 5, weight: 60, velocity: 0.7)]),
      ]));
      await f2;

      samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      final combos = VelocityCombinations.fromSamples(samples);
      expect(combos.isEligible(1, 100), isTrue, reason: 'the original selection is still valid');
      expect(combos.isEligible(5, 60), isTrue, reason: 'the new option is also now available');
    });
  });

  group('review-follow-up issue 2 — refreshLoadedCoverage (the production refresh action)', () {
    // refreshLoadedCoverage is the exact function the AppBar refresh button
    // and the app-resume lifecycle hook call (see _refreshLoadedData in
    // exercise_details_screen.dart) — not a reimplementation of the wiring,
    // the wiring itself, extracted so it's testable without mounting the
    // Firebase-dependent screen (matching this codebase's established
    // pattern of testing an extracted production widget/function directly,
    // e.g. test/wes2_app_bar_test.dart).

    test('a null loader (no session yet) is a safe no-op', () async {
      await refreshLoadedCoverage(
        loader: null,
        e1rmCutoff: DateTime(2026, 8, 1),
        metric: AnalyticsMetric.e1rm,
        velocityCutoff: DateTime(2026, 8, 1),
      );
      // Completing without throwing is the whole assertion.
    });

    test('refreshes an ALREADY FULLY-COVERED interval — invalidate(), not requestCoverage()',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final e1rmCutoff = DateTime(2026, 8, 1);
      final initial = loader.requestCoverage(e1rmCutoff);
      rig.resolve(0, RawFetchResult.ok([
        doc('keep', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 5, weight: 100, rir: 1)]),
      ]));
      await initial;
      expect(loader.coversSince(e1rmCutoff), isTrue);

      // A plain requestCoverage() for the SAME (already-covered) depth would
      // be a silent no-op — proving this must go through invalidate().
      final refresh = refreshLoadedCoverage(
        loader: loader,
        e1rmCutoff: e1rmCutoff,
        metric: AnalyticsMetric.e1rm,
        velocityCutoff: e1rmCutoff,
      );
      expect(rig.calls, hasLength(2),
          reason: 'refreshing already-loaded data must still trigger a real fetch');
      rig.resolve(1, const RawFetchResult.ok([])); // "keep" was deleted server-side
      await refresh;

      expect(loader.docs, isEmpty,
          reason: 'the production refresh path must apply an authoritative deletion');
    });

    test('E1RM mode: refreshes the deepest of the trend/rep-target cutoffs', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final shallow = DateTime(2026, 8, 1);
      final deep = DateTime(2025, 1, 1);
      final initial = loader.requestCoverage(deep);
      rig.resolve(0, const RawFetchResult.ok([]));
      await initial;

      final refresh = refreshLoadedCoverage(
        loader: loader,
        e1rmCutoff: shallow, // e.g. the trend chart's own (shallower) cutoff
        metric: AnalyticsMetric.e1rm,
        velocityCutoff: shallow,
      );
      rig.resolve(1, const RawFetchResult.ok([])); // the refresh's own fetch
      await refresh;
      // The refreshed interval must be at least the deepest relevant
      // cutoff; since `deep` was already covered and `shallow` is a subset
      // of it, this must not have needed to go deeper than `deep`.
      expect(loader.coversSince(deep), isTrue);
    });

    test('velocity mode: refreshes the deeper of the E1RM cutoff and the velocity window',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final e1rmCutoff = DateTime(2026, 8, 1);
      final velocityCutoff = DateTime(2025, 1, 1); // a longer custom velocity range

      final refresh = refreshLoadedCoverage(
        loader: loader,
        e1rmCutoff: e1rmCutoff,
        metric: AnalyticsMetric.velocity,
        velocityCutoff: e1rmCutoff,
        customVelocityStart: velocityCutoff,
      );
      rig.resolve(0, const RawFetchResult.ok([]));
      await refresh;

      expect(loader.coversSince(velocityCutoff), isTrue,
          reason: 'the deeper (velocity custom range) cutoff must be the one actually fetched');
    });

    test('deleting the fastest matching velocity set via the production refresh path '
        'promotes the next-fastest', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);
      final since = DateTime(2026, 8, 1);

      final initial = loader.requestCoverage(since);
      rig.resolve(0, RawFetchResult.ok([
        doc('fast', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.42)]),
        doc('slow', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.30)]),
      ]));
      await initial;

      final refresh = refreshLoadedCoverage(
        loader: loader,
        e1rmCutoff: since,
        metric: AnalyticsMetric.velocity,
        velocityCutoff: since,
      );
      rig.resolve(1, RawFetchResult.ok([
        doc('slow', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.30)]),
      ]));
      await refresh;

      final samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100);
      expect(points.single.velocity, 0.30);
    });

    test('deleting the last matching set via the production refresh path removes the point',
        () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);
      final since = DateTime(2026, 8, 1);

      final initial = loader.requestCoverage(since);
      rig.resolve(0, RawFetchResult.ok([
        doc('only', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.42)]),
      ]));
      await initial;

      final refresh = refreshLoadedCoverage(
        loader: loader,
        e1rmCutoff: since,
        metric: AnalyticsMetric.velocity,
        velocityCutoff: since,
      );
      rig.resolve(1, const RawFetchResult.ok([]));
      await refresh;

      final samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(dailyMaxVelocity(samples: samples, reps: 1, weight: 100), isEmpty);
    });

    test('a refresh preserves data outside the refreshed interval', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final wide = loader.requestCoverage(DateTime(2020, 1, 1));
      rig.resolve(0, RawFetchResult.ok([doc('old', DateTime(2020, 6, 1),
          exerciseId: 'bench-id', exerciseName: 'Bench Press', sets: [setMap(reps: 5, weight: 60)])]));
      await wide;

      final refresh = refreshLoadedCoverage(
        loader: loader,
        e1rmCutoff: DateTime(2026, 1, 1),
        metric: AnalyticsMetric.e1rm,
        velocityCutoff: DateTime(2026, 1, 1),
      );
      rig.resolve(1, RawFetchResult.ok([doc('new', DateTime(2026, 2, 1),
          exerciseId: 'bench-id', exerciseName: 'Bench Press', sets: [setMap(reps: 5, weight: 70)])]));
      await refresh;

      expect(loader.docs.map((d) => d.id).toSet(), {'old', 'new'});
    });

    test('a failed refresh keeps valid data and surfaces an error even though coverage '
        'was previously complete', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);
      final since = DateTime(2026, 8, 1);

      final initial = loader.requestCoverage(since);
      rig.resolve(0, RawFetchResult.ok([doc('keep', DateTime(2026, 8, 10),
          exerciseId: 'bench-id', exerciseName: 'Bench Press', sets: [setMap(reps: 5, weight: 100)])]));
      await initial;
      expect(loader.coversSince(since), isTrue);

      final refresh = refreshLoadedCoverage(
        loader: loader,
        e1rmCutoff: since,
        metric: AnalyticsMetric.e1rm,
        velocityCutoff: since,
      );
      rig.resolve(1, const RawFetchResult.failure('offline'));
      await expectLater(refresh, throwsA(anything));

      expect(loader.error, isNotNull,
          reason: 'a refresh failure must be visible even though cached coverage was complete');
      final workouts = deriveWorkoutsForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      expect(workouts, hasLength(1), reason: 'valid data must survive a failed refresh');
    });
  });

  group('review-follow-up issue 4 — velocityWindowStatus (the production velocity UI state)',
      () {
    // velocityWindowStatus is the exact function _buildVelocitySection uses
    // to decide whether "No data for this range" is honest yet, and
    // whether a load/refresh failure must be shown even while an
    // already-valid chart is on screen — not a reimplementation of that
    // decision, the decision itself, extracted for direct testability
    // (same approach as refreshLoadedCoverage above).

    test('no loader yet (no session) is "loading", never "ready" or "failed"', () {
      expect(
        velocityWindowStatus(loader: null, windowSince: DateTime(2026, 1, 1)),
        VelocityWindowStatus.loading,
      );
    });

    test('an empty selected period whose fetch has not completed is "loading", '
        'never presented as "No data for this range"', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      // Nothing requested/resolved yet.
      expect(
        velocityWindowStatus(loader: loader, windowSince: DateTime(2026, 1, 1)),
        VelocityWindowStatus.loading,
      );
    });

    test(
        'full scenario: recent samples load, an older custom period is selected, its fetch '
        'fails (shown despite existing samples), then a retry succeeds', () async {
      final rig = FakeFetcherRig();
      final loader = AnalyticsHistoryLoader(uid: 'athlete1', fetcher: rig.fetcher);
      addTearDown(loader.dispose);

      final recentSince = DateTime(2026, 8, 1);
      final olderSince = DateTime(2025, 1, 1); // an older/custom period selection

      // 1. Recent velocity samples load successfully.
      final recent = loader.requestCoverage(recentSince);
      rig.resolve(0, RawFetchResult.ok([
        doc('recent-set', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.4)]),
      ]));
      await recent;
      expect(velocityWindowStatus(loader: loader, windowSince: recentSince),
          VelocityWindowStatus.ready);
      expect(deriveVelocitySamplesForExercise(
              docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press'),
          isNotEmpty,
          reason: 'existing samples must not mask the later older-period failure');

      // 2. The user selects an older/custom period — its coverage isn't
      // known yet (not requested), so it must read as "loading", never
      // "ready" and never a false "no data".
      expect(velocityWindowStatus(loader: loader, windowSince: olderSince),
          VelocityWindowStatus.loading);

      // 3. Its fetch is attempted and fails.
      final olderAttempt = loader.requestCoverage(olderSince);
      rig.resolve(1, const RawFetchResult.failure('offline'));
      await olderAttempt.catchError((_) {});

      expect(velocityWindowStatus(loader: loader, windowSince: olderSince),
          VelocityWindowStatus.failed,
          reason: 'the failure for the selected older period must be visible '
              'despite recent samples already existing');
      // The ALREADY-COVERED recent window must not be retroactively marked
      // incomplete by an unrelated interval's failure.
      expect(velocityWindowStatus(loader: loader, windowSince: recentSince),
          VelocityWindowStatus.ready,
          reason: "a different interval's failure must not mark an already-complete "
              'visible chart as incomplete');

      // 4. A successful retry clears the error and populates the missing
      // (older) data.
      final retry = loader.requestCoverage(olderSince);
      rig.resolve(2, RawFetchResult.ok([
        doc('recent-set', DateTime(2026, 8, 10),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.4)]),
        doc('older-set', DateTime(2025, 3, 1),
            exerciseId: 'bench-id', exerciseName: 'Bench Press',
            sets: [setMap(reps: 1, weight: 100, velocity: 0.5)]),
      ]));
      await retry;

      expect(velocityWindowStatus(loader: loader, windowSince: olderSince),
          VelocityWindowStatus.ready,
          reason: 'a successful retry must clear the error and mark the period ready');
      expect(loader.error, isNull);
      final samples = deriveVelocitySamplesForExercise(
          docs: loader.docs, targetId: 'bench-id', targetName: 'Bench Press');
      final points = dailyMaxVelocity(samples: samples, reps: 1, weight: 100);
      expect(points.map((p) => p.date), [DateTime(2025, 3, 1), DateTime(2026, 8, 10)]);
    });
  });
}
