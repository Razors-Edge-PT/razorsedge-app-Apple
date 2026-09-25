'use strict';

// profileShowcaseV2: categories, per-exercise records and RE Points.

const test = require('node:test');
const assert = require('node:assert');

const {
  applyWorkoutDayV2,
  refreshV2,
  memoryStoreV2,
  dayDocIdV2,
} = require('../showcase/store_v2');
const {
  buildShowcaseV2,
  selectDefaultExerciseId,
  liveFingerprintsV2,
  PROFILE_SHOWCASE_V2_SCHEMA,
} = require('../showcase/reducer_v2');
const { buildShowcase } = require('../showcase/reducer');
const { showcaseE1rm } = require('../showcase/e1rm_spec');
const { pickBodyweightAsOf } = require('../showcase/bodyweight');
const { reCoefficient, Sex, RE_POINTS_FORMULA_VERSION } = require('../showcase/re_points');
const { parseArgs, sameSnapshotV2 } = require('../scripts/backfill_profile_showcase_v2');

const ID = {
  bench: 'AmfUWbF1DH3I7qPAdh5k',
  dbBench: 'kTs5fLSTKjUkUZL10iii',
  chin: 'XM9026peNIu0R8qh7UqY',
  lat: '1XOIXxeLFhgmgjZS9Cyq',
  ohpDb: 'RdsGazgdH0xgpjek0n3u',
  ohpBb: 'lVDG90yN6Z8aPjRNV2wc',
  dip: 'FtayDmR5BVnGS1FXlXLL',
  deadlift: 'MsGl7e9yanDeEnYX0e4X',
  sumo: '10pEctikt6PP8eAg9Eip',
  hipThrust: 'LGhFj8o0sG3X12296UAh',
  squat: 'heeBViVINHO6tUScSd6y',
  bssDb: 'ISXQqOEXLjMrPEs0xjgJ',
  bssBb: 'VUEvvjuo4cxBghNuux66',
};

function row(exerciseId, sets) {
  return { exerciseId, name: 'x', sets };
}
function workout(...rows) {
  return { exercises: rows };
}
/** Weigh-ins → a bodyweightAsOf(dateKey) resolver with the triggers' rule. */
function weighIns(list) {
  const entries = list.map(([dateKey, weight], i) => ({ id: `w${i}`, dateKey, weight }));
  const fn = (dateKey) => pickBodyweightAsOf(entries, dateKey);
  fn.entries = entries;
  return fn;
}
function bwByDateFor(history, resolver) {
  const out = {};
  for (const d of Object.keys(history)) out[d] = resolver(d);
  return out;
}
function pts(e1rm, factor, bw, sex) {
  return Number((e1rm * factor * reCoefficient(sex || Sex.MALE, bw)).toFixed(4));
}
function entry(snapshot, category, exerciseId) {
  return snapshot.categories[category].exercises[exerciseId];
}
async function applyAll(store, order, history) {
  for (const d of order) await applyWorkoutDayV2(store, d, history[d]);
  return store.getSnapshot();
}

// ── Load semantics ──────────────────────────────────────────────────────────

test('flat DB bench and DB Bulgarian split squat do NOT double the stored load', () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const history = {
    '2026-01-02': workout(
      row(ID.dbBench, [{ weight: 40, reps: 1 }]),
      row(ID.bssDb, [{ weight: 30, reps: 1 }]),
    ),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw), sex: Sex.MALE });
  const db = entry(snap, 'horizontalPress', ID.dbBench);
  assert.strictEqual(db.e1rm.weight, 40);
  assert.strictEqual(db.e1rm.e1rm, 40);
  assert.strictEqual(db.rePoints, pts(40, 2.35, 80));
  const bss = entry(snap, 'squatPattern', ID.bssDb);
  assert.strictEqual(bss.e1rm.e1rm, 30);
  assert.strictEqual(bss.rePoints, pts(30, 2.5, 80));
});

test('barbell Bulgarian split squat uses the full recorded barbell load', () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const history = { '2026-01-02': workout(row(ID.bssBb, [{ weight: 100, reps: 1 }])) };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw), sex: Sex.MALE });
  const bss = entry(snap, 'squatPattern', ID.bssBb);
  assert.strictEqual(bss.e1rm.e1rm, 100);
  assert.strictEqual(bss.factor, 1.25);
  assert.strictEqual(bss.rePoints, pts(100, 1.25, 80));
});

