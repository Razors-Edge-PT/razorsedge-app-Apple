'use strict';

// Firestore security-rules tests for push notifications and the direct-message
// hardening that push delivery relies on, against the REAL rules engine:
//   npm run test:rules
//
//   pushDevices/{sha256(token)}  owner-only read/delete; create/update must
//                                name the caller, bind the id to the token and
//                                stamp the server clock; a takeover must
//                                present the same token
//   pushPreferences/{uid}        the account itself only — not a coach, not
//                                the super admin, not a friend
//   pushOutbox, pushConfig       nobody (server only)
//   conversations                participants fixed to the id's two accounts
//                                and immutable
//   conversations/../messages    senderId == caller on create, immutable after;
//                                only the sender completes a message, others
//                                may only react
//
// Every DM write an INSTALLED build makes is replayed here and must still pass.

const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');
const {
  serverTimestamp, increment, deleteField,
} = require('firebase/firestore');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
// Conversation ids are uidA_uidB with 28-character uids (what Firebase Auth
// issues and what the rules slice on).
const uid = (s) => s.padEnd(28, 'x');
const ALICE = uid('alicePush');
const BOB = uid('bobPush');
const CAROL = uid('carolPush'); // ALICE's friend, not BOB's
const DAVE = uid('davePush'); // nobody's friend
const COACH = uid('coachPush'); // ALICE's assigned coach

const convIdFor = (a, b) => [a, b].sort().join('_');
const AB = convIdFor(ALICE, BOB);
const AD = convIdFor(ALICE, DAVE);

const sha = (t) => crypto.createHash('sha256').update(t, 'utf8').digest('hex');
const TOKEN_A = 'fcm-token-alice-phone:APA91b-aaaaaaaaaaaaaaaaaaaa';
const TOKEN_B = 'fcm-token-bob-phone:APA91b-bbbbbbbbbbbbbbbbbbbbbbbb';
const TOKEN_SHARED = 'fcm-token-shared-phone:APA91b-ssssssssssssssssssss';

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-push',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });

  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const accepted = { status: 'accepted' };
    await db.doc(`buddyAssignments/${ALICE}`).set({ athletes: { [BOB]: accepted, [CAROL]: accepted } });
    await db.doc(`buddyAssignments/${BOB}`).set({ athletes: { [ALICE]: accepted } });
    await db.doc(`buddyAssignments/${CAROL}`).set({ athletes: { [ALICE]: accepted } });

    await db.doc(`conversations/${AB}`).set({
      participants: { [ALICE]: true, [BOB]: true },
      participantList: [ALICE, BOB].sort(),
      participantState: { [ALICE]: { unreadCount: 0 }, [BOB]: { unreadCount: 0 } },
      lastMessage: null,
    });
    await db.doc(`conversations/${AB}/messages/fromBob`).set({
      senderId: BOB, type: 'text', text: 'hi', sentAt: new Date(),
    });
    await db.doc(`conversations/${AB}/messages/bobShell`).set({
      senderId: BOB, type: 'image', text: '', sentAt: new Date(),
    });
    await db.doc(`conversations/${AB}/messages/aliceShell`).set({
      senderId: ALICE, type: 'image', text: '', sentAt: new Date(),
    });
    await db.doc(`conversations/${AB}/messages/aliceVideoShell`).set({
      senderId: ALICE, type: 'video', text: '', sentAt: new Date(),
    });

    await db.doc(`pushDevices/${sha(TOKEN_B)}`).set({
      uid: BOB, token: TOKEN_B, platform: 'android', updatedAt: new Date(),
    });
    await db.doc(`pushOutbox/job1`).set({ type: 'directMessage', recipientUid: ALICE });
    await db.doc(`pushPreferences/${ALICE}`).set({ directMessages: true, updatedAt: new Date() });

    await db.doc(`athleteAssignments/${ALICE}`).set({ coaches: { [COACH]: { approved: true } } });
    await db.doc(`accountEntitlements/${COACH}`).set({ coach: { state: 'active', source: 'manual_review' } });
  });
});

test.after(async () => {
  if (env) await env.cleanup();
});

const as = (u) => env.authenticatedContext(u).firestore();
const anon = () => env.unauthenticatedContext().firestore();

const registration = (owner, token, extra = {}) => ({
  uid: owner, token, platform: 'android', appVersion: '1.7.21+91', updatedAt: serverTimestamp(), ...extra,
});

