'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const compat = require('../planned_blocks_compat')._internals;

test('planned-blocks path mapping removes the legacy uid/blocks layer', () => {
  assert.equal(
    compat.canonicalDocumentPath('athlete-1', 'block-1'),
    'users/athlete-1/planned_blocks/block-1',
  );
  assert.equal(
    compat.canonicalDocumentPath(
      'athlete-1',
      'block-1/weeks/week_2/days/day_4',
    ),
    'users/athlete-1/planned_blocks/block-1/weeks/week_2/days/day_4',
  );
  assert.equal(
    compat.legacyDocumentPath(
      'athlete-1',
      'block-1/block_data/2026-08-27',
    ),
    'planned_blocks/athlete-1/blocks/block-1/block_data/2026-08-27',
  );
});

test('planned-blocks path mapping rejects collection and malformed paths', () => {
  assert.throws(
    () => compat.canonicalDocumentPath('athlete-1', 'block-1/weeks'),
    /Invalid planned-blocks relative document path/,
  );
  assert.throws(
    () => compat.canonicalDocumentPath('athlete/1', 'block-1'),
    /Invalid planned-blocks mirror userId/,
  );
});

test('mirror writes the complete document to its mapped destination', async () => {
  const calls = [];
  const firestore = {
    doc(path) {
      return {
        async set(data, options) { calls.push(['set', path, data, options]); },
        async delete() { calls.push(['delete', path]); },
      };
    },
  };
  const data = { name: 'Strength block', selectedDays: ['Monday'] };

  await compat.mirrorChange({
    id: 'event-1',
    params: { userId: 'athlete-1', document: 'block-1' },
    data: { after: { exists: true, data: () => data } },
  }, compat.canonicalDocumentPath, firestore);

  assert.deepEqual(calls, [[
    'set',
    'users/athlete-1/planned_blocks/block-1',
    data,
    { merge: false },
  ]]);
});

test('mirror propagates deletions', async () => {
  const calls = [];
  const firestore = {
    doc(path) {
      return {
        async set() { calls.push(['set', path]); },
        async delete() { calls.push(['delete', path]); },
      };
    },
  };

  await compat.mirrorChange({
    id: 'event-2',
    params: {
      userId: 'athlete-1',
      document: 'block-1/weeks/week_0/days/day_1',
    },
    data: { after: { exists: false } },
  }, compat.legacyDocumentPath, firestore);

  assert.deepEqual(calls, [[
    'delete',
    'planned_blocks/athlete-1/blocks/block-1/weeks/week_0/days/day_1',
  ]]);
});
