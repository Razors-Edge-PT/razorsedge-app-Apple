'use strict';

// Copy-time recomposition (stabilisation item 5): the exact buildDraftText
// used by both generateReport and coachPrepareCheckInCopy is exercised here,
// proving that a weigh-in performed between generation and copy removes the
// stale weigh-in request from the final text, deterministically.
//
// The callable returns this text verbatim; the Flutter screen copies that
// exact string to the clipboard and the transaction stores the same string
// as finalText — so displayed text == clipboard text == server finalText by
// construction (single string, single source).

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'goodlift-us-storage';
process.env.FUNCTIONS_EMULATOR = 'true';

const { buildDraftText } = require('../coach/index');

const repEvent = {
  id: '2026-08-08_bench_rep6',
  type: 'repPB',
  dateKey: '2026-08-08',
  exerciseId: 'bench',
  exerciseName: 'Bench Press, Barbell',
  reps: 6,
  weightKg: 102.5,
  prevWeightKg: 100,
  pctImprovement: 0.025,
};

const baseArgs = {
  events: [repEvent],
  completion: null,
  settings: {},
  identity: { gender: 'male', firstName: 'Tom' },
  coverageStart: '2026-08-06',
  coverageEnd: '2026-08-10',
  variantSeed: 7,
};

test('copy recompose: stale weigh-in request present at generation time', () => {
  const generated = buildDraftText({
    ...baseArgs,
    bodyweight: {
      goal: 'cut', trend: 'insufficient', weighInStatus: 'overdue',
      currentAvg: null, previousAvg: null, newMilestoneId: null,
    },
  });
  assert.ok(generated.includes('could I get you to weigh in today'));
  assert.ok(generated.includes('new 6 rep target PB'));
});

test('copy recompose: after the athlete weighs in, the live recheck drops the request', () => {
  const finalText = buildDraftText({
    ...baseArgs,
    bodyweight: {
      goal: 'cut', trend: 'onTrack', weighInStatus: 'ok',
      currentAvg: 100.8, previousAvg: 101.8, newMilestoneId: null,
    },
  });
  assert.ok(!finalText.includes('weigh in today'));
  assert.ok(finalText.includes('slowly coming down'));
  // Training portion is unchanged (frozen achievements, same seed → same greeting/alias).
  assert.ok(finalText.includes('new 6 rep target PB'));
});

test('copy recompose: composition is deterministic — same inputs, same finalText', () => {
  const args = {
    ...baseArgs,
    bodyweight: { goal: 'cut', trend: 'onTrack', weighInStatus: 'ok', newMilestoneId: null },
  };
  assert.equal(buildDraftText(args), buildDraftText(args));
});

test('copy recompose: praised weeks and custom lift filters apply at copy time', () => {
  // A completion already praised by a previous copy must not re-enter, and
  // custom mode must drop non-selected lifts from the client draft.
  const text = buildDraftText({
    ...baseArgs,
    settings: {
      messageExerciseMode: 'custom',
      customExerciseIds: ['other'],
      praisedWeeks: { '2026-08-03': 'earlierReport' },
    },
    completion: {
      weekKey: '2026-08-03', completedAll: true, completedCount: 3, plannedCount: 3,
    },
    bodyweight: null,
  });
  assert.equal(text, ''); // bench filtered out, week already praised → nothing
});
