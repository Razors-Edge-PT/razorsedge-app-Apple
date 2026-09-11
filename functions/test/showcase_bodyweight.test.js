'use strict';

// Bodyweight context for the Chin-Up showcase record.
//
// The profile shows a Chin-Up as the ADDED load ("+53.5 kg × 3, at 85 kg
// BW"). These tests pin what the server publishes to make that possible — the
// basis of the stored load and the bodyweight for each record's OWN date — and,
// just as important, that none of it changes which set holds a record, the
// record itself, or its fingerprint.

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'goodlift-us-storage';
process.env.FUNCTIONS_EMULATOR = 'true';

const { BIG_FIVE } = require('../showcase/big_five');
const bw = require('../showcase/bodyweight');
const {
  extractBigFiveSets,
  summarizeWorkoutDay,
  buildShowcase,
} = require('../showcase/reducer');
const {
  applyWorkoutDay,
  rebuildAll,
  refreshBodyweight,
  memoryStore,
  sameDay,
} = require('../showcase/store');

const CHIN = 'XM9026peNIu0R8qh7UqY';
const BENCH = 'AmfUWbF1DH3I7qPAdh5k';

function workout(exerciseId, sets) {
  return { exercises: [{ exerciseId, name: 'x', sets }] };
}

/** Device-local noon in Auckland in winter (NZST, UTC+12) — 00:00 UTC. */
function nzNoon(dateKey) {
  const [y, m, d] = dateKey.split('-').map(Number);
  return Date.UTC(y, m - 1, d, 0, 0, 0);
}

function weighIn(dateKey, weight, extra) {
  return Object.assign(
    { id: `w-${dateKey}-${weight}`, weight, unit: 'kg', tsMillis: nzNoon(dateKey) },
    extra || {},
  );
}

/** A resolver over a fixed weigh-in list, counting how often it is asked. */
function resolverOver(entries) {
  const calls = [];
  const fn = async (dateKey) => {
    calls.push(dateKey);
    return bw.pickBodyweightAsOf(entries, dateKey);
  };
  fn.calls = calls;
  return fn;
}

// ── Which lifts ─────────────────────────────────────────────────────────────

test('only the Chin-Up is bodyweight-loaded', () => {
  assert.deepEqual(
    BIG_FIVE.filter((l) => l.bodyweightLoaded).map((l) => l.slot),
    ['chinUp'],
  );
  assert.equal(bw.isBodyweightSlot('chinUp'), true);
  for (const slot of ['bench', 'squat', 'deadlift', 'ohpUnilateral', 'nope']) {
    assert.equal(bw.isBodyweightSlot(slot), false, slot);
  }
});

// ── Load basis ──────────────────────────────────────────────────────────────

test('a set stamped with setIndex (WES2) is added load; any other set is absolute', () => {
  assert.equal(bw.setLoadBasis({ setIndex: 0, weight: 20 }), 'added');
  assert.equal(bw.setLoadBasis({ setIndex: 3 }), 'added');
  assert.equal(bw.setLoadBasis({ weight: 138.5 }), 'absolute');
  assert.equal(bw.setLoadBasis({ setIndex: '1' }), 'absolute');
  assert.equal(bw.setLoadBasis({ setIndex: Number.NaN }), 'absolute');
  assert.equal(bw.setLoadBasis(null), 'absolute');
});

test('Chin-Up sets carry their basis; every other lift keeps its exact shape', () => {
  const day = {
    exercises: [
      { exerciseId: CHIN, name: 'Chin-Up', sets: [
        { weight: 138.5, reps: 3 },
        { setIndex: 1, weight: 20, reps: 5 },
      ] },
      { exerciseId: BENCH, name: 'Bench', sets: [
        { setIndex: 0, weight: 100, reps: 5 },
      ] },
    ],
  };
  const sets = extractBigFiveSets(day);
  assert.deepEqual(sets.chinUp.map((s) => s.basis), ['absolute', 'added']);
  // Byte-for-byte what bench produced before bodyweight context existed.
  assert.deepEqual(sets.bench, [{ setKey: 's0', weight: 100, reps: 5 }]);

  const summary = summarizeWorkoutDay('2026-06-01', day);
  assert.deepEqual(Object.keys(summary.bench.bestE1rm), ['setKey', 'weight', 'reps']);
  assert.equal(summary.chinUp.heaviest.basis, 'absolute');
});

