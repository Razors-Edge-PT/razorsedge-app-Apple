// The buddy feed: a per-viewer projection of gallery posts, and the confirmed
// friend list it is fanned out over.
//
// ── Why there is a `socialGraph` projection ────────────────────────────────
// A confirmed friendship is MUTUAL: both `buddyAssignments` documents must say
// `accepted` (see buddy_model.js for why). But `buddyAssignments/{ownerUid}`
// is readable only by its owner, so neither the client nor a cheap server
// read can answer "are these two confirmed friends?" without reading the OTHER
// person's document — which the client may not do at all, and which would cost
// one read per friend on every post write.
//
// `socialGraph/{uid}.friends` is that answer, precomputed. It is a PROJECTION,
// never an authority: no security rule reads it, and if it were deleted
// entirely the rules would still permit and deny exactly what they do now. It
// is recomputed from `buddyAssignments` — both sides — whenever a friendship
// changes, so it converges rather than drifts.
//
// It is also what lets the People view render confirmed buddies at all. The
// viewer's own assignment document lists people they have accepted; only the
// intersection with the other side is a friendship.
//
// ── Why fan-out, and what the alternative would have cost ──────────────────
// The direct alternative is querying `posts` for the viewer's friends:
//
//     where ownerUid in [...], showInGrid == true,
//     mediaType in [image, video], orderBy createdAt desc
//
// It reuses an index that already exists and stores nothing. It also does not
// work past a handful of friends. `in` takes at most 30 values, so a viewer
// with 200 friends needs 7 parallel queries; combining that with the
// `mediaType in [...]` disjunction multiplies the expansion again. Merging N
// independently-ordered cursors into one globally-ordered page means
// over-fetching from every chunk, holding the merge state across pages, and
// re-deriving it on every refresh — and a viewer whose 200 friends are mostly
// inactive pays all N queries to produce one page. Correct global ordering
// with stable cursor pagination is exactly the thing the chunked query cannot
// give cheaply.
//
// Fan-out inverts the cost: one bounded write per friend when a post is
// published (rare), and ONE ordered, cursor-paginated query per page when the
// feed is read (constant, and the common case). The stored copy is metadata
// only — a reference to the post and the fields needed to draw a card. No
// media bytes are duplicated: `thumbUrl`/`smallUrl` and the Storage paths
// point at the same objects the profile grid already uses, with the same cache
// identity, so a photo cached by the profile is the same cache entry here.
//
// The cost is write amplification on publish, bounded by MAX_FANOUT, and
// storage of roughly 300 bytes per (viewer, post) pair. For an app of this
// size that is the right side of the trade.
//
// ── Idempotency ────────────────────────────────────────────────────────────
// A feed item's id is `{ownerUid}__{postId}`. It is derived, not generated, so
// every one of these handlers can run any number of times and converge on the
// same set of documents. `set()` with a fully-computed value replaces rather
// than accumulates, and the removal paths delete by the same derived id. That
// is what makes `retry: true` safe, and what makes a duplicated event harmless
// rather than a source of duplicate cards.

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const M = require('./buddy_model');

const COL_GRAPH = 'socialGraph';
const SUB_FEED = 'feed';
const COL_POSTS = 'posts';

/** Media types a feed card can actually render. Mirrors kSupportedMediaTypes. */
const SUPPORTED_MEDIA = ['image', 'video'];

/** Post kinds that are never feed content, whatever else they carry. */
const EXCLUDED_KINDS = ['re_daily'];

/** Recent posts copied into a feed when a friendship is accepted. */
const BACKFILL_LIMIT = 30;

/** Ceiling on viewers one post write may fan out to, per invocation. */
const MAX_FANOUT = 500;

/** Firestore's own limit on a single batched write. */
const BATCH_LIMIT = 400;

const ts = () => admin.firestore.FieldValue.serverTimestamp();

/** The derived id of a feed item. Deterministic, so writes are idempotent. */
function feedItemId(ownerUid, postId) {
  return `${ownerUid}__${postId}`;
}

