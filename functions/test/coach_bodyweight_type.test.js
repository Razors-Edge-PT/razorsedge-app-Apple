'use strict';

// A `Body Weight` catalogue TYPE makes an exercise bodyweight-loaded on the
// server too, and a bodyweight set's stored `0` is a real set at "0 kg added".
//
// Two independent rules, mirroring lib/exercise_type.dart and
// test/bodyweight_exercise_type_test.dart:
//
//   CLASSIFICATION — id/name in the hard-coded catalogue (unchanged) OR a
//   catalogue `type` of "Body Weight" (trimmed, case-insensitive). Never the
//   exercise's name, category or body parts.
//
//   RAW SET VALIDITY — WES2 stores what was TYPED, so a bodyweight set's
//   stored `0` means 0 kg ADDED and its TOTAL is the athlete's own bodyweight.
//   On every other exercise a stored 0 still means nothing logged, and a
//   NEGATIVE weight is invalid everywhere.
//
// The exercise that motivated the change ("Jump chin up") is never named in
// the catalogues: it must qualify through its stored `type` alone.

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  BODYWEIGHT_EXERCISE_TYPE,
  BODYWEIGHT_EXERCISE_NAMES,
  isBodyweightType,
  isBodyweightExercise,
  rowIsBodyweight,
  isStoredWeightPerformed,
  isRawSetPerformed,
} = require('../coach/bodyweight_exercises');
const {
  summarizeWorkoutDay, hasBodyweightExercise, deriveExerciseEvents,
} = require('../coach/pb_engine');
const { applyWorkoutDay, bulkRebuild } = require('../coach/analytics_store');
const {
  exerciseIdsIn, untypedExerciseIdsIn, typesFromRows, makeExerciseTypeResolver,
} = require('../coach/exercise_types');
const { hasCompletedSets } = require('../coach/adherence');
const { extractBigFiveSets } = require('../showcase/reducer');
const { pickBodyweightAsOf } = require('../showcase/bodyweight');
const { memoryStore, snapshotOf } = require('../test-helpers/memory_store');

const CHIN = 'XM9026peNIu0R8qh7UqY';
const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
/** An exercise in NEITHER hard-coded list — it can only qualify by type. */
const TYPED = 'typed-bw-exercise-id-03';
const TYPED_KEY = TYPED.toLowerCase();
const TYPED_NAME = 'Some Untracked Movement';

/** WES2: the ADDED load, verbatim, with setIndex stamped. */
const wes2 = (added, reps, setIndex = 0) => ({ setIndex, weight: added, reps });
/** Legacy screen: TOTAL stored, typed added load beside it. */
const legacy = (total, added, reps) => ({ weight: total, weightAdded: added, reps });

const row = (id, name, sets, type) => ({
  exerciseId: id, name, ...(type ? { type } : {}), sets,
});
const doc = (...rows) => ({ exercises: rows });
const weighIn = (dateKey, weight) => ({ id: `w-${dateKey}`, weight, unit: 'kg', dateKey });

/** The shared memory store, resolving bodyweight from [entries]. */
function storeWith(entries, exerciseTypes) {
  const c = memoryStore();
  c.store.getBodyweightAsOfMany = async (keys) =>
    new Map(keys.map((d) => [d, pickBodyweightAsOf(entries, d)]));
  if (exerciseTypes) {
    const { typesFromRows: fromRows } = require('../coach/exercise_types');
    c.store.getExerciseTypesFor = async (data) => {
      const out = fromRows(data);
      for (const [k, v] of Object.entries(exerciseTypes)) if (!out.has(k)) out.set(k, v);
      return out;
    };
  }
  return c;
}

// ── 1. The hard-coded catalogue still stands on its own ────────────────────

test('hard-coded ids and names still classify with no type', () => {
  assert.equal(isBodyweightExercise(CHIN, 'x'), true);
  assert.equal(isBodyweightExercise(CHIN.toLowerCase(), 'x'), true,
    'lowercased catalogue copies');
  assert.equal(isBodyweightExercise(null, ' Chin-Up '), true);
  assert.equal(isBodyweightExercise('FtayDmR5BVnGS1FXlXLL', ''), true, 'Triceps Dip');
  assert.equal(isBodyweightExercise(BENCH, 'Bench Press, Barbell'), false);
});

