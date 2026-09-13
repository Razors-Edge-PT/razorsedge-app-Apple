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
});

// ── Settling against current state ──────────────────────────────────────────
// The stub is deliberately a real little store: these are the rules that stop
// a redelivered or out-of-order event from lying about what exists.

function stubDb({ record, live }) {
  const writes = [];
  const snapOf = (data) => ({
    exists: data != null,
    data: () => data,
    get: (k) => (data == null ? undefined : data[k]),
  });
  const recordRef = { __kind: 'record' };
  const liveRef = { __kind: 'live' };
  const db = {
    collection: () => ({
      doc: () => ({ collection: () => ({ doc: () => recordRef }) }),
    }),
    liveRef,
    writes,
    async runTransaction(fn) {
      return fn({
        async get(ref) {
          return snapOf(ref === recordRef ? record : live);
        },
        update(ref, patch) {
          writes.push(patch);
          Object.assign(record, patch);
        },
      });
    },
  };
  return db;
}

test('an interaction that is gone retires its record, whatever the event said',
  async () => {
    const record = { read: false, invalidated: false, preview: 'nice' };
    const db = stubDb({ record, live: null });
    const out = await A.settleActivity(db, {
      recipientUid: OWNER,
      activityId: 'pc_x',
      canonical: { ref: db.liveRef, state: (s) => ({ present: s.exists }) },
      reason: 'comment-deleted',
    });
    assert.equal(out, 'retired');
    assert.equal(record.invalidated, true);
    // Read state is never touched: an interaction that comes back comes back
    // as it was.
    assert.equal(record.read, false);
    assert.ok(!('readAt' in record));
  });

test('an interaction that is THERE revives its record and never re-alerts',
  async () => {
    const record = { read: true, invalidated: true, preview: 'nice' };
    const db = stubDb({ record, live: { text: 'nice' } });
    const out = await A.settleActivity(db, {
      recipientUid: OWNER,
      activityId: 'pc_x',
      canonical: {
        ref: db.liveRef,
        state: (s) => ({ present: s.exists, preview: (s.data() || {}).text }),
      },
    });
    assert.equal(out, 'revived');
    assert.equal(record.invalidated, false);
    assert.equal(record.read, true, 'still read — reviving is not re-announcing');
  });

test('wording comes from the live document, so a stale event cannot undo an edit',
  async () => {
    const record = { read: false, invalidated: false, preview: 'the new words' };
    const db = stubDb({ record, live: { text: 'the new words' } });
    // An OLD edit event is replayed. Nothing about it reaches the record: the
    // only text considered is the one the comment currently has.
    const out = await A.settleActivity(db, {
      recipientUid: OWNER,
      activityId: 'pc_x',
      canonical: {
        ref: db.liveRef,
        state: (s) => ({ present: s.exists, preview: (s.data() || {}).text }),
      },
    });
    assert.equal(out, 'unchanged');
    assert.equal(record.preview, 'the new words');
    assert.equal(db.writes.length, 0, 'nothing to say, nothing written');
  });

test('a changed emoji is refreshed in place', async () => {
  const record = { read: false, invalidated: false, emoji: '🔥' };
  const db = stubDb({ record, live: { reactions: { u2: '❤️' } } });
  const out = await A.settleActivity(db, {
    recipientUid: OWNER,
    activityId: 'dr_x',
    canonical: {
      ref: db.liveRef,
      state: (s) => {
        const e = ((s.data() || {}).reactions || {}).u2;
        return e ? { present: true, emoji: e } : { present: false };
      },
    },
  });
  assert.equal(out, 'refreshed');
  assert.equal(record.emoji, '❤️');
});

test('a record that was never written is not invented by settling', async () => {
  const db = stubDb({ record: null, live: null });
  assert.equal(
    await A.settleActivity(db, {
      recipientUid: OWNER,
      activityId: 'pl_missing',
      canonical: { ref: db.liveRef, state: (s) => ({ present: s.exists }) },
    }),
    'no-record',
  );
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
