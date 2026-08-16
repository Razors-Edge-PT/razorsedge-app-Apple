// Regression fixtures for the 2026-08 lifetime-PB correctness incident.
//
// Every case below reproduces a concrete production symptom or one of the
// rules that replaced the defective behaviour. Case 1, 2 and 4 are Aja's
// actual disputed 2026-08-13 report items.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { coachE1rm } = require('../coach/e1rm');
const {
  summarizeWorkoutDay, deriveExerciseEvents, applyDayToState, emptyState,
} = require('../coach/pb_engine');
const { bulkRebuild, applyWorkoutDay } = require('../coach/analytics_store');
const { selectPraise } = require('../coach/praise');
const { memoryStore } = require('../test-helpers/memory_store');

// ── fixture helpers ─────────────────────────────────────────────────────────

/** A workout document containing one exercise with the given sets. */
function workout(exerciseId, name, sets) {
  return { exercises: [{ exerciseId, name, sets }] };
}

/** Per-day summary for one exercise, straight from the real extractor. */
function dayOf(exerciseId, name, sets) {
  return summarizeWorkoutDay(workout(exerciseId, name, sets))[exerciseId];
}

function eventsFor(exerciseId, name, byDate) {
  const history = {};
  for (const [dateKey, sets] of Object.entries(byDate)) {
    history[dateKey] = dayOf(exerciseId, name, sets);
  }
  return deriveExerciseEvents(exerciseId, history);
}

const MCP = 'ex_machine_chest_press';
const FACE_PULL = 'ex_kp_face_pull';

// ── 1. Previous 25 x 15, later 25 x 14 at the same weight → not new ─────────
//
// Aja's report claimed "Machine Chest Press 25kg x 14 — new 14 rep target PB".
// The 2026-07-23 session already did 25kg for 15, which establishes at least
// that 14-rep performance at that weight.

test('regression 1: 25x15 history makes a later 25x14 dominated, not a new PB', () => {
  const { events } = eventsFor(MCP, 'Machine Chest Press', {
    '2026-07-23': [{ weight: 25, reps: 15, rir: 1.5 }],
    '2026-08-13': [{ weight: 25, reps: 14, rir: 1.5 }],
  });
  assert.deepEqual(events.filter((e) => e.dateKey === '2026-08-13'), []);
});

// ── 2. Previous 25 x 15, later 25 x 15 → exact equal, not new ───────────────
//
// The other half of the Machine Chest Press dispute: an exact PB equal is not
// a new rep-target PB, and its E1RM is equal rather than new either.

test('regression 2: an exact 25x15 repeat is an equal, not a new PB or E1RM PB', () => {
  const { events, repBest, e1rmBest } = eventsFor(MCP, 'Machine Chest Press', {
    '2026-07-23': [{ weight: 25, reps: 15, rir: 1.5 }],
    '2026-08-13': [{ weight: 25, reps: 15, rir: 1.5 }],
  });
  assert.deepEqual(events, []);
  assert.equal(repBest['15'].weightKg, 25);
  assert.equal(repBest['15'].dateKey, '2026-07-23'); // record stays with the original
  assert.equal(e1rmBest.dateKey, '2026-07-23');
});

// ── 3. Previous E1RM 43.9, later mathematically equivalent 43.9 → not new ───
//
// The two sets reach the same E1RM by different routes, so the second lands a
// few ulps above the first in floating point. Tolerance must absorb that
// without ever letting a genuine tie through as an improvement.

test('regression 3: a mathematically equivalent E1RM is not a new E1RM PB', () => {
  const later = { weight: 43.9 * 25 / 36, reps: 12 }; // 36/(37-12) = 1.44
  const a = coachE1rm(43.9, 1);
  const b = coachE1rm(later.weight, later.reps);
  assert.equal(a, 43.9);
  assert.ok(Math.abs(b - a) < 1e-9, 'fixture must be mathematically equal');

  const { events } = eventsFor('ex_row', 'Seated Row, Cable', {
    '2026-05-01': [{ weight: 43.9, reps: 1 }],
    '2026-06-01': [{ weight: later.weight, reps: later.reps }],
  });
  assert.deepEqual(events.filter((e) => e.type === 'e1rmPB'), []);
});

test('regression 3b: raw float noise never counts as an improvement', () => {
  const state = emptyState('ex');
  applyDayToState(state, 'ex', '2026-01-01', dayOf('ex', 'Ex', [{ weight: 0.1 + 0.2, reps: 5 }]));
  const events = applyDayToState(state, 'ex', '2026-01-02', dayOf('ex', 'Ex', [{ weight: 0.3, reps: 5 }]));
  assert.notEqual(0.1 + 0.2, 0.3); // the classic float gap really is there
  assert.deepEqual(events, []);
});