test('unilateral DB OHP scores with 2.61; E1RM uses the existing curve, RIR ignored', () => {
  const bw = weighIns([['2026-01-01', 85]]);
  const history = {
    '2026-01-02': workout(row(ID.ohpDb, [{ weight: 30, reps: 5, rir: 3 }])),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  const e = entry(snap, 'overheadPress', ID.ohpDb);
  assert.strictEqual(e.e1rm.e1rm, showcaseE1rm(30, 5));
  assert.strictEqual(e.rePoints, pts(showcaseE1rm(30, 5), 2.61, 85));
});

// ── Bodyweight-loaded: Chin-Up and Triceps Dip share one path ───────────────

for (const [label, id, category, factor] of [
  ['Chin-Up', ID.chin, 'verticalPull', 1.0],
  ['Triceps Dip', ID.dip, 'overheadPress', 0.73],
]) {
  test(`${label}: weighted WES2 set scores the combined bodyweight + added load`, () => {
    const bw = weighIns([['2026-01-01', 80]]);
    const history = {
      '2026-01-02': workout(row(id, [{ weight: 20, reps: 1, setIndex: 0 }])),
    };
    const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
    const e = entry(snap, category, id);
    assert.strictEqual(e.e1rm.loadBasis, 'added');
    assert.strictEqual(e.e1rm.addedKg, 20);
    assert.strictEqual(e.e1rm.totalKg, 100);
    assert.strictEqual(e.e1rm.totalE1rm, 100);
    assert.strictEqual(e.e1rm.bodyweightKg, 80);
    assert.strictEqual(e.rePoints, pts(100, factor, 80));
  });

  test(`${label}: bodyweight-only set (added 0) scores the bodyweight`, () => {
    const bw = weighIns([['2026-01-01', 75]]);
    const history = {
      '2026-01-02': workout(row(id, [{ weight: 0, reps: 1, setIndex: 0 }])),
    };
    const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
    const e = entry(snap, category, id);
    assert.strictEqual(e.e1rm.totalKg, 75);
    assert.strictEqual(e.rePoints, pts(75, factor, 75));
  });

  test(`${label}: legacy absolute total with typed added load uses the existing rules`, () => {
    const bw = weighIns([['2026-01-01', 80]]);
    // Legacy screen stored its own (stale) 78 kg + 20 = 98 total; the typed
    // added load is authoritative and the recorded bodyweight is 80.
    const history = {
      '2026-01-02': workout(row(id, [{ weight: 98, reps: 1, weightAdded: 20 }])),
    };
    const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
    const e = entry(snap, category, id);
    assert.strictEqual(e.e1rm.loadBasis, 'absolute');
    assert.strictEqual(e.e1rm.totalKg, 100);
    assert.strictEqual(e.rePoints, pts(100, factor, 80));
  });

  test(`${label}: legacy absolute total without typed load keeps the stored total`, () => {
    const bw = weighIns([['2026-01-01', 80]]);
    const history = { '2026-01-02': workout(row(id, [{ weight: 110, reps: 1 }])) };
    const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
    const e = entry(snap, category, id);
    assert.strictEqual(e.e1rm.totalKg, 110);
    assert.strictEqual(e.e1rm.addedKg, 30);
    assert.strictEqual(e.rePoints, pts(110, factor, 80));
  });

  test(`${label}: an assisted (negative) load is not a performed set in the storage model`, () => {
    const bw = weighIns([['2026-01-01', 80]]);
    const history = {
      '2026-01-02': workout(row(id, [{ weight: -20, reps: 5, setIndex: 0 }])),
    };
    const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
    assert.strictEqual(snap.categories[category], undefined);
  });

  test(`${label}: no recorded bodyweight → record kept, points unavailable (null)`, () => {
    const history = {
      '2026-01-02': workout(row(id, [{ weight: 20, reps: 3, setIndex: 0 }])),
    };
    const snap = buildShowcaseV2(history, { bodyweightByDate: {} });
    const e = entry(snap, category, id);
    assert.ok(e.e1rm);
    assert.strictEqual(e.rePoints, null);
  });
}

test('Chin-Up V2 records are identical to the V1 records for the same history', () => {
  const bw = weighIns([['2026-01-01', 82], ['2026-02-01', 84]]);
  const history = {
    '2026-01-05': workout(row(ID.chin, [{ weight: 110, reps: 3, weightAdded: 28 }])),
    '2026-02-05': workout(row(ID.chin, [{ weight: 25, reps: 5, setIndex: 0 }, { weight: 30, reps: 2, setIndex: 1 }])),
  };
  const bwByDate = bwByDateFor(history, bw);
  const v1 = buildShowcase(history, { bodyweightByDate: bwByDate });
  const v2 = buildShowcaseV2(history, { bodyweightByDate: bwByDate });
  const e = entry(v2, 'verticalPull', ID.chin);
  assert.deepStrictEqual(e.e1rm, v1.lifts.chinUp.e1rm);
  assert.deepStrictEqual(e.heaviest, v1.lifts.chinUp.heaviest);
});

// ── Bodyweight as of the record's date ──────────────────────────────────────

test('points use the bodyweight recorded on or before the source performance date', () => {
  const bw = weighIns([['2026-01-01', 80], ['2026-03-01', 90], ['2026-06-01', 100]]);
  const history = {
    '2026-02-15': workout(row(ID.bench, [{ weight: 150, reps: 1 }])),
    '2026-03-01': workout(row(ID.squat, [{ weight: 200, reps: 1 }])),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  // Bench on 02-15 → the 01-01 weigh-in (80), never the later 90 or 100.
  assert.strictEqual(entry(snap, 'horizontalPress', ID.bench).rePoints, pts(150, 1, 80));
  // Squat on 03-01 → the same-day weigh-in (90).
  assert.strictEqual(entry(snap, 'squatPattern', ID.squat).rePoints, pts(200, 0.8, 90));
});

test('no weigh-in on or before the lift → points unavailable, not zero', () => {
  const bw = weighIns([['2026-05-01', 80]]);
  const history = { '2026-02-15': workout(row(ID.bench, [{ weight: 150, reps: 1 }])) };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  const e = entry(snap, 'horizontalPress', ID.bench);
  assert.strictEqual(e.rePoints, null);
  assert.strictEqual(e.e1rm.e1rm, 150);
});

test('sex changes the coefficient (female vs male)', () => {
  const bw = weighIns([['2026-01-01', 63]]);
  const history = { '2026-01-02': workout(row(ID.lat, [{ weight: 90, reps: 1 }])) };
  const bwByDate = bwByDateFor(history, bw);
  const f = buildShowcaseV2(history, { bodyweightByDate: bwByDate, sex: Sex.FEMALE });
  const m = buildShowcaseV2(history, { bodyweightByDate: bwByDate, sex: Sex.MALE });
  assert.strictEqual(entry(f, 'verticalPull', ID.lat).rePoints, pts(90, 0.85, 63, Sex.FEMALE));
  assert.strictEqual(entry(m, 'verticalPull', ID.lat).rePoints, pts(90, 0.85, 63, Sex.MALE));
  assert.notStrictEqual(entry(f, 'verticalPull', ID.lat).rePoints, entry(m, 'verticalPull', ID.lat).rePoints);
});

// ── Category default ────────────────────────────────────────────────────────

test('the highest-scoring alternative becomes the category default', () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const history = {
    '2026-01-02': workout(
      row(ID.bench, [{ weight: 100, reps: 1 }]), // 100 × 1.00
      row(ID.dbBench, [{ weight: 50, reps: 1 }]), // 50 × 2.35 = 117.5
    ),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  assert.strictEqual(snap.categories.horizontalPress.bestExerciseId, ID.dbBench);
});

test('equal points tie-break to catalogue order (conventional before sumo)', () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const history = {
    '2026-01-02': workout(
      row(ID.sumo, [{ weight: 200, reps: 1 }]),
      row(ID.deadlift, [{ weight: 200, reps: 1 }]),
    ),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  const hh = snap.categories.hipHinge;
  assert.strictEqual(hh.exercises[ID.deadlift].rePoints, hh.exercises[ID.sumo].rePoints);
  assert.strictEqual(hh.bestExerciseId, ID.deadlift);
});

test('selection: an unscored exercise never displaces a scored one', () => {
  const exercises = {
    [ID.bench]: { exerciseId: ID.bench, e1rm: { e1rm: 200 }, rePoints: null },
    [ID.dbBench]: { exerciseId: ID.dbBench, e1rm: { e1rm: 10 }, rePoints: 5 },
  };
  assert.strictEqual(selectDefaultExerciseId('horizontalPress', exercises), ID.dbBench);
});

test('selection: with no valid points, the first exercise with a record; else the primary', () => {
  assert.strictEqual(
    selectDefaultExerciseId('hipHinge', {
      [ID.hipThrust]: { exerciseId: ID.hipThrust, e1rm: {}, rePoints: null },
      [ID.sumo]: { exerciseId: ID.sumo, heaviest: {}, rePoints: null },
    }),
    ID.sumo,
  );
  assert.strictEqual(selectDefaultExerciseId('hipHinge', {}), ID.deadlift);
  assert.strictEqual(selectDefaultExerciseId('squatPattern', null), ID.squat);
});

test('selection: a genuine higher score wins regardless of order', () => {
  assert.strictEqual(
    selectDefaultExerciseId('squatPattern', {
      [ID.squat]: { exerciseId: ID.squat, e1rm: {}, rePoints: 100 },
      [ID.bssBb]: { exerciseId: ID.bssBb, e1rm: {}, rePoints: 100.0001 },
    }),
    ID.bssBb,
  );
});

// ── Storage: day contributions, edits, deletes, out-of-order ────────────────

test('two exercises of one category on one day are separate day contributions', async () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const store = memoryStoreV2({ bodyweightAsOf: bw });
  await applyWorkoutDayV2(store, '2026-01-02', workout(
    row(ID.deadlift, [{ weight: 200, reps: 1 }]),
    row(ID.sumo, [{ weight: 190, reps: 1 }]),
  ));
  assert.ok(store._days.has(dayDocIdV2('deadlift', '2026-01-02')));
  assert.ok(store._days.has(dayDocIdV2('deadliftSumo', '2026-01-02')));
  assert.strictEqual(dayDocIdV2('deadliftSumo', '2026-01-02'), 'hipHinge__deadliftSumo__2026-01-02');
  const snap = await store.getSnapshot();
  assert.deepStrictEqual(
    Object.keys(snap.categories.hipHinge.exercises).sort(),
    [ID.deadlift, ID.sumo].sort(),
  );
});

test('chronological appends take the fast path and equal a full rebuild', async () => {
  const bw = weighIns([['2026-01-01', 80], ['2026-02-10', 82]]);
  const history = {
    '2026-01-05': workout(row(ID.bench, [{ weight: 100, reps: 5 }]), row(ID.chin, [{ weight: 10, reps: 5, setIndex: 0 }])),
    '2026-02-05': workout(row(ID.dbBench, [{ weight: 45, reps: 3 }]), row(ID.lat, [{ weight: 70, reps: 8 }])),
    '2026-03-05': workout(row(ID.bench, [{ weight: 120, reps: 1 }]), row(ID.dip, [{ weight: 15, reps: 4, setIndex: 0 }])),
  };
  const store = memoryStoreV2({ bodyweightAsOf: bw, sex: 'M' });
  const paths = [];
  for (const d of Object.keys(history)) paths.push((await applyWorkoutDayV2(store, d, history[d])).path);
  assert.deepStrictEqual(paths, ['append', 'append', 'append']);
  const expected = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw), sex: Sex.MALE });
  assert.deepStrictEqual(await store.getSnapshot(), expected);
  assert.strictEqual(expected.schema, PROFILE_SHOWCASE_V2_SCHEMA);
  assert.strictEqual(expected.rePointsFormulaVersion, RE_POINTS_FORMULA_VERSION);
});

