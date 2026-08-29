// Stories: publication, exact 24-hour expiry, and idempotent cleanup.
//
// ── Why publication time is server-derived ──────────────────────────────────
// A client clock cannot be trusted to start a 24-hour window. Firestore rules
// therefore require `publishedAt == request.time` on create, so the stored
// timestamp IS the server's commit time. The client writes
// FieldValue.serverTimestamp(); anything else is rejected.
//
// ── Why readers use publishedAt, not expiresAt ──────────────────────────────
// `expiresAt` is stamped by the onCreate trigger below, which is useful for
// audit and for the cleanup query, but it lands a moment AFTER the document
// does. Readers therefore compute liveness from `publishedAt + 24h`, which is
// exact from the instant the document exists and needs no second write. A
// story is live iff `now - publishedAt < 24h`; at EXACTLY 24 hours it is
// expired.
//
// ── Offline ────────────────────────────────────────────────────────────────
// A story selected while offline never reaches this code. It sits in the
// client's durable media outbox as a pending item that only the owner can see,
// and its 24 hours begin when the upload and this document both succeed.

'use strict';

const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

/** A story's lifetime, in milliseconds. */
const STORY_TTL_MS = 24 * 60 * 60 * 1000;

/**
 * Pure liveness rule. Exactly STORY_TTL_MS after publication the story is
 * EXPIRED, not live.
 */
function isStoryLive(publishedAtMs, nowMs) {
  if (!Number.isFinite(publishedAtMs) || !Number.isFinite(nowMs)) return false;
  return nowMs - publishedAtMs < STORY_TTL_MS;
}

/** The instant a story published at publishedAtMs stops being visible. */
function storyExpiryMs(publishedAtMs) {
  return publishedAtMs + STORY_TTL_MS;
}

/** The oldest publication time that is still live at nowMs. */
function liveCutoffMs(nowMs) {
  return nowMs - STORY_TTL_MS;
}

function db() {
  return admin.firestore();
}

/**
 * Stamps expiresAt from the document's own server-assigned publishedAt.
 * Idempotent: it never overwrites an expiresAt that is already correct, and
 * re-delivery recomputes the identical value.
 */
const storyOnPublished = onDocumentCreated(
  { document: 'users/{uid}/stories/{storyId}', retry: true },
  async (event) => {
    const snap = event.data;
    if (!snap || !snap.exists) return;
    const data = snap.data();
    const publishedAt = data && data.publishedAt;
    if (!publishedAt || typeof publishedAt.toMillis !== 'function') return;
    const expiresAtMs = storyExpiryMs(publishedAt.toMillis());
    const existing = data.expiresAt;
    if (existing && typeof existing.toMillis === 'function'
        && existing.toMillis() === expiresAtMs) {
      return;
    }
    await snap.ref.set(
      { expiresAt: admin.firestore.Timestamp.fromMillis(expiresAtMs) },
      { merge: true },
    );
  },
);

/**
 * Deletes expired stories and their Storage objects.
 *
 * Safe and idempotent by construction:
 *   * it only ever touches documents whose publishedAt is already older than
 *     the TTL, so a story that is still live can never be caught;
 *   * Storage deletion tolerates "already gone" (404) — a re-run after a crash
 *     finishes the job rather than failing;
 *   * the Firestore document is deleted LAST, so a crash between the two
 *     leaves a record that the next run will retry, never an orphaned file
 *     with no record of it.
 */
async function cleanupExpiredStories(
  nowMs,
  { limit = 500, firestore, bucket, timestampFromMillis } = {},
) {
  const fs = firestore || db();
  const files = bucket || (() => admin.storage().bucket())();
  const toTimestamp =
    timestampFromMillis || ((ms) => admin.firestore.Timestamp.fromMillis(ms));

  const cutoff = toTimestamp(liveCutoffMs(nowMs));
  const q = await fs
    .collectionGroup('stories')
    .where('publishedAt', '<=', cutoff)
    .orderBy('publishedAt')
    .limit(limit)
    .get();

  let documentsDeleted = 0;
  let objectsDeleted = 0;
  let objectsMissing = 0;

  for (const doc of q.docs) {
    const data = doc.data() || {};
    const paths = [];
    if (typeof data.storagePath === 'string' && data.storagePath) paths.push(data.storagePath);
    if (typeof data.thumbPath === 'string' && data.thumbPath) paths.push(data.thumbPath);

    let objectFailed = false;
    for (const path of paths) {
      try {
        await files.file(path).delete();
        objectsDeleted++;
      } catch (err) {
        if (err && (err.code === 404 || err.code === 'storage/object-not-found')) {
          objectsMissing++;
        } else {
          logger.warn('story cleanup: storage delete failed', {
            path,
            error: err && err.message,
          });
          // Leave the document in place so the NEXT run retries this object.
          // Never delete the record while its file may still exist — that is
          // the only way this sweep could orphan a Storage object.
          objectFailed = true;
          break;
        }
      }
    }
    if (objectFailed) continue;
    await doc.ref.delete();
    documentsDeleted++;
  }

  return { documentsDeleted, objectsDeleted, objectsMissing, scanned: q.size };
}

/** Hourly sweep. Cheap: the query is bounded and indexed on publishedAt. */
const storyCleanupScheduler = onSchedule(
  { schedule: 'every 60 minutes', timeZone: 'Etc/UTC', retryCount: 2 },
  async () => {
    const result = await cleanupExpiredStories(Date.now());
    if (result.scanned > 0) logger.info('story cleanup', result);
  },
);

module.exports = {
  STORY_TTL_MS,
  isStoryLive,
  storyExpiryMs,
  liveCutoffMs,
  cleanupExpiredStories,
  storyOnPublished,
  storyCleanupScheduler,
};
