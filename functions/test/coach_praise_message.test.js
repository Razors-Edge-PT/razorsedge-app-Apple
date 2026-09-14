'use strict';

// Factual achievement lists and un-addressed bodyweight lines — the client
// draft composition shared by report generation, draft refresh and copy.

const test = require('node:test');
const assert = require('node:assert/strict');

const { selectAchievements } = require('../coach/praise');
const { deriveExerciseEvents, summarizeWorkoutDay } = require('../coach/pb_engine');
const { coachE1rm } = require('../coach/e1rm');
const { buildDraftText } = require('../coach/draft');
const msg = require('../coach/message');

const DAY = '2026-09-10';

function repEv(exerciseId, name, reps, weightKg, prevWeightKg, dateKey = DAY) {
  return {
    id: `${dateKey}_${exerciseId}_rep${reps}`,
    type: 'repPB', dateKey, exerciseId, exerciseName: name, reps, weightKg,
    prevWeightKg, pctImprovement: (weightKg - prevWeightKg) / prevWeightKg,
  };
}
function e1Ev(exerciseId, name, weightKg, reps, prevE1rmKg, dateKey = DAY) {
  const e1rmKg = coachE1rm(weightKg, reps);
  return {
    id: `${dateKey}_${exerciseId}_e1rm`,
    type: 'e1rmPB', dateKey, exerciseId, exerciseName: name, e1rmKg, prevE1rmKg,
    pctImprovement: (e1rmKg - prevE1rmKg) / prevE1rmKg, weightKg, reps,
  };
}
function maxEv(exerciseId, name, weightKg, reps, prevWeightKg, dateKey = DAY) {
  return {
    id: `${dateKey}_${exerciseId}_maxweight`,
    type: 'maxWeightPB', dateKey, exerciseId, exerciseName: name, weightKg, reps,
    prevWeightKg, pctImprovement: (weightKg - prevWeightKg) / prevWeightKg,
  };
}
const kg1 = (v) => `${Math.round(v * 10) / 10}kg`;

function draft(events, extra = {}) {
  return buildDraftText({
    events,
    settings: {},
    bodyweight: null,
    coverageStart: '2026-09-07',
    coverageEnd: '2026-09-14',
    variantSeed: 7,
    e1rmPraiseFloorKey: null,
    ...extra,
  });
}

const GREETING_OR_FILLER = /\b(hey|hi|heya|bro|man|nice work hitting|great stuff|huge|excluding RIR|keep it up|awesome|congrat\w*|well done|all your workouts)\b/i;
const EMOJI = /\p{Extended_Pictographic}/u;

// ── Line shapes ─────────────────────────────────────────────────────────────

test('line: rep-target PB is load, reps and exercise only', () => {
  assert.equal(draft([repEv('bp', 'Bench Press, Barbell', 8, 150, 145)]),
    '• 150kg for 8 reps on the bench press');
});

test('line: same performance rep PB + E1RM PB is ONE line with the computed E1RM appended', () => {
  const text = draft([
    repEv('bp', 'Bench Press, Barbell', 8, 150, 145),
    e1Ev('bp', 'Bench Press, Barbell', 150, 8, 180),
  ]);
  assert.equal(text, `• 150kg for 8 reps on the bench press, New E1RM PB of ${kg1(coachE1rm(150, 8))}`);
  assert.equal(text.split('\n').length, 1);
});

test('line: E1RM-only PB names its own contributing set', () => {
  const text = draft([e1Ev('bp', 'Bench Press, Barbell', 140, 10, 180)]);
  assert.equal(text, `• 140kg for 10 reps on the bench press, New E1RM PB of ${kg1(coachE1rm(140, 10))}`);
});

test('line: an E1RM from a DIFFERENT set on the same exercise/day is never attached', () => {
  // Same exercise, same day — but the E1RM came from 120 x 12, not 150 x 8.
  const text = draft([
    repEv('bp', 'Bench Press, Barbell', 8, 150, 145),
    e1Ev('bp', 'Bench Press, Barbell', 120, 12, 150),
  ]);
  const lines = text.split('\n');
  assert.deepEqual(lines, [
    '• 150kg for 8 reps on the bench press',
    `• 120kg for 12 reps on the bench press, New E1RM PB of ${kg1(coachE1rm(120, 12))}`,
  ]);
});

