// The operational scripts that must run around the tightened rules.
//
// Both are one-time-ish tools that touch production data, so the parts worth
// testing are the ones that decide WHAT to write: the classification of
// one-sided friendships, and the add-only repair. A tool that mis-classifies
// silently unfriends people, or silently manufactures a friendship.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  athletesOf,
  isAccepted,
  pairKey,
  scan,
  repair,
  labelOf,
  describeEntry,
  scanMalformedPendingInvites,
} = require('../scripts/symmetrise_buddy_assignments');

/**
 * A Firestore stand-in with just the surface the script uses.
 *
 * Written against the real call shape — `collection().orderBy().limit()
 * .startAfter().get()`, `batch().set().commit()` — so the script under test is
 * exercised as written rather than through a rewritten copy of itself.
 */
function fakeDb(docsByCollection) {
  const store = new Map();
  for (const [col, docs] of Object.entries(docsByCollection)) {
    store.set(col, new Map(Object.entries(docs)));
  }

  const committed = [];

  function docRef(col, id) {
    return {
      __col: col,
      __id: id,
      async get() {
        const c = store.get(col);
        const data = c ? c.get(id) : undefined;
        return {
          id,
          exists: data !== undefined,
          data: () => data,
        };
      },
    };
  }

  function collection(col) {
    const all = () =>
      [...(store.get(col) || new Map()).entries()]
        .map(([id, data]) => ({ id, exists: true, data: () => data }))
        .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

    const query = (after, cap) => ({
      limit: (n) => query(after, n),
      startAfter: (cursor) => query(cursor.id, cap),
      async get() {
        let docs = all();
        if (after) docs = docs.filter((d) => d.id > after);
        if (cap) docs = docs.slice(0, cap);
        return { docs, empty: docs.length === 0, size: docs.length };
      },
    });

    return {
      doc: (id) => docRef(col, id),
      orderBy: () => query(null, null),
    };
  }

  return {
    committed,
    store,
    collection,
    batch() {
      const ops = [];
      return {
        set(ref, data, options) {
          ops.push({ col: ref.__col, id: ref.__id, data, options });
        },
        async commit() {
          for (const op of ops) {
            const c = store.get(op.col) || new Map();
            const existing = c.get(op.id) || {};
            // merge:true on a nested athletes map, which is what the script
            // relies on to add one entry without touching the others.
            const merged = {
              ...existing,
              athletes: { ...(existing.athletes || {}), ...op.data.athletes },
            };
            c.set(op.id, merged);
            store.set(op.col, c);
            committed.push(op);
          }
        },
      };
    },
  };
}

test('symmetrise: reads an athletes map defensively', () => {
  assert.deepEqual(athletesOf(null), {});
  assert.deepEqual(athletesOf({}), {});
  assert.deepEqual(athletesOf({ athletes: 'nope' }), {});
  assert.deepEqual(athletesOf({ athletes: { a: 1 } }), { a: 1 });
});

test('symmetrise: only an accepted entry counts as accepted', () => {
  assert.equal(isAccepted({ status: 'accepted' }), true);
  assert.equal(isAccepted({ status: 'pending' }), false);
  assert.equal(isAccepted(null), false);
  assert.equal(isAccepted('accepted'), false);
});

test('symmetrise: a pair has one canonical key whichever way round', () => {
  assert.equal(pairKey('a', 'b'), pairKey('b', 'a'));
  assert.equal(pairKey('a', 'b'), 'a|b');
});

test('symmetrise: a mutual pair is left alone', async () => {
  const db = fakeDb({
    buddyAssignments: {
      alice: { athletes: { bob: { status: 'accepted' } } },
      bob: { athletes: { alice: { status: 'accepted' } } },
    },
  });
  const { mutual, oneSided } = await scan(db, 0);
  assert.equal(mutual.length, 1);
  assert.equal(oneSided.length, 0);
});

test('symmetrise: a one-sided pair is found, and named the right way round', async () => {
  const db = fakeDb({
    buddyAssignments: {
      alice: { athletes: { bob: { status: 'accepted' } } },
      bob: { athletes: {} },
    },
  });
  const { oneSided } = await scan(db, 0);
  assert.equal(oneSided.length, 1);
  assert.equal(oneSided[0].claimant, 'alice');
  assert.equal(oneSided[0].missing, 'bob');
});

test('symmetrise: a pending entry is never treated as a friendship', async () => {
  // The whole point of the add-only contract: a request nobody answered must
  // not be turned into a friendship by a repair tool.
  const db = fakeDb({
    buddyAssignments: {
      alice: { athletes: { bob: { status: 'pending' } } },
      bob: { athletes: {} },
    },
  });
  const { mutual, oneSided } = await scan(db, 0);
  assert.equal(mutual.length, 0);
  assert.equal(oneSided.length, 0);
});