// ── 4. Previous 28x15 / E1RM 45.8, later 27x15 / E1RM 44.2 → neither new ────
//
// Aja's report claimed both a rep-target PB and an E1RM PB for the lighter
// Face Pull session.

test('regression 4: 27x15 after 28x15 is neither a rep PB nor an E1RM PB', () => {
  const { events, repBest, e1rmBest } = eventsFor(FACE_PULL, 'KP Face Pull', {
    '2026-05-04': [{ weight: 28, reps: 15, rir: null }],
    '2026-08-13': [{ weight: 27, reps: 15, rir: 1 }],
  });
  assert.deepEqual(events, []);
  assert.equal(repBest['15'].weightKg, 28);
  assert.ok(Math.abs(e1rmBest.e1rmKg - 45.8) < 0.05, `expected ~45.8, got ${e1rmBest.e1rmKg}`);
  assert.ok(Math.abs(coachE1rm(27, 15) - 44.2) < 0.05);
});

// ── 5. Previous 100x5 @ RIR 2, later exact 100x5 @ RIR 1 ────────────────────

test('regression 5: matching a PB at a strictly lower RIR praises effort only', () => {
  const { events } = eventsFor('ex_squat', 'Back Squat, Barbell', {
    '2026-01-05': [{ weight: 100, reps: 5, rir: 2 }],
    '2026-02-05': [{ weight: 100, reps: 5, rir: 1 }],
  });
  assert.equal(events.length, 1);
  const ev = events[0];
  assert.equal(ev.type, 'rirMatchPB');
  assert.equal(ev.id, '2026-02-05_ex_squat_rirmatch5');
  assert.equal(ev.weightKg, 100);
  assert.equal(ev.reps, 5);
  assert.equal(ev.rir, 1);
  assert.equal(ev.prevRir, 2);
  // Explicitly NOT presented as a strength improvement.
  assert.equal(events.filter((e) => e.type === 'repPB').length, 0);
  assert.equal(events.filter((e) => e.type === 'e1rmPB').length, 0);
  assert.equal(events.filter((e) => e.type === 'maxWeightPB').length, 0);
});

test('regression 5b: the same RIR improvement cannot be praised twice', () => {
  const { events } = eventsFor('ex_squat', 'Back Squat, Barbell', {
    '2026-01-05': [{ weight: 100, reps: 5, rir: 2 }],
    '2026-02-05': [{ weight: 100, reps: 5, rir: 1 }], // qualifies
    '2026-03-05': [{ weight: 100, reps: 5, rir: 1 }], // equal to the new baseline
    '2026-04-05': [{ weight: 100, reps: 5, rir: 2 }], // higher again
  });
  assert.equal(events.filter((e) => e.type === 'rirMatchPB').length, 1);
  assert.equal(events[0].dateKey, '2026-02-05');
});

// ── 6. Same / higher / null RIR → no PB-match praise ────────────────────────

for (const [label, priorRir, currentRir] of [
  ['equal RIR', 2, 2],
  ['higher RIR', 2, 3],
  ['null current RIR', 2, null],
  ['null prior RIR', null, 1],
  ['both null', null, null],
]) {
  test(`regression 6: ${label} produces no PB-match praise`, () => {
    const { events } = eventsFor('ex_squat', 'Back Squat, Barbell', {
      '2026-01-05': [{ weight: 100, reps: 5, rir: priorRir }],
      '2026-02-05': [{ weight: 100, reps: 5, rir: currentRir }],
    });
    assert.deepEqual(events, []);
  });
}

// ── 7. Previous 170x2, later 180x1 → all-time heaviest, ranked first ────────

test('regression 7: 180x1 after 170x2 is a new all-time heaviest weight', () => {
  const { events } = eventsFor('ex_dl', 'Deadlift, Conventional', {
    '2026-01-05': [{ weight: 170, reps: 2 }],
    '2026-02-05': [{ weight: 180, reps: 1 }],
  });
  const maxWeight = events.filter((e) => e.type === 'maxWeightPB');
  assert.equal(maxWeight.length, 1);
  assert.equal(maxWeight[0].weightKg, 180);
  assert.equal(maxWeight[0].reps, 1);
  assert.equal(maxWeight[0].prevWeightKg, 170);
});

