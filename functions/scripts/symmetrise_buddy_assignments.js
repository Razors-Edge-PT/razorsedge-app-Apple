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
// STRATEGIES
//   --strategy=symmetrise       (default) ADD the missing accepted entry, so a
//                               half-recorded friendship becomes whole.
//   --strategy=remove-one-sided REMOVE both sides' entries plus the pair's own
//                               invite documents, so the pair holds no
//                               relationship and either person can send a fresh
//                               request. For pairs whose surviving half is
//                               ambiguous — a deleted account, a status-less
//                               legacy entry — where completing the friendship
//                               would invent one nobody asked for.
//
//   The strategies are mutually exclusive and neither is implied. A run with no
//   --strategy uses symmetrise, which is add-only; nothing deletes anything
//   without both --strategy=remove-one-sided AND --apply on the same command.
//
// Modes:
//   (default)  dry-run — report every pair the chosen strategy would act on,
//                        write nothing
//   --report           — dry run PLUS identity resolution and an invite audit,
//                        for deciding which pairs are real friendships and
//                        which are obsolete test data. Read-only.
//   --apply            — write the missing side
//   --verify           — report any pair still one-sided (expects zero)
//
// --report resolves nothing it could act on: it adds names, account existence,
// the direction each side actually holds, and a scan for pending invites
// missing fromUid/buddyUid (which the tightened rules make un-answerable by an
// old client). It changes NO repair semantics — the classification and the
// add-only contract above are untouched.
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
    'Full read-only preflight (names, account existence, invite audit):',
    '  node scripts/symmetrise_buddy_assignments.js --project goodlift-us-storage --report',
    '',
    'Reset the four ambiguous pairs instead of completing them (dry run):',
    '  node scripts/symmetrise_buddy_assignments.js --project goodlift-us-storage \\',
    '    --strategy=remove-one-sided',
    '',
    'Reset them for real, then verify:',
    '  node scripts/symmetrise_buddy_assignments.js --project goodlift-us-storage \\',
    '    --strategy=remove-one-sided --apply',
    '  node scripts/symmetrise_buddy_assignments.js --project goodlift-us-storage \\',
    '    --strategy=remove-one-sided --verify',
    '',
    'symmetrise (the default) only ever ADDS. remove-one-sided deletes only the',
    'named athletes.{uid} keys of the one-sided pairs and their own invites, and',
    'requires --apply. Neither ever deletes a whole document.',
  ].join('\n');
}

