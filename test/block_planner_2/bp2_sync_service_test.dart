import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_sync_service.dart';

import 'bp2_test_support.dart';

void main() {
  const athlete = 'athlete-uid';
  const coach = 'coach-uid';

  Future<Harness> seeded() async {
    final h = Harness();
    await h.seedShared('bp', 'Bench Press, Barbell');
    await h.seedShared('sq', 'Back Squat, Barbell',
        category: 'Squat Pattern', bodyPart: 'Quads');
    await h.seedCustom(athlete, 'c1', 'Athlete Custom');
    await h.seedCustom(coach, 'coachCustom', 'Coach Custom');
    await h.seedTemplate(athlete, 't1', 'b1', [
      {'exerciseId': 'bp', 'name': 'Bench Press, Barbell'}
    ]);
    await h.seedBlock(athlete, 'b1', isActive: true);
    await h.seedUser(athlete, username: 'richard', displayName: 'Richard S');
    return h;
  }

  test('cold refresh downloads every collection once and caches it', () async {
    final h = await seeded();
    final r = await h.sync.refresh(athlete);
    expect(
        r.refetched,
        containsAll([
          Bp2SyncService.kShared,
          Bp2SyncService.kCustom,
          Bp2SyncService.kTemplates,
          Bp2SyncService.kBlocks,
        ]));
    expect(r.snapshot.shared.map((e) => e.id), containsAll(['bp', 'sq']));
    expect(r.snapshot.custom.map((e) => e.id), ['c1']);
    expect(r.snapshot.templates.single.blockId, 'b1');
    expect(r.snapshot.blocks.single.isActive, isTrue);
    expect(r.snapshot.athleteLabel, 'richard');
    expect(h.repo.totalFetches, 4);
    expect(h.repo.countCalls, 0); // nothing cached → no count needed
  });

  test('warm open with unchanged revision performs only count reads', () async {
    final h = await seeded();
    await h.sync.refresh(athlete);
    final cacheWritesAfterCold = h.cache.writes;
    h.now = h.now.add(const Duration(minutes: 5));

    final r = await h.sync.refresh(athlete);
    expect(r.refetched, isEmpty);
    expect(h.repo.totalFetches, 4, reason: 'no re-download');
    expect(h.repo.countCalls, 4, reason: 'one aggregate count per collection');
    expect(h.cache.writes, cacheWritesAfterCold, reason: 'cache untouched');
    expect(r.snapshot.custom.map((e) => e.id), ['c1']);
  });

  test('cached data renders before remote freshness completes', () async {
    final h = await seeded();
    await h.sync.refresh(athlete);
    final cached = await h.sync.readCached(athlete);
    expect(cached, isNotNull);
    expect(cached!.shared.length, 2);
    expect(cached.athleteLabel, 'richard');
    // Reading the cache costs no repository reads at all.
    expect(h.repo.countCalls, 0);
    expect(h.repo.totalFetches, 4);
  });

  test('a changed count re-downloads only that collection (deletion detected)',
      () async {
    final h = await seeded();
    await h.sync.refresh(athlete);
    await h.db
        .collection('users')
        .doc(athlete)
        .collection('customExercises')
        .doc('c1')
        .delete();
    await h.seedCustom(athlete, 'c2', 'Replacement');
    await h.seedCustom(athlete, 'c3', 'Another');
    h.now = h.now.add(const Duration(minutes: 1));

    final r = await h.sync.refresh(athlete);
    expect(r.refetched, {Bp2SyncService.kCustom});
    expect(r.snapshot.custom.map((e) => e.id).toSet(), {'c2', 'c3'});
    expect(h.repo.sharedFetches, 1);
    expect(h.repo.customFetches, 2);
    expect(h.repo.templateFetches, 1);
    expect(h.repo.blockFetches, 1);
  });

  test('max age bounds staleness for in-place edits a count cannot see',
      () async {
    final h = await seeded();
    await h.sync.refresh(athlete);
    await h.db
        .collection('exercises')
        .doc('bp')
        .update({'name': 'Bench Press (renamed)'});
    h.now = h.now.add(const Duration(hours: 25));
    final r = await h.sync.refresh(athlete);
    expect(r.refetched, contains(Bp2SyncService.kShared));
    expect(r.snapshot.shared.firstWhere((e) => e.id == 'bp').name,
        'Bench Press (renamed)');
  });

  test('reads and cache keys are scoped to the selected athlete, not the coach',
      () async {
    final h = await seeded();
    final r = await h.sync.refresh(athlete);
    expect(r.snapshot.custom.map((e) => e.id), ['c1']);
    expect(r.snapshot.custom.any((e) => e.id == 'coachCustom'), isFalse);
    expect(
        h.cache.keysFor(athlete),
        containsAll([
          Bp2SyncService.kCustom,
          Bp2SyncService.kTemplates,
          Bp2SyncService.kBlocks,
          Bp2SyncService.kAthleteLabel,
        ]));
    expect(h.cache.keysFor(coach), isEmpty);
    // Shared catalogue is stored once, under the shared scope.
    expect(
        h.cache.keysFor(Bp2SyncService.sharedScope), [Bp2SyncService.kShared]);
    // The coach's own pool is a separate partition.
    final rc = await h.sync.refresh(coach);
    expect(rc.snapshot.custom.map((e) => e.id), ['coachCustom']);
    expect(h.repo.sharedFetches, 1,
        reason: 'shared catalogue not re-downloaded');
  });

  test('athlete label resolves username → displayName → neutral fallback',
      () async {
    final h = Harness();
    await h.seedUser('u1', username: 'jane', displayName: 'Jane D');
    await h.seedUser('u2', displayName: 'Only Display');
    expect(await h.repo.fetchAthleteLabel('u1'), 'jane');
    expect(await h.repo.fetchAthleteLabel('u2'), 'Only Display');
    expect(await h.repo.fetchAthleteLabel('nobody'), 'athlete');
  });

  test('a locally added custom exercise updates the cache without a download',
      () async {
    final h = await seeded();
    await h.sync.refresh(athlete);
    await h.seedCustom(athlete, 'c9', 'Brand New');
    final custom = await h.sync.addCustomExerciseToCache(
      athlete,
      (await h.repo.fetchCustomExercises(athlete))
          .firstWhere((e) => e.id == 'c9'),
    );
    expect(custom.map((e) => e.id).toSet(), {'c1', 'c9'});
    h.now = h.now.add(const Duration(minutes: 1));
    final r = await h.sync.refresh(athlete);
    expect(r.refetched, isEmpty, reason: 'count now matches the cache');
  });
}
