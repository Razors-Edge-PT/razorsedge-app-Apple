'use strict';

const test = require('node:test');
const assert = require('node:assert');

const {
  showcaseE1rm,
  SHOWCASE_FORMULA_VERSION,
  BRZYCKI_MAX_REPS,
} = require('../showcase/e1rm_spec');
const { matchBigFive, BIG_FIVE, SLOT_ORDER } = require('../showcase/big_five');
const {
  recordFingerprint,
  extractBigFiveSets,
  summarizeWorkoutDay,
  buildShowcase,
  liveFingerprints,
} = require('../showcase/reducer');

const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
const SQUAT = 'heeBViVINHO6tUScSd6y';

function workout(exerciseId, sets, extra) {
  return {
    exercises: [Object.assign({ exerciseId, name: 'x', sets }, extra || {})],
  };
}

// ── E1RM ────────────────────────────────────────────────────────────────────

test('E1RM at 1 rep equals the weight exactly', () => {
  assert.strictEqual(showcaseE1rm(180, 1), 180);
  assert.strictEqual(showcaseE1rm(2.5, 1), 2.5);
});

test('E1RM uses Brzycki for low reps', () => {
  assert.ok(Math.abs(showcaseE1rm(180, 2) - (180 * 36) / 35) < 1e-12);
  assert.ok(Math.abs(showcaseE1rm(100, 5) - (100 * 36) / 32) < 1e-12);
  assert.ok(Math.abs(showcaseE1rm(60, 10) - (60 * 36) / 27) < 1e-12);
});

test('E1RM switches formula exactly between 25 and 26 reps', () => {
  assert.strictEqual(BRZYCKI_MAX_REPS, 25);
  // 25 reps is still Brzycki.
  assert.ok(Math.abs(showcaseE1rm(50, 25) - (50 * 36) / 12) < 1e-12);
  // 26 reps is Epley, which is a very different number — proving the
  // boundary is real and not an off-by-one.
  assert.ok(Math.abs(showcaseE1rm(50, 26) - 50 * (1 + 0.0333 * 26)) < 1e-12);
  assert.ok(showcaseE1rm(50, 25) > showcaseE1rm(50, 26));
});

test('E1RM rejects invalid input', () => {
  assert.strictEqual(showcaseE1rm(0, 5), 0);
  assert.strictEqual(showcaseE1rm(100, 0), 0);
  assert.strictEqual(showcaseE1rm(-100, 5), 0);
  assert.strictEqual(showcaseE1rm(NaN, 5), 0);
});

test('E1RM is completely independent of RIR', () => {
  const sets = (rir) => [{ weight: 100, reps: 5, rir: rir }];
  const a = summarizeWorkoutDay('2026-01-01', workout(BENCH, sets(0)));
  const b = summarizeWorkoutDay('2026-01-01', workout(BENCH, sets(4)));
  assert.deepStrictEqual(a.bench.bestE1rm, b.bench.bestE1rm);
  // and the raw curve never sees it
  assert.strictEqual(showcaseE1rm(100, 5), showcaseE1rm(100, 5));
});

// ── Big Five identity ───────────────────────────────────────────────────────

test('the five stable ids resolve to the five slots', () => {
  assert.deepStrictEqual(
    BIG_FIVE.map((l) => l.exerciseId),
    [
      'AmfUWbF1DH3I7qPAdh5k',
      'heeBViVINHO6tUScSd6y',
      'MsGl7e9yanDeEnYX0e4X',
      'XM9026peNIu0R8qh7UqY',
      'RdsGazgdH0xgpjek0n3u',
    ],
  );
  assert.deepStrictEqual(SLOT_ORDER, [
    'bench',
    'squat',
    'deadlift',
    'chinUp',
    'ohpUnilateral',
  ]);
});

test('ids are matched case-folded (2026 lowercased-id regression)', () => {
  assert.strictEqual(matchBigFive(BENCH.toLowerCase(), null).slot, 'bench');
  assert.strictEqual(matchBigFive(BENCH.toUpperCase(), null).slot, 'bench');
  assert.strictEqual(matchBigFive(`  ${SQUAT}  `, null).slot, 'squat');
});

test('legacy id-less rows match only exact canonical aliases', () => {
  assert.strictEqual(matchBigFive(null, 'Bench Press').slot, 'bench');
  assert.strictEqual(matchBigFive(null, 'bench press, barbell').slot, 'bench');
  assert.strictEqual(matchBigFive(null, 'Deadlift').slot, 'deadlift');
  assert.strictEqual(matchBigFive(null, 'Chin-Up').slot, 'chinUp');
});

test('similarly named catalogue variants are never claimed', () => {
  for (const name of [
    'Larsen Bench Press',
    'Bench Press, Larsen Press',
    'Bench Press, Narrow Grip',
    'Bench Press, Touch n Go',
    'Decline Bench Press, Barbell',
    'Back Squat, Low bar',
    'Back Squat, Pin Squat',
    'Smith Machine Squat',
    'Sumo Deadlift',
    'Romanian Deadlift',
    'Deadlift, Deficit',
    'Pull-Up',
    'Pull-Up, Wide Arm',
    'Overhead Dumbbell Press',
  ]) {
    assert.strictEqual(matchBigFive(null, name), null, `${name} must not match`);
  }
});

