// The projection verifier: does socialGraph agree with the authority, and is
// any feed still holding a stranger's post?
//
// ── Why this needs its own tests ───────────────────────────────────────────
// A verifier that reports "clean" when it is not is worse than no verifier —
// it is the thing standing between a rules deploy and a silent access change,
// and its only job is to disagree when the projections disagree. So the tests
// below are mostly about it FAILING correctly: a stale friend list, a feed row
// by an ex-friend, a projection that never got written at all.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  athletesOf,
  isAccepted,
  readAuthority,
  diff,
} = require('../scripts/verify_social_projections');

const accepted = () => ({ status: 'accepted' });

/** A Firestore stand-in exposing only what readAuthority uses. */
function fakeDb(assignments) {
  return {
    collection(name) {
      assert.equal(name, 'buddyAssignments');
      return {
        async get() {
          return {
            size: Object.keys(assignments).length,
            docs: Object.entries(assignments).map(([id, data]) => ({
              id,
              data: () => data,
            })),
          };
        },
      };
    },
  };
}

const graphOf = (obj) =>
  new Map(
    Object.entries(obj).map(([uid, friends]) => [
      uid,
      friends === null
        ? { exists: false, friends: null }
        : { exists: true, friends: [...friends].sort() },
    ]),
  );

const feedsOf = (obj) =>
  new Map(
    Object.entries(obj).map(([uid, owners]) => [
      uid,
      {
        rows: Object.values(owners).reduce((a, b) => a + b, 0),
        owners: new Map(Object.entries(owners)),
      },
    ]),
  );

test('authority: a friendship needs both sides, as the rules require', async () => {
  const db = fakeDb({
    a: { athletes: { b: accepted(), c: accepted() } },
    b: { athletes: { a: accepted() } },
    c: { athletes: {} },
  });
  const { mutual } = await readAuthority(db);
  assert.deepEqual(mutual.get('a'), ['b'], 'c never accepted back');
  assert.deepEqual(mutual.get('b'), ['a']);
  assert.deepEqual(mutual.get('c'), []);
});

test('authority: a self-entry is not a friendship', async () => {
  const db = fakeDb({ a: { athletes: { a: accepted() } } });
  const { mutual } = await readAuthority(db);
  assert.deepEqual(mutual.get('a'), []);
});

test('authority: a pending or status-less entry is not a friendship', async () => {
  const db = fakeDb({
    a: { athletes: { b: { status: 'pending' }, c: { displayName: 'x' } } },
    b: { athletes: { a: accepted() } },
    c: { athletes: { a: accepted() } },
  });
  const { mutual } = await readAuthority(db);
  assert.deepEqual(mutual.get('a'), []);
});

test('verify: matching projections report clean', () => {
  const mutual = new Map([
    ['a', ['b']],
    ['b', ['a']],
  ]);
  const result = diff({
    mutual,
    graph: graphOf({ a: ['b'], b: ['a'] }),
    feeds: feedsOf({ a: { a: 2, b: 3 }, b: { b: 1 } }),
  });
  assert.deepEqual(result.graphMismatches, []);
  assert.deepEqual(result.feedLeaks, []);
});

test('verify: a missing socialGraph document is a mismatch, not a pass', () => {
  // The exact production state before the backfill: the authority is right and
  // nothing has projected it. Treating "no document" as "no friends, fine"
  // would report clean while every user sees an empty buddy list.
  const result = diff({
    mutual: new Map([['a', ['b']]]),
    graph: graphOf({ a: null }),
    feeds: feedsOf({ a: {} }),
  });
  assert.equal(result.graphMismatches.length, 1);
  assert.equal(result.graphMismatches[0].uid, 'a');
  assert.equal(result.graphMismatches[0].graphExists, false);
});

test('verify: a stale friend left in the projection is caught', () => {
  const result = diff({
    mutual: new Map([['a', ['b']]]),
    graph: graphOf({ a: ['b', 'ghost'] }),
    feeds: feedsOf({ a: {} }),
  });
  assert.equal(result.graphMismatches.length, 1);
  assert.deepEqual(result.graphMismatches[0].projected, ['b', 'ghost']);
  assert.deepEqual(result.graphMismatches[0].expected, ['b']);
});

test('verify: a friend missing from the projection is caught', () => {
  const result = diff({
    mutual: new Map([['a', ['b', 'c']]]),
    graph: graphOf({ a: ['b'] }),
    feeds: feedsOf({ a: {} }),
  });
  assert.equal(result.graphMismatches.length, 1);
});

test('verify: an empty projection for someone with no friends is correct', () => {
  const result = diff({
    mutual: new Map([['a', []]]),
    graph: graphOf({ a: [] }),
    feeds: feedsOf({ a: {} }),
  });
  assert.deepEqual(result.graphMismatches, []);
});

test('verify: a feed row by an ex-friend is reported', () => {
  // The one that matters most after an unfriending: content the viewer can
  // still see listed. The row itself does not grant media access — the posts
  // and Storage rules are evaluated separately — but it should not be there.
  const result = diff({
    mutual: new Map([['a', ['b']]]),
    graph: graphOf({ a: ['b'] }),
    feeds: feedsOf({ a: { b: 2, exfriend: 4 } }),
  });
  assert.equal(result.feedLeaks.length, 1);
  assert.deepEqual(result.feedLeaks[0], {
    viewerUid: 'a',
    ownerUid: 'exfriend',
    rows: 4,
  });
});

test('verify: a viewer\'s own posts in their own feed are not a leak', () => {
  const result = diff({
    mutual: new Map([['a', []]]),
    graph: graphOf({ a: [] }),
    feeds: feedsOf({ a: { a: 5 } }),
  });
  assert.deepEqual(result.feedLeaks, []);
});

test('verify: helpers read malformed data defensively', () => {
  assert.deepEqual(athletesOf(null), {});
  assert.deepEqual(athletesOf({ athletes: 'nope' }), {});
  assert.equal(isAccepted({ status: 'accepted' }), true);
  assert.equal(isAccepted({ status: 'pending' }), false);
  assert.equal(isAccepted(undefined), false);
});
