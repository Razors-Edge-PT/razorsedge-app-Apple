'use strict';

// "Your buddy request was accepted" — the decision logic, with no Firestore.
// The transactional adapter is exercised against the emulator in
// test-emulator/social_notifications.spec.js.

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'goodlift-us-storage';
process.env.FUNCTIONS_EMULATOR = 'true';

const N = require('../social/notifications');

const pending = { status: 'pending', fromUid: 'alice', buddyUid: 'bob' };
const accepted = { status: 'accepted', fromUid: 'alice', buddyUid: 'bob' };
const denied = { status: 'denied', fromUid: 'alice', buddyUid: 'bob' };

// ── What counts as an acceptance ────────────────────────────────────────────

test('only a pending → accepted invite is an acceptance', () => {
  assert.equal(N.inviteChange(pending, accepted), N.InviteChange.ACCEPTED);
});

test('historical and scripted accepted invites announce nothing', () => {
  // Already accepted before deployment, re-stamped by a retry or a merge.
  assert.equal(N.inviteChange(accepted, accepted), N.InviteChange.NONE);
  assert.equal(
    N.inviteChange(accepted, { ...accepted, respondedAt: 'later' }),
    N.InviteChange.NONE,
  );
  // An invite that APPEARS already accepted (a repair script, a restore) has
  // no pending predecessor and is not an acceptance anybody just made.
  assert.equal(N.inviteChange(null, accepted), N.InviteChange.NONE);
});

test('declines, sends and edits announce nothing', () => {
  assert.equal(N.inviteChange(null, pending), N.InviteChange.NONE);
  assert.equal(N.inviteChange(pending, denied), N.InviteChange.NONE);
  assert.equal(N.inviteChange(pending, pending), N.InviteChange.NONE);
  assert.equal(N.inviteChange(denied, accepted), N.InviteChange.NONE);
});

test('a deleted invite may end a notice', () => {
  assert.equal(N.inviteChange(accepted, null), N.InviteChange.REMOVED);
  assert.equal(N.inviteChange(pending, null), N.InviteChange.REMOVED);
  assert.equal(N.inviteChange(null, null), N.InviteChange.NONE);
});

// ── What to do about it ─────────────────────────────────────────────────────

test('a confirmed acceptance creates the notice', () => {
  assert.deepEqual(
    N.decideNotice({ change: 'accepted', mutual: true, existing: null, eventId: 'e1' }),
    { action: 'create', reason: 'accepted' },
  );
});

test('an acceptance the other side has not confirmed announces nothing', () => {
  assert.equal(
    N.decideNotice({ change: 'accepted', mutual: false, existing: null, eventId: 'e1' }).action,
    'none',
  );
});

test('a redelivered event writes nothing — not even to reset a seen notice', () => {
  const seen = { seen: true, sourceEventId: 'e1' };
  assert.deepEqual(
    N.decideNotice({ change: 'accepted', mutual: true, existing: seen, eventId: 'e1' }),
    { action: 'none', reason: 'duplicate-delivery' },
  );
});

test('a NEW acceptance after an unfriend notifies again', () => {
  const old = { seen: true, sourceEventId: 'e1' };
  assert.equal(
    N.decideNotice({ change: 'accepted', mutual: true, existing: old, eventId: 'e2' }).action,
    'create',
  );
});

test('removing an invite clears the notice only once the friendship has ended', () => {
  const existing = { seen: false, sourceEventId: 'e1' };
  assert.equal(
    N.decideNotice({ change: 'removed', mutual: false, existing, eventId: 'e2' }).action,
    'delete',
  );
  assert.equal(
    N.decideNotice({ change: 'removed', mutual: true, existing, eventId: 'e2' }).action,
    'none',
    'a receiver tidying an old invite changes nothing',
  );
  assert.equal(
    N.decideNotice({ change: 'removed', mutual: false, existing: null, eventId: 'e2' }).action,
    'none',
  );
});

// ── Shape and address ───────────────────────────────────────────────────────

test('the notice is unread, names the acceptor and records its source event', () => {
  const now = { serverTimestamp: true };
  assert.deepEqual(
    N.acceptedNotice({ acceptorUid: 'bob', eventId: 'e1', acceptedAt: null, now }),
    {
      type: 'buddyAccepted',
      otherUid: 'bob',
      seen: false,
      createdAt: now,
      acceptedAt: now,
      sourceEventId: 'e1',
    },
  );
});

test('the notice goes to the SENDER, keyed by the acceptor, one per pair', () => {
  const paths = [];
  const fakeDb = {
    collection: (c) => ({
      doc: (d) => ({
        collection: (s) => ({
          doc: (id) => {
            const p = `${c}/${d}/${s}/${id}`;
            paths.push(p);
            return { path: p };
          },
        }),
      }),
    }),
  };
  // alice asked, bob accepted.
  assert.equal(
    N.acceptedNoticeRef(fakeDb, 'alice', 'bob').path,
    'users/alice/socialNotifications/buddyAccepted_bob',
  );
  // Deterministic: however often it is computed, it is the same document.
  assert.equal(N.acceptedNoticeId('bob'), N.acceptedNoticeId('bob'));
  assert.notEqual(N.acceptedNoticeId('bob'), N.acceptedNoticeId('carol'));
});

test('a self-invite or a missing party is never processed', async () => {
  const neverTouched = {
    runTransaction() { throw new Error('must not open a transaction'); },
    collection() { throw new Error('must not read'); },
  };
  assert.deepEqual(
    await N.applyInviteWrite(neverTouched, {
      receiverUid: 'alice', senderUid: 'alice', beforeData: pending, afterData: accepted, eventId: 'e',
    }),
    { action: 'none', reason: 'invalid-pair' },
  );
  assert.deepEqual(
    await N.applyInviteWrite(neverTouched, {
      receiverUid: 'bob', senderUid: 'alice', beforeData: accepted, afterData: accepted, eventId: 'e',
    }),
    { action: 'none', reason: 'not-an-acceptance' },
  );
});

test('index.js exports the invite trigger', () => {
  const idx = require('../index');
  assert.ok(idx.socialOnBuddyInviteWritten, 'socialOnBuddyInviteWritten missing');
  // The relationship callables are untouched and still exported.
  for (const name of ['buddySendRequest', 'buddyRespondToRequest', 'buddyCancelRequest', 'buddyRemoveFriend']) {
    assert.ok(idx[name], `${name} missing`);
  }
});