test('a row carrying another exercise id is never rescued by its name', () => {
  // Larsen Bench Press's real catalogue id, but mislabelled "Bench Press".
  assert.strictEqual(
    matchBigFive('YvwK9kwc1hcA2omz1g4r', 'Bench Press'),
    null,
  );
});

// ── Set extraction ──────────────────────────────────────────────────────────

test('only sets with weight > 0 and reps > 0 participate', () => {
  const sets = [
    { weight: 100, reps: 5 },
    { weight: 0, reps: 5 },
    { weight: 100, reps: 0 },
    { weight: -20, reps: 3 },
    { weight: 120, reps: null },
    { weight: 90, reps: 3 },
  ];
  const got = extractBigFiveSets(workout(BENCH, sets));
  assert.strictEqual(got.bench.length, 2);
  assert.deepStrictEqual(
    got.bench.map((s) => s.weight),
    [100, 90],
  );
});

test('WES2 actualWeight / actualReps aliases are accepted', () => {
  const got = extractBigFiveSets(
    workout(BENCH, [{ actualWeight: 140, actualReps: 3 }]),
  );
  assert.strictEqual(got.bench.length, 1);
  assert.strictEqual(got.bench[0].weight, 140);
});

test('set keys are deterministic and stable against unrelated row changes', () => {
  const got = extractBigFiveSets(
    workout(BENCH, [{ weight: 100, reps: 5 }, { weight: 110, reps: 3 }]),
  );
  assert.deepStrictEqual(
    got.bench.map((s) => s.setKey),
    ['s0', 's1'],
  );
});

test('deleting an unrelated exercise does not move another lift set key', () => {
  const both = extractBigFiveSets({
    exercises: [
      { exerciseId: BENCH, name: 'b', sets: [{ weight: 100, reps: 5 }] },
      { exerciseId: SQUAT, name: 's', sets: [{ weight: 200, reps: 5 }] },
    ],
  });
  const squatOnly = extractBigFiveSets({
    exercises: [{ exerciseId: SQUAT, name: 's', sets: [{ weight: 200, reps: 5 }] }],
  });
  // Positional keys count sets of THAT lift, so removing bench leaves squat's
  // fingerprint — and any proof video attached to it — exactly where it was.
  assert.strictEqual(both.squat[0].setKey, squatOnly.squat[0].setKey);
});

test('an explicit set id wins over the positional key', () => {
  const got = extractBigFiveSets(
    workout(BENCH, [{ id: 'set-abc', weight: 100, reps: 5 }]),
  );
  assert.strictEqual(got.bench[0].setKey, 'set-abc');
});

// ── Heaviest-load semantics ─────────────────────────────────────────────────

test('heaviest load ignores rep count: 180x2 beats 175x1', () => {
  const snap = buildShowcase({
    '2026-01-01': workout(BENCH, [
      { weight: 175, reps: 1 },
      { weight: 180, reps: 2 },
    ]),
  });
  assert.strictEqual(snap.lifts.bench.heaviest.weight, 180);
  assert.strictEqual(snap.lifts.bench.heaviest.reps, 2);
});

test('heaviest load: 190x1 beats 180x2', () => {
  const snap = buildShowcase({
    '2026-01-01': workout(BENCH, [{ weight: 180, reps: 2 }]),
    '2026-02-01': workout(BENCH, [{ weight: 190, reps: 1 }]),
  });
  assert.strictEqual(snap.lifts.bench.heaviest.weight, 190);
  assert.strictEqual(snap.lifts.bench.heaviest.reps, 1);
});

test('equal weight prefers more repetitions', () => {
  const snap = buildShowcase({
    '2026-01-01': workout(BENCH, [{ weight: 180, reps: 1 }]),
    '2026-01-02': workout(BENCH, [{ weight: 180, reps: 4 }]),
    '2026-01-03': workout(BENCH, [{ weight: 180, reps: 2 }]),
  });
  assert.strictEqual(snap.lifts.bench.heaviest.reps, 4);
  assert.strictEqual(snap.lifts.bench.heaviest.dateKey, '2026-01-02');
});

test('equal weight and reps break to the LATEST date, then a stable set key', () => {
  const snap = buildShowcase({
    '2026-01-01': workout(BENCH, [{ weight: 180, reps: 2 }]),
    '2026-03-09': workout(BENCH, [{ weight: 180, reps: 2 }]),
  });
  assert.strictEqual(snap.lifts.bench.heaviest.dateKey, '2026-03-09');

  const sameDay = buildShowcase({
    '2026-01-01': workout(BENCH, [
      { id: 'zzz', weight: 180, reps: 2 },
      { id: 'aaa', weight: 180, reps: 2 },
    ]),
  });
  assert.strictEqual(sameDay.lifts.bench.heaviest.setKey, 'aaa');
});