test('the basis never changes which set holds a record, or its fingerprint', () => {
  const legacy = {
    '2026-06-01': workout(CHIN, [{ weight: 138.5, reps: 3 }, { weight: 142, reps: 2 }]),
    '2026-06-08': workout(CHIN, [{ weight: 130, reps: 6 }]),
    '2026-06-09': workout(BENCH, [{ weight: 120, reps: 3 }]),
  };
  // Identical performances, as WES2 would have stamped them.
  const stamped = JSON.parse(JSON.stringify(legacy));
  for (const date of Object.keys(stamped)) {
    stamped[date].exercises[0].sets.forEach((s, i) => { s.setIndex = i; });
  }
  const a = buildShowcase(legacy);
  const b = buildShowcase(stamped);
  assert.deepEqual(bw.stripBodyweightAnnotations(a), bw.stripBodyweightAnnotations(b));
  assert.equal(a.lifts.chinUp.e1rm.fingerprint, b.lifts.chinUp.e1rm.fingerprint);
  assert.equal(a.lifts.chinUp.heaviest.fingerprint, b.lifts.chinUp.heaviest.fingerprint);
  assert.equal(a.lifts.chinUp.e1rm.loadBasis, 'absolute');
  assert.equal(b.lifts.chinUp.e1rm.loadBasis, 'added');
  // Bench records carry no bodyweight field at all.
  assert.equal('loadBasis' in a.lifts.bench.e1rm, false);
});

// ── Which bodyweight ────────────────────────────────────────────────────────

test('the bodyweight for a lift is the latest weigh-in on or before its date', () => {
  const entries = [
    weighIn('2026-05-20', 86),
    weighIn('2026-05-30', 85),
    weighIn('2026-06-02', 84), // after the lift: never used for it
  ];
  assert.deepEqual(bw.pickBodyweightAsOf(entries, '2026-06-01'), {
    weightKg: 85,
    dateKey: '2026-05-30',
  });
  // A weigh-in ON the lift's own day counts.
  assert.deepEqual(bw.pickBodyweightAsOf(entries, '2026-06-02'), {
    weightKg: 84,
    dateKey: '2026-06-02',
  });
  // Nothing on or before the date is "not recorded", not today's value.
  assert.equal(bw.pickBodyweightAsOf(entries, '2026-05-01'), null);
  assert.equal(bw.pickBodyweightAsOf([], '2026-06-01'), null);
});

test('on the chosen day AM beats PM, a missing time of day is AM, then the latest stamp', () => {
  const day = '2026-06-10';
  assert.equal(bw.pickBodyweightAsOf([
    weighIn(day, 86, { tod: 'pm' }),
    weighIn(day, 85, { tod: 'am' }),
  ], day).weightKg, 85);
  assert.equal(bw.pickBodyweightAsOf([
    weighIn(day, 86, { tod: 'pm' }),
    weighIn(day, 84.6),
  ], day).weightKg, 84.6);
  assert.equal(bw.pickBodyweightAsOf([
    weighIn(day, 85, { id: 'a', tsMillis: nzNoon(day) }),
    weighIn(day, 84, { id: 'b', tsMillis: nzNoon(day) + 1000 }),
  ], day).weightKg, 84);
  // Fully tied entries resolve by id, so the answer never depends on read order.
  const tied = [weighIn(day, 85, { id: 'b' }), weighIn(day, 84, { id: 'a' })];
  assert.equal(bw.pickBodyweightAsOf(tied, day).weightKg, 84);
  assert.equal(bw.pickBodyweightAsOf([...tied].reverse(), day).weightKg, 84);
});