// ── pushDevices ─────────────────────────────────────────────────────────────

test('a device registers its own token under the hashed id', async () => {
  await assertSucceeds(as(ALICE).doc(`pushDevices/${sha(TOKEN_A)}`).set(registration(ALICE, TOKEN_A)));
  // Refresh (weekly freshness write) by the same owner.
  await assertSucceeds(as(ALICE).doc(`pushDevices/${sha(TOKEN_A)}`).set(registration(ALICE, TOKEN_A)));
  await assertSucceeds(as(ALICE).doc(`pushDevices/${sha(TOKEN_A)}`).get());
  await assertSucceeds(as(ALICE).collection('pushDevices').where('uid', '==', ALICE).get());
});

test('a registration cannot be forged, misfiled or backdated', async () => {
  // Someone else's uid as owner.
  await assertFails(as(ALICE).doc(`pushDevices/${sha(TOKEN_A)}`).set(registration(BOB, TOKEN_A)));
  // Id not bound to the token: the same token under a second id would give
  // one phone two owners.
  await assertFails(as(ALICE).doc(`pushDevices/${sha('other')}`).set(registration(ALICE, TOKEN_A)));
  await assertFails(as(ALICE).doc('pushDevices/myPhone').set(registration(ALICE, TOKEN_A)));
  // Client clock instead of the server's.
  await assertFails(
    as(ALICE).doc(`pushDevices/${sha(TOKEN_A)}`).set(registration(ALICE, TOKEN_A, { updatedAt: new Date() })),
  );
  // Extra fields, bad platform, missing token.
  await assertFails(
    as(ALICE).doc(`pushDevices/${sha(TOKEN_A)}`).set(registration(ALICE, TOKEN_A, { isAdmin: true })),
  );
  await assertFails(
    as(ALICE).doc(`pushDevices/${sha(TOKEN_A)}`).set(registration(ALICE, TOKEN_A, { platform: 'web' })),
  );
  await assertFails(anon().doc(`pushDevices/${sha(TOKEN_A)}`).set(registration(ALICE, TOKEN_A)));
});

test('nobody reads or deletes another account\'s registration', async () => {
  for (const reader of [as(ALICE), as(CAROL), as(COACH), as(SUPER), anon()]) {
    await assertFails(reader.doc(`pushDevices/${sha(TOKEN_B)}`).get());
    await assertFails(reader.collection('pushDevices').where('uid', '==', BOB).get());
  }
  // An unfiltered list would expose every token.
  await assertFails(as(ALICE).collection('pushDevices').get());
  await assertFails(as(ALICE).doc(`pushDevices/${sha(TOKEN_B)}`).delete());
  await assertFails(as(COACH).doc(`pushDevices/${sha(TOKEN_B)}`).delete());
  await assertSucceeds(as(BOB).doc(`pushDevices/${sha(TOKEN_B)}`).get());
});

test('switching accounts on one phone moves the token; it never has two owners', async () => {
  const id = sha(TOKEN_SHARED);
  await assertSucceeds(as(ALICE).doc(`pushDevices/${id}`).set(registration(ALICE, TOKEN_SHARED)));
  // Carol signs in on the same phone: same token → same document, new owner.
  await assertSucceeds(as(CAROL).doc(`pushDevices/${id}`).set(registration(CAROL, TOKEN_SHARED)));
  await assertFails(as(ALICE).doc(`pushDevices/${id}`).get());
  await assertSucceeds(as(CAROL).doc(`pushDevices/${id}`).get());
  // A takeover cannot change the token the document is keyed by.
  await assertFails(
    as(DAVE).doc(`pushDevices/${id}`).set(registration(DAVE, 'a-different-token')),
  );
  // The previous owner can no longer delete it.
  await assertFails(as(ALICE).doc(`pushDevices/${id}`).delete());
  await assertSucceeds(as(CAROL).doc(`pushDevices/${id}`).delete());
});

// ── pushPreferences ─────────────────────────────────────────────────────────

test('an account sets its own notification preferences', async () => {
  await assertSucceeds(as(ALICE).doc(`pushPreferences/${ALICE}`).set({
    friendRequests: false, messagePreviews: true, updatedAt: serverTimestamp(),
  }, { merge: true }));
  await assertSucceeds(as(ALICE).doc(`pushPreferences/${ALICE}`).get());
});

