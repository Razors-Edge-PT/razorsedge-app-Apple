'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { selectPraise } = require('../coach/praise');
const msg = require('../coach/message');

function repEv(exerciseId, name, reps, weightKg, prevWeightKg, dateKey = '2026-08-12') {
  return {
    id: `${dateKey}_${exerciseId}_rep${reps}`,
    type: 'repPB', dateKey, exerciseId, exerciseName: name, reps, weightKg,
    prevWeightKg, pctImprovement: (weightKg - prevWeightKg) / prevWeightKg,
  };
}
function e1Ev(exerciseId, name, e1rmKg, prevE1rmKg, dateKey = '2026-08-12') {
  return {
    id: `${dateKey}_${exerciseId}_e1rm`,
    type: 'e1rmPB', dateKey, exerciseId, exerciseName: name, e1rmKg, prevE1rmKg,
    pctImprovement: (e1rmKg - prevE1rmKg) / prevE1rmKg, weightKg: 0, reps: 0,
  };
}

// ── Selection & ranking ─────────────────────────────────────────────────────

test('praise: three rep PBs fill all three slots ranked by % improvement', () => {
  const { praises } = selectPraise({
    repEvents: [
      repEv('a', 'Bench Press, Barbell', 6, 102.5, 100),   // 2.5 %
      repEv('b', 'Back Squat, Barbell', 5, 145, 137.5),    // 5.45 %
      repEv('c', 'Lat Pull Down, Supinated', 3, 130, 120), // 8.3 %
      repEv('d', 'Romanian Deadlift', 8, 101, 100),        // 1 %
    ],
    e1rmEvents: [], completion: null, allowedExerciseIds: null,
  });
  assert.equal(praises.length, 3);
  assert.deepEqual(praises.map((p) => p.event.exerciseId), ['c', 'b', 'a']);
});

test('praise: 2 rep + 1 e1rm and 1 rep + 2 e1rm keep priority order', () => {
  const two = selectPraise({
    repEvents: [repEv('a', 'A', 5, 105, 100), repEv('b', 'B', 5, 110, 100)],
    e1rmEvents: [e1Ev('c', 'C', 150, 140)],
    completion: null, allowedExerciseIds: null,
  });
  assert.deepEqual(two.praises.map((p) => p.kind), ['repPB', 'repPB', 'e1rmPB']);

  const one = selectPraise({
    repEvents: [repEv('a', 'A', 5, 105, 100)],
    e1rmEvents: [e1Ev('c', 'C', 150, 140), e1Ev('d', 'D', 160, 150)],
    completion: null, allowedExerciseIds: null,
  });
  assert.deepEqual(one.praises.map((p) => p.kind), ['repPB', 'e1rmPB', 'e1rmPB']);
});

test('praise: PB plus completed-all → PB first, completion afterwards', () => {
  const { praises } = selectPraise({
    repEvents: [repEv('a', 'A', 5, 105, 100)],
    e1rmEvents: [],
    completion: { completedAll: true, count: 3, planned: 3, weekAlreadyPraised: false },
    allowedExerciseIds: null,
  });
  assert.deepEqual(praises.map((p) => p.kind), ['repPB', 'completedAll']);
});

test('praise: completed-all outranks (and suppresses) 3+ workouts', () => {
  const { praises, usedCompletion } = selectPraise({
    repEvents: [], e1rmEvents: [],
    completion: { completedAll: true, count: 4, planned: 4, weekAlreadyPraised: false },
    allowedExerciseIds: null,
  });
  assert.equal(praises.length, 1);
  assert.equal(praises[0].kind, 'completedAll');
  assert.equal(usedCompletion, 'all');
});

test('praise: 3+ workouts used when not all planned were completed', () => {
  const { praises } = selectPraise({
    repEvents: [], e1rmEvents: [],
    completion: { completedAll: false, count: 3, planned: 4, weekAlreadyPraised: false },
    allowedExerciseIds: null,
  });
  assert.deepEqual(praises.map((p) => p.kind), ['threePlus']);
});

test('praise: nothing qualifying → no fabricated achievements', () => {
  const { praises } = selectPraise({
    repEvents: [], e1rmEvents: [],
    completion: { completedAll: false, count: 2, planned: 4, weekAlreadyPraised: false },
    allowedExerciseIds: null,
  });
  assert.equal(praises.length, 0);
});

test('praise: already-praised week is not praised again', () => {
  const { praises } = selectPraise({
    repEvents: [], e1rmEvents: [],
    completion: { completedAll: true, count: 3, planned: 3, weekAlreadyPraised: true },
    allowedExerciseIds: null,
  });
  assert.equal(praises.length, 0);
});

test('praise: same lift/day rep + e1rm PB consumes ONE slot with alsoE1rm attached', () => {
  const { praises } = selectPraise({
    repEvents: [repEv('a', 'Bench Press, Barbell', 5, 105, 100)],
    e1rmEvents: [e1Ev('a', 'Bench Press, Barbell', 118, 112.5)],
    completion: null, allowedExerciseIds: null,
  });
  assert.equal(praises.length, 1);
  assert.equal(praises[0].kind, 'repPB');
  assert.ok(praises[0].alsoE1rm);
});