/**
 * True when a `posts` document belongs in a feed.
 *
 * The same rule the profile grid applies (`_belongsInGrid` in
 * lib/profile/data/media_repository.dart), plus an explicit kind exclusion.
 *
 *   showInGrid === true   the direct statement of gallery eligibility. Note it
 *                         must be exactly true: RE Daily and other non-gallery
 *                         writers omit the field entirely, and the profile
 *                         grid's "absent means yes" default is a CLIENT-side
 *                         compatibility rule for old uploads, not something to
 *                         reproduce here where it would let every daily
 *                         summary card into the feed.
 *   mediaType             must be a type that can be rendered. A record with
 *                         the field missing or unknown is malformed, and
 *                         defaulting it to `image` is how a video URL ends up
 *                         in an image decoder.
 *   media present         a post with no URL and no Storage path has nothing
 *                         to show, whatever its other fields claim.
 *   type not re_daily     belt and braces. The two clauses above already
 *                         exclude every RE Daily record ever written, but the
 *                         cost of saying so is one comparison and the cost of
 *                         being wrong is a training summary in a photo feed.
 */
function isFeedEligiblePost(data) {
  if (!data || typeof data !== 'object') return false;
  if (typeof data.ownerUid !== 'string' || data.ownerUid.trim() === '') {
    return false;
  }
  if (data.showInGrid !== true) return false;
  const mediaType =
    typeof data.mediaType === 'string' ? data.mediaType.trim().toLowerCase() : '';
  if (!SUPPORTED_MEDIA.includes(mediaType)) return false;
  if (EXCLUDED_KINDS.includes(data.type)) return false;
  const hasMedia =
    (typeof data.smallUrl === 'string' && data.smallUrl !== '') ||
    (typeof data.thumbUrl === 'string' && data.thumbUrl !== '') ||
    (typeof data.storagePathOriginal === 'string' &&
      data.storagePathOriginal !== '');
  if (!hasMedia) return false;
  if (!data.createdAt) return false;
  return true;
}

/**
 * The feed row for a post: references and display metadata, never media.
 *
 * Owner identity — username, display name, avatar — is deliberately NOT copied
 * here. Denormalising it would mean a single username change rewriting every
 * feed row that account ever appeared in, across every friend, which is an
 * unbounded fan-out triggered by a rename. The client resolves identity once
 * per distinct owner per page from `users_public` instead, which is bounded by
 * the page size and cached, and which makes a rename or a new avatar appear
 * immediately with no backfill at all.
 */
function feedItemFrom(postId, data) {
  return {
    ownerUid: data.ownerUid,
    postId,
    createdAt: data.createdAt,
    mediaType: String(data.mediaType).trim().toLowerCase(),
    thumbUrl: typeof data.thumbUrl === 'string' ? data.thumbUrl : '',
    smallUrl: typeof data.smallUrl === 'string' ? data.smallUrl : '',
    storagePathOriginal:
      typeof data.storagePathOriginal === 'string'
        ? data.storagePathOriginal
        : '',
    thumbStoragePath:
      typeof data.thumbStoragePath === 'string' ? data.thumbStoragePath : '',
    caption: typeof data.caption === 'string' ? data.caption : '',
  };
}

/** Accepted uids added and removed between two assignment snapshots. */
function diffAcceptedUids(beforeData, afterData) {
  const before = new Set(M.acceptedUids(beforeData));
  const after = new Set(M.acceptedUids(afterData));
  const added = [...after].filter((uid) => !before.has(uid));
  const removed = [...before].filter((uid) => !after.has(uid));
  return { added, removed };
}

/** Commits [ops] in chunks Firestore will accept. */
async function commitAll(db, ops) {
  for (let i = 0; i < ops.length; i += BATCH_LIMIT) {
    const batch = db.batch();
    for (const op of ops.slice(i, i + BATCH_LIMIT)) {
      if (op.kind === 'set') batch.set(op.ref, op.data, { merge: false });
      else batch.delete(op.ref);
    }
    // eslint-disable-next-line no-await-in-loop
    await batch.commit();
  }
}

const graphRef = (db, uid) => db.collection(COL_GRAPH).doc(uid);
const feedRef = (db, viewerUid, itemId) =>
  db.collection(M.COL_USERS).doc(viewerUid).collection(SUB_FEED).doc(itemId);

/**
 * Recomputes `socialGraph/{uid}.friends` from the authority.
 *
 * Reads [uid]'s assignment document, then the counterpart document of every
 * account it lists as accepted, and keeps only the ones that accept back. One
 * read per candidate, on a friendship change only — never on a post write,
 * which is the path that has to stay cheap.
 *
 * Returns the friend sets before and after, so the caller can act on exactly
 * what changed.
 */
