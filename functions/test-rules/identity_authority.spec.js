'use strict';

// Firestore security-rules tests for USERNAME AUTHORITY, run against the REAL
// rules engine in the Firestore emulator:
//   npm run test:rules
//
// The property under test is that `username`, `usernameLower` and
// `displayName` on users/{uid} and users_public/{uid} belong to the
// profileChangeUsername callable and its usernames/{sha256(name)} reservation
// index — not to the client.
//
// The one deliberate exception is the compatibility window: an installed
// pre-1.7.13 build stamps username + usernameLower onto both documents during
// signup and never calls the callable. Denying that outright would break
// account creation on every one of those installs the moment these rules
// deployed, so a FIRST claim on an account that has none still succeeds, and
// identityOnPublicProfileWritten reconciles it against the index afterwards.
//
// A RENAME is denied at all times, in every build. That is the case that can
// take a name from another account, and it has no legacy caller.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const SUPER = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const OWNER = 'identityOwner';
const NEWBIE = 'identityNewbie';   // no username yet — the legacy signup case
const OTHER = 'identityOther';

let env;

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'rules-test-identity',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', '..', 'firestore.rules'), 'utf8'),
    },
  });
});

test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    // An established account: it already holds a username.
    await db.doc(`users/${OWNER}`).set({
      username: 'BenchKing', usernameLower: 'benchking', bio: 'Chasing 200.',
    });
    await db.doc(`users_public/${OWNER}`).set({
      username: 'BenchKing', usernameLower: 'benchking', displayName: 'BenchKing',
    });
    // A brand-new account mid-signup: the documents exist (email, createdAt)
    // but carry no username yet.
    await db.doc(`users/${NEWBIE}`).set({ email: 'new@example.invalid' });
    await db.doc(`users_public/${NEWBIE}`).set({ email: 'new@example.invalid' });
    // The reservation the callable would have written for OWNER.
    await db.doc('usernames/anyhash').set({
      uid: OWNER, username: 'BenchKing', usernameLower: 'benchking',
    });
  });
});

test.after(async () => { await env.cleanup(); });

const as = (uid) => env.authenticatedContext(uid).firestore();

// ── The rename path is closed ───────────────────────────────────────────────

test('rules: the owner cannot rename themselves on users_public', async () => {
  const db = as(OWNER);
  await assertFails(db.doc(`users_public/${OWNER}`).set(
    { username: 'Stolen', usernameLower: 'stolen' }, { merge: true },
  ));
});

test('rules: the owner cannot rename themselves on users', async () => {
  const db = as(OWNER);
  await assertFails(db.doc(`users/${OWNER}`).set(
    { username: 'Stolen', usernameLower: 'stolen' }, { merge: true },
  ));
});

test('rules: changing only usernameLower is still a rename', async () => {
  // Half a rename is the more dangerous shape, not the safer one: it makes the
  // searchable index disagree with the displayed name.
  const db = as(OWNER);
  await assertFails(db.doc(`users_public/${OWNER}`).set(
    { usernameLower: 'stolen' }, { merge: true },
  ));
});

test('rules: a casing-only change is still a rename', async () => {
  const db = as(OWNER);
  await assertFails(db.doc(`users_public/${OWNER}`).set(
    { username: 'BENCHKING' }, { merge: true },
  ));
});

test('rules: nobody else can write another account identity', async () => {
  const db = as(OTHER);
  await assertFails(db.doc(`users_public/${OWNER}`).set(
    { username: 'Stolen', usernameLower: 'stolen' }, { merge: true },
  ));
});

// ── displayName is never a client field ─────────────────────────────────────

test('rules: the owner cannot write displayName, even on a fresh account', async () => {
  // displayName is a pure server mirror of the reserved username. No client
  // build has ever written it here, so it has no compatibility window.
  await assertFails(as(NEWBIE).doc(`users_public/${NEWBIE}`).set(
    { username: 'Newbie', usernameLower: 'newbie', displayName: 'Newbie' },
    { merge: true },
  ));
  await assertFails(as(OWNER).doc(`users_public/${OWNER}`).set(
    { displayName: 'Something Else' }, { merge: true },
  ));
});

// ── The legacy signup window is open ────────────────────────────────────────

test('rules: a pre-1.7.13 build can still stamp a FIRST username at signup', async () => {
  // This is exactly the write buildIdentityPayloadFields() produces, on both
  // documents, in the installed builds this release has to keep working.
  const db = as(NEWBIE);
  await assertSucceeds(db.doc(`users/${NEWBIE}`).set(
    { username: 'Newbie', usernameLower: 'newbie', fullName: 'New Bie' },
    { merge: true },
  ));
  await assertSucceeds(db.doc(`users_public/${NEWBIE}`).set(
    { username: 'Newbie', usernameLower: 'newbie', fullName: 'New Bie' },
    { merge: true },
  ));
});

