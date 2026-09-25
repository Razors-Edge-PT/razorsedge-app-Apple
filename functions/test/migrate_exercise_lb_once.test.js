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
