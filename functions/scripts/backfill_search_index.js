#!/usr/bin/env node
'use strict';

// Builds `userSearchIndex/{uid}` for accounts that already exist.
//
// WHY THIS EXISTS
//   searchIndexOnPublicProfileWritten maintains the search projection from
//   `users_public`, but it only fires when a public profile is WRITTEN. Every
//   account that existed before the function was deployed has no index document
//   and is therefore invisible to buddy search until the next time its owner
//   happens to edit their profile. This walks `users_public` once and indexes
//   what is already there.
//
// SAFETY CONTRACT
//   * READ-ONLY on `users_public`. The source of truth is never modified; the
//     only collection written is `userSearchIndex`.
//   * Uses syncSearchIndex() from functions/social/search_index.js — the SAME
//     function the trigger uses. There is no second copy of the projection
//     logic here to drift from it, so a backfilled document is byte-for-byte
//     what the trigger would have written.
//   * Idempotent. The document is derived from the current public profile and
//     replaced, never accumulated. A run that would change nothing writes
//     nothing, so re-running is cheap and safe.
//   * An account with nothing to match on, and a deleted account, produce a
//     DELETE of any stale index document rather than a nameless row.
//
// ORDER OF OPERATIONS
//   Deploy the rules (userSearchIndex is client-read, server-write) and the
//   functions first, then run this with --apply, then --verify. Search returns
//   nothing for un-indexed accounts until it has run; it never returns wrong
//   results, so it is safe to run after the client ships.
//
// Modes:
//   (default)  dry-run — report what each account would produce, write nothing
//   --apply            — write the index documents
//   --verify           — recompute and report any account whose index is stale
//
// Credentials come from GOOGLE_APPLICATION_CREDENTIALS or the ambient service
// account.

const admin = require('firebase-admin');

const {
  SEARCH_INDEX,
  buildSearchIndexDoc,
  sameIndexDoc,
  syncSearchIndex,
} = require('../social/search_index');

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const SOURCE = 'users_public';
const PAGE = 400;

function usage() {
  return [
    'Backfill the buddy-search projection (userSearchIndex)',
    '',
    'Dry run (default — writes nothing):',
    '  node scripts/backfill_search_index.js --project goodlift-us-storage',
    '',
    'Dry run for one account:',
    '  node scripts/backfill_search_index.js --project goodlift-us-storage --uid <uid>',
    '',
    'Apply:',
    '  node scripts/backfill_search_index.js --project goodlift-us-storage --apply',
    '',
    'Verify every published index matches a fresh recomputation:',
    '  node scripts/backfill_search_index.js --project goodlift-us-storage --verify',
    '',
    'Reads users_public only; writes userSearchIndex only.',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    uid: null,
    apply: false,
    verify: false,
    limit: 0,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--uid') out.uid = argv[++i];
    else if (arg === '--limit') out.limit = Number(argv[++i]) || 0;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (out.apply && out.verify) {
    throw new Error('Choose --apply or --verify, not both.');
  }
  return out;
}

/** Yields every public profile, or just the one named by [uid]. */
async function* publicProfiles(db, { uid, limit }) {
  if (uid) {
    const snap = await db.collection(SOURCE).doc(uid).get();
    yield { uid, data: snap.exists ? snap.data() : null };
    return;
  }

  let cursor = null;
  let seen = 0;
  for (;;) {
    let q = db
      .collection(SOURCE)
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(PAGE);
    if (cursor) q = q.startAfter(cursor);
    // eslint-disable-next-line no-await-in-loop
    const snap = await q.get();
    if (snap.empty) return;
    for (const doc of snap.docs) {
      yield { uid: doc.id, data: doc.data() };
      seen += 1;
      if (limit && seen >= limit) return;
    }
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGE) return;
  }
}

/**
 * What one account's index SHOULD be, compared against what it is.
 *
 * The comparison is [sameIndexDoc], the same field-by-field test the trigger
 * uses to decide whether a write is needed — so "stale" here means exactly what
 * "would write" means there.
 */
