#!/usr/bin/env node
'use strict';

// Read-only verification of the server-maintained social projections against
// the authority.
//
// WHY THIS IS SEPARATE FROM THE REPAIR TOOL
//   symmetrise_buddy_assignments verifies the AUTHORITY — the buddyAssignments
//   documents. It says nothing about whether the projections the app actually
//   reads agree with it. `socialGraph/{uid}.friends` and `users/{uid}/feed` are
//   written by feedOnBuddyAssignmentWritten and feedOnPostWritten, which are
//   asynchronous: after a friendship changes there is a window in which the
//   authority is right and the projections are stale.
//
//   So this walks both, compares them to the authority, and reports the
//   difference. It polls for a bounded time rather than assuming the triggers
//   have caught up, and it gives up and reports rather than waiting forever.
//
// SAFETY
//   Reads only. There is no write path in this file at all — no set, update,
//   delete or batch — and no flag that introduces one.
//
// Usage:
//   node scripts/verify_social_projections.js --project goodlift-us-storage
//   node scripts/verify_social_projections.js --project ... --uids a,b,c
//   node scripts/verify_social_projections.js --project ... --wait 120
//   node scripts/verify_social_projections.js --project ... --json

const admin = require('firebase-admin');

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const COL_ASSIGNMENTS = 'buddyAssignments';
const COL_GRAPH = 'socialGraph';
const COL_USERS = 'users';
const SUB_FEED = 'feed';

function usage() {
  return [
    'Verify socialGraph and feed projections against buddyAssignments',
    '',
    '  node scripts/verify_social_projections.js --project goodlift-us-storage',
    '',
    'Options:',
    '  --uids a,b,c   restrict the per-account detail to these uids',
    '  --wait N       poll up to N seconds for async triggers to settle (default 90)',
    '  --json         emit a machine-readable snapshot as well',
    '',
    'Read-only. This script has no write path.',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    uids: [],
    waitSeconds: 90,
    json: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--uids') {
      out.uids = String(argv[++i] || '')
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean);
    } else if (arg === '--wait') out.waitSeconds = Number(argv[++i]) || 0;
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return out;
}

const athletesOf = (d) =>
  d && d.athletes && typeof d.athletes === 'object' ? d.athletes : {};

const isAccepted = (e) =>
  !!e && typeof e === 'object' && e.status === 'accepted';

/**
 * The authoritative mutual-friend map, computed the way the rules decide it.
 *
 * Both documents must name the other as accepted. This is the same test
 * firestore.rules isBuddyOf() applies, so what this returns is what the rules
 * will actually permit — not an approximation of it.
 */
async function readAuthority(db) {
  const snap = await db.collection(COL_ASSIGNMENTS).get();
  const accepted = new Map(); // uid -> Set(uids it accepts)
  for (const doc of snap.docs) {
    const set = new Set();
    const athletes = athletesOf(doc.data());
    for (const other of Object.keys(athletes)) {
      if (other !== doc.id && isAccepted(athletes[other])) set.add(other);
    }
    accepted.set(doc.id, set);
  }

  const mutual = new Map(); // uid -> sorted array of confirmed friends
  for (const [uid, set] of accepted) {
    const confirmed = [...set].filter((other) => {
      const back = accepted.get(other);
      return back ? back.has(uid) : false;
    });
    mutual.set(uid, confirmed.sort());
  }
  return { accepted, mutual, documents: snap.size };
}

/** `socialGraph/{uid}.friends` for every account the authority mentions. */
async function readGraph(db, uids) {
  const out = new Map();
  const list = [...uids];
  for (let i = 0; i < list.length; i += 200) {
    const chunk = list.slice(i, i + 200);
    // eslint-disable-next-line no-await-in-loop
    const snaps = await db.getAll(
      ...chunk.map((u) => db.collection(COL_GRAPH).doc(u)),
    );
    snaps.forEach((snap, n) => {
      const d = snap.exists ? snap.data() || {} : {};
      const friends = Array.isArray(d.friends)
        ? d.friends.filter((f) => typeof f === 'string').sort()
        : null;
      out.set(chunk[n], { exists: snap.exists, friends });
    });
  }
  return out;
}

/** Distinct post owners appearing in each viewer's feed. */
async function readFeedOwners(db, uids) {
  const out = new Map();
  for (const uid of uids) {
    // eslint-disable-next-line no-await-in-loop
    const snap = await db
      .collection(COL_USERS)
      .doc(uid)
      .collection(SUB_FEED)
      .get();
    const owners = new Map();
    for (const doc of snap.docs) {
      const owner = (doc.data() || {}).ownerUid;
      if (typeof owner !== 'string' || !owner) continue;
      owners.set(owner, (owners.get(owner) || 0) + 1);
    }
    out.set(uid, { rows: snap.size, owners });
  }
  return out;
}

/**
 * Every disagreement between the authority and the projections.
 *
 * A feed row whose owner is neither the viewer nor a confirmed friend is the
 * one that matters most: it is content the viewer can still see listed after
 * the friendship ended.
 */
