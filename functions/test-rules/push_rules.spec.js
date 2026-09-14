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
const assert = require('node:assert/strict');
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

    // Social activity: one unread, one already read.
    await db.doc(`users/${ALICE}/socialActivity/act1`).set({
      type: 'postComment', actorUid: BOB, subject: 'post:p1', postId: 'p1',
      commentId: 'c1', read: false, createdAt: new Date(),
    });
    await db.doc(`users/${ALICE}/socialActivity/act2`).set({
      type: 'postLike', actorUid: BOB, subject: 'post:p1', postId: 'p1',
      read: true, readAt: new Date(), createdAt: new Date(),
    });
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

// ── The unread ledger is the server's ───────────────────────────────────────

test('a participant records their own reading, and the legacy counter still works', async () => {
  const conv = as(ALICE).doc(`conversations/${AB}`);
  await assertSucceeds(conv.update({
    [`participantState.${ALICE}.readIncoming`]: 4,
    [`participantState.${ALICE}.lastReadAt`]: serverTimestamp(),
    [`participantState.${ALICE}.unreadCount`]: 0,
  }));
  // Installed builds still bump the other person's legacy counter when they
  // send; that must keep working.
  await assertSucceeds(conv.update({
    [`participantState.${BOB}.unreadCount`]: increment(1),
    updatedAt: serverTimestamp(),
  }));
});

test('nobody can move the ledger — their own or the other person\'s', async () => {
  // The server has counted messages for both participants.
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(`conversations/${AB}`).set({
      participantState: { [ALICE]: { incoming: 3 }, [BOB]: { incoming: 2 } },
    }, { merge: true });
  });
  const conv = as(ALICE).doc(`conversations/${AB}`);
  // Inflating or clearing my own count.
  await assertFails(conv.update({ [`participantState.${ALICE}.incoming`]: 99 }));
  await assertFails(conv.update({ [`participantState.${ALICE}.incoming`]: 0 }));
  // Hiding messages from the other person, or inflating their badge.
  await assertFails(conv.update({ [`participantState.${BOB}.incoming`]: 0 }));
  await assertFails(conv.update({ [`participantState.${BOB}.incoming`]: 50 }));
  await assertFails(as(BOB).doc(`conversations/${AB}`).update({
    [`participantState.${ALICE}.incoming`]: 1,
  }));
  // Smuggled alongside a legitimate read.
  await assertFails(conv.update({
    [`participantState.${ALICE}.readIncoming`]: 2,
    [`participantState.${ALICE}.incoming`]: 2,
  }));
  // A whole-map rewrite cannot drop it either.
  await assertFails(conv.update({
    participantState: { [ALICE]: { readIncoming: 1 }, [BOB]: { unreadCount: 0 } },
  }));
});

test('a new conversation cannot be opened with a ledger already in it', async () => {
  const cid = convIdFor(ALICE, CAROL);
  await assertFails(as(ALICE).doc(`conversations/${cid}`).set({
    participants: { [ALICE]: true, [CAROL]: true },
    participantState: { [ALICE]: { incoming: 7 }, [CAROL]: { unreadCount: 0 } },
  }));
  await assertSucceeds(as(ALICE).doc(`conversations/${cid}`).set({
    participants: { [ALICE]: true, [CAROL]: true },
    participantState: { [ALICE]: { unreadCount: 0 }, [CAROL]: { unreadCount: 0 } },
  }));
});

test('a message\'s ledger position cannot be set or changed by a client', async () => {
  const msgs = as(ALICE).doc(`conversations/${AB}`).collection('messages');
  await assertFails(msgs.doc('seeded').set({
    senderId: ALICE, type: 'text', text: 'hi', incomingSeq: 99, sentAt: serverTimestamp(),
  }));
  await assertSucceeds(msgs.doc('plain').set({
    senderId: ALICE, type: 'text', text: 'hi', sentAt: serverTimestamp(),
  }));
  await assertFails(msgs.doc('plain').update({ incomingSeq: 99 }));
  // Not by the recipient either, alongside a reaction.
  await assertFails(as(BOB).doc(`conversations/${AB}/messages/plain`).update({
    [`reactions.${BOB}`]: '🔥', incomingSeq: 1,
  }));
  await assertSucceeds(as(BOB).doc(`conversations/${AB}/messages/plain`).update({
    [`reactions.${BOB}`]: '🔥',
  }));
});

