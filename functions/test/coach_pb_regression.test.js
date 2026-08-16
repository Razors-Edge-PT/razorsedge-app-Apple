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

// ── 4b. Exercise-identity case split (the ACTUAL Face Pull cause) ───────────
//
// Production workout documents written 2026-03-03..2026-05-07 persisted
// lowercased copies of the catalog id. The 28kg x 15 on 2026-05-04 was stored
// under "eeexnmsxv90q0ruggecq" while every later session used
// "eeEXnmSXv90q0rUgGECq", so the two casings formed independent lifetime
// streams and the heavier history was invisible to the comparison. That is why
// the lighter 27kg x 15 on 2026-08-06 published as a new rep PB (prev 25) and
// a new E1RM PB (44.2 vs a stream-local 40.9) despite the real lifetime bests
// being 28kg and 45.8.

test('regression 4b: case-split exercise ids resolve to one lifetime stream', () => {
  const MIXED = 'eeEXnmSXv90q0rUgGECq';
  const LOWER = 'eeexnmsxv90q0ruggecq';
  assert.equal(MIXED.toLowerCase(), LOWER, 'fixture must be a pure case split');

  // Aja's real sequence, abbreviated to the decisive days.
  const history = {};
  const add = (dateKey, id, sets) => {
    const summary = summarizeWorkoutDay(workout(id, 'KP Face Pull', sets));
    const keys = Object.keys(summary);
    assert.equal(keys.length, 1);
    assert.equal(keys[0], LOWER, 'both casings must fold to the same stream key');
    history[dateKey] = summary[keys[0]];
  };
  add('2026-04-23', LOWER, [{ weight: 32, reps: 10 }]);
  add('2026-05-04', LOWER, [{ weight: 28, reps: 15 }]);       // E1RM 45.8
  add('2026-05-21', MIXED, [{ weight: 25, reps: 15, rir: 1.5 }]);
  add('2026-08-06', MIXED, [{ weight: 27, reps: 15 }]);       // the false PB

  const { events, repBest, e1rmBest, catalogExerciseId } =
    deriveExerciseEvents(LOWER, history);

  // Nothing at all on 2026-08-06: 27 < 28 at 15 reps, 44.2 < 45.8 E1RM.
  assert.deepEqual(events.filter((e) => e.dateKey === '2026-08-06'), []);
  assert.equal(repBest['15'].weightKg, 28);
  assert.equal(repBest['15'].dateKey, '2026-05-04');
  assert.ok(Math.abs(e1rmBest.e1rmKg - 45.818) < 0.01);
  assert.equal(e1rmBest.dateKey, '2026-05-04');

  // The catalog casing is preserved for display/reference.
  assert.equal(catalogExerciseId, MIXED);
});

test('regression 4b2: both casings inside ONE day merge (production 2026-04-23)', () => {
  const summary = summarizeWorkoutDay({
    exercises: [
      { exerciseId: 'eeexnmsxv90q0ruggecq', name: 'KP Face Pull', sets: [{ weight: 32, reps: 10 }] },
      { exerciseId: 'eeEXnmSXv90q0rUgGECq', name: 'KP Face Pull', sets: [{ weight: 30, reps: 12 }] },
    ],
  });
  assert.deepEqual(Object.keys(summary), ['eeexnmsxv90q0ruggecq']);
  const day = summary.eeexnmsxv90q0ruggecq;
  assert.equal(day.bestByReps['10'], 32);
  assert.equal(day.bestByReps['12'], 30);
  assert.equal(day.catalogExerciseId, 'eeEXnmSXv90q0rUgGECq');
});

test('regression 4c: the coach custom-exercise filter survives folding', () => {
  const ev = {
    type: 'repPB', exerciseId: 'eeexnmsxv90q0ruggecq',
    catalogExerciseId: 'eeEXnmSXv90q0rUgGECq',
    dateKey: '2026-08-06', exerciseName: 'KP Face Pull',
    reps: 15, weightKg: 30, prevWeightKg: 28, pctImprovement: 0.07,
  };
  // The coach picked the catalog id in its original casing.
  const picked = selectPraise({
    maxWeightEvents: [], repEvents: [ev], e1rmEvents: [], rirMatchEvents: [],
    completion: null, allowedExerciseIds: ['eeEXnmSXv90q0rUgGECq'],
  });
  assert.equal(picked.praises.length, 1);

  // An unrelated selection still excludes it.
  const excluded = selectPraise({
    maxWeightEvents: [], repEvents: [ev], e1rmEvents: [], rirMatchEvents: [],
    completion: null, allowedExerciseIds: ['someOtherExerciseId'],
  });
  assert.equal(excluded.praises.length, 0);
});

// ── 5. RIR direction: HIGHER at the same weight and reps is the improvement ─
//
// RIR is reps-in-reserve. Matching a PB with MORE left in the tank means the
// performance got easier — evidence of improved strength. A LOWER RIR only
// means the athlete worked closer to failure and must never fire this event.
// (v3 had this backwards and published 34 lower-RIR events across the three
// enrolled athletes; v4 inverts it and rebuilds.)

