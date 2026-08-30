'use strict';

// The decision core behind identityOnPublicProfileWritten.
//
// These cover the rules that decide who keeps a contested name after a legacy
// client claim landed without going through the reservation service. The
// Firestore side of the same behaviour — the transaction, the trigger and the
// firestore.rules compatibility window — is covered against the real engines
// in test-rules/identity_authority.spec.js.

const test = require('node:test');
const assert = require('node:assert');

const {
  Reconciliation,
  planReconciliation,
  usernameVariants,
} = require('../identity/reconcile');
const { MAX_LENGTH } = require('../identity/username_rules');

// ── Variants ────────────────────────────────────────────────────────────────

test('variants are numbered and stay inside the length limit', () => {
  assert.deepStrictEqual(usernameVariants('Bench', 3), ['Bench2', 'Bench3', 'Bench4']);
  for (const v of usernameVariants('a'.repeat(MAX_LENGTH))) {
    assert.ok(v.length <= MAX_LENGTH, `${v} is ${v.length} characters`);
  }
});

test('variants are distinct', () => {
  const list = usernameVariants('Bench', 8);
  assert.strictEqual(new Set(list).size, list.length);
});

// ── No reservation yet ──────────────────────────────────────────────────────

test('a free name is claimed for the account that wrote it', () => {
  const plan = planReconciliation({
    uid: 'u1',
    storedUsername: 'BenchKing',
    reservation: null,
    freeVariants: [],
  });
  assert.strictEqual(plan.decision, Reconciliation.CLAIM);
  assert.strictEqual(plan.username, 'BenchKing');
  assert.strictEqual(plan.usernameLower, 'benchking');
});

test('an empty username is left alone', () => {
  for (const stored of ['', '   ', null, undefined]) {
    const plan = planReconciliation({
      uid: 'u1',
      storedUsername: stored,
      reservation: null,
      freeVariants: [],
    });
    assert.strictEqual(plan.decision, Reconciliation.NOOP);
    assert.strictEqual(plan.reason, 'no-username');
  }
});

// ── Already ours ────────────────────────────────────────────────────────────

test('a name already reserved to us with the same casing writes nothing', () => {
  const plan = planReconciliation({
    uid: 'u1',
    storedUsername: 'BenchKing',
    reservation: { uid: 'u1', username: 'BenchKing', usernameLower: 'benchking' },
    freeVariants: [],
  });
  assert.strictEqual(plan.decision, Reconciliation.NOOP);
  assert.strictEqual(plan.reason, 'already-ours');
});

test('a casing-only difference is corrected rather than ignored', () => {
  // The reservation is ours, so nobody else is affected — but the index must
  // still record the casing the account actually displays.
  const plan = planReconciliation({
    uid: 'u1',
    storedUsername: 'BENCHKING',
    reservation: { uid: 'u1', username: 'BenchKing', usernameLower: 'benchking' },
    freeVariants: [],
  });
  assert.strictEqual(plan.decision, Reconciliation.CLAIM);
  assert.strictEqual(plan.username, 'BENCHKING');
});

// ── Contested ───────────────────────────────────────────────────────────────

test('a name another account holds moves the claimant to a free variant', () => {
  const plan = planReconciliation({
    uid: 'u2',
    storedUsername: 'BenchKing',
    reservation: { uid: 'u1', username: 'BenchKing', usernameLower: 'benchking' },
    freeVariants: ['BenchKing3', 'BenchKing4'],
  });
  assert.strictEqual(plan.decision, Reconciliation.RENAME);
  assert.strictEqual(plan.heldBy, 'u1');
  // The FIRST free variant wins, so the outcome is deterministic.
  assert.strictEqual(plan.username, 'BenchKing3');
  assert.strictEqual(plan.usernameLower, 'benchking3');
});

test('a contested marker belongs to nobody, so every claimant loses it', () => {
  // The backfill writes { contested: true } with NO uid for a name several
  // legacy accounts already display.
  const plan = planReconciliation({
    uid: 'u2',
    storedUsername: 'BenchKing',
    reservation: { contested: true, contestedUids: ['u1', 'u2'], usernameLower: 'benchking' },
    freeVariants: ['BenchKing2'],
  });
  assert.strictEqual(plan.decision, Reconciliation.RENAME);
  assert.strictEqual(plan.username, 'BenchKing2');
});

test('with no free variant the account is left exactly as it is', () => {
  // Writing a name that is also taken would be worse than leaving the drift
  // in place for an operator to see.
  const plan = planReconciliation({
    uid: 'u2',
    storedUsername: 'BenchKing',
    reservation: { uid: 'u1', username: 'BenchKing', usernameLower: 'benchking' },
    freeVariants: [],
  });
  assert.strictEqual(plan.decision, Reconciliation.NOOP);
  assert.strictEqual(plan.reason, 'no-free-variant');
  assert.strictEqual(plan.heldBy, 'u1');
});

// ── Convergence ─────────────────────────────────────────────────────────────

test('re-running a rename plan on its own result is a no-op', () => {
  // The trigger writes users_public, so it re-fires itself. The second pass
  // must terminate, or the reconciler is an infinite loop.
  const first = planReconciliation({
    uid: 'u2',
    storedUsername: 'BenchKing',
    reservation: { uid: 'u1', username: 'BenchKing', usernameLower: 'benchking' },
    freeVariants: ['BenchKing2'],
  });
  assert.strictEqual(first.decision, Reconciliation.RENAME);

  const second = planReconciliation({
    uid: 'u2',
    storedUsername: first.username,
    reservation: {
      uid: 'u2',
      username: first.username,
      usernameLower: first.usernameLower,
    },
    freeVariants: [],
  });
  assert.strictEqual(second.decision, Reconciliation.NOOP);
  assert.strictEqual(second.reason, 'already-ours');
});

test('re-running a claim plan on its own result is a no-op', () => {
  const first = planReconciliation({
    uid: 'u1',
    storedUsername: 'BenchKing',
    reservation: null,
    freeVariants: [],
  });
  const second = planReconciliation({
    uid: 'u1',
    storedUsername: 'BenchKing',
    reservation: {
      uid: 'u1',
      username: first.username,
      usernameLower: first.usernameLower,
    },
    freeVariants: [],
  });
  assert.strictEqual(second.decision, Reconciliation.NOOP);
});
