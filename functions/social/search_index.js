// Maintains `userSearchIndex/{uid}` — the ONLY collection buddy discovery
// searches.
//
// ── Why a projection at all ────────────────────────────────────────────────
// The legacy buddy search queried `users_public` directly, on three ordered
// prefix ranges, one of which was `emailLower` — and it returned the matched
// email to the client. `users_public` is readable by every signed-in account,
// so that was an email-enumeration primitive with a search box in front of it.
// It also could not tolerate a single typo, because a prefix range cannot.
//
// This projection fixes both halves at once. It carries ONLY fields that are
// safe for one signed-in stranger to see about another — uid, username,
// display name, the name the user chose to publish, a small avatar, and the
// derived match tokens. No email, no phone number, no entitlement or
// subscription state, no coach relationship, no training data. A field that is
// not copied here cannot leak from here.
//
// ── Who is allowed to write it ─────────────────────────────────────────────
// This function, and nothing else. firestore.rules denies client writes to
// `userSearchIndex` outright; the Admin SDK used here bypasses rules. So the
// index cannot be forged: an account cannot make itself findable under someone
// else's name, and cannot inject terms it does not own.
//
// ── Where first and last name come from ────────────────────────────────────
// This app has never stored a first/last pair. It stores one `fullName`, so
// first and last are DERIVED: the first whitespace-separated token and the
// last. `Anna-Maria de la Cruz` therefore indexes `anna maria` and `cruz`
// alongside the full name, which is what a search for either half needs. It is
// a heuristic, and it is applied identically to every account, so nobody is
// findable under a name they did not publish.

'use strict';

const { onDocumentWritten } = require('firebase-functions/v2/firestore');
const logger = require('firebase-functions/logger');
const admin = require('firebase-admin');

const { buildSearchTokens, normalizeText } = require('./search_normalize');

const SEARCH_INDEX = 'userSearchIndex';

/** Trims a value to a string, or '' for anything that is not one. */
function str(value) {
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * First and last name derived from a single `fullName`.
 *
 * A one-word name is a first name with no surname, not a surname — that is how
 * the app's own display fallbacks already read it.
 */
function splitFullName(fullName) {
  const parts = str(fullName).split(/\s+/).filter(Boolean);
  if (parts.length === 0) return { firstName: '', lastName: '' };
  if (parts.length === 1) return { firstName: parts[0], lastName: '' };
  return {
    firstName: parts.slice(0, -1).join(' '),
    lastName: parts[parts.length - 1],
  };
}

/**
 * The discoverable identity of an account, read out of its public profile.
 *
 * Everything this returns is already visible to any signed-in user through
 * `users_public`; the point of naming them explicitly is that the projection
 * can only ever contain what is listed here.
 */
function discoverableIdentity(publicData) {
  const data = publicData || {};
  const fullName = str(data.fullName);
  const { firstName, lastName } = splitFullName(fullName);
  return {
    username: str(data.username),
    usernameLower: str(data.usernameLower) || normalizeText(data.username),
    displayName: str(data.displayName) || fullName || str(data.username),
    fullName,
    firstName,
    lastName,
    photoURL: str(data.photoURL),
  };
}

/**
 * The index document for [uid], or null when the account should not appear in
 * search at all.
 *
 * Null covers a deleted account (the public profile is gone), and an account
 * with nothing to match on — no username and no name. Indexing the latter
 * would put a nameless row in front of anyone whose query happened to produce
 * no tokens.
 */
function buildSearchIndexDoc(uid, publicData) {
  if (!uid || !publicData) return null;
  const identity = discoverableIdentity(publicData);
  const tokens = buildSearchTokens(identity);
  if (tokens.terms.length === 0) return null;
  return {
    uid,
    username: identity.username,
    usernameLower: identity.usernameLower,
    displayName: identity.displayName,
    fullName: identity.fullName,
    firstName: identity.firstName,
    lastName: identity.lastName,
    photoURL: identity.photoURL,
    terms: tokens.terms,
    prefixes: tokens.prefixes,
    grams: tokens.grams,
  };
}

/** Field-by-field equality of two index payloads, ignoring `updatedAt`. */
function sameIndexDoc(a, b) {
  if (!a || !b) return false;
  const keys = [
    'uid',
    'username',
    'usernameLower',
    'displayName',
    'fullName',
    'firstName',
    'lastName',
    'photoURL',
  ];
  for (const k of keys) {
    if ((a[k] || '') !== (b[k] || '')) return false;
  }
  for (const k of ['terms', 'prefixes', 'grams']) {
    const x = a[k] || [];
    const y = b[k] || [];
    if (x.length !== y.length) return false;
    for (let i = 0; i < x.length; i += 1) {
      if (x[i] !== y[i]) return false;
    }
  }
  return true;
}

/**
 * Brings `userSearchIndex/{uid}` into line with the account's public profile.
 *
 * Idempotent by construction: the document is REPLACED with a value computed
 * purely from the current public profile, so running it twice writes the same
 * thing, and running it after a missed event still converges. A run that would
 * change nothing writes nothing, which is what stops a rename storm from
 * costing one index write per unrelated profile touch.
 *
 * Returns 'deleted', 'written' or 'unchanged', for the backfill tool's counts.
 */
async function syncSearchIndex(db, uid, publicData) {
  const ref = db.collection(SEARCH_INDEX).doc(uid);
  const next = buildSearchIndexDoc(uid, publicData);

  if (next === null) {
    const existing = await ref.get();
    if (!existing.exists) return 'unchanged';
    await ref.delete();
    return 'deleted';
  }

  const existing = await ref.get();
  if (existing.exists && sameIndexDoc(existing.data(), next)) return 'unchanged';

  await ref.set(
    { ...next, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: false },
  );
  return 'written';
}

/**
 * Keeps the search projection in step with `users_public`.
 *
 * Covers every maintenance case the projection has, because every one of them
 * lands here as a write to the public profile: a username change (made by the
 * profileChangeUsername callable), a name or avatar change, a brand-new
 * account, and account deletion — which deletes the public profile, and
 * therefore deletes the index entry.
 *
 * `retry: true` is safe because the handler is idempotent: it derives the
 * whole document from the current public profile rather than applying a delta.
 */
const searchIndexOnPublicProfileWritten = onDocumentWritten(
  { document: 'users_public/{uid}', retry: true },
  async (event) => {
    const uid = event.params.uid;
    const after = event.data && event.data.after;
    const publicData = after && after.exists ? after.data() : null;
    try {
      const result = await syncSearchIndex(
        admin.firestore(),
        uid,
        publicData,
      );
      if (result !== 'unchanged') {
        logger.info('[searchIndex] %s %s', result, uid);
      }
    } catch (err) {
      logger.error('[searchIndex] failed for %s: %s', uid, err && err.message);
      throw err;
    }
  },
);

module.exports = {
  SEARCH_INDEX,
  splitFullName,
  discoverableIdentity,
  buildSearchIndexDoc,
  sameIndexDoc,
  syncSearchIndex,
  searchIndexOnPublicProfileWritten,
};
