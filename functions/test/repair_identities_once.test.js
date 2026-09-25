'use strict';

// One-time identity repair planner (scripts/repair_identities_once.js).

const test = require('node:test');
const assert = require('node:assert/strict');
const { planAccount, planKey } = require('../scripts/repair_identities_once');
const R = require('../identity/username_rules');

/** Evidence builder: a world of reservations and claims. */
function ev(over = {}, world = {}) {
  const reservations = world.reservations || {};
  const claims = world.claims || {};
  return Object.assign({
    uid: 'u1',
    priv: {},
    pub: {},
    auth: { displayName: null, email: 'person@example.com', providers: [{ providerId: 'password', displayName: null }] },
    owned: [],
    reservationAt: (lower) => reservations[lower] || null,
    claimants: (lower) => claims[lower] || [],
    reportOnly: null,
  }, over);
}

test('consistent account: nothing to do, never renamed', () => {
  const p = planAccount(ev({
    priv: { username: 'NZBench', usernameLower: 'nzbench' },
    pub: { username: 'NZBench', usernameLower: 'nzbench', displayName: 'NZBench' },
    owned: [{ key: R.usernameIndexKey('nzbench'), username: 'NZBench', usernameLower: 'nzbench' }],
    auth: { displayName: 'NZBench', providers: [] },
  }, { reservations: { nzbench: { uid: 'u1', username: 'NZBench', usernameLower: 'nzbench' } }, claims: { nzbench: ['u1'] } }));
  assert.equal(p.status, 'ok');
});

test('missing usernameLower (and public displayName) is repaired in place', () => {
  const p = planAccount(ev({
    priv: { username: 'Lifter' },
    pub: { username: 'Lifter', usernameLower: 'lifter' },
    owned: [{ key: 'k', username: 'Lifter', usernameLower: 'lifter' }],
  }, { reservations: { lifter: { uid: 'u1', username: 'Lifter', usernameLower: 'lifter' } }, claims: { lifter: ['u1'] } }));
  assert.equal(p.status, 'repair');
  assert.deepEqual(p.repairs.priv, { usernameLower: 'lifter' });
  assert.deepEqual(p.repairs.pub, { displayName: 'Lifter' });
  assert.equal(p.repairs.reservation, null);
  assert.equal(p.repairs.auth, 'Lifter', 'Auth follows a username-field repair');
});

test('missing public identity with a valid private username', () => {
  const p = planAccount(ev({ priv: { username: 'helpzie' }, pub: { displayName: 'Helpzie' }, auth: { displayName: 'Helpzie', providers: [] } },
    { claims: { helpzie: ['u1'] } }));
  assert.equal(p.status, 'repair');
  assert.equal(p.username, 'helpzie', 'users.username outranks a legacy displayName');
  assert.deepEqual(p.repairs.pub, { username: 'helpzie', usernameLower: 'helpzie', displayName: 'helpzie' });
  assert.deepEqual(p.repairs.priv, { usernameLower: 'helpzie' });
  assert.equal(p.repairs.reservation, 'create');
});

test('valid legacy displayName promoted to username (password account, Auth agrees)', () => {
  const p = planAccount(ev({ priv: { displayName: 'DylanGale' }, pub: {}, auth: { displayName: 'DylanGale', email: 'd@x.com', providers: [{ providerId: 'password' }] } }));
  assert.equal(p.status, 'repair');
  assert.equal(p.username, 'DylanGale');
  assert.equal(p.source, 'users.displayName');
  assert.deepEqual(p.repairs.priv, { username: 'DylanGale', usernameLower: 'dylangale' });
  assert.deepEqual(p.repairs.pub, { username: 'DylanGale', usernameLower: 'dylangale', displayName: 'DylanGale' });
  assert.equal(p.repairs.reservation, 'create');
  assert.equal(p.repairs.auth, null, 'Auth already says DylanGale');
});

test('invalid displayName containing spaces is never promoted; fullName and email never either', () => {
  const p = planAccount(ev({ priv: { displayName: 'Julien Powell', fullName: 'Julien Powell' }, pub: { fullName: 'Julien Powell' }, auth: { displayName: 'Julien Powell', providers: [{ providerId: 'google.com', displayName: 'Julien Powell' }] } }));
  assert.equal(p.status, 'unresolved');
  assert.match(p.reason, /no valid username evidence/);
  const e = planAccount(ev({ priv: { displayName: 'person' }, pub: {}, auth: { displayName: null, email: 'person@example.com', providers: [] } }));
  assert.equal(e.status, 'unresolved', 'the email prefix is not a username');
});

test('a Google profile name is not an established username', () => {
  const p = planAccount(ev({ priv: { displayName: 'Steven' }, pub: {}, auth: { displayName: 'Steven', providers: [{ providerId: 'google.com', displayName: 'Steven' }] } }));
  assert.equal(p.status, 'unresolved');
});

