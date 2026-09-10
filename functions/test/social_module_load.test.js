'use strict';

// Smoke test: the social modules load under the functions runtime environment
// and export the callables and triggers index.js wires up, without disturbing
// the exports that were already there.
//
// This is the only coverage buddies.js gets outside the emulator — it is
// Firestore transactions end to end — so it is what catches a syntax error, a
// bad require path or a renamed export before a deploy does.

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'goodlift-us-storage';
process.env.FUNCTIONS_EMULATOR = 'true';

test('social modules export their cloud functions', () => {
  const buddies = require('../social/buddies');
  for (const name of [
    'buddySendRequest',
    'buddyRespondToRequest',
    'buddyCancelRequest',
    'buddyRemoveFriend',
  ]) {
    assert.ok(buddies[name], `missing export ${name}`);
  }

  const feed = require('../social/feed');
  assert.ok(feed.feedOnPostWritten, 'feedOnPostWritten missing');
  assert.ok(feed.feedOnBuddyAssignmentWritten, 'feedOnBuddyAssignmentWritten missing');

  const searchIndex = require('../social/search_index');
  assert.ok(
    searchIndex.searchIndexOnPublicProfileWritten,
    'searchIndexOnPublicProfileWritten missing',
  );
});

test('index.js exposes the social functions alongside the existing ones', () => {
  const idx = require('../index');
  for (const name of [
    'buddySendRequest',
    'buddyRespondToRequest',
    'buddyCancelRequest',
    'buddyRemoveFriend',
    'feedOnPostWritten',
    'feedOnBuddyAssignmentWritten',
    'searchIndexOnPublicProfileWritten',
  ]) {
    assert.ok(idx[name], `missing export ${name}`);
  }
  // The pre-existing surface is untouched.
  assert.ok(idx.repointsMonthlyAggregator, 'repointsMonthlyAggregator missing');
  assert.ok(idx.stripeWebhook, 'stripeWebhook missing');
  assert.ok(idx.storyOnPublished, 'storyOnPublished missing');
  assert.ok(idx.identityOnPublicProfileWritten, 'identity reconciler missing');
  assert.ok(idx.coachModeGrantCoach, 'coach mode callable missing');
});

test('the social search index does not share a trigger with the reconciler', () => {
  // Both watch users_public. They are separate exports on purpose: the
  // reconciler WRITES users_public on the rename path, and folding the index
  // into it would make one function's convergence argument depend on the
  // other's.
  const idx = require('../index');
  assert.notEqual(
    idx.searchIndexOnPublicProfileWritten,
    idx.identityOnPublicProfileWritten,
  );
});
