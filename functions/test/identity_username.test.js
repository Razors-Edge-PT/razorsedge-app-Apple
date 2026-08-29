'use strict';

const test = require('node:test');
const assert = require('node:assert');

const {
  normalizeUsername,
  displayUsername,
  validateUsername,
  usernameIndexKey,
  indexKeyForRaw,
} = require('../identity/username_rules');
const { Decision, planUsernameChange } = require('../identity/reservation');

// ── Normalisation ───────────────────────────────────────────────────────────

test('normalisation trims, NFKC-folds and lowercases', () => {
  assert.strictEqual(normalizeUsername('  RichArd  '), 'richard');
  assert.strictEqual(normalizeUsername('BENCHKING'), 'benchking');
  assert.strictEqual(normalizeUsername(null), '');
  assert.strictEqual(normalizeUsername(42), '');
});

test('normalisation is backward compatible with the old toLowerCase() writes', () => {
  for (const name of ['Richard', 'lift_er', 'a-b-c', 'Zoe99', 'MAX']) {
    assert.strictEqual(normalizeUsername(name), name.toLowerCase());
  }
});

test('the display form keeps casing but drops surrounding whitespace', () => {
  assert.strictEqual(displayUsername('  RichArd '), 'RichArd');
});

test('validation enforces 3-22 characters and no whitespace', () => {
  assert.strictEqual(validateUsername('abc').ok, true);
  assert.strictEqual(validateUsername('a'.repeat(22)).ok, true);
  assert.strictEqual(validateUsername('ab').ok, false);
  assert.strictEqual(validateUsername('a'.repeat(23)).ok, false);
  assert.strictEqual(validateUsername('has space').ok, false);
  assert.strictEqual(validateUsername('   ').ok, false);
  assert.strictEqual(validateUsername('').code, 'empty');
});

test('validation rejects control characters', () => {
  const res = validateUsername(`ab${String.fromCharCode(9)}cd`);
  assert.strictEqual(res.ok, false);
});

// ── Index key safety ────────────────────────────────────────────────────────

test('the index key is a fixed-length hex hash, so unsafe names are path-safe', () => {
  for (const name of ['a/b', '..', '.', 'x'.repeat(200), 'ünïcødé', '__proto__']) {
    const key = usernameIndexKey(normalizeUsername(name));
    assert.strictEqual(key.length, 64);
    assert.match(key, /^[0-9a-f]{64}$/);
  }
});

test('the index key is case-insensitive but distinguishes different names', () => {
  assert.strictEqual(indexKeyForRaw('Richard'), indexKeyForRaw('RICHARD'));
  assert.strictEqual(indexKeyForRaw(' richard '), indexKeyForRaw('Richard'));
  assert.notStrictEqual(indexKeyForRaw('richard'), indexKeyForRaw('richardo'));
});

// ── Reservation decisions ───────────────────────────────────────────────────

const A = 'uidA';
const B = 'uidB';

test('a free name is claimed and the old reservation released', () => {
  const plan = planUsernameChange({
    callerUid: A,
    requested: 'NewName',
    currentLower: 'oldname',
    existingReservation: null,
    oldReservation: { uid: A, usernameLower: 'oldname' },
  });
  assert.strictEqual(plan.decision, Decision.CLAIM);
  assert.strictEqual(plan.username, 'NewName');
  assert.strictEqual(plan.usernameLower, 'newname');
  assert.strictEqual(plan.releaseOld, true);
});

test('a name held by someone else is refused, case-insensitively', () => {
  const plan = planUsernameChange({
    callerUid: A,
    requested: 'RICHARD',
    currentLower: 'oldname',
    existingReservation: { uid: B, usernameLower: 'richard' },
    oldReservation: null,
  });
  assert.strictEqual(plan.decision, Decision.TAKEN);
});

test('re-claiming your own name is a no-op', () => {
  const plan = planUsernameChange({
    callerUid: A,
    requested: 'Richard',
    currentLower: 'richard',
    existingReservation: { uid: A, usernameLower: 'richard', username: 'Richard' },
    oldReservation: null,
  });
  assert.strictEqual(plan.decision, Decision.NOOP);
});

test('changing only the CASING of your own name still writes the display form', () => {
  const plan = planUsernameChange({
    callerUid: A,
    requested: 'RICHARD',
    currentLower: 'richard',
    existingReservation: { uid: A, usernameLower: 'richard', username: 'Richard' },
    oldReservation: null,
  });
  assert.strictEqual(plan.decision, Decision.CLAIM);
  assert.strictEqual(plan.username, 'RICHARD');
  // Same index key, so nothing is released.
  assert.strictEqual(plan.releaseOld, false);
});

test('a reservation belonging to another account is never released', () => {
  const plan = planUsernameChange({
    callerUid: A,
    requested: 'NewName',
    currentLower: 'oldname',
    // Somehow the old key is held by B. We must not delete B's reservation.
    oldReservation: { uid: B, usernameLower: 'oldname' },
    existingReservation: null,
  });
  assert.strictEqual(plan.decision, Decision.CLAIM);
  assert.strictEqual(plan.releaseOld, false);
});