test('only an Auth displayName is not enough', () => {
  const p = planAccount(ev({ priv: {}, pub: {}, auth: { displayName: 'quinton', providers: [{ providerId: 'password' }] } }));
  assert.equal(p.status, 'unresolved');
  assert.match(p.reason, /only the Auth displayName/);
});

test('username collision: reserved by another uid, contested marker, or claimed elsewhere', () => {
  const base = { priv: { displayName: 'Taken' }, pub: {}, auth: { displayName: 'Taken', providers: [] } };
  assert.match(planAccount(ev(base, { reservations: { taken: { uid: 'other' } } })).reason, /reserved by another account/);
  assert.match(planAccount(ev(base, { reservations: { taken: { username: 'Taken' } } })).reason, /contested/);
  assert.match(planAccount(ev(base, { claims: { taken: ['other'] } })).reason, /also claimed by other/);
});

test('conflicting private/public usernames are reported, not guessed', () => {
  const p = planAccount(ev({ priv: { username: 'alpha' }, pub: { username: 'beta' } }));
  assert.equal(p.status, 'unresolved');
  assert.match(p.reason, /conflicting usernames/);
  const d = planAccount(ev({ priv: { displayName: 'alpha' }, pub: {}, auth: { displayName: 'beta', providers: [] } }));
  assert.match(d.reason, /disagrees with Auth/);
});

test('reservation owned by the same uid is kept; a second owned name is a conflict, not released blindly', () => {
  const key = R.usernameIndexKey('keep');
  const world = { reservations: { keep: { uid: 'u1', username: 'keep', usernameLower: 'keep' } }, claims: { keep: ['u1'] } };
  const ok = planAccount(ev({
    priv: { username: 'keep', usernameLower: 'keep' },
    pub: { username: 'keep', usernameLower: 'keep', displayName: 'keep' },
    owned: [{ key, username: 'keep', usernameLower: 'keep' }],
    auth: { displayName: 'keep', providers: [] },
  }, world));
  assert.equal(ok.status, 'ok');
  const two = planAccount(ev({
    priv: { username: 'keep', usernameLower: 'keep' },
    pub: { username: 'keep', usernameLower: 'keep', displayName: 'keep' },
    owned: [{ key, username: 'keep', usernameLower: 'keep' }, { key: 'oldkey', username: 'old', usernameLower: 'old' }],
  }, world));
  assert.equal(two.status, 'unresolved');
  assert.match(two.reason, /conflicting/);
});

test('reservation owned by another uid blocks even an established username', () => {
  const p = planAccount(ev({ priv: { username: 'mine' }, pub: { username: 'mine' } }, { reservations: { mine: { uid: 'someoneElse' } } }));
  assert.equal(p.status, 'unresolved');
  assert.match(p.reason, /reserved by another account \(someoneElse\)/);
});

test('invalid stored username is reported', () => {
  assert.match(planAccount(ev({ priv: { username: 'has space' }, pub: {} })).reason, /invalid stored username/);
});

test('missing users or users_public document: never created', () => {
  assert.match(planAccount(ev({ priv: null, pub: null })).reason, /missing users and users_public/);
  assert.match(planAccount(ev({ priv: {}, pub: null })).reason, /users_public document/);
});

test('report-only accounts are never repaired', () => {
  const p = planAccount(ev({ priv: { displayName: 'AppleReviewer' }, pub: {}, auth: { displayName: 'AppleReviewer', providers: [] }, reportOnly: 'test account' }));
  assert.equal(p.status, 'unresolved');
  assert.match(p.reason, /report-only/);
});

test('idempotent: the repaired state plans to ok', () => {
  const world = { reservations: {}, claims: { dylangale: ['u1'] } };
  const first = planAccount(ev({ priv: { displayName: 'DylanGale' }, pub: {}, auth: { displayName: 'DylanGale', providers: [] } }, world));
  assert.equal(first.status, 'repair');
  const priv = Object.assign({ displayName: 'DylanGale' }, first.repairs.priv);
  const pub = Object.assign({}, first.repairs.pub);
  world.reservations.dylangale = { uid: 'u1', username: 'DylanGale', usernameLower: 'dylangale' };
  const second = planAccount(ev({ priv, pub, auth: { displayName: 'DylanGale', providers: [] },
    owned: [{ key: R.usernameIndexKey('dylangale'), username: 'DylanGale', usernameLower: 'dylangale' }] }, world));
  assert.equal(second.status, 'ok');
  assert.notEqual(planKey(first), planKey(second));
});

test('a plan only ever writes identity fields (no points, rankings or profile data)', () => {
  const p = planAccount(ev({ priv: { displayName: 'DylanGale', rePoints: 5 }, pub: { profileShowcaseV2: {}, fullName: 'Dylan Gale' }, auth: { displayName: 'DylanGale', providers: [] } }));
  const fields = new Set([...Object.keys(p.repairs.priv), ...Object.keys(p.repairs.pub)]);
  for (const f of fields) assert.ok(['username', 'usernameLower', 'displayName'].includes(f), f);
});
