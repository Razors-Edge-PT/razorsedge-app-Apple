// The remove-one-sided strategy: resetting an ambiguous pair without touching
// anybody else's friendship.
//
// ── What makes this worth testing carefully ────────────────────────────────
// This is the only part of the social work that DELETES production data. The
// failure that matters is not "it did not remove the four pairs" — that is
// visible immediately and re-runnable. It is "it removed something else": a
// sibling entry in the same athletes map, a whole assignment document, or one
// of the nine mutual friendships. Those are silent, and the people affected
// find out by losing access to each other.
//
// So every test below asserts BOTH halves: the intended entry is gone AND the
// untouched ones are byte-for-byte what they were.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const admin = require('firebase-admin');

const {
  entryFor,
  areMutualFriends,
  scan,
  planRemoval,
  applyRemoval,
  verifyRemoval,
  STRATEGY_SYMMETRISE,
  STRATEGY_REMOVE,
  STRATEGIES,
} = require('../scripts/symmetrise_buddy_assignments');

const DELETE = admin.firestore.FieldValue.delete();

/**
 * A Firestore stand-in covering the surface the removal path uses.
 *
 * Deep-clones on read so a test cannot accidentally observe its own mutation,
 * and records every commit so "what did it actually write?" is answerable
 * rather than inferred from the end state.
 */
function fakeDb({ assignments = {}, invites = {}, profiles = {} } = {}) {
  const store = {
    buddyAssignments: new Map(Object.entries(structuredClone(assignments))),
    users_public: new Map(Object.entries(structuredClone(profiles))),
    users: new Map(Object.keys(profiles).map((k) => [k, {}])),
  };
  // invites: { 'receiverUid/senderUid': {...} }
  const inviteStore = new Map(Object.entries(structuredClone(invites)));
  const commits = [];
  const deletedDocs = [];

  const snapOf = (col, id) => {
    const data = store[col] ? store[col].get(id) : undefined;
    return {
      id,
      exists: data !== undefined,
      data: () => structuredClone(data),
    };
  };

  const inviteRef = (receiver, sender) => ({
    __invite: `${receiver}/${sender}`,
    id: sender,
    path: `users/${receiver}/buddyInvites/${sender}`,
    async get() {
      const key = `${receiver}/${sender}`;
      const data = inviteStore.get(key);
      return {
        exists: data !== undefined,
        ref: inviteRef(receiver, sender),
        data: () => structuredClone(data),
      };
    },
  });

  const docRef = (col, id) => ({
    __col: col,
    __id: id,
    id,
    async get() {
      return snapOf(col, id);
    },
    collection: (sub) => {
      assert.equal(sub, 'buddyInvites', `unexpected subcollection ${sub}`);
      return { doc: (sender) => inviteRef(id, sender) };
    },
  });

  const orderedDocs = () =>
    [...store.buddyAssignments.entries()]
      .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
      .map(([id, data]) => ({ id, exists: true, data: () => structuredClone(data) }));

  const query = (after, cap) => ({
    limit: (n) => query(after, n),
    startAfter: (cursor) => query(cursor.id, cap),
    async get() {
      let docs = orderedDocs();
      if (after) docs = docs.filter((d) => d.id > after);
      if (cap) docs = docs.slice(0, cap);
      return { docs, empty: docs.length === 0, size: docs.length };
    },
  });

  return {
    store,
    inviteStore,
    commits,
    deletedDocs,
    collection(col) {
      return {
        doc: (id) => docRef(col, id),
        orderBy: () => query(null, null),
      };
    },
    batch() {
      const ops = [];
      return {
        set(ref, data, options) {
          assert.deepEqual(
            options,
            { merge: true },
            'a field delete must be a merge, never a document replace',
          );
          ops.push({ kind: 'set', ref, data });
        },
        delete(ref) {
          ops.push({ kind: 'delete', ref });
        },
        async commit() {
          for (const op of ops) {
            if (op.kind === 'delete') {
              assert.ok(
                op.ref.__invite,
                'only invite DOCUMENTS may be deleted outright',
              );
              inviteStore.delete(op.ref.__invite);
              deletedDocs.push(op.ref.path);
              commits.push({ kind: 'deleteDoc', path: op.ref.path });
              continue;
            }
            const existing = store[op.ref.__col].get(op.ref.__id) || {};
            const athletes = { ...(existing.athletes || {}) };
            for (const [k, v] of Object.entries(op.data.athletes || {})) {
              if (v === DELETE) {
                delete athletes[k];
                commits.push({
                  kind: 'deleteField',
                  path: `${op.ref.__col}/${op.ref.__id}`,
                  field: `athletes.${k}`,
                });
              } else {
                athletes[k] = { ...(athletes[k] || {}), ...v };
                commits.push({
                  kind: 'setField',
                  path: `${op.ref.__col}/${op.ref.__id}`,
                  field: `athletes.${k}`,
                });
              }
            }
            store[op.ref.__col].set(op.ref.__id, { ...existing, athletes });
          }
        },
      };
    },
  };
}

const accepted = (at = 'x') => ({ status: 'accepted', acceptedAt: at });

