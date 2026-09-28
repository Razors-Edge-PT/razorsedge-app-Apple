'use strict';

// Pins the backfill's week-1 RIR rule to the app's canonical Dart rule
// (BlockExerciseDefaultsRepository.healWeek1RirPlan) via shared vectors that
// test/week1_rir_heal_parity_test.dart asserts against the Dart code, and
// covers the extra safety the backfill adds (ambiguous → no fill).

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { planWeek1RirFill, applyFills } = require('../scripts/week1_rir_fill');

const vectors = JSON.parse(fs.readFileSync(
  path.join(__dirname, 'fixtures', 'week1_rir_fill_vectors.json'), 'utf8'));

for (const [name, { input, expected }] of Object.entries(vectors)) {
  test(`parity with the Dart heal: ${name}`, () => {
    const plan = planWeek1RirFill(input);
    assert.notEqual(plan.status, 'ambiguous', plan.reasons.join('; '));
    assert.deepEqual(applyFills(input, plan.fills), expected);
    // Idempotent: the filled result needs nothing more.
    const again = planWeek1RirFill(expected);
    assert.deepEqual(again.fills, []);
  });
}

test('fills are only additions: every original leaf survives unchanged', () => {
  const leaves = (o, p = []) => (o && typeof o === 'object' && !Array.isArray(o)
    ? Object.entries(o).flatMap(([k, v]) => leaves(v, [...p, k]))
    : [[p.join('.'), JSON.stringify(o)]]);
  for (const { input } of Object.values(vectors)) {
    const out = applyFills(input, planWeek1RirFill(input).fills);
    const after = new Map(leaves(out));
    for (const [k, v] of leaves(input)) assert.equal(after.get(k), v, k);
  }
});

test('intentional blanks and zeroes are never overwritten', () => {
  const input = vectors.intentional_blank_and_zero_kept.input;
  const plan = planWeek1RirFill(input);
  assert.equal(plan.status, 'complete');
  assert.deepEqual(plan.fills, []);
});

test('set 3/4 are created only when the planned set count requires them', () => {
  const two = planWeek1RirFill({
    defaultSets: 2,
    repTargets: { week1: { instance1: '8' } },
    rirPlan: { week1: { session1: { set1: { rir: '2', reps: '8' } } } },
  });
  assert.deepEqual(two.fills.map((f) => f.path.join('.')),
    ['rirPlan.week1.session1.set2']);
  const four = planWeek1RirFill({
    defaultSets: 2,
    repTargets: { week1: { instance1: '8 x 4' } },
  });
  assert.deepEqual(four.fills.map((f) => f.path.at(-1)),
    ['set1', 'set2', 'set3', 'set4']);
});

test('ambiguous records are reported and never filled', () => {
  const cases = {
    'defaultSets absent': { repTargets: { week1: { instance1: '8' } } },
    'defaultSets not an integer': { defaultSets: 3.5, repTargets: { week1: { instance1: '8' } } },
    'non-contiguous instances': { defaultSets: 2, repTargets: { week1: { instance1: '8', instance3: '6' } } },
    'rirPlan not a map': { defaultSets: 2, repTargets: { week1: { instance1: '8' } }, rirPlan: 'x' },
    'session not a map': { defaultSets: 2, repTargets: { week1: { instance1: '8' } }, rirPlan: { week1: { session1: [] } } },
    'set explicitly null': { defaultSets: 1, repTargets: { week1: { instance1: '8' } }, rirPlan: { week1: { session1: { set1: null } } } },
  };
  for (const [name, input] of Object.entries(cases)) {
    const plan = planWeek1RirFill(input);
    assert.equal(plan.status, 'ambiguous', name);
    assert.deepEqual(plan.fills, [], name);
    assert.ok(plan.reasons.length > 0, name);
  }
});

test('no week-1 rep-target instances (e.g. DUP, Signature) is not applicable', () => {
  const plan = planWeek1RirFill({
    defaultSets: 3, repTargets: { min: '6', max: '12' },
  });
  assert.equal(plan.status, 'not-applicable');
  assert.deepEqual(plan.fills, []);
});
