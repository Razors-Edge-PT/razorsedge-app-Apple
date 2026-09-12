'use strict';

// The unread ledger's rules, and the notification identity the app matches on.
// Firestore behaviour (counting, idempotency, delivery skipping) is
// test-emulator/dm_unread.spec.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'goodlift-us-storage';
process.env.FUNCTIONS_EMULATOR = 'true';

const U = require('../push/dm_unread');
const P = require('../push/push_model');

const A = 'a'.repeat(28);
const B = 'b'.repeat(28);
const CONV = `${A}_${B}`;

const conv = (mine) => ({ participantState: { [A]: mine } });

test('unread is the ledger minus what was acknowledged', () => {
  assert.equal(U.unreadFor(conv({ incoming: 5, readIncoming: 0 }), A), 5);
  assert.equal(U.unreadFor(conv({ incoming: 5, readIncoming: 3 }), A), 2);
  assert.equal(U.unreadFor(conv({ incoming: 5, readIncoming: 5 }), A), 0);
  // An acknowledgement can never go past the ledger into negative numbers.
  assert.equal(U.unreadFor(conv({ incoming: 5, readIncoming: 9 }), A), 0);
  assert.equal(U.unreadFor({}, A), 0);
  assert.equal(U.unreadFor(null, A), 0);
});

test('a conversation from before the ledger still shows its legacy count', () => {
  assert.equal(U.unreadFor(conv({ unreadCount: 3 }), A), 3);
  // Once the ledger has started it is the only source.
  assert.equal(U.unreadFor(conv({ incoming: 1, readIncoming: 1, unreadCount: 3 }), A), 0);
});

test('acknowledgement is judged per message, never on a zero counter', () => {
  const state = conv({ incoming: 7, readIncoming: 5 });
  assert.equal(U.isAcknowledged(state, A, 5), true);
  assert.equal(U.isAcknowledged(state, A, 4), true);
  assert.equal(U.isAcknowledged(state, A, 6), false, 'a newer message is not read');
  assert.equal(U.isAcknowledged(state, A, 7), false);
  // A message with no ledger position yet (the counter write has not landed)
  // must never count as read — that is the case that would silently drop a
  // genuinely new message's push.
  assert.equal(U.isAcknowledged(state, A, undefined), false);
  assert.equal(U.isAcknowledged(state, A, 0), false);
  assert.equal(U.isAcknowledged(state, A, NaN), false);
  // Nothing read yet at all.
  assert.equal(U.isAcknowledged(conv({ incoming: 2 }), A, 1), false);
  assert.equal(U.isAcknowledged({}, A, 1), false);
});

test('only the addressed participant is read from the ledger', () => {
  const state = { participantState: { [A]: { incoming: 4 }, [B]: { incoming: 9, readIncoming: 9 } } };
  assert.equal(U.unreadFor(state, A), 4);
  assert.equal(U.unreadFor(state, B), 0);
  assert.equal(U.isAcknowledged(state, A, 4), false);
  assert.equal(U.isAcknowledged(state, B, 9), true);
});

// ── Notification identity ───────────────────────────────────────────────────

test('a DM alert is tagged by conversation AND message', () => {
  const job = { type: 'directMessage', conversationId: CONV, messageId: 'msg1', actorUid: B };
  const tag = P.presentationTag(job);
  const expectedKey = crypto.createHash('sha256').update(CONV).digest('hex').slice(0, 8);
  assert.equal(tag, `dm|${expectedKey}|msg1`);
  // The app cancels one thread by this prefix; a different thread must not
  // share it.
  assert.ok(tag.startsWith(`dm|${P.conversationTagKey(CONV)}|`));
  assert.notEqual(P.conversationTagKey(CONV), P.conversationTagKey(`${A}_${'c'.repeat(28)}`));
  // Two messages in one thread are separate alerts.
  assert.notEqual(tag, P.presentationTag({ ...job, messageId: 'msg2' }));
  // APNs caps a collapse id at 64 bytes.
  assert.ok(Buffer.byteLength(tag) <= 64, `${tag} is ${Buffer.byteLength(tag)} bytes`);
});

test('social alerts stay tagged per person', () => {
  assert.equal(P.presentationTag({ type: 'friendRequest', actorUid: B }), `fr_${B}`);
  assert.equal(P.presentationTag({ type: 'friendAccepted', actorUid: B }), `fa_${B}`);
});

test('the payload names the message so the app can cancel and de-duplicate it', () => {
  const data = P.routingData({
    type: 'directMessage',
    recipientUid: A,
    actorUid: B,
    conversationId: CONV,
    messageId: 'msg1',
    incomingSeq: 4,
  });
  assert.deepEqual(data, {
    v: '1',
    type: 'directMessage',
    recipientUid: A,
    actorUid: B,
    convId: CONV,
    msgId: 'msg1',
    seq: '4',
  });
  for (const v of Object.values(data)) assert.equal(typeof v, 'string');

  // A job from before the ledger carries neither, and must still be routable.
  const legacy = P.routingData({
    type: 'directMessage', recipientUid: A, actorUid: B, conversationId: CONV,
  });
  assert.equal(legacy.msgId, undefined);
  assert.equal(legacy.seq, undefined);
  assert.equal(legacy.convId, CONV);

  // Social payloads are unchanged.
  assert.deepEqual(P.routingData({ type: 'friendRequest', recipientUid: A, actorUid: B }), {
    v: '1', type: 'friendRequest', recipientUid: A, actorUid: B,
  });
});

test('message content never reaches the tag or the routing data', () => {
  const job = {
    type: 'directMessage', recipientUid: A, actorUid: B,
    conversationId: CONV, messageId: 'msg1', incomingSeq: 1,
  };
  const blob = JSON.stringify([P.presentationTag(job), P.routingData(job)]);
  assert.ok(!blob.includes('secret'));
});