test('symmetrise: repair adds the missing side and nothing else', async () => {
  const db = fakeDb({
    buddyAssignments: {
      alice: {
        athletes: { bob: { status: 'accepted' }, carol: { status: 'pending' } },
      },
      bob: { athletes: { dave: { status: 'accepted' } } },
      dave: { athletes: { bob: { status: 'accepted' } } },
    },
  });
  const { oneSided } = await scan(db, 0);
  const result = await repair(db, oneSided);

  assert.equal(result.errors.length, 0);
  assert.equal(result.repaired, 1);

  const bob = db.store.get('buddyAssignments').get('bob');
  assert.equal(bob.athletes.alice.status, 'accepted');
  // The entry it already had is untouched.
  assert.equal(bob.athletes.dave.status, 'accepted');
  // A pending request was not promoted.
  const carol = db.store.get('buddyAssignments').get('carol');
  assert.equal(carol, undefined);
});

test('symmetrise: running twice repairs nothing the second time', async () => {
  const db = fakeDb({
    buddyAssignments: {
      alice: { athletes: { bob: { status: 'accepted' } } },
      bob: { athletes: {} },
    },
  });
  await repair(db, (await scan(db, 0)).oneSided);
  const second = await scan(db, 0);
  assert.equal(second.oneSided.length, 0);
  const again = await repair(db, second.oneSided);
  assert.equal(again.repaired, 0);
});

test('symmetrise: a pair repaired in between is skipped, not re-stamped', async () => {
  const db = fakeDb({
    buddyAssignments: {
      alice: { athletes: { bob: { status: 'accepted' } } },
      bob: { athletes: {} },
    },
  });
  const { oneSided } = await scan(db, 0);
  // The fan-out trigger gets there first.
  db.store.get('buddyAssignments').set('bob', {
    athletes: { alice: { status: 'accepted', acceptedAt: 'original' } },
  });

  const result = await repair(db, oneSided);
  assert.equal(result.repaired, 0);
  assert.equal(result.skipped, 1);
  assert.equal(
    db.store.get('buddyAssignments').get('bob').athletes.alice.acceptedAt,
    'original',
    'an already-accepted entry must not have its timestamp moved',
  );
});

test('symmetrise: a self-entry is ignored', async () => {
  const db = fakeDb({
    buddyAssignments: {
      alice: { athletes: { alice: { status: 'accepted' } } },
    },
  });
  const { mutual, oneSided } = await scan(db, 0);
  assert.equal(mutual.length, 0);
  assert.equal(oneSided.length, 0);
});

test('symmetrise: the report is deterministic', async () => {
  const build = () =>
    fakeDb({
      buddyAssignments: {
        zoe: { athletes: { adam: { status: 'accepted' } } },
        adam: { athletes: {} },
        mia: { athletes: { leo: { status: 'accepted' } } },
        leo: { athletes: {} },
      },
    });
  const a = await scan(build(), 0);
  const b = await scan(build(), 0);
  assert.deepEqual(a.oneSided, b.oneSided);
  // Ordered by the CANONICAL pair key, so 'adam|zoe' precedes 'leo|mia'
  // regardless of which side of each pair happened to record the acceptance.
  assert.deepEqual(
    a.oneSided.map((p) => `${p.claimant}->${p.missing}`),
    ['zoe->adam', 'mia->leo'],
  );
});

test('backfill_search_index exposes its report surface', () => {
  const script = require('../scripts/backfill_search_index');
  assert.equal(typeof script.inspect, 'function');
  assert.equal(typeof script.publicProfiles, 'function');
});

// ── Read-only preflight reporting ──────────────────────────────────────────
//
// The report exists so a human can tell a real friendship from obsolete test
// data before applying anything. Its job is to be UNAMBIGUOUS about accounts
// that are gone and entries that are malformed, because those are exactly the
// pairs worth leaving alone.

test('report: an account with a name and handle is labelled with both', () => {
  assert.equal(
    labelOf({
      hasPublicProfile: true,
      hasAccountDoc: true,
      displayName: 'Ruby Cain',
      username: 'rubycakes',
      fullName: '',
    }),
    'Ruby Cain  @rubycakes',
  );
});

test('report: a deleted account is called out, not shown as anonymous', () => {
  // A blank label reads as "no name set". "MISSING / DELETED" is a different
  // fact, and it is the one that decides whether to repair the pair at all.
  assert.equal(
    labelOf({ hasPublicProfile: false, hasAccountDoc: false }),
    'MISSING / DELETED',
  );
});

test('report: a half-present account says which half is missing', () => {
  const label = labelOf({
    hasPublicProfile: false,
    hasAccountDoc: true,
    displayName: 'Someone',
    username: '',
  });
  assert.match(label, /no users_public/);
  assert.match(label, /\(no username\)/);
});

test('report: falls back to fullName when there is no display name', () => {
  assert.equal(
    labelOf({
      hasPublicProfile: true,
      hasAccountDoc: true,
      displayName: '',
      fullName: 'Shawn Cain',
      username: 'MrWalker',
    }),
    'Shawn Cain  @MrWalker',
  );
});