test('line: an E1RM from another exercise is never attached', () => {
  const lines = draft([
    repEv('bp', 'Bench Press, Barbell', 8, 150, 145),
    e1Ev('lp', 'Bench Press, Larsen Press', 150, 8, 150),
  ]).split('\n');
  assert.equal(lines.length, 2);
  assert.equal(lines[0], '• 150kg for 8 reps on the bench press');
  assert.match(lines[1], /^• 150kg for 8 reps on the Larsen bench press, New E1RM PB of /);
});

test('line: all-time heaviest + rep target + E1RM on one set stays one line', () => {
  const text = draft([
    maxEv('dl', 'Deadlift, Conventional', 200, 3, 195),
    repEv('dl', 'Deadlift, Conventional', 3, 200, 190),
    e1Ev('dl', 'Deadlift, Conventional', 200, 3, 205),
  ]);
  assert.equal(text,
    `• 200kg for 3 reps on the deadlift, all-time heaviest, New E1RM PB of ${kg1(coachE1rm(200, 3))}`);
});

test('line: RIR match is a factual comparison, never a new PB', () => {
  const text = draft([{
    type: 'rirMatchPB', dateKey: DAY, exerciseId: 'mcp', exerciseName: 'Machine Chest Press',
    weightKg: 25, reps: 15, rir: 2, prevRir: 1.5,
  }]);
  assert.equal(text, '• 25kg for 15 reps on the Machine Chest Press, matched PB at RIR 2 (previously RIR 1.5)');
  assert.doesNotMatch(text, /New/);
});

test('line: 1 rep is singular; decimals kept; legacy E1RM without a set still states the value', () => {
  assert.equal(draft([repEv('bp', 'Bench Press, Barbell', 1, 102.5, 100)]),
    '• 102.5kg for 1 rep on the bench press');
  const legacy = { ...e1Ev('bp', 'Bench Press, Barbell', 140, 10, 170) };
  delete legacy.weightKg;
  delete legacy.reps;
  assert.equal(draft([legacy]), `• New E1RM PB of ${kg1(coachE1rm(140, 10))} on the bench press`);
});

test('line: bodyweight exercises show the added load; E1RM keeps the added-load convention', () => {
  const bw = 80;
  const rep = { ...repEv('cu', 'Chin-Up', 5, 100, 95), bodyweightKg: bw };
  const e1 = { ...e1Ev('cu', 'Chin-Up', 100, 5, 110), bodyweightKg: bw };
  const text = draft([rep, e1]);
  assert.equal(text, `• +20kg for 5 reps on the Chin-Up, New E1RM PB of +${kg1(coachE1rm(100, 5) - bw)}`);
  assert.equal(draft([{ ...repEv('cu', 'Chin-Up', 8, 80, 78), bodyweightKg: bw }]),
    '• bodyweight for 8 reps on the Chin-Up');
});

// ── Selection ───────────────────────────────────────────────────────────────

test('selection: more than three achievements are ALL listed, in deterministic order', () => {
  const events = [
    repEv('a', 'Bench Press, Barbell', 6, 102.5, 100),
    repEv('b', 'Back Squat, Barbell', 5, 145, 137.5),
    repEv('c', 'Lat Pull Down, Supinated', 3, 130, 120),
    repEv('d', 'Romanian Deadlift', 8, 101, 100),
    e1Ev('e', 'Seated Row, Cable', 70, 10, 80),
  ];
  const lines = draft(events).split('\n');
  assert.equal(lines.length, 5);
  assert.deepEqual(lines.map((l) => l.replace(/^• [^ ]+ for \d+ reps? on the /, '').split(',')[0]), [
    'supinated lat pull', 'squat', 'bench press', 'RDL', 'Seated Row',
  ]);
  assert.equal(draft([...events].reverse()), draft(events));
});

test('selection: a dominated set from the same session is not listed again', () => {
  const items = selectAchievements({
    repEvents: [
      repEv('bp', 'Bench Press, Barbell', 8, 150, 145),
      repEv('bp', 'Bench Press, Barbell', 6, 145, 140), // same session, beaten by 150 x 8
      repEv('bp', 'Bench Press, Barbell', 10, 140, 135), // more reps: distinct
    ],
  });
  // 140x10 improved 3.7 % and 150x8 3.4 %, so 140x10 ranks first.
  assert.deepEqual(items.map((i) => `${i.weightKg}x${i.reps}`), ['140x10', '150x8']);
});

test('selection: the same lift on two different days is two achievements', () => {
  const items = selectAchievements({
    repEvents: [
      repEv('bp', 'Bench Press, Barbell', 8, 150, 145, '2026-09-08'),
      repEv('bp', 'Bench Press, Barbell', 8, 152.5, 150, '2026-09-11'),
    ],
  });
  assert.equal(items.length, 2);
});