// ── The inbox read path (Messages permission-denied regression) ────────────
//
// `conversations` has no query DirectMessages/DmUnreadService can safely run:
// a LIST request against a collection whose read rule needs get()/exists()
// (isConvFriend() → isBuddyOf(), reading buddyAssignments) cannot be proven
// safe from the query's own filters, so Firestore denies the WHOLE request —
// this is what produced the reported "[cloud_firestore/permission-denied]"
// on the Messages screen for an ordinary user with any conversation at all,
// regardless of which one. The fix (lib/social/dm_unread_service.dart) reads
// `socialGraph/{uid}.friends` — already owner-readable, already maintained by
// functions/social/feed.js — and opens one individual document
// listen/get per confirmed friend's conversation instead of listing the
// collection. These tests are the doc-level contract that design depends on.
//
// isBuddyOf() was also fixed to use `.get(key, default)` instead of bracket
// map-indexing (`athletes[uid]`), which THROWS when the key is absent — the
// ordinary case for a non-friend, since nobody's `athletes` map lists
// everyone. A thrown evaluation error and a clean `false` both deny a single
// get() identically, but only the exception could have poisoned a list
// query — assertFails below cannot tell the two apart directly, but a
// permission-denied here without setup mistakes confirms the access
// decision itself, which is what the client-side redesign now depends on
// exclusively (see functions/test-emulator or dm_unread_test.dart for the
// premature-cancellation regressions this shares a root cause with).
test('a confirmed friend reads their own conversation by direct document access', async () => {
  await assertSucceeds(as(ALICE).doc(`conversations/${AB}`).get());
  await assertSucceeds(as(BOB).doc(`conversations/${AB}`).get());
});

test('a confirmed friend can read their conversation before it is created, and again once it exists', async () => {
  // The DmUnreadService inbox listener subscribes to a friend's conversation
  // id as soon as the friendship is confirmed, before any message has ever
  // been sent — the document may not exist yet. A fresh friend pair is used
  // so no earlier test's conversation document interferes.
  const FRESH = uid('freshFriendPush');
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc(`buddyAssignments/${ALICE}`).set({
      athletes: { [BOB]: { status: 'accepted' }, [CAROL]: { status: 'accepted' }, [FRESH]: { status: 'accepted' } },
    });
    await db.doc(`buddyAssignments/${FRESH}`).set({ athletes: { [ALICE]: { status: 'accepted' } } });
  });
  const convId = convIdFor(ALICE, FRESH);

  // Not created yet: readable as "does not exist", not denied outright —
  // otherwise the listener errors and Firestore never revives it once the
  // conversation is actually created.
  const before = await as(ALICE).doc(`conversations/${convId}`).get();
  assert.equal(before.exists, false);

  // A stranger to this pair still cannot read it, missing or not.
  await assertFails(as(DAVE).doc(`conversations/${convId}`).get());
  await assertFails(as(COACH).doc(`conversations/${convId}`).get());

  // Created by an authorised party (the real create rule, unchanged):
  // now readable with its real data by both participants.
  await assertSucceeds(as(ALICE).doc(`conversations/${convId}`).set({
    participants: { [ALICE]: true, [FRESH]: true },
    participantList: [ALICE, FRESH].sort(),
    participantState: { [ALICE]: { unreadCount: 0 }, [FRESH]: { unreadCount: 0 } },
    lastMessage: null,
  }));
  const after = await as(ALICE).doc(`conversations/${convId}`).get();
  assert.equal(after.exists, true);
  await assertSucceeds(as(FRESH).doc(`conversations/${convId}`).get());
  await assertFails(as(DAVE).doc(`conversations/${convId}`).get());

  // Restore the fixture for later tests.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc(`buddyAssignments/${ALICE}`).set({ athletes: { [BOB]: { status: 'accepted' }, [CAROL]: { status: 'accepted' } } });
    await db.doc(`buddyAssignments/${FRESH}`).delete();
    await db.doc(`conversations/${convId}`).delete();
  });
});

test('a non-friend cannot read a conversation naming them even when it does not exist', async () => {
  const convId = convIdFor(ALICE, DAVE); // DAVE is nobody's friend
  await assertFails(as(ALICE).doc(`conversations/${convId}`).get());
  await assertFails(as(DAVE).doc(`conversations/${convId}`).get());
});

test('a non-friend cannot read a conversation naming them, even after it exists', async () => {
  const AD_direct = convIdFor(ALICE, DAVE);
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.firestore().doc(`conversations/${AD_direct}`).set({
      participants: { [ALICE]: true, [DAVE]: true },
      participantState: { [ALICE]: { unreadCount: 0 }, [DAVE]: { unreadCount: 0 } },
    });
  });
  await assertFails(as(ALICE).doc(`conversations/${AD_direct}`).get());
  await assertFails(as(DAVE).doc(`conversations/${AD_direct}`).get());
});

