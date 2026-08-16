'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { coachE1rm, E1RM_FORMULA_VERSION } = require('../coach/e1rm');
const { summarizeWorkoutDay, deriveExerciseEvents } = require('../coach/pb_engine');

// ── E1RM formula ────────────────────────────────────────────────────────────

test('e1rm: 1 rep returns the weight itself', () => {
  assert.equal(coachE1rm(100, 1), 100);
});

test('e1rm: <=25 reps uses Brzycki', () => {
  // 100 x 5 → 100 * 36 / 32 = 112.5
  assert.ok(Math.abs(coachE1rm(100, 5) - 112.5) < 1e-9);
  // 100 x 10 → 100 * 36 / 27 = 133.333… (pinned identically in the Dart suite)
  assert.ok(Math.abs(coachE1rm(100, 10) - 100 * 36 / 27) < 1e-9);
  // boundary: 25 reps still Brzycki → 100 * 36 / 12 = 300
  assert.ok(Math.abs(coachE1rm(100, 25) - 300) < 1e-9);
});

test('e1rm: >25 reps uses Epley (1 + 0.0333 r)', () => {
  // 100 x 26 → 100 * (1 + 0.0333*26) = 186.58
  assert.ok(Math.abs(coachE1rm(100, 26) - 186.58) < 1e-9);
});

test('e1rm: invalid weight/reps return 0', () => {
  assert.equal(coachE1rm(0, 5), 0);
  assert.equal(coachE1rm(-10, 5), 0);
  assert.equal(coachE1rm(100, 0), 0);
  assert.equal(coachE1rm(null, 5), 0);
  assert.equal(coachE1rm(100, undefined), 0);
  assert.equal(coachE1rm(NaN, 5), 0);
});

test('e1rm: formula version exported and versioned', () => {
  assert.equal(E1RM_FORMULA_VERSION, 1);
});

// ── Day summary ─────────────────────────────────────────────────────────────

function workout(exs) {
  return { exercises: exs };
}
function ex(id, name, sets) {
  return { exerciseId: id, name, sets };
}

test('summary: best weight per exact rep count within a day', () => {
  const s = summarizeWorkoutDay(workout([
    ex('bench', 'Bench Press, Barbell', [
      { weight: 100, reps: 5 },
      { weight: 102.5, reps: 5 },
      { weight: 105, reps: 5 },
      { weight: 95, reps: 8 },
    ]),
  ]));
  assert.equal(s.bench.bestByReps['5'], 105);
  assert.equal(s.bench.bestByReps['8'], 95);
});

test('summary: RIR present is ignored, not disqualifying', () => {
  const s = summarizeWorkoutDay(workout([
    ex('bench', 'Bench', [{ weight: 100, reps: 5, rir: 2.5 }]),
  ]));
  assert.equal(s.bench.bestByReps['5'], 100);
  // E1RM uses weight+reps only: 100x5 → 112.5 regardless of rir
  assert.ok(Math.abs(s.bench.bestE1rm - 112.5) < 1e-9);
});

test('summary: invalid/missing weight or reps sets are ignored', () => {
  const s = summarizeWorkoutDay(workout([
    ex('bench', 'Bench', [
      { weight: 0, reps: 5 },
      { weight: 100, reps: 0 },
      { weight: null, reps: 5 },
      { reps: 5 },
      { weight: 100 },
    ]),
  ]));
  assert.equal(s.bench, undefined);
});

test('summary: rows without any exercise id are skipped', () => {
  const s = summarizeWorkoutDay(workout([
    { name: 'Mystery', sets: [{ weight: 100, reps: 5 }] },
  ]));
  assert.deepEqual(s, {});
});

test('summary: legacy id and legacy actualWeight/actualReps fields work', () => {
  const s = summarizeWorkoutDay(workout([
    { id: 'squat', name: 'Back Squat, Barbell', sets: [{ actualWeight: 140, actualReps: 3 }] },
  ]));
  assert.equal(s.squat.bestByReps['3'], 140);
});

test('summary: wesPlannedExercises are not treated as results', () => {
  const s = summarizeWorkoutDay({
    exercises: [],
    wesPlannedExercises: [ex('bench', 'Bench', [{ weight: 100, reps: 5 }])],
  });
  assert.deepEqual(s, {});
});

// ── Event derivation ────────────────────────────────────────────────────────

function day(bestByReps, e1rmSet, name = 'Bench Press, Barbell') {
  const entry = { name, bestByReps: bestByReps || {}, bestE1rm: 0, bestE1rmSet: null };
  if (e1rmSet) {
    entry.bestE1rm = coachE1rm(e1rmSet.weight, e1rmSet.reps);
    entry.bestE1rmSet = e1rmSet;
  }
  return entry;
}

test('events: first-ever result is baseline, not a PB', () => {
  const { events, repBest, e1rmBest } = deriveExerciseEvents('bench', {
    '2026-01-05': day({ 5: 100 }, { weight: 100, reps: 5 }),
  });
  assert.equal(events.length, 0);
  assert.equal(repBest['5'].weightKg, 100);
  assert.ok(e1rmBest);
});