test('report: an absent entry and a status-less entry are described differently', () => {
  // Production has both. A legacy entry carrying addedAt and displayName but
  // NO status is not the same as no entry at all, and the operator needs to
  // see which one they are looking at.
  assert.equal(describeEntry(null, 'other'), 'no entry');
  assert.equal(describeEntry({ athletes: {} }, 'other'), 'no entry');
  assert.match(
    describeEntry(
      { athletes: { other: { displayName: 'Stevie_Wanda' } } },
      'other',
    ),
    /status=\(none\)/,
  );
  assert.match(
    describeEntry({ athletes: { other: { status: 'accepted' } } }, 'other'),
    /status=accepted/,
  );
});

/** A db whose collection-group read fails, forcing the per-account walk. */
function fakeInviteDb(invitesByUser, { collectionGroupWorks = false } = {}) {
  const docOf = (receiver, sender, data) => ({
    ref: {
      id: sender,
      path: `users/${receiver}/buddyInvites/${sender}`,
    },
    data: () => data,
  });

  return {
    collectionGroup() {
      return {
        where() {
          return {
            async get() {
              if (!collectionGroupWorks) {
                throw new Error('9 FAILED_PRECONDITION: index required');
              }
              const docs = [];
              for (const [receiver, invites] of Object.entries(invitesByUser)) {
                for (const [sender, data] of Object.entries(invites)) {
                  if (data.status === 'pending') {
                    docs.push(docOf(receiver, sender, data));
                  }
                }
              }
              return { docs };
            },
          };
        },
      };
    },
    collection() {
      return {
        select: () => ({
          async get() {
            return {
              docs: Object.keys(invitesByUser).map((receiver) => ({
                id: receiver,
                ref: {
                  collection: () => ({
                    where: () => ({
                      async get() {
                        const docs = [];
                        for (const [sender, data] of Object.entries(
                          invitesByUser[receiver],
                        )) {
                          if (data.status === 'pending') {
                            docs.push(docOf(receiver, sender, data));
                          }
                        }
                        return { docs };
                      },
                    }),
                  }),
                },
              })),
            };
          },
        }),
      };
    },
  };
}

const wellFormed = {
  receiver1: {
    sender1: { status: 'pending', fromUid: 'sender1', buddyUid: 'receiver1' },
  },
};

test('report: a well-formed pending invite is not flagged', async () => {
  const result = await scanMalformedPendingInvites(
    fakeInviteDb(wellFormed, { collectionGroupWorks: true }),
  );
  assert.equal(result.scanned, 1);
  assert.equal(result.bad.length, 0);
  assert.equal(result.viaFallback, false);
});

test('report: the audit still completes without a collection-group index', async () => {
  // Production has no COLLECTION_GROUP index on buddyInvites.status, so the
  // fallback IS the path this takes. An audit that simply failed there would
  // leave the operator with no answer about the very risk it exists to check.
  const result = await scanMalformedPendingInvites(fakeInviteDb(wellFormed));
  assert.equal(result.viaFallback, true);
  assert.equal(result.scanned, 1);
  assert.equal(result.bad.length, 0);
});

test('report: an invite missing fromUid or buddyUid is flagged', async () => {
  const result = await scanMalformedPendingInvites(
    fakeInviteDb(
      {
        r1: {
          s1: { status: 'pending', buddyUid: 'r1' },
          s2: { status: 'pending', fromUid: 's2' },
          s3: { status: 'pending', fromUid: 's3', buddyUid: 'r1' },
        },
      },
      { collectionGroupWorks: true },
    ),
  );
  assert.equal(result.scanned, 3);
  assert.equal(result.bad.length, 2);
  assert.match(result.bad[0].problems.join(' '), /fromUid absent/);
  assert.match(result.bad[1].problems.join(' '), /buddyUid absent/);
});

test('report: a pointer that disagrees with its path is flagged too', async () => {
  // The rule compares the STORED fromUid against the document id, so an invite
  // whose fields point somewhere else is just as un-answerable as one missing
  // them. Both would otherwise look fine to a field-presence check.
  const result = await scanMalformedPendingInvites(
    fakeInviteDb(
      {
        r1: {
          s1: { status: 'pending', fromUid: 'somebody-else', buddyUid: 'r1' },
          s2: { status: 'pending', fromUid: 's2', buddyUid: 'wrong-receiver' },
        },
      },
      { collectionGroupWorks: true },
    ),
  );
  assert.equal(result.bad.length, 2);
  assert.match(result.bad[0].problems.join(' '), /!= docId/);
  assert.match(result.bad[1].problems.join(' '), /!= receiver/);
});

test('report: resolved invites are not audited', async () => {
  const result = await scanMalformedPendingInvites(
    fakeInviteDb(
      { r1: { s1: { status: 'denied' }, s2: { status: 'accepted' } } },
      { collectionGroupWorks: true },
    ),
  );
  assert.equal(result.scanned, 0);
  assert.equal(result.bad.length, 0);
});
