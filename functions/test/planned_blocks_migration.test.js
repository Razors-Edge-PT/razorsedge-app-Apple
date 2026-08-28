'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const migration = require('../scripts/migrate_planned_blocks_to_users')._internals;

test('planned-blocks migration defaults to a non-writing dry run', () => {
  assert.deepEqual(migration.parseArgs([]), {
    projectId: 'goodlift-us-storage',
    uid: null,
    execute: false,
    verify: false,
    allowKnownOrphans: false,
  });
  assert.deepEqual(
    migration.parseArgs(['--uid', 'athlete-1', '--execute']),
    {
      projectId: 'goodlift-us-storage',
      uid: 'athlete-1',
      execute: true,
      verify: false,
      allowKnownOrphans: false,
    },
  );
});

test('known orphans must be opted in explicitly', () => {
  // Off unless asked for: an unexpected orphan still fails the run.
  assert.equal(migration.parseArgs([]).allowKnownOrphans, false);
  assert.equal(
    migration.parseArgs(['--verify', '--allow-known-orphans']).allowKnownOrphans,
    true,
  );
});

test('planned-blocks migration refuses conflicting write modes', () => {
  assert.throws(
    () => migration.parseArgs(['--execute', '--verify']),
    /Choose either --execute or --verify/,
  );
  assert.throws(
    () => migration.parseArgs(['--wat']),
    /Unknown argument/,
  );
});

test('Firestore comparison is stable across key order and typed values', () => {
  const timestampA = { seconds: 10, nanoseconds: 20, toMillis() { return 10000; } };
  const timestampB = { seconds: 10, nanoseconds: 20, toMillis() { return 10000; } };
  assert.equal(
    migration.documentsEqual(
      { b: [2, 3], a: timestampA },
      { a: timestampB, b: [2, 3] },
    ),
    true,
  );
  assert.equal(
    migration.documentsEqual({ value: 1 }, { value: 2 }),
    false,
  );
});

test('migration recursively copies block, week, and day documents', async () => {
  function sourceDoc(path, data, collections = {}) {
    return {
      path,
      id: path.split('/').at(-1),
      async get() { return { exists: true, data: () => data }; },
      async listCollections() {
        return Object.entries(collections).map(([id, documents]) => ({
          id,
          async listDocuments() { return documents; },
        }));
      },
    };
  }

  const day = sourceDoc(
    'planned_blocks/u/blocks/b/weeks/week_0/days/day_1',
    { exercises: [{ id: 'bench' }] },
  );
  const week = sourceDoc(
    'planned_blocks/u/blocks/b/weeks/week_0',
    { exists: true },
    { days: [day] },
  );
  const block = sourceDoc(
    'planned_blocks/u/blocks/b',
    { name: 'Block B' },
    { weeks: [week] },
  );

  const writes = [];
  function destinationDoc(path) {
    return {
      path,
      async get() { return { exists: false }; },
      async set(data, options) { writes.push({ path, data, options }); },
      collection(id) {
        return { doc: (childId) => destinationDoc(`${path}/${id}/${childId}`) };
      },
    };
  }

  const stats = migration.newStats();
  await migration.walkDocumentTree(
    block,
    destinationDoc('users/u/planned_blocks/b'),
    { execute: true, verify: false },
    stats,
  );

  assert.equal(stats.sourceDocuments, 3);
  assert.equal(stats.created, 3);
  assert.deepEqual(
    writes.map((write) => write.path),
    [
      'users/u/planned_blocks/b',
      'users/u/planned_blocks/b/weeks/week_0',
      'users/u/planned_blocks/b/weeks/week_0/days/day_1',
    ],
  );
  assert.ok(writes.every((write) => write.options.merge === false));
});

test('a missing users/{uid} doc copies nothing, even with --allow-known-orphans',
  async () => {
    // The flag only stops confirmed deleted accounts failing the run. It must
    // never cause their data to be written into the canonical hierarchy, which
    // would resurrect deleted users' training data under a phantom user doc.
    for (const allowKnownOrphans of [false, true]) {
      const touched = [];
      const db = {
        collection(name) {
          touched.push(`collection:${name}`);
          return {
            doc: (id) => ({
              async get() { return { exists: false }; },
              collection(child) {
                touched.push(`collection:${name}/${id}/${child}`);
                return { async listDocuments() { return []; } };
              },
            }),
          };
        },
      };

      const stats = migration.newStats();
      await migration.migrateUser(db, 'deleted-user', {
        execute: true,
        verify: false,
        allowKnownOrphans,
      }, stats);

      assert.deepEqual(stats.orphanUsers, ['deleted-user']);
      assert.equal(stats.sourceDocuments, 0);
      assert.equal(stats.created, 0);
      // It must bail out before ever reaching the legacy blocks subcollection.
      assert.ok(!touched.some((entry) => entry.includes('/blocks')));
    }
  });
