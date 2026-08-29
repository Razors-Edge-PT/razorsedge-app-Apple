'use strict';

// Fail-closed regression tests for the migration's PREFLIGHT.
//
// The defect: every required read was wrapped in a catch that recorded a
// `problem()` and then carried on with an EMPTY result. An expired credential
// therefore looked exactly like "there is nothing here" — every count read 0,
// the unresolved-legacy-coach gate passed vacuously, and the run exited 0.
// A real `--apply` would have sailed straight past its own safety gate.
//
// These tests inject failures into individual reads by loading the migration
// against a FAKE firebase-admin, so each required read can be failed in
// isolation. No network, no emulator, no credentials.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const Module = require('node:module');

// resolveProjectId() runs when main() executes, not when the module loads, so
// the project must stay set for the whole file. The wrong-project test
// overrides it locally.
process.env.GCLOUD_PROJECT = 'goodlift-us-storage';

const ADMIN_ID = require.resolve('firebase-admin');
const MIGRATION_ID = require.resolve('../migrate_coach_mode');

/** A Firestore DocumentSnapshot stand-in. */
const snap = (data) => ({ exists: !!data, id: 'x', data: () => data || null });
/** A QuerySnapshot stand-in. */
const query = (docs) => ({ size: docs.length, docs });
const qdoc = (id, data) => ({ id, data: () => data });

/**
 * Loads a FRESH copy of the migration with a fake firebase-admin.
 *
 * `fail` names which required read should throw:
 *   'coachAssignments' | 'athleteAssignments' | 'entitlement' | 'link' | 'auth'
 * `authError` overrides the Auth error code (to test user-not-found).
 */
function loadMigration({ fail, authError, argv } = {}) {
  const boom = (what) => { throw new Error('injected failure: ' + what); };

  const writes = [];

  const docApi = (collectionName, docId) => ({
    get: async () => {
      if (collectionName === 'accountEntitlements') {
        if (fail === 'entitlement') boom('entitlement read');
        return snap(null); // no entitlement yet
      }
      if (collectionName === 'coachAthleteLinks') {
        if (fail === 'link') boom('link read');
        return snap(null);
      }
      if (collectionName === 'users') return snap({ email: 'x@y.z' });
      return snap(null);
    },
    set: async (data, opts) => {
      writes.push({ op: 'set', collectionName, docId, data, opts });
    },
    update: async (data) => {
      writes.push({ op: 'update', collectionName, docId, data });
    },
  });

  const collectionApi = (name) => ({
    doc: (id) => docApi(name, id),
    get: async () => {
      if (name === 'coachAssignments') {
        if (fail === 'coachAssignments') boom('coachAssignments scan');
        return query([
          qdoc('someLegacyCoach', { athletes: { ath1: { email: 'a@b.c' } } }),
        ]);
      }
      if (name === 'athleteAssignments') {
        if (fail === 'athleteAssignments') boom('athleteAssignments scan');
        return query([
          qdoc('ath1', { coaches: { someLegacyCoach: { approved: true } } }),
        ]);
      }
      return query([]);
    },
  });

  const fakeAdmin = {
    apps: [{}], // pretend initializeApp already ran
    initializeApp: () => {},
    firestore: Object.assign(
      () => ({ collection: collectionApi }),
      { FieldValue: { serverTimestamp: () => 'TS', delete: () => 'DEL' } },
    ),
    auth: () => ({
      getUser: async () => {
        if (fail === 'auth') {
          const e = new Error(authError || 'injected failure: auth lookup');
          e.code = authError || 'auth/internal-error';
          throw e;
        }
        return { uid: 'u', customClaims: {}, displayName: 'N', email: 'e@x.y' };
      },
      setCustomUserClaims: async (uid, claims) => {
        writes.push({ op: 'setCustomUserClaims', uid, claims });
      },
    }),
  };

  // Install the fake, drop any cached migration, then load a fresh one.
  const realAdmin = require.cache[ADMIN_ID];
  require.cache[ADMIN_ID] = new Module(ADMIN_ID, null);
  require.cache[ADMIN_ID].filename = ADMIN_ID;
  require.cache[ADMIN_ID].loaded = true;
  require.cache[ADMIN_ID].exports = fakeAdmin;
  delete require.cache[MIGRATION_ID];

  const savedArgv = process.argv;
  process.argv = ['node', MIGRATION_ID].concat(argv || []);

  let mod;
  try {
    mod = require(MIGRATION_ID);
  } finally {
    process.argv = savedArgv;
    if (realAdmin) require.cache[ADMIN_ID] = realAdmin;
    else delete require.cache[ADMIN_ID];
    delete require.cache[MIGRATION_ID];
  }
  return { mod, writes };
}