/**
 * Production's shape, reduced: four one-sided pairs and two mutual ones that
 * must come through untouched.
 *
 * `alice` deliberately appears in a one-sided pair AND a mutual one, in the
 * SAME athletes map — that is the case where a careless delete takes the
 * wrong key or rewrites the map wholesale.
 */
function productionLike() {
  return fakeDb({
    profiles: {
      alice: { username: 'alice', displayName: 'Alice A' },
      bob: { username: 'bob', displayName: 'Bob B' },
      carol: { username: 'carol', displayName: 'Carol C' },
      dave: { username: 'dave', displayName: 'Dave D' },
      erin: { username: 'erin', displayName: 'Erin E' },
    },
    assignments: {
      // one-sided: alice -> bob, and alice is mutual with carol
      alice: { athletes: { bob: accepted(), carol: accepted() } },
      carol: { athletes: { alice: accepted(), dave: accepted() } },
      dave: { athletes: { carol: accepted() } },
      // bob has an unrelated mutual friendship with erin
      bob: { athletes: { erin: accepted() } },
      erin: { athletes: { bob: accepted() } },
    },
    invites: {
      'bob/alice': { status: 'accepted', fromUid: 'alice', buddyUid: 'bob' },
      // an invite between two people NOT in a one-sided pair
      'erin/bob': { status: 'accepted', fromUid: 'bob', buddyUid: 'erin' },
    },
  });
}

test('remove: the strategy list is closed and defaults to add-only', () => {
  // Nothing deletes unless the caller names the deleting strategy explicitly.
  assert.deepEqual(STRATEGIES, [STRATEGY_SYMMETRISE, STRATEGY_REMOVE]);
  assert.equal(STRATEGY_SYMMETRISE, 'symmetrise');
  assert.equal(STRATEGY_REMOVE, 'remove-one-sided');
});

test('remove: entryFor sees a status-less entry that isAccepted does not', () => {
  // Pair 4 in production: an entry with addedAt and displayName and NO status.
  // symmetrise ignores it; a reset has to clear it, so the two helpers must
  // genuinely differ here.
  const data = { athletes: { other: { displayName: 'Stevie', addedAt: 't' } } };
  assert.notEqual(entryFor(data, 'other'), null);
  assert.equal(areMutualFriends(data, { athletes: { self: accepted() } }, 'self', 'other'), false);
});

test('remove: the plan names every uid, path and field it would touch', async () => {
  const db = productionLike();
  const { oneSided } = await scan(db, 0);
  const plan = await planRemoval(db, oneSided);

  assert.equal(plan.length, 1);
  const item = plan[0];
  assert.equal(item.claimantId.username, 'alice');
  assert.equal(item.missingId.username, 'bob');
  assert.deepEqual(
    item.entryDeletes.map((d) => `${d.path}#${d.field}`),
    ['buddyAssignments/alice#athletes.bob'],
  );
  assert.deepEqual(
    item.inviteDeletes.map((d) => d.path),
    ['users/bob/buddyInvites/alice'],
  );
});

test('remove: only the one-sided entry goes; every mutual one survives', async () => {
  const db = productionLike();
  const { oneSided, mutual } = await scan(db, 0);
  assert.equal(mutual.length, 3, 'alice<->carol, carol<->dave, bob<->erin');

  const plan = await planRemoval(db, oneSided);
  const out = await applyRemoval(db, plan);
  assert.equal(out.errors.length, 0);

  const alice = db.store.buddyAssignments.get('alice');
  // The target is gone...
  assert.equal(alice.athletes.bob, undefined);
  // ...and the sibling entry in the SAME map is untouched.
  assert.deepEqual(alice.athletes.carol, accepted());
  // Every other document is exactly as it was.
  assert.deepEqual(db.store.buddyAssignments.get('carol').athletes, {
    alice: accepted(),
    dave: accepted(),
  });
  assert.deepEqual(db.store.buddyAssignments.get('bob').athletes, {
    erin: accepted(),
  });
  assert.deepEqual(db.store.buddyAssignments.get('erin').athletes, {
    bob: accepted(),
  });
});

test('remove: the mutual pair count is unchanged afterwards', async () => {
  const db = productionLike();
  const before = (await scan(db, 0)).mutual.length;
  const { oneSided } = await scan(db, 0);
  await applyRemoval(db, await planRemoval(db, oneSided));

  const check = await verifyRemoval(db, before);
  assert.equal(check.ok, true);
  assert.equal(check.oneSided.length, 0);
  assert.equal(check.mutual.length, before);
});

test('remove: verification fails loudly if a mutual friendship went missing', async () => {
  // The check that distinguishes success from catastrophe. "Zero one-sided
  // pairs" is also what deleting everything looks like.
  const db = productionLike();
  const { oneSided } = await scan(db, 0);
  await applyRemoval(db, await planRemoval(db, oneSided));
  // Simulate collateral damage.
  db.store.buddyAssignments.set('erin', { athletes: {} });

  const check = await verifyRemoval(db, 3);
  assert.equal(check.ok, false);
});