test('the E1RM record and the heaviest record can differ', () => {
  const snap = buildShowcase({
    // 100x10 → E1RM 133.3 ; 130x1 → E1RM 130 but heavier absolute load.
    '2026-01-01': workout(BENCH, [
      { weight: 100, reps: 10 },
      { weight: 130, reps: 1 },
    ]),
  });
  assert.strictEqual(snap.lifts.bench.heaviest.weight, 130);
  assert.strictEqual(snap.lifts.bench.e1rm.weight, 100);
  assert.notStrictEqual(
    snap.lifts.bench.e1rm.fingerprint,
    snap.lifts.bench.heaviest.fingerprint,
  );
});

test('one set can carry both achievements', () => {
  const snap = buildShowcase({
    '2026-01-01': workout(BENCH, [
      { weight: 100, reps: 1 },
      { weight: 150, reps: 3 },
    ]),
  });
  assert.strictEqual(
    snap.lifts.bench.e1rm.fingerprint,
    snap.lifts.bench.heaviest.fingerprint,
  );
});

// ── Fingerprints ────────────────────────────────────────────────────────────

test('a fingerprint is stable across recomputation', () => {
  const day = { '2026-01-01': workout(BENCH, [{ weight: 180, reps: 2 }]) };
  assert.strictEqual(
    buildShowcase(day).lifts.bench.heaviest.fingerprint,
    buildShowcase(day).lifts.bench.heaviest.fingerprint,
  );
});

test('a fingerprint changes when the source performance changes', () => {
  const a = buildShowcase({ '2026-01-01': workout(BENCH, [{ weight: 180, reps: 2 }]) });
  const b = buildShowcase({ '2026-01-01': workout(BENCH, [{ weight: 181, reps: 2 }]) });
  const c = buildShowcase({ '2026-01-01': workout(BENCH, [{ weight: 180, reps: 3 }]) });
  const d = buildShowcase({ '2026-01-02': workout(BENCH, [{ weight: 180, reps: 2 }]) });
  const fps = [a, b, c, d].map((s) => s.lifts.bench.heaviest.fingerprint);
  assert.strictEqual(new Set(fps).size, 4);
});

test('a fingerprint does not depend on the E1RM formula version', () => {
  // The fingerprint payload deliberately excludes e1rm and formulaVersion so
  // a curve change cannot orphan every attached proof video.
  const fp = recordFingerprint({
    slot: 'bench',
    exerciseId: BENCH,
    dateKey: '2026-01-01',
    setKey: 's0',
    weight: 180,
    reps: 2,
  });
  assert.strictEqual(fp.length, 32);
  assert.strictEqual(
    fp,
    recordFingerprint({
      slot: 'bench',
      exerciseId: BENCH.toLowerCase(),
      dateKey: '2026-01-01',
      setKey: 's0',
      weight: 180.0004,
      reps: 2,
    }),
  );
});

test('liveFingerprints lists exactly the standing records', () => {
  const snap = buildShowcase({
    '2026-01-01': workout(BENCH, [
      { weight: 100, reps: 10 },
      { weight: 130, reps: 1 },
    ]),
  });
  const live = liveFingerprints(snap);
  assert.strictEqual(live.size, 2);
  assert.ok(live.has(snap.lifts.bench.e1rm.fingerprint));
  assert.ok(live.has(snap.lifts.bench.heaviest.fingerprint));
});

// ── Snapshot shape ──────────────────────────────────────────────────────────

test('the snapshot carries the schema and formula version and no proof data', () => {
  const snap = buildShowcase({
    '2026-01-01': workout(BENCH, [{ weight: 100, reps: 5 }]),
  });
  assert.strictEqual(snap.schema, 'profileShowcaseV1');
  assert.strictEqual(snap.formulaVersion, SHOWCASE_FORMULA_VERSION);
  assert.deepStrictEqual(Object.keys(snap.lifts), ['bench']);
  assert.ok(!('proof' in snap.lifts.bench));
});

test('untrained lifts are simply absent', () => {
  const snap = buildShowcase({
    '2026-01-01': workout(SQUAT, [{ weight: 200, reps: 3 }]),
  });
  assert.deepStrictEqual(Object.keys(snap.lifts), ['squat']);
});

test('rebuilding is order independent', () => {
  const days = {
    '2026-03-01': workout(BENCH, [{ weight: 150, reps: 3 }]),
    '2026-01-01': workout(BENCH, [{ weight: 180, reps: 1 }]),
    '2026-02-01': workout(BENCH, [{ weight: 170, reps: 2 }]),
  };
  const forward = buildShowcase(days);
  const reversed = buildShowcase(
    Object.fromEntries(Object.entries(days).reverse()),
  );
  assert.deepStrictEqual(forward, reversed);
});
