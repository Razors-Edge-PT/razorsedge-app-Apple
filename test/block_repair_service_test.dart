import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_repair_service.dart';

/// Unit tests for the idempotent no-active-block self-heal.
/// Uses fake_cloud_firestore; template/creation side-effects are injected so
/// the tests cover the repair decisions themselves.
void main() {
  const athleteUid = '8DBY246vxgYYg1UtxMsB2d6ckpY2';

  CollectionReference<Map<String, dynamic>> blocksCol(
          FakeFirebaseFirestore fs, String uid) =>
      fs.collection('users').doc(uid).collection('planned_blocks');

  Future<List<String>> activeBlockIds(
      FakeFirebaseFirestore fs, String uid) async {
    final snap =
        await blocksCol(fs, uid).where('isActive', isEqualTo: true).get();
    return snap.docs.map((d) => d.id).toList();
  }

  Map<String, dynamic> block({
    required bool isActive,
    required DateTime start,
    required DateTime end,
    String name = 'Block',
  }) =>
      {
        'name': name,
        'isActive': isActive,
        'startDate': Timestamp.fromDate(start),
        'endDate': Timestamp.fromDate(end),
      };

  group('blocks exist but none active', () {
    late FakeFirebaseFirestore fs;
    late int templateEnsureCalls;
    late BlockRepairService service;
    final now = DateTime.now();

    setUp(() async {
      fs = FakeFirebaseFirestore();
      templateEnsureCalls = 0;
      service = BlockRepairService(
        firestore: fs,
        ensureTemplates: (_) async => templateEnsureCalls++,
      );
      // Past, current (covers today), and future block — all inactive.
      await blocksCol(fs, athleteUid).doc('past').set(block(
          isActive: false,
          start: now.subtract(const Duration(days: 400)),
          end: now.subtract(const Duration(days: 220)),
          name: 'Past'));
      await blocksCol(fs, athleteUid).doc('current').set(block(
          isActive: false,
          start: now.subtract(const Duration(days: 10)),
          end: now.add(const Duration(days: 171)),
          name: 'Current'));
      await blocksCol(fs, athleteUid).doc('future').set(block(
          isActive: false,
          start: now.add(const Duration(days: 172)),
          end: now.add(const Duration(days: 353)),
          name: 'Future'));
    });

    test('repair activates the block covering today and ensures templates',
        () async {
      final result =
          await service.ensureActiveBlockAndTemplatesForUser(athleteUid);

      expect(result.activeBlockId, 'current');
      expect(result.activatedExistingBlock, isTrue);
      expect(result.createdBlocks, isFalse);
      expect(result.templatesEnsured, isTrue);
      expect(templateEnsureCalls, 1);
      expect(await activeBlockIds(fs, athleteUid), ['current']);
    });

    test('running repair twice is a no-op the second time (idempotent)',
        () async {
      await service.ensureActiveBlockAndTemplatesForUser(athleteUid);
      final second =
          await service.ensureActiveBlockAndTemplatesForUser(athleteUid);

      expect(second.activeBlockId, 'current');
      expect(second.activatedExistingBlock, isFalse,
          reason: 'block already active — must not re-activate');
      expect(templateEnsureCalls, 1,
          reason: 'healthy second run must not re-run template ensure');
      expect(await activeBlockIds(fs, athleteUid), ['current'],
          reason: 'still exactly one active block');
    });

    test('only future blocks → earliest upcoming is activated', () async {
      await blocksCol(fs, athleteUid).doc('current').delete();
      await blocksCol(fs, athleteUid).doc('past').delete();
      await blocksCol(fs, athleteUid).doc('future2').set(block(
          isActive: false,
          start: now.add(const Duration(days: 400)),
          end: now.add(const Duration(days: 580))));

      final result =
          await service.ensureActiveBlockAndTemplatesForUser(athleteUid);
      expect(result.activeBlockId, 'future');
    });
  });

  group('user with an already-active block', () {
    test('is untouched and templates are not re-ensured by default', () async {
      final fs = FakeFirebaseFirestore();
      var templateEnsureCalls = 0;
      final now = DateTime.now();
      await blocksCol(fs, athleteUid).doc('b1').set(block(
          isActive: true,
          start: now.subtract(const Duration(days: 5)),
          end: now.add(const Duration(days: 176))));

      final service = BlockRepairService(
        firestore: fs,
        ensureTemplates: (_) async => templateEnsureCalls++,
      );
      final result =
          await service.ensureActiveBlockAndTemplatesForUser(athleteUid);

      expect(result.activeBlockId, 'b1');
      expect(result.activatedExistingBlock, isFalse);
      expect(templateEnsureCalls, 0);
      expect(await activeBlockIds(fs, athleteUid), ['b1']);
    });

    test('alwaysEnsureTemplates forces the (flag-guarded) template ensure',
        () async {
      final fs = FakeFirebaseFirestore();
      var templateEnsureCalls = 0;
      final now = DateTime.now();
      await blocksCol(fs, athleteUid).doc('b1').set(block(
          isActive: true,
          start: now,
          end: now.add(const Duration(days: 181))));

      final service = BlockRepairService(
        firestore: fs,
        ensureTemplates: (_) async => templateEnsureCalls++,
      );
      final result = await service.ensureActiveBlockAndTemplatesForUser(
          athleteUid,
          alwaysEnsureTemplates: true);

      expect(result.templatesEnsured, isTrue);
      expect(templateEnsureCalls, 1);
    });
  });

  group('user with no blocks at all', () {
    test('background call (allowCreate=false) never creates anything',
        () async {
      final fs = FakeFirebaseFirestore();
      var createCalls = 0;
      final service = BlockRepairService(
        firestore: fs,
        createBlocks: (_) async => createCalls++,
        ensureTemplates: (_) async {},
      );

      final result =
          await service.ensureActiveBlockAndTemplatesForUser(athleteUid);

      expect(result.hasActiveBlock, isFalse);
      expect(result.createdBlocks, isFalse);
      expect(createCalls, 0);
      expect((await blocksCol(fs, athleteUid).get()).docs, isEmpty);
    });

    test(
        'explicit repair (allowCreate=true) creates for the SELECTED uid and '
        'then finds the new active block', () async {
      final fs = FakeFirebaseFirestore();
      final createdForUids = <String>[];
      final service = BlockRepairService(
        firestore: fs,
        createBlocks: (uid) async {
          createdForUids.add(uid);
          // Simulate the production creation path: Block 1 active + upcoming.
          final now = DateTime.now();
          await blocksCol(fs, uid).doc('new1').set(block(
              isActive: true, start: now, end: now.add(const Duration(days: 181))));
          await blocksCol(fs, uid).doc('new2').set(block(
              isActive: false,
              start: now.add(const Duration(days: 182)),
              end: now.add(const Duration(days: 363))));
        },
        ensureTemplates: (_) async {},
      );

      final result = await service.ensureActiveBlockAndTemplatesForUser(
          athleteUid,
          allowCreate: true);

      expect(createdForUids, [athleteUid],
          reason: 'creation must target the selected athlete uid');
      expect(result.createdBlocks, isTrue);
      expect(result.activeBlockId, 'new1');
      expect(result.templatesEnsured, isTrue);
      expect(await activeBlockIds(fs, athleteUid), ['new1']);
    });
  });
}