test('a hard-coded exercise stays bodyweight whatever type it carries', () => {
  // The lists are a FALLBACK, not a veto: existing history cannot change
  // interpretation because someone filled in a `type` later.
  assert.equal(isBodyweightExercise(CHIN, 'Chin-Up', 'Barbell'), true);
});

// ── 2-4. Type-derived classification ───────────────────────────────────────

test('an otherwise unknown exercise with type "Body Weight" qualifies', () => {
  assert.equal(isBodyweightExercise(TYPED, TYPED_NAME), false);
  assert.equal(isBodyweightExercise(TYPED, TYPED_NAME, 'Body Weight'), true);
});

test('type matching is trimmed and case-insensitive', () => {
  for (const t of ['Body Weight', '  Body Weight  ', 'body weight',
    'BODY WEIGHT', '\tBoDy WeIgHt\n']) {
    assert.equal(isBodyweightType(t), true, `type "${t}"`);
    assert.equal(isBodyweightExercise(TYPED, TYPED_NAME, t), true, `type "${t}"`);
  }
});

test('other types do not classify as bodyweight', () => {
  for (const t of ['Barbell', 'Dumbbell', 'Machine', 'Cable Stack',
    'Suspension System', 'Bodyweight', 'Body  Weight', 'Body Weighted',
    '', '   ', null, undefined, 42, {}]) {
    assert.equal(isBodyweightType(t), false, `type "${String(t)}"`);
    assert.equal(isBodyweightExercise(TYPED, TYPED_NAME, t), false,
      `type "${String(t)}"`);
  }
});

test('classification is never inferred from the exercise name', () => {
  for (const n of ['Bodyweight Squat', 'Body Weight Row', 'Chin-Up Variation']) {
    assert.equal(isBodyweightExercise(`x-${n}`, n), false, `name "${n}"`);
  }
});

// ── 5. The motivating exercise is in neither hard-coded list ───────────────

test('the hard-coded catalogue names no "jump chin up" variant', () => {
  for (const n of BODYWEIGHT_EXERCISE_NAMES) {
    assert.equal(n.includes('jump'), false, `hard list must not be extended: ${n}`);
  }
  assert.equal(isBodyweightExercise(null, 'Jump chin up'), false);
  assert.equal(isBodyweightExercise('unknown', 'Jump chin up', 'Body Weight'), true);
});

// ── 15. App/server parity of the catalogue type value ─────────────────────

test('the server catalogue type matches the app constant', () => {
  const fs = require('fs');
  const dart = fs.readFileSync('../lib/exercise_type.dart', 'utf8');
  const m = dart.match(/const String kBodyweightExerciseType = '([^']+)';/);
  assert.ok(m, 'kBodyweightExerciseType must be a plain string constant');
  assert.equal(m[1], BODYWEIGHT_EXERCISE_TYPE);
});

test('the app offers exactly this value in its Add Exercise dropdown', () => {
  const fs = require('fs');
  const dialog = fs.readFileSync('../lib/add_exercise_dialog.dart', 'utf8');
  assert.ok(dialog.includes(`'${BODYWEIGHT_EXERCISE_TYPE}'`),
    'the dropdown value and the classifier must be the same string');
});

// ── Row classification (snapshot, resolved map, fallbacks) ────────────────

test('rowIsBodyweight prefers the row\'s own type snapshot', () => {
  assert.equal(rowIsBodyweight(row(TYPED, TYPED_NAME, [], 'Body Weight')), true);
  assert.equal(rowIsBodyweight(row(TYPED, TYPED_NAME, [], 'Barbell')), false);
  assert.equal(rowIsBodyweight(row(TYPED, TYPED_NAME, [])), false);
});

test('rowIsBodyweight falls back to a resolved type map, by either casing', () => {
  const ex = row(TYPED, TYPED_NAME, []);
  assert.equal(rowIsBodyweight(ex, new Map([[TYPED, 'Body Weight']])), true);
  assert.equal(rowIsBodyweight(ex, { [TYPED]: 'Body Weight' }), true);
  assert.equal(rowIsBodyweight(row(TYPED_KEY, TYPED_NAME, []),
    new Map([[TYPED_KEY, 'Body Weight']])), true);
  assert.equal(rowIsBodyweight(ex, new Map([['other', 'Body Weight']])), false);
});

// ── 14. Raw stored-set validity ───────────────────────────────────────────

test('a stored 0 is valid ONLY for a bodyweight exercise', () => {
  assert.equal(isStoredWeightPerformed(0, true), true);
  assert.equal(isStoredWeightPerformed(0, false), false);
});

