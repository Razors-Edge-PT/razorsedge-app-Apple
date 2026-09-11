'use strict';

// Push notifications — the pure model: what is a notification, who gets it,
// what it says, and how FCM results are treated. No Firestore, no FCM.
// Delivery against real Firestore is test-emulator/push_delivery.spec.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || 'goodlift-us-storage';
process.env.FUNCTIONS_EMULATOR = 'true';

const P = require('../push/push_model');

const ts = (seconds, nanoseconds = 0) => ({ seconds, nanoseconds, toMillis: () => seconds * 1000 });
const A = 'a'.repeat(28);
const B = 'b'.repeat(28);
const CONV = `${A}_${B}`;

// ── Friend requests ─────────────────────────────────────────────────────────

test('a request is new only when it BECOMES pending', () => {
  const pending = { status: 'pending', fromUid: A, buddyUid: B, createdAt: ts(10) };
  assert.equal(P.isNewPendingRequest(null, pending), true, 'first request');
  assert.equal(P.isNewPendingRequest({ status: 'denied' }, pending), true, 're-sent after a decline');
  assert.equal(P.isNewPendingRequest({ status: 'accepted' }, pending), true, 're-sent over a stale accepted invite');
  assert.equal(P.isNewPendingRequest(pending, { ...pending, fromDisplayName: 'x' }), false, 'repair/edit');
  assert.equal(P.isNewPendingRequest(pending, pending), false, 'repeated Add');
  assert.equal(P.isNewPendingRequest(pending, { status: 'denied' }), false, 'decline');
  assert.equal(P.isNewPendingRequest(pending, null), false, 'cancel');
  assert.equal(P.isNewPendingRequest(pending, { status: 'accepted' }), false, 'accept');
});

test('an invite must name its own path\'s parties', () => {
  assert.equal(P.inviteMatchesPath({ fromUid: A, buddyUid: B }, B, A), true);
  assert.equal(P.inviteMatchesPath({ fromUid: A, buddyUid: 'c' }, B, A), false);
  assert.equal(P.inviteMatchesPath({ fromUid: 'c', buddyUid: B }, B, A), false);
  assert.equal(P.inviteMatchesPath({}, A, A), false, 'self-request');
});

test('request occurrence is the invite createdAt to the nanosecond', () => {
  assert.equal(P.inviteOccurrence({ createdAt: ts(1700000000, 123) }, 'e1'), 'c:1700000000.000000123');
  assert.notEqual(
    P.inviteOccurrence({ createdAt: ts(1700000000, 123) }),
    P.inviteOccurrence({ createdAt: ts(1700000000, 124) }),
  );
  assert.equal(P.inviteOccurrence({}, 'evt-9'), 'e:evt-9', 'legacy invite without createdAt');
});

test('job ids are deterministic per (type, recipient, occurrence)', () => {
  const j1 = P.jobIdFor('friendRequest', B, `${A}|c:1.0`);
  assert.equal(j1, P.jobIdFor('friendRequest', B, `${A}|c:1.0`));
  assert.match(j1, /^fr_[0-9a-f]{40}$/);
  assert.notEqual(j1, P.jobIdFor('friendRequest', B, `${A}|c:2.0`), 'a new request after a decline');
  assert.notEqual(j1, P.jobIdFor('friendAccepted', B, `${A}|c:1.0`));
  assert.notEqual(j1, P.jobIdFor('friendRequest', A, `${A}|c:1.0`));
  assert.throws(() => P.jobIdFor('marketing', B, 'x'));
});

// ── Direct messages ─────────────────────────────────────────────────────────