async function recomputeFriends(db, uid) {
  const [graphSnap, ownSnap] = await Promise.all([
    graphRef(db, uid).get(),
    db.collection(M.COL_ASSIGNMENTS).doc(uid).get(),
  ]);

  const previous = new Set(
    graphSnap.exists && Array.isArray(graphSnap.data().friends)
      ? graphSnap.data().friends
      : [],
  );

  const candidates = M.acceptedUids(ownSnap.exists ? ownSnap.data() : null);
  const counterparts = await Promise.all(
    candidates.map((other) =>
      db.collection(M.COL_ASSIGNMENTS).doc(other).get(),
    ),
  );

  const confirmed = [];
  candidates.forEach((other, i) => {
    const otherData = counterparts[i].exists ? counterparts[i].data() : null;
    if (M.isAccepted(M.entryFor(otherData, uid))) confirmed.push(other);
  });
  confirmed.sort();

  const next = new Set(confirmed);
  const changed =
    previous.size !== next.size || confirmed.some((u) => !previous.has(u));
  if (changed) {
    await graphRef(db, uid).set(
      { uid, friends: confirmed, updatedAt: ts() },
      { merge: false },
    );
  }
  return { previous, next };
}

/** Eligible recent posts by [ownerUid], newest first. */
async function recentEligiblePosts(db, ownerUid, limit) {
  const snap = await db
    .collection(COL_POSTS)
    .where('ownerUid', '==', ownerUid)
    .where('showInGrid', '==', true)
    .where('mediaType', 'in', SUPPORTED_MEDIA)
    .orderBy('createdAt', 'desc')
    .limit(limit)
    .get();
  return snap.docs.filter((d) => isFeedEligiblePost(d.data()));
}

/**
 * Copies a BOUNDED slice of [ownerUid]'s recent posts into [viewerUid]'s feed.
 *
 * Bounded on purpose. Accepting a request should show you what your new buddy
 * has been doing lately, not replay their entire history — an unbounded
 * backfill turns one tap into thousands of writes, and the older material is
 * reachable through their profile anyway.
 */
async function backfillInto(db, viewerUid, ownerUid) {
  const docs = await recentEligiblePosts(db, ownerUid, BACKFILL_LIMIT);
  const ops = docs.map((d) => ({
    kind: 'set',
    ref: feedRef(db, viewerUid, feedItemId(ownerUid, d.id)),
    data: { ...feedItemFrom(d.id, d.data()), indexedAt: ts() },
  }));
  await commitAll(db, ops);
  return ops.length;
}

/** Removes every feed row [viewerUid] holds for [ownerUid]'s posts. */
async function purgeFrom(db, viewerUid, ownerUid) {
  let removed = 0;
  for (;;) {
    // eslint-disable-next-line no-await-in-loop
    const snap = await db
      .collection(M.COL_USERS)
      .doc(viewerUid)
      .collection(SUB_FEED)
      .where('ownerUid', '==', ownerUid)
      .limit(BATCH_LIMIT)
      .get();
    if (snap.empty) break;
    // eslint-disable-next-line no-await-in-loop
    await commitAll(
      db,
      snap.docs.map((d) => ({ kind: 'delete', ref: d.ref })),
    );
    removed += snap.size;
    if (snap.size < BATCH_LIMIT) break;
  }
  return removed;
}

/** The viewers a post by [ownerUid] should reach: the owner and their friends. */
async function audienceFor(db, ownerUid) {
  const snap = await graphRef(db, ownerUid).get();
  const friends =
    snap.exists && Array.isArray(snap.data().friends) ? snap.data().friends : [];
  if (friends.length > MAX_FANOUT) {
    logger.warn(
      '[feed] %s has %d friends; fanning out to the first %d',
      ownerUid,
      friends.length,
      MAX_FANOUT,
    );
  }
  // The owner always sees their own post, whether or not they have friends.
  return [ownerUid, ...friends.slice(0, MAX_FANOUT)];
}

/**
 * Brings every viewer's feed into line with one post.
 *
 * Publishing, hiding (`showInGrid: false`), replacing and deleting all land
 * here, and all resolve to the same question asked once: is this post eligible
 * right now? If yes every viewer gets the current row; if no every viewer has
 * it removed. Nothing accumulates, so a replayed event is a no-op.
 */
