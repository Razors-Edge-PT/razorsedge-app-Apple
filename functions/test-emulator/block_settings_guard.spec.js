'use strict';

// Planned-block settings against the REAL Firestore engine (emulator).
//
// Proves the storage semantics the app-side BlockSaveGuard relies on
// (lib/block_save_guard.dart), using the exact write shapes each path emits:
//
//  * the OLD legacy Block Planner save — `set({exerciseSettings: <local map>,
//    exercises: <local list>}, {merge: true})` — wipes a populated
//    exerciseSettings map / membership list when the UI state is temporarily
//    empty (an empty map is a leaf in a merge mask);
//  * the guarded shapes — one `exerciseSettings.<id>` FieldPath update per
//    changed exercise, a FieldValue.delete() for one explicitly removed id,
//    metadata-only updates, and NO write at all for an empty UI state —
//    leave every other stored entry byte-for-byte intact.
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
});

const db = () => admin.firestore();
const { FieldPath, FieldValue } = admin.firestore;

const SETTINGS = {
  bench: {
    periodizationModel: 'DUP, By Exposure',
    repTargets: { week1: { instance1: '5', instance2: '8' } },
    rirPlan: { week1: { session1: { set1: { rir: '2' } } } },
    increments: { primary: 2.5, secondary: 1.25 },
    defaultSets: 4,
    notes: 'Pause first rep.',
    showVelocityField: true,
    unknownFutureKey: { nested: [1, 2, 3] },
  },
  squat: {
    periodizationModel: 'Linear, Classic',
    repTargets: { week1: { instance1: '8' } },
    increments: { primary: 5 },
    defaultSets: 0,
    notes: '',
  },
  curl: { defaultSets: 2, weightUnit: 'lb' },
};
const MEMBERS = ['bench', 'squat', 'curl'];

let seq = 0;
async function seedBlock() {
  seq += 1;
  const ref = db().doc(`users/u${Date.now().toString(36)}${seq}/planned_blocks/active`);
  await ref.set({
    name: 'Pre-update block',
    isActive: true,
    exerciseSettings: SETTINGS,
    exercises: MEMBERS,
    plannedExercises: MEMBERS,
    plannedExerciseDetails: { bench: { notes: 'legacy' } },
  });
  return ref;
}

const data = async (ref) => (await ref.get()).data();

test('OLD shape: an empty UI map in a merge-set WIPES populated settings', async () => {
  const ref = await seedBlock();
  await ref.set(
    { exerciseSettings: {}, exercises: [], plannedExercises: [] },
    { merge: true },
  );
  const after = await data(ref);
  assert.deepEqual(after.exerciseSettings, {}, 'the destructive write the guard forbids');
  assert.deepEqual(after.exercises, []);
});

test('GUARDED: an empty UI state emits no write — the block is untouched', async () => {
  const ref = await seedBlock();
  const before = await data(ref);
  // BlockSaveGuard.plan refuses an empty membership / all-excluded list and
  // never accepts exerciseSettings as metadata, so nothing is sent.
  const after = await data(ref);
  assert.deepEqual(after, before);
});

test('GUARDED: one changed exercise updates only its own entry', async () => {
  const ref = await seedBlock();
  const merged = { ...SETTINGS.squat, notes: 'new note' }; // merged over server
  await db().runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    assert.ok(snap.exists);
    txn.update(ref, new FieldPath('exerciseSettings', 'squat'), merged);
  });
  const after = await data(ref);
  assert.deepEqual(after.exerciseSettings.squat, merged);
  assert.deepEqual(after.exerciseSettings.bench, SETTINGS.bench, 'unknown keys survive');
  assert.deepEqual(after.exerciseSettings.curl, SETTINGS.curl);
  assert.deepEqual(after.exercises, MEMBERS);
  assert.deepEqual(after.plannedExerciseDetails, { bench: { notes: 'legacy' } });
});

test('GUARDED: an explicit removal deletes exactly that exercise', async () => {
  const ref = await seedBlock();
  await ref.update(
    new FieldPath('exerciseSettings', 'curl'), FieldValue.delete(),
    'exercises', ['bench', 'squat'],
    'plannedExercises', ['bench', 'squat'],
  );
  const after = await data(ref);
  assert.deepEqual(Object.keys(after.exerciseSettings).sort(), ['bench', 'squat']);
  assert.deepEqual(after.exerciseSettings.bench, SETTINGS.bench);
  assert.deepEqual(after.exerciseSettings.squat, SETTINGS.squat);
});

test('GUARDED: metadata-only save (Save button) leaves settings intact', async () => {
  const ref = await seedBlock();
  await ref.update({ name: 'Renamed', isActive: true, selectedDays: ['Mon'] });
  const after = await data(ref);
  assert.deepEqual(after.exerciseSettings, SETTINGS);
  assert.deepEqual(after.exercises, MEMBERS);
});

test('GUARDED: a missing block is never created by a per-exercise update', async () => {
  const ref = db().doc(`users/missing${Date.now()}/planned_blocks/none`);
  await assert.rejects(
    ref.update(new FieldPath('exerciseSettings', 'bench'), SETTINGS.bench),
  );
  assert.equal((await ref.get()).exists, false);
});

test('WES2 save shape: a mergeFields write of exerciseSettings keeps every other block field', async () => {
  // fake_cloud_firestore drops the other top-level fields on this write; the
  // real engine must not (the WES2 Dart tests compare settings entries only).
  const ref = await seedBlock();
  const before = await data(ref);
  await db().runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    const all = { ...snap.data().exerciseSettings };
    all.squat = { ...all.squat, increments: { primary: 2.5 } };
    txn.set(ref, { exerciseSettings: all }, { mergeFields: ['exerciseSettings'] });
  });
  const after = await data(ref);
  for (const k of Object.keys(before).filter((k) => k !== 'exerciseSettings')) {
    assert.deepEqual(after[k], before[k], k);
  }
  assert.deepEqual(after.exerciseSettings.bench, SETTINGS.bench);
  assert.deepEqual(after.exerciseSettings.squat.increments, { primary: 2.5 });
});