test('text is deliverable when saved; media only once attached', () => {
  assert.equal(P.messageKind({ senderId: A, type: 'text', text: 'hi' }), 'text');
  assert.equal(P.messageKind({ senderId: A, text: 'legacy, no type' }), 'text');
  assert.equal(P.messageKind({ senderId: A, type: 'text', text: '   ' }), null);
  assert.equal(P.messageKind({ senderId: A, type: 'image', text: '' }), null, 'upload shell');
  assert.equal(P.messageKind({ senderId: A, type: 'video', text: '' }), null, 'upload shell');
  assert.equal(P.messageKind({ senderId: A, type: 'image', text: '', imageUrl: 'https://x/i' }), 'photo');
  assert.equal(P.messageKind({ senderId: A, type: 'video', text: '', videoUrl: 'https://x/v' }), 'video');
  assert.equal(P.messageKind({ senderId: A, type: 'image', text: 'caption', imageUrl: '' }), null,
    'a shell is not deliverable even with text');
});

test('a message notifies exactly once — at the write that makes it deliverable', () => {
  const shell = { senderId: A, type: 'image', text: '' };
  const ready = { ...shell, imageUrl: 'https://x/i' };
  assert.equal(P.becameDeliverable(null, shell), false, 'shell created');
  assert.equal(P.becameDeliverable(shell, ready), true, 'upload attached');
  assert.equal(P.becameDeliverable(ready, { ...ready, reactions: { [B]: '🔥' } }), false, 'reaction');
  assert.equal(P.becameDeliverable(ready, { ...ready, imageUrl: 'https://x/j' }), false, 'URL rewritten');
  assert.equal(P.becameDeliverable(shell, { ...shell, reactions: { [B]: '🔥' } }), false, 'failed upload stays silent');
  const text = { senderId: A, type: 'text', text: 'hi' };
  assert.equal(P.becameDeliverable(null, text), true);
  assert.equal(P.becameDeliverable(text, text), false, 'redelivered event');
  assert.equal(P.becameDeliverable(text, null), false);
});

test('the recipient is the OTHER account named by the conversation id', () => {
  const conv = { participants: { [A]: true, [B]: true } };
  assert.deepEqual(
    P.resolveDmParties({ convId: CONV, messageData: { senderId: A }, conversationData: conv }),
    { senderUid: A, recipientUid: B },
  );
  assert.deepEqual(
    P.resolveDmParties({ convId: CONV, messageData: { senderId: B }, conversationData: conv }),
    { senderUid: B, recipientUid: A },
  );
});

test('forged or inconsistent messages have no recipient', () => {
  const conv = { participants: { [A]: true, [B]: true } };
  const C = 'c'.repeat(28);
  const reason = (args) => P.resolveDmParties(args).reason;
  assert.equal(reason({ convId: CONV, messageData: { senderId: C }, conversationData: conv }), 'sender-not-in-conversation');
  assert.equal(reason({ convId: CONV, messageData: {}, conversationData: conv }), 'no-sender');
  assert.equal(reason({ convId: 'nonsense', messageData: { senderId: A } }), 'bad-conversation-id');
  assert.equal(reason({ convId: `${A}_${A}`, messageData: { senderId: A } }), 'bad-conversation-id', 'self conversation');
  assert.equal(
    reason({ convId: CONV, messageData: { senderId: A }, conversationData: { participants: { [A]: true, [C]: true } } }),
    'participants-mismatch',
  );
  assert.equal(
    reason({ convId: CONV, messageData: { senderId: A }, conversationData: { participants: { [A]: true, [B]: true, [C]: true } } }),
    'participants-mismatch',
  );
  assert.equal(
    reason({ convId: CONV, messageData: { senderId: A }, conversationData: { participants: { [A]: true, [B]: false } } }),
    'participants-mismatch',
  );
});

// ── Preferences and presentation ────────────────────────────────────────────

test('categories default ON, message previews default OFF', () => {
  assert.deepEqual(P.preferencesFrom(null), {
    friendRequests: true, friendAccepted: true, directMessages: true, messagePreviews: false,
  });
  const p = P.preferencesFrom({ directMessages: false, messagePreviews: 'yes' });
  assert.equal(P.typeEnabled(p, 'directMessage'), false);
  assert.equal(P.typeEnabled(p, 'friendRequest'), true);
  assert.equal(p.messagePreviews, false, 'a malformed value never turns previews on');
});

