// Pure username normalisation, validation and index-key derivation.
//
// No Firebase imports, so the exact rules the callable enforces are the rules
// the unit tests and the backfill migration run. lib/profile/data/username_rules.dart
// is the pinned Dart mirror.
//
// ── Normalisation ───────────────────────────────────────────────────────────
// trim → Unicode NFKC → lowercase. NFKC is the identity on ASCII, so every
// username already written by the app normalises to exactly the value the old
// `username.toLowerCase()` code produced and the backfill is non-destructive.
//
// ── Index key ───────────────────────────────────────────────────────────────
// The reservation document id is sha256(normalised) in hex, NOT the name
// itself. A username may legally contain '/', '.', '..' or a 1500-byte run of
// astral characters, all of which are illegal or dangerous as Firestore
// document ids. Hashing makes the key a fixed-length, path-safe constant.

'use strict';

const crypto = require('crypto');

/** Matches the app's long-standing rule: 3–22 characters, no whitespace. */
const USERNAME_PATTERN = /^\S{3,22}$/u;

const MIN_LENGTH = 3;
const MAX_LENGTH = 22;

/** trim → NFKC → lowercase. Returns '' for anything that is not a string. */
function normalizeUsername(raw) {
  if (typeof raw !== 'string') return '';
  return raw.trim().normalize('NFKC').toLowerCase();
}

/** The display form: trimmed, NFKC, original casing preserved. */
function displayUsername(raw) {
  if (typeof raw !== 'string') return '';
  return raw.trim().normalize('NFKC');
}

/**
 * Validation result: { ok: true } or { ok: false, code, message }.
 * Runs against the DISPLAY form so a name that is only whitespace, or that
 * carries control characters, is rejected before it can reach the index.
 */
function validateUsername(raw) {
  const display = displayUsername(raw);
  if (!display) {
    return { ok: false, code: 'empty', message: 'Enter a username.' };
  }
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(display)) {
    return {
      ok: false,
      code: 'invalid-characters',
      message: 'That username contains characters we can’t use.',
    };
  }
  if (!USERNAME_PATTERN.test(display)) {
    return {
      ok: false,
      code: 'invalid-format',
      message: `Usernames are ${MIN_LENGTH}–${MAX_LENGTH} characters with no spaces.`,
    };
  }
  return { ok: true };
}

/** Path-safe reservation document id for a normalised username. */
function usernameIndexKey(normalized) {
  return crypto.createHash('sha256').update(String(normalized), 'utf8').digest('hex');
}

/** Convenience: index key straight from a raw, unnormalised name. */
function indexKeyForRaw(raw) {
  return usernameIndexKey(normalizeUsername(raw));
}

module.exports = {
  USERNAME_PATTERN,
  MIN_LENGTH,
  MAX_LENGTH,
  normalizeUsername,
  displayUsername,
  validateUsername,
  usernameIndexKey,
  indexKeyForRaw,
};
