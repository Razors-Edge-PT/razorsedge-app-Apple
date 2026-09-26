'use strict';

// One-time single-account lb→kg correction (scripts/migrate_exercise_lb_once.js):
// argument parsing, the exact-target guards, the conversion, what is and is
// not touched, and the once-only guard.

const test = require('node:test');
const assert = require('node:assert/strict');
const m = require('../scripts/migrate_exercise_lb_once');

const UID = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const EX = '1XOIXxeLFhgmgjZS9Cyq';
const opts = { exerciseId: EX, exerciseName: 'Lat Pull Down, Supinated' };

test('exact conversion factor, unrounded', () => {
  assert.equal(m.KG_PER_LB, 0.45359237);
  assert.equal(m.lbToKg(300), 300 * 0.45359237);
  assert.equal(Number(m.lbToKg(300).toFixed(6)), 136.077711);
  assert.equal(Number(m.lbToKg(15).toFixed(6)), 6.803886);
});

test('convertLoad keeps the stored type and ignores non-loads', () => {
  assert.deepEqual(m.convertLoad(275), { changed: true, value: 275 * 0.45359237 });
  assert.deepEqual(m.convertLoad('247.5'), { changed: true, value: String(247.5 * 0.45359237) });
  for (const raw of [undefined, null, '', ' ', 'abc', 0, -5, NaN, Infinity, {}, []]) {
    assert.deepEqual(m.convertLoad(raw), { changed: false }, String(raw));
  }
});

test('argument parsing and exact-target protection', () => {
  const a = m.parseArgs(['--uid', UID, '--exercise', EX]);
  assert.equal(a.apply, false, 'dry run by default');
  assert.doesNotThrow(() => m.assertExactTarget(a));
  assert.equal(m.parseArgs(['--uid', UID, '--exercise', EX, '--apply']).apply, true);
  assert.deepEqual(m.parseArgs(['--uid', UID, '--exercise', EX, '--exclude-dates', '2025-11-05']).excludeDates, ['2025-11-05']);
  assert.throws(() => m.parseArgs(['--apply', '--verify']));
  assert.throws(() => m.parseArgs(['--exclude-dates', 'Nov5']));
  assert.throws(() => m.parseArgs(['--everyone']));
  assert.throws(() => m.assertExactTarget({ uid: 'someoneElse', exerciseId: EX }));
  assert.throws(() => m.assertExactTarget({ uid: UID, exerciseId: EX.toLowerCase() }), 'case must match exactly');
  assert.throws(() => m.assertExactTarget({ uid: UID, exerciseId: 'AmfUWbF1DH3I7qPAdh5k' }));
  assert.throws(() => m.assertExactTarget({ uid: null, exerciseId: null }));
});

test('only the matching entry\'s weights change; everything else is preserved', () => {
  const other = { exerciseId: 'AmfUWbF1DH3I7qPAdh5k', name: 'Bench Press, Barbell', sets: [{ weight: 140, reps: 1, rir: 0 }] };
  const wide = { exerciseId: 'wideArmId', name: 'Lat Pull Down, Wide Arm', sets: [{ weight: 200, reps: 8 }] };
  const lat = { exerciseId: EX, name: 'Lat Pull Down, Supinated', savedAt: 'x', orderIndex: 2,
    sets: [{ weight: 275, reps: 3, rir: 1, setIndex: 0, velocity: 0.4, notes: 'n' }, { reps: 5 }, { weight: 260, rir: 1 }] };
  const doc = { date: '2026-09-21', name: 'Pull', exercises: [other, lat, wide], lastEditedAt: 1 };
  const { changes } = m.planWorkouts([['2026-09-21', doc]], opts);
  assert.equal(changes.length, 1);
  const [c] = changes;
  assert.equal(c.sets.length, 2, 'the set without a load is not a change');
  assert.deepEqual(c.exercises[0], other);
  assert.deepEqual(c.exercises[2], wide, 'a different Lat Pull Down is never touched');
  const s = c.exercises[1].sets;
  assert.deepEqual(s[0], { weight: 275 * 0.45359237, reps: 3, rir: 1, setIndex: 0, velocity: 0.4, notes: 'n' });
  assert.deepEqual(s[1], { reps: 5 });
  assert.deepEqual(s[2], { weight: 260 * 0.45359237, rir: 1 });
  assert.equal(c.exercises[1].savedAt, 'x');
  assert.equal(doc.exercises[1].sets[0].weight, 275, 'the input is not mutated');
});