test('notification wording for the three events', () => {
  assert.deepEqual(P.renderNotification({ type: 'friendRequest', actorName: 'Sam' }),
    { title: 'Friend request', body: 'Sam sent you a friend request' });
  assert.deepEqual(P.renderNotification({ type: 'friendAccepted', actorName: 'Sam' }),
    { title: 'Friend request accepted', body: 'Sam accepted your friend request' });
  assert.equal(P.renderNotification({ type: 'directMessage', actorName: 'Sam', kind: 'text', text: 'secret' }).body,
    'Sam sent you a message');
  assert.equal(P.renderNotification({ type: 'directMessage', actorName: 'Sam', kind: 'photo' }).body, 'Sam sent you a photo');
  assert.equal(P.renderNotification({ type: 'directMessage', actorName: 'Sam', kind: 'video' }).body, 'Sam sent you a video');
});

test('message text appears only with previews on, and is truncated', () => {
  const off = P.renderNotification({ type: 'directMessage', actorName: 'Sam', kind: 'text', text: 'my PIN is 1234', previews: false });
  assert.ok(!JSON.stringify(off).includes('1234'));
  const on = P.renderNotification({ type: 'directMessage', actorName: 'Sam', kind: 'text', text: 'see you at 6', previews: true });
  assert.deepEqual(on, { title: 'Sam', body: 'see you at 6' });
  const long = P.renderNotification({ type: 'directMessage', actorName: 'Sam', kind: 'text', text: 'x'.repeat(500), previews: true });
  assert.equal(Array.from(long.body).length, 120);
});

test('display name follows the app\'s bestName order', () => {
  assert.equal(P.displayNameFrom({ displayName: 'Sam S', fullName: 'Samuel', username: 'sam' }), 'Sam S');
  assert.equal(P.displayNameFrom({ fullName: 'Samuel', username: 'sam' }), 'Samuel');
  assert.equal(P.displayNameFrom({ username: 'sam' }), 'sam');
  assert.equal(P.displayNameFrom(null), 'A GoodLift member');
});

test('the FCM message is user-visible, routable, expiring and collapsible', () => {
  const nowMs = Date.UTC(2026, 8, 11, 0, 0, 0);
  const job = {
    id: 'dm_x', type: 'directMessage', recipientUid: B, actorUid: A,
    conversationId: CONV, messageId: 'm1', expiresAt: { toMillis: () => nowMs + 3600_000 },
  };
  const msg = P.buildMessage({ job, rendered: { title: 't', body: 'b' }, nowMs });
  assert.deepEqual(msg.notification, { title: 't', body: 'b' });
  assert.deepEqual(msg.data, { v: '1', type: 'directMessage', recipientUid: B, actorUid: A, convId: CONV });
  for (const v of Object.values(msg.data)) assert.equal(typeof v, 'string');
  assert.equal(msg.android.ttl, 3600_000);
  assert.equal(msg.android.notification.channelId, 'goodlift_direct_messages');
  assert.equal(msg.android.notification.tag, 'dm_m1');
  assert.equal(msg.android.notification.icon, 'ic_stat_goodlift');
  assert.equal(msg.apns.headers['apns-collapse-id'], 'dm_m1');
  assert.equal(msg.apns.headers['apns-expiration'], String(Math.floor((nowMs + 3600_000) / 1000)));
  assert.equal(msg.apns.headers['apns-push-type'], 'alert');
  assert.ok(Buffer.byteLength(msg.apns.headers['apns-collapse-id']) <= 64);
  assert.equal(msg.token, undefined, 'the token is added per device by the worker');

  const fr = P.buildMessage({
    job: { ...job, type: 'friendRequest', conversationId: undefined },
    rendered: { title: 't', body: 'b' }, nowMs,
  });
  assert.equal(fr.data.convId, undefined);
  assert.equal(fr.android.notification.channelId, 'goodlift_friend_requests');
  assert.equal(fr.android.notification.tag, `fr_${A}`);
  assert.ok(Buffer.byteLength(fr.apns.headers['apns-collapse-id']) <= 64);
});