test('out-of-order delivery, edits and deletes converge on the full rebuild', async () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const history = {
    '2026-01-05': workout(row(ID.squat, [{ weight: 180, reps: 1 }])),
    '2026-02-05': workout(row(ID.bssBb, [{ weight: 120, reps: 3 }])),
    '2026-03-05': workout(row(ID.squat, [{ weight: 150, reps: 3 }])),
  };
  const store = memoryStoreV2({ bodyweightAsOf: bw });
  await applyAll(store, ['2026-03-05', '2026-01-05', '2026-02-05'], history);
  assert.deepStrictEqual(
    await store.getSnapshot(),
    buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) }),
  );

  // Edit: the old record's set is lowered.
  history['2026-01-05'] = workout(row(ID.squat, [{ weight: 140, reps: 1 }]));
  const edit = await applyWorkoutDayV2(store, '2026-01-05', history['2026-01-05']);
  assert.strictEqual(edit.path, 'rebuild');
  assert.deepStrictEqual(
    await store.getSnapshot(),
    buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) }),
  );

  // Delete the only barbell BSS day: the exercise disappears from V2.
  delete history['2026-02-05'];
  await applyWorkoutDayV2(store, '2026-02-05', null);
  const snap = await store.getSnapshot();
  assert.deepStrictEqual(snap, buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) }));
  assert.strictEqual(snap.categories.squatPattern.exercises[ID.bssBb], undefined);

  // Duplicate delivery is a no-op.
  const again = await applyWorkoutDayV2(store, '2026-01-05', history['2026-01-05']);
  assert.strictEqual(again.path, 'noop');
});