function parseArgs(argv) {
  const out = {
    projectId: DEFAULT_PROJECT_ID,
    apply: false,
    verify: false,
    report: false,
    strategy: STRATEGY_SYMMETRISE,
    expectMutual: null,
    limit: 0,
    help: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') out.apply = true;
    else if (arg === '--verify') out.verify = true;
    else if (arg === '--report') out.report = true;
    else if (arg.startsWith('--strategy=')) out.strategy = arg.split('=')[1];
    else if (arg === '--strategy') out.strategy = argv[++i];
    else if (arg === '--expect-mutual') {
      out.expectMutual = Number(argv[++i]);
    } else if (arg === '--limit') out.limit = Number(argv[++i]) || 0;
    else if (arg === '--project') out.projectId = argv[++i];
    else if (arg === '--help' || arg === '-h') out.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (out.apply && out.verify) {
    throw new Error('Choose --apply or --verify, not both.');
  }
  if (out.report && (out.apply || out.verify)) {
    throw new Error('--report is read-only; use it on its own.');
  }
  if (!STRATEGIES.includes(out.strategy)) {
    throw new Error(
      `Unknown --strategy "${out.strategy}". ` +
        `Expected one of: ${STRATEGIES.join(', ')}.`,
    );
  }
  if (
    out.expectMutual !== null &&
    (!Number.isInteger(out.expectMutual) || out.expectMutual < 0)
  ) {
    throw new Error('--expect-mutual takes a non-negative integer.');
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
 * The entry [ownerData] holds for [otherUid], whatever its status, or null.
 *
 * Deliberately not "the ACCEPTED entry": a reset has to clear a relationship
 * record that carries no status at all, which is the shape production actually
 * has for one of these pairs. Mirrors `entryFor` in ../social/buddy_model.js;
 * duplicated rather than imported so this script stays runnable on its own,
 * against a project whose Functions have not been deployed yet.
 */
function entryFor(ownerData, otherUid) {
  const entry = athletesOf(ownerData)[otherUid];
  return entry && typeof entry === 'object' ? entry : null;
}

/**
 * True when both documents record each other as accepted.
 *
 * The guard that keeps the nine mutual friendships out of the removal path:
 * re-checked at write time, so a pair somebody accepts mid-run is left alone.
 * Mirrors `areMutualFriends` in ../social/buddy_model.js.
 */
function areMutualFriends(aData, bData, aUid, bUid) {
  return isAccepted(entryFor(aData, bUid)) && isAccepted(entryFor(bData, aUid));
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

// ── Read-only preflight reporting ──────────────────────────────────────────

/**
 * Everything knowable about one account, for a human deciding about a pair.
 *
 * Reads `users_public` (the discoverable profile) and `users` (the account
 * record) so a deleted account can be told apart from one that merely never
 * published a name. Neither read can modify anything.
 */
async function resolveIdentity(db, uid) {
  const [pub, priv] = await Promise.all([
    db.collection('users_public').doc(uid).get(),
    db.collection('users').doc(uid).get(),
  ]);
  const d = pub.exists ? pub.data() || {} : {};
  const str = (v) => (typeof v === 'string' ? v.trim() : '');
  return {
    uid,
    hasPublicProfile: pub.exists,
    hasAccountDoc: priv.exists,
    username: str(d.username),
    displayName: str(d.displayName),
    fullName: str(d.fullName),
  };
}

/** A one-line human label for an account. */
function labelOf(id) {
  if (!id.hasPublicProfile && !id.hasAccountDoc) return 'MISSING / DELETED';
  const name = id.displayName || id.fullName || '(no name)';
  const handle = id.username ? `@${id.username}` : '(no username)';
  const flags = [];
  if (!id.hasPublicProfile) flags.push('no users_public');
  if (!id.hasAccountDoc) flags.push('no users doc');
  return `${name}  ${handle}${flags.length ? `  [${flags.join(', ')}]` : ''}`;
}

/** The raw entry [ownerUid] holds for [otherUid], described. */
function describeEntry(ownerData, otherUid) {
  const entry = athletesOf(ownerData)[otherUid];
  if (!entry || typeof entry !== 'object') return 'no entry';
  const at = entry.acceptedAt || entry.addedAt;
  const when =
    at && typeof at.toDate === 'function' ? at.toDate().toISOString() : '';
  const extra = entry.displayName ? ` displayName="${entry.displayName}"` : '';
  return `status=${entry.status || '(none)'}${when ? ` at ${when}` : ''}${extra}`;
}

/**
 * Pending invites that the tightened rules would make un-answerable.
 *
 * The dedicated buddyInvites update rule requires the stored document to carry
 * `fromUid` and `buddyUid` matching the document path; a pending invite that
 * does not can currently be answered only because the users/{subcoll} catch-all
 * still grants the receiver an unconstrained write, and that catch-all no
 * longer covers buddyInvites. Such an invite stays answerable by the NEW client
 * (the callable runs on the Admin SDK) but not by an installed one.
 *
 * Uses a collection-group read, falling back to a per-account walk when the
 * collection-group index is absent, so the audit completes either way.
 */
async function scanMalformedPendingInvites(db) {
  const bad = [];
  const seen = { scanned: 0, viaFallback: false };

  const inspect = (docRef, data, receiverUid) => {
    seen.scanned += 1;
    const from = data && data.fromUid;
    const buddy = data && data.buddyUid;
    const problems = [];
    if (typeof from !== 'string' || from.trim() === '') {
      problems.push('fromUid absent');
    } else if (from !== docRef.id) {
      problems.push(`fromUid "${from}" != docId "${docRef.id}"`);
    }
    if (typeof buddy !== 'string' || buddy.trim() === '') {
      problems.push('buddyUid absent');
    } else if (receiverUid && buddy !== receiverUid) {
      problems.push(`buddyUid "${buddy}" != receiver "${receiverUid}"`);
    }
    if (problems.length > 0) {
      bad.push({ path: docRef.path, problems, status: data && data.status });
    }
  };

  try {
    const snap = await db
      .collectionGroup('buddyInvites')
      .where('status', '==', 'pending')
      .get();
    for (const doc of snap.docs) {
      // users/{receiver}/buddyInvites/{sender}
      const parts = doc.ref.path.split('/');
      inspect(doc.ref, doc.data(), parts.length >= 2 ? parts[1] : '');
    }
  } catch (err) {
    seen.viaFallback = true;
    process.stdout.write(
      `  (collection-group read unavailable: ${err.message};\n` +
        '   walking accounts instead)\n',
    );
    const users = await db.collection('users').select().get();
    for (const u of users.docs) {
      // eslint-disable-next-line no-await-in-loop
      const invites = await u.ref
        .collection('buddyInvites')
        .where('status', '==', 'pending')
        .get();
      for (const doc of invites.docs) inspect(doc.ref, doc.data(), u.id);
    }
  }

  return { bad, scanned: seen.scanned, viaFallback: seen.viaFallback };
}

/**
 * The full read-only preflight: who these people are, what each side holds,
 * and which pending invites are malformed.
 *
 * Prints enough to decide, per pair, whether it is a real friendship worth
 * preserving or obsolete test data. It never writes.
 */
async function printReport(db, oneSided, mutual) {
  process.stdout.write(`\n== ONE-SIDED ACCEPTED PAIRS ${'='.repeat(44)}\n`);
  if (oneSided.length === 0) process.stdout.write('  none\n');

  let n = 0;
  for (const pair of oneSided) {
    n += 1;
    // eslint-disable-next-line no-await-in-loop
    const [claimantId, missingId, claimantDoc, missingDoc] = await Promise.all([
      resolveIdentity(db, pair.claimant),
      resolveIdentity(db, pair.missing),
      db.collection(COL).doc(pair.claimant).get(),
      db.collection(COL).doc(pair.missing).get(),
    ]);
    const claimantData = claimantDoc.exists ? claimantDoc.data() : null;
    const missingData = missingDoc.exists ? missingDoc.data() : null;

    process.stdout.write(`\nPAIR ${n} of ${oneSided.length}\n`);
    process.stdout.write(`  HOLDS the acceptance  : ${pair.claimant}\n`);
    process.stdout.write(`                          ${labelOf(claimantId)}\n`);
    process.stdout.write(
      `                          ${COL}/${pair.claimant}` +
        `${claimantDoc.exists ? '' : '   [DOCUMENT MISSING]'}\n`,
    );
    process.stdout.write(
      `      entry for the other : ${describeEntry(claimantData, pair.missing)}\n`,
    );
    process.stdout.write(`  MISSING the acceptance: ${pair.missing}\n`);
    process.stdout.write(`                          ${labelOf(missingId)}\n`);
    process.stdout.write(
      `                          ${COL}/${pair.missing}` +
        `${missingDoc.exists ? '' : '   [DOCUMENT MISSING]'}\n`,
    );
    process.stdout.write(
      `      entry for the other : ${describeEntry(missingData, pair.claimant)}\n`,
    );
    process.stdout.write(
      `  --apply would write   : ${COL}/${pair.missing}` +
        `.athletes.${pair.claimant}.status = 'accepted'\n`,
    );
    if (!missingId.hasPublicProfile && !missingId.hasAccountDoc) {
      process.stdout.write(
        '  NOTE: the missing side has no account. Repairing it restores a\n' +
          '        friendship with an account nobody can sign in to.\n',
      );
    }
    if (!claimantId.hasPublicProfile && !claimantId.hasAccountDoc) {
      process.stdout.write(
        '  NOTE: the side holding the acceptance has no account.\n',
      );
    }
  }

  process.stdout.write(`\n== MUTUAL PAIRS (no action) ${'='.repeat(44)}\n`);
  for (const pair of mutual) {
    // eslint-disable-next-line no-await-in-loop
    const [x, y] = await Promise.all([
      resolveIdentity(db, pair.a),
      resolveIdentity(db, pair.b),
    ]);
    process.stdout.write(`  ${labelOf(x)}\n     <-> ${labelOf(y)}\n`);
  }

  process.stdout.write(
    `\n== PENDING INVITES MISSING fromUid / buddyUid ${'='.repeat(26)}\n`,
  );
  const invites = await scanMalformedPendingInvites(db);
  process.stdout.write(`  pending invites scanned : ${invites.scanned}\n`);
  process.stdout.write(`  malformed               : ${invites.bad.length}\n`);
  for (const b of invites.bad) {
    process.stdout.write(`    ${b.path}\n      ${b.problems.join('; ')}\n`);
  }
  if (invites.bad.length === 0) {
    process.stdout.write(
      '  Every pending invite carries both pointers, so the tightened\n' +
        '  buddyInvites rule leaves all of them answerable by installed\n' +
        '  clients. No action needed.\n',
    );
  } else {
    process.stdout.write(
      '\n  These stay answerable by the NEW client (buddyRespondToRequest runs\n' +
        '  on the Admin SDK and bypasses rules) but NOT by an installed one\n' +
        '  once the tightened rules deploy.\n',
    );
  }
}

// ── Strategy: remove-one-sided ─────────────────────────────────────────────
//
// The alternative to symmetrising. Instead of completing a half-recorded
// friendship, it CLEARS both sides so the pair genuinely holds no
// relationship, and either person can send a fresh request afterwards.
//
// Chosen when the surviving half is ambiguous — an account that no longer
// exists, an entry with no status at all, a friendship nobody can date. A
// repaired ambiguous pair is a friendship neither party asked for; a cleared
// one is a clean slate that either of them can act on.
//
// WHAT IT TOUCHES, EXACTLY
//   For each pair (A holds the acceptance, B is missing it):
//     buddyAssignments/A  →  delete the single key `athletes.B`
//     buddyAssignments/B  →  delete the single key `athletes.A`, if present
//   plus the pair's own invite documents in both directions, because a stale
//   invite is what stops the relationship being genuinely reset:
//     users/A/buddyInvites/B  and  users/B/buddyInvites/A
//
//   An installed client re-sending to somebody who still has an invite
//   document cannot create one — the tightened create rule does not apply to
//   an existing document, and the update rule belongs to the receiver. And
//   buddyRespondToRequest refuses to accept an invite already marked denied.
//   Leaving those behind would reset the friendship on paper and leave the
//   pair unable to use it.
//
// WHAT IT NEVER TOUCHES
//   * a whole buddyAssignments document — only named keys inside it;
//   * any other entry in the same document, including every mutual friendship;
//   * a pair that is mutually accepted, checked again at write time;
//   * accounts, public profiles, posts, media, stories, or the invite history
//     of any pair other than these.
//
// PROJECTIONS
//   Every delete is a write to buddyAssignments/{uid}, which is the trigger
//   path of feedOnBuddyAssignmentWritten. That handler recomputes
//   socialGraph/{uid} for both sides from the authority and purges the feed
//   rows of anyone who stopped being a friend, so no stale projection is left
//   behind. It must therefore be DEPLOYED BEFORE this runs — see the rollout
//   order. Run this before the trigger exists and the assignment entries go
//   while socialGraph and users/{uid}/feed keep the removed relationship.

/** The strategies this tool knows. The default never deletes anything. */
const STRATEGY_SYMMETRISE = 'symmetrise';
const STRATEGY_REMOVE = 'remove-one-sided';
const STRATEGIES = [STRATEGY_SYMMETRISE, STRATEGY_REMOVE];

const SUB_INVITES = 'buddyInvites';
const COL_USERS = 'users';

const inviteRefOf = (db, receiverUid, senderUid) =>
  db.collection(COL_USERS).doc(receiverUid).collection(SUB_INVITES).doc(senderUid);

/**
 * Everything the removal would touch, resolved and read-only.
 *
 * Built entirely from reads so the dry run and the apply agree about what the
 * work is, and so a human can see every uid, name, path and field before any
 * of it happens.
 */
async function planRemoval(db, oneSided) {
  const plan = [];

  for (const pair of oneSided) {
    // eslint-disable-next-line no-await-in-loop
    const [claimantId, missingId, claimantDoc, missingDoc, inviteA, inviteB] =
      await Promise.all([
        resolveIdentity(db, pair.claimant),
        resolveIdentity(db, pair.missing),
        db.collection(COL).doc(pair.claimant).get(),
        db.collection(COL).doc(pair.missing).get(),
        inviteRefOf(db, pair.claimant, pair.missing).get(),
        inviteRefOf(db, pair.missing, pair.claimant).get(),
      ]);

    const claimantData = claimantDoc.exists ? claimantDoc.data() : null;
    const missingData = missingDoc.exists ? missingDoc.data() : null;

    const entryDeletes = [];
    if (entryFor(claimantData, pair.missing)) {
      entryDeletes.push({
        ownerUid: pair.claimant,
        otherUid: pair.missing,
        path: `${COL}/${pair.claimant}`,
        field: `athletes.${pair.missing}`,
        describes: describeEntry(claimantData, pair.missing),
      });
    }
    if (entryFor(missingData, pair.claimant)) {
      // Pair 4's case: a legacy entry carrying addedAt and displayName but no
      // status. It is not an acceptance, so symmetrising ignored it — but it
      // is a relationship record, so a reset has to clear it too.
      entryDeletes.push({
        ownerUid: pair.missing,
        otherUid: pair.claimant,
        path: `${COL}/${pair.missing}`,
        field: `athletes.${pair.claimant}`,
        describes: describeEntry(missingData, pair.claimant),
      });
    }

    const inviteDeletes = [];
    for (const snap of [inviteA, inviteB]) {
      if (!snap.exists) continue;
      const d = snap.data() || {};
      inviteDeletes.push({
        path: snap.ref.path,
        status: typeof d.status === 'string' ? d.status : '(none)',
      });
    }

    plan.push({
      pair,
      claimantId,
      missingId,
      entryDeletes,
      inviteDeletes,
      noop: entryDeletes.length === 0 && inviteDeletes.length === 0,
    });
  }

  return plan;
}

/** Prints the whole plan: every uid, name, path and field, before anything runs. */
function printRemovalPlan(plan, { willApply }) {
  process.stdout.write(
    `\n== PLAN: ${STRATEGY_REMOVE} ${'='.repeat(46)}\n` +
      (willApply
        ? 'APPLYING. Each entry below will be deleted.\n'
        : 'DRY RUN. Nothing below will be written.\n'),
  );

  let entries = 0;
  let invites = 0;
  let n = 0;

  for (const item of plan) {
    n += 1;
    process.stdout.write(`\nPAIR ${n} of ${plan.length}\n`);
    process.stdout.write(
      `  ${item.pair.claimant}\n    ${labelOf(item.claimantId)}\n`,
    );
    process.stdout.write(
      `  ${item.pair.missing}\n    ${labelOf(item.missingId)}\n`,
    );

    if (item.noop) {
      process.stdout.write('  nothing to remove — already clear\n');
      continue;
    }

    for (const del of item.entryDeletes) {
      entries += 1;
      process.stdout.write(
        `  DELETE FIELD  ${del.path}\n` +
          `                  ${del.field}\n` +
          `                  currently: ${del.describes}\n`,
      );
    }
    for (const del of item.inviteDeletes) {
      invites += 1;
      process.stdout.write(
        `  DELETE DOC    ${del.path}\n` +
          `                  status=${del.status}` +
          `${del.status === 'pending' ? '   <-- LIVE REQUEST' : ''}\n`,
      );
    }
  }

  process.stdout.write(
    `\n  assignment fields to delete : ${entries}\n` +
      `  invite documents to delete  : ${invites}\n`,
  );
  const live = plan.some((i) =>
    i.inviteDeletes.some((d) => d.status === 'pending'),
  );
  if (live) {
    process.stdout.write(
      '\n  WARNING: one of these invites is still PENDING. Removing it\n' +
        '  cancels a request somebody is waiting on. Review before --apply.\n',
    );
  }
  return { entries, invites };
}

/**
 * Executes the plan, one pair at a time, re-reading before every delete.
 *
 * Idempotent and race-safe in the same way the repair is: the state is read
 * again inside the write, so a pair somebody has meanwhile made MUTUAL is
 * skipped rather than torn down, and a pair already cleared costs nothing.
 *
 * Deletes are `set(merge:true)` of a single `FieldValue.delete()` on one named
 * key. That cannot remove the document and cannot touch a sibling entry, which
 * is what keeps the nine mutual friendships out of reach.
 */
async function applyRemoval(db, plan) {
  let fieldsRemoved = 0;
  let invitesRemoved = 0;
  let skippedMutual = 0;
  let skippedAbsent = 0;
  const errors = [];

  for (const item of plan) {
    const { claimant, missing } = item.pair;
    try {
      // eslint-disable-next-line no-await-in-loop
      const [claimantDoc, missingDoc] = await Promise.all([
        db.collection(COL).doc(claimant).get(),
        db.collection(COL).doc(missing).get(),
      ]);
      const claimantData = claimantDoc.exists ? claimantDoc.data() : null;
      const missingData = missingDoc.exists ? missingDoc.data() : null;

      // Somebody accepted while we were reading. A mutual friendship is not
      // this tool's to remove.
      if (areMutualFriends(claimantData, missingData, claimant, missing)) {
        skippedMutual += 1;
        process.stdout.write(
          `  SKIP ${claimant} x ${missing} — became mutual since the scan\n`,
        );
        continue;
      }

      const batch = db.batch();
      let queued = 0;

      if (entryFor(claimantData, missing)) {
        batch.set(
          db.collection(COL).doc(claimant),
          { athletes: { [missing]: admin.firestore.FieldValue.delete() } },
          { merge: true },
        );
        queued += 1;
      } else {
        skippedAbsent += 1;
      }

      if (entryFor(missingData, claimant)) {
        batch.set(
          db.collection(COL).doc(missing),
          { athletes: { [claimant]: admin.firestore.FieldValue.delete() } },
          { merge: true },
        );
        queued += 1;
      }

      const inviteFields = queued;

      // eslint-disable-next-line no-await-in-loop
      const [inviteA, inviteB] = await Promise.all([
        inviteRefOf(db, claimant, missing).get(),
        inviteRefOf(db, missing, claimant).get(),
      ]);
      for (const snap of [inviteA, inviteB]) {
        if (!snap.exists) continue;
        batch.delete(snap.ref);
        queued += 1;
      }

      if (queued > 0) {
        // eslint-disable-next-line no-await-in-loop
        await batch.commit();
        fieldsRemoved += inviteFields;
        invitesRemoved += queued - inviteFields;
      }
    } catch (err) {
      errors.push({ pair: `${claimant} x ${missing}`, message: err.message });
    }
  }

  return { fieldsRemoved, invitesRemoved, skippedMutual, skippedAbsent, errors };
}

/**
 * Confirms the outcome: the one-sided pairs are gone AND the mutual ones are
 * all still there.
 *
 * The second half is the point. "Zero one-sided pairs" is also what you would
 * see if the tool had deleted everything, so a verification that only counts
 * what it removed cannot tell success from catastrophe.
 */
async function verifyRemoval(db, expectedMutual) {
  const { mutual, oneSided } = await scan(db, 0);
  const okOneSided = oneSided.length === 0;
  const okMutual =
    expectedMutual === null || mutual.length === expectedMutual;

  process.stdout.write(`  one-sided pairs remaining : ${oneSided.length}\n`);
  process.stdout.write(
    `  mutual pairs intact       : ${mutual.length}` +
      (expectedMutual === null ? '\n' : ` (expected ${expectedMutual})\n`),
  );
  for (const p of oneSided) {
    process.stdout.write(`    still one-sided: ${p.claimant} -> ${p.missing}\n`);
  }
  return { ok: okOneSided && okMutual, mutual, oneSided };
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

  const mode = args.apply
    ? 'APPLY'
    : args.verify
      ? 'VERIFY'
      : args.report
        ? 'REPORT'
        : 'DRY RUN';
  process.stdout.write(
    `symmetrise_buddy_assignments — ${mode} on ${args.projectId}\n` +
      `strategy: ${args.strategy}\n\n`,
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

  if (args.report) {
    await printReport(db, oneSided, mutual);
    process.stdout.write(
      '\nREPORT ONLY — nothing was written. ' +
        'Decide per pair, then re-run with --apply.\n',
    );
    return;
  }

  // ── remove-one-sided ────────────────────────────────────────────────────
  if (args.strategy === STRATEGY_REMOVE) {
    if (args.verify) {
      const expected =
        args.expectMutual === null ? mutual.length : args.expectMutual;
      const result = await verifyRemoval(db, args.expectMutual);
      if (result.ok) {
        process.stdout.write(
          '\nVERIFY OK — no one-sided pair remains and every mutual\n' +
            `friendship is intact (${result.mutual.length}).\n`,
        );
      } else {
        process.stdout.write(
          '\nVERIFY FAILED — see the counts above. ' +
            `Expected ${expected} mutual pair(s) and 0 one-sided.\n`,
        );
        process.exitCode = 1;
      }
      return;
    }

    const plan = await planRemoval(db, oneSided);
    printRemovalPlan(plan, { willApply: args.apply });

    if (!args.apply) {
      process.stdout.write(
        '\nDRY RUN — nothing was written. Re-run with ' +
          '--strategy=remove-one-sided --apply to reset these pairs.\n',
      );
      return;
    }

    const before = mutual.length;
    process.stdout.write('\napplying...\n');
    const out = await applyRemoval(db, plan);
    process.stdout.write(`\nassignment fields removed : ${out.fieldsRemoved}\n`);
    process.stdout.write(`invite documents removed  : ${out.invitesRemoved}\n`);
    process.stdout.write(`skipped (became mutual)   : ${out.skippedMutual}\n`);
    process.stdout.write(`skipped (already clear)   : ${out.skippedAbsent}\n`);
    process.stdout.write(`errors                    : ${out.errors.length}\n`);
    for (const e of out.errors) {
      process.stderr.write(`  ${e.pair}: ${e.message}\n`);
    }
    if (out.errors.length > 0) {
      process.exitCode = 1;
      return;
    }

    process.stdout.write('\nre-checking...\n');
    const check = await verifyRemoval(db, before);
    if (!check.ok) {
      process.stdout.write(
        '\nPOST-CHECK FAILED — the mutual friendships or the one-sided\n' +
          'pairs are not what they should be. Investigate before deploying\n' +
          'the tightened rules.\n',
      );
      process.exitCode = 1;
      return;
    }
    process.stdout.write(
      '\nDone. The four pairs hold no relationship; every mutual\n' +
        'friendship is unchanged. feedOnBuddyAssignmentWritten has been\n' +
        'triggered by each delete and will have recomputed socialGraph and\n' +
        'purged the matching feed rows — provided it was deployed first.\n',
    );
    return;
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

module.exports = {
  athletesOf,
  isAccepted,
  entryFor,
  areMutualFriends,
  pairKey,
  scan,
  repair,
  labelOf,
  describeEntry,
  resolveIdentity,
  scanMalformedPendingInvites,
  STRATEGY_SYMMETRISE,
  STRATEGY_REMOVE,
  STRATEGIES,
  planRemoval,
  printRemovalPlan,
  applyRemoval,
  verifyRemoval,
};