test('a negative stored weight is invalid everywhere', () => {
  assert.equal(isStoredWeightPerformed(-0.5, true), false);
  assert.equal(isStoredWeightPerformed(-0.5, false), false);
  assert.equal(isStoredWeightPerformed(-100, true), false);
});

test('absent and non-finite stored weights are never valid', () => {
  for (const v of [null, undefined, NaN, Infinity, -Infinity, '60']) {
    assert.equal(isStoredWeightPerformed(v, true), false, String(v));
  }
  assert.equal(isStoredWeightPerformed(60, true), true);
  assert.equal(isStoredWeightPerformed(60, false), true);
});

test('reps must remain positive whatever the weight', () => {
  assert.equal(isRawSetPerformed(0, 5, true), true);
  assert.equal(isRawSetPerformed(0, 0, true), false);
  assert.equal(isRawSetPerformed(0, -3, true), false);
  assert.equal(isRawSetPerformed(60, null, false), false);
});

// ── Day summaries: normalisation of a zero-added bodyweight set ───────────

test('a WES2 bodyweight set stored as 0 totals the recorded bodyweight', () => {
  const s = summarizeWorkoutDay(
    doc(row(TYPED, TYPED_NAME, [wes2(0, 8)], 'Body Weight')),
    { bodyweightKg: 82.5 },
  );
  assert.equal(s[TYPED_KEY].bestWeight, 82.5);
  assert.equal(s[TYPED_KEY].bestWeightReps, 8);
  assert.equal(s[TYPED_KEY].bodyweightKg, 82.5);
});

test('a WES2 bodyweight set stored positive totals bodyweight + added', () => {
  const s = summarizeWorkoutDay(
    doc(row(TYPED, TYPED_NAME, [wes2(20, 5)], 'Body Weight')),
    { bodyweightKg: 82.5 },
  );
  assert.equal(s[TYPED_KEY].bestWeight, 102.5);
});

test('a legacy bodyweight set keeps the existing normalisation', () => {
  // Typed added load is authoritative: 53.5 typed + 85 recorded = 138.5.
  const s = summarizeWorkoutDay(
    doc(row(CHIN, 'Chin-Up', [legacy(138.5, 53.5, 3)])), { bodyweightKg: 85 });
  assert.equal(s[CHIN.toLowerCase()].bestWeight, 138.5);
  // No typed added load → the stored value IS the total, unchanged.
  const t = summarizeWorkoutDay(
    doc(row(CHIN, 'Chin-Up', [{ weight: 138.5, reps: 3 }])), { bodyweightKg: 85 });
  assert.equal(t[CHIN.toLowerCase()].bestWeight, 138.5);
});

test('a non-bodyweight WES2 set stored as 0 remains excluded', () => {
  assert.deepEqual(
    summarizeWorkoutDay(doc(row(BENCH, 'Bench Press, Barbell', [wes2(0, 8)])),
      { bodyweightKg: 82.5 }),
    {},
  );
});

test('a NEGATIVE bodyweight stored weight remains excluded', () => {
  assert.deepEqual(
    summarizeWorkoutDay(
      doc(row(TYPED, TYPED_NAME, [wes2(-5, 8)], 'Body Weight')),
      { bodyweightKg: 82.5 }),
    {},
  );
});

test('a bodyweight set needing a weigh-in is excluded when none exists', () => {
  assert.deepEqual(
    summarizeWorkoutDay(
      doc(row(TYPED, TYPED_NAME, [wes2(0, 8)], 'Body Weight')),
      { bodyweightKg: null }),
    {},
    'omit rather than guess — no default bodyweight in historical analytics',
  );
});

test('a missing weight field is not "0 kg added"', () => {
  assert.deepEqual(
    summarizeWorkoutDay(
      doc(row(TYPED, TYPED_NAME, [{ setIndex: 0, reps: 8 }], 'Body Weight')),
      { bodyweightKg: 82.5 }),
    {},
  );
});

test('the coverage form counts a bodyweight-only day without a weigh-in', () => {
  // No `bodyweightKg` key at all → the RAW "which exercises were trained"
  // form, which must not start excluding bodyweight sets for want of a
  // weigh-in.
  const s = summarizeWorkoutDay(
    doc(row(TYPED, TYPED_NAME, [wes2(0, 8)], 'Body Weight')));
  assert.equal(Object.keys(s).length, 1);
  assert.equal(s[TYPED_KEY].bestWeight, 0, 'raw form reads the stored value');
});