test('case-folded ids match (server rule); legacy non-date docs and exclusions are reported, not changed', () => {
  const lat = (id, w) => ({ exerciseId: id, name: 'Lat Pull Down, Supinated', sets: [{ weight: w, reps: 3 }] });
  const res = m.planWorkouts([
    ['2026-04-12', { exercises: [lat(EX.toLowerCase(), 245)] }],
    ['2025-11-05', { exercises: [lat(EX, 134)] }],
    ['nZFnNtmPslo85yYOuNq2', { exercises: [{ name: 'Lat Pull Down, Supinated', sets: [{ weight: 130, reps: 1 }] }] }],
    ['2026-01-01', { exercises: [{ name: 'Lat Pull Down, Supinated', sets: [{ weight: 99, reps: 1 }] }] }],
  ], Object.assign({ excludeDates: ['2025-11-05'] }, opts));
  assert.deepEqual(res.changes.map((c) => c.docId), ['2026-04-12']);
  assert.deepEqual(res.legacyDocs, ['nZFnNtmPslo85yYOuNq2']);
  assert.deepEqual(res.skipped.map((s) => s.docId), ['2025-11-05']);
});

test('settings: weightUnit lb, numeric increments converted, other settings untouched', () => {
  const blocks = [
    ['active', { isActive: true, exerciseSettings: { [EX]: { increments: { primary: 15 }, repTargets: { a: 1 } }, other: { increments: { primary: 5 } } } }],
    ['skip', { exerciseSettings: { [EX]: { increments: { primary: 2.5, secondary: 5 } } } }],
    ['none', { exerciseSettings: { other: { increments: { primary: 5 } } } }],
    ['done', { exerciseSettings: { [EX]: { weightUnit: 'lb' } } }],
  ];
  const plan = m.planBlocks(blocks, { exerciseId: EX, skipIncrements: ['skip'] });
  assert.deepEqual(plan.map((b) => b.blockId), ['active', 'skip']);
  assert.deepEqual(plan[0].increments, [{ key: 'primary', before: 15, after: 15 * 0.45359237 }]);
  assert.equal(plan[0].isActive, true);
  assert.deepEqual(plan[1].increments, [], 'skipped block keeps its increments');
  assert.equal(plan[1].incrementsSkipped, true);
});

test('refuses a second application before writing anything', async () => {
  let writes = 0;
  const db = { collection() { writes += 1; throw new Error('must not be reached'); } };
  const state = { marker: { status: 'done' }, workouts: [], blocks: [] };
  await assert.rejects(() => m.apply({}, db, state, { changes: [], legacyDocs: [], skipped: [] }, [], {}), /already exists/);
  assert.equal(writes, 0);
});

test('content hash detects a changed document and ignores key order', () => {
  assert.equal(m.contentHash({ a: 1, b: [1, { c: 2 }] }), m.contentHash({ b: [1, { c: 2 }], a: 1 }));
  assert.notEqual(m.contentHash({ a: 1 }), m.contentHash({ a: 2 }));
});

// ── Generalised to an approved account list + explicit selection ────────────

const RUBY = 'L7YjSMnm7tXD3BwyskmmrgVhKsS2';
const lat = (id, weights) => ({
  exerciseId: id, name: 'Lat Pull Down, Supinated', sets: weights.map((w, i) => ({ weight: w, reps: 8, rir: 1, setIndex: i })),
});
const sel = (sets) => m.parseSelection({ uid: RUBY, exerciseId: EX, sets }, RUBY);
const withSel = (sets) => Object.assign({ selection: sel(sets) }, opts);

test('approved accounts only; per-account marker; Richard unchanged', () => {
  assert.deepEqual(Object.keys(m.TARGETS).sort(), [RUBY, UID].sort());
  assert.equal(m.targetFor(UID).username, 'NZBenchPress');
  assert.equal(m.targetFor(RUBY).username, 'rubycakes');
  assert.equal(m.markerIdFor(UID), `exerciseLbCorrection_${UID}_${EX}`);
  assert.equal(m.markerIdFor(RUBY), `exerciseLbCorrection_${RUBY}_${EX}`);
  assert.doesNotThrow(() => m.assertExactTarget({ uid: RUBY, exerciseId: EX }));
  assert.throws(() => m.assertExactTarget({ uid: RUBY.toLowerCase(), exerciseId: EX }));
  assert.throws(() => m.assertExactTarget({ uid: 'toString', exerciseId: EX }), 'prototype keys are not targets');
});

