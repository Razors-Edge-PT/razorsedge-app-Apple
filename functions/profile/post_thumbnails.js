'use strict';

const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const run = promisify(execFile);
const MAX_VIDEO_BYTES = 200 * 1024 * 1024;

function posterPlan(postId, data) {
  if (!data || data.mediaType !== 'video' || !data.ownerUid) return null;
  // Exact existing per-post location. Never infer another account's object
  // from a supplied download URL, and never fetch a remote URL through ffmpeg.
  const prefix = `users/${data.ownerUid}/posts/${postId}/`;
  const original = data.storagePathOriginal;
  if (typeof original !== 'string' || !original.startsWith(prefix) ||
      !/^original\.(mp4|mov|m4v|webm|3gp|3gpp|avi|mkv|mpeg|mpg|qt)$/i.test(original.slice(prefix.length))) {
    return null;
  }
  return { ownerUid: data.ownerUid, postId, original, thumb: `${prefix}thumb.jpg` };
}

async function renderPoster(video, output, ffmpeg = 'ffmpeg') {
  await run(ffmpeg, [
    '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
    '-i', video, '-frames:v', '1', '-vf', 'scale=720:-2',
    '-threads', '1', '-q:v', '4', output,
  ], { timeout: 45000, maxBuffer: 1024 * 1024 });
  const bytes = await fs.readFile(output);
  if (bytes.length < 4 || bytes.length > 2 * 1024 * 1024 ||
      bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    throw new Error('Renderer did not produce a bounded JPEG.');
  }
  return bytes;
}

async function repairPoster({ db, bucket, postId, data, apply = false,
  render = renderPoster, downloadUrl }) {
  const plan = posterPlan(postId, data);
  if (!plan) return { status: 'unsupported-path', postId };
  const thumb = bucket.file(plan.thumb);
  const [exists] = await thumb.exists();
  if (!apply) {
    return { status: exists ? 'reuse-existing-poster' : 'generate-poster', postId };
  }
  if (!exists) {
    const original = bucket.file(plan.original);
    const [metadata] = await original.getMetadata();
    const size = Number(metadata.size);
    if (!Number.isFinite(size) || size <= 0 || size > MAX_VIDEO_BYTES) {
      throw new Error(`Video ${postId} exceeds the repair size bound.`);
    }
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'goodlift-poster-'));
    try {
      const video = path.join(dir, `original${path.extname(plan.original)}`);
      await original.download({ destination: video });
      const bytes = await render(video, path.join(dir, 'thumb.jpg'));
      try {
        await thumb.save(bytes, {
          resumable: false,
          preconditionOpts: { ifGenerationMatch: 0 },
          metadata: {
            contentType: 'image/jpeg',
            metadata: { firebaseStorageDownloadTokens: randomUUID() },
          },
        });
      } catch (error) {
        // A concurrent uploader may have created the poster. Reuse it;
        // never overwrite a newer image or rotate its existing token.
        if (Number(error.code) !== 412) throw error;
      }
    } finally {
      await fs.rm(dir, { recursive: true, force: true });
    }
  }
  const [thumbMetadata] = await thumb.getMetadata();
  if (thumbMetadata.contentType !== 'image/jpeg' || Number(thumbMetadata.size) <= 0) {
    throw new Error(`Existing poster ${postId} is not a usable JPEG.`);
  }
  const url = await downloadUrl(thumb);
  // Only the two existing preview fields change. No timestamps, scores,
  // caption, friendship or original video is rewritten. The existing post
  // trigger propagates this update into the friends' feed projections.
  const ref = db.collection('posts').doc(postId);
  const status = await db.runTransaction(async (tx) => {
    const current = await tx.get(ref);
    const fresh = current.exists ? current.data() : null;
    const freshPlan = posterPlan(postId, fresh);
    if (!freshPlan || freshPlan.ownerUid !== plan.ownerUid ||
        freshPlan.original !== plan.original) return 'post-changed-or-deleted';
    if (fresh.thumbUrl === url && fresh.thumbStoragePath === plan.thumb) return 'already-repaired';
    // If another upload supplied a different poster while we rendered, keep it.
    if (fresh.thumbUrl !== data.thumbUrl || fresh.thumbStoragePath !== data.thumbStoragePath) {
      return 'post-changed-or-deleted';
    }
    tx.update(ref, { thumbUrl: url, thumbStoragePath: plan.thumb });
    return 'repaired';
  });
  return { status, postId };
}

module.exports = { posterPlan, renderPoster, repairPoster };
