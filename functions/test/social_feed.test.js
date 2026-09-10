'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const feed = require('../social/feed');

const post = (over) => ({
  ownerUid: 'owner',
  showInGrid: true,
  mediaType: 'image',
  smallUrl: 'https://example.test/a.jpg?alt=media&token=abc',
  thumbUrl: 'https://example.test/a_thumb.jpg',
  storagePathOriginal: 'users/owner/posts/m1/original.jpg',
  createdAt: { seconds: 1, nanoseconds: 0 },
  ...over,
});

// ── Eligibility ─────────────────────────────────────────────────────────────

test('feed: a valid gallery post is eligible', () => {
  assert.equal(feed.isFeedEligiblePost(post()), true);
  assert.equal(feed.isFeedEligiblePost(post({ mediaType: 'video' })), true);
  assert.equal(feed.isFeedEligiblePost(post({ mediaType: 'IMAGE' })), true);
});

test('feed: an RE Daily card never reaches the feed', () => {
  // RE Daily writes ownerUid + createdAt and NO media, on every training day.
  // Left in, it would be the majority of the feed.
  assert.equal(
    feed.isFeedEligiblePost({
      ownerUid: 'owner',
      type: 're_daily',
      createdAt: { seconds: 1 },
      dailyTotal: 42,
    }),
    false,
  );
  // Even one carrying every other valid field is excluded by kind alone.
  assert.equal(feed.isFeedEligiblePost(post({ type: 're_daily' })), false);
});

test('feed: a hidden post is excluded', () => {
  assert.equal(feed.isFeedEligiblePost(post({ showInGrid: false })), false);
});

test('feed: a post with no showInGrid is excluded', () => {
  // The profile grid treats an ABSENT field as "yes" for pre-1.7.13 uploads.
  // Reproducing that here would admit every RE Daily record ever written, so
  // the server requires the field to be exactly true.
  const p = post();
  delete p.showInGrid;
  assert.equal(feed.isFeedEligiblePost(p), false);
});

test('feed: a malformed or unknown media type is excluded', () => {
  for (const mediaType of [undefined, '', 'gif', 'application/pdf', 42, null]) {
    assert.equal(
      feed.isFeedEligiblePost(post({ mediaType })),
      false,
      `admitted mediaType ${JSON.stringify(mediaType)}`,
    );
  }
});

test('feed: a post with no media at all is excluded', () => {
  assert.equal(
    feed.isFeedEligiblePost(
      post({ smallUrl: '', thumbUrl: '', storagePathOriginal: '' }),
    ),
    false,
  );
});

test('feed: a post with no owner or no timestamp is excluded', () => {
  assert.equal(feed.isFeedEligiblePost(post({ ownerUid: '' })), false);
  assert.equal(feed.isFeedEligiblePost(post({ ownerUid: null })), false);
  assert.equal(feed.isFeedEligiblePost(post({ createdAt: null })), false);
  assert.equal(feed.isFeedEligiblePost(null), false);
  assert.equal(feed.isFeedEligiblePost('nope'), false);
});

// ── Item shape ──────────────────────────────────────────────────────────────

test('feed: the item id is derived, so writes are idempotent', () => {
  assert.equal(feed.feedItemId('owner', 'p1'), 'owner__p1');
  assert.equal(feed.feedItemId('owner', 'p1'), feed.feedItemId('owner', 'p1'));
});

test('feed: the row carries references, never media bytes', () => {
  const row = feed.feedItemFrom('p1', post({ caption: 'PB day' }));
  assert.equal(row.postId, 'p1');
  assert.equal(row.ownerUid, 'owner');
  assert.equal(row.caption, 'PB day');
  assert.equal(row.storagePathOriginal, 'users/owner/posts/m1/original.jpg');
  // Nothing that could be a copy of the object itself.
  for (const key of Object.keys(row)) {
    const v = row[key];
    assert.ok(
      typeof v !== 'string' || v.length < 2048,
      `field ${key} looks like inlined media`,
    );
    assert.ok(
      typeof v !== 'string' || !v.startsWith('data:'),
      `field ${key} inlined a data URI`,
    );
  }
});

test('feed: the row does not denormalise owner identity', () => {
  // Copying username/avatar into every row would make one rename an unbounded
  // fan-out. The client resolves identity per distinct owner per page instead.
  const row = feed.feedItemFrom('p1', post({ username: 'lifter', photoURL: 'x' }));
  assert.equal(row.username, undefined);
  assert.equal(row.displayName, undefined);
  assert.equal(row.photoURL, undefined);
});

test('feed: missing optional string fields become empty, never undefined', () => {
  // An undefined value is rejected by Firestore on write.
  const bare = {
    ownerUid: 'owner',
    showInGrid: true,
    mediaType: 'video',
    storagePathOriginal: 'users/owner/posts/m2/original.mp4',
    createdAt: { seconds: 5 },
  };
  const row = feed.feedItemFrom('p2', bare);
  for (const [k, v] of Object.entries(row)) {
    assert.notEqual(v, undefined, `field ${k} was undefined`);
  }
  assert.equal(row.caption, '');
  assert.equal(row.thumbUrl, '');
});

// ── Friendship diffing ──────────────────────────────────────────────────────

const assign = (entries) => ({ athletes: entries });
const A = { status: 'accepted' };
const P = { status: 'pending' };

test('feed: accepted additions and removals are detected', () => {
  const { added, removed } = feed.diffAcceptedUids(
    assign({ x: A, y: A }),
    assign({ y: A, z: A }),
  );
  assert.deepEqual(added, ['z']);
  assert.deepEqual(removed, ['x']);
});

test('feed: a pending entry becoming accepted counts as added', () => {
  const { added, removed } = feed.diffAcceptedUids(assign({ x: P }), assign({ x: A }));
  assert.deepEqual(added, ['x']);
  assert.deepEqual(removed, []);
});

test('feed: a deleted assignment document removes everyone', () => {
  const { added, removed } = feed.diffAcceptedUids(assign({ x: A, y: A }), null);
  assert.deepEqual(added, []);
  assert.deepEqual(removed.sort(), ['x', 'y']);
});

test('feed: an unchanged document produces no work', () => {
  const { added, removed } = feed.diffAcceptedUids(assign({ x: A }), assign({ x: A }));
  assert.deepEqual(added, []);
  assert.deepEqual(removed, []);
});

test('feed: backfill and fan-out stay bounded', () => {
  // The numbers themselves are the guarantee: an unbounded backfill turns one
  // tap into thousands of writes.
  assert.ok(feed.BACKFILL_LIMIT > 0 && feed.BACKFILL_LIMIT <= 100);
  assert.ok(feed.MAX_FANOUT > 0 && feed.MAX_FANOUT <= 5000);
});
