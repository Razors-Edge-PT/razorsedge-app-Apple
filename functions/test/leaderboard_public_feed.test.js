'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const feed = require('../leaderboard/public_feed');
const ageFs = require('../leaderboard/age_firestore');
const age = require('../leaderboard/age');

const P = 10000;

function rawEntry(uid, points, extra) {
  return Object.assign({
    uid,
    totalPointsUnits: points * P,
    tieBreakDateKey: '2026-10-01',
    username: `display-${uid}`, // the raw entry's username may be a displayName/fullName fallback
    photoURL: `https://example.invalid/${uid}.jpg`,
    email: `${uid}@example.com`,
    dob: '01-01-1950',
    sex: 'female',
    categoryBestUnits: { hipHinge: points * P },
  }, extra || {});
}

test('builds an allowlisted schema-1 snapshot from the raw top 20 only', () => {
  const raw = [];
  for (let i = 0; i < 25; i += 1) raw.push(rawEntry(`u${i}`, 500 - i));
  raw.splice(3, 0, rawEntry('zero', 0));
  const profiles = new Map([
    ['u0', { username: 'coded_nz', fullName: 'Legal Name', email: 'x@y.z' }],
    ['u1', { displayName: 'Only A Display Name', fullName: 'Legal Name' }],
    ['u2', { username: '   ' }],
  ]);
  const medalSnapshot = {
    categories: {
      hipHinge: [{ uid: 'u0', place: 1, pointsUnits: 5 }, { uid: 'u1', place: 2 }, { uid: 'u0', place: 3 }],
      squatPattern: [{ uid: 'u0', place: 2, recordDateKey: '2026-01-01' }],
      notACategory: [{ uid: 'u0', place: 1 }],
    },
  };
  const snap = feed.buildPublicSnapshot({
    periodKey: '2026-10',
    rawEntries: raw,
    publicProfiles: profiles,
    medalSnapshot,
    silverUids: new Set(['u1']),
    generatedAt: '2026-10-03T08:00:00.000Z',
    isEligible: (uid) => uid !== 'u4',
  });
  assert.equal(snap.schemaVersion, 1);
  assert.equal(snap.periodKey, '2026-10');
  assert.equal(snap.entries.length, 20);
  assert.deepEqual(snap.entries.map((e) => e.rank), Array.from({ length: 20 }, (_, i) => i + 1));
  assert.ok(snap.entries.every((e) => Number.isSafeInteger(e.totalPointsUnits) && e.totalPointsUnits > 0));
  assert.equal(snap.entries[0].username, 'coded_nz');
  assert.equal(snap.entries[1].username, 'GoodLift athlete', 'never a displayName or legal-name fallback');
  assert.equal(snap.entries[2].username, 'GoodLift athlete');
  assert.equal(snap.entries[1].silverEligible, true);
  assert.equal(snap.entries[0].silverEligible, false);
  assert.deepEqual(snap.entries[0].medals, [{ categoryKey: 'hipHinge', place: 1 }, { categoryKey: 'squatPattern', place: 2 }]);
  assert.deepEqual(snap.entries[3].medals, []);
  assert.ok(!snap.entries.some((e) => e.username.includes('u4')), 'excluded accounts are skipped');
  // Nothing private at any level.
  const json = JSON.stringify(snap);
  for (const forbidden of ['uid', 'dob', 'email', 'sex', 'photoURL', 'example.invalid', 'Legal Name', 'display-', 'tieBreak', 'categoryBest', 'recordDateKey', 'pointsUnits"']) {
    assert.ok(!json.includes(forbidden), forbidden);
  }
  for (const e of snap.entries) assert.deepEqual(Object.keys(e).sort(), ['medals', 'rank', 'silverEligible', 'totalPointsUnits', 'username']);
  assert.deepEqual(Object.keys(snap).sort(), ['entries', 'generatedAt', 'periodKey', 'schemaVersion']);
});

test('the served snapshot is re-sanitised: stray private fields never escape', () => {
  const stored = {
    schemaVersion: 1,
    periodKey: 'all_time',
    generatedAt: '2026-10-03T08:00:00.000Z',
    uid: 'secret',
    entries: [
      { rank: 1, username: 'a', totalPointsUnits: 10, silverEligible: true, uid: 'x', dob: '01-01-1950', medals: [{ categoryKey: 'hipHinge', place: 1, uid: 'x' }, { categoryKey: 'hipHinge', place: 2 }] },
    ],
  };
  const out = feed.sanitizeSnapshot(stored, 'all_time');
  assert.deepEqual(out, {
    schemaVersion: 1,
    periodKey: 'all_time',
    generatedAt: '2026-10-03T08:00:00.000Z',
    entries: [{ rank: 1, username: 'a', totalPointsUnits: 10, silverEligible: true, medals: [{ categoryKey: 'hipHinge', place: 1 }] }],
  });
  assert.equal(feed.sanitizeSnapshot(Object.assign({}, stored, { periodKey: '2026-09' }), '2026-10'), null, 'another month is not ready');
  assert.equal(feed.sanitizeSnapshot({ ...stored, entries: [{ rank: 2, username: 'a', totalPointsUnits: 1 }] }, 'all_time'), null);
  assert.equal(feed.sanitizeSnapshot({ ...stored, entries: [{ rank: 1, username: 'a', totalPointsUnits: 1.5 }] }, 'all_time'), null);
  assert.equal(feed.sanitizeSnapshot(null, 'all_time'), null);
});