test('remove: no assignment document is ever deleted', async () => {
  const db = productionLike();
  const idsBefore = [...db.store.buddyAssignments.keys()].sort();
  const { oneSided } = await scan(db, 0);
  await applyRemoval(db, await planRemoval(db, oneSided));

  assert.deepEqual([...db.store.buddyAssignments.keys()].sort(), idsBefore);
  // Only invite documents appear in the outright-delete log.
  for (const path of db.deletedDocs) {
    assert.match(path, /^users\/[^/]+\/buddyInvites\/[^/]+$/);
  }
});

test('remove: both sides go when both hold an entry', async () => {
  // Pair 4's shape: one accepted entry and one legacy status-less entry.
  const db = fakeDb({
    profiles: { x: { username: 'x' }, y: { username: 'y' } },
    assignments: {
      x: { athletes: { y: accepted() } },
      y: { athletes: { x: { displayName: 'x', addedAt: 't' } } },
    },
  });
  const { oneSided } = await scan(db, 0);
  const plan = await planRemoval(db, oneSided);
  assert.equal(plan[0].entryDeletes.length, 2);

  await applyRemoval(db, plan);
  assert.deepEqual(db.store.buddyAssignments.get('x').athletes, {});
  assert.deepEqual(db.store.buddyAssignments.get('y').athletes, {});
});

test('remove: the pair can start over — no entries and no invites remain', async () => {
  const db = productionLike();
  const { oneSided } = await scan(db, 0);
  await applyRemoval(db, await planRemoval(db, oneSided));

  assert.equal(entryFor(db.store.buddyAssignments.get('alice'), 'bob'), null);
  assert.equal(entryFor(db.store.buddyAssignments.get('bob'), 'alice'), null);
  assert.equal(db.inviteStore.has('bob/alice'), false);
  // An invite belonging to a DIFFERENT pair is untouched.
  assert.equal(db.inviteStore.has('erin/bob'), true);
});

test('remove: running it twice changes nothing the second time', async () => {
  const db = productionLike();
  const { oneSided } = await scan(db, 0);
  await applyRemoval(db, await planRemoval(db, oneSided));
  const afterFirst = structuredClone([...db.store.buddyAssignments.entries()]);
  const commitsAfterFirst = db.commits.length;

  // Re-plan against the new state, as a second run would.
  const second = await scan(db, 0);
  assert.equal(second.oneSided.length, 0);
  const out = await applyRemoval(db, await planRemoval(db, second.oneSided));

  assert.equal(out.fieldsRemoved, 0);
  assert.equal(out.invitesRemoved, 0);
  assert.equal(db.commits.length, commitsAfterFirst, 'no further writes');
  assert.deepEqual([...db.store.buddyAssignments.entries()], afterFirst);
});

test('remove: a stale plan whose pair became mutual is skipped, not applied', async () => {
  // The race the re-read exists for: somebody accepts between the scan and the
  // apply. Tearing that down would delete a friendship made moments earlier.
  const db = productionLike();
  const { oneSided } = await scan(db, 0);
  const plan = await planRemoval(db, oneSided);

  const bob = db.store.buddyAssignments.get('bob');
  db.store.buddyAssignments.set('bob', {
    athletes: { ...bob.athletes, alice: accepted() },
  });

  const out = await applyRemoval(db, plan);
  assert.equal(out.skippedMutual, 1);
  assert.equal(out.fieldsRemoved, 0);
  assert.deepEqual(db.store.buddyAssignments.get('alice').athletes.bob, accepted());
});

test('remove: an already-clear pair is a no-op, not an error', async () => {
  const db = fakeDb({
    profiles: { p: { username: 'p' }, q: { username: 'q' } },
    assignments: { p: { athletes: {} }, q: { athletes: {} } },
  });
  const plan = await planRemoval(db, [{ claimant: 'p', missing: 'q' }]);
  assert.equal(plan[0].noop, true);
  const out = await applyRemoval(db, plan);
  assert.equal(out.errors.length, 0);
  assert.equal(out.fieldsRemoved, 0);
});

test('remove: a missing counterpart document is handled without error', async () => {
  // Pair 1 in production: the missing side has no buddyAssignments document.
  const db = fakeDb({
    profiles: { a: { username: 'a' }, b: { username: 'b' } },
    assignments: { a: { athletes: { b: accepted() } } },
  });
  const { oneSided } = await scan(db, 0);
  const out = await applyRemoval(db, await planRemoval(db, oneSided));
  assert.equal(out.errors.length, 0);
  assert.equal(db.store.buddyAssignments.has('b'), false, 'not created');
  assert.deepEqual(db.store.buddyAssignments.get('a').athletes, {});
});

test('remove: every write is a merge, so a map is never replaced wholesale', async () => {
  // Enforced inside the fake's batch.set, which asserts {merge:true}. A
  // document-replacing write would drop every sibling friendship in the map.
  const db = productionLike();
  const { oneSided } = await scan(db, 0);
  await applyRemoval(db, await planRemoval(db, oneSided));
  assert.ok(db.commits.some((c) => c.kind === 'deleteField'));
});
