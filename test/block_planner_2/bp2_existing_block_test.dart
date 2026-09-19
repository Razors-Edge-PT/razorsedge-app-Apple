import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_controller.dart';
import 'package:localtest222/block_planner_2/bp2_date_utils.dart';

import 'bp2_test_support.dart';

/// Existing-block loading, stored-date interpretation and block-name
/// precedence/persistence.
void main() {
  const athlete = 'athlete-uid';
  const coach = 'coach-uid';
  const custom = 'Bench Nationals 2026 9 weeks';
  final legacyStart = DateTime(2026, 8, 17); // Monday
  final legacyEnd = DateTime(2026, 11, 2); // Monday: exclusive boundary

  Future<Harness> seeded() async {
    final h = Harness();
    await h.seedShared('bp', 'Bench Press, Barbell');
    await h.seedUser(athlete, username: 'NZBenchPress');
    await h.seedUser(coach, username: 'coach');
    await h.seedBlock(athlete, 'bench',
        isActive: true, name: custom, start: legacyStart, end: legacyEnd);
    await h.seedBlock(athlete, 'unnamed',
        isActive: false, omitName: true, start: legacyStart, end: legacyEnd);
    return h;
  }

  Bp2Controller fresh(Harness h) => Bp2Controller(
        sync: h.sync,
        repo: h.repo,
        now: () => h.now,
        draftDebounce: Duration.zero,
      );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  group('stored date semantics', () {
    test(
        'legacy exclusive end (Mon→Mon, 77 days) reads as 11 weeks ending Sunday',
        () {
      final r = Bp2DateUtils.fromStored(legacyStart, legacyEnd);
      expect(r.start, DateTime(2026, 8, 17));
      expect(r.end, DateTime(2026, 11, 1));
      expect(r.weeks, 11);
    });

    test('canonical inclusive Sunday end is unchanged', () {
      final r =
          Bp2DateUtils.fromStored(DateTime(2026, 8, 17), DateTime(2026, 11, 1));
      expect(r.end, DateTime(2026, 11, 1));
      expect(r.weeks, 11);
      // Bootstrap blocks: start + 181 days (26 weeks, inclusive).
      final boot = Bp2DateUtils.fromStored(DateTime(2026, 9, 14),
          DateTime(2026, 9, 14).add(const Duration(days: 181)));
      expect(boot.weeks, 26);
    });

    test('generated-name detection is tied to the dates, not the label', () {
      final r = Bp2DateUtils.fromStored(legacyStart, legacyEnd);
      expect(
          Bp2DateUtils.isGeneratedName(
              'NZBenchPress — 17 Aug 2026 to 1 Nov 2026', r),
          isTrue);
      expect(Bp2DateUtils.isGeneratedName(custom, r), isFalse);
    });
  });

  group('opening an existing block', () {
    test('loads the exact block: custom name, stored dates, 11 weeks, no write',
        () async {
      final h = await seeded();
      final before = await h.block(athlete, 'bench');
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'bench', activeBlockId: 'bench');

      expect(c.block!.id, 'bench');
      expect(c.name, custom, reason: 'custom name loads exactly');
      expect(c.nameIsAuto, isFalse);
      expect(c.range!.start, DateTime(2026, 8, 17));
      expect(c.range!.end, DateTime(2026, 11, 1));
      expect(c.range!.weeks, 11, reason: 'never parsed from "9 weeks"');
      expect(c.isDirty, isFalse);
      expect((await c.save(fromExit: true)).nothingToSave, isTrue);
      expect(await h.block(athlete, 'bench'), before, reason: 'untouched');
      c.dispose();
    });

    test(
        'a block without a name shows the athlete/date fallback without writing',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'unnamed');
      expect(c.name, 'NZBenchPress — 17 Aug 2026 to 1 Nov 2026');
      expect(c.nameIsAuto, isTrue);
      expect(c.isDirty, isFalse);
      expect((await c.save()).nothingToSave, isTrue);
      expect((await h.block(athlete, 'unnamed'))!.containsKey('name'), isFalse);
      c.dispose();
    });

    test('legacy blockName is read; only the canonical name field is written',
        () async {
      final h = await seeded();
      await h.seedBlock(athlete, 'legacy',
          isActive: false,
          omitName: true,
          start: legacyStart,
          end: legacyEnd,
          extra: {'blockName': 'Old Style Name', 'unknownMeta': 7});
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'legacy');
      expect(c.name, 'Old Style Name');
      c.setName('New Style Name');
      expect((await c.save()).success, isTrue);
      final doc = (await h.block(athlete, 'legacy'))!;
      expect(doc['name'], 'New Style Name');
      expect(doc['blockName'], 'Old Style Name');
      expect(doc['unknownMeta'], 7);
      c.dispose();
    });

    test('a name-only save never rewrites (reinterprets) the stored dates',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'bench');
      c.setName('Bench Nationals 2026');
      expect((await c.save()).success, isTrue);
      final doc = (await h.block(athlete, 'bench'))!;
      expect(doc['name'], 'Bench Nationals 2026');
      expect((doc['startDate'] as Timestamp).toDate(), legacyStart);
      expect((doc['endDate'] as Timestamp).toDate(), legacyEnd);
      expect(h.repo.scaffolds, isEmpty);
      c.dispose();
    });

    test('a date change writes whole Monday–Sunday weeks with an inclusive end',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'bench');
      c.setRange(DateTime(2026, 8, 19), DateTime(2026, 11, 10));
      expect(c.range!.weeks, 13);
      expect(c.name, custom, reason: 'custom name survives date changes');
      expect((await c.save()).success, isTrue);
      final doc = (await h.block(athlete, 'bench'))!;
      expect((doc['startDate'] as Timestamp).toDate(), DateTime(2026, 8, 17));
      expect((doc['endDate'] as Timestamp).toDate(), DateTime(2026, 11, 15));
      expect(doc['name'], custom);
      expect(h.repo.scaffolds.single.$4, 13);
      c.dispose();
    });

    test('an untouched fallback follows date changes and is saved with them',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'unnamed');
      c.setRange(DateTime(2026, 8, 24), DateTime(2026, 11, 1));
      expect(c.name, 'NZBenchPress — 24 Aug 2026 to 1 Nov 2026');
      expect((await c.save()).success, isTrue);
      final doc = (await h.block(athlete, 'unnamed'))!;
      expect(doc['name'], 'NZBenchPress — 24 Aug 2026 to 1 Nov 2026');
      c.dispose();

      // Reloaded: recognised as generated, so it keeps following the dates.
      final c2 = fresh(h);
      await c2.bind(uid: athlete, blockId: 'unnamed');
      expect(c2.nameIsAuto, isTrue);
      c2.setRange(DateTime(2026, 8, 31), DateTime(2026, 11, 1));
      expect(c2.name, 'NZBenchPress — 31 Aug 2026 to 1 Nov 2026');
      c2.dispose();
    });

    test('manual save persists a custom name and reload restores it', () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'unnamed');
      c.setName('Peaking');
      c.setRange(DateTime(2026, 8, 24), DateTime(2026, 11, 1));
      expect(c.name, 'Peaking', reason: 'dates never overwrite a custom name');
      expect((await c.save()).success, isTrue);
      expect((await h.block(athlete, 'unnamed'))!['name'], 'Peaking');
      c.dispose();

      final c2 = fresh(h);
      await c2.bind(uid: athlete, blockId: 'unnamed');
      expect(c2.name, 'Peaking');
      expect(c2.nameIsAuto, isFalse);
      c2.dispose();
    });

    test('exit autosave persists the custom name', () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'bench');
      c.setName('Exit Named');
      final out = await c.save(fromExit: true);
      expect(out.success, isTrue);
      expect((await h.block(athlete, 'bench'))!['name'], 'Exit Named');
      c.dispose();
    });

    test('clearing a custom name restores the fallback without touching dates',
        () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'bench');
      c.setName('   ');
      expect(c.nameIsAuto, isTrue);
      expect(c.effectiveName, 'NZBenchPress — 17 Aug 2026 to 1 Nov 2026');
      expect((await c.save()).success, isTrue);
      final doc = (await h.block(athlete, 'bench'))!;
      expect(doc['name'], 'NZBenchPress — 17 Aug 2026 to 1 Nov 2026');
      expect((doc['startDate'] as Timestamp).toDate(), legacyStart);
      expect((doc['endDate'] as Timestamp).toDate(), legacyEnd);
      expect(c.name, 'NZBenchPress — 17 Aug 2026 to 1 Nov 2026');
      c.dispose();

      final c2 = fresh(h);
      await c2.bind(uid: athlete, blockId: 'bench');
      expect(c2.nameIsAuto, isTrue);
      expect(c2.range!.weeks, 11);
      c2.dispose();
    });

    test('a coach edits the selected athlete\'s block, never their own',
        () async {
      final h = await seeded();
      await h.seedBlock(coach, 'bench', isActive: true, name: 'Coach own');
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'bench');
      expect(c.name, custom);
      c.setName('Athlete block renamed by coach');
      expect((await c.save()).success, isTrue);
      expect((await h.block(athlete, 'bench'))!['name'],
          'Athlete block renamed by coach');
      expect((await h.block(coach, 'bench'))!['name'], 'Coach own');
      c.dispose();
    });

    test('a missing block is reported, never fabricated or written', () async {
      final h = await seeded();
      final c = h.controller;
      await c.bind(uid: athlete, blockId: 'does-not-exist');
      expect(c.block, isNull);
      expect(c.blockLoaded, isFalse);
      expect(c.blockLoadError, isNotNull);
      expect((await c.save()).success, isFalse);
      expect(await h.block(athlete, 'does-not-exist'), isNull);
      c.dispose();
    });

    test('a delayed load of a previously selected block cannot win', () async {
      final h = await seeded();
      final c = h.controller;
      final first = c.bind(uid: athlete, blockId: 'bench');
      final second = c.bind(uid: athlete, blockId: 'unnamed');
      await Future.wait([first, second]);
      await settle();
      expect(c.block!.id, 'unnamed');
      expect(c.name, 'NZBenchPress — 17 Aug 2026 to 1 Nov 2026');
      c.dispose();
    });
  });

  test('a genuinely new draft is four Monday–Sunday weeks from this Monday',
      () async {
    final h = await seeded();
    final c = h.controller; // now = Thu 24 Sep 2026
    await c.bind(uid: athlete);
    expect(c.block!.existsRemotely, isFalse);
    expect(c.range!.start, DateTime(2026, 9, 21));
    expect(c.range!.end, DateTime(2026, 10, 18));
    expect(c.range!.end.weekday, DateTime.sunday);
    expect(c.range!.weeks, 4);
    expect(c.name, 'NZBenchPress — 21 Sep 2026 to 18 Oct 2026');
    c.dispose();
  });
}