test('regression 5: prior 25x15 @ RIR 1.5, current 25x15 @ RIR 2 fires once', () => {
  const { events } = eventsFor(MCP, 'Machine Chest Press', {
    '2026-07-23': [{ weight: 25, reps: 15, rir: 1.5 }],
    '2026-08-13': [{ weight: 25, reps: 15, rir: 2 }],
  });
  assert.equal(events.length, 1);
  const ev = events[0];
  assert.equal(ev.type, 'rirMatchPB');
  assert.equal(ev.id, `2026-08-13_${MCP}_rirmatch15`);
  assert.equal(ev.weightKg, 25);
  assert.equal(ev.reps, 15);
  assert.equal(ev.rir, 2);
  assert.equal(ev.prevRir, 1.5);
  // Never presented as a new PB of any kind.
  assert.equal(events.filter((e) => e.type === 'repPB').length, 0);
  assert.equal(events.filter((e) => e.type === 'e1rmPB').length, 0);
  assert.equal(events.filter((e) => e.type === 'maxWeightPB').length, 0);
});

for (const [label, currentRir] of [
  ['equal RIR 1.5', 1.5],
  ['lower RIR 1', 1],
  ['lower RIR 0', 0],
]) {
  test(`regression 5: current ${label} produces no event`, () => {
    const { events } = eventsFor(MCP, 'Machine Chest Press', {
      '2026-07-23': [{ weight: 25, reps: 15, rir: 1.5 }],
      '2026-08-13': [{ weight: 25, reps: 15, rir: currentRir }],
    });
    assert.deepEqual(events, []);
  });
}

for (const [label, priorRir, currentRir] of [
  ['missing current RIR', 1.5, null],
  ['missing prior RIR', null, 2],
  ['both missing', null, null],
  ['invalid current RIR', 1.5, 'abc'],
  ['negative current RIR', 1.5, -1],
]) {
  test(`regression 5: ${label} produces no event`, () => {
    const { events } = eventsFor(MCP, 'Machine Chest Press', {
      '2026-07-23': [{ weight: 25, reps: 15, rir: priorRir }],
      '2026-08-13': [{ weight: 25, reps: 15, rir: currentRir }],
    });
    assert.deepEqual(events, []);
  });
}

test('regression 5: baseline rises monotonically — repeat at RIR 2 does not re-fire', () => {
  const { events, repRir } = eventsFor(MCP, 'Machine Chest Press', {
    '2026-07-23': [{ weight: 25, reps: 15, rir: 1.5 }],
    '2026-08-13': [{ weight: 25, reps: 15, rir: 2 }],   // fires
    '2026-08-20': [{ weight: 25, reps: 15, rir: 2 }],   // equal to new baseline
    '2026-08-27': [{ weight: 25, reps: 15, rir: 1 }],   // lower again
  });
  const rir = events.filter((e) => e.type === 'rirMatchPB');
  assert.equal(rir.length, 1);
  assert.equal(rir[0].dateKey, '2026-08-13');
  assert.equal(repRir['15'].rir, 2, 'baseline must not fall back to 1');
});

test('regression 5: a later match at RIR 2.5 fires once more', () => {
  const { events } = eventsFor(MCP, 'Machine Chest Press', {
    '2026-07-23': [{ weight: 25, reps: 15, rir: 1.5 }],
    '2026-08-13': [{ weight: 25, reps: 15, rir: 2 }],   // fires (1.5 -> 2)
    '2026-08-20': [{ weight: 25, reps: 15, rir: 2 }],   // equal, no event
    '2026-08-27': [{ weight: 25, reps: 15, rir: 2.5 }], // fires (2 -> 2.5)
  });
  const rir = events.filter((e) => e.type === 'rirMatchPB');
  assert.deepEqual(rir.map((e) => `${e.dateKey}:${e.prevRir}->${e.rir}`), [
    '2026-08-13:1.5->2',
    '2026-08-27:2->2.5',
  ]);
});

// Aja's REAL production sequence: 2026-07-23 logged 25x15 @ RIR 1.5, then
// 2026-08-13 logged 25x15 @ RIR 1. v3 praised that as an achievement; it is a
// LOWER RIR and must produce nothing.
test('regression 5: Aja 25x15 RIR 1.5 -> RIR 1 must NOT fire', () => {
  const { events } = eventsFor(MCP, 'Machine Chest Press', {
    '2026-07-23': [{ weight: 23, reps: 15, rir: 3 }, { weight: 25, reps: 15, rir: 1.5 },
      { weight: 25, reps: 15, rir: null }],
    '2026-08-13': [{ weight: 25, reps: 15, rir: 1.5 }, { weight: 25, reps: 15, rir: 1 },
      { weight: 25, reps: 13, rir: null }],
  });
  assert.deepEqual(events.filter((e) => e.type === 'rirMatchPB'), []);
});

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
    // same 25x15, but with MORE reps in reserve than 2026-02-05 → rirMatchPB
    ['2026-04-05', workout(MCP, 'Machine Chest Press', [{ weight: 25, reps: 15, rir: 2.5 }])],
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
    // Same 25x15, logged at RIR 2.5 instead of 1.5 → easier, so it praises.
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