test('selection parsing is strict and bound to one account', () => {
  const ok = { docId: '2026-01-22', entryIndex: 3, setIndex: 0, expected: 125 };
  assert.equal(sel([ok]).get('2026-01-22#3#0'), 125);
  assert.throws(() => m.parseSelection({ uid: UID, exerciseId: EX, sets: [ok] }, RUBY), /not L7Yj/);
  assert.throws(() => m.parseSelection({ uid: RUBY, exerciseId: 'x', sets: [ok] }, RUBY));
  assert.throws(() => sel([]));
  assert.throws(() => sel([ok, ok]), /Duplicate/);
  assert.throws(() => sel([Object.assign({}, ok, { expected: 0 })]));
  assert.throws(() => sel([Object.assign({}, ok, { setIndex: -1 })]));
  assert.throws(() => m.parseArgs(['--selection', 'f.json', '--exclude-dates', '2026-01-01']));
  assert.throws(() => m.parseArgs(['--set-increment-lb', '15', '--skip-increments', 'b']));
  assert.throws(() => m.parseArgs(['--set-increment-lb', 'abc']));
  assert.equal(m.parseArgs(['--set-increment-lb', '15']).setIncrementLb, 15);
});

test('mixed history: unselected sets before a boundary stay kg; selected sets convert, unrounded', () => {
  const workouts = [
    ['2025-03-01', { exercises: [lat(EX, [60, 62.5])] }],
    ['2026-01-22', { exercises: [{ exerciseId: 'other', sets: [{ weight: 40 }] }, lat(EX, [125, 110])] }],
  ];
  const res = m.planWorkouts(workouts, withSel([
    { docId: '2026-01-22', entryIndex: 1, setIndex: 0, expected: 125 },
    { docId: '2026-01-22', entryIndex: 1, setIndex: 1, expected: 110 },
  ]));
  assert.deepEqual(res.changes.map((c) => c.docId), ['2026-01-22']);
  assert.deepEqual(res.kept.map((k) => `${k.docId}#${k.setIndex}=${k.weight}`), ['2025-03-01#0=60', '2025-03-01#1=62.5']);
  const [c] = res.changes;
  assert.equal(c.exercises[1].sets[0].weight, 125 * 0.45359237);
  assert.equal(c.exercises[1].sets[0].weight, 56.69904625, 'exact product, not rounded');
  assert.equal(c.exercises[1].sets[1].weight, 49.895160700000005);
  assert.deepEqual(c.exercises[0], workouts[1][1].exercises[0], 'other exercise untouched');
  assert.deepEqual(Object.assign({}, c.exercises[1].sets[0], { weight: 125 }), workouts[1][1].exercises[1].sets[0], 'reps/rir/setIndex preserved');
  assert.equal(workouts[1][1].exercises[1].sets[0].weight, 125, 'the input is not mutated');
});

test('explicit keep inside a converted document', () => {
  const res = m.planWorkouts([['2026-06-03', { exercises: [lat(EX, [110, 110])] }]],
    withSel([{ docId: '2026-06-03', entryIndex: 0, setIndex: 1, expected: 110 }]));
  const s = res.changes[0].exercises[0].sets;
  assert.equal(s[0].weight, 110, 'unselected set keeps its kg value');
  assert.equal(s[1].weight, 110 * 0.45359237);
  assert.equal(res.kept.length, 1);
});

test('changed source aborts before any write; missing or foreign selections abort', () => {
  const w = [['2026-09-14', { exercises: [lat(EX, [130])] }]];
  const at = (docId, setIndex) => withSel([{ docId, entryIndex: 0, setIndex, expected: 125 }]);
  assert.throws(() => m.planWorkouts(w, at('2026-09-14', 0)), /stores 130, audited 125/);
  assert.throws(() => m.planWorkouts(w, at('2026-09-14', 5)), /not found/);
  assert.throws(() => m.planWorkouts(w, at('2026-09-15', 0)), /not found/);
  const wide = [['2026-09-14', { exercises: [{ exerciseId: 'wideArm', name: 'Lat Pull Down, Wide Arm', sets: [{ weight: 125 }] }] }]];
  assert.throws(() => m.planWorkouts(wide, at('2026-09-14', 0)), /not found/, 'never another exercise');
});

test('legacy random-id documents: excluded unless their sets are selected explicitly', () => {
  const legacy = ['nZFnNtmPslo85yYOuNq2', { date: '2025-07-01', exercises: [{ name: 'Lat Pull Down, Supinated', sets: [{ weight: 130, reps: 1 }] }] }];
  const none = m.planWorkouts([legacy, ['2026-01-01', { exercises: [lat(EX, [100])] }]],
    withSel([{ docId: '2026-01-01', entryIndex: 0, setIndex: 0, expected: 100 }]));
  assert.deepEqual(none.legacyDocs, ['nZFnNtmPslo85yYOuNq2']);
  assert.deepEqual(none.changes.map((c) => c.docId), ['2026-01-01']);
  const picked = m.planWorkouts([legacy], withSel([{ docId: 'nZFnNtmPslo85yYOuNq2', entryIndex: 0, setIndex: 0, expected: 130 }]));
  assert.equal(picked.changes[0].exercises[0].sets[0].weight, 130 * 0.45359237);
  assert.equal(picked.changes[0].exercises[0].name, 'Lat Pull Down, Supinated');
});