test('deleting every workout in a category removes the category', async () => {
  const store = memoryStoreV2({ bodyweightAsOf: weighIns([['2026-01-01', 80]]) });
  await applyWorkoutDayV2(store, '2026-01-05', workout(row(ID.hipThrust, [{ weight: 140, reps: 8 }])));
  assert.ok((await store.getSnapshot()).categories.hipHinge);
  await applyWorkoutDayV2(store, '2026-01-05', null);
  assert.deepStrictEqual((await store.getSnapshot()).categories, {});
});

test('a later weigh-in refreshes points of EVERY affected lift, not only bodyweight-loaded ones', async () => {
  const entries = [];
  const resolver = (d) => pickBodyweightAsOf(entries, d);
  const store = memoryStoreV2({ bodyweightAsOf: resolver });
  const history = {
    '2026-01-05': workout(row(ID.bench, [{ weight: 120, reps: 1 }]), row(ID.chin, [{ weight: 20, reps: 1, setIndex: 0 }])),
  };
  await applyAll(store, ['2026-01-05'], history);
  let snap = await store.getSnapshot();
  assert.strictEqual(entry(snap, 'horizontalPress', ID.bench).rePoints, null);
  assert.strictEqual(entry(snap, 'verticalPull', ID.chin).rePoints, null);

  // Weighed in on the training morning, logged afterwards.
  entries.push({ id: 'a', dateKey: '2026-01-05', weight: 80 });
  const res = await refreshV2(store, { bodyweight: true, sinceDateKey: '2026-01-05' });
  assert.strictEqual(res.changed, true);
  snap = await store.getSnapshot();
  assert.strictEqual(entry(snap, 'horizontalPress', ID.bench).rePoints, pts(120, 1, 80));
  assert.strictEqual(entry(snap, 'verticalPull', ID.chin).rePoints, pts(100, 1, 80));
  assert.deepStrictEqual(
    snap,
    buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, resolver) }),
  );

  // Editing the weigh-in moves the points again.
  entries[0].weight = 90;
  await refreshV2(store, { bodyweight: true, sinceDateKey: '2026-01-05' });
  snap = await store.getSnapshot();
  assert.strictEqual(entry(snap, 'horizontalPress', ID.bench).rePoints, pts(120, 1, 90));
  assert.strictEqual(entry(snap, 'verticalPull', ID.chin).rePoints, pts(110, 1, 90));

  // Repeated delivery is a no-op.
  const again = await refreshV2(store, { bodyweight: true, sinceDateKey: '2026-01-05' });
  assert.strictEqual(again.changed, false);
});