test('an unfriended pair loses read access to their own past conversation, others unaffected', async () => {
  // BOB and CAROL are not friends of each other; seed a conversation that
  // once existed between confirmed friends and then unfriend them, mirroring
  // "a removed friendship does not make other permitted conversations
  // unusable" — ALICE's own conversations with BOB and CAROL must stay fine.
  const BC = convIdFor(BOB, CAROL);
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc(`buddyAssignments/${BOB}`).set(
      { athletes: { [ALICE]: { status: 'accepted' }, [CAROL]: { status: 'accepted' } } },
    );
    await db.doc(`buddyAssignments/${CAROL}`).set(
      { athletes: { [ALICE]: { status: 'accepted' }, [BOB]: { status: 'accepted' } } },
    );
    await db.doc(`conversations/${BC}`).set({
      participants: { [BOB]: true, [CAROL]: true },
      participantState: { [BOB]: { unreadCount: 0 }, [CAROL]: { unreadCount: 0 } },
    });
  });
  await assertSucceeds(as(BOB).doc(`conversations/${BC}`).get());

  await env.withSecurityRulesDisabled(async (ctx) => {
    // BOB removes CAROL — one-sided, as an unfriend actually writes.
    await ctx.firestore().doc(`buddyAssignments/${BOB}`).set(
      { athletes: { [ALICE]: { status: 'accepted' } } },
    );
  });
  await assertFails(as(BOB).doc(`conversations/${BC}`).get());
  await assertFails(as(CAROL).doc(`conversations/${BC}`).get());
  // ALICE's own, unrelated conversation with BOB is untouched.
  await assertSucceeds(as(ALICE).doc(`conversations/${AB}`).get());
  await assertSucceeds(as(BOB).doc(`conversations/${AB}`).get());

  // Restore both assignment docs so later tests see the original fixture.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await db.doc(`buddyAssignments/${BOB}`).set({ athletes: { [ALICE]: { status: 'accepted' } } });
    await db.doc(`buddyAssignments/${CAROL}`).set({ athletes: { [ALICE]: { status: 'accepted' } } });
    await db.doc(`conversations/${BC}`).delete();
  });
});

test('a coach cannot read or post in an athlete\'s conversations', async () => {
  await assertFails(as(COACH).doc(`conversations/${AB}`).get());
  await assertFails(as(COACH).doc(`conversations/${AB}/messages/c1`).set({
    senderId: COACH, type: 'text', text: 'x',
  }));
});

// ── socialActivity ──────────────────────────────────────────────────────────
// Server-written, owner-read, and the owner's ONE write is marking something
// read. Everything else — inventing an interaction, retargeting one, hiding
// one, or taking one back to unread — is denied.

test('only the owner can read their activity', async () => {
  await assertSucceeds(as(ALICE).doc(`users/${ALICE}/socialActivity/act1`).get());
  await assertFails(as(BOB).doc(`users/${ALICE}/socialActivity/act1`).get());
  await assertFails(as(COACH).doc(`users/${ALICE}/socialActivity/act1`).get());
  await assertFails(anon().doc(`users/${ALICE}/socialActivity/act1`).get());
  // Nor can a friend enumerate them.
  await assertFails(as(BOB).collection(`users/${ALICE}/socialActivity`).get());
});

test('the owner marks one read, at the server clock, and nothing else', async () => {
  const ref = as(ALICE).doc(`users/${ALICE}/socialActivity/act1`);
  await assertFails(ref.update({ read: true })); // no readAt
  await assertFails(ref.update({ read: true, readAt: new Date() })); // client clock
  await assertFails(ref.update({ read: true, readAt: serverTimestamp(), preview: 'x' }));
  await assertFails(ref.update({ read: true, readAt: serverTimestamp(), actorUid: ALICE }));
  await assertSucceeds(ref.update({ read: true, readAt: serverTimestamp() }));
});

test('read is one-way: nothing can take an interaction back to unread', async () => {
  const ref = as(ALICE).doc(`users/${ALICE}/socialActivity/act2`);
  await assertFails(ref.update({ read: false, readAt: serverTimestamp() }));
  // Re-reading something already read is refused as well, so a replayed
  // offline write cannot move `readAt` around.
  await assertFails(ref.update({ read: true, readAt: serverTimestamp() }));
});

test('nobody can create, delete, or write into somebody else\'s activity', async () => {
  await assertFails(as(ALICE).doc(`users/${ALICE}/socialActivity/forged`).set({
    type: 'postLike', actorUid: BOB, subject: 'post:p1', read: false, createdAt: serverTimestamp(),
  }));
  await assertFails(as(ALICE).doc(`users/${ALICE}/socialActivity/act1`).delete());
  await assertFails(as(BOB).doc(`users/${ALICE}/socialActivity/act1`).update({
    read: true, readAt: serverTimestamp(),
  }));
  await assertFails(as(BOB).doc(`users/${ALICE}/socialActivity/planted`).set({
    type: 'postLike', actorUid: BOB, subject: 'post:p1', read: false, createdAt: serverTimestamp(),
  }));
});

test('the new notification categories are accepted; unknown fields are not', async () => {
  const ref = as(ALICE).doc(`pushPreferences/${ALICE}`);
  await assertSucceeds(ref.set({
    friendRequests: true,
    friendAccepted: true,
    directMessages: true,
    messageReactions: false,
    postComments: true,
    postReactions: false,
    messagePreviews: false,
    commentPreviews: true,
    updatedAt: serverTimestamp(),
  }));
  await assertFails(ref.set({ postComments: 'yes', updatedAt: serverTimestamp() }));
  await assertFails(ref.set({ somethingElse: true, updatedAt: serverTimestamp() }));
});
