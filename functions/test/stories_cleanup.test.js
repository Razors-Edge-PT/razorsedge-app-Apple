'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { cleanupExpiredStories } = require('../social/stories');

const HOUR = 60 * 60 * 1000;
const T0 = Date.UTC(2026, 7, 29, 12, 0, 0);
const NOW = T0 + 30 * HOUR;

function ts(ms) {
  return { _ms: ms, toMillis: () => ms };
}

/** Minimal stand-ins for the two SDK surfaces cleanup touches. */
function fakeWorld(stories, { failingPaths = new Set() } = {}) {
  const docs = new Map(stories.map((s) => [s.id, Object.assign({}, s)]));
  const objects = new Set();
  for (const s of stories) {
    if (s.storagePath) objects.add(s.storagePath);
    if (s.thumbPath) objects.add(s.thumbPath);
  }

  const firestore = {
    collectionGroup() {
      const state = { cutoff: null, limit: Infinity };
      const q = {
        where(_field, _op, value) {
          state.cutoff = value._ms;
          return q;
        },
        orderBy() {
          return q;
        },
        limit(n) {
          state.limit = n;
          return q;
        },
        async get() {
          const matching = [...docs.values()]
            .filter((d) => d.publishedAtMs <= state.cutoff)
            .sort((a, b) => a.publishedAtMs - b.publishedAtMs)
            .slice(0, state.limit);
          return {
            size: matching.length,
            docs: matching.map((d) => ({
              id: d.id,
              data: () => d,
              ref: {
                async delete() {
                  docs.delete(d.id);
                },
              },
            })),
          };
        },
      };
      return q;
    },
  };

  const bucket = {
    file(path) {
      return {
        async delete() {
          if (failingPaths.has(path)) {
            const e = new Error('permission denied');
            e.code = 500;
            throw e;
          }
          if (!objects.has(path)) {
            const e = new Error('not found');
            e.code = 404;
            throw e;
          }
          objects.delete(path);
        },
      };
    },
  };

  return { firestore, bucket, docs, objects };
}

function run(world, now = NOW) {
  return cleanupExpiredStories(now, {
    firestore: world.firestore,
    bucket: world.bucket,
    timestampFromMillis: ts,
  });
}

const expired = {
  id: 'old',
  publishedAtMs: T0,
  storagePath: 'users/u1/stories/old.mp4',
  thumbPath: 'users/u1/stories/old_thumb.jpg',
};
const live = {
  id: 'fresh',
  publishedAtMs: NOW - HOUR,
  storagePath: 'users/u1/stories/fresh.mp4',
};

test('cleanup deletes expired stories and their storage objects', async () => {
  const world = fakeWorld([expired, live]);
  const res = await run(world);
  assert.strictEqual(res.documentsDeleted, 1);
  assert.strictEqual(res.objectsDeleted, 2);
  assert.deepStrictEqual([...world.docs.keys()], ['fresh']);
  assert.deepStrictEqual([...world.objects], ['users/u1/stories/fresh.mp4']);
});

test('cleanup never touches a story that is still live', async () => {
  const world = fakeWorld([live]);
  const res = await run(world);
  assert.strictEqual(res.scanned, 0);
  assert.strictEqual(res.documentsDeleted, 0);
  assert.deepStrictEqual([...world.docs.keys()], ['fresh']);
});

test('a story published exactly 24 hours ago is swept', async () => {
  const world = fakeWorld([{ id: 'edge', publishedAtMs: T0 }]);
  const res = await run(world, T0 + 24 * HOUR);
  assert.strictEqual(res.documentsDeleted, 1);
});

test('a story published one millisecond inside the window survives', async () => {
  const world = fakeWorld([{ id: 'edge', publishedAtMs: T0 + 1 }]);
  const res = await run(world, T0 + 24 * HOUR);
  assert.strictEqual(res.documentsDeleted, 0);
});

test('cleanup is idempotent: a second run is a no-op', async () => {
  const world = fakeWorld([expired, live]);
  await run(world);
  const second = await run(world);
  assert.strictEqual(second.documentsDeleted, 0);
  assert.strictEqual(second.scanned, 0);
});

test('an already-deleted storage object does not block record deletion', async () => {
  // Crash window: the previous run deleted the file, then died before
  // deleting the document.
  const world = fakeWorld([expired]);
  world.objects.delete(expired.storagePath);
  world.objects.delete(expired.thumbPath);
  const res = await run(world);
  assert.strictEqual(res.objectsMissing, 2);
  assert.strictEqual(res.documentsDeleted, 1);
  assert.strictEqual(world.docs.size, 0);
});

test('a real storage failure keeps the record for the next run', async () => {
  const world = fakeWorld([expired], {
    failingPaths: new Set([expired.storagePath]),
  });
  const res = await run(world);
  assert.strictEqual(res.documentsDeleted, 0);
  assert.strictEqual(world.docs.size, 1, 'record must survive to retry');

  // Once Storage recovers, the next run finishes the job.
  const healthy = fakeWorld([expired]);
  const second = await run(healthy);
  assert.strictEqual(second.documentsDeleted, 1);
  assert.strictEqual(healthy.objects.size, 0);
});