test('pound, invalid and unstamped weigh-ins are ignored', () => {
  const day = '2026-06-10';
  const entries = [
    weighIn('2026-06-01', 85),
    weighIn(day, 190, { unit: 'lb' }),
    weighIn(day, 0),
    weighIn(day, -3),
    weighIn(day, Number.NaN),
    Object.assign(weighIn(day, 99), { tsMillis: undefined }),
  ];
  assert.deepEqual(bw.pickBodyweightAsOf(entries, day), {
    weightKg: 85,
    dateKey: '2026-06-01',
  });
  // A missing unit is kilograms, as BodyWeightTracker treats it.
  assert.equal(
    bw.pickBodyweightAsOf([weighIn(day, 83, { unit: undefined })], day).weightKg,
    83,
  );
});

test('a weigh-in is dated in Auckland, which can make it look later but never earlier', () => {
  // 23:30 NZST on 10 June — still the 10th.
  const lateOnTenth = { id: 'x', weight: 85, unit: 'kg', tsMillis: Date.UTC(2026, 5, 10, 11, 30) };
  // 00:30 NZST on 11 June — the 11th, so not available to a lift on the 10th.
  const earlyOnEleventh = { id: 'y', weight: 90, unit: 'kg', tsMillis: Date.UTC(2026, 5, 10, 12, 30) };
  assert.equal(bw.pickBodyweightAsOf([lateOnTenth, earlyOnEleventh], '2026-06-10').weightKg, 85);

  // Noon in Los Angeles on 11 June is the 12th in Auckland: never mistaken
  // for a weigh-in from before a lift on the 11th.
  const laNoonEleventh = { id: 'z', weight: 70, unit: 'kg', tsMillis: Date.UTC(2026, 5, 11, 19, 0) };
  assert.equal(bw.pickBodyweightAsOf([laNoonEleventh], '2026-06-11'), null);
  // Noon in London on 10 June is still the 10th in Auckland.
  const londonNoon = { id: 'l', weight: 72, unit: 'kg', tsMillis: Date.UTC(2026, 5, 10, 11, 0) };
  assert.equal(bw.pickBodyweightAsOf([londonNoon], '2026-06-10').weightKg, 72);
});

test('the query bound covers every weigh-in dated on or before the lift day', () => {
  assert.equal(bw.bodyweightCutoffMillis('2026-06-10'), Date.UTC(2026, 5, 11));
  // The latest instant still dated the 10th in Auckland is before the bound.
  assert.ok(Date.UTC(2026, 5, 10, 11, 59, 59) < bw.bodyweightCutoffMillis('2026-06-10'));
});

// ── Publishing ──────────────────────────────────────────────────────────────

const HISTORY = {
  // Best E1RM: 138.5 × 3 → 146.6 (legacy total, bodyweight 85 that day).
  '2026-06-01': workout(CHIN, [{ weight: 138.5, reps: 3 }]),
  // Heaviest: 142 × 2 (bodyweight 83.4 by then).
  '2026-06-15': workout(CHIN, [{ weight: 142, reps: 2 }]),
  '2026-06-16': workout(BENCH, [{ weight: 120, reps: 3 }]),
};
const WEIGH_INS = [weighIn('2026-05-31', 85), weighIn('2026-06-14', 83.4)];

test('each Chin-Up record carries the bodyweight for its own date', async () => {
  const store = memoryStore({ bodyweightAsOf: resolverOver(WEIGH_INS) });
  for (const d of Object.keys(HISTORY)) await applyWorkoutDay(store, d, HISTORY[d]);
  const chin = (await store.getSnapshot()).lifts.chinUp;

  assert.equal(chin.e1rm.dateKey, '2026-06-01');
  assert.equal(chin.e1rm.bodyweightKg, 85);
  assert.equal(chin.e1rm.bodyweightDateKey, '2026-05-31');
  assert.equal(chin.e1rm.loadBasis, 'absolute');

  assert.equal(chin.heaviest.dateKey, '2026-06-15');
  assert.equal(chin.heaviest.bodyweightKg, 83.4);
  assert.equal(chin.heaviest.bodyweightDateKey, '2026-06-14');
});