test('requests: only GET/HEAD and exactly period=current|all_time', () => {
  assert.deepEqual(feed.parsePublicRequest('GET', ''), { period: 'current' });
  assert.deepEqual(feed.parsePublicRequest('GET', 'period=current'), { period: 'current' });
  assert.deepEqual(feed.parsePublicRequest('HEAD', 'period=all_time'), { period: 'all_time' });
  assert.equal(feed.parsePublicRequest('POST', 'period=current').status, 405);
  assert.equal(feed.parsePublicRequest('DELETE', '').status, 405);
  assert.equal(feed.parsePublicRequest('GET', 'period=2026-09').status, 400);
  assert.equal(feed.parsePublicRequest('GET', 'period=current&period=all_time').status, 400);
  assert.equal(feed.parsePublicRequest('GET', 'period=current&uid=abc').status, 400);
  assert.equal(feed.parsePublicRequest('GET', 'uid=abc').status, 400);
  assert.equal(feed.parsePublicRequest('GET', 'period=').status, 400);
});

function fakeRes() {
  const r = { headers: {}, statusCode: 0, body: undefined, ended: false, headersSent: false };
  r.status = (s) => { r.statusCode = s; return r; };
  r.set = (k, v) => { r.headers[k.toLowerCase()] = v; return r; };
  r.send = (b) => { r.body = b; r.headersSent = true; return r; };
  r.end = () => { r.ended = true; r.headersSent = true; return r; };
  return r;
}

const NOW = Date.parse('2026-10-03T09:00:00.000Z'); // 2026-10-03 22:00 in Auckland

test('handler: one snapshot read, JSON + nosniff + bounded public cache', async () => {
  const reads = [];
  const stored = {
    schemaVersion: 1, periodKey: '2026-10', generatedAt: '2026-10-03T08:58:00.000Z',
    entries: [{ rank: 1, username: 'coded_nz', totalPointsUnits: 22000000, silverEligible: false, medals: [] }],
  };
  const res = fakeRes();
  await ageFs.handlePublicRequest({ method: 'GET', originalUrl: '/publicLeaderboard?period=current' }, res, {
    nowMs: () => NOW,
    readSnapshot: async (key) => { reads.push(key); return stored; },
  });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(reads, ['2026-10']);
  assert.match(res.headers['content-type'], /^application\/json/);
  assert.equal(res.headers['x-content-type-options'], 'nosniff');
  assert.equal(res.headers['cache-control'], 'public, max-age=60, s-maxage=60');
  assert.deepEqual(JSON.parse(res.body), stored);
});

test('handler: rejects methods/params, 503 for missing, other-month or stale snapshots', async () => {
  const run = async (method, url, stored, nowMs) => {
    const res = fakeRes();
    await ageFs.handlePublicRequest({ method, originalUrl: url }, res, { nowMs: () => nowMs || NOW + Math.random(), readSnapshot: async () => stored });
    return res;
  };
  const post = await run('POST', '/publicLeaderboard?period=current', null);
  assert.equal(post.statusCode, 405);
  assert.equal(post.headers.allow, 'GET, HEAD');
  assert.equal((await run('GET', '/publicLeaderboard?period=2026-09', null)).statusCode, 400);
  assert.equal((await run('GET', '/publicLeaderboard?period=current&x=1', null)).statusCode, 400);
  // Each of these must not be served from the in-memory cache of an earlier test.
  const missing = await run('GET', '/publicLeaderboard?period=all_time', null, NOW + 60000);
  assert.equal(missing.statusCode, 503);
  assert.equal(missing.headers['cache-control'], 'no-store');
  assert.deepEqual(JSON.parse(missing.body), { error: 'leaderboard-unavailable' });
  const old = { schemaVersion: 1, periodKey: 'all_time', generatedAt: '2026-10-03T06:00:00.000Z', entries: [] };
  assert.equal((await run('GET', '/publicLeaderboard?period=all_time', old, NOW + 120000)).statusCode, 503, 'a stopped publisher is not served');
  const head = await run('HEAD', '/publicLeaderboard?period=all_time',
    { schemaVersion: 1, periodKey: 'all_time', generatedAt: '2026-10-03T09:01:00.000Z', entries: [] }, NOW + 180000);
  assert.equal(head.statusCode, 200);
  assert.equal(head.ended, true);
  assert.equal(head.body, undefined);
});