function diff({ mutual, graph, feeds }) {
  const graphMismatches = [];
  const feedLeaks = [];

  for (const [uid, friends] of mutual) {
    const g = graph.get(uid);
    const projected = g && g.friends ? g.friends : [];
    const expected = friends;
    const same =
      projected.length === expected.length &&
      projected.every((f, i) => f === expected[i]);
    if (!same) {
      graphMismatches.push({
        uid,
        expected,
        projected,
        graphExists: !!(g && g.exists),
      });
    }
  }

  for (const [uid, feed] of feeds) {
    const allowed = new Set([uid, ...(mutual.get(uid) || [])]);
    for (const [owner, rows] of feed.owners) {
      if (!allowed.has(owner)) {
        feedLeaks.push({ viewerUid: uid, ownerUid: owner, rows });
      }
    }
  }

  return { graphMismatches, feedLeaks };
}

const sleep = (ms) =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`${err.message}\n\n${usage()}\n`);
    process.exitCode = 2;
    return;
  }
  if (args.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }

  admin.initializeApp({ projectId: args.projectId });
  const db = admin.firestore();

  process.stdout.write(
    `verify_social_projections — READ-ONLY on ${args.projectId}\n\n`,
  );

  const deadline = Date.now() + args.waitSeconds * 1000;
  let attempt = 0;
  let authority;
  let graph;
  let feeds;
  let result;

  // Triggers are asynchronous. Poll until the projections agree or the budget
  // runs out — never indefinitely, and report the last state either way.
  for (;;) {
    attempt += 1;
    // eslint-disable-next-line no-await-in-loop
    authority = await readAuthority(db);
    const uids = [...authority.mutual.keys()];
    // eslint-disable-next-line no-await-in-loop
    graph = await readGraph(db, uids);
    // eslint-disable-next-line no-await-in-loop
    feeds = await readFeedOwners(db, uids);
    result = diff({ mutual: authority.mutual, graph, feeds });

    const clean =
      result.graphMismatches.length === 0 && result.feedLeaks.length === 0;
    if (clean || Date.now() >= deadline) break;

    process.stdout.write(
      `  attempt ${attempt}: ${result.graphMismatches.length} graph mismatch(es), ` +
        `${result.feedLeaks.length} stale feed owner(s) — waiting for triggers...\n`,
    );
    // eslint-disable-next-line no-await-in-loop
    await sleep(5000);
  }

  const mutualPairs = new Set();
  for (const [uid, friends] of authority.mutual) {
    for (const f of friends) {
      mutualPairs.add(uid < f ? `${uid}|${f}` : `${f}|${uid}`);
    }
  }

  process.stdout.write(`assignment documents      : ${authority.documents}\n`);
  process.stdout.write(`mutual pairs (authority)  : ${mutualPairs.size}\n`);
  process.stdout.write(`accounts with a projection: ${
    [...graph.values()].filter((g) => g.exists).length
  }\n`);
  process.stdout.write(`polling attempts          : ${attempt}\n\n`);

  const focus = args.uids.length > 0 ? args.uids : [];
  if (focus.length > 0) {
    process.stdout.write('per-account detail:\n');
    for (const uid of focus) {
      const expected = authority.mutual.get(uid) || [];
      const g = graph.get(uid);
      const f = feeds.get(uid);
      process.stdout.write(`  ${uid}\n`);
      process.stdout.write(
        `    authority friends : ${expected.length ? expected.join(', ') : '(none)'}\n`,
      );
      process.stdout.write(
        `    socialGraph       : ${
          g && g.exists
            ? g.friends && g.friends.length
              ? g.friends.join(', ')
              : '(empty)'
            : '(no document)'
        }\n`,
      );
      process.stdout.write(
        `    feed rows         : ${f ? f.rows : 0}` +
          `${f && f.owners.size ? ` from ${[...f.owners.keys()].join(', ')}` : ''}\n`,
      );
    }
    process.stdout.write('\n');
  }

  if (result.graphMismatches.length > 0) {
    process.stdout.write('socialGraph MISMATCHES:\n');
    for (const m of result.graphMismatches) {
      process.stdout.write(
        `  ${m.uid}\n    expected: ${m.expected.join(', ') || '(none)'}\n` +
          `    stored  : ${
            m.graphExists ? m.projected.join(', ') || '(empty)' : '(no document)'
          }\n`,
      );
    }
  }

  if (result.feedLeaks.length > 0) {
    process.stdout.write('\nSTALE FEED ROWS (owner is not self or a friend):\n');
    for (const l of result.feedLeaks) {
      process.stdout.write(
        `  viewer ${l.viewerUid} still holds ${l.rows} row(s) by ${l.ownerUid}\n`,
      );
    }
  }

  if (args.json) {
    process.stdout.write(
      `\nJSON ${JSON.stringify({
        mutualPairs: [...mutualPairs].sort(),
        graphMismatches: result.graphMismatches,
        feedLeaks: result.feedLeaks,
      })}\n`,
    );
  }

  const clean =
    result.graphMismatches.length === 0 && result.feedLeaks.length === 0;
  if (clean) {
    process.stdout.write(
      '\nPROJECTIONS OK — socialGraph agrees with the authority everywhere,\n' +
        'and no feed holds a row by a non-friend.\n',
    );
  } else {
    process.stdout.write(
      '\nPROJECTIONS OUT OF SYNC — see above. If the triggers are healthy this\n' +
        'resolves on its own; if it persists, check the function logs.\n',
    );
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`${err && err.stack ? err.stack : err}\n`);
    process.exitCode = 1;
  });
}

module.exports = { athletesOf, isAccepted, readAuthority, diff };