test('16. a non-bodyweight day summarises exactly as before', () => {
  const s = summarizeWorkoutDay(
    doc(row(BENCH, 'Bench Press, Barbell', [wes2(100, 5), wes2(110, 5, 1)])),
    { bodyweightKg: 82.5 });
  assert.equal(s[BENCH.toLowerCase()].bestWeight, 110);
  assert.equal(s[BENCH.toLowerCase()].bodyweightKg, undefined);
});

// ── hasBodyweightExercise decides whether a weigh-in lookup is needed ─────

test('hasBodyweightExercise sees a type snapshot and a resolved map', () => {
  const d = doc(row(TYPED, TYPED_NAME, [wes2(0, 8)]));
  assert.equal(hasBodyweightExercise(d), false);
  assert.equal(hasBodyweightExercise(d, new Map([[TYPED, 'Body Weight']])), true);
  assert.equal(
    hasBodyweightExercise(doc(row(TYPED, TYPED_NAME, [wes2(0, 8)], 'Body Weight'))),
    true);
  assert.equal(hasBodyweightExercise(doc(row(CHIN, 'Chin-Up', []))), true,
    'the hard-coded catalogue still answers');
});

// ── 12. Coach adherence / completed-workout-day detection ────────────────

test('12. a zero-added bodyweight day counts as a completed workout', () => {
  assert.equal(
    hasCompletedSets(doc(row(TYPED, TYPED_NAME, [wes2(0, 6)], 'Body Weight'))),
    true);
  assert.equal(
    hasCompletedSets(doc(row(TYPED, TYPED_NAME, [wes2(0, 6)])),
      new Map([[TYPED, 'Body Weight']])),
    true, 'a historical row resolves its type at the adapter boundary');
  assert.equal(hasCompletedSets(doc(row(CHIN, 'Chin-Up', [wes2(0, 6)]))), true);
});

test('a zero-weight ORDINARY day is still not a completed workout', () => {
  assert.equal(
    hasCompletedSets(doc(row(BENCH, 'Bench Press, Barbell', [wes2(0, 6)]))),
    false);
});

test('a negative bodyweight day is not a completed workout', () => {
  assert.equal(
    hasCompletedSets(doc(row(TYPED, TYPED_NAME, [wes2(-10, 6)], 'Body Weight'))),
    false);
  assert.equal(
    hasCompletedSets(doc(row(TYPED, TYPED_NAME, [wes2(0, 0)], 'Body Weight'))),
    false, 'reps must remain positive');
});

test('16. an ordinary positive day still counts (unchanged)', () => {
  assert.equal(
    hasCompletedSets(doc(row(BENCH, 'Bench Press, Barbell', [wes2(100, 5)]))),
    true);
  assert.equal(hasCompletedSets({}), false);
  assert.equal(hasCompletedSets({ exercises: [] }), false);
});

// ── 13. Coach PB analytics over a zero-added bodyweight stream ───────────

