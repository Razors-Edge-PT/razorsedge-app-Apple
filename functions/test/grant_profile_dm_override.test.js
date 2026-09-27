'use strict';

// scripts/grant_profile_dm_override.js against an in-memory Admin SDK:
// allow-list, dry run, backup-before-write, merge (never replace), idempotency,
// claims never touched, and verify's refusal when anyone else holds the flag.

const test = require('node:test');
const assert = require('node:assert/strict');

const S = require('../scripts/grant_profile_dm_override');

function fakeAdmin({ docs = {}, claims = { isCoach: true } } = {}) {
  const store = new Map(Object.entries(docs));
  const writes = [];
  const claimWrites = [];
  const docRef = (p) => ({
    async get() {
      const d = store.get(p);
      return { exists: d !== undefined, data: () => d, get: (k) => (d || {})[k] };
    },
    async set(data, opts) {
      writes.push({ p, data, opts });
      const prev = opts && opts.merge ? store.get(p) || {} : {};
      const next = { ...prev };
      for (const [k, v] of Object.entries(data)) next[k] = typeof v === 'object' && v && v.__ts ? 'TS' : v;
      store.set(p, next);
    },
  });
  const firestore = () => ({
    collection: (c) => ({
      doc: (id) => docRef(`${c}/${id}`),
      where: (field, op, value) => ({
        async get() {
          const out = [];
          for (const [p, d] of store) {
            if (p.startsWith(`${c}/`) && d[field] === value) out.push({ id: p.slice(c.length + 1) });
          }
          return { docs: out };
        },
      }),
    }),
  });
  firestore.FieldValue = { serverTimestamp: () => ({ __ts: true }) };
  return {
    store, writes, claimWrites,
    firestore,
    auth: () => ({
      getUser: async (uid) => ({ uid, email: 'r@example.com', customClaims: claims }),
      setCustomUserClaims: async (...a) => claimWrites.push(a),
    }),
  };
}

const quiet = () => {};

test('the allow-list is exactly Richard; the test account is named only to be refused', () => {
  assert.equal(S.ALLOWED_UID, 'yoVAqScwLMQLAgNHh8v9IK49fBw2');
  assert.equal(S.TEST_ACCOUNT_UID, 'jhIB7Yi1whYwPvBSmK27KltJGn23');
  assert.notEqual(S.ALLOWED_UID, S.TEST_ACCOUNT_UID);
});

test('arguments: dry run by default; apply and verify are exclusive; nothing else accepted', () => {
  assert.deepEqual(S.parseArgs([]), { apply: false, verify: false });
  assert.throws(() => S.parseArgs(['--apply', '--verify']));
  assert.throws(() => S.parseArgs(['--uid', 'someone']));
});

test('dry run writes nothing', async () => {
  const admin = fakeAdmin();
  const r = await S.run({ apply: false, verify: false }, { admin, log: quiet });
  assert.equal(r.dryRun, true);
  assert.equal(admin.writes.length, 0);
});

test('apply merges the flag, keeps every other field, backs up, and never touches claims', async () => {
  const admin = fakeAdmin({
    docs: { [`accessGrants/${S.ALLOWED_UID}`]: { note: 'keep me' } },
  });
  const r = await S.run({ apply: true, verify: false }, { admin, log: quiet });
  assert.equal(r.changed, true);
  assert.ok(r.backup && require('fs').existsSync(r.backup));
  const backup = JSON.parse(require('fs').readFileSync(r.backup, 'utf8'));
  assert.deepEqual(backup.grantDocument, { note: 'keep me' });
  assert.deepEqual(backup.customClaims, { isCoach: true });
  require('fs').unlinkSync(r.backup);
  assert.equal(admin.writes.length, 1);
  assert.equal(admin.writes[0].p, `accessGrants/${S.ALLOWED_UID}`);
  assert.deepEqual(admin.writes[0].opts, { merge: true });
  const after = admin.store.get(`accessGrants/${S.ALLOWED_UID}`);
  assert.equal(after.note, 'keep me');
  assert.equal(after.profileAndDmOverride, true);
  assert.equal(admin.claimWrites.length, 0);
});

test('apply is idempotent', async () => {
  const admin = fakeAdmin({
    docs: { [`accessGrants/${S.ALLOWED_UID}`]: { profileAndDmOverride: true } },
  });
  const r = await S.run({ apply: true, verify: false }, { admin, log: quiet });
  assert.equal(r.changed, false);
  assert.equal(admin.writes.length, 0);
});

test('verify passes only when Richard alone holds the flag', async () => {
  const ok = fakeAdmin({ docs: { [`accessGrants/${S.ALLOWED_UID}`]: { profileAndDmOverride: true } } });
  assert.deepEqual((await S.run({ verify: true }, { admin: ok, log: quiet })).holders, [S.ALLOWED_UID]);

  const missing = fakeAdmin();
  await assert.rejects(S.run({ verify: true }, { admin: missing, log: quiet }), /VERIFY FAILED/);

  const testHolds = fakeAdmin({
    docs: {
      [`accessGrants/${S.ALLOWED_UID}`]: { profileAndDmOverride: true },
      [`accessGrants/${S.TEST_ACCOUNT_UID}`]: { profileAndDmOverride: true },
    },
  });
  await assert.rejects(S.run({ verify: true }, { admin: testHolds, log: quiet }), /VERIFY FAILED/);

  const other = fakeAdmin({
    docs: {
      [`accessGrants/${S.ALLOWED_UID}`]: { profileAndDmOverride: true },
      'accessGrants/someoneElse': { profileAndDmOverride: true },
    },
  });
  await assert.rejects(S.run({ verify: true }, { admin: other, log: quiet }), /VERIFY FAILED/);
});