test('selection: custom exercise mode filters by stable id (catalog casing tolerated)', () => {
  const events = [
    { ...repEv('bench_id', 'Bench Press, Barbell', 8, 150, 145), catalogExerciseId: 'Bench_ID' },
    repEv('larsen_id', 'Bench Press, Larsen Press', 4, 125, 120),
  ];
  const text = draft(events, {
    settings: { messageExerciseMode: 'custom', customExerciseIds: ['Bench_ID'] },
  });
  assert.equal(text, '• 150kg for 8 reps on the bench press');
  assert.equal(draft(events, { settings: { messageExerciseMode: 'custom', customExerciseIds: [] } }), '');
});

test('selection: nothing qualifying → empty draft, nothing fabricated', () => {
  assert.equal(draft([]), '');
});

// ── Exact exercise identity ─────────────────────────────────────────────────

test('identity: comma qualifiers are never truncated (regression: cleanExerciseName)', () => {
  assert.equal(msg.cleanExerciseName('Seated Row, Cable'), 'Seated Row, Cable');
  assert.equal(msg.cleanExerciseName('Bench Press, Larsen Press'), 'Bench Press, Larsen Press');
  assert.equal(msg.exerciseLabel('Incline Bench Press, Dumbbell, Neutral Grip'),
    'Incline Bench Press, Dumbbell, Neutral Grip');
  assert.equal(msg.exerciseLabel('Bench Press, Larsen Press'), 'Larsen bench press');
  assert.equal(msg.exerciseLabel('Bench Press, Barbell'), 'bench press');
  assert.equal(msg.exerciseLabel('  Romanian Deadlift '), 'RDL');
});

test('identity: Larsen vs barbell bench, and cable vs machine seated rows, stay distinct in one recap', () => {
  const text = draft([
    repEv('bb', 'Bench Press, Barbell', 8, 150, 145),
    repEv('lp', 'Bench Press, Larsen Press', 4, 125, 120),
    repEv('rc', 'Seated Row, Cable', 10, 80, 75),
    repEv('rm', 'Seated Row, Machine', 10, 90, 85),
  ]);
  const lines = text.split('\n');
  assert.equal(lines.length, 4);
  assert.ok(lines.includes('• 150kg for 8 reps on the bench press'));
  assert.ok(lines.includes('• 125kg for 4 reps on the Larsen bench press'));
  assert.ok(lines.includes('• 80kg for 10 reps on the Seated Row, Cable'));
  assert.ok(lines.includes('• 90kg for 10 reps on the Seated Row, Machine'));
});

test('identity: two different exercises that would share an alias fall back to full names', () => {
  const text = draft([
    repEv('bb', 'Bench Press, Barbell', 8, 150, 145),
    repEv('custom', 'bench press', 8, 60, 55),
  ]);
  assert.ok(text.includes('on the Bench Press, Barbell'));
  assert.ok(text.includes('on the bench press'));
  assert.notEqual(text.split('\n')[0].split(' on the ')[1], text.split('\n')[1].split(' on the ')[1]);
});

test('identity: two ids of the same name in one day are separate streams (distinct ids)', () => {
  const day = summarizeWorkoutDay({
    exercises: [
      { exerciseId: 'LARSEN1', name: 'Bench Press, Larsen Press', sets: [{ weight: 125, reps: 4 }] },
      { exerciseId: 'BARBELL1', name: 'Bench Press, Barbell', sets: [{ weight: 150, reps: 8 }] },
    ],
  });
  assert.equal(day.larsen1.name, 'Bench Press, Larsen Press');
  assert.equal(day.barbell1.name, 'Bench Press, Barbell');
});

// ── Production PB path → lines ──────────────────────────────────────────────

test('production path: engine events for the same set merge; the E1RM is the engine value', () => {
  const { events } = deriveExerciseEvents('bp', {
    '2026-09-01': summarizeWorkoutDay({ exercises: [{ exerciseId: 'bp', name: 'Bench Press, Barbell',
      sets: [{ weight: 145, reps: 8 }] }] }).bp,
    [DAY]: summarizeWorkoutDay({ exercises: [{ exerciseId: 'bp', name: 'Bench Press, Barbell',
      sets: [{ weight: 150, reps: 8, rir: 1 }, { weight: 120, reps: 5 }] }] }).bp,
  });
  const text = draft(events);
  assert.equal(text,
    `• 150kg for 8 reps on the bench press, all-time heaviest, New E1RM PB of ${kg1(coachE1rm(150, 8))}`);
});

