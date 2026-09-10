#!/usr/bin/env node
'use strict';

// Repairs one-sided buddyAssignments so the tightened, MUTUAL isBuddyOf() rule
// does not silently unfriend people who really are friends.
//
// WHY THIS EXISTS
//   firestore.rules and storage.rules used to accept a friendship claimed by
//   EITHER side:
//
//       buddyAssignments/A.athletes[B].accepted  OR
//       buddyAssignments/B.athletes[A].accepted
//
//   and buddyAssignments/{ownerUid} lets the owner write their own document.
//   Together that made friendship self-assertable: any signed-in account could
//   write `athletes.{victim} = {status:'accepted'}` into its OWN document and
//   immediately read the victim's posts, stories, lift videos and Storage
//   media. Both rule files now require BOTH sides, which closes it, because an
//   account can only ever write its own side.
//
//   The cost is that a genuinely-accepted pair whose reciprocal write was lost
//   — the old accept path wrote only one side — now reads as not-friends. This
//   script adds the missing side for exactly those pairs, and nothing else.
//
// SAFETY CONTRACT
//   * ADD-ONLY. It never deletes an entry, never downgrades a status, and
//     never touches a pending entry. The only write it can make is setting
//     `athletes.{other}.status = 'accepted'` on a document whose counterpart
//     ALREADY says accepted.
//   * It cannot manufacture a friendship. A pair where neither side says
//     accepted is not touched; a pair where one side says accepted is, by
//     definition, one where somebody already recorded an acceptance.
//   * Idempotent. A second run reports zero repairs, because the first run
//     made both sides agree.
//   * Reads before it writes, per pair, so a pair repaired by the fan-out
//     function in between is skipped rather than rewritten.
//
// ORDER OF OPERATIONS — this matters
//   Run with --apply BEFORE deploying the tightened firestore.rules and
//   storage.rules. Between the deploy and the repair, affected pairs lose
//   access to each other's media.
//
// Modes:
//   (default)  dry-run — report every pair that would be repaired, write nothing
//   --apply            — write the missing side
//   --verify           — report any pair still one-sided (expects zero)
//
// Credentials come from GOOGLE_APPLICATION_CREDENTIALS or the ambient service
// account.

const admin = require('firebase-admin');

const DEFAULT_PROJECT_ID = 'goodlift-us-storage';
const COL = 'buddyAssignments';

/** Firestore's own limit on one batched write, with headroom. */
const BATCH_LIMIT = 400;

