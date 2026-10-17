// Edit Training Preferences (drawer / Templates) for an established member,
// exercised through the shared writers the screen calls in edit mode.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/onboarding_identity_payload.dart';
import 'package:localtest222/signup/first_block_seeder.dart';
import 'package:localtest222/signup/onboarding_models.dart';
import 'package:localtest222/signup/onboarding_writer.dart';

void main() {
  const uid = 'member_1';
  late FakeFirebaseFirestore db;
  final created = Timestamp.fromDate(DateTime(2025, 3, 4));

  setUp(() async {
    db = FakeFirebaseFirestore();
    await db.doc('users/$uid').set({
      'username': 'Lifter',
      'usernameLower': 'lifter',
      'fullName': 'Lee Lifter',
      'createdAt': created,
      'sex': 'M',
      'dob': '01-02-1990',
    });
    await db.doc('users/$uid/profile/fitness_onboarding').set({
      'painNow': {'Neck': 6, 'Knees': 3},
      'injuries': ['Neck', 'Knees'],
    });
    await db.doc('users/$uid/planned_blocks/blockA').set({'name': 'A', 'isActive': true});
    await db.doc('users/$uid/block_planner/current_block').set({'blockId': 'blockA'});
  });

  test('the edit payload never carries username or createdAt', () {
    final payload = {
      'email': 'lee@example.test',
      ...buildIdentityPayloadFields(sex: 'M', dob: '01-02-1990'),
      ...buildCreatedAtField(isNewAccount: false),
    };
    expect(payload.keys, isNot(contains('username')));
    expect(payload.keys, isNot(contains('usernameLower')));
    expect(payload.keys, isNot(contains('createdAt')));
    expect(payload['dob'], '01-02-1990');
  });

  test('saving preferences keeps identity and createdAt, replaces answers',
      () async {
    final form = OnboardingFormData()
      ..injuries.add('Knees')
      ..painSlider['Knees'] = 4
      ..experience = TrainingExperience.twoPlus
      ..env = 'commercial'
      ..equipSelected.addAll(['Hack Squat'])
      ..minTrainingDays = 3;
    await db.doc('users/$uid').set({
      ...buildIdentityPayloadFields(sex: 'M', dob: '01-02-1990'),
      ...buildCreatedAtField(isNewAccount: false),
    }, SetOptions(merge: true));

    await writeFitnessOnboarding(db, uid, OnboardingSubmission.fromForm(form));

    final user = (await db.doc('users/$uid').get()).data()!;
    expect(user['username'], 'Lifter');
    expect(user['usernameLower'], 'lifter');
    expect(user['fullName'], 'Lee Lifter');
    expect(user['createdAt'], created);
    expect(user['weeklyFrequency'], 3);
    final onb = (await db.doc('users/$uid/profile/fitness_onboarding').get()).data()!;
    expect(onb['painNow'], {'Knees': 4}, reason: 'deselected Neck cleared');
    expect(onb['experience'], 'twoPlus');
    expect(onb['environment'], 'commercial');
  });

  test('an established member gets no new blocks and keeps the pointer',
      () async {
    final seeded = <String>[];
    final seeder = FirstBlockSeeder(
      firestore: db,
      seedDefaults: ({required uid, required blockId, required exerciseIds}) async =>
          seeded.add(blockId),
      scaffold: (ref, start, {startWeek = 0}) async {},
    );

    await seeder.ensureForEditMode(uid, authFallbackName: 'Lifter');

    final blocks = await db.collection('users/$uid/planned_blocks').get();
    expect(blocks.docs.map((d) => d.id), ['blockA']);
    expect((await db.doc('users/$uid/block_planner/current_block').get()).data(),
        {'blockId': 'blockA'});
    expect(seeded, isEmpty);
  });

  test('a submission is a deep copy: later edits do not change it', () {
    final form = OnboardingFormData()..injuries.add('Knees');
    final submission = OnboardingSubmission.fromForm(form);
    form.injuries.add('Neck');
    form.childFocusLevel['Back'] = {'Lats': 2};
    expect(submission.form.injuries, {'Knees'});
    expect(submission.bodyFocusChildren, isEmpty);
  });
}
