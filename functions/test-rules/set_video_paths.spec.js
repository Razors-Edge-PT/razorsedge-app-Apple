'use strict';

// Firestore Rules cover for the paths the WES2 set-video feature actually
// uses at runtime.
//
// The rules themselves are UNCHANGED by this feature, which is precisely why
// this file exists: an unchanged rules file does not prove that a newly
// exercised operation is permitted. Three operations are new in the client:
//
//   1. an ADDITIVE merge write of `setId` onto one set inside
//      users/{uid}/workouts/{dateKey}, from the camera tap;
//   2. a Source.server read of users_public/{uid}.profileShowcaseV1, from the
//      showcase projection adapter;
//   3. a read of users/{uid}/proofs/{fingerprint}, from durable upload
//      recovery — INCLUDING the case where it does not exist, which is the
//      branch that decides an upload was dropped and must be retried.
//
// (3) changed BECAUSE of this file. Recovery originally read posts/{mediaId}.
// `match /posts/{postId}` allows read only if isSocial(resource.data.ownerUid),
// and on a missing document `resource` is null, so the read is DENIED rather
// than returning "not found" — proven below. The recovery branch would have
// thrown, been swallowed, and left the record queued for ever. Recovery now
// reads the owner's own proof pointer, which is readable whether or not it
// exists and is the same document the uploader consults for idempotency.