test('--set-increment-lb sets primary to n lb in kg on every block with settings; nothing else changes', () => {
  const blocks = [
    ['a', { isActive: true, exerciseSettings: { [EX]: { increments: { primary: 2.5 }, defaultSets: 3 }, other: { increments: { primary: 2.5 } } } }],
    ['b', { exerciseSettings: { [EX]: { increments: { primary: 2.5, secondary: 1 } } } }],
    ['c', { exerciseSettings: { [EX]: { defaultSets: 3 } } }],
    ['d', { weeks: [{ exerciseId: EX }] }],
  ];
  const plan = m.planBlocks(blocks, { exerciseId: EX, setIncrementLb: 15 });
  assert.deepEqual(plan.map((b) => b.blockId), ['a', 'b', 'c'], 'a block without settings is not written');
  for (const b of plan) assert.deepEqual(b.increments.map((i) => [i.key, i.after]), [['primary', 6.80388555]]);
  assert.equal(plan[0].increments[0].before, 2.5);
  assert.equal(plan[2].increments[0].before, null);
  const done = [['x', { exerciseSettings: { [EX]: { weightUnit: 'lb', increments: { primary: 15 * 0.45359237 } } } }]];
  assert.deepEqual(m.planBlocks(done, { exerciseId: EX, setIncrementLb: 15 }), [], 'already applied: nothing to do');
});

test('verifyAgainstBackup accepts exactly the planned change and rejects anything else', () => {
  const before = {
    date: '2026-01-22', lastEditedAt: { __timestamp: '2026-06-03T04:47:14.347Z', millis: 1780462034347 },
    exercises: [{ exerciseId: 'other', sets: [{ weight: 40, reps: 5 }] }, lat(EX, [125, 110])],
  };
  const block = { name: 'B', exerciseSettings: { [EX]: { increments: { primary: 2.5 }, defaultSets: 3 }, other: { increments: { primary: 2.5 } } } };
  const plan = m.planWorkouts([['2026-01-22', before]], opts);
  const blockPlan = m.planBlocks([['blk', block]], { exerciseId: EX, setIncrementLb: 15 });
  const manifest = {
    target: { uid: RUBY, exerciseId: EX },
    workoutChanges: plan.changes.map((c) => ({ docId: c.docId, sets: c.sets })),
    settingsChanges: blockPlan,
  };
  const W = `users/${RUBY}/workouts/2026-01-22`;
  const B = `users/${RUBY}/planned_blocks/blk`;
  const documents = [{ path: W, data: before }, { path: B, data: block }];
  const goodBlock = () => ({ name: 'B', exerciseSettings: { [EX]: { increments: { primary: 6.80388555 }, defaultSets: 3, weightUnit: 'lb' }, other: { increments: { primary: 2.5 } } } });
  const good = new Map([[W, Object.assign({}, before, { exercises: plan.changes[0].exercises })], [B, goodBlock()]]);
  assert.deepEqual(m.verifyAgainstBackup(manifest, documents, good), []);

  const ex = JSON.parse(JSON.stringify(plan.changes[0].exercises));
  ex[1].sets[0].weight = 56.699;
  assert.equal(m.verifyAgainstBackup(manifest, documents, new Map(good).set(W, Object.assign({}, before, { exercises: ex }))).length, 1, 'a rounded value fails');
  assert.equal(m.verifyAgainstBackup(manifest, documents, new Map(good).set(W, Object.assign({}, good.get(W), { name: 'x' }))).length, 1, 'an unrelated field fails');
  const otherEx = goodBlock();
  otherEx.exerciseSettings.other.increments.primary = 5;
  assert.equal(m.verifyAgainstBackup(manifest, documents, new Map(good).set(B, otherEx)).length, 1, "another exercise's settings fail");
  const missing = new Map(good);
  missing.delete(B);
  assert.equal(m.verifyAgainstBackup(manifest, documents, missing).length, 1);
});

test('idempotent: once converted, the audited selection no longer matches and nothing is planned', () => {
  const converted = [['2026-01-22', { exercises: [lat(EX, [125 * 0.45359237])] }]];
  assert.throws(() => m.planWorkouts(converted, withSel([{ docId: '2026-01-22', entryIndex: 0, setIndex: 0, expected: 125 }])), /audited 125/);
});