test('preferences are private to the account — not a coach, friend or admin', async () => {
  for (const other of [as(BOB), as(COACH), as(SUPER), anon()]) {
    await assertFails(other.doc(`pushPreferences/${ALICE}`).get());
    await assertFails(other.doc(`pushPreferences/${ALICE}`).set({
      directMessages: false, updatedAt: serverTimestamp(),
    }, { merge: true }));
  }
});

test('preferences are typed and server-stamped', async () => {
  await assertFails(as(ALICE).doc(`pushPreferences/${ALICE}`).set({
    directMessages: 'yes', updatedAt: serverTimestamp(),
  }, { merge: true }));
  await assertFails(as(ALICE).doc(`pushPreferences/${ALICE}`).set({
    marketing: true, updatedAt: serverTimestamp(),
  }, { merge: true }));
  await assertFails(as(ALICE).doc(`pushPreferences/${ALICE}`).set({
    directMessages: false, updatedAt: new Date('2020-01-01'),
  }, { merge: true }));
});

// ── Server-owned delivery state ─────────────────────────────────────────────

test('no client reads or writes the outbox or the kill switch, super admin included', async () => {
  for (const who of [as(ALICE), as(BOB), as(SUPER), anon()]) {
    await assertFails(who.doc('pushOutbox/job1').get());
    await assertFails(who.collection('pushOutbox').where('recipientUid', '==', ALICE).get());
    await assertFails(who.doc('pushOutbox/forged').set({ type: 'directMessage', recipientUid: BOB }));
    await assertFails(who.doc('pushOutbox/job1').update({ status: 'sent' }));
    await assertFails(who.doc('pushConfig/delivery').set({ enabled: false }));
    await assertFails(who.doc('pushConfig/delivery').get());
  }
});

test('the users/{uid} catch-all does not reach push data', async () => {
  // Push data is not under users/{uid}; writing a look-alike there grants
  // nothing the server reads.
  await assertSucceeds(as(ALICE).doc(`users/${ALICE}/pushDevices/x`).set({ a: 1 }));
  await assertFails(as(ALICE).doc(`pushDevices/x`).set({ a: 1 }));
  await assertFails(as(ALICE).doc(`users/${ALICE}/socialNotifications/x`).set({ type: 'buddyAccepted' }));
});

// ── Direct messages: every installed-build write still works ────────────────

test('installed builds: open a new conversation from the buddy picker', async () => {
  const cid = convIdFor(ALICE, CAROL);
  await assertSucceeds(as(ALICE).doc(`conversations/${cid}`).set({
    participants: { [ALICE]: true, [CAROL]: true },
    participantList: [ALICE, CAROL].sort(),
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    lastMessage: null,
    participantState: { [ALICE]: { unreadCount: 0 }, [CAROL]: { unreadCount: 0 } },
  }));
  // Touch on reopen.
  await assertSucceeds(as(ALICE).doc(`conversations/${cid}`).update({ updatedAt: serverTimestamp() }));
});

test('installed builds: send text, bump preview/unread, mark read, bootstrap merge', async () => {
  const conv = as(ALICE).doc(`conversations/${AB}`);
  await assertSucceeds(conv.collection('messages').doc('t1').set({
    senderId: ALICE, type: 'text', text: 'hello', clientId: 'c1',
    localSentAt: Date.now(), sentAt: serverTimestamp(),
  }));
  await assertSucceeds(conv.update({
    lastMessage: { text: 'hello', senderId: ALICE, sentAt: serverTimestamp() },
    updatedAt: serverTimestamp(),
    [`participantState.${ALICE}.unreadCount`]: 0,
    [`participantState.${ALICE}.lastReadAt`]: serverTimestamp(),
    [`participantState.${BOB}.unreadCount`]: increment(1),
  }));
  // Bob opens the thread.
  await assertSucceeds(as(BOB).doc(`conversations/${AB}`).update({
    [`participantState.${BOB}.unreadCount`]: 0,
    [`participantState.${BOB}.lastReadAt`]: serverTimestamp(),
  }));
  // The catchError bootstrap repeats the same participants with merge.
  await assertSucceeds(conv.set({
    participants: { [ALICE]: true, [BOB]: true },
    participantList: [ALICE, BOB].sort(),
    updatedAt: serverTimestamp(),
  }, { merge: true }));
});

