'use strict';

// The bodyweight normalisation boundary, pinned by shared vectors.
//
// functions/showcase/bodyweight_vectors.json is asserted here and by
// test/bodyweight_load_test.dart, so the server's showcase records and the
// app's progression history, history screens and showcase mirror normalise a
// bodyweight-loaded set identically.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const bw = require('../showcase/bodyweight');
const { buildShowcase } = require('../showcase/reducer');

const vectors = require(path.join(__dirname, '..', 'showcase', 'bodyweight_vectors.json'));

function close(actual, expected, label) {
  if (expected === null) {
    assert.equal(actual, null, label);
    return;
  }
  assert.ok(
    typeof actual === 'number' && Math.abs(actual - expected) <= 1e-9,
    `${label}: ${actual} ≠ ${expected}`,
  );
}

test('vectors cover the boundary', () => {
  assert.ok(vectors.normalize.length >= 10);
  assert.ok(vectors.pick.length >= 6);
  assert.ok(vectors.showcase.length >= 5);
});

for (const v of vectors.normalize) {
  test(`normalizeLoad: ${v.name}`, () => {
    const n = bw.normalizeLoad(v.input);
    for (const k of ['addedKg', 'totalKg', 'totalE1rm', 'addedE1rm']) close(n[k], v.expect[k], k);
    assert.deepEqual(bw.e1rmRank(n, v.input.reps), v.e1rmRank);
    assert.deepEqual(bw.heaviestRank(n), v.heaviestRank);
  });
}

for (const v of vectors.pick) {
  test(`pickBodyweightAsOf: ${v.name}`, () => {
    assert.deepEqual(bw.pickBodyweightAsOf(v.entries, v.dateKey), v.expect);
  });
}

for (const v of vectors.showcase) {
  test(`showcase: ${v.name}`, () => {
    const got = buildShowcase(v.history, { bodyweightByDate: v.bodyweightByDate }).lifts.chinUp;
    assert.deepEqual(JSON.parse(JSON.stringify(got)), v.expect);
  });
}

test('the reported example reads +61.6 from 138.5 × 3 at 85 kg', () => {
  const n = bw.normalizeLoad({ basis: 'absolute', storedKg: 138.5, reps: 3, typedAddedKg: 53.5, bodyweightKg: 85 });
  assert.equal(n.totalKg, 138.5);
  assert.equal(n.addedKg, 53.5);
  assert.equal(n.totalE1rm.toFixed(1), '146.6');
  assert.equal(n.addedE1rm.toFixed(1), '61.6');
});