test('annotation changes nothing about the records themselves', async () => {
  const store = memoryStore({ bodyweightAsOf: resolverOver(WEIGH_INS) });
  for (const d of Object.keys(HISTORY)) await applyWorkoutDay(store, d, HISTORY[d]);
  const published = await store.getSnapshot();
  const pure = buildShowcase(HISTORY);

  assert.deepEqual(bw.stripBodyweightAnnotations(published), bw.stripBodyweightAnnotations(pure));
  // Stored values are the canonical system loads, untouched.
  assert.equal(published.lifts.chinUp.e1rm.weight, 138.5);
  assert.equal(published.lifts.chinUp.heaviest.weight, 142);
  assert.equal(published.lifts.chinUp.e1rm.fingerprint, pure.lifts.chinUp.e1rm.fingerprint);
  // Bench is published exactly as before.
  assert.deepEqual(published.lifts.bench, pure.lifts.bench);
});

test('a lift with no weigh-in on or before it publishes no bodyweight, and says nothing else', async () => {
  const store = memoryStore({ bodyweightAsOf: resolverOver([weighIn('2026-07-01', 80)]) });
  await applyWorkoutDay(store, '2026-06-01', HISTORY['2026-06-01']);
  const r = (await store.getSnapshot()).lifts.chinUp.e1rm;
  assert.equal(r.loadBasis, 'absolute');
  assert.equal('bodyweightKg' in r, false);
  assert.equal('bodyweightDateKey' in r, false);
});

test('a store that cannot resolve bodyweight publishes exactly the reducer output', async () => {
  const store = memoryStore();
  for (const d of Object.keys(HISTORY)) await applyWorkoutDay(store, d, HISTORY[d]);
  assert.deepEqual(await store.getSnapshot(), buildShowcase(HISTORY));
});

test('a write that touches only another lift does not look bodyweight up again', async () => {
  const resolve = resolverOver(WEIGH_INS);
  const store = memoryStore({ bodyweightAsOf: resolve });
  await applyWorkoutDay(store, '2026-06-01', HISTORY['2026-06-01']);
  const asked = resolve.calls.length;
  await applyWorkoutDay(store, '2026-06-16', HISTORY['2026-06-16']);
  assert.equal(resolve.calls.length, asked);
  assert.equal((await store.getSnapshot()).lifts.chinUp.e1rm.bodyweightKg, 85);
});

test('retries and duplicate deliveries converge on the same annotated snapshot', async () => {
  const store = memoryStore({ bodyweightAsOf: resolverOver(WEIGH_INS) });
  for (const d of Object.keys(HISTORY)) await applyWorkoutDay(store, d, HISTORY[d]);
  const before = JSON.stringify(await store.getSnapshot());
  const again = await applyWorkoutDay(store, '2026-06-15', HISTORY['2026-06-15']);
  assert.equal(again.path, 'noop');
  assert.equal(JSON.stringify(await store.getSnapshot()), before);
});

test('rebuildAll annotates exactly as the incremental path does', async () => {
  const incremental = memoryStore({ bodyweightAsOf: resolverOver(WEIGH_INS) });
  for (const d of Object.keys(HISTORY)) await applyWorkoutDay(incremental, d, HISTORY[d]);
  const rebuilt = memoryStore({ bodyweightAsOf: resolverOver(WEIGH_INS) });
  const snap = await rebuildAll(rebuilt, Object.entries(HISTORY));
  assert.deepEqual(snap, await incremental.getSnapshot());
});

test('a day stored before sets carried a basis is rewritten on its next save', () => {
  const stored = { slot: 'chinUp', dateKey: '2026-06-01', exerciseId: CHIN,
    bestE1rm: { setKey: 's0', weight: 138.5, reps: 3 },
    heaviest: { setKey: 's0', weight: 138.5, reps: 3 } };
  const fresh = summarizeWorkoutDay('2026-06-01', HISTORY['2026-06-01']).chinUp;
  assert.equal(sameDay(stored, fresh), false);
  assert.equal(sameDay(fresh, JSON.parse(JSON.stringify(fresh))), true);
  const bench = summarizeWorkoutDay('2026-06-16', HISTORY['2026-06-16']).bench;
  assert.equal(sameDay(bench, JSON.parse(JSON.stringify(bench))), true);
});

// ── Later weigh-ins ─────────────────────────────────────────────────────────