async function syncPostToFeeds(db, postId, beforeData, afterData) {
  const data = afterData || beforeData;
  if (!data || typeof data.ownerUid !== 'string' || !data.ownerUid) {
    return { written: 0, removed: 0 };
  }
  const ownerUid = data.ownerUid;
  const eligible = isFeedEligiblePost(afterData);
  const viewers = await audienceFor(db, ownerUid);
  const itemId = feedItemId(ownerUid, postId);

  if (eligible) {
    const row = { ...feedItemFrom(postId, afterData), indexedAt: ts() };
    await commitAll(
      db,
      viewers.map((viewerUid) => ({
        kind: 'set',
        ref: feedRef(db, viewerUid, itemId),
        data: row,
      })),
    );
    return { written: viewers.length, removed: 0 };
  }

  await commitAll(
    db,
    viewers.map((viewerUid) => ({
      kind: 'delete',
      ref: feedRef(db, viewerUid, itemId),
    })),
  );
  return { written: 0, removed: viewers.length };
}

// ── Triggers ────────────────────────────────────────────────────────────────

/**
 * Keeps every feed in step with one post.
 *
 * `retry: true` is safe: the handler recomputes the desired state from the
 * post's current value and writes it under a derived id.
 */
const feedOnPostWritten = onDocumentWritten(
  { document: 'posts/{postId}', retry: true },
  async (event) => {
    const postId = event.params.postId;
    const before = event.data && event.data.before;
    const after = event.data && event.data.after;
    const beforeData = before && before.exists ? before.data() : null;
    const afterData = after && after.exists ? after.data() : null;
    try {
      const result = await syncPostToFeeds(
        admin.firestore(),
        postId,
        beforeData,
        afterData,
      );
      if (result.written || result.removed) {
        logger.info(
          '[feed] post %s → %d written, %d removed',
          postId,
          result.written,
          result.removed,
        );
      }
    } catch (err) {
      logger.error('[feed] post %s failed: %s', postId, err && err.message);
      throw err;
    }
  },
);

/**
 * Keeps the confirmed-friend projection and the feeds in step with a
 * friendship change.
 *
 * Fires on ANY write to an assignment document, which is what makes it correct
 * for the legacy client paths too: an old build that accepts or removes on one
 * side only still lands here, and the recomputation reads BOTH sides before
 * deciding. Counterparts whose membership changed are recomputed as well, so a
 * one-sided legacy write cannot leave the other person's projection stale.
 */
const feedOnBuddyAssignmentWritten = onDocumentWritten(
  { document: 'buddyAssignments/{ownerUid}', retry: true },
  async (event) => {
    const ownerUid = event.params.ownerUid;
    const before = event.data && event.data.before;
    const after = event.data && event.data.after;
    const beforeData = before && before.exists ? before.data() : null;
    const afterData = after && after.exists ? after.data() : null;
    const db = admin.firestore();

    const { added, removed } = diffAcceptedUids(beforeData, afterData);
    const affected = new Set([ownerUid, ...added, ...removed]);

    try {
      for (const uid of affected) {
        // eslint-disable-next-line no-await-in-loop
        const { previous, next } = await recomputeFriends(db, uid);
        const gained = [...next].filter((u) => !previous.has(u));
        const lost = [...previous].filter((u) => !next.has(u));

        for (const friendUid of gained) {
          // eslint-disable-next-line no-await-in-loop
          const count = await backfillInto(db, uid, friendUid);
          logger.info('[feed] backfilled %d posts from %s into %s', count, friendUid, uid);
        }
        for (const exFriendUid of lost) {
          // eslint-disable-next-line no-await-in-loop
          const count = await purgeFrom(db, uid, exFriendUid);
          logger.info('[feed] purged %d posts by %s from %s', count, exFriendUid, uid);
        }
      }
    } catch (err) {
      logger.error(
        '[feed] assignment %s failed: %s',
        ownerUid,
        err && err.message,
      );
      throw err;
    }
  },
);

module.exports = {
  COL_GRAPH,
  SUB_FEED,
  SUPPORTED_MEDIA,
  EXCLUDED_KINDS,
  BACKFILL_LIMIT,
  MAX_FANOUT,
  feedItemId,
  isFeedEligiblePost,
  feedItemFrom,
  diffAcceptedUids,
  recomputeFriends,
  recentEligiblePosts,
  backfillInto,
  purgeFrom,
  audienceFor,
  syncPostToFeeds,
  feedOnPostWritten,
  feedOnBuddyAssignmentWritten,
};