test('events: strictly higher weight at same reps is a PB; equal or lower is not', () => {
  const { events } = deriveExerciseEvents('bench', {
    '2026-01-05': day({ 5: 100 }),
    '2026-01-12': day({ 5: 102.5 }),   // PB
    '2026-01-19': day({ 5: 102.5 }),   // equal → no PB
    '2026-01-26': day({ 5: 100 }),     // lower → no PB
  });
  const repEvents = events.filter((e) => e.type === 'repPB');
  assert.equal(repEvents.length, 1);
  assert.equal(repEvents[0].dateKey, '2026-01-12');
  assert.equal(repEvents[0].weightKg, 102.5);
  assert.equal(repEvents[0].prevWeightKg, 100);
});

// Rep counts are NOT independent streams: a rep target is judged against every
// prior set that reached AT LEAST that many reps. (The pre-v3 engine bucketed
// each exact rep count separately, which is what published Aja's dominated
// 25kg x 14 as a "new 14 rep target PB" on 2026-08-13.)
test('events: a rep target is judged against all prior sets at >= that many reps', () => {
  const { events, repBest } = deriveExerciseEvents('bench', {
    '2026-01-05': day({ 6: 100 }),
    '2026-01-12': day({ 5: 105 }),     // 105 beats the 100 done for 6 → 5-rep PB
    '2026-01-19': day({ 6: 102.5 }),   // 102.5 beats the 100 done for 6 → 6-rep PB
  });
  const repEvents = events.filter((e) => e.type === 'repPB');
  assert.equal(repEvents.length, 2);
  assert.deepEqual(repEvents.map((e) => e.reps), [5, 6]);
  assert.equal(repEvents[0].prevWeightKg, 100); // compared against the 6-rep set
  assert.equal(repBest['5'].weightKg, 105);
});

test('events: several same-rep improvements in one workout produce one event at the day best', () => {
  // 100x5 baseline earlier; then 102.5 and 105 in one session → day best 105
  const { events } = deriveExerciseEvents('bench', {
    '2026-01-05': day({ 5: 100 }),
    '2026-01-12': day({ 5: 105 }), // summarize already collapsed to day best
  });
  const repEvents = events.filter((e) => e.type === 'repPB');
  assert.equal(repEvents.length, 1);
  assert.equal(repEvents[0].weightKg, 105);
});

test('events: e1rm baseline then improvement; strongest set of the day wins', () => {
  const { events } = deriveExerciseEvents('bench', {
    '2026-01-05': day({ 5: 100 }, { weight: 100, reps: 5 }),  // e1rm 112.5 baseline
    '2026-01-12': day({ 3: 110 }, { weight: 110, reps: 3 }),  // e1rm 116.47 → PB
  });
  const e1 = events.filter((e) => e.type === 'e1rmPB');
  assert.equal(e1.length, 1);
  assert.equal(e1[0].dateKey, '2026-01-12');
  assert.ok(e1[0].e1rmKg > e1[0].prevE1rmKg);
  assert.equal(e1[0].formulaVersion, E1RM_FORMULA_VERSION);
});

test('events: deterministic ids and full recompute reproduce identical stream', () => {
  const history = {
    '2026-01-05': day({ 5: 100 }, { weight: 100, reps: 5 }),
    '2026-01-12': day({ 5: 102.5 }, { weight: 102.5, reps: 5 }),
  };
  const a = deriveExerciseEvents('bench', history);
  const b = deriveExerciseEvents('bench', history);
  assert.deepEqual(a, b);
  // 102.5 beats every prior weight, so it is both an all-time heaviest lift
  // and a 5-rep-target PB. Both events exist (praise.js merges them into one
  // message item); ids are deterministic.
  assert.deepEqual(a.events.map((e) => e.id).sort(), [
    '2026-01-12_bench_e1rm',
    '2026-01-12_bench_maxweight',
    '2026-01-12_bench_rep5',
  ]);
});

test('events: editing history (delete a day) removes dependent events on recompute', () => {
  const full = {
    '2026-01-05': day({ 5: 100 }),
    '2026-01-12': day({ 5: 102.5 }),
    '2026-01-19': day({ 5: 105 }),
  };
  const before = deriveExerciseEvents('bench', full);
  // Each improvement is both an all-time heaviest and a 5-rep-target PB.
  assert.deepEqual(before.events.map((e) => e.id).sort(), [
    '2026-01-12_bench_maxweight', '2026-01-12_bench_rep5',
    '2026-01-19_bench_maxweight', '2026-01-19_bench_rep5',
  ]);

  // Athlete's Jan 12 workout is deleted/corrected: recompute drops its events
  // and re-bases Jan 19 on the surviving history.
  const { '2026-01-12': _gone, ...rest } = full;
  const after = deriveExerciseEvents('bench', rest);
  assert.deepEqual(after.events.map((e) => e.id).sort(), [
    '2026-01-19_bench_maxweight', '2026-01-19_bench_rep5',
  ]);
  const rep = after.events.find((e) => e.type === 'repPB');
  assert.equal(rep.prevWeightKg, 100);
});

test('events: formula-version rebaseline does not invent a new PB event dated today', () => {
  // Recomputing the same history yields events only on historical improvement
  // days — no event exists for a day without an actual improvement, so a
  // version bump alone (recompute with no new training) creates no new
  // "today" event.
  const history = {
    '2026-01-05': day({ 5: 100 }, { weight: 100, reps: 5 }),
    '2026-01-12': day({ 5: 102.5 }, { weight: 102.5, reps: 5 }),
  };
  const recomputed = deriveExerciseEvents('bench', history);
  const todayKey = '2026-08-14';
  assert.ok(recomputed.events.every((e) => e.dateKey !== todayKey));
});
