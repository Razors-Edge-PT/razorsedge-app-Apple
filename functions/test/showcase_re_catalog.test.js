'use strict';

// The RE Points catalogue and arithmetic, pinned to the fixture the Dart suite
// (test/profile_re_catalog_test.dart) asserts too.

const test = require('node:test');
const assert = require('node:assert');

const fixture = require('./fixtures/re_catalog_parity.json');
const {
  RE_CATEGORIES,
  RE_EXERCISES,
  reExercisesOfCategory,
  reExerciseBySlot,
  reExerciseById,
  matchReExercise,
  LoadSemantics,
} = require('../showcase/re_catalog');
const { BIG_FIVE } = require('../showcase/big_five');
const { reCoefficient, rePoints, scoringSexOf, Sex } = require('../showcase/re_points');
const { isBodyweightSlot } = require('../showcase/bodyweight');

test('catalogue matches the shared parity fixture exactly', () => {
  const actual = RE_CATEGORIES.map((c) => ({
    key: c.key,
    displayName: c.displayName,
    exercises: reExercisesOfCategory(c.key).map((e) => ({
      slot: e.slot,
      exerciseId: e.exerciseId,
      displayName: e.displayName,
      legacyNameAliases: e.legacyNameAliases,
      factor: e.factor,
      bodyweightLoaded: e.bodyweightLoaded,
      loadSemantics: e.loadSemantics,
    })),
  }));
  assert.deepStrictEqual(actual, fixture.categories);
});

test('categories are in the agreed display order', () => {
  assert.deepStrictEqual(
    RE_CATEGORIES.map((c) => [c.key, c.displayName]),
    [
      ['horizontalPress', 'Horizontal Press'],
      ['verticalPull', 'Vertical Pull'],
      ['overheadPress', 'Overhead Press / Dip'],
      ['hipHinge', 'Hip Hinge'],
      ['squatPattern', 'Squat Pattern'],
    ],
  );
});

test('exact ids, factors and category membership', () => {
  const table = RE_EXERCISES.map((e) => [e.category, e.exerciseId, e.displayName, e.factor]);
  assert.deepStrictEqual(table, [
    ['horizontalPress', 'AmfUWbF1DH3I7qPAdh5k', 'Bench Press, Barbell', 1.0],
    ['horizontalPress', 'kTs5fLSTKjUkUZL10iii', 'Flat Bench Dumbbell Press', 2.35],
    ['verticalPull', 'XM9026peNIu0R8qh7UqY', 'Chin-Up', 1.0],
    ['verticalPull', '1XOIXxeLFhgmgjZS9Cyq', 'Lat Pull Down, Supinated', 0.85],
    ['overheadPress', 'RdsGazgdH0xgpjek0n3u', 'Overhead Dumbbell Press, Unilateral', 2.61],
    ['overheadPress', 'lVDG90yN6Z8aPjRNV2wc', 'Overhead Barbell Press', 1.53],
    ['overheadPress', 'FtayDmR5BVnGS1FXlXLL', 'Triceps Dip', 0.73],
    ['hipHinge', 'MsGl7e9yanDeEnYX0e4X', 'Deadlift, Conventional', 0.74],
    ['hipHinge', '10pEctikt6PP8eAg9Eip', 'Deadlift, Sumo', 0.74],
    ['hipHinge', 'LGhFj8o0sG3X12296UAh', 'Hip Thrust, Barbell', 0.55],
    ['squatPattern', 'heeBViVINHO6tUScSd6y', 'Back Squat, Barbell', 0.8],
    ['squatPattern', 'ISXQqOEXLjMrPEs0xjgJ', 'Bulgarian Split Squat, Dumbbell', 2.5],
    ['squatPattern', 'VUEvvjuo4cxBghNuux66', 'Bulgarian Split Squat, Barbell', 1.25],
  ]);
});

test('unilateral DB overhead press is exactly 2.61', () => {
  assert.strictEqual(reExerciseById('RdsGazgdH0xgpjek0n3u').factor, 2.61);
});

test('conventional and sumo deadlift both use 0.74', () => {
  assert.strictEqual(reExerciseById('MsGl7e9yanDeEnYX0e4X').factor, 0.74);
  assert.strictEqual(reExerciseById('10pEctikt6PP8eAg9Eip').factor, 0.74);
});

test('Lat Pull Down, Supinated uses 0.85 and lives only in Vertical Pull', () => {
  const lat = reExerciseById('1XOIXxeLFhgmgjZS9Cyq');
  assert.strictEqual(lat.factor, 0.85);
  assert.strictEqual(lat.category, 'verticalPull');
  assert.strictEqual(RE_EXERCISES.filter((e) => e.exerciseId === lat.exerciseId).length, 1);
  assert.ok(!reExercisesOfCategory('squatPattern').some((e) => e.exerciseId === lat.exerciseId));
});

test('slots and ids are unique; every exercise belongs to a known category', () => {
  const slots = RE_EXERCISES.map((e) => e.slot);
  const ids = RE_EXERCISES.map((e) => e.exerciseId.toLowerCase());
  assert.strictEqual(new Set(slots).size, slots.length);
  assert.strictEqual(new Set(ids).size, ids.length);
  const cats = new Set(RE_CATEGORIES.map((c) => c.key));
  for (const e of RE_EXERCISES) assert.ok(cats.has(e.category), e.slot);
});