async function inspect(db, uid, publicData) {
  const next = buildSearchIndexDoc(uid, publicData);
  const existing = await db.collection(SEARCH_INDEX).doc(uid).get();

  if (next === null) {
    return existing.exists ? 'would_delete' : 'not_indexable';
  }
  if (!existing.exists) return 'would_create';
  return sameIndexDoc(existing.data(), next) ? 'current' : 'would_update';
}

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

  const mode = args.apply ? 'APPLY' : args.verify ? 'VERIFY' : 'DRY RUN';
  process.stdout.write(
    `backfill_search_index — ${mode} on ${args.projectId}\n\n`,
  );

  const counts = {
    scanned: 0,
    written: 0,
    deleted: 0,
    unchanged: 0,
    would_create: 0,
    would_update: 0,
    would_delete: 0,
    not_indexable: 0,
    current: 0,
  };
  const errors = [];
  const stale = [];

  for await (const { uid, data } of publicProfiles(db, args)) {
    counts.scanned += 1;
    try {
      if (args.apply) {
        // The trigger's own function, so a backfilled document and a
        // trigger-written one are identical by construction.
        const result = await syncSearchIndex(db, uid, data);
        if (result === 'written') counts.written += 1;
        else if (result === 'deleted') counts.deleted += 1;
        else counts.unchanged += 1;
      } else {
        const verdict = await inspect(db, uid, data);
        counts[verdict] += 1;
        if (args.verify && verdict !== 'current' && verdict !== 'not_indexable') {
          stale.push({ uid, verdict });
        }
      }
    } catch (err) {
      errors.push({ uid, message: err.message });
    }
    if (counts.scanned % 500 === 0) {
      process.stdout.write(`  ... ${counts.scanned} scanned\n`);
    }
  }

  process.stdout.write(`\npublic profiles scanned : ${counts.scanned}\n`);
  if (args.apply) {
    process.stdout.write(`index documents written : ${counts.written}\n`);
    process.stdout.write(`index documents deleted : ${counts.deleted}\n`);
    process.stdout.write(`already current         : ${counts.unchanged}\n`);
  } else {
    process.stdout.write(`would create            : ${counts.would_create}\n`);
    process.stdout.write(`would update            : ${counts.would_update}\n`);
    process.stdout.write(`would delete (stale)    : ${counts.would_delete}\n`);
    process.stdout.write(`already current         : ${counts.current}\n`);
    process.stdout.write(
      `not indexable           : ${counts.not_indexable} ` +
        '(no username and no name — never findable, by design)\n',
    );
  }
  process.stdout.write(`errors                  : ${errors.length}\n`);

  for (const e of errors.slice(0, 20)) {
    process.stderr.write(`  ${e.uid}: ${e.message}\n`);
  }
  if (errors.length > 20) {
    process.stderr.write(`  ... and ${errors.length - 20} more\n`);
  }

  if (args.verify) {
    if (stale.length === 0 && errors.length === 0) {
      process.stdout.write('\nVERIFY OK — every indexable account is current.\n');
    } else {
      process.stdout.write(
        `\nVERIFY FAILED — ${stale.length} account(s) out of date. Run --apply.\n`,
      );
      for (const s of stale.slice(0, 20)) {
        process.stdout.write(`  ${s.uid}: ${s.verdict}\n`);
      }
      process.exitCode = 1;
    }
    return;
  }

  if (errors.length > 0) {
    process.exitCode = 1;
    return;
  }

  process.stdout.write(
    args.apply
      ? '\nDone. Re-run with --verify to confirm.\n'
      : '\nDRY RUN — nothing was written. Re-run with --apply.\n',
  );
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`${err && err.stack ? err.stack : err}\n`);
    process.exitCode = 1;
  });
}

module.exports = { inspect, publicProfiles };
