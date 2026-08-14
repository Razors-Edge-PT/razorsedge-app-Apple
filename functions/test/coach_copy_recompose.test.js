'use strict';

// Copy-time recomposition (item 5 / final item I context): the exact
// buildDraftText used by both generateReport and the copy transaction is
// exercised here, proving that a weigh-in performed between generation and
// copy removes the stale weigh-in request deterministically, and (item M)
// that E1RM events below the rebaseline praise floor can never be praised.

const test = require('node:test');
const assert = require('node:assert/strict');

const { buildDraftText } = require('../coach/draft');

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

function e1Event(dateKey) {
  return {
    id: `${dateKey}_squat_e1rm`,
    type: 'e1rmPB',
    dateKey,
    exerciseId: 'squat',
    exerciseName: 'Back Squat, Barbell',
    e1rmKg: 160,
    prevE1rmKg: 152,
    pctImprovement: 8 / 152,
    weightKg: 140,
    reps: 4,
    formulaVersion: 1,
  };
}

const baseArgs = {
  events: [repEvent],
  completion: null,
  settings: {},
  identity: { gender: 'male', firstName: 'Tom' },
  coverageStart: '2026-08-06',
  coverageEnd: '2026-08-10',
  variantSeed: 7,
  e1rmPraiseFloorKey: null,
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

// ── Item M: formula-change rebaseline cannot create praise ─────────────────

test('rebaseline: an in-window E1RM event below the praise floor is never praised', () => {
  // Formula changed on 2026-08-09; the recompute produced an e1rm event
  // dated 2026-08-08 (inside the active window) purely from reclassified
  // history. The floor excludes it from the client draft.
  const text = buildDraftText({
    ...baseArgs,
    events: [e1Event('2026-08-08')],
    e1rmPraiseFloorKey: '2026-08-09',
    bodyweight: null,
  });
  assert.equal(text, '');
});

test('rebaseline: a genuine improvement after the floor produces exactly one E1RM praise', () => {
  const text = buildDraftText({
    ...baseArgs,
    events: [e1Event('2026-08-09')],
    e1rmPraiseFloorKey: '2026-08-09',
    bodyweight: null,
  });
  assert.ok(text.includes('new E1RM PB'));
  assert.ok(text.includes('160kg excluding RIR'));
});

test('rebaseline: rep-target praise is unaffected by the E1RM floor', () => {
  const text = buildDraftText({
    ...baseArgs,
    e1rmPraiseFloorKey: '2026-08-09', // rep event dated 08-08 still praises
    bodyweight: null,
  });
  assert.ok(text.includes('new 6 rep target PB'));
});
