'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { promisify } = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
const hasFfmpeg = require('node:child_process').spawnSync('ffmpeg', ['-version']).status === 0;
const { posterPlan, repairPoster, renderPoster } = require('../profile/post_thumbnails');
const { argumentsFor } = require('../scripts/repair_post_thumbnails');

const data = { ownerUid: 'o', mediaType: 'video',
  storagePathOriginal: 'users/o/posts/p/original.mp4', thumbUrl: '', caption: '85x3' };

function setup({ exists = false, current = data, saveError, size = 100 } = {}) {
  const calls = { saved: [], updated: [], downloads: [], renders: 0, writes: 0 };
  const thumb = {
    exists: async () => [exists],
    save: async (bytes, options) => {
      calls.saved.push({ bytes, options });
      if (saveError) throw saveError;
    },
    getMetadata: async () => [{ contentType: 'image/jpeg', size: 100 }],
  };
  const bucket = { file: (name) => name.endsWith('thumb.jpg') ? thumb : {
    getMetadata: async () => [{ size }],
    download: async ({ destination }) => {
      calls.downloads.push(name);
      await fs.writeFile(destination, 'local-video');
    },
  } };
  const db = {
    collection: () => ({ doc: (id) => ({ id }) }),
    runTransaction: async (fn) => {
      calls.writes++;
      return fn({
        get: async () => ({ exists: current !== null, data: () => current }),
        update: (ref, patch) => calls.updated.push({ ref, patch }),
      });
    },
  };
  const render = async (video) => {
    calls.renders++;
    assert.equal(await fs.readFile(video, 'utf8'), 'local-video');
    return Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
  };
  return { calls, opts: { db, bucket, postId: 'p', data, render,
    downloadUrl: async () => 'https://example.test/thumb.jpg', apply: true } };
}

test('repair only accepts the exact owner/post video location', () => {
  assert.equal(posterPlan('p', data).thumb, 'users/o/posts/p/thumb.jpg');
  for (const original of ['users/other/posts/p/original.mp4',
    'users/o/posts/other/original.mp4', 'https://host/video.mp4',
    'users/o/posts/p/../../original.mp4']) {
    assert.equal(posterPlan('p', { ...data, storagePathOriginal: original }), null);
  }
  assert.equal(posterPlan('p', { ...data, mediaType: 'image' }), null);
});

test('dry run does not download, render, upload or update anything', async () => {
  const { calls, opts } = setup();
  assert.equal((await repairPoster({ ...opts, apply: false })).status, 'generate-poster');
  assert.equal(calls.renders + calls.saved.length + calls.downloads.length + calls.writes, 0);
});

test('existing JPEG is reused, never overwritten or regenerated', async () => {
  const { calls, opts } = setup({ exists: true });
  assert.equal((await repairPoster(opts)).status, 'repaired');
  assert.equal(calls.renders + calls.saved.length + calls.downloads.length, 0);
  assert.deepEqual(calls.updated[0].patch, {
    thumbUrl: 'https://example.test/thumb.jpg', thumbStoragePath: 'users/o/posts/p/thumb.jpg',
  });
});

test('missing JPEG is generated; upload cannot overwrite a newer object', async () => {
  const { calls, opts } = setup();
  assert.equal((await repairPoster(opts)).status, 'repaired');
  assert.equal(calls.renders, 1);
  assert.deepEqual(calls.downloads, [data.storagePathOriginal]);
  assert.deepEqual(calls.saved[0].options.preconditionOpts, { ifGenerationMatch: 0 });
  assert.deepEqual(Object.keys(calls.updated[0].patch).sort(), ['thumbStoragePath', 'thumbUrl']);
});

test('oversized videos stop before download or writes', async () => {
  const { calls, opts } = setup({ size: 300 * 1024 * 1024 });
  await assert.rejects(repairPoster(opts), /size bound/);
  assert.equal(calls.downloads.length + calls.saved.length + calls.writes, 0);
});

test('concurrent poster creation is reused after generation-match conflict', async () => {
  const { opts } = setup({ saveError: { code: 412 } });
  assert.equal((await repairPoster(opts)).status, 'repaired');
});

test('deleted/replaced posts and concurrently updated previews are preserved', async () => {
  for (const current of [null, { ...data, ownerUid: 'other' },
    { ...data, storagePathOriginal: 'users/o/posts/p/original.mov' },
    { ...data, thumbUrl: 'https://example.test/newer.jpg' }]) {
    const { calls, opts } = setup({ exists: true, current });
    assert.equal((await repairPoster(opts)).status, 'post-changed-or-deleted');
    assert.equal(calls.updated.length, 0);
  }
});

test('repeated repairs do not rewrite post metadata or refanout', async () => {
  const { calls, opts } = setup({ exists: true, current: { ...data,
    thumbUrl: 'https://example.test/thumb.jpg', thumbStoragePath: 'users/o/posts/p/thumb.jpg' } });
  assert.equal((await repairPoster(opts)).status, 'already-repaired');
  assert.equal(calls.updated.length, 0);
});

test('renderer extracts a real still without altering the video', { skip: !hasFfmpeg }, async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'goodlift-poster-test-'));
  try {
    const video = path.join(dir, 'clip.mp4');
    await execFile('ffmpeg', ['-nostdin', '-loglevel', 'error', '-f', 'lavfi',
      '-i', 'color=c=blue:s=64x48:d=0.3', '-c:v', 'mpeg4', '-y', video]);
    const before = await fs.readFile(video);
    const still = await renderPoster(video, path.join(dir, 'thumb.jpg'));
    assert.equal(still[0], 0xff);
    assert.equal(still[1], 0xd8);
    assert.deepEqual(await fs.readFile(video), before);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test('command requires a single named account and bounded work', () => {
  assert.deepEqual(argumentsFor(['--username', '@coded_nz']),
    { username: 'coded_nz', apply: false, limit: 10 });
  assert.throws(() => argumentsFor([]));
  assert.throws(() => argumentsFor(['--username', 'coded_nz', '--limit', '51']));
  assert.throws(() => argumentsFor(['--username', 'coded_nz', '--unknown']));
});
