'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const M = require('../social/buddy_model');

const accepted = () => ({ status: 'accepted' });
const pending = () => ({ status: 'pending' });
const assign = (entries) => ({ athletes: entries });

// ── The security property the mutual rule exists for ────────────────────────

test('buddy model: a self-asserted friendship is not a friendship', () => {
  // `buddyAssignments/{ownerUid}` lets the owner write their own document, so
  // this is a state ANY signed-in account can put itself in unilaterally.
  // Under the old either-side rule it granted read access to the victim's
  // posts, stories and Storage media.
  const attacker = assign({ victim: accepted() });
  const victim = assign({});
  assert.equal(
    M.areMutualFriends(attacker, victim, 'attacker', 'victim'),
    false,
  );
});

test('buddy model: a friendship needs both sides to say accepted', () => {
  assert.equal(
    M.areMutualFriends(
      assign({ b: accepted() }),
      assign({ a: accepted() }),
      'a',
      'b',
    ),
    true,
  );
});

test('buddy model: a one-sided removal ends the friendship', () => {
  // The legacy client deleted only the remover's entry. Under the old
  // either-side rule the survivor kept media access; under the mutual rule it
  // does not.
  assert.equal(
    M.areMutualFriends(assign({}), assign({ a: accepted() }), 'a', 'b'),
    false,
  );
});

test('buddy model: pending on both sides is still not a friendship', () => {
  assert.equal(
    M.areMutualFriends(
      assign({ b: pending() }),
      assign({ a: pending() }),
      'a',
      'b',
    ),
    false,
  );
});

test('buddy model: malformed entries are not accepted', () => {
  for (const bad of [null, undefined, 'accepted', 42, {}, { status: 'x' }]) {
    assert.equal(M.isAccepted(bad), false, `treated ${JSON.stringify(bad)} as accepted`);
  }
  assert.equal(M.areMutualFriends(null, null, 'a', 'b'), false);
});

// ── Relationship state ──────────────────────────────────────────────────────

const stateOf = (o) =>
  M.relationshipState({
    viewerUid: 'me',
    otherUid: 'you',
    viewerAssignment: null,
    otherAssignment: null,
    incomingInvite: null,
    ...o,
  });

test('buddy model: relationship states', () => {
  assert.equal(stateOf({}), 'none');
  assert.equal(stateOf({ otherUid: 'me' }), 'self');
  assert.equal(stateOf({ viewerAssignment: assign({ you: pending() }) }), 'requested');
  assert.equal(stateOf({ incomingInvite: { status: 'pending' } }), 'incoming');
  assert.equal(
    stateOf({
      viewerAssignment: assign({ you: accepted() }),
      otherAssignment: assign({ me: accepted() }),
    }),
    'friends',
  );
});

test('buddy model: an incoming request outranks an outgoing one', () => {
  // Both crossed. Showing "Requested" would tell the user to wait when the
  // other person is the one waiting.
  assert.equal(
    stateOf({
      viewerAssignment: assign({ you: pending() }),
      incomingInvite: { status: 'pending' },
    }),
    'incoming',
  );
});

test('buddy model: a resolved invite does not read as incoming', () => {
  assert.equal(stateOf({ incomingInvite: { status: 'denied' } }), 'none');
  assert.equal(stateOf({ incomingInvite: { status: 'accepted' } }), 'none');
});

// ── Send resolution ─────────────────────────────────────────────────────────

const sendOf = (o) =>
  M.resolveSendOutcome({
    senderUid: 'a',
    targetUid: 'b',
    senderAssignment: null,
    targetAssignment: null,
    outgoingInvite: null,
    incomingInvite: null,
    ...o,
  });

test('buddy model: a first send creates', () => {
  assert.equal(sendOf({}), 'create');
});

test('buddy model: a repeated send does not create a second request', () => {
  assert.equal(sendOf({ outgoingInvite: { status: 'pending' } }), 'already_requested');
});

test('buddy model: sending to an existing friend is a no-op success', () => {
  assert.equal(
    sendOf({
      senderAssignment: assign({ b: accepted() }),
      targetAssignment: assign({ a: accepted() }),
    }),
    'already_friends',
  );
});

test('buddy model: a reverse request resolves into acceptance', () => {
  // Otherwise two crossed pending invites sit forever, each side waiting.
  assert.equal(sendOf({ incomingInvite: { status: 'pending' } }), 'accept_reverse');
});

test('buddy model: a reverse request wins over an outgoing one', () => {
  assert.equal(
    sendOf({
      incomingInvite: { status: 'pending' },
      outgoingInvite: { status: 'pending' },
    }),
    'accept_reverse',
  );
});

test('buddy model: you cannot send to yourself', () => {
  assert.throws(
    () => sendOf({ targetUid: 'a' }),
    (err) => err instanceof M.ValidationError && err.field === 'targetUid',
  );
});

// ── Rate limiting ───────────────────────────────────────────────────────────

test('buddy model: the first request opens a window', () => {
  const r = M.nextRateState(null, 1000);
  assert.equal(r.allowed, true);
  assert.deepEqual(r.state, { windowStart: 1000, count: 1 });
});

test('buddy model: requests are allowed up to the limit, then refused', () => {
  let state = null;
  for (let i = 0; i < M.RATE_LIMIT; i += 1) {
    const r = M.nextRateState(state, 1000);
    assert.equal(r.allowed, true, `refused at attempt ${i + 1}`);
    state = r.state;
  }
  const over = M.nextRateState(state, 1000);
  assert.equal(over.allowed, false);
  assert.ok(over.retryAfterMs > 0);
});

test('buddy model: the window reopens once it has elapsed', () => {
  const state = { windowStart: 1000, count: M.RATE_LIMIT };
  assert.equal(M.nextRateState(state, 1000 + M.RATE_WINDOW_MS - 1).allowed, false);
  const reopened = M.nextRateState(state, 1000 + M.RATE_WINDOW_MS);
  assert.equal(reopened.allowed, true);
  assert.deepEqual(reopened.state, {
    windowStart: 1000 + M.RATE_WINDOW_MS,
    count: 1,
  });
});

test('buddy model: a corrupt counter fails open into a fresh window', () => {
  // A missing or malformed document must not lock an account out of the
  // feature permanently.
  for (const bad of [{}, { windowStart: 'x' }, { count: 3 }]) {
    assert.equal(M.nextRateState(bad, 5000).allowed, true);
  }
});

// ── Argument validation ─────────────────────────────────────────────────────

test('buddy model: uid arguments are validated', () => {
  assert.equal(M.requireUid('  abc  ', 'uid'), 'abc');
  for (const bad of [null, undefined, '', '   ', 42, {}, 'x'.repeat(129)]) {
    assert.throws(
      () => M.requireUid(bad, 'uid'),
      (err) => err instanceof M.ValidationError,
      `accepted ${JSON.stringify(bad)}`,
    );
  }
});

test('buddy model: acceptedUids lists only accepted entries', () => {
  assert.deepEqual(
    M.acceptedUids(assign({ a: accepted(), b: pending(), c: accepted() })).sort(),
    ['a', 'c'],
  );
  assert.deepEqual(M.acceptedUids(null), []);
});
