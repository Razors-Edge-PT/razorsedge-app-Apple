// The activity record: identity, shape, and what it must never do.
'use strict';

const test = require('node:test');
const assert = require('node:assert');

const A = require('../push/activity');
const P = require('../push/push_model');

const OWNER = 'owner-uid';

test('a record id is derived from the interaction, not from the event', () => {
  const occurrence = P.postOccurrence({ kind: 'like', postId: 'p1', actorUid: 'u2' });
  const first = A.activityIdFor(P.PushType.POST_LIKE, OWNER, occurrence);
  const replay = A.activityIdFor(P.PushType.POST_LIKE, OWNER, occurrence);
  assert.equal(first, replay, 'a replayed event finds its own record');
  assert.match(first, /^pl_[0-9a-f]{40}$/);

  // Different person, post, type or recipient — all different records.
  assert.notEqual(first, A.activityIdFor(P.PushType.POST_LIKE, 'someone-else', occurrence));
  assert.notEqual(first, A.activityIdFor(P.PushType.POST_GOOD_LIFT, OWNER, occurrence));
  assert.notEqual(
    first,
    A.activityIdFor(P.PushType.POST_LIKE, OWNER,
      P.postOccurrence({ kind: 'like', postId: 'p1', actorUid: 'u3' })),
  );
});

test('every type that produces a record has an id prefix', () => {
  for (const type of [P.PushType.POST_COMMENT, P.PushType.POST_LIKE,
    P.PushType.POST_GOOD_LIFT, P.PushType.DM_REACTION]) {
    assert.ok(A.activityIdFor(type, OWNER, 'x'), type);
  }
  // A friend request is not an interaction with content: it has its own
  // existing surface (the Buddy Hub), and no activity record.
  assert.throws(() => A.activityIdFor(P.PushType.FRIEND_REQUEST, OWNER, 'x'));
});

test('the subject says what reading this interaction means reading', () => {
  assert.equal(A.subjectOf({ type: P.PushType.POST_COMMENT, postId: 'p1' }), 'post:p1');
  assert.equal(A.subjectOf({ type: P.PushType.POST_LIKE, postId: 'p1' }), 'post:p1');
  assert.equal(A.subjectOf({ type: P.PushType.DM_REACTION, conversationId: 'a_b' }), 'dm:a_b');
});

test('a record starts unread and carries its own alert tag', () => {
  const record = A.activityRecord({
    type: P.PushType.POST_COMMENT,
    actorUid: 'u2',
    occurrence: 'post|p1|comment|c1',
    postId: 'p1',
    commentId: 'c1',
    preview: '  nice   work  ',
    tag: 'post|abc12345|pc_x',
    now: 'SERVER_TIME',
  });
  assert.equal(record.read, false);
  assert.equal(record.type, P.PushType.POST_COMMENT);
  assert.equal(record.actorUid, 'u2');
  assert.equal(record.subject, 'post:p1');
  assert.equal(record.commentId, 'c1');
  assert.equal(record.preview, 'nice work', 'whitespace collapsed for the list');
  assert.equal(record.tag, 'post|abc12345|pc_x');
  assert.equal(record.createdAt, 'SERVER_TIME');
  assert.ok(!('readAt' in record));
});

test('a long comment is truncated before it is stored', () => {
  const long = 'x'.repeat(400);
  const record = A.activityRecord({
    type: P.PushType.POST_COMMENT, actorUid: 'u2', occurrence: 'o', postId: 'p1',
    commentId: 'c1', preview: long, now: 1,
  });
  assert.ok(record.preview.length <= A.PREVIEW_MAX, 'bounded');
  assert.ok(record.preview.endsWith('…'));
});

test('a record says outright that it is valid', () => {
  const record = A.activityRecord({
    type: P.PushType.POST_LIKE, actorUid: 'u2', occurrence: 'o', postId: 'p1', now: 1,
  });
  // Written rather than absent, so a withdrawal is a field CHANGING and the
  // field can be queried on.
  assert.equal(record.invalidated, false);
});

test('a withdrawn interaction is invalidated, never deleted and never re-read',
  async () => {
    const writes = [];
    const db = {
      collection: () => ({
        doc: () => ({
          collection: () => ({
            doc: () => ({
              async update(patch) { writes.push(patch); },
            }),
          }),
        }),
      }),
    };
    assert.equal(await A.retireActivity(db, OWNER, 'pl_x', 'reaction-withdrawn'), true);
    assert.equal(writes.length, 1);
    assert.equal(writes[0].invalidated, true);
    assert.equal(writes[0].invalidReason, 'reaction-withdrawn');
    // `read` is left exactly as it was: an interaction that comes back comes
    // back as it was, not as freshly unread and not as silently read.
    assert.ok(!('read' in writes[0]), 'read state is not touched');
    assert.ok(!('readAt' in writes[0]));
  });

test('retiring what was never recorded is a no-op, not a failure', async () => {
  const notFound = Object.assign(new Error('NOT_FOUND'), { code: 5 });
  const db = {
    collection: () => ({
      doc: () => ({
        collection: () => ({
          doc: () => ({ async update() { throw notFound; } }),
        }),
      }),
    }),
  };
  assert.equal(await A.retireActivity(db, OWNER, 'pl_missing', 'x'), false);
  assert.equal(await A.refreshActivity(db, OWNER, 'pl_missing', { emoji: '🔥' }), false);
});

test('a refresh writes only the wording that changed', async () => {
  const writes = [];
  const db = {
    collection: () => ({
      doc: () => ({
        collection: () => ({
          doc: () => ({ async update(patch) { writes.push(patch); } }),
        }),
      }),
    }),
  };
  await A.refreshActivity(db, OWNER, 'pc_x', { preview: '  fixed   typo ' });
  assert.deepEqual(writes[0], { preview: 'fixed typo' });
  await A.refreshActivity(db, OWNER, 'dr_x', { emoji: '❤️' });
  assert.deepEqual(writes[1], { emoji: '❤️' });
  // Nothing to say: nothing written, and no claim that anything was.
  assert.equal(await A.refreshActivity(db, OWNER, 'dr_x', {}), false);
  assert.equal(writes.length, 2);
});

test('empty optional fields are left out rather than stored as blanks', () => {
  const record = A.activityRecord({
    type: P.PushType.POST_LIKE, actorUid: 'u2', occurrence: 'o', postId: 'p1', now: 1,
  });
  assert.ok(!('commentId' in record));
  assert.ok(!('preview' in record));
  assert.ok(!('emoji' in record));
  assert.ok(!('conversationId' in record));
});