test('the five V1 lifts keep their V1 slot keys and ids (stable fingerprints)', () => {
  for (const lift of BIG_FIVE) {
    const def = reExerciseBySlot(lift.slot);
    assert.ok(def, lift.slot);
    assert.strictEqual(def.exerciseId, lift.exerciseId);
    assert.strictEqual(def.displayName, lift.displayName);
    assert.strictEqual(!!def.bodyweightLoaded, !!lift.bodyweightLoaded);
  }
});

test('bodyweight-loaded flag is definition-driven: Chin-Up and Triceps Dip only', () => {
  const bw = RE_EXERCISES.filter((e) => e.bodyweightLoaded).map((e) => e.slot);
  assert.deepStrictEqual(bw, ['chinUp', 'tricepsDip']);
  assert.strictEqual(isBodyweightSlot('chinUp'), true);
  assert.strictEqual(isBodyweightSlot('tricepsDip'), true);
  for (const e of RE_EXERCISES.filter((x) => !x.bodyweightLoaded)) {
    assert.strictEqual(isBodyweightSlot(e.slot), false, e.slot);
  }
  assert.strictEqual(reExerciseBySlot('tricepsDip').loadSemantics, LoadSemantics.BODYWEIGHT_PLUS_ADDED);
});

test('per-dumbbell exercises are declared as such', () => {
  const per = RE_EXERCISES.filter((e) => e.loadSemantics === LoadSemantics.PER_DUMBBELL)
    .map((e) => e.slot);
  assert.deepStrictEqual(per, ['dbBenchFlat', 'ohpUnilateral', 'bulgarianSplitSquatDumbbell']);
  assert.strictEqual(reExerciseBySlot('bulgarianSplitSquatBarbell').loadSemantics, LoadSemantics.TOTAL);
});

test('matching: case-folded ids decide; a present unknown id is never rescued', () => {
  assert.strictEqual(matchReExercise('10pectikt6pp8eag9eip', 'x').slot, 'deadliftSumo');
  assert.strictEqual(matchReExercise('  FtayDmR5BVnGS1FXlXLL ', null).slot, 'tricepsDip');
  // A real id for some other exercise, named like a catalogue exercise.
  assert.strictEqual(matchReExercise('t66qeWQqnuEtaoyZqRp0', 'Triceps Dip'), null);
  assert.strictEqual(matchReExercise('RFyjAjezFs8Rf7CQoaXz', 'Chin-Up'), null);
});

test('matching: id-less legacy rows use the closed exact alias list only', () => {
  assert.strictEqual(matchReExercise(null, 'Sumo Deadlift').slot, 'deadliftSumo');
  assert.strictEqual(matchReExercise('', 'bulgarian split squat').slot, 'bulgarianSplitSquatDumbbell');
  assert.strictEqual(matchReExercise(undefined, 'Triceps Dip').slot, 'tricepsDip');
  for (const name of [
    'Triceps Dip Machine',
    'Bulgarian Split Squat, Deficit',
    'Overhead Dumbbell Press',
    'Pull-Up',
    'Lat Pull Down, Wide Arm',
    'Incline Bench Dumbbell Press',
    'Hip Thrust, Unilateral',
  ]) {
    assert.strictEqual(matchReExercise(null, name), null, name);
  }
});

test('coefficient matches the shared vectors (port of lib/formula.dart)', () => {
  for (const v of fixture.coefficients) {
    const got = reCoefficient(v.sex, v.bodyweightKg);
    assert.ok(Math.abs(got - v.coefficient) <= 1e-12 * Math.abs(v.coefficient), JSON.stringify(v));
  }
});

test('points match the shared vectors; missing bodyweight is null, not zero', () => {
  for (const v of fixture.points) {
    assert.strictEqual(rePoints(v), v.rePoints, JSON.stringify(v));
  }
  assert.strictEqual(rePoints({ e1rmKg: 100, factor: 1, bodyweightKg: null, sex: Sex.MALE }), null);
  assert.strictEqual(rePoints({ e1rmKg: 100, factor: 1, bodyweightKg: 0, sex: Sex.MALE }), null);
  assert.strictEqual(rePoints({ e1rmKg: 0, factor: 1, bodyweightKg: 80, sex: Sex.MALE }), null);
});

test('points = E1RM × factor × coefficient, rounded to 4 dp', () => {
  const c = reCoefficient(Sex.MALE, 85);
  assert.strictEqual(
    rePoints({ e1rmKg: 40, factor: 2.61, bodyweightKg: 85, sex: Sex.MALE }),
    Number((40 * 2.61 * c).toFixed(4)),
  );
});

test('sex handling preserves the production rule: F is female, anything else male', () => {
  assert.strictEqual(scoringSexOf('F'), Sex.FEMALE);
  assert.strictEqual(scoringSexOf(' f '), Sex.FEMALE);
  assert.strictEqual(scoringSexOf('M'), Sex.MALE);
  assert.strictEqual(scoringSexOf('N'), Sex.MALE);
  assert.strictEqual(scoringSexOf(null), Sex.MALE);
  assert.strictEqual(scoringSexOf(undefined), Sex.MALE);
});
