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

test('categories default ON, previews default OFF', () => {
  assert.deepEqual(P.preferencesFrom(null), {
    friendRequests: true,
    friendAccepted: true,
    directMessages: true,
    messageReactions: true,
    postComments: true,
    postReactions: true,
    messagePreviews: false,
    commentPreviews: false,
  });
  const p = P.preferencesFrom({ directMessages: false, messagePreviews: 'yes' });
  assert.equal(P.typeEnabled(p, 'directMessage'), false);
  assert.equal(P.typeEnabled(p, 'friendRequest'), true);
  assert.equal(p.messagePreviews, false, 'a malformed value never turns previews on');
});

test('a saved preference document from an older build keeps its answers, and '
  + 'gets the new categories switched on', () => {
  // What an account that opened Settings before this release has stored.
  const saved = {
    friendRequests: false,
    friendAccepted: true,
    directMessages: true,
    messagePreviews: true,
  };
  const p = P.preferencesFrom(saved);
  assert.equal(p.friendRequests, false, 'their answer is not overwritten');
  assert.equal(p.messagePreviews, true);
  assert.equal(P.typeEnabled(p, 'postComment'), true);
  assert.equal(P.typeEnabled(p, 'postLike'), true);
  assert.equal(P.typeEnabled(p, 'postGoodLift'), true);
  assert.equal(P.typeEnabled(p, 'dmReaction'), true);
  assert.equal(p.commentPreviews, false, 'a new preview switch starts off');
});

test('likes and Good Lifts share one switch; comments have their own', () => {
  const off = P.preferencesFrom({ postReactions: false });
  assert.equal(P.typeEnabled(off, 'postLike'), false);
  assert.equal(P.typeEnabled(off, 'postGoodLift'), false);
  assert.equal(P.typeEnabled(off, 'postComment'), true, 'comments are separate');
  const noComments = P.preferencesFrom({ postComments: false });
  assert.equal(P.typeEnabled(noComments, 'postComment'), false);
  assert.equal(P.typeEnabled(noComments, 'postLike'), true);
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
  assert.deepEqual(msg.data, {
    v: '1', type: 'directMessage', recipientUid: B, actorUid: A, convId: CONV, msgId: 'm1',
  });
  for (const v of Object.values(msg.data)) assert.equal(typeof v, 'string');
  assert.equal(msg.android.ttl, 3600_000);
  assert.equal(msg.android.notification.channelId, 'goodlift_direct_messages');
  // Conversation-scoped so reading one thread can cancel exactly its alerts.
  const dmTag = `dm|${P.conversationTagKey(CONV)}|m1`;
  assert.equal(msg.android.notification.tag, dmTag);
  assert.equal(msg.android.notification.icon, 'ic_stat_goodlift');
  assert.equal(msg.apns.headers['apns-collapse-id'], dmTag);
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
  assert.deepEqual(P.ALL_TYPES.slice().sort(), [
    'directMessage', 'dmReaction', 'friendAccepted', 'friendRequest',
    'postComment', 'postGoodLift', 'postLike',
  ]);
});

// ── Post interactions and message reactions ─────────────────────────────────

test('only an ARRIVING like or Good Lift is an event', () => {
  assert.equal(P.isNewReaction(null, { createdAt: 1 }), true);
  assert.equal(P.isNewReaction({ createdAt: 1 }, null), false, 'un-liking says nothing');
  assert.equal(P.isNewReaction({ createdAt: 1 }, { createdAt: 2 }), false, 'a touch is not new');
  assert.equal(P.isNewReaction(null, null), false);
});

test('a like taken back and given again is the SAME occurrence', () => {
  const first = P.postOccurrence({ kind: 'like', postId: 'p1', actorUid: 'u2' });
  const again = P.postOccurrence({ kind: 'like', postId: 'p1', actorUid: 'u2' });
  assert.equal(first, again);
  assert.equal(
    P.jobIdFor('postLike', 'owner', first),
    P.jobIdFor('postLike', 'owner', again),
    'so it lands on one job and cannot alert twice',
  );
  // A different person, or a different post, is a different occurrence.
  assert.notEqual(first, P.postOccurrence({ kind: 'like', postId: 'p1', actorUid: 'u3' }));
  assert.notEqual(first, P.postOccurrence({ kind: 'like', postId: 'p2', actorUid: 'u2' }));
  // A Good Lift on the same post by the same person is its own occurrence.
  assert.notEqual(first, P.postOccurrence({ kind: 'goodLift', postId: 'p1', actorUid: 'u2' }));
});

