'use strict';

const test = require('node:test');
const assert = require('node:assert');

const {
  parseArgs,
  excludedMedalUids,
} = require('../scripts/remove_excluded_leaderboard_accounts');

test('cleanup arguments are dry-run by default and reject conflicting modes', () => {
  assert.deepStrictEqual(parseArgs([]), {
    projectId: 'goodlift-us-storage',
    apply: false,
    verify: false,
    help: false,
  });
  assert.throws(
    () => parseArgs(['--apply', '--verify']),
    /Choose either --apply or --verify/,
  );
  assert.throws(() => parseArgs(['--uid', 'someone']), /Unknown argument/);
});

test('medal verification finds excluded UIDs in any category only once', () => {
  const targets = new Set(['excluded-a', 'excluded-b']);
  const snapshot = {
    categories: {
      horizontalPress: [
        { uid: 'real-athlete' },
        { uid: 'excluded-a' },
      ],
      verticalPull: [
        { uid: 'excluded-b' },
        { uid: 'excluded-a' },
      ],
    },
  };
  assert.deepStrictEqual(
    excludedMedalUids(snapshot, targets),
    ['excluded-a', 'excluded-b'],
  );
});