test('raw entry writes: only changes to age inputs are projected', () => {
  const a = rawEntry('u', 100);
  assert.equal(ageFs.rawWriteMatters(a, Object.assign({}, a, { updatedAt: 'later', medalRankKeys: { x: 1 } })), false);
  assert.equal(ageFs.rawWriteMatters(a, Object.assign({}, a, { totalPointsUnits: 1 })), true);
  assert.equal(ageFs.rawWriteMatters(a, Object.assign({}, a, { categoryDateKeys: { hipHinge: '2026-10-02' } })), true);
  assert.equal(ageFs.rawWriteMatters(a, Object.assign({}, a, { username: 'renamed' })), true);
  assert.equal(ageFs.rawWriteMatters(null, a), true);
  assert.equal(ageFs.rawWriteMatters(a, null), true);
  assert.equal(ageFs.rawWriteMatters(null, null), false);
});

test('age entry document carries only what the app needs', () => {
  const raw = rawEntry('u', 300, { formulaVersion: 'lb2' });
  const r = age.adjustAllTime(Object.assign({}, raw, { categoryDateKeys: { hipHinge: '2026-09-01' } }), '01-01-1966', '2026-10-03');
  const doc = ageFs.ageEntryDoc('u', 'all_time', raw, r, true);
  assert.deepEqual(Object.keys(doc).sort(), [
    'adjustedCategoryUnits', 'adjustedTotalUnits', 'ageComplete', 'ageModelVersion', 'leaderboardFormulaVersion',
    'periodKey', 'photoURL', 'rawTotalPointsUnits', 'silverEligible', 'tieBreakDateKey', 'uid', 'username',
  ]);
  assert.equal(doc.adjustedTotalUnits, 358.2 * P);
  const incomplete = ageFs.ageEntryDoc('u', 'all_time', raw, { complete: false, reason: 'missing-dob' }, false);
  assert.equal(incomplete.ageComplete, false);
  assert.equal(incomplete.adjustedTotalUnits, null);
  assert.ok(!JSON.stringify(incomplete).includes('missing-dob'), 'the private reason is not published');
  assert.ok(!JSON.stringify(doc).includes('1966'), 'no birth date');
});

test('age reconciliation: missing, stale-model, drifted, silver candidates and orphans; bounded', async () => {
  const calls = [];
  const raw = [
    { uid: 'ok', totalPointsUnits: 10 * P, tieBreakDateKey: 'd', formulaVersion: 'f' },
    { uid: 'missing', totalPointsUnits: 10 * P },
    { uid: 'stale', totalPointsUnits: 10 * P, tieBreakDateKey: 'd', formulaVersion: 'f' },
    { uid: 'drift', totalPointsUnits: 12 * P, tieBreakDateKey: 'd', formulaVersion: 'f' },
    { uid: 'silver', totalPointsUnits: 300 * P, tieBreakDateKey: 'd', formulaVersion: 'f' },
  ];
  const v = age.AGE_MODEL_VERSION;
  const ages = [
    { uid: 'ok', ageModelVersion: v, rawTotalPointsUnits: 10 * P, tieBreakDateKey: 'd', leaderboardFormulaVersion: 'f' },
    { uid: 'stale', ageModelVersion: 'old', rawTotalPointsUnits: 10 * P, tieBreakDateKey: 'd', leaderboardFormulaVersion: 'f' },
    { uid: 'drift', ageModelVersion: v, rawTotalPointsUnits: 10 * P, tieBreakDateKey: 'd', leaderboardFormulaVersion: 'f' },
    { uid: 'silver', ageModelVersion: v, rawTotalPointsUnits: 300 * P, tieBreakDateKey: 'd', leaderboardFormulaVersion: 'f' },
    { uid: 'orphan', ageModelVersion: v },
  ];
  const { counts } = await ageFs.runAgeReconciliation({
    boards: () => ['all_time'],
    listRawEntries: async (p, limit) => { assert.equal(limit, 5000); return raw; },
    listAgeEntries: async () => ages,
    recompute: async (uid) => { calls.push(uid); return 'set'; },
  });
  assert.deepEqual(calls.sort(), ['drift', 'missing', 'orphan', 'silver', 'stale']);
  assert.equal(counts.checked, 5);
  assert.equal(counts.deleted, 1);
});
