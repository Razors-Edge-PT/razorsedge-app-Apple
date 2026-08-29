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
function loadMigration(opts = {}) {
  const { fail, authError, argv } = opts;
  const boom = (what) => { throw new Error('injected failure: ' + what); };

  const writes = [];

  // Mutable store so a test can simulate a document appearing/changing
  // between preflight and mutation.
  const store = opts.store || {};

  const docApi = (collectionName, docId) => ({
    get: async () => {
      if (collectionName === 'accountEntitlements') {
        if (fail === 'entitlement') boom('entitlement read');
        return snap(store['accountEntitlements/' + docId] || null);
      }
      if (collectionName === 'coachAthleteLinks') {
        if (fail === 'link') boom('link read');
        return snap(store['coachAthleteLinks/' + docId] || null);
      }
      if (collectionName === 'users') {
        if (fail === 'userDoc') boom('users doc read');
        return snap({ email: 'x@y.z' });
      }
      return snap(null);
    },
    // SYNCHRONOUS on purpose: real Firestore tx.set() queues the write
    // synchronously, so an injected failure must throw synchronously too.
    set: (data, o) => {
      if (fail === 'writeFirestore') boom('firestore write');
      writes.push({ op: 'set', collectionName, docId, data, opts: o });
    },
    create: (data) => {
      if (fail === 'writeFirestore') boom('firestore write');
      if (store['coachAthleteLinks/' + docId] || opts.linkAppearsAtWrite) {
        const e = new Error('already exists');
        e.code = 6;
        throw e;
      }
      writes.push({ op: 'create', collectionName, docId, data });
    },
    update: (data) => {
      if (fail === 'writeFirestore') boom('firestore write');
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
      () => ({
        collection: collectionApi,
        runTransaction: async (fn) => fn({
          get: (ref) => ref.get(),
          set: (ref, data, o) => ref.set(data, o),
          update: (ref, data) => ref.update(data),
        }),
      }),
      { FieldValue: { serverTimestamp: () => 'TS', delete: () => 'DEL' } },
    ),
    auth: () => ({
      getUser: async (uid) => {
        if ((opts.missingUids || []).includes(uid)) {
          const e = new Error('no user record');
          e.code = 'auth/user-not-found';
          throw e;
        }
        if (fail === 'auth') {
          const e = new Error(authError || 'injected failure: auth lookup');
          e.code = authError || 'auth/internal-error';
          throw e;
        }
        const custom = (opts.existingClaims || {})[uid] || {};
        return { uid, customClaims: custom, displayName: 'N', email: 'e@x.y' };
      },
      setCustomUserClaims: async (uid, claims) => {
        if (fail === 'writeClaims') boom('claim write');
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

// ══════════════════════════════════════════════════════════════════════════
// Identity resolution belongs to the READ phase
// ══════════════════════════════════════════════════════════════════════════

test('Auth identity lookup failure during --apply WITHOUT --claims fails closed',
  async () => {
    // identityFor() used to run inside applyEntitlements()/applyRelationships(),
    // so this failure struck AFTER writes had begun. It is now a preflight read.
    const { mod, writes } = loadMigration({ fail: 'auth', argv: ['--apply'] });
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT);
    const r = mod._internals.report;
    assert.equal(r.auditComplete, false);
    assert.ok(r.operationalFailures.some((f) => f.kind === 'identity-auth-lookup-failed'),
      'the Auth identity read must be an operational failure');
    assert.equal(writes.length, 0, 'zero writes');
  });

test('users/{uid} identity read failure fails closed', async () => {
  const { mod, writes } = loadMigration({ fail: 'userDoc', argv: ['--apply'] });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT);
  const r = mod._internals.report;
  assert.equal(r.auditComplete, false);
  assert.ok(r.operationalFailures.some((f) => f.kind === 'identity-user-doc-read-failed'));
  assert.equal(writes.length, 0, 'zero writes');
});

test('both identity failures return 4 with zero writes, dry run and apply',
  async () => {
    for (const fail of ['auth', 'userDoc']) {
      for (const argv of [[], ['--apply'], ['--apply', '--claims']]) {
        const { mod, writes } = loadMigration({ fail, argv });
        const { code } = await runMain(mod);
        assert.equal(code, mod.EXIT_INCOMPLETE_AUDIT,
          'fail=' + fail + ' argv=' + JSON.stringify(argv));
        assert.equal(writes.length, 0);
      }
    }
  });

test('a DELETED reviewed coach gets no entitlement, profile or claim',
  async () => {
    const reviewed = require('../migrate_coach_mode').LEGACY_COACH_UIDS;
    const gone = reviewed[0];
    const { mod, writes } = loadMigration({
      missingUids: [gone], argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_OK, 'a stale uid must not block the run');
    const r = mod._internals.report;
    assert.equal(r.auditComplete, true, 'user-not-found is a DATA fact');
    assert.ok(r.problems.some(
      (p) => p.kind === 'reviewed-coach-account-missing' && p.uid === gone));
    assert.equal(r.counts.reviewedCoachesMissing, 1);

    for (const w of writes) {
      assert.notEqual(w.docId, gone,
        'no entitlement/profile may be written for a deleted account');
      assert.notEqual(w.uid, gone, 'no claim may be set for a deleted account');
    }
    assert.equal(r.applied.entitlements.includes(gone), false);
    assert.equal(r.applied.profiles.includes(gone), false);
    assert.equal(r.applied.claims.includes(gone), false);
  });

test('an approved link with a MISSING party produces no blank active link',
  async () => {
    // 'ath1' is the athlete in the fake athleteAssignments fixture.
    const { mod, writes } = loadMigration({
      missingUids: ['ath1'], argv: ['--apply', '--allow-unresolved'],
    });
    const { code } = await runMain(mod);

    assert.equal(code, mod.EXIT_OK);
    const r = mod._internals.report;
    assert.ok(r.problems.some((p) => p.kind === 'link-party-account-missing'),
      'the missing party must be reported');
    assert.equal(r.counts.linksSkippedMissingParty, 1);
    assert.equal(r.counts.linksCreated, 0);
    assert.equal(
      writes.some((w) => w.collectionName === 'coachAthleteLinks'), false,
      'no link document may be written');
  });

// ══════════════════════════════════════════════════════════════════════════
// Concurrent-change protection
// ══════════════════════════════════════════════════════════════════════════

test('a link appearing AFTER preflight is never overwritten', async () => {
  const { mod, writes } = loadMigration({
    linkAppearsAtWrite: true, argv: ['--apply', '--allow-unresolved'],
  });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_APPLY_FAILED,
    'a collision is an apply failure requiring a rerun');
  const r = mod._internals.report;
  assert.ok(r.applyFailures.some((f) => f.kind === 'link-create-conflict'));
  assert.match(r.blockedReason, /RERUN/);
  assert.equal(
    writes.some((w) => w.collectionName === 'coachAthleteLinks'), false,
    'create() must refuse rather than overwrite');
});

test('an entitlement suspended AFTER preflight is never reactivated', async () => {
  const reviewed = require('../migrate_coach_mode').LEGACY_COACH_UIDS;
  const target = reviewed[0];
  // Preflight sees nothing; the transaction then finds a suspended doc.
  const store = {};
  let reads = 0;
  const trap = {
    get [('accountEntitlements/' + target)]() {
      reads += 1;
      // First read (preflight) → absent. Later reads (transaction) → suspended.
      return reads > 1 ? { coach: { state: 'suspended' } } : null;
    },
  };
  Object.defineProperty(store, 'accountEntitlements/' + target, {
    enumerable: true,
    get: Object.getOwnPropertyDescriptor(trap, 'accountEntitlements/' + target).get,
  });

  const { mod, writes } = loadMigration({
    store, argv: ['--apply', '--allow-unresolved'],
  });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_APPLY_FAILED);
  const r = mod._internals.report;
  assert.ok(r.applyFailures.some(
    (f) => f.kind === 'entitlement-state-conflict' && f.state === 'suspended'),
  'the suspension must be detected inside the transaction');
  assert.equal(
    writes.some((w) => w.docId === target && w.collectionName === 'accountEntitlements'),
    false, 'a suspended entitlement must never be resurrected');
});

test('entitlement and profile are written in ONE transaction', async () => {
  const { mod, writes } = loadMigration({
    argv: ['--apply', '--allow-unresolved'],
  });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_OK);
  const r = mod._internals.report;
  // Every applied entitlement has a matching profile and vice versa.
  assert.deepEqual(r.applied.entitlements.slice().sort(),
    r.applied.profiles.slice().sort(),
    'entitlement and profile land together or not at all');
  assert.ok(r.applied.entitlements.length > 0);
});

// ══════════════════════════════════════════════════════════════════════════
// Write failures are reported honestly
// ══════════════════════════════════════════════════════════════════════════

test('a Firestore write failure returns the apply-failure code', async () => {
  const { mod } = loadMigration({
    fail: 'writeFirestore', argv: ['--apply', '--allow-unresolved'],
  });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_APPLY_FAILED);
  const r = mod._internals.report;
  assert.ok(r.applyFailures.length > 0);
  assert.equal(r.blocked, true);
  // EVERY Firestore write failed, so nothing landed. The report must say so
  // honestly rather than warning about partial writes that do not exist.
  assert.equal(r.writesPerformed, 0);
  assert.equal(r.mutationStarted, true);
  assert.match(r.blockedReason, /APPLY FAILED/);
  assert.match(r.blockedReason, /NO writes landed/);
  assert.match(r.blockedReason, /RERUN/);
});

test('a claim write failure returns the apply-failure code', async () => {
  const { mod } = loadMigration({
    fail: 'writeClaims', argv: ['--apply', '--claims', '--allow-unresolved'],
  });
  const { code } = await runMain(mod);

  assert.equal(code, mod.EXIT_APPLY_FAILED);
  const r = mod._internals.report;
  assert.ok(r.applyFailures.some((f) => f.kind === 'claim-write-failed'));
  // Firestore writes DID land — the report must say so rather than pretend
  // the run was atomic.
  assert.ok(r.applied.entitlements.length > 0,
    'earlier successful writes are reported honestly');
});

test('partial writes are reported honestly and a rerun completes safely',
  async () => {
    const reviewed = require('../migrate_coach_mode').LEGACY_COACH_UIDS;

    // Run 1: claim writes fail; Firestore writes succeed.
    const first = loadMigration({
      fail: 'writeClaims', argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    const r1 = await runMain(first.mod);
    assert.equal(r1.code, first.mod.EXIT_APPLY_FAILED);
    const rep1 = first.mod._internals.report;
    assert.ok(rep1.applied.entitlements.length > 0);
    assert.equal(rep1.applied.claims.length, 0);

    // Run 2: the underlying cause is fixed. The preflight sees the entitlements
    // that already landed and skips them; the run completes cleanly.
    const store = {};
    for (const uid of rep1.applied.entitlements) {
      store['accountEntitlements/' + uid] = { coach: { state: 'active' } };
    }
    const second = loadMigration({
      store, argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    const r2 = await runMain(second.mod);

    assert.equal(r2.code, second.mod.EXIT_OK, 'the rerun completes');
    const rep2 = second.mod._internals.report;
    assert.equal(rep2.applyFailures.length, 0);
    assert.ok(rep2.counts.entitlementsAlreadyActive >= reviewed.length - 1,
      'already-applied entitlements are skipped, not rewritten');
    assert.ok(rep2.applied.claims.length > 0, 'the outstanding claims now land');
  });

test('the full exit-code contract is intact', async () => {
  const { mod } = loadMigration({});
  assert.equal(mod.EXIT_OK, 0);
  assert.equal(mod.EXIT_UNEXPECTED_ERROR, 1);
  assert.equal(mod.EXIT_PROJECT_BLOCKED, 2);
  assert.equal(mod.EXIT_UNRESOLVED_COACHES, 3);
  assert.equal(mod.EXIT_INCOMPLETE_AUDIT, 4);
  assert.equal(mod.EXIT_APPLY_FAILED, 5);
  const codes = [mod.EXIT_OK, mod.EXIT_UNEXPECTED_ERROR, mod.EXIT_PROJECT_BLOCKED,
    mod.EXIT_UNRESOLVED_COACHES, mod.EXIT_INCOMPLETE_AUDIT, mod.EXIT_APPLY_FAILED];
  assert.equal(new Set(codes).size, codes.length, 'every code is distinct');
});

test('an unexpected exception still surfaces as exit 1', () => {
  // main() propagates; the single wrapper maps a thrown error to
  // EXIT_UNEXPECTED_ERROR. Asserted on the executable source so a future
  // refactor cannot silently swallow it.
  const fs = require('node:fs');
  const code = fs.readFileSync(
    require.resolve('../migrate_coach_mode'), 'utf8')
    .split('\n')
    .filter((l) => !l.trim().startsWith('//'))
    .join('\n');
  assert.match(code, /\.catch\(\(err\) => \{/);
  assert.match(code, /process\.exit\(EXIT_UNEXPECTED_ERROR\)/);
  assert.equal(code.includes('process.exit(1)'), false,
    'the wrapper must use the named constant, not a bare 1');
});

test('reviewed coach set reflects Richard review', () => {
  const mig = require('../migrate_coach_mode');
  // Adam primary + secondary present; deleted account gone; Aja never present.
  assert.ok(mig.LEGACY_COACH_UIDS.includes('ejBDKEZPFfQz2Sdzd7BZlNydxZ33'),
    'Adam primary coach account');
  assert.ok(mig.LEGACY_COACH_UIDS.includes('LGxzlyBNh5f1zclM1F0l6tl6Py82'),
    'Adam secondary coach account');
  assert.ok(mig.LEGACY_COACH_UIDS.includes('ykx0RvDMc5OIuZ2R4kqWMhGbrGV2'),
    'Google Play reviewer must retain Coach Mode');
  assert.equal(mig.LEGACY_COACH_UIDS.includes('SMTEVGPH1MXgOgbcBbJFU1HjU8G3'),
    false, 'the deleted account must be gone');
  assert.equal(mig.LEGACY_COACH_UIDS.includes('tlmT17Jlgfe63OYfk8P2IPAs4072'),
    false, 'Aja is not a coach');

  // Free-membership mirror: deleted account gone, Play reviewer kept.
  assert.equal(mig.LEGACY_FREE_MEMBERSHIP_UIDS.includes('SMTEVGPH1MXgOgbcBbJFU1HjU8G3'),
    false);
  assert.ok(mig.LEGACY_FREE_MEMBERSHIP_UIDS.includes('ykx0RvDMc5OIuZ2R4kqWMhGbrGV2'));
  // The secondary coach account is NOT given a permanent comp membership.
  assert.equal(mig.LEGACY_FREE_MEMBERSHIP_UIDS.includes('LGxzlyBNh5f1zclM1F0l6tl6Py82'),
    false, 'a new coach must need no permanent allowlist entry');
});

// ══════════════════════════════════════════════════════════════════════════
// DEFECT 1 — the human-readable report must match what actually happened
// ══════════════════════════════════════════════════════════════════════════
//
// emitReport() printed "*** BLOCKED - NO WRITES PERFORMED ***" for ANY
// blocked run. Gate 4 also sets blocked after mutation failures, when earlier
// writes may genuinely have landed — so the banner flatly contradicted the
// paragraph beneath it. These assert the RENDERED output, not just the JSON.

/** Runs main() and returns the rendered human report. */
async function renderHuman(mod) {
  const { stdout } = await runMain(mod);
  return stdout;
}

test('human output: incomplete preflight says NO WRITES PERFORMED', async () => {
  const { mod, writes } = loadMigration({
    fail: 'coachAssignments', argv: ['--apply'],
  });
  const out = await renderHuman(mod);

  assert.match(out, /BLOCKED - NO WRITES PERFORMED/);
  assert.doesNotMatch(out, /PARTIAL WRITES MAY HAVE LANDED/);
  assert.equal(writes.length, 0);
  assert.equal(mod._internals.report.mutationStarted, false,
    'a preflight blocker fires before mutation begins');
  assert.equal(mod._internals.report.writesPerformed, 0);
});

test('human output: unresolved-coach blocker says NO WRITES PERFORMED', async () => {
  const { mod, writes } = loadMigration({ argv: ['--apply'] });
  const out = await renderHuman(mod);

  assert.match(out, /BLOCKED - NO WRITES PERFORMED/);
  assert.doesNotMatch(out, /PARTIAL WRITES MAY HAVE LANDED/);
  assert.match(out, /REFUSING TO APPLY/);
  assert.equal(writes.length, 0);
  assert.equal(mod._internals.report.mutationStarted, false);
});

test('human output: apply failure AFTER a successful write never claims zero',
  async () => {
    // Firestore writes succeed; the claim write fails. So writes DID land.
    const { mod } = loadMigration({
      fail: 'writeClaims', argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    const out = await renderHuman(mod);
    const r = mod._internals.report;

    assert.ok(r.writesPerformed > 0, 'precondition: some writes landed');
    assert.equal(r.mutationStarted, true);

    assert.doesNotMatch(out, /NO WRITES PERFORMED/,
      'the banner must never claim zero writes once some have landed');
    assert.match(out, /APPLY INCOMPLETE - PARTIAL WRITES MAY HAVE LANDED/);
    assert.match(out, /RERUN REQUIRED/);
    // The counts are shown.
    assert.match(out, /writes landed: \d+/);
    assert.match(out, /writes failed: \d+/);
  });

test('human output: apply failure BEFORE any write says none landed, not preflight',
  async () => {
    // EVERY Firestore write fails, so nothing lands at all.
    const { mod } = loadMigration({
      fail: 'writeFirestore', argv: ['--apply', '--allow-unresolved'],
    });
    const out = await renderHuman(mod);
    const r = mod._internals.report;

    assert.equal(r.writesPerformed, 0);
    assert.equal(r.mutationStarted, true, 'mutation DID begin');

    assert.match(out, /APPLY FAILED - NO WRITES LANDED \(preflight was OK\)/);
    assert.doesNotMatch(out, /PARTIAL WRITES MAY HAVE LANDED/);
    // Must not be mistaken for a preflight blocker.
    assert.doesNotMatch(out, /BLOCKED - NO WRITES PERFORMED/);
    assert.doesNotMatch(out, /INCOMPLETE AUDIT/);
    assert.equal(r.auditComplete, true, 'the preflight genuinely succeeded');
  });

test('JSON and human reports represent the same state', async () => {
  for (const opts of [
    { fail: 'coachAssignments', argv: ['--apply'] },
    { argv: ['--apply'] },
    { fail: 'writeClaims', argv: ['--apply', '--claims', '--allow-unresolved'] },
    { fail: 'writeFirestore', argv: ['--apply', '--allow-unresolved'] },
  ]) {
    const { mod } = loadMigration(opts);
    const out = await renderHuman(mod);
    const r = mod._internals.report;

    // The banner shown must agree with the machine fields.
    const saysNoWrites = /NO WRITES PERFORMED/.test(out);
    const saysPartial = /PARTIAL WRITES MAY HAVE LANDED/.test(out);
    assert.equal(saysNoWrites, !r.mutationStarted,
      'NO WRITES PERFORMED iff mutation never began');
    assert.equal(saysPartial, r.mutationStarted && r.writesPerformed > 0,
      'PARTIAL only when mutation began and something landed');
    assert.equal(r.writesPerformed,
      r.applied.entitlements.length + r.applied.profiles.length
      + r.applied.claims.length + r.applied.links.length,
      'writesPerformed must equal what applied[] records');
  }
});

// ══════════════════════════════════════════════════════════════════════════
// DEFECT 2 — the mirrored claim must follow the entitlement
// ══════════════════════════════════════════════════════════════════════════

const REVIEWED = require('../migrate_coach_mode').LEGACY_COACH_UIDS;
const TARGET = REVIEWED[0];

/** Store fixture: one reviewed uid holds the given entitlement state. */
function entStore(uid, state) {
  const store = {};
  if (state) store['accountEntitlements/' + uid] = { coach: { state } };
  return store;
}

test('suspended entitlement + no claim: no coach claim is granted', async () => {
  const { mod, writes } = loadMigration({
    store: entStore(TARGET, 'suspended'),
    argv: ['--apply', '--claims', '--allow-unresolved'],
  });
  await runMain(mod);
  const r = mod._internals.report;

  assert.ok(r.problems.some(
    (p) => p.kind === 'entitlement-conflict' && p.uid === TARGET));
  assert.equal(r.applied.claims.includes(TARGET), false,
    'a suspended coach must never receive isCoach');
  assert.equal(
    writes.some((w) => w.op === 'setCustomUserClaims' && w.uid === TARGET),
    false);
});

test('suspended entitlement + stale isCoach: ONLY that claim is removed',
  async () => {
    const { mod, writes } = loadMigration({
      store: entStore(TARGET, 'suspended'),
      existingClaims: {
        [TARGET]: { isCoach: true, stripeRole: 'premium', tier: 3 },
      },
      argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    await runMain(mod);
    const r = mod._internals.report;

    assert.equal(r.counts.claimsRevoked, 1);
    const w = writes.find(
      (x) => x.op === 'setCustomUserClaims' && x.uid === TARGET);
    assert.ok(w, 'the stale claim must be corrected');
    assert.equal(w.claims.isCoach, undefined, 'isCoach removed');
    assert.equal(w.claims.stripeRole, 'premium', 'unrelated claim preserved');
    assert.equal(w.claims.tier, 3, 'unrelated claim preserved');
  });

test('revoked entitlement behaves identically', async () => {
  const { mod, writes } = loadMigration({
    store: entStore(TARGET, 'revoked'),
    existingClaims: { [TARGET]: { isCoach: true, stripeRole: 'premium' } },
    argv: ['--apply', '--claims', '--allow-unresolved'],
  });
  await runMain(mod);

  const w = writes.find((x) => x.op === 'setCustomUserClaims' && x.uid === TARGET);
  assert.ok(w);
  assert.equal(w.claims.isCoach, undefined);
  assert.equal(w.claims.stripeRole, 'premium');
  assert.equal(mod._internals.report.applied.claims.includes(TARGET), true,
    'the corrective removal is itself a successful write');
});

test('entitlement/profile transaction failure prevents that coach claim',
  async () => {
    const { mod, writes } = loadMigration({
      fail: 'writeFirestore',
      argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    await runMain(mod);
    const r = mod._internals.report;

    assert.equal(r.applied.entitlements.length, 0, 'no entitlement landed');
    assert.equal(
      writes.some((w) => w.op === 'setCustomUserClaims'), false,
      'no coach claim may be granted when its entitlement failed');
    assert.ok(r.actions.some(
      (a) => a.kind === 'claim-skipped-entitlement-not-activated'));
  });

test('concurrent suspension during entitlement mutation prevents the claim',
  async () => {
    // Preflight sees no entitlement; the transaction then finds it suspended.
    let reads = 0;
    const store = {};
    Object.defineProperty(store, 'accountEntitlements/' + TARGET, {
      enumerable: true,
      get() {
        reads += 1;
        return reads > 1 ? { coach: { state: 'suspended' } } : null;
      },
    });

    const { mod, writes } = loadMigration({
      store, argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    const { code } = await runMain(mod);
    const r = mod._internals.report;

    assert.equal(code, mod.EXIT_APPLY_FAILED);
    assert.ok(r.applyFailures.some(
      (f) => f.kind === 'entitlement-state-conflict' && f.uid === TARGET));
    assert.equal(r.applied.entitlements.includes(TARGET), false);
    assert.equal(
      writes.some((w) => w.op === 'setCustomUserClaims' && w.uid === TARGET),
      false, 'a concurrently suspended account must not receive isCoach');
  });

test('an ALREADY-ACTIVE entitlement receives the mirrored claim', async () => {
  const { mod, writes } = loadMigration({
    store: entStore(TARGET, 'active'),
    argv: ['--apply', '--claims', '--allow-unresolved'],
  });
  await runMain(mod);
  const r = mod._internals.report;

  assert.ok(mod._internals.entitlementDisposition.alreadyActive.has(TARGET));
  const w = writes.find((x) => x.op === 'setCustomUserClaims' && x.uid === TARGET);
  assert.ok(w, 'an active coach gets the routing hint');
  assert.equal(w.claims.isCoach, true);
  assert.equal(r.applied.claims.includes(TARGET), true);
});

test('a SUCCESSFULLY CREATED entitlement receives the mirrored claim',
  async () => {
    const { mod, writes } = loadMigration({
      argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    await runMain(mod);
    const r = mod._internals.report;

    assert.ok(r.applied.entitlements.length > 0);
    for (const uid of r.applied.entitlements) {
      const w = writes.find(
        (x) => x.op === 'setCustomUserClaims' && x.uid === uid);
      assert.ok(w, 'newly activated coach ' + uid + ' must get the claim');
      assert.equal(w.claims.isCoach, true);
    }
  });

test('a concurrent suspension between preflight and the CLAIM write is caught',
  async () => {
    // Entitlement is active at preflight, so the claim is planned. It then
    // becomes suspended before applyClaims revalidates.
    let reads = 0;
    const store = {};
    Object.defineProperty(store, 'accountEntitlements/' + TARGET, {
      enumerable: true,
      get() {
        reads += 1;
        // Preflight + entitlement planning see active; the claim
        // revalidation (a later read) sees suspended.
        return reads > 1
          ? { coach: { state: 'suspended' } }
          : { coach: { state: 'active' } };
      },
    });

    const { mod, writes } = loadMigration({
      store, argv: ['--apply', '--claims', '--allow-unresolved'],
    });
    const { code } = await runMain(mod);
    const r = mod._internals.report;

    assert.equal(code, mod.EXIT_APPLY_FAILED,
      'a failed revalidation after mutation began is an APPLY failure');
    assert.notEqual(code, mod.EXIT_INCOMPLETE_AUDIT,
      'it must NOT be reported as an incomplete preflight');
    assert.ok(r.applyFailures.some((f) => f.kind === 'claim-entitlement-conflict'));
    assert.equal(
      writes.some((w) => w.op === 'setCustomUserClaims' && w.uid === TARGET),
      false, 'the claim must not contradict the suspension');
  });

test('a claim write failure still returns exit 5 and is rerunnable', async () => {
  const { mod } = loadMigration({
    fail: 'writeClaims', argv: ['--apply', '--claims', '--allow-unresolved'],
  });
  const { code } = await runMain(mod);
  const r = mod._internals.report;

  assert.equal(code, mod.EXIT_APPLY_FAILED);
  assert.ok(r.applyFailures.some((f) => f.kind === 'claim-write-failed'));
  assert.match(r.blockedReason, /RERUN/);

  // Rerun with the cause fixed and the entitlements already in place: the
  // outstanding claims land and the run completes.
  const store = {};
  for (const uid of r.applied.entitlements) {
    store['accountEntitlements/' + uid] = { coach: { state: 'active' } };
  }
  const second = loadMigration({
    store, argv: ['--apply', '--claims', '--allow-unresolved'],
  });
  const r2 = await runMain(second.mod);
  assert.equal(r2.code, second.mod.EXIT_OK, 'the rerun completes');
  assert.ok(second.mod._internals.report.applied.claims.length > 0);
});

test('account decisions are unchanged by this pass', () => {
  const mig = require('../migrate_coach_mode');
  assert.ok(mig.LEGACY_COACH_UIDS.includes('ejBDKEZPFfQz2Sdzd7BZlNydxZ33'),
    'Adam primary is a coach');
  assert.ok(mig.LEGACY_COACH_UIDS.includes('LGxzlyBNh5f1zclM1F0l6tl6Py82'),
    'Adam secondary is a coach through the migration entitlement');
  assert.ok(mig.LEGACY_COACH_UIDS.includes('ykx0RvDMc5OIuZ2R4kqWMhGbrGV2'),
    'Play reviewer keeps Coach Mode');
  assert.equal(mig.LEGACY_COACH_UIDS.includes('tlmT17Jlgfe63OYfk8P2IPAs4072'),
    false, 'Aja is not a coach');
  assert.equal(mig.LEGACY_COACH_UIDS.includes('SMTEVGPH1MXgOgbcBbJFU1HjU8G3'),
    false, 'the deleted account is not a coach');
  // Adam secondary must NOT be on the permanent comp-membership mirror.
  assert.equal(
    mig.LEGACY_FREE_MEMBERSHIP_UIDS.includes('LGxzlyBNh5f1zclM1F0l6tl6Py82'),
    false, 'a coach must need no permanent allowlist entry');
});