test('registration ids are the lowercase SHA-256 of the token', () => {
  const t = 'token:abc';
  assert.equal(P.deviceIdForToken(t), crypto.createHash('sha256').update(t).digest('hex'));
  assert.equal(P.tokenLabel(t).length, 10);
  assert.ok(!P.tokenLabel(t).includes('abc'));
});

// ── FCM results and the job state machine ───────────────────────────────────

test('only token errors delete a registration; INVALID_ARGUMENT needs a proven payload', () => {
  assert.equal(P.classifySendError('messaging/registration-token-not-registered'), 'invalid');
  assert.equal(P.classifySendError('messaging/invalid-registration-token'), 'invalid');
  assert.equal(P.classifySendError('messaging/invalid-argument'), 'failed');
  assert.equal(P.classifySendError('messaging/invalid-argument', { payloadProvenValid: true }), 'invalid');
  assert.equal(P.classifySendError('messaging/third-party-auth-error'), 'failed', 'APNs key problem is not the token');
  for (const code of ['messaging/server-unavailable', 'messaging/internal-error', 'messaging/message-rate-exceeded', 'app/network-error', undefined]) {
    assert.equal(P.classifySendError(code), 'retry', String(code));
  }
});

test('claiming: terminal, expired, exhausted, busy and abandoned jobs', () => {
  const now = 1_000_000;
  const future = { toMillis: () => now + 1000 };
  const past = { toMillis: () => now - 1 };
  assert.equal(P.claimDecision(null, now).reason, 'missing');
  for (const status of ['sent', 'skipped', 'expired', 'failed']) {
    assert.equal(P.claimDecision({ status, expiresAt: future }, now).claim, false);
  }
  assert.deepEqual(P.claimDecision({ status: 'pending', expiresAt: past }, now),
    { claim: false, reason: 'expired', finalize: 'expired' });
  assert.equal(P.claimDecision({ status: 'pending', expiresAt: future, attempts: P.MAX_ATTEMPTS }, now).finalize, 'failed');
  assert.equal(P.claimDecision({ status: 'sending', expiresAt: future, lease: { until: future } }, now).reason, 'busy');
  assert.equal(P.claimDecision({ status: 'sending', expiresAt: future, lease: { until: past } }, now).reason, 'lease-expired');
  assert.equal(P.claimDecision({ status: 'pending', expiresAt: future, attempts: 2 }, now).claim, true);
});

test('status after an attempt', () => {
  assert.equal(P.statusAfterAttempt({ a: 'sent', b: 'retry' }), 'pending');
  assert.equal(P.statusAfterAttempt({ a: 'sent', b: 'invalid' }), 'sent');
  assert.equal(P.statusAfterAttempt({ a: 'invalid', b: 'failed' }), 'failed');
});

test('delivery windows are bounded well under FCM\'s 28-day default', () => {
  for (const t of P.ALL_TYPES) {
    assert.ok(P.DELIVERY_WINDOW_MS[t] <= 24 * 3600_000, t);
    assert.ok(P.PREFERENCE_FIELD[t], t);
    assert.ok(P.ANDROID_CHANNEL[t], t);
  }
  assert.deepEqual(P.ALL_TYPES.sort(), ['directMessage', 'friendAccepted', 'friendRequest']);
});

test('the push module is wired into index.js and changes nothing else', () => {
  const idx = require('../index');
  assert.ok(idx.pushOnDirectMessageWritten);
  assert.ok(idx.pushOutboxOnCreated);
  assert.ok(idx.socialOnBuddyInviteWritten);
  const pushExports = Object.keys(idx).filter((k) => /^push/.test(k));
  assert.deepEqual(pushExports.sort(), ['pushOnDirectMessageWritten', 'pushOutboxOnCreated']);
});