test('a weigh-in after every record date changes nothing', async () => {
  const entries = [{ id: 'a', dateKey: '2026-01-01', weight: 80 }];
  const store = memoryStoreV2({ bodyweightAsOf: (d) => pickBodyweightAsOf(entries, d) });
  await applyWorkoutDayV2(store, '2026-01-05', workout(row(ID.bench, [{ weight: 120, reps: 1 }])));
  entries.push({ id: 'b', dateKey: '2026-03-01', weight: 95 });
  const res = await refreshV2(store, { bodyweight: true, sinceDateKey: '2026-03-01' });
  assert.strictEqual(res.changed, false);
});

test('V1 lifts keep their V1 fingerprints in V2, so attached proofs keep standing', () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const history = {
    '2026-01-05': workout(
      row(ID.bench, [{ weight: 100, reps: 5, id: 'setA' }]),
      row(ID.squat, [{ weight: 150, reps: 3 }]),
      row(ID.deadlift, [{ weight: 200, reps: 1 }]),
      row(ID.ohpDb, [{ weight: 25, reps: 6 }]),
      row(ID.chin, [{ weight: 10, reps: 5, setIndex: 0 }]),
    ),
  };
  const bwByDate = bwByDateFor(history, bw);
  const v1 = buildShowcase(history, { bodyweightByDate: bwByDate });
  const v2 = buildShowcaseV2(history, { bodyweightByDate: bwByDate });
  const pairs = [
    ['bench', 'horizontalPress', ID.bench],
    ['squat', 'squatPattern', ID.squat],
    ['deadlift', 'hipHinge', ID.deadlift],
    ['ohpUnilateral', 'overheadPress', ID.ohpDb],
    ['chinUp', 'verticalPull', ID.chin],
  ];
  for (const [slot, cat, id] of pairs) {
    assert.strictEqual(entry(v2, cat, id).e1rm.fingerprint, v1.lifts[slot].e1rm.fingerprint, slot);
    assert.strictEqual(entry(v2, cat, id).heaviest.fingerprint, v1.lifts[slot].heaviest.fingerprint, slot);
  }
});