test('regression 7b: it ranks first and does not also appear as a rep-PB item', () => {
  const { events } = eventsFor('ex_dl', 'Deadlift, Conventional', {
    '2026-01-05': [{ weight: 170, reps: 2 }],
    '2026-02-05': [{ weight: 180, reps: 1 }],
  });
  // The engine records both facts (180 also beats every prior set at >= 1 rep)…
  assert.equal(events.filter((e) => e.type === 'repPB').length, 1);

  // …but the athlete is told once, as the top-ranked all-time-heaviest item.
  const { praises } = selectPraise({
    maxWeightEvents: events.filter((e) => e.type === 'maxWeightPB'),
    repEvents: events.filter((e) => e.type === 'repPB'),
    e1rmEvents: events.filter((e) => e.type === 'e1rmPB'),
    rirMatchEvents: [],
    completion: null,
    allowedExerciseIds: null,
  });
  assert.equal(praises.length, 1);
  assert.equal(praises[0].kind, 'maxWeightPB');
});

// ── 8. More than three achievements → deterministic top three ───────────────

test('regression 8: the top three praise items are selected deterministically', () => {
  const mk = (type, exerciseId, extra) => ({
    type, exerciseId, dateKey: '2026-02-05', exerciseName: exerciseId, reps: 5, ...extra,
  });
  const input = {
    maxWeightEvents: [mk('maxWeightPB', 'ex_a', { weightKg: 180, pctImprovement: 0.05 })],
    repEvents: [
      mk('repPB', 'ex_b', { weightKg: 110, pctImprovement: 0.10 }),
      mk('repPB', 'ex_c', { weightKg: 105, pctImprovement: 0.02 }),
    ],
    e1rmEvents: [mk('e1rmPB', 'ex_d', { e1rmKg: 130, pctImprovement: 0.20 })],
    rirMatchEvents: [mk('rirMatchPB', 'ex_e', { weightKg: 100, rir: 0, prevRir: 3 })],
    completion: { completedAll: true, count: 4, planned: 4, weekAlreadyPraised: false },
    allowedExerciseIds: null,
  };

  const { praises } = selectPraise(input);
  assert.equal(praises.length, 3);
  // Category order wins over pct improvement: all-time heaviest, then the two
  // rep PBs (ranked by improvement) — the bigger E1RM gain does not jump the
  // queue, and completion never displaces a PB.
  assert.deepEqual(praises.map((p) => `${p.kind}:${p.event.exerciseId}`), [
    'maxWeightPB:ex_a', 'repPB:ex_b', 'repPB:ex_c',
  ]);

  // Deterministic: repeated selection is byte-identical.
  assert.deepEqual(selectPraise(input).praises, praises);
});

test('regression 8b: ties break deterministically, not by input order', () => {
  const mk = (exerciseId) => ({
    type: 'repPB', exerciseId, dateKey: '2026-02-05', exerciseName: exerciseId,
    reps: 5, weightKg: 100, pctImprovement: 0.05,
  });
  const forward = selectPraise({
    maxWeightEvents: [], repEvents: [mk('ex_c'), mk('ex_a'), mk('ex_b')],
    e1rmEvents: [], rirMatchEvents: [], completion: null, allowedExerciseIds: null,
  });
  const reversed = selectPraise({
    maxWeightEvents: [], repEvents: [mk('ex_b'), mk('ex_a'), mk('ex_c')],
    e1rmEvents: [], rirMatchEvents: [], completion: null, allowedExerciseIds: null,
  });
  assert.deepEqual(forward.praises.map((p) => p.event.exerciseId), ['ex_a', 'ex_b', 'ex_c']);
  assert.deepEqual(forward.praises, reversed.praises);
});

// ── 9. Bootstrap and incremental processing agree ───────────────────────────