test('13. a zero-added bodyweight day produces PB events at the total load',
  async () => {
    const entries = [weighIn('2026-08-01', 80)];
    const { store } = storeWith(entries, { [TYPED]: 'Body Weight' });
    // Baseline day, then a bodyweight-only day at a HEAVIER bodyweight.
    await applyWorkoutDay(store, '2026-08-05',
      doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight')));
    await store.flush();
    const c2 = storeWith([weighIn('2026-08-01', 80), weighIn('2026-08-10', 84)],
      { [TYPED]: 'Body Weight' });
    await bulkRebuild(c2.store, [
      ['2026-08-05', doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight'))],
      ['2026-08-12', doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight'))],
    ]);
    await c2.store.flush();
    const summary = c2.summaries.get(TYPED_KEY);
    assert.ok(summary, 'the stream exists');
    assert.equal(summary.maxWeight.weightKg, 84,
      'the second day is heavier because the athlete weighs more');
    const events = [...c2.events.values()];
    assert.ok(events.some((e) => e.type === 'maxWeightPB' && e.weightKg === 84),
      'a bodyweight-only session can set a PB');
    assert.ok(events.every((e) => e.dateKey === '2026-08-12'),
      'the baseline day itself never publishes an event');
  });

test('13. a bodyweight stream with no weigh-ins publishes nothing', async () => {
  const c = storeWith([], { [TYPED]: 'Body Weight' });
  await bulkRebuild(c.store, [
    ['2026-08-05', doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight'))],
    ['2026-08-12', doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight'))],
  ]);
  await c.store.flush();
  assert.deepEqual([...c.summaries.keys()], []);
  assert.deepEqual([...c.events.keys()], []);
});

test('13. an ordinary exercise\'s zero-weight day still publishes nothing',
  async () => {
    const c = storeWith([weighIn('2026-08-01', 80)]);
    await bulkRebuild(c.store, [
      ['2026-08-05', doc(row(BENCH, 'Bench Press, Barbell', [wes2(0, 5)]))],
      ['2026-08-12', doc(row(BENCH, 'Bench Press, Barbell', [wes2(0, 5)]))],
    ]);
    await c.store.flush();
    assert.deepEqual([...c.summaries.keys()], []);
  });

test('the workout, weigh-in and bulk paths agree on one day', async () => {
  const entries = [weighIn('2026-08-01', 80)];
  const data = doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight'));
  const a = storeWith(entries, { [TYPED]: 'Body Weight' });
  await applyWorkoutDay(a.store, '2026-08-05', data);
  await a.store.flush();
  const b = storeWith(entries, { [TYPED]: 'Body Weight' });
  await bulkRebuild(b.store, [['2026-08-05', data]]);
  await b.store.flush();
  assert.deepEqual(snapshotOf(a), snapshotOf(b));
});

test('a historical row with no snapshot matches one that carries it', async () => {
  const entries = [weighIn('2026-08-01', 80)];
  const withSnapshot = doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight'));
  const without = doc(row(TYPED, TYPED_NAME, [wes2(0, 5)]));
  const a = storeWith(entries, { [TYPED]: 'Body Weight' });
  await bulkRebuild(a.store, [['2026-08-05', withSnapshot]]);
  await a.store.flush();
  const b = storeWith(entries, { [TYPED]: 'Body Weight' });
  await bulkRebuild(b.store, [['2026-08-05', without]]);
  await b.store.flush();
  assert.deepEqual(snapshotOf(a), snapshotOf(b));
});

// ── 10. Showcase: a bodyweight-loaded slot accepts a stored 0 ────────────

test('10. the chin-up slot accepts a stored 0 (0 kg added)', () => {
  const out = extractBigFiveSets(doc(row(CHIN, 'Chin-Up', [wes2(0, 5)])));
  assert.equal(out.chinUp.length, 1);
  assert.equal(out.chinUp[0].weight, 0);
  assert.equal(out.chinUp[0].basis, 'added');
});

test('an ordinary slot still rejects a stored 0, and 0 is rejected negative', () => {
  assert.deepEqual(
    extractBigFiveSets(doc(row(BENCH, 'Bench Press, Barbell', [wes2(0, 5)]))), {});
  assert.deepEqual(extractBigFiveSets(doc(row(CHIN, 'Chin-Up', [wes2(-5, 5)]))), {});
});

test('16. an ordinary positive showcase set is unchanged', () => {
  const out = extractBigFiveSets(
    doc(row(BENCH, 'Bench Press, Barbell', [wes2(100, 5)])));
  assert.equal(out.bench[0].weight, 100);
  assert.equal(out.bench[0].basis, undefined);
});

// ── 6. The bounded exercise-type boundary ───────────────────────────────

test('id collection is distinct and skips rows with no id', () => {
  const d = doc(
    row(TYPED, TYPED_NAME, []),
    row(TYPED, TYPED_NAME, []),
    { name: 'no id', sets: [] },
    { id: BENCH, name: 'legacy id field', sets: [] },
  );
  assert.deepEqual(exerciseIdsIn(d).sort(), [BENCH, TYPED].sort());
});

test('only rows WITHOUT a snapshot need a catalogue lookup', () => {
  const d = doc(
    row(TYPED, TYPED_NAME, [], 'Body Weight'),
    row(BENCH, 'Bench Press, Barbell', []),
  );
  assert.deepEqual(untypedExerciseIdsIn(d), [BENCH]);
  assert.deepEqual([...typesFromRows(d)], [[TYPED, 'Body Weight']]);
});

test('the resolver reads /exercises first, then the athlete\'s custom pool',
  async () => {
    const reads = [];
    const db = fakeDb(reads, {
      [`exercises/${BENCH}`]: { type: 'Barbell' },
      [`users/u1/customExercises/${TYPED}`]: { type: 'Body Weight' },
    });
    const r = makeExerciseTypeResolver(db, 'u1');
    const out = await r.resolve([BENCH, TYPED, 'nowhere']);
    assert.equal(out.get(BENCH), 'Barbell');
    assert.equal(out.get(TYPED), 'Body Weight');
    assert.equal(out.has('nowhere'), false);
    assert.ok(reads.includes(`exercises/${BENCH}`));
    assert.ok(reads.includes(`users/u1/customExercises/${TYPED}`));
    assert.equal(reads.includes(`users/u1/customExercises/${BENCH}`), false,
      'a global hit must not also read the custom pool');
  });

test('the resolver caches, including negative results', async () => {
  const reads = [];
  const db = fakeDb(reads, { [`exercises/${BENCH}`]: { type: 'Barbell' } });
  const r = makeExerciseTypeResolver(db, 'u1');
  await r.resolve([BENCH, 'nowhere']);
  const first = reads.length;
  await r.resolve([BENCH, 'nowhere']);
  await r.resolve([BENCH, 'nowhere']);
  assert.equal(reads.length, first, 'no exercise document is read twice');
});

test('forWorkout reads nothing for rows that carry their own snapshot',
  async () => {
    const reads = [];
    const r = makeExerciseTypeResolver(fakeDb(reads, {}), 'u1');
    const out = await r.forWorkout(
      doc(row(TYPED, TYPED_NAME, [], 'Body Weight')));
    assert.equal(out.get(TYPED), 'Body Weight');
    assert.deepEqual(reads, [], 'a snapshotted row costs no Firestore read');
  });

test('forWorkout resolves only the ids that lack a snapshot', async () => {
  const reads = [];
  const db = fakeDb(reads, { [`exercises/${BENCH}`]: { type: 'Barbell' } });
  const r = makeExerciseTypeResolver(db, 'u1');
  const out = await r.forWorkout(doc(
    row(TYPED, TYPED_NAME, [], 'Body Weight'),
    row(BENCH, 'Bench Press, Barbell', []),
  ));
  assert.equal(out.get(TYPED), 'Body Weight');
  assert.equal(out.get(BENCH), 'Barbell');
  assert.deepEqual(reads, [`exercises/${BENCH}`]);
});

test('a blank or non-string catalogue type resolves to "no type"', async () => {
  const reads = [];
  const db = fakeDb(reads, {
    'exercises/a': { type: '   ' },
    'exercises/b': { type: 42 },
    'exercises/c': {},
  });
  const r = makeExerciseTypeResolver(db, 'u1');
  const out = await r.resolve(['a', 'b', 'c']);
  assert.equal(out.size, 0);
});

test('a store with no type boundary falls back to the row snapshots', async () => {
  // Exactly the pre-existing behaviour for every deployment that has not
  // implemented getExerciseTypesFor.
  const c = storeWith([weighIn('2026-08-01', 80)]);
  assert.equal(typeof c.store.getExerciseTypesFor, 'undefined');
  await applyWorkoutDay(c.store, '2026-08-05',
    doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight')));
  await c.store.flush();
  assert.ok(c.summaries.get(TYPED_KEY), 'the snapshot alone suffices');
});

/** A minimal Firestore double: getAll over doc refs, recording every path. */
function fakeDb(reads, docs) {
  const ref = (path) => ({ path });
  return {
    collection: (c) => ({
      doc: (id) => ({
        path: `${c}/${id}`,
        collection: (sub) => ({ doc: (sid) => ref(`${c}/${id}/${sub}/${sid}`) }),
      }),
    }),
    async getAll(...refs) {
      return refs.map((r) => {
        reads.push(r.path);
        const data = docs[r.path];
        return { exists: data !== undefined, data: () => data };
      });
    },
  };
}

// ── deriveExerciseEvents is still pure over already-normalised days ───────

test('deriveExerciseEvents needs no type context of its own', () => {
  const d = summarizeWorkoutDay(
    doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight')),
    { bodyweightKg: 80 });
  const out = deriveExerciseEvents(TYPED_KEY, {
    '2026-08-05': d[TYPED_KEY],
    '2026-08-12': summarizeWorkoutDay(
      doc(row(TYPED, TYPED_NAME, [wes2(0, 5)], 'Body Weight')),
      { bodyweightKg: 84 })[TYPED_KEY],
  });
  assert.equal(out.maxWeight.weightKg, 84);
  assert.equal(out.dayCount, 2);
});