test('new exercises get stable, distinct fingerprints that survive a rebuild', async () => {
  const bw = weighIns([['2026-01-01', 80]]);
  const history = {
    '2026-01-05': workout(
      row(ID.deadlift, [{ weight: 200, reps: 1 }]),
      row(ID.sumo, [{ weight: 200, reps: 1 }]),
    ),
  };
  const a = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw) });
  const store = memoryStoreV2({ bodyweightAsOf: bw });
  await applyAll(store, ['2026-01-05'], history);
  const b = await store.getSnapshot();
  const fa = liveFingerprintsV2(a);
  assert.deepStrictEqual(fa, liveFingerprintsV2(b));
  const conv = entry(a, 'hipHinge', ID.deadlift).e1rm.fingerprint;
  const sumo = entry(a, 'hipHinge', ID.sumo).e1rm.fingerprint;
  assert.notStrictEqual(conv, sumo, 'same load/date/set on two exercises must not share a proof');
  // Case-folded ids do not change a fingerprint.
  const folded = { '2026-01-05': workout(row(ID.sumo.toLowerCase(), [{ weight: 200, reps: 1 }])) };
  const c = buildShowcaseV2(folded, { bodyweightByDate: bwByDateFor(folded, bw) });
  assert.strictEqual(entry(c, 'hipHinge', ID.sumo).e1rm.fingerprint, sumo);
});

test('the public snapshot carries no sex and no bodyweight for ordinary lifts', () => {
  const bw = weighIns([['2026-01-01', 63]]);
  const history = {
    '2026-01-05': workout(row(ID.bench, [{ weight: 60, reps: 5 }]), row(ID.hipThrust, [{ weight: 100, reps: 8 }])),
  };
  const snap = buildShowcaseV2(history, { bodyweightByDate: bwByDateFor(history, bw), sex: Sex.FEMALE });
  const json = JSON.stringify(snap);
  assert.ok(!/"sex"|female|"bodyweightKg"|"bodyweightDateKey"/.test(json), json);
});

test('golden: the sample snapshot the Dart suite parses is exactly what the server builds', () => {
  const golden = require('./fixtures/showcase_v2_sample.json');
  const { SAMPLE_HISTORY, SAMPLE_WEIGH_INS } = require('./fixtures/showcase_v2_sample_input');
  const bw = weighIns(SAMPLE_WEIGH_INS);
  const snap = buildShowcaseV2(SAMPLE_HISTORY, {
    bodyweightByDate: bwByDateFor(SAMPLE_HISTORY, bw),
    sex: Sex.MALE,
  });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(snap)), golden);
});

// ── Backfill helpers ────────────────────────────────────────────────────────

test('V2 backfill: dry run by default; apply and verify are exclusive', () => {
  const d = parseArgs([]);
  assert.strictEqual(d.apply, false);
  assert.strictEqual(d.verify, false);
  assert.throws(() => parseArgs(['--apply', '--verify']));
  assert.throws(() => parseArgs(['--bogus']));
  assert.strictEqual(parseArgs(['--uid', 'u1', '--apply']).uid, 'u1');
});

test('V2 backfill: comparison ignores key order and the mirror stamp', () => {
  const a = { schema: 'profileShowcaseV2', categories: { x: { a: 1, b: 2 } }, updatedAtMs: 1 };
  const b = { categories: { x: { b: 2, a: 1 } }, schema: 'profileShowcaseV2', updatedAtMs: 2 };
  assert.ok(sameSnapshotV2(a, b));
  assert.ok(!sameSnapshotV2(a, { schema: 'profileShowcaseV2', categories: { x: { a: 1, b: 3 } } }));
});
