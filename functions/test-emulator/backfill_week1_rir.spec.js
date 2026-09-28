'use strict';

// Week-1 RIR backfill against the real Firestore engine (emulator).
//
//   npm run test:emulator

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const admin = require('firebase-admin');

let B; // scripts/backfill_week1_rir
let W; // scripts/week1_rir_fill

const PROJECT = process.env.GCLOUD_PROJECT || 'rules-test';

test.before(async () => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    'FIRESTORE_EMULATOR_HOST must be set — run through `npm run test:emulator`',
  );
  if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT });
  B = require('../scripts/backfill_week1_rir');
  W = require('../scripts/week1_rir_fill');
  // The collection-group scan must only see this spec's blocks.
  const res = await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`,
    { method: 'DELETE' },
  );
  assert.ok(res.ok, `emulator reset failed: ${res.status}`);
});

const db = () => admin.firestore();

// Every case the backfill must handle, in one realistic block.
const INCOMPLETE = {
  periodizationModel: 'DUP, By Exposure',
  defaultSets: 3,
  repTargets: { week1: { instance1: '5', instance2: '8 x 2' } },
  rirPlan: {
    week1: { session1: { set1: { rir: '2' } } },
    week2: { session1: { set1: { rir: '9' } } }, // other weeks untouched
  },
  notes: 'keep',
  unknownFutureKey: { nested: [1, 2, 3] },
};
const COMPLETE = {
  defaultSets: 1,
  repTargets: { week1: { instance1: '10' } },
  rirPlan: { week1: { session1: { set1: { rir: '1.5', reps: '10' } } } },
};
const BLANK_AND_ZERO = {
  defaultSets: 3,
  repTargets: { week1: { instance1: '6' } },
  rirPlan: { week1: { session1: {
    set1: { reps: '6' }, // RIR deliberately cleared
    set2: { rir: '', reps: '' },
    set3: { rir: '0', reps: 0 },
  } } },
  increments: { primary: 0 },
  notes: '',
};
const AMBIGUOUS = { repTargets: { week1: { instance1: '8' } } }; // no defaultSets
const SIGNATURE = { defaultSets: 3, repTargets: { min: '6', max: '12' } };
const TWO_SETS = { defaultSets: 2, repTargets: { week1: { instance1: '12' } } };

const BLOCK_FIELDS = {
  name: 'Active block',
  isActive: true,
  startDate: admin.firestore.Timestamp.fromDate(new Date('2026-09-07T00:00:00Z')),
  exercises: ['inc', 'ok', 'blank', 'amb', 'sig', 'two'],
  plannedExerciseDetails: { inc: { notes: 'legacy' } },
};

async function seed() {
  await db().doc('users/alice/planned_blocks/b1').set({
    ...BLOCK_FIELDS,
    exerciseSettings: {
      inc: INCOMPLETE, ok: COMPLETE, blank: BLANK_AND_ZERO,
      amb: AMBIGUOUS, sig: SIGNATURE, two: TWO_SETS,
    },
  });
  await db().doc('users/alice/planned_blocks/b2').set({
    name: 'Complete block', exerciseSettings: { ok: COMPLETE },
  });
  await db().doc('users/bob/planned_blocks/b1').set({
    name: 'Bob', exerciseSettings: { two: TWO_SETS },
  });
  // Retired top-level tree: never scanned, never written.
  await db().doc('planned_blocks/alice/blocks/b1').set({
    exerciseSettings: { two: TWO_SETS },
  });
}

async function snapshotAll() {
  // listDocuments() includes "missing" parents (users/{uid} with no fields),
  // so every nested planned block is reached.
  const out = {};
  const walkCol = async (col) => {
    for (const ref of await col.listDocuments()) {
      const snap = await ref.get();
      if (snap.exists) out[ref.path] = snap.data();
      for (const sub of await ref.listCollections()) await walkCol(sub);
    }
  };
  for (const col of await db().listCollections()) await walkCol(col);
  return JSON.parse(JSON.stringify(out));
}

const filled = (s) => W.applyFills(s, W.planWeek1RirFill(s).fills);

test('dry run writes nothing and reports users, blocks, exercises and fields', async () => {
  await seed();
  const before = await snapshotAll();
  const report = await B.run({ db: db(), pageSize: 2 });
  assert.deepEqual(await snapshotAll(), before, 'dry run is read-only');

  assert.equal(report.mode, 'dry-run');
  assert.equal(report.scannedBlocks, 3, 'only users/*/planned_blocks');
  assert.deepEqual(Object.keys(report.users).sort(), ['alice', 'bob']);
  const b1 = report.users.alice.blocks.b1;
  const byId = Object.fromEntries(b1.map((e) => [e.exerciseId, e]));
  assert.deepEqual(Object.keys(byId).sort(), ['amb', 'inc', 'two']);
  assert.deepEqual(byId.inc.fields.map((f) => f.path), [
    'rirPlan.week1.session1.set1.reps',
    'rirPlan.week1.session1.set2',
    'rirPlan.week1.session1.set3',
    'rirPlan.week1.session2.set1',
    'rirPlan.week1.session2.set2',
  ], 'session2 has 2 sets ("8 x 2"), never a third');
  assert.equal(byId.amb.status, 'ambiguous');
  assert.match(byId.amb.reasons.join(' '), /defaultSets absent/);
  assert.deepEqual(byId.two.fields.map((f) => f.path),
    ['rirPlan.week1.session1.set1', 'rirPlan.week1.session1.set2'],
    'defaultSets 2 → never set3/set4');
  assert.equal(report.totals.usersAffected, 2);
  assert.equal(report.totals.blocksAffected, 2);
  assert.equal(report.totals.exercisesAmbiguous, 1);
  assert.equal(report.totals.blocksWritten, 0);
});

test('apply fills only missing, derivable leaves; everything else is byte-identical', async () => {
  const before = await snapshotAll();
  const report = await B.run({ db: db(), apply: true });
  const after = await snapshotAll();

  assert.equal(report.totals.blocksWritten, 2);
  const a1 = after['users/alice/planned_blocks/b1'];
  const b1Before = before['users/alice/planned_blocks/b1'];
  assert.deepEqual(a1.exerciseSettings.inc, filled(b1Before.exerciseSettings.inc));
  assert.deepEqual(a1.exerciseSettings.two, filled(TWO_SETS));
  for (const id of ['ok', 'blank', 'amb', 'sig']) {
    assert.deepEqual(a1.exerciseSettings[id], b1Before.exerciseSettings[id], id);
  }
  for (const k of Object.keys(b1Before).filter((k) => k !== 'exerciseSettings')) {
    assert.deepEqual(a1[k], b1Before[k], k);
  }
  assert.deepEqual(a1.exerciseSettings.inc.rirPlan.week2, INCOMPLETE.rirPlan.week2);
  assert.equal(a1.exerciseSettings.inc.rirPlan.week1.session1.set1.rir, '2',
    'an existing RIR value is never overwritten');
  assert.deepEqual(after['users/alice/planned_blocks/b2'], before['users/alice/planned_blocks/b2']);
  assert.deepEqual(after['users/bob/planned_blocks/b1'].exerciseSettings.two, filled(TWO_SETS));
  assert.deepEqual(after['planned_blocks/alice/blocks/b1'], before['planned_blocks/alice/blocks/b1'],
    'the retired tree is never touched');
  for (const p of Object.keys(before)) assert.ok(p in after, `nothing deleted: ${p}`);
});

test('running it again makes no additional changes', async () => {
  const before = await snapshotAll();
  const report = await B.run({ db: db(), apply: true });
  assert.equal(report.totals.blocksWritten, 0);
  assert.equal(report.totals.fieldsToFill, 0);
  assert.equal(report.totals.exercisesAmbiguous, 1, 'still reported, never guessed');
  assert.deepEqual(await snapshotAll(), before);
});

test('resumable: a checkpointed run in slices reaches the same result', async () => {
  // Fresh data for a separate user, processed one block per invocation.
  await db().doc('users/carol/planned_blocks/x1').set({ exerciseSettings: { two: TWO_SETS } });
  await db().doc('users/carol/planned_blocks/x2').set({ exerciseSettings: { two: TWO_SETS } });
  const ckpt = path.join(os.tmpdir(), `rir-ckpt-${Date.now()}`);
  let written = 0;
  for (let i = 0; i < 5; i += 1) {
    const r = await B.run({ db: db(), apply: true, uid: 'carol', pageSize: 1, limitBlocks: 1, checkpoint: ckpt });
    written += r.totals.blocksWritten;
  }
  fs.rmSync(ckpt, { force: true });
  assert.equal(written, 2);
  for (const id of ['x1', 'x2']) {
    const d = (await db().doc(`users/carol/planned_blocks/${id}`).get()).data();
    assert.deepEqual(d.exerciseSettings.two, filled(TWO_SETS));
  }
});

test('the transaction re-plans against the server copy (no stale overwrite)', async () => {
  await db().doc('users/dave/planned_blocks/y1').set({ exerciseSettings: { two: TWO_SETS } });
  // A user fills set1 between the scan and the write: the backfill must keep it.
  const realGet = admin.firestore.Transaction.prototype.get;
  let once = false;
  admin.firestore.Transaction.prototype.get = async function patched(ref) {
    if (!once && ref.path === 'users/dave/planned_blocks/y1') {
      once = true;
      await db().doc(ref.path).update(
        new admin.firestore.FieldPath('exerciseSettings', 'two', 'rirPlan', 'week1', 'session1', 'set1'),
        { rir: '4', reps: '12' },
      );
    }
    return realGet.call(this, ref);
  };
  try {
    await B.run({ db: db(), apply: true, uid: 'dave' });
  } finally {
    admin.firestore.Transaction.prototype.get = realGet;
  }
  const d = (await db().doc('users/dave/planned_blocks/y1').get()).data();
  assert.deepEqual(d.exerciseSettings.two.rirPlan.week1.session1.set1, { rir: '4', reps: '12' });
  assert.ok(d.exerciseSettings.two.rirPlan.week1.session1.set2, 'set2 still filled');
});