test('only a NEW comment is an event: not an edit, not a deletion', () => {
  assert.equal(P.isNewComment(null, { uid: 'u2', text: 'nice' }), true);
  assert.equal(P.isNewComment({ uid: 'u2', text: 'nice' }, { uid: 'u2', text: 'edited' }), false);
  assert.equal(P.isNewComment({ uid: 'u2', text: 'nice' }, null), false);
  assert.equal(P.isNewComment(null, { text: 'no author' }), false);
});

test('a reaction arriving is an event; changing or removing one is not', () => {
  const msg = (reactions) => ({ senderId: 'u1', text: 'x', reactions });
  assert.deepEqual(
    P.newReactors(msg({}), msg({ u2: '🔥' })),
    [{ actorUid: 'u2', emoji: '🔥' }],
  );
  assert.deepEqual(
    P.newReactors(msg({ u2: '🔥' }), msg({ u2: '❤️' })),
    [],
    'swapping the emoji must not alert again',
  );
  assert.deepEqual(P.newReactors(msg({ u2: '🔥' }), msg({})), [], 'removing says nothing');
  assert.deepEqual(
    P.newReactors(msg({ u2: '🔥' }), msg({ u2: '🔥', u3: '👏' })),
    [{ actorUid: 'u3', emoji: '👏' }],
    'a second person is a separate interaction',
  );
  // A message with no reactions field at all.
  assert.deepEqual(P.newReactors({ senderId: 'u1' }, { senderId: 'u1' }), []);
});

test('a reaction that goes away, and one that changes, are told apart', () => {
  const msg = (reactions) => ({ senderId: 'u1', text: 'x', reactions });
  assert.deepEqual(
    P.goneReactors(msg({ u2: '🔥' }), msg({})),
    [{ actorUid: 'u2', emoji: '🔥' }],
    'taken back: the record for it must stop counting',
  );
  assert.deepEqual(P.goneReactors(msg({ u2: '🔥' }), msg({ u2: '❤️' })), [],
    'a swap is not a withdrawal');
  assert.deepEqual(P.goneReactors(msg({ u2: '🔥' }), null),
    [{ actorUid: 'u2', emoji: '🔥' }],
    'a deleted message takes its reactions with it');
  assert.deepEqual(P.goneReactors(msg({}), msg({ u2: '🔥' })), []);

  assert.deepEqual(
    P.changedReactors(msg({ u2: '🔥' }), msg({ u2: '❤️' })),
    [{ actorUid: 'u2', emoji: '❤️' }],
    'the list must not go on showing the emoji they changed their mind about',
  );
  assert.deepEqual(P.changedReactors(msg({ u2: '🔥' }), msg({ u2: '🔥' })), [],
    'unchanged is nothing to do');
  assert.deepEqual(P.changedReactors(msg({}), msg({ u2: '🔥' })), [],
    'an arrival is an arrival, not a change');
  assert.deepEqual(P.changedReactors(msg({ u2: '🔥' }), msg({})), []);
});

test('wording for post interactions and reactions', () => {
  assert.deepEqual(P.renderNotification({ type: 'postLike', actorName: 'Sam' }),
    { title: 'New like', body: 'Sam liked your post' });
  assert.deepEqual(P.renderNotification({ type: 'postGoodLift', actorName: 'Sam' }),
    { title: 'Good lift!', body: 'Sam gave your video a Good Lift' });
  assert.deepEqual(P.renderNotification({ type: 'dmReaction', actorName: 'Sam', emoji: '🔥' }),
    { title: 'New reaction', body: 'Sam reacted 🔥 to your message' });
  assert.equal(P.renderNotification({ type: 'dmReaction', actorName: 'Sam' }).body,
    'Sam reacted to your message');
});