test('a CONTESTED marker blocks the name for everyone, including the holders', () => {
  // The backfill writes { contested: true } with NO uid for a name several
  // legacy accounts already display. It declares no winner, and it must stop a
  // brand-new signup taking a name four existing profiles show.
  const contested = { usernameLower: 'tata', contested: true, contestedUids: [A, B] };
  for (const uid of [A, B, 'brandNewUser']) {
    const plan = planUsernameChange({
      callerUid: uid,
      requested: 'tata',
      currentLower: null,
      existingReservation: contested,
      oldReservation: null,
    });
    assert.strictEqual(plan.decision, Decision.TAKEN, uid);
  }
});

test('a contested marker is never released when a holder renames away', () => {
  const plan = planUsernameChange({
    callerUid: A,
    requested: 'SomethingElse',
    currentLower: 'tata',
    existingReservation: null,
    // Their old key is the contested marker, which belongs to nobody.
    oldReservation: { usernameLower: 'tata', contested: true },
  });
  assert.strictEqual(plan.decision, Decision.CLAIM);
  assert.strictEqual(plan.releaseOld, false,
    'freeing a contested name would let a stranger take it');
});

test('an invalid name never reaches the index', () => {
  const plan = planUsernameChange({
    callerUid: A,
    requested: 'no',
    currentLower: null,
    existingReservation: null,
    oldReservation: null,
  });
  assert.strictEqual(plan.decision, Decision.INVALID);
  assert.strictEqual(plan.code, 'invalid-format');
});

test('a user with no stored username can claim a first name', () => {
  const plan = planUsernameChange({
    callerUid: A,
    requested: 'FirstOne',
    currentLower: null,
    existingReservation: null,
    oldReservation: null,
  });
  assert.strictEqual(plan.decision, Decision.CLAIM);
  assert.strictEqual(plan.releaseOld, false);
});

// ── Concurrency ─────────────────────────────────────────────────────────────

/**
 * Models Firestore's optimistic transaction contract: a transaction commits
 * only if every document it READ is unchanged at commit time, otherwise it is
 * retried against fresh data. This proves the ALGORITHM — a single-document
 * existence check inside a transaction — cannot let two accounts hold one
 * name, which is exactly what the old "query then write" could not promise.
 */
function transactionalStore() {
  const docs = new Map(); // key -> { data, version }
  return {
    docs,
    async runTransaction(fn, { maxAttempts = 5 } = {}) {
      for (let attempt = 0; attempt < maxAttempts; attempt++) {
        const readVersions = new Map();
        const writes = [];
        const tx = {
          get(key) {
            const entry = docs.get(key);
            readVersions.set(key, entry ? entry.version : null);
            return entry ? entry.data : null;
          },
          set(key, data) {
            writes.push({ key, data });
          },
          delete(key) {
            writes.push({ key, data: null });
          },
        };
        const result = await fn(tx);
        // Commit check: every read must still be at the version we saw.
        let stale = false;
        for (const [key, version] of readVersions) {
          const entry = docs.get(key);
          const now = entry ? entry.version : null;
          if (now !== version) {
            stale = true;
            break;
          }
        }
        if (stale) continue;
        for (const w of writes) {
          if (w.data === null) docs.delete(w.key);
          else {
            const prev = docs.get(w.key);
            docs.set(w.key, { data: w.data, version: (prev ? prev.version : 0) + 1 });
          }
        }
        return result;
      }
      throw new Error('transaction: too many retries');
    },
  };
}

function claimAttempt(store, uid, requested) {
  return store.runTransaction(async (tx) => {
    const key = indexKeyForRaw(requested);
    const existing = tx.get(key);
    const plan = planUsernameChange({
      callerUid: uid,
      requested,
      currentLower: null,
      existingReservation: existing,
      oldReservation: null,
    });
    if (plan.decision !== Decision.CLAIM) return plan.decision;
    tx.set(key, { uid, username: plan.username, usernameLower: plan.usernameLower });
    return Decision.CLAIM;
  });
}

test('two accounts racing for one name: exactly one wins', async () => {
  const store = transactionalStore();
  // Interleave the two transactions by starting both before either commits.
  const [a, b] = await Promise.all([
    claimAttempt(store, A, 'SharedName'),
    claimAttempt(store, B, 'sharedname'),
  ]);
  const outcomes = [a, b].sort();
  assert.deepStrictEqual(outcomes, [Decision.CLAIM, Decision.TAKEN]);
  assert.strictEqual(store.docs.size, 1);
});

test('a race between different-cased spellings collides on one index key', async () => {
  const store = transactionalStore();
  const results = await Promise.all([
    claimAttempt(store, A, 'BenchKing'),
    claimAttempt(store, B, 'BENCHKING'),
    claimAttempt(store, 'uidC', 'benchking'),
  ]);
  assert.strictEqual(results.filter((r) => r === Decision.CLAIM).length, 1);
  assert.strictEqual(results.filter((r) => r === Decision.TAKEN).length, 2);
  assert.strictEqual(store.docs.size, 1);
});
