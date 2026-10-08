'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { sexFilterOf, selectSexEntries, appSexBoard } = require('../leaderboard/sex_filter');
const feed = require('../leaderboard/public_feed');
const age = require('../leaderboard/age');
const ageFs = require('../leaderboard/age_firestore');

test('only explicit male/female choices classify; Yes, unknown and missing stay in All', () => {
  for (const v of ['M', 'm', ' Male ']) assert.equal(sexFilterOf(v), 'male');
  for (const v of ['F', 'f', 'Female']) assert.equal(sexFilterOf(v), 'female');
  for (const v of ['N', 'Yes.', 'robot', '', null, undefined, 1]) assert.equal(sexFilterOf(v), null);
});

test('sex boards select before the top-20 limit, preserve tie order and independently rank age scores', () => {
  const raws = Array.from({ length: 45 }, (_, i) => ({ uid: `u${i}`, totalPointsUnits: 10000 - i }));
  const sexes = new Map(raws.map((e, i) => [e.uid, i < 22 ? 'male' : 'female']));
  const female = selectSexEntries(raws, sexes, 'female');
  assert.equal(female.length, 20); assert.equal(female[0].uid, 'u22');
  assert.equal(female.at(-1).uid, 'u41');
  const adjusted = [...raws].reverse().map(e => ({ ...e, ageComplete: true,
    ageModelVersion: age.AGE_MODEL_VERSION, adjustedTotalUnits: 10000 + Number(e.uid.slice(1)) }));
  const femaleAge = selectSexEntries(adjusted, sexes, 'female');
  const publicAge = feed.buildPublicAgeSnapshot({ periodKey: 'all_time', ageEntries: femaleAge,
    publicProfiles: new Map(), ageModelVersion: age.AGE_MODEL_VERSION, rankedCount: 23,
    incompleteCount: 0, generatedAt: new Date().toISOString() });
  assert.equal(femaleAge[0].uid, 'u44');
  assert.deepEqual(publicAge.entries.map(e => e.rank), Array.from({ length: 20 }, (_, i) => i + 1));
  assert.deepEqual(selectSexEntries(raws, sexes, 'all'), raws.slice(0, 20));
  assert.throws(() => selectSexEntries(raws, sexes, 'robot'));
});

test('app snapshots allowlist entry fields and retain monthly contribution details', () => {
  const board = appSexBoard({ periodKey: 'all_time', sex: 'female', view: 'raw',
    generatedAt: new Date().toISOString(), entries: [{ uid: 'athlete', totalPointsUnits: 500,
      categoryExerciseBreakdown: { hipHinge: [] }, dob: 'secret', sex: 'F', email: 'secret' }] });
  assert.equal(board.sexFilter, 'female'); assert.equal(board.entries[0].uid, 'athlete');
  assert.deepEqual(board.entries[0].categoryExerciseBreakdown, { hipHinge: [] });
  assert.ok(!JSON.stringify(board).includes('secret')); assert.ok(!('sex' in board.entries[0]));
});

test('sex query is strict and uses independent raw/age/month/group snapshot keys', () => {
  for (const sex of ['all', 'male', 'female']) {
    assert.deepEqual(feed.parsePublicRequest('GET', `period=all_time&view=age&sex=${sex}`), { period: 'all_time', view: 'age', sex });
    const suffix = sex === 'all' ? '' : `_${sex}`;
    assert.equal(feed.snapshotKeyFor('current', '2026-10', 'age', sex), `2026-10_age${suffix}`);
    assert.equal(feed.snapshotKeyFor('all_time', '2026-10', 'raw', sex), `all_time${suffix}`);
  }
  for (const q of ['sex=', 'sex=robot', 'sex=Male', 'sex=male&sex=female']) assert.equal(feed.parsePublicRequest('GET', q).status, 400);
});

test('public handler cannot reuse another sex or mode cache; marker must match the requested sex', async () => {
  const now = Date.parse('2026-10-08T00:00:00Z');
  const keys = [];
  const deps = { nowMs: () => now, readSnapshot: async key => {
    keys.push(key);
    const isAge = key.includes('_age');
    const sex = key.endsWith('_female') ? 'female' : 'male';
    return { schemaVersion: isAge ? 2 : 1, ...(isAge ? { view: 'age', ageModelVersion: age.AGE_MODEL_VERSION,
      rankedCount: 1, incompleteCount: 0 } : {}), sexFilter: sex, periodKey: 'all_time',
      generatedAt: new Date(now).toISOString(), entries: [{ rank: 1, username: `${sex}-${isAge}`,
        ...(isAge ? { adjustedTotalUnits: 40000 } : { totalPointsUnits: 30000, silverEligible: false }), medals: [], dob: 'secret' }] };
  } };
  function response() { return { status(n) { this.code = n; return this; }, set() {}, send(s) { this.body = JSON.parse(s); }, end() {} }; }
  for (const sex of ['male', 'female']) for (const view of ['raw', 'age']) {
    const res = response();
    await ageFs.handlePublicRequest({ method: 'GET', url: `?period=all_time&view=${view}&sex=${sex}` }, res, deps);
    assert.equal(res.code, 200); assert.equal(res.body.sexFilter, sex);
    assert.equal(res.body.entries[0].username, `${sex}-${view === 'age'}`);
    assert.ok(!JSON.stringify(res.body).includes('secret'));
  }
  assert.equal(new Set(keys).size, 4);
  const res = response();
  await ageFs.handlePublicRequest({ method: 'GET', url: '?period=current&sex=female' }, res,
    { nowMs: () => now, readSnapshot: async () => ({ schemaVersion: 1, periodKey: '2026-10',
      sexFilter: 'male', generatedAt: new Date(now).toISOString(), entries: [] }) });
  assert.equal(res.code, 503);
});
