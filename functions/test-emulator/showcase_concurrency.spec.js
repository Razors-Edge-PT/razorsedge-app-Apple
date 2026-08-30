'use strict';

// PRODUCTION-ADAPTER concurrency tests for the Big Five showcase projection.
//
// These run the REAL Firestore adapter (firestore_store.js) against the REAL
// Firestore emulator through firebase-admin — not the in-memory store the unit
// tests use. That distinction is the whole point: the defect these cover is
// invisible to an in-memory store, because an in-memory store has no notion of
// two callers reading the same document at the same moment.
//
//   npm run test:emulator
//
// ── What is being proved ────────────────────────────────────────────────────
// The projection is a read-modify-write over users_public/{uid}.
// profileShowcaseV1. Two trigger instances for the SAME athlete can be alive
// at the same time — a squat day and a bench day landing together, or an
// original delivery racing its own retry. With a plain batch, both read the
// same snapshot, each folds in only its own lift, and the second commit
// silently drops the first athlete's lift while leaving its showcaseDays
// document in place: a projection that disagrees with the data it is derived
// from.
//
// applyWorkoutDayTransactionally puts the read inside the atomic unit, so the
// losing attempt is replayed against the committed state and both lifts
// survive.

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

const BENCH = 'AmfUWbF1DH3I7qPAdh5k';
const SQUAT = 'heeBViVINHO6tUScSd6y';
const DEADLIFT = 'MsGl7e9yanDeEnYX0e4X';

let store;

test.before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: process.env.GCLOUD_PROJECT || 'rules-test' });
  }
  // Required AFTER initializeApp: the module resolves admin.firestore() lazily,
  // but requiring it earlier would still be fine — this only keeps the order
  // obvious to a reader.
  store = require('../showcase/firestore_store');
});

function workout(exerciseId, sets) {
  return { exercises: [{ exerciseId, name: 'x', sets }] };
}

let seq = 0;
function freshUid() {
  seq += 1;
  return `concurrency_${Date.now()}_${seq}`;
}

async function wipe(uid) {
  const db = admin.firestore();
  await db.recursiveDelete(db.collection('users').doc(uid));
  await db.collection('users_public').doc(uid).delete().catch(() => {});
}

async function readSnapshot(uid) {
  return store.readPublishedSnapshot(uid);
}

async function readDayIds(uid) {
  const q = await store.daysCol(uid).get();
  return q.docs.map((d) => d.id).sort();
}

// ── Two different days, two different lifts, at the same instant ────────────

test('separate trigger instances appending different days and lifts both survive', async () => {
  const uid = freshUid();
  try {
    // Started together, with no ordering between them: exactly the shape of
    // two Cloud Functions instances woken by two workout writes.
    const [a, b] = await Promise.all([
      store.applyWorkoutDayTransactionally(
        uid, '2026-01-05', workout(SQUAT, [{ weight: 200, reps: 3 }]),
      ),
      store.applyWorkoutDayTransactionally(
        uid, '2026-01-06', workout(BENCH, [{ weight: 140, reps: 2 }]),
      ),
    ]);
    assert.equal(a.changed, true);
    assert.equal(b.changed, true);

    // BOTH day contributions are stored.
    assert.deepEqual(await readDayIds(uid), ['bench__2026-01-06', 'squat__2026-01-05']);

    // BOTH lifts are in the published snapshot. This is the assertion the
    // pre-fix code fails: whichever trigger committed second wrote a snapshot
    // built from a read that predated the other one.
    const snap = await readSnapshot(uid);
    assert.ok(snap, 'a snapshot was published');
    assert.ok(snap.lifts.squat && snap.lifts.squat.heaviest, 'the squat day survived');
    assert.ok(snap.lifts.bench && snap.lifts.bench.heaviest, 'the bench day survived');
    assert.equal(snap.lifts.squat.heaviest.weight, 200);
    assert.equal(snap.lifts.bench.heaviest.weight, 140);
  } finally {
    await wipe(uid);
  }
});