test('praise: custom exercise selection filters the client draft only', () => {
  const { praises } = selectPraise({
    repEvents: [repEv('a', 'A', 5, 105, 100), repEv('b', 'B', 5, 120, 100)],
    e1rmEvents: [e1Ev('c', 'C', 150, 140)],
    completion: null,
    allowedExerciseIds: ['a'],
  });
  assert.equal(praises.length, 1);
  assert.equal(praises[0].event.exerciseId, 'a');
});

// ── Aliases / greetings ─────────────────────────────────────────────────────

test('alias: known table entries and conservative fallback', () => {
  assert.equal(msg.exerciseAlias('Back Squat, Barbell', 1), 'squat');
  assert.equal(msg.exerciseAlias('Romanian Deadlift', 1), 'RDL');
  assert.equal(msg.exerciseAlias('Bulgarian Split Squat', 1), 'BG split squat');
  // fallback: comma qualifier dropped, nothing else invented
  assert.equal(msg.exerciseAlias('Seated Row, Cable', 1), 'Seated Row');
});

test('alias: bench variant is stable for a given seed', () => {
  const a = msg.exerciseAlias('Bench Press, Barbell', 42);
  const b = msg.exerciseAlias('Bench Press, Barbell', 42);
  assert.equal(a, b);
  assert.ok(['bench', 'bench press'].includes(a));
});

test('greeting: male random-but-persisted, female by first name, neutral fallback', () => {
  const g1 = msg.greeting('male', 'Tom', 7);
  assert.equal(g1, msg.greeting('male', 'Tom', 7)); // stable per seed
  assert.ok(['Hey bro', 'Hey man'].includes(g1));
  assert.equal(msg.greeting('female', 'Sarah', 7), 'Hi Sarah');
  assert.equal(msg.weighInGreeting('female', 'Sarah', 7), 'Heya Sarah');
  assert.equal(msg.greeting(null, 'Alex', 7), 'Hi Alex'); // no gender guess
});

// ── Composition ─────────────────────────────────────────────────────────────

test('compose: rep PB + positive cut becomes one combined two-paragraph draft', () => {
  const { praises } = selectPraise({
    repEvents: [repEv('a', 'Bench Press, Barbell', 6, 102.5, 100)],
    e1rmEvents: [], completion: null, allowedExerciseIds: null,
  });
  const text = msg.composeDraft({
    praises,
    bodyweight: { goal: 'cut', trend: 'onTrack', weighInStatus: 'ok', newMilestoneId: null },
    gender: 'male', firstName: 'Tom', variantSeed: 7,
  });
  assert.ok(/^Hey (bro|man), nice work hitting 102\.5kg for 6 on the bench/.test(text));
  assert.ok(text.includes('new 6 rep target PB 💪'));
  assert.ok(text.includes('slowly coming down, keep it up 👍'));
});

test('compose: struggling cutter asks about the diet, never congratulates', () => {
  const text = msg.composeDraft({
    praises: [],
    bodyweight: { goal: 'cut', trend: 'offTrack', weighInStatus: 'ok', newMilestoneId: null },
    gender: 'male', firstName: 'Tom', variantSeed: 3,
  });
  assert.ok(/diet/i.test(text));
  assert.ok(!text.includes('keep it up'));
});

test('compose: maintainer inside band gets stable wording', () => {
  const text = msg.composeDraft({
    praises: [],
    bodyweight: { goal: 'maintain', trend: 'stable', weighInStatus: 'ok', newMilestoneId: null },
    gender: 'female', firstName: 'Sarah', variantSeed: 3,
  });
  assert.ok(text.includes('stable'));
  assert.ok(text.startsWith('Hi Sarah'));
});

test('compose: stale weigh-in with nothing else → standalone weigh-in prompt', () => {
  const text = msg.composeDraft({
    praises: [],
    bodyweight: { goal: 'cut', trend: 'insufficient', weighInStatus: 'overdue', newMilestoneId: null },
    gender: 'female', firstName: 'Sarah', variantSeed: 3,
  });
  assert.equal(text, 'Heya Sarah, could I get you to weigh in today please?');
});

test('compose: completion-only message avoids misleading date wording', () => {
  const { praises } = selectPraise({
    repEvents: [], e1rmEvents: [],
    completion: { completedAll: true, count: 3, planned: 3, weekAlreadyPraised: false },
    allowedExerciseIds: null,
  });
  const text = msg.composeDraft({
    praises, bodyweight: null, gender: 'male', firstName: 'Tom', variantSeed: 9,
  });
  assert.ok(text.includes('nice work getting all your workouts in 👍'));
  assert.ok(!/last week/i.test(text));
});

test('compose: nothing to say returns null (no fabricated praise)', () => {
  const text = msg.composeDraft({
    praises: [], bodyweight: { goal: 'cut', trend: 'insufficient', weighInStatus: 'ok' },
    gender: 'male', firstName: 'Tom', variantSeed: 9,
  });
  assert.equal(text, null);
});

test('compose: bulker milestone sentence appended after trend line', () => {
  const text = msg.composeDraft({
    praises: [],
    bodyweight: { goal: 'bulk', trend: 'onTrack', weighInStatus: 'ok', newMilestoneId: 'bulk_90' },
    gender: 'male', firstName: 'Tom', variantSeed: 9,
  });
  assert.ok(text.includes('slowly going up'));
  assert.ok(text.includes('90kg mark'));
});