test('a weigh-in logged after the workout, for that day, updates only the bodyweight', async () => {
  const entries = [weighIn('2026-05-20', 86)];
  const store = memoryStore({ bodyweightAsOf: resolverOver(entries) });
  await applyWorkoutDay(store, '2026-06-01', HISTORY['2026-06-01']);
  assert.equal((await store.getSnapshot()).lifts.chinUp.e1rm.bodyweightKg, 86);

  entries.push(weighIn('2026-06-01', 85)); // trained, then weighed in
  const before = await store.getSnapshot();
  const r = await refreshBodyweight(store);
  assert.equal(r.changed, true);
  const after = await store.getSnapshot();
  assert.equal(after.lifts.chinUp.e1rm.bodyweightKg, 85);
  assert.equal(after.lifts.chinUp.e1rm.bodyweightDateKey, '2026-06-01');
  assert.deepEqual(bw.stripBodyweightAnnotations(after), bw.stripBodyweightAnnotations(before));

  // A second delivery of the same weigh-in writes nothing.
  assert.deepEqual(await refreshBodyweight(store), { changed: false, reason: 'unchanged' });
});

test('a weigh-in after the lift date never becomes that lift\'s bodyweight', async () => {
  const entries = [weighIn('2026-05-20', 86)];
  const store = memoryStore({ bodyweightAsOf: resolverOver(entries) });
  await applyWorkoutDay(store, '2026-06-01', HISTORY['2026-06-01']);
  entries.push(weighIn('2026-06-05', 80));
  assert.deepEqual(await refreshBodyweight(store), { changed: false, reason: 'unchanged' });
  assert.equal((await store.getSnapshot()).lifts.chinUp.e1rm.bodyweightKg, 86);
});

test('refresh does nothing for an account without a Chin-Up record, or a stale snapshot', async () => {
  const resolve = resolverOver(WEIGH_INS);
  const benchOnly = memoryStore({ bodyweightAsOf: resolve });
  assert.deepEqual(await refreshBodyweight(benchOnly), { changed: false, reason: 'no-snapshot' });
  await applyWorkoutDay(benchOnly, '2026-06-16', HISTORY['2026-06-16']);
  assert.deepEqual(await refreshBodyweight(benchOnly), { changed: false, reason: 'no-bodyweight-lift' });
  assert.equal(resolve.calls.length, 0);

  const stale = memoryStore({ bodyweightAsOf: resolve });
  await stale.setSnapshot(Object.assign(buildShowcase(HISTORY), { formulaVersion: -1 }));
  assert.deepEqual(await refreshBodyweight(stale), { changed: false, reason: 'stale-version' });
  assert.deepEqual(await refreshBodyweight(memoryStore()), { changed: false, reason: 'no-resolver' });
});

test('annotation leaves other slots as the very same objects', async () => {
  const lifts = buildShowcase(HISTORY).lifts;
  const out = await bw.annotateLifts(lifts, resolverOver(WEIGH_INS));
  assert.equal(out.bench, lifts.bench);
  assert.notEqual(out.chinUp, lifts.chinUp);
  // The input is not mutated.
  assert.equal('bodyweightKg' in lifts.chinUp.e1rm, false);
});

test('stripping annotations restores the pre-annotation snapshot', async () => {
  const store = memoryStore({ bodyweightAsOf: resolverOver(WEIGH_INS) });
  const annotated = await rebuildAll(store, Object.entries(HISTORY));
  const stripped = bw.stripBodyweightAnnotations(annotated);
  for (const kind of ['e1rm', 'heaviest']) {
    for (const f of bw.ANNOTATION_FIELDS) {
      assert.equal(f in stripped.lifts.chinUp[kind], false, `${kind}.${f}`);
    }
  }
  assert.equal(annotated.lifts.chinUp.e1rm.bodyweightKg, 85, 'input untouched');
});

// ── Deployment surface ──────────────────────────────────────────────────────

test('index.js exports the weigh-in trigger beside the workout trigger', () => {
  const idx = require('../index');
  assert.ok(idx.showcaseOnWorkoutWrite, 'showcaseOnWorkoutWrite missing');
  assert.ok(idx.showcaseOnWeightWrite, 'showcaseOnWeightWrite missing');
});