function usage() {
  return [
    'Symmetrise buddyAssignments for the mutual isBuddyOf() rule',
    '',
    'Dry run (default — writes nothing):',
    '  node scripts/symmetrise_buddy_assignments.js --project goodlift-us-storage',
    '',
    'Apply (run BEFORE deploying the tightened rules):',
    '  node scripts/symmetrise_buddy_assignments.js --project goodlift-us-storage --apply',
    '',
    'Verify no one-sided accepted pair remains:',
    '  node scripts/symmetrise_buddy_assignments.js --project goodlift-us-storage --verify',
    '',
    'Only ever ADDS the missing accepted entry. Never deletes or downgrades.',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    apply: false,
    verify: false,
    limit: 0,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
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

function athletesOf(data) {
  const athletes = data && data.athletes;
  return athletes && typeof athletes === 'object' ? athletes : {};
}

function isAccepted(entry) {
  return !!entry && typeof entry === 'object' && entry.status === 'accepted';
}

/**
 * Every accepted edge, as a canonically-ordered pair key.
 *
 * Canonical ordering (`a|b` with a < b) is what makes the two directions of one
 * friendship collapse into ONE pair, so a pair both sides agree on is examined
 * once rather than twice, and the counts mean what they say.
 */
function pairKey(a, b) {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}

/**
 * Scans every assignment document and classifies each accepted pair.
 *
 * Returns:
 *   mutual    both sides say accepted — nothing to do
 *   oneSided  exactly one side says accepted — the repair set
 */
async function scan(db, limit) {
  const mutual = [];
  const oneSided = [];

  /** pairKey -> Set of uids that claim the acceptance. */
  const claims = new Map();

  let scanned = 0;
  let query = db.collection(COL).orderBy(admin.firestore.FieldPath.documentId());
  let cursor = null;

  for (;;) {
    let page = query.limit(500);
    if (cursor) page = page.startAfter(cursor);
    // eslint-disable-next-line no-await-in-loop
    const snap = await page.get();
    if (snap.empty) break;

    for (const doc of snap.docs) {
      const ownerUid = doc.id;
      const athletes = athletesOf(doc.data());
      for (const otherUid of Object.keys(athletes)) {
        if (otherUid === ownerUid) continue;
        if (!isAccepted(athletes[otherUid])) continue;
        const key = pairKey(ownerUid, otherUid);
        if (!claims.has(key)) claims.set(key, new Set());
        claims.get(key).add(ownerUid);
      }
      scanned += 1;
    }

    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < 500) break;
    if (limit && scanned >= limit) break;
  }

  for (const [key, claimants] of claims) {
    const [a, b] = key.split('|');
    if (claimants.size === 2) {
      mutual.push({ a, b });
    } else {
      // The one that claims it is the side that exists; the other is missing.
      const claimant = [...claimants][0];
      const missing = claimant === a ? b : a;
      oneSided.push({ claimant, missing });
    }
  }

  // Deterministic output, so two runs of a dry run produce the same report and
  // a diff of two reports means something.
  mutual.sort((x, y) => pairKey(x.a, x.b).localeCompare(pairKey(y.a, y.b)));
  oneSided.sort((x, y) =>
    pairKey(x.claimant, x.missing).localeCompare(
      pairKey(y.claimant, y.missing),
    ),
  );

  return { scanned, mutual, oneSided };
}

/**
 * Writes the missing accepted entry for each one-sided pair.
 *
 * Re-reads the target document first: the fan-out trigger, or another run, may
 * have repaired the pair in between, and re-stamping an entry that is already
 * accepted would move its acceptedAt for no reason.
 */
async function repair(db, oneSided) {
  let repaired = 0;
  let skipped = 0;
  const errors = [];

  for (let i = 0; i < oneSided.length; i += BATCH_LIMIT) {
    const chunk = oneSided.slice(i, i + BATCH_LIMIT);
    const batch = db.batch();
    let queued = 0;

    // eslint-disable-next-line no-await-in-loop
    const targets = await Promise.all(
      chunk.map((p) => db.collection(COL).doc(p.missing).get()),
    );

    chunk.forEach((pair, n) => {
      const existing = athletesOf(targets[n].exists ? targets[n].data() : null);
      if (isAccepted(existing[pair.claimant])) {
        skipped += 1;
        return;
      }
      batch.set(
        db.collection(COL).doc(pair.missing),
        {
          athletes: {
            [pair.claimant]: {
              status: 'accepted',
              acceptedAt: admin.firestore.FieldValue.serverTimestamp(),
              symmetrisedBy: 'symmetrise_buddy_assignments',
            },
          },
        },
        { merge: true },
      );
      queued += 1;
    });

    if (queued > 0) {
      try {
        // eslint-disable-next-line no-await-in-loop
        await batch.commit();
        repaired += queued;
      } catch (err) {
        errors.push({ chunk: i / BATCH_LIMIT, message: err.message });
      }
    }
  }

  return { repaired, skipped, errors };
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
    `symmetrise_buddy_assignments — ${mode} on ${args.projectId}\n\n`,
  );

  const { scanned, mutual, oneSided } = await scan(db, args.limit);

  process.stdout.write(`assignment documents scanned : ${scanned}\n`);
  process.stdout.write(`mutual accepted pairs        : ${mutual.length}\n`);
  process.stdout.write(`one-sided accepted pairs     : ${oneSided.length}\n\n`);

  if (oneSided.length > 0) {
    const preview = oneSided.slice(0, 20);
    process.stdout.write('one-sided pairs (claimant -> missing side):\n');
    for (const p of preview) {
      process.stdout.write(`  ${p.claimant} -> ${p.missing}\n`);
    }
    if (oneSided.length > preview.length) {
      process.stdout.write(`  ... and ${oneSided.length - preview.length} more\n`);
    }
    process.stdout.write('\n');
  }

  if (args.verify) {
    if (oneSided.length === 0) {
      process.stdout.write('VERIFY OK — every accepted pair is mutual.\n');
    } else {
      process.stdout.write(
        `VERIFY FAILED — ${oneSided.length} pair(s) still one-sided. ` +
          'Run with --apply.\n',
      );
      process.exitCode = 1;
    }
    return;
  }

  if (!args.apply) {
    process.stdout.write(
      oneSided.length === 0
        ? 'Nothing to repair. Safe to deploy the tightened rules.\n'
        : `DRY RUN — would add ${oneSided.length} missing accepted entr` +
            `${oneSided.length === 1 ? 'y' : 'ies'}. Re-run with --apply.\n`,
    );
    return;
  }

  const { repaired, skipped, errors } = await repair(db, oneSided);
  process.stdout.write(`repaired : ${repaired}\n`);
  process.stdout.write(`skipped  : ${skipped} (already mutual when re-read)\n`);
  process.stdout.write(`errors   : ${errors.length}\n`);
  for (const e of errors) {
    process.stderr.write(`  batch ${e.chunk}: ${e.message}\n`);
  }
  if (errors.length > 0) process.exitCode = 1;
  else {
    process.stdout.write(
      '\nDone. Re-run with --verify, then deploy the tightened rules.\n',
    );
  }
}

if (require.main === module) {
  main().catch((err) => {
    process.stderr.write(`${err && err.stack ? err.stack : err}\n`);
    process.exitCode = 1;
  });
}

module.exports = { athletesOf, isAccepted, pairKey, scan, repair };
