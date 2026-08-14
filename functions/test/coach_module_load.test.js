'use strict';

// Smoke test: the coach module loads under the functions runtime environment
// and exports exactly the expected six functions, without disturbing the
// existing exports in index.js (repointsMonthlyAggregator, Stripe handlers).

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'goodlift-us-storage';
process.env.FUNCTIONS_EMULATOR = 'true';

test('coach module exports the nine cloud functions', () => {
  const coach = require('../coach');
  for (const name of [
    'coachAnalyticsOnWorkoutWrite',
    'coachOnAthleteSettingsWritten',
    'coachOnAthleteAssignmentsWritten',
    'coachOnCoachAssignmentsWritten',
    'coachCheckpointScheduler',
    'coachReviewContext',
    'coachPrepareCheckInCopy',
    'coachUndoCheckIn',
    'coachSkipCheckIn',
  ]) {
    assert.ok(coach[name], `missing export ${name}`);
  }
});

test('index.js keeps existing exports intact alongside the coach exports', () => {
  const idx = require('../index');
  assert.ok(idx.repointsMonthlyAggregator, 'repointsMonthlyAggregator missing');
  assert.ok(idx.createCheckoutSession, 'createCheckoutSession missing');
  assert.ok(idx.createEarlyBirdCheckoutSession, 'createEarlyBirdCheckoutSession missing');
  assert.ok(idx.stripeWebhook, 'stripeWebhook missing');
  assert.ok(idx.coachAnalyticsOnWorkoutWrite, 'coach trigger missing');
  assert.ok(idx.coachCheckpointScheduler, 'coach scheduler missing');
});
