'use strict';

// Copy-time recomposition: the exact buildDraftText used by generateReport,
// the existing-draft refresh and the copy transaction is exercised here,
// proving that a weigh-in performed between generation and copy removes the
// stale weigh-in request deterministically, and that E1RM events below the
// rebaseline floor can never be listed.

const test = require('node:test');
const assert = require('node:assert/strict');

const { buildDraftText, computePraisedWeekKey, COMPOSITION_VERSION } = require('../coach/draft');

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
  assert.equal(generated, '• 102.5kg for 6 reps on the bench press\n\nCan I get you to weigh in please?');
});

test('copy recompose: after the athlete weighs in, the live recheck drops the request', () => {
  const finalText = buildDraftText({
    ...baseArgs,
    bodyweight: {
      goal: 'cut', trend: 'onTrack', weighInStatus: 'ok',
      currentAvg: 100.8, previousAvg: 101.8, newMilestoneId: null,
    },
  });
  assert.equal(finalText, '• 102.5kg for 6 reps on the bench press\n\nNice work on the diet, weight coming down');
});

test('copy recompose: composition is deterministic — same inputs, same finalText', () => {
  const args = {
    ...baseArgs,
    bodyweight: { goal: 'cut', trend: 'onTrack', weighInStatus: 'ok', newMilestoneId: null },
  };
  assert.equal(buildDraftText(args), buildDraftText(args));
});

test('copy recompose: identity and completion never change the text (no names, no congratulations)', () => {
  const plain = buildDraftText({ ...baseArgs, bodyweight: null });
  const withAll = buildDraftText({
    ...baseArgs,
    identity: { gender: 'female', firstName: 'Sarah' },
    completion: { weekKey: '2026-08-03', completedAll: true, completedCount: 4, plannedCount: 4 },
    bodyweight: null,
  });
  assert.equal(withAll, plain);
});

test('copy recompose: custom lift filters apply at copy time', () => {
  const text = buildDraftText({
    ...baseArgs,
    settings: { messageExerciseMode: 'custom', customExerciseIds: ['other'] },
    completion: { weekKey: '2026-08-03', completedAll: true, completedCount: 3, plannedCount: 3 },
    bodyweight: null,
  });
  assert.equal(text, ''); // bench filtered out; attendance is not a message
});

test('copy recompose: no consistency praise is recorded because none is emitted', () => {
  const report = {
    events: [repEvent],
    completion: { weekKey: '2026-08-03', completedAll: true, completedCount: 4, plannedCount: 4 },
  };
  assert.equal(computePraisedWeekKey(report, {}, { start: '2026-08-06', end: '2026-08-10' }), null);
  assert.ok(COMPOSITION_VERSION >= 2);
});

// ── E1RM formula-change rebaseline cannot create a PB line ─────────────────

test('rebaseline: an in-window E1RM event below the floor is never listed', () => {
  const text = buildDraftText({
    ...baseArgs,
    events: [e1Event('2026-08-08')],
    e1rmPraiseFloorKey: '2026-08-09',
    bodyweight: null,
  });
  assert.equal(text, '');
});

test('rebaseline: a genuine improvement after the floor produces exactly one E1RM line', () => {
  const text = buildDraftText({
    ...baseArgs,
    events: [e1Event('2026-08-09')],
    e1rmPraiseFloorKey: '2026-08-09',
    bodyweight: null,
  });
  assert.equal(text, '• 140kg for 4 reps on the squat, New E1RM PB of 160kg');
});

test('rebaseline: rep-target lines are unaffected by the E1RM floor', () => {
  const text = buildDraftText({
    ...baseArgs,
    e1rmPraiseFloorKey: '2026-08-09', // rep event dated 08-08 still listed
    bodyweight: null,
  });
  assert.equal(text, '• 102.5kg for 6 reps on the bench press');
});

test('rebaseline: a floored E1RM is not appended to a rep line of the same set', () => {
  const sameSetE1 = {
    ...e1Event('2026-08-08'), exerciseId: 'bench', exerciseName: 'Bench Press, Barbell',
    weightKg: 102.5, reps: 6,
  };
  const text = buildDraftText({
    ...baseArgs,
    events: [repEvent, sameSetE1],
    e1rmPraiseFloorKey: '2026-08-09',
    bodyweight: null,
  });
  assert.equal(text, '• 102.5kg for 6 reps on the bench press');
});