/** Silences the report while capturing the exit code. */
async function runMain(mod) {
  const outWrite = process.stdout.write;
  const errWrite = process.stderr.write;
  let stdout = '';
  let stderr = '';
  process.stdout.write = (c) => { stdout += c; return true; };
  process.stderr.write = (c) => { stderr += c; return true; };
  try {
    const code = await mod.main();
    return { code, stdout, stderr };
  } finally {
    process.stdout.write = outWrite;
    process.stderr.write = errWrite;
  }
}

// ── Individual required reads must fail closed ──────────────────────────────

test('failed coachAssignments scan fails closed (dry run exits 4)', async () => {
  const { mod, writes } = loadMigration({ fail: 'coachAssignments' });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT);
  const r = mod._internals.report;
  assert.equal(r.auditComplete, false, 'a failed scan is NOT an empty scan');
  assert.ok(r.operationalFailures.some(
    (f) => f.kind === 'unresolved-scan-failed' && f.collection === 'coachAssignments'));
  assert.equal(r.blocked, true);
  assert.equal(writes.length, 0);
});

test('failed athleteAssignments scan fails closed', async () => {
  const { mod, writes } = loadMigration({ fail: 'athleteAssignments' });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT);
  const r = mod._internals.report;
  assert.equal(r.auditComplete, false);
  assert.ok(r.operationalFailures.some(
    (f) => f.kind === 'athlete-assignments-scan-failed'
        || (f.kind === 'unresolved-scan-failed' && f.collection === 'athleteAssignments')));
  assert.equal(writes.length, 0);
});

test('failed entitlement read fails closed', async () => {
  const { mod, writes } = loadMigration({ fail: 'entitlement' });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT);
  const r = mod._internals.report;
  assert.equal(r.auditComplete, false);
  assert.ok(r.operationalFailures.some((f) => /entitlement-read-failed/.test(f.kind)));
  assert.equal(writes.length, 0);
});

test('failed link read fails closed', async () => {
  const { mod, writes } = loadMigration({ fail: 'link' });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT);
  assert.equal(mod._internals.report.auditComplete, false);
  assert.ok(mod._internals.report.operationalFailures.some(
    (f) => f.kind === 'link-read-failed'));
  assert.equal(writes.length, 0);
});

test('failed Auth/claim lookup fails closed under --claims', async () => {
  const { mod, writes } = loadMigration({ fail: 'auth', argv: ['--claims'] });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT);
  const r = mod._internals.report;
  assert.equal(r.auditComplete, false);
  assert.ok(r.operationalFailures.some((f) => f.kind === 'claim-refresh-lookup-failed'));
  assert.equal(writes.length, 0);
});

test('a MISSING Auth account is a data finding, not an operational failure',
  async () => {
    // "This account no longer exists" is a fact about the data. Blocking on it
    // forever would be wrong, so it must not mark the audit incomplete.
    const { mod } = loadMigration({
      fail: 'auth', authError: 'auth/user-not-found', argv: ['--claims'],
    });
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_OK, 'a stale uid must not block the run');
    const r = mod._internals.report;
    assert.equal(r.auditComplete, true);
    assert.equal(r.operationalFailures.length, 0);
    assert.ok(r.problems.some((p) => p.kind === 'claim-refresh-account-missing'));
  });

// ── Apply mode must write NOTHING after a preflight failure ─────────────────