test('rules: a first claim on a document that does not exist at all succeeds', async () => {
  const db = as('identityBrandNew');
  await assertSucceeds(db.doc('users_public/identityBrandNew').set({
    username: 'Fresh', usernameLower: 'fresh', email: 'f@example.invalid',
  }));
});

test('rules: a second claim by the same account is a rename and is denied', async () => {
  // The window is FIRST claim only, so it cannot be used twice to walk a name
  // onto an account that already has one.
  const db = as(NEWBIE);
  await assertSucceeds(db.doc(`users_public/${NEWBIE}`).set(
    { username: 'Newbie', usernameLower: 'newbie' }, { merge: true },
  ));
  await assertFails(db.doc(`users_public/${NEWBIE}`).set(
    { username: 'Newbie2', usernameLower: 'newbie2' }, { merge: true },
  ));
});

// ── The legacy window still enforces the shape ──────────────────────────────

test('rules: a legacy claim must obey the same 3-22 character rule', async () => {
  const db = as(NEWBIE);
  await assertFails(db.doc(`users_public/${NEWBIE}`).set(
    { username: 'ab', usernameLower: 'ab' }, { merge: true },
  ));
  await assertFails(db.doc(`users_public/${NEWBIE}`).set(
    { username: 'a'.repeat(23), usernameLower: 'a'.repeat(23) }, { merge: true },
  ));
});

test('rules: a legacy claim may not contain whitespace', async () => {
  const db = as(NEWBIE);
  await assertFails(db.doc(`users_public/${NEWBIE}`).set(
    { username: 'has space', usernameLower: 'has space' }, { merge: true },
  ));
});

test('rules: usernameLower must actually be the lower-cased username', async () => {
  // Otherwise a legacy claim could index one name while displaying another,
  // which is the exact drift the reservation index exists to prevent.
  const db = as(NEWBIE);
  await assertFails(db.doc(`users_public/${NEWBIE}`).set(
    { username: 'Newbie', usernameLower: 'somethingelse' }, { merge: true },
  ));
  await assertFails(db.doc(`users_public/${NEWBIE}`).set(
    { username: 'Newbie', usernameLower: 'Newbie' }, { merge: true },
  ));
});

test('rules: a legacy claim cannot smuggle profileShowcaseV1 alongside it', async () => {
  const db = as(NEWBIE);
  await assertFails(db.doc(`users_public/${NEWBIE}`).set({
    username: 'Newbie',
    usernameLower: 'newbie',
    profileShowcaseV1: { schema: 'profileShowcaseV1', lifts: {} },
  }, { merge: true }));
});

// ── Everything that is NOT identity still works ─────────────────────────────

test('rules: ordinary profile edits are unaffected', async () => {
  // The identity guard must not become a general write block: bio, avatar and
  // every other owner-editable field keep working exactly as before.
  await assertSucceeds(as(OWNER).doc(`users_public/${OWNER}`).set(
    { bio: 'New bio', photoURL: 'https://example.invalid/a.jpg' }, { merge: true },
  ));
  await assertSucceeds(as(OWNER).doc(`users/${OWNER}`).set(
    { sex: 'M', dob: '01-01-1990' }, { merge: true },
  ));
});

test('rules: rewriting the SAME username is not a change and is allowed', async () => {
  // A merge that re-sends the identical value affects no keys, so a client
  // that re-sends its whole profile payload is not broken by this guard.
  await assertSucceeds(as(OWNER).doc(`users_public/${OWNER}`).set(
    { username: 'BenchKing', usernameLower: 'benchking', bio: 'Still chasing 200.' },
    { merge: true },
  ));
});

test('rules: the super admin keeps full identity access', async () => {
  await assertSucceeds(as(SUPER).doc(`users_public/${OWNER}`).set(
    { username: 'Renamed', usernameLower: 'renamed', displayName: 'Renamed' },
    { merge: true },
  ));
});

// ── The reservation index itself ────────────────────────────────────────────

test('rules: no client may write the username reservation index', async () => {
  await assertFails(as(OTHER).doc('usernames/anyhash').set({ uid: OTHER }));
  await assertFails(as(OWNER).doc('usernames/anyhash').set({ uid: OWNER }));
  await assertFails(as(OWNER).doc('usernames/anyhash').delete());
  await assertFails(as(SUPER).doc('usernames/anyhash').set({ uid: SUPER }));
});

test('rules: any signed-in user may READ the index, so availability is checkable', async () => {
  await assertSucceeds(as(OTHER).doc('usernames/anyhash').get());
  await assertFails(env.unauthenticatedContext().firestore().doc('usernames/anyhash').get());
});
