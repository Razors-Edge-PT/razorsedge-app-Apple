'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const authz = require('../coach/authz');

function evaluate(coachAssignData, athleteAssignData) {
  return authz.evaluateAssignment({
    coachAssignData, athleteAssignData,
    coachUid: 'coachA', athleteUid: 'ath1',
  });
}

// Matrix from stabilisation item A.

test('authz: approved athleteAssignments entry grants access', () => {
  assert.equal(evaluate(null, { coaches: { coachA: { approved: true } } }), true);
});

test('authz: admin-seeded coachAssignments entry grants access', () => {
  assert.equal(evaluate({ athletes: { ath1: { email: 'a@b.c' } } }, null), true);
  // Seeded entries may be any non-null shape (the app writes {email}).
  assert.equal(evaluate({ athletes: { ath1: {} } }, null), true);
});

test('authz: pending/unapproved athleteAssignments entry does NOT grant access', () => {
  assert.equal(evaluate(null, { coaches: { coachA: {} } }), false);
  assert.equal(evaluate(null, { coaches: { coachA: { status: 'pending' } } }), false);
});

test('authz: explicitly false approval does NOT grant access', () => {
  assert.equal(evaluate(null, { coaches: { coachA: { approved: false } } }), false);
});

test('authz: missing relationship does NOT grant access', () => {
  assert.equal(evaluate(null, null), false);
  assert.equal(evaluate({ athletes: {} }, { coaches: {} }), false);
  assert.equal(evaluate({ athletes: { other: {} } }, { coaches: { otherCoach: { approved: true } } }), false);
});

test('authz: malformed relationships do NOT grant access', () => {
  assert.equal(evaluate(null, { coaches: { coachA: true } }), false);        // boolean, not object
  assert.equal(evaluate(null, { coaches: { coachA: 'approved' } }), false);  // string
  assert.equal(evaluate(null, { coaches: { coachA: { approved: 'true' } } }), false); // string true
  assert.equal(evaluate(null, { coaches: { coachA: { approved: 1 } } }), false);      // truthy non-bool
  assert.equal(evaluate({ athletes: { ath1: null } }, null), false);         // explicit null seeded
});

test('authz: removed relationship revokes; one remaining valid source preserves', () => {
  // Both sources present → authorised.
  assert.equal(evaluate(
    { athletes: { ath1: {} } },
    { coaches: { coachA: { approved: true } } }), true);
  // Seeded removed, approval remains → still authorised.
  assert.equal(evaluate(
    { athletes: {} },
    { coaches: { coachA: { approved: true } } }), true);
  // Approval flipped false, seeded remains → still authorised.
  assert.equal(evaluate(
    { athletes: { ath1: {} } },
    { coaches: { coachA: { approved: false } } }), true);
  // Both removed → revoked.
  assert.equal(evaluate({ athletes: {} }, { coaches: {} }), false);
});