test('installed builds: photo and video shells, then the sender attaches the URL', async () => {
  const msgs = as(ALICE).doc(`conversations/${AB}`).collection('messages');
  await assertSucceeds(msgs.doc('img1').set({
    senderId: ALICE, type: 'image', text: '', localSentAt: Date.now(), sentAt: serverTimestamp(),
  }));
  await assertSucceeds(msgs.doc('img1').update({ imageUrl: 'https://example.test/i.jpg' }));
  await assertSucceeds(msgs.doc('vid1').set({
    senderId: ALICE, type: 'video', text: '', localSentAt: Date.now(), sentAt: serverTimestamp(),
  }));
  await assertSucceeds(msgs.doc('vid1').update({ videoUrl: 'https://example.test/v.mp4' }));
  // The (unreachable) composer path writes a complete video message at once.
  await assertSucceeds(msgs.doc('vid2').set({
    senderId: ALICE, type: 'video', text: '', videoUrl: 'https://example.test/v2.mp4',
    clientId: 'c2', localSentAt: Date.now(), sentAt: serverTimestamp(),
  }));
});

test('installed builds: either participant reacts and un-reacts', async () => {
  const m = as(ALICE).doc(`conversations/${AB}/messages/fromBob`);
  await assertSucceeds(m.update({ [`reactions.${ALICE}`]: '🔥' }));
  await assertSucceeds(m.update({ [`reactions.${ALICE}`]: deleteField() }));
  await assertSucceeds(as(BOB).doc(`conversations/${AB}/messages/fromBob`).update({ [`reactions.${BOB}`]: '👍' }));
});

// ── Direct messages: forgeries push delivery depends on refusing ────────────

test('a participant cannot send as the other person', async () => {
  await assertFails(as(ALICE).doc(`conversations/${AB}/messages/forged`).set({
    senderId: BOB, type: 'text', text: 'I owe you money', sentAt: serverTimestamp(),
  }));
  // Nor with the sender omitted.
  await assertFails(as(ALICE).doc(`conversations/${AB}/messages/nosender`).set({
    type: 'text', text: 'anon', sentAt: serverTimestamp(),
  }));
});

test('senderId is immutable and only the sender completes a message', async () => {
  await assertFails(as(ALICE).doc(`conversations/${AB}/messages/aliceShell`).update({ senderId: BOB }));
  await assertFails(as(BOB).doc(`conversations/${AB}/messages/fromBob`).update({ senderId: ALICE }));
  // Alice attaching media to BOB's empty upload shell.
  await assertFails(
    as(ALICE).doc(`conversations/${AB}/messages/bobShell`).update({ imageUrl: 'https://evil.test/x.jpg' }),
  );
  await assertFails(as(ALICE).doc(`conversations/${AB}/messages/fromBob`).update({ text: 'edited' }));
  // A reaction smuggling a content change.
  await assertFails(as(ALICE).doc(`conversations/${AB}/messages/fromBob`).update({
    [`reactions.${ALICE}`]: '😂', text: 'edited',
  }));
});

test('participants cannot be rewritten to add or swap an account', async () => {
  // Alice adds her friend Carol to the Alice–Bob thread.
  await assertFails(as(ALICE).doc(`conversations/${AB}`).update({ [`participants.${CAROL}`]: true }));
  await assertFails(as(ALICE).doc(`conversations/${AB}`).update({
    participants: { [ALICE]: true, [CAROL]: true },
  }));
  await assertFails(as(ALICE).doc(`conversations/${AB}`).update({ [`participants.${BOB}`]: false }));
});

test('a new conversation must name exactly the two accounts in its id', async () => {
  const cid = convIdFor(ALICE, CAROL);
  const base = { participantList: [ALICE, CAROL].sort(), createdAt: serverTimestamp() };
  // The other side is not the account the id names.
  await assertFails(as(ALICE).doc(`conversations/${cid}`).set({
    ...base, participants: { [ALICE]: true, [BOB]: true },
  }));
  await assertFails(as(ALICE).doc(`conversations/${cid}`).set({
    ...base, participants: { [ALICE]: true, [CAROL]: false },
  }));
  // Friendship gate still applies: Dave is nobody's friend.
  await assertFails(as(ALICE).doc(`conversations/${AD}`).set({
    participants: { [ALICE]: true, [DAVE]: true },
  }));
});

test('a coach cannot read or post in an athlete\'s conversations', async () => {
  await assertFails(as(COACH).doc(`conversations/${AB}`).get());
  await assertFails(as(COACH).doc(`conversations/${AB}/messages/c1`).set({
    senderId: COACH, type: 'text', text: 'x',
  }));
});