const { describe, it, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {
  doc,
  getDoc,
  setDoc,
  updateDoc,
} = require('firebase/firestore');

const OWNER = 'owner-1';
const STRANGER = 'stranger-9';
const DATE_KEY = '2026-08-31';
const MEDIA_ID = 'media-abc';

let testEnv;

describe('set-video Firestore paths', () => {
  before(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: 'rules-test',
      firestore: {
        rules: fs.readFileSync(
          path.join(__dirname, '..', '..', 'firestore.rules'),
          'utf8',
        ),
        host: '127.0.0.1',
        port: 8080,
      },
    });
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
  });

  beforeEach(async () => {
    await testEnv.clearFirestore();
  });

  describe('1. additive setId write on a workout set', () => {
    it('the owner may merge a setId onto their own workout', async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(
          doc(ctx.firestore(), `users/${OWNER}/workouts/${DATE_KEY}`),
          {
            exercises: [
              { exerciseId: 'ex1', name: 'Bench', sets: [{ setIndex: 0, weight: 100, reps: 5 }] },
            ],
          },
        );
      });

      const db = testEnv.authenticatedContext(OWNER).firestore();
      await assertSucceeds(
        updateDoc(doc(db, `users/${OWNER}/workouts/${DATE_KEY}`), {
          exercises: [
            {
              exerciseId: 'ex1',
              name: 'Bench',
              sets: [{ setIndex: 0, weight: 100, reps: 5, setId: 'sid-1' }],
            },
          ],
        }),
      );
    });

    it('a stranger may not write another athlete\'s workout', async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(
          doc(ctx.firestore(), `users/${OWNER}/workouts/${DATE_KEY}`),
          { exercises: [] },
        );
      });

      const db = testEnv.authenticatedContext(STRANGER).firestore();
      await assertFails(
        updateDoc(doc(db, `users/${OWNER}/workouts/${DATE_KEY}`), {
          exercises: [{ exerciseId: 'ex1', sets: [{ setId: 'sid-1' }] }],
        }),
      );
    });

    it('the owner may read their own workout back', async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(
          doc(ctx.firestore(), `users/${OWNER}/workouts/${DATE_KEY}`),
          { exercises: [] },
        );
      });
      const db = testEnv.authenticatedContext(OWNER).firestore();
      await assertSucceeds(
        getDoc(doc(db, `users/${OWNER}/workouts/${DATE_KEY}`)),
      );
    });

    it('an unauthenticated client may not read a workout', async () => {
      const db = testEnv.unauthenticatedContext().firestore();
      await assertFails(
        getDoc(doc(db, `users/${OWNER}/workouts/${DATE_KEY}`)),
      );
    });
  });

  describe('2. showcase projection read', () => {
    it('the owner may read their own users_public projection', async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `users_public/${OWNER}`), {
          profileShowcaseV1: { schema: 'profileShowcaseV1', lifts: {} },
        });
      });
      const db = testEnv.authenticatedContext(OWNER).firestore();
      await assertSucceeds(getDoc(doc(db, `users_public/${OWNER}`)));
    });

    it('the client may not forge its own showcase projection', async () => {
      const db = testEnv.authenticatedContext(OWNER).firestore();
      await assertFails(
        setDoc(doc(db, `users_public/${OWNER}`), {
          profileShowcaseV1: { schema: 'profileShowcaseV1', lifts: { bench: {} } },
        }),
      );
    });
  });

  describe('3. durable upload recovery', () => {
    it('the owner may read their own published post', async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `posts/${MEDIA_ID}`), {
          ownerUid: OWNER,
          mediaType: 'video',
        });
      });
      const db = testEnv.authenticatedContext(OWNER).firestore();
      await assertSucceeds(getDoc(doc(db, `posts/${MEDIA_ID}`)));
    });

    it('a MISSING post is DENIED, which is why recovery must not read it',
      async () => {
        // The finding this file exists for. `match /posts/{postId}` allows read
        // only if isSocial(resource.data.ownerUid), and on a document that does
        // not exist `resource` is null, so the rule errors and the read is
        // denied rather than returning "not found".
        //
        // The first implementation of durable upload recovery read
        // posts/{mediaId} to decide whether an upload had landed. It would have
        // thrown here, been swallowed, and left the record queued for ever - a
        // dropped upload that never retried. Recovery reads the owner's own
        // proof pointer instead; this test pins WHY.
        const db = testEnv.authenticatedContext(OWNER).firestore();
        await assertFails(getDoc(doc(db, 'posts/definitely-not-a-real-post')));
      });

    it("a stranger may not read another user's post", async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `posts/${MEDIA_ID}`), {
          ownerUid: OWNER,
          mediaType: 'video',
        });
      });
      const db = testEnv.authenticatedContext(STRANGER).firestore();
      await assertFails(getDoc(doc(db, `posts/${MEDIA_ID}`)));
    });

    it('the owner may create the proof post the uploader writes', async () => {
      const db = testEnv.authenticatedContext(OWNER).firestore();
      await assertSucceeds(
        setDoc(doc(db, `posts/${MEDIA_ID}`), {
          ownerUid: OWNER,
          mediaType: 'video',
          createdAt: new Date(),
        }),
      );
    });

    it('the owner may read their own proof pointer, present or absent',
      async () => {
        const db = testEnv.authenticatedContext(OWNER).firestore();

        // Absent: this is the "upload was dropped" branch, and it must be a
        // successful read reporting not-found, not a denial.
        const missing = await assertSucceeds(
          getDoc(doc(db, `users/${OWNER}/proofs/no-such-fingerprint`)),
        );
        assert.equal(missing.exists(), false);

        await testEnv.withSecurityRulesDisabled(async (ctx) => {
          await setDoc(
            doc(ctx.firestore(), `users/${OWNER}/proofs/fp-1`),
            { fingerprint: 'fp-1', postId: MEDIA_ID, slot: 'bench' },
          );
        });

        const found = await assertSucceeds(
          getDoc(doc(db, `users/${OWNER}/proofs/fp-1`)),
        );
        assert.equal(found.exists(), true);
        assert.equal(found.data().postId, MEDIA_ID);
      });

    it("a stranger may not read another athlete's proof pointer", async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), `users/${OWNER}/proofs/fp-1`), {
          fingerprint: 'fp-1',
          postId: MEDIA_ID,
        });
      });
      const db = testEnv.authenticatedContext(STRANGER).firestore();
      await assertFails(getDoc(doc(db, `users/${OWNER}/proofs/fp-1`)));
    });

    it('the owner may delete their own post, as full deletion requires',
      async () => {
        await testEnv.withSecurityRulesDisabled(async (ctx) => {
          await setDoc(doc(ctx.firestore(), `posts/${MEDIA_ID}`), {
            ownerUid: OWNER,
            mediaType: 'video',
          });
        });
        const db = testEnv.authenticatedContext(OWNER).firestore();
        const { deleteDoc } = require('firebase/firestore');
        await assertSucceeds(deleteDoc(doc(db, `posts/${MEDIA_ID}`)));
      });
  });
});
