'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { _internals: B } = require('../scripts/backfill_week1_rir');

test('the week-1 RIR backfill defaults to a non-writing dry run', () => {
  const a = B.parseArgs([]);
  assert.equal(a.apply, false);
  assert.equal(a.projectId, 'goodlift-us-storage');
  assert.equal(B.parseArgs(['--apply', '--uid', 'u1']).apply, true);
  assert.throws(() => B.parseArgs(['--bogus']));
  assert.throws(() => B.parseArgs(['--page-size', '0']));
});

test('only users/{uid}/planned_blocks/{id} documents are ever processed', () => {
  assert.equal(B.isUserBlockPath('users/u1/planned_blocks/b1'), true);
  assert.equal(B.isUserBlockPath('planned_blocks/u1'), false);
  assert.equal(B.isUserBlockPath('planned_blocks/u1/blocks/b1'), false);
});