test('regression 9: lifetime bootstrap and incremental appends agree exactly', async () => {
  // A history that exercises every stream: dominance, equality, all-time
  // heaviest, an RIR match and an E1RM improvement.
  const entries = [
    ['2026-01-05', workout(MCP, 'Machine Chest Press', [{ weight: 22.5, reps: 14, rir: 2 }])],
    ['2026-02-05', workout(MCP, 'Machine Chest Press', [{ weight: 25, reps: 15, rir: 1.5 }])],
    ['2026-03-05', workout(MCP, 'Machine Chest Press', [{ weight: 25, reps: 14, rir: 1.5 }])],
    ['2026-04-05', workout(MCP, 'Machine Chest Press', [{ weight: 25, reps: 15, rir: 0.5 }])],
    ['2026-05-05', workout(MCP, 'Machine Chest Press', [{ weight: 30, reps: 8, rir: 1 }])],
    ['2026-06-05', workout(MCP, 'Machine Chest Press', [{ weight: 30, reps: 8, rir: 1 }])],
  ];

  const boot = memoryStore();
  await bulkRebuild(boot.store, entries);
  await boot.store.flush();

  const incr = memoryStore();
  for (const [dateKey, data] of entries) {
    await applyWorkoutDay(incr.store, dateKey, data);
    await incr.store.flush();
  }

  assert.deepEqual(snapshot(incr), snapshot(boot));

  // And the result is actually correct, not merely consistent.
  const ids = [...boot.events.keys()].sort();
  assert.deepEqual(ids, [
    // 25kg beats the 22.5kg baseline → all-time heaviest, and its E1RM (40.9)
    // beats the baseline's (35.2). No rep15 event: nothing in history had ever
    // reached 15 reps, so there is no comparable weight to improve on.
    '2026-02-05_ex_machine_chest_press_e1rm',
    '2026-02-05_ex_machine_chest_press_maxweight',
    // Same 25x15, logged at RIR 0.5 instead of 1.5 → effort praise only.
    '2026-04-05_ex_machine_chest_press_rirmatch15',
    // 30kg is a new all-time heaviest and beats the 25kg standing at >= 8 reps.
    // Its E1RM (37.2) is BELOW the 25x15 E1RM (40.9), so no E1RM event.
    '2026-05-05_ex_machine_chest_press_maxweight',
    '2026-05-05_ex_machine_chest_press_rep8',
  ]);
  // The dominated 25x14 on 2026-03-05 produced nothing at all — this is Aja's
  // exact false-PB case, replayed through the real store.
  assert.ok(!ids.some((id) => id.includes('2026-03-05')));
});

// ── 10. Rebuilds remove obsolete false events ──────────────────────────────

test('regression 10: a rebuild deletes events the old algorithm wrongly created', async () => {
  const live = memoryStore();

  // Seed the day documents the way production holds them …
  await applyWorkoutDay(live.store, '2026-07-23',
    workout(MCP, 'Machine Chest Press', [{ weight: 25, reps: 15, rir: 1.5 }]));
  await applyWorkoutDay(live.store, '2026-08-13',
    workout(MCP, 'Machine Chest Press', [{ weight: 25, reps: 14, rir: 1.5 }]));
  await live.store.flush();
  assert.deepEqual([...live.events.keys()], [], 'corrected engine creates nothing');

  // … then plant the false "new 14 rep target PB" the defective v2 engine
  // published on 2026-08-13.
  const falseEventId = '2026-08-13_ex_machine_chest_press_rep14';
  await live.store.setEvent({
    id: falseEventId,
    type: 'repPB',
    dateKey: '2026-08-13',
    exerciseId: MCP,
    exerciseName: 'Machine Chest Press',
    reps: 14,
    weightKg: 25,
    prevWeightKg: 22.5,
    pctImprovement: 0.111,
  });
  await live.store.flush();
  assert.ok(live.events.has(falseEventId));

  // Re-applying the day takes the REBUILD branch (the day doc already exists),
  // which reconciles events against what the surviving data justifies — so the
  // false event is DELETED, not merely left alone.
  await applyWorkoutDay(live.store, '2026-08-13',
    workout(MCP, 'Machine Chest Press', [{ weight: 25, reps: 14, rir: 1.5 }]));
  await live.store.flush();

  assert.ok(!live.events.has(falseEventId), 'obsolete false event must be deleted');
  assert.deepEqual([...live.events.keys()], []);
});

test('regression 10b: a full re-bootstrap converges and is idempotent', async () => {
  const live = memoryStore();
  await live.store.setEvent({
    id: '2026-08-13_ex_kp_face_pull_rep15',
    type: 'repPB', dateKey: '2026-08-13', exerciseId: FACE_PULL,
    exerciseName: 'KP Face Pull', reps: 15, weightKg: 27, prevWeightKg: 20,
  });
  await live.store.flush();

  const entries = [
    ['2026-05-04', workout(FACE_PULL, 'KP Face Pull', [{ weight: 28, reps: 15 }])],
    ['2026-08-13', workout(FACE_PULL, 'KP Face Pull', [{ weight: 27, reps: 15, rir: 1 }])],
  ];

  // runBootstrap clears the three collections before bulkRebuild; model that.
  live.events.clear();
  live.days.clear();
  live.summaries.clear();
  await bulkRebuild(live.store, entries);
  await live.store.flush();
  const first = snapshot(live);
  assert.deepEqual([...live.events.keys()], []); // no PB survives the rebuild

  live.events.clear();
  live.days.clear();
  live.summaries.clear();
  await bulkRebuild(live.store, entries);
  await live.store.flush();
  assert.deepEqual(snapshot(live), first); // idempotent
});

function snapshot(m) {
  return JSON.stringify({
    summaries: [...m.summaries.entries()].sort(),
    days: [...m.days.entries()].sort(),
    events: [...m.events.entries()].sort(),
  });
}