test('a comment\'s words appear only with comment previews on', () => {
  const text = 'my gym door code is 4417';
  const off = P.renderNotification({ type: 'postComment', actorName: 'Sam', text });
  assert.deepEqual(off, { title: 'New comment', body: 'Sam commented on your post' });
  assert.ok(!JSON.stringify(off).includes('4417'), 'the text never enters the payload');
  // The DM preview switch does not speak for comments.
  const dmOnly = P.renderNotification({ type: 'postComment', actorName: 'Sam', text, previews: true });
  assert.equal(dmOnly.body, 'Sam commented on your post');
  const on = P.renderNotification({ type: 'postComment', actorName: 'Sam', text, commentPreviews: true });
  assert.deepEqual(on, { title: 'Sam commented', body: text });
});

test('tags group a post\'s alerts, and a reaction replaces its own', () => {
  const like = { type: 'postLike', postId: 'p1', actorUid: 'u2', activityId: 'pl_abc', id: 'j1' };
  const comment = { type: 'postComment', postId: 'p1', actorUid: 'u3', activityId: 'pc_def', id: 'j2' };
  const other = { type: 'postLike', postId: 'p2', actorUid: 'u2', activityId: 'pl_ghi', id: 'j3' };
  const prefix = `post|${P.subjectTagKey('p1')}|`;
  assert.ok(P.presentationTag(like).startsWith(prefix));
  assert.ok(P.presentationTag(comment).startsWith(prefix));
  assert.ok(!P.presentationTag(other).startsWith(prefix), 'another post is untouched');
  assert.notEqual(P.presentationTag(like), P.presentationTag(comment),
    'two interactions on one post are two alerts');

  // A reaction's tag ends in the RECORD's id, not the message's: two people
  // reacting to one message are two interactions, and reading one must cancel
  // only its own alert. It also lets the app turn a delivered tag back into
  // the record it is about.
  const react = {
    type: 'dmReaction', conversationId: 'a_b', messageId: 'm9', actorUid: 'u2', activityId: 'dr_x',
  };
  assert.equal(P.presentationTag(react), `dmr|${P.subjectTagKey('a_b')}|dr_x`);
  assert.notEqual(
    P.presentationTag(react),
    P.presentationTag({
      type: 'dmReaction', conversationId: 'a_b', messageId: 'm9', actorUid: 'u4', activityId: 'dr_y',
    }),
    'two reactions to one message are two alerts',
  );
  assert.notEqual(P.presentationTag(react),
    P.presentationTag({ type: 'directMessage', conversationId: 'a_b', messageId: 'm9' }),
    'a reaction alert is not the message alert');
});

test('routing carries what the app needs to open and to acknowledge', () => {
  const comment = P.routingData({
    type: 'postComment', recipientUid: 'owner', actorUid: 'u2',
    postId: 'p1', commentId: 'c7', activityId: 'pc_def',
  });
  assert.equal(comment.postId, 'p1');
  assert.equal(comment.commentId, 'c7');
  assert.equal(comment.activityId, 'pc_def');
  const react = P.routingData({
    type: 'dmReaction', recipientUid: 'owner', actorUid: 'u2',
    conversationId: 'a_b', messageId: 'm9', activityId: 'dr_x',
  });
  assert.equal(react.convId, 'a_b');
  assert.equal(react.msgId, 'm9');
  assert.equal(react.activityId, 'dr_x');
  // Values are all strings: FCM data payloads carry nothing else.
  for (const v of Object.values({ ...comment, ...react })) {
    assert.equal(typeof v, 'string');
  }
});

test('the push module is wired into index.js and changes nothing else', () => {
  const idx = require('../index');
  assert.ok(idx.pushOnDirectMessageWritten);
  assert.ok(idx.pushOutboxOnCreated);
  assert.ok(idx.socialOnBuddyInviteWritten);
  const pushExports = Object.keys(idx).filter((k) => /^push/.test(k));
  assert.deepEqual(pushExports.sort(), [
    'pushOnDirectMessageWritten',
    'pushOnPostCommentWritten',
    'pushOnPostDeleted',
    'pushOnPostGoodLiftWritten',
    'pushOnPostLikeWritten',
    'pushOutboxOnCreated',
  ], 'every trigger that must be deployed is exported');
});
