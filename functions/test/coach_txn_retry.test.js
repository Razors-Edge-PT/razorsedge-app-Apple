'use strict';

// Transient-contention retry around the copy/undo/skip transactions.
// Concurrent Copy calls (double-tap, two devices) previously surfaced
// "INVALID_ARGUMENT: Transaction is invalid or closed" ~15% of the time under
// contention; these transactions are idempotent, so re-running the whole
// transaction is safe and returns the correct answer instead of an error.

const test = require('node:test');
const assert = require('node:assert/strict');

const { isTransientTxnError, withTxnRetry, TxnError } = require('../coach/checkin_txns');

function grpcErr(code, message) {
  const e = new Error(message || `code ${code}`);
  e.code = code;
  return e;
}

test('classifier: contention/availability codes are transient', () => {
  assert.equal(isTransientTxnError(grpcErr(10, 'ABORTED')), true);
  assert.equal(isTransientTxnError(grpcErr(4, 'DEADLINE_EXCEEDED')), true);
  assert.equal(isTransientTxnError(grpcErr(14, 'UNAVAILABLE')), true);
});

test('classifier: the observed contended-transaction INVALID_ARGUMENT is transient', () => {
  assert.equal(
    isTransientTxnError(grpcErr(3, '3 INVALID_ARGUMENT: Transaction is invalid or closed.')),
    true);
});

test('classifier: genuine INVALID_ARGUMENT and other errors are NOT transient', () => {
  assert.equal(isTransientTxnError(grpcErr(3, 'INVALID_ARGUMENT: bad field path')), false);
  assert.equal(isTransientTxnError(grpcErr(7, 'PERMISSION_DENIED')), false);
  assert.equal(isTransientTxnError(grpcErr(5, 'NOT_FOUND')), false);
  assert.equal(isTransientTxnError(new Error('boom')), false);
  assert.equal(isTransientTxnError(null), false);
});

test('retry: a transient failure is retried and the later result returned', async () => {
  let calls = 0;
  const result = await withTxnRetry(async () => {
    calls += 1;
    if (calls < 3) throw grpcErr(3, 'Transaction is invalid or closed');
    return { ok: true, calls };
  });
  assert.deepEqual(result, { ok: true, calls: 3 });
});

test('retry: business-rule TxnError is never retried', async () => {
  let calls = 0;
  await assert.rejects(
    () => withTxnRetry(async () => {
      calls += 1;
      throw new TxnError('failed-precondition', 'A newer check-in was already finalised.');
    }),
    (err) => err instanceof TxnError && /newer check-in/.test(err.message));
  assert.equal(calls, 1); // exactly one attempt — no retry storm on a real rejection
});

test('retry: non-transient errors propagate immediately', async () => {
  let calls = 0;
  await assert.rejects(
    () => withTxnRetry(async () => {
      calls += 1;
      throw grpcErr(7, 'PERMISSION_DENIED');
    }),
    (err) => err.code === 7);
  assert.equal(calls, 1);
});

test('retry: gives up after the attempt budget and rethrows the last error', async () => {
  let calls = 0;
  await assert.rejects(
    () => withTxnRetry(async () => {
      calls += 1;
      throw grpcErr(10, 'ABORTED');
    }, 3),
    (err) => err.code === 10);
  assert.equal(calls, 3);
});
