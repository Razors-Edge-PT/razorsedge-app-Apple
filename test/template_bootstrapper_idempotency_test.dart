import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/template_bootstrapper.dart';

/// Verifies the initial-template bootstrap is idempotent and block-linked:
///  - a user with an active block gets exactly one set of templates,
///  - running it again duplicates nothing (flag + existence guards),
///  - B1/B2/B3 templates point at active/upcoming block ids.
void main() {
  const uid = 'julienTestUid';

  late FakeFirebaseFirestore fs;

  Future<void> seedUser() async {
    // Male, dob 01-01-1996 (DMY) → age 30 on 2026 dates → MALE_27_39 branch.
    await fs.collection('users').doc(uid).set({
      'sex': 'M',
      'dob': '01-01-1996',
      'username': 'julien',
    });
  }

  Future<void> seedBlocks() async {
    final blocks =
        fs.collection('planned_blocks').doc(uid).collection('blocks');
    final now = DateTime.now();
    await blocks.doc('blockA').set({
      'isActive': true,
      'startDate': Timestamp.fromDate(now),
      'endDate': Timestamp.fromDate(now.add(const Duration(days: 181))),
    });
    await blocks.doc('blockB').set({
      'isActive': false,
      'startDate': Timestamp.fromDate(now.add(const Duration(days: 182))),
      'endDate': Timestamp.fromDate(now.add(const Duration(days: 363))),
    });
    await blocks.doc('blockC').set({
      'isActive': false,
      'startDate': Timestamp.fromDate(now.add(const Duration(days: 364))),
      'endDate': Timestamp.fromDate(now.add(const Duration(days: 545))),
    });
  }

  Future<QuerySnapshot<Map<String, dynamic>>> templates() =>
      fs.collection('users').doc(uid).collection('templates').get();

  setUp(() async {
    fs = FakeFirebaseFirestore();
    TemplatesBootstrapper.debugFirestore = fs;
    await seedUser();
    await seedBlocks();
  });

  tearDown(() {
    TemplatesBootstrapper.debugFirestore = null;
  });

  test('new eligible user with active block gets the full template set',
      () async {
    await TemplatesBootstrapper.ensureInitialTemplatesForUser(uid);

    final snap = await templates();
    expect(snap.size, 12, reason: '3 blocks × 4 days for the male branch');

    final userDoc = (await fs.collection('users').doc(uid).get()).data()!;
    expect(userDoc['templatesBootstrapped_v1'], isTrue);

    // Block links: B1 → active block, B2/B3 → upcoming in start-date order.
    for (final d in snap.docs) {
      final assign = d.data()['blockAssignment'] as String?;
      final blockId = d.data()['blockId'] as String?;
      switch (assign) {
        case 'B1':
          expect(blockId, 'blockA');
          break;
        case 'B2':
          expect(blockId, 'blockB');
          break;
        case 'B3':
          expect(blockId, 'blockC');
          break;
        default:
          fail('unexpected blockAssignment: $assign');
      }
    }
  });

  test('running bootstrap twice does not duplicate templates', () async {
    await TemplatesBootstrapper.ensureInitialTemplatesForUser(uid);
    await TemplatesBootstrapper.ensureInitialTemplatesForUser(uid);

    expect((await templates()).size, 12,
        reason: 'flag guard must stop the second run from re-creating');
  });

  test('bootstrap flag alone (templates already present) is respected even '
      'when the flag was lost', () async {
    await TemplatesBootstrapper.ensureInitialTemplatesForUser(uid);
    // Simulate a lost flag (e.g. partial user-doc restore).
    await fs.collection('users').doc(uid).set(
        {'templatesBootstrapped_v1': FieldValue.delete()},
        SetOptions(merge: true));

    await TemplatesBootstrapper.ensureInitialTemplatesForUser(uid);

    expect((await templates()).size, 12,
        reason: 'existing-templates guard must stop re-creation');
    final userDoc = (await fs.collection('users').doc(uid).get()).data()!;
    expect(userDoc['templatesBootstrapped_v1'], isTrue,
        reason: 'flag must be restored');
  });

  test('no active block → bootstrap aborts without setting the flag '
      '(so it can retry after repair)', () async {
    await fs
        .collection('planned_blocks')
        .doc(uid)
        .collection('blocks')
        .doc('blockA')
        .update({'isActive': false});

    await TemplatesBootstrapper.ensureInitialTemplatesForUser(uid);

    expect((await templates()).size, 0);
    final userDoc = (await fs.collection('users').doc(uid).get()).data()!;
    expect(userDoc['templatesBootstrapped_v1'], isNot(isTrue));
  });

  test('concurrent calls for the same uid run the bootstrap only once',
      () async {
    await Future.wait([
      TemplatesBootstrapper.ensureInitialTemplatesForUser(uid),
      TemplatesBootstrapper.ensureInitialTemplatesForUser(uid),
      TemplatesBootstrapper.ensureInitialTemplatesForUser(uid),
    ]);

    expect((await templates()).size, 12,
        reason: 'in-flight guard must prevent duplicate creation');
  });
}