test('three simultaneous lifts on three days all survive', async () => {
  const uid = freshUid();
  try {
    await Promise.all([
      store.applyWorkoutDayTransactionally(
        uid, '2026-02-01', workout(SQUAT, [{ weight: 210, reps: 1 }]),
      ),
      store.applyWorkoutDayTransactionally(
        uid, '2026-02-02', workout(BENCH, [{ weight: 150, reps: 1 }]),
      ),
      store.applyWorkoutDayTransactionally(
        uid, '2026-02-03', workout(DEADLIFT, [{ weight: 260, reps: 1 }]),
      ),
    ]);

    const snap = await readSnapshot(uid);
    for (const slot of ['squat', 'bench', 'deadlift']) {
      assert.ok(snap.lifts[slot] && snap.lifts[slot].heaviest, `${slot} survived`);
    }
    assert.equal(snap.lifts.squat.heaviest.weight, 210);
    assert.equal(snap.lifts.bench.heaviest.weight, 150);
    assert.equal(snap.lifts.deadlift.heaviest.weight, 260);
  } finally {
    await wipe(uid);
  }
});

// ── The same lift, two days, at the same instant ────────────────────────────

test('two simultaneous days of the SAME lift keep the better result', async () => {
  const uid = freshUid();
  try {
    await Promise.all([
      store.applyWorkoutDayTransactionally(
        uid, '2026-03-01', workout(BENCH, [{ weight: 120, reps: 5 }]),
      ),
      store.applyWorkoutDayTransactionally(
        uid, '2026-03-02', workout(BENCH, [{ weight: 145, reps: 1 }]),
      ),
    ]);

    assert.deepEqual(await readDayIds(uid), ['bench__2026-03-01', 'bench__2026-03-02']);
    const snap = await readSnapshot(uid);
    // 145x1 is the heaviest; the fold is over BOTH days whichever order the
    // two transactions committed in.
    assert.equal(snap.lifts.bench.heaviest.weight, 145);
    assert.equal(snap.lifts.bench.heaviest.dateKey, '2026-03-02');
  } finally {
    await wipe(uid);
  }
});

// ── Duplicate delivery converges ────────────────────────────────────────────

test('duplicate retries of the same day converge on one identical result', async () => {
  const uid = freshUid();
  try {
    const day = workout(BENCH, [{ weight: 130, reps: 3 }]);
    await store.applyWorkoutDayTransactionally(uid, '2026-04-01', day);
    const first = await readSnapshot(uid);

    // At-least-once delivery: the same event arrives four more times, two of
    // them simultaneously.
    await store.applyWorkoutDayTransactionally(uid, '2026-04-01', day);
    const [r1, r2] = await Promise.all([
      store.applyWorkoutDayTransactionally(uid, '2026-04-01', day),
      store.applyWorkoutDayTransactionally(uid, '2026-04-01', day),
    ]);
    await store.applyWorkoutDayTransactionally(uid, '2026-04-01', day);

    // A duplicate must be recognised as a no-op, not re-folded.
    assert.equal(r1.changed, false);
    assert.equal(r2.changed, false);

    const after = await readSnapshot(uid);
    assert.deepEqual(stripVolatile(after), stripVolatile(first));
    assert.deepEqual(await readDayIds(uid), ['bench__2026-04-01']);
  } finally {
    await wipe(uid);
  }
});

test('a retry racing a NEW day loses neither', async () => {
  const uid = freshUid();
  try {
    const benchDay = workout(BENCH, [{ weight: 125, reps: 4 }]);
    await store.applyWorkoutDayTransactionally(uid, '2026-05-01', benchDay);

    // The original delivery is retried at the same moment a genuinely new day
    // lands. The retry must not roll the new day back out of the snapshot.
    await Promise.all([
      store.applyWorkoutDayTransactionally(uid, '2026-05-01', benchDay),
      store.applyWorkoutDayTransactionally(
        uid, '2026-05-02', workout(SQUAT, [{ weight: 190, reps: 5 }]),
      ),
    ]);

    const snap = await readSnapshot(uid);
    assert.ok(snap.lifts.bench && snap.lifts.bench.heaviest, 'the bench day survived');
    assert.ok(snap.lifts.squat && snap.lifts.squat.heaviest, 'the squat day survived');
    assert.equal(snap.lifts.squat.heaviest.weight, 190);
  } finally {
    await wipe(uid);
  }
});

// ── An edit re-folds the CHANGED day, not the stale one ─────────────────────