// ── No greetings / filler anywhere ──────────────────────────────────────────

const BW = (extra) => ({ goal: 'cut', trend: 'insufficient', weighInStatus: 'ok', newMilestoneId: null, ...extra });

test('weigh-in only: the exact reminder, no addressing', () => {
  assert.equal(draft([], { bodyweight: BW({ weighInStatus: 'overdue' }) }),
    'Can I get you to weigh in please?');
  assert.equal(draft([], { bodyweight: BW({ weighInStatus: 'due' }) }),
    'Can I get you to weigh in please?');
});

test('trend only: cutting on track uses the requested wording', () => {
  assert.equal(draft([], { bodyweight: BW({ trend: 'onTrack' }) }),
    'Nice work on the diet, weight coming down');
});

test('goal wording: bulking gain is never a weight-loss message; off-track asks about the diet', () => {
  const bulk = draft([], { bodyweight: BW({ goal: 'bulk', trend: 'onTrack' }) });
  assert.equal(bulk, 'Nice work on the diet, weight going up');
  assert.doesNotMatch(bulk, /down/);
  for (let seed = 0; seed < 12; seed++) {
    const cutOff = draft([], { variantSeed: seed, bodyweight: BW({ trend: 'offTrack' }) });
    assert.match(cutOff, /diet/);
    assert.doesNotMatch(cutOff, /Nice work/);
    const bulkOff = draft([], { variantSeed: seed, bodyweight: BW({ goal: 'bulk', trend: 'offTrack' }) });
    assert.doesNotMatch(bulkOff, /coming down|going down at the moment, how/);
  }
  assert.equal(draft([], { bodyweight: BW({ goal: 'maintain', trend: 'stable' }) }), 'Body weight holding stable');
  assert.match(draft([], { bodyweight: BW({ goal: 'maintain', trend: 'driftUp' }) }), /creeping up/);
  assert.match(draft([], { bodyweight: BW({ goal: 'maintain', trend: 'driftDown' }) }), /dipping/);
});

test('milestones: cut and bulk milestones stay goal-gated, maintain gets none', () => {
  assert.equal(draft([], { bodyweight: BW({ trend: 'onTrack', newMilestoneId: 'cut_110' }) }),
    'Nice work on the diet, weight coming down\nUnder 110kg now, great milestone');
  assert.match(draft([], { bodyweight: BW({ goal: 'bulk', trend: 'onTrack', newMilestoneId: 'bulk_90' }) }),
    /Reached the 90kg mark, great milestone/);
  assert.equal(msg.milestoneSentence('maintain', 'cut_110'), null);
});

test('combined: bullets first, bodyweight separate, one reminder only', () => {
  const text = draft([repEv('bp', 'Bench Press, Barbell', 8, 150, 145)], {
    bodyweight: BW({ trend: 'onTrack', weighInStatus: 'overdue' }),
  });
  assert.equal(text, [
    '• 150kg for 8 reps on the bench press',
    '',
    'Nice work on the diet, weight coming down',
    'Can I get you to weigh in please?',
  ].join('\n'));
  assert.equal(text.match(/weigh in/g).length, 1);
});

test('no greeting, name, emoji or filler in any branch', () => {
  const pb = [repEv('bp', 'Bench Press, Barbell', 8, 150, 145), e1Ev('bp', 'Bench Press, Barbell', 150, 8, 180)];
  const cases = [];
  for (const goal of ['cut', 'bulk', 'maintain']) {
    for (const trend of ['onTrack', 'offTrack', 'stable', 'driftUp', 'driftDown', 'insufficient']) {
      for (const weighInStatus of ['ok', 'due', 'overdue']) {
        for (const events of [[], pb]) {
          cases.push(draft(events, { bodyweight: { goal, trend, weighInStatus, newMilestoneId: `${goal}_100` } }));
        }
      }
    }
  }
  for (const text of cases) {
    assert.doesNotMatch(text, GREETING_OR_FILLER, text);
    assert.doesNotMatch(text, EMOJI, text);
    assert.doesNotMatch(text, /Tom|Sarah/);
  }
});

test('null / insufficient data: nothing to say returns an empty draft', () => {
  assert.equal(draft([], { bodyweight: null }), '');
  assert.equal(draft([], { bodyweight: BW({}) }), '');
  assert.equal(msg.composeDraft({ achievements: [], bodyweight: null, variantSeed: 1 }), null);
});