test('--apply performs ZERO writes after any preflight failure', async () => {
  for (const fail of ['coachAssignments', 'athleteAssignments', 'entitlement', 'link']) {
    const { mod, writes } = loadMigration({ fail, argv: ['--apply'] });
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT, 'fail=' + fail);
    assert.equal(writes.length, 0,
      'apply must abort BEFORE the first write (fail=' + fail + ')');
    assert.match(mod._internals.report.blockedReason, /NOTHING WAS WRITTEN/);
  }
});

test('--apply --claims performs ZERO writes after an Auth preflight failure',
  async () => {
    const { mod, writes } = loadMigration({
      fail: 'auth', argv: ['--apply', '--claims'],
    });
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT);
    assert.equal(writes.length, 0,
      'no Firestore write and no setCustomUserClaims may occur');
  });

// ── --allow-unresolved must not override operational failures ──────────────

test('--allow-unresolved does NOT bypass an operational read failure', async () => {
  for (const fail of ['coachAssignments', 'athleteAssignments', 'entitlement']) {
    const { mod, writes } = loadMigration({
      fail, argv: ['--apply', '--allow-unresolved'],
    });
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT,
      '--allow-unresolved overrides reviewed DATA only (fail=' + fail + ')');
    assert.equal(writes.length, 0);
    assert.match(mod._internals.report.blockedReason,
      /--allow-unresolved does NOT override this/);
  }
});

// ── Healthy paths still behave ─────────────────────────────────────────────

test('a successful dry run still exits 0 and writes nothing', async () => {
  const { mod, writes } = loadMigration({});
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_OK);
  const r = mod._internals.report;
  assert.equal(r.auditComplete, true);
  assert.equal(r.operationalFailures.length, 0);
  assert.notEqual(r.blocked, true);
  assert.equal(writes.length, 0, 'a dry run never writes');
});

test('the unresolved-coach gate still returns 3 on a COMPLETE audit', async () => {
  // The fake data contains a legacy coach uid that is not in the reviewed set
  // and has no entitlement, so gate 3 must fire — and only because the audit
  // genuinely completed.
  const { mod, writes } = loadMigration({ argv: ['--apply'] });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_UNRESOLVED_COACHES);
  const r = mod._internals.report;
  assert.equal(r.auditComplete, true, 'gate 3 is only meaningful when complete');
  assert.ok(r.counts.legacyCoachesUnresolved >= 1);
  assert.equal(writes.length, 0, 'blocked apply writes nothing');
  assert.match(r.blockedReason, /REFUSING TO APPLY/);
});

test('--allow-unresolved DOES bypass the data gate on a complete audit',
  async () => {
    const { mod, writes } = loadMigration({
      argv: ['--apply', '--allow-unresolved'],
    });
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_OK);
    assert.equal(mod._internals.report.auditComplete, true);
    assert.ok(writes.length > 0, 'an allowed apply does perform its writes');
  });

test('the wrong-project gate still returns 2 and reads nothing', async () => {
  const savedProject = process.env.GCLOUD_PROJECT;
  try {
    // Every read is rigged to throw; the project gate must fire first, so the
    // result is 2 (not 4) and no read is ever attempted.
    const { mod, writes } = loadMigration({
      fail: 'coachAssignments', argv: ['--apply'],
    });
    process.env.GCLOUD_PROJECT = 'definitely-wrong-project';
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_PROJECT_BLOCKED);
    assert.equal(mod._internals.report.auditComplete, true,
      'the project gate fires before any read is attempted');
    assert.equal(writes.length, 0);
  } finally {
    if (savedProject === undefined) delete process.env.GCLOUD_PROJECT;
    else process.env.GCLOUD_PROJECT = savedProject;
  }
});

test('exit codes remain distinct and documented', () => {
  const { mod } = loadMigration({});
  assert.equal(mod.EXIT_OK, 0);
  assert.equal(mod.EXIT_UNEXPECTED_ERROR, 1);
  assert.equal(mod.EXIT_PROJECT_BLOCKED, 2);
  assert.equal(mod.EXIT_UNRESOLVED_COACHES, 3);
  assert.equal(mod.EXIT_INCOMPLETE_AUDIT, 4);
  // An operational failure and a data conflict must never share a code.
  assert.notEqual(mod.EXIT_INCOMPLETE_AUDIT, mod.EXIT_UNRESOLVED_COACHES);
});