test('an edit rebuilds the slot from the edited day, not the stored one', async () => {
  // The buffered store queues its day writes and then re-reads the slot to
  // re-fold it. Without a pending-write overlay that re-read returns the days
  // as they were BEFORE the edit, and the published snapshot keeps a result
  // the athlete has just corrected away.
  const uid = freshUid();
  try {
    await store.applyWorkoutDayTransactionally(
      uid, '2026-06-01', workout(BENCH, [{ weight: 100, reps: 5 }]),
    );
    await store.applyWorkoutDayTransactionally(
      uid, '2026-06-02', workout(BENCH, [{ weight: 180, reps: 1 }]),
    );
    assert.equal((await readSnapshot(uid)).lifts.bench.heaviest.weight, 180);

    // 180 was a typo; it was really 118.
    const edit = await store.applyWorkoutDayTransactionally(
      uid, '2026-06-02', workout(BENCH, [{ weight: 118, reps: 1 }]),
    );
    assert.equal(edit.path, 'rebuild');

    const snap = await readSnapshot(uid);
    assert.equal(snap.lifts.bench.heaviest.weight, 118);
    assert.equal(snap.lifts.bench.heaviest.dateKey, '2026-06-02');
  } finally {
    await wipe(uid);
  }
});

test('deleting a day removes its contribution from the snapshot', async () => {
  const uid = freshUid();
  try {
    await store.applyWorkoutDayTransactionally(
      uid, '2026-07-01', workout(BENCH, [{ weight: 100, reps: 5 }]),
    );
    await store.applyWorkoutDayTransactionally(
      uid, '2026-07-02', workout(BENCH, [{ weight: 160, reps: 1 }]),
    );
    // null workoutData is what the trigger passes for a deleted document.
    await store.applyWorkoutDayTransactionally(uid, '2026-07-02', null);

    assert.deepEqual(await readDayIds(uid), ['bench__2026-07-01']);
    const snap = await readSnapshot(uid);
    assert.equal(snap.lifts.bench.heaviest.weight, 100);
  } finally {
    await wipe(uid);
  }
});

test('removing the last day for a lift takes the achievement DOWN', async () => {
  // The snapshot mirror is published with mergeFields, not merge. A deep merge
  // can only ever ADD keys, so an omitted lift would keep standing on the
  // public profile after the workout it came from was deleted.
  const uid = freshUid();
  try {
    await store.applyWorkoutDayTransactionally(
      uid, '2026-09-01', workout(BENCH, [{ weight: 100, reps: 5 }]),
    );
    await store.applyWorkoutDayTransactionally(
      uid, '2026-09-02', workout(SQUAT, [{ weight: 180, reps: 5 }]),
    );
    assert.ok((await readSnapshot(uid)).lifts.bench, 'bench was published');

    await store.applyWorkoutDayTransactionally(uid, '2026-09-01', null);

    const snap = await readSnapshot(uid);
    assert.equal(snap.lifts.bench, undefined, 'bench is gone from the snapshot');
    assert.ok(snap.lifts.squat, 'squat is untouched');
  } finally {
    await wipe(uid);
  }
});

// ── The snapshot mirror never disturbs its neighbours ───────────────────────

test('publishing the snapshot leaves the rest of users_public alone', async () => {
  const uid = freshUid();
  try {
    const db = admin.firestore();
    await db.collection('users_public').doc(uid).set({
      username: 'BenchKing',
      usernameLower: 'benchking',
      rePointsRolling12: 1234,
    });

    await Promise.all([
      store.applyWorkoutDayTransactionally(
        uid, '2026-08-01', workout(BENCH, [{ weight: 100, reps: 5 }]),
      ),
      store.applyWorkoutDayTransactionally(
        uid, '2026-08-02', workout(SQUAT, [{ weight: 180, reps: 5 }]),
      ),
    ]);

    const doc = await db.collection('users_public').doc(uid).get();
    const d = doc.data();
    assert.equal(d.username, 'BenchKing');
    assert.equal(d.rePointsRolling12, 1234);
    assert.ok(d.profileShowcaseV1.lifts.bench);
    assert.ok(d.profileShowcaseV1.lifts.squat);
  } finally {
    await wipe(uid);
  }
});

/** updatedAtMs is a wall clock; it is expected to differ between runs. */
function stripVolatile(snapshot) {
  if (!snapshot) return snapshot;
  const copy = JSON.parse(JSON.stringify(snapshot));
  delete copy.updatedAtMs;
  return copy;
}
