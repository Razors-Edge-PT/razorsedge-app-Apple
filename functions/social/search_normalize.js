// Normalisation and candidate-term generation for buddy discovery.
//
// ── Why this file has a Dart twin ──────────────────────────────────────────
// The index is written HERE (trusted backend) and queried from the client
// (lib/social/search_normalize.dart). Both sides must agree on exactly one
// question: "what string is this text, really?" If the writer folds accents
// and the reader does not, `renee` never finds `Renée` and the index looks
// broken rather than mismatched. The two files are pinned together by a shared
// vector table — functions/test/social_search_normalize.test.js and
// test/social_search_normalize_test.dart assert the SAME inputs produce the
// SAME outputs, so a change to one that is not mirrored fails a test rather
// than silently degrading search.
//
// ── Why NFD alone is not enough ────────────────────────────────────────────
// `'é'.normalize('NFD')` splits into `e` + a combining acute, so stripping the
// combining range folds most accented Latin letters for free. It does NOT
// touch the letters that are atomic in Unicode rather than composed:
// æ ø ß œ đ ł ħ ŧ ı ŋ þ have no canonical decomposition and survive NFD
// unchanged. Those are exactly the letters Nordic, Polish and German names are
// spelled with, so they are folded by an explicit table — the SAME table the
// Dart side uses, which is what keeps the two implementations in step given
// Dart has no Unicode normalisation available to it at all.

'use strict';

/// Longest prefix stored. Beyond this a query falls back to `terms` (exact),
/// which is why a 40-character name is still findable by its full spelling.
/// Bounded because prefix count is linear in this number, per stored string.
const MAX_PREFIX = 15;

/// Shortest query we will serve. One character matches a large fraction of any
/// user base, so it is a collection scan wearing a query's clothes.
const MIN_QUERY = 2;

/// Hard ceilings on the arrays written to a single index document, so one
/// pathological name cannot inflate a document or a query's index cost.
const MAX_PREFIXES = 120;
const MAX_GRAMS = 90;

/// Combining marks left behind by NFD decomposition (U+0300–U+036F).
const COMBINING = /[̀-ͯ]/g;

/// Source characters grouped by the ASCII they fold to.
///
/// Mirrors `_foldingGroups` in lib/social/search_normalize.dart, character for
/// character. Entries that DO decompose under NFD are harmless duplicates of
/// what the decomposition already did; the entries that matter are the atomic
/// letters listed in the header comment.
const FOLDING_GROUPS = [
  ['àáâãäåāăą', 'a'],
  ['ÀÁÂÃÄÅĀĂĄ', 'a'],
  ['çćĉċč', 'c'],
  ['ÇĆĈĊČ', 'c'],
  ['ðďđ', 'd'],
  ['ÐĎĐ', 'd'],
  ['èéêëēĕėęě', 'e'],
  ['ÈÉÊËĒĔĖĘĚ', 'e'],
  ['ĝğġģ', 'g'],
  ['ĜĞĠĢ', 'g'],
  ['ĥħ', 'h'],
  ['ĤĦ', 'h'],
  ['ìíîïĩīĭįı', 'i'],
  ['ÌÍÎÏĨĪĬĮİ', 'i'],
  ['ĵ', 'j'],
  ['Ĵ', 'j'],
  ['ķĸ', 'k'],
  ['Ķ', 'k'],
  ['ĺļľŀł', 'l'],
  ['ĹĻĽĿŁ', 'l'],
  ['ñńņňŉ', 'n'],
  ['ÑŃŅŇ', 'n'],
  ['òóôõöøōŏő', 'o'],
  ['ÒÓÔÕÖØŌŎŐ', 'o'],
  ['ŕŗř', 'r'],
  ['ŔŖŘ', 'r'],
  ['śŝşš', 's'],
  ['ŚŜŞŠ', 's'],
  ['ţťŧ', 't'],
  ['ŢŤŦ', 't'],
  ['ùúûüũūŭůűų', 'u'],
  ['ÙÚÛÜŨŪŬŮŰŲ', 'u'],
  ['ŵ', 'w'],
  ['Ŵ', 'w'],
  ['ýÿŷ', 'y'],
  ['ÝŶŸ', 'y'],
  ['źżž', 'z'],
  ['ŹŻŽ', 'z'],
  // Multi-character expansions. NFD does not produce these either, so both
  // files special-case them identically.
  ['æ', 'ae'],
  ['Æ', 'ae'],
  ['œ', 'oe'],
  ['Œ', 'oe'],
  ['ß', 'ss'],
  ['þ', 'th'],
  ['Þ', 'th'],
  ['ŋ', 'n'],
  ['Ŋ', 'n'],
];

const FOLDING = new Map();
for (const [sources, target] of FOLDING_GROUPS) {
  for (const ch of sources) FOLDING.set(ch.codePointAt(0), target);
}

/**
 * True for a character that survives normalisation as itself.
 *
 * Deliberately implemented as an explicit range test rather than `\p{L}`, so
 * that it can be mirrored exactly by the Dart side, which has no Unicode
 * general-category tables available to it. Letters and digits survive;
 * punctuation, symbols and emoji become a space.
 */
function isAlphanumeric(rune) {
  if (rune >= 0x30 && rune <= 0x39) return true; // 0-9
  if (rune >= 0x61 && rune <= 0x7a) return true; // a-z
  if (rune >= 0x41 && rune <= 0x5a) return true; // A-Z
  if (rune < 0x80) return false;
  if (rune >= 0x80 && rune <= 0xbf) return false; // Latin-1 punctuation
  if (rune === 0xd7 || rune === 0xf7) return false; // × ÷
  if (rune >= 0x2000 && rune <= 0x206f) return false; // general punctuation
  if (rune >= 0x2190 && rune <= 0x2bff) return false; // arrows and symbols
  // Invisible formatting. A variation selector rides along behind an emoji
  // (🏋️ is U+1F3CB U+FE0F), so dropping only the pictograph leaves an untypeable
  // character in the middle of the normalised string and nothing ever matches
  // that account again.
  if (rune >= 0xfe00 && rune <= 0xfe0f) return false; // variation selectors
  if (rune >= 0xe000 && rune <= 0xf8ff) return false; // private use
  if (rune >= 0xfff0 && rune <= 0xffff) return false; // specials
  if (rune >= 0x1f000) return false; // emoji and pictographs
  return true;
}

/**
 * The canonical form of a piece of user-supplied text.
 *
 * Accents folded, case dropped, punctuation reduced to spaces and runs of
 * whitespace collapsed. `  Renée   O'Brien-Smith ` and `renee obrien smith`
 * normalise to the same string, which is the whole point: neither the person
 * searching nor the person indexed should have to reproduce the other's
 * punctuation.
 */
function normalizeText(raw) {
  if (typeof raw !== 'string' || raw.length === 0) return '';
  const decomposed = raw.normalize('NFD').replace(COMBINING, '');
  let out = '';
  let pendingSpace = false;
  let wroteAny = false;

  const writeText = (text) => {
    if (!text) return;
    if (pendingSpace) {
      out += ' ';
      pendingSpace = false;
    }
    out += text;
    wroteAny = true;
  };

  for (const ch of decomposed) {
    const rune = ch.codePointAt(0);
    const folded = FOLDING.get(rune);
    if (folded !== undefined) {
      writeText(folded);
      continue;
    }
    if (isAlphanumeric(rune)) {
      writeText(ch.toLowerCase());
      continue;
    }
    if (wroteAny) pendingSpace = true;
  }
  return out;
}

/** [normalizeText] with spaces removed, for "firstlast" style matching. */
function compactText(raw) {
  return normalizeText(raw).replace(/ /g, '');
}

/**
 * Every prefix of [value] from MIN_QUERY to MAX_PREFIX characters.
 *
 * Uses Array.from so an astral-plane character counts as one character rather
 * than as two surrogate halves — slicing a surrogate pair in half produces a
 * prefix that can never be typed.
 */
function prefixesOf(value) {
  const chars = Array.from(value);
  const out = [];
  const limit = Math.min(chars.length, MAX_PREFIX);
  for (let n = MIN_QUERY; n <= limit; n += 1) {
    out.push(chars.slice(0, n).join(''));
  }
  return out;
}

/**
 * Padded trigrams of [value].
 *
 * The `$` padding is what makes the START of a string matter: without it
 * `john` and `ohnj` produce the same gram set. Spaces are dropped first so
 * "first last" and "firstlast" share a gram set.
 */
function trigramsOf(value) {
  const compact = value.replace(/ /g, '');
  if (!compact) return [];
  const chars = Array.from(compact);
  if (chars.length < 3) return [`$${chars.join('')}`];
  const padded = ['$', ...chars, '$'];
  const out = [];
  for (let i = 0; i + 3 <= padded.length; i += 1) {
    out.push(padded.slice(i, i + 3).join(''));
  }
  return out;
}

/** Unique, sorted and capped at [max]. Sorted so the output is deterministic. */
function boundedSet(values, max) {
  const seen = new Set();
  for (const v of values) {
    if (typeof v === 'string' && v.length > 0) seen.add(v);
  }
  return Array.from(seen).sort().slice(0, max);
}

/**
 * The exact strings an account should be findable by.
 *
 * Deliberately NOT the email address. `users_public` still carries
 * `emailLower` for legacy reasons, and the whole reason this projection exists
 * is that searching it must not be an email-enumeration primitive.
 */
function searchTermsFor({ username, firstName, lastName, displayName } = {}) {
  const user = normalizeText(username);
  const first = normalizeText(firstName);
  const last = normalizeText(lastName);
  const display = normalizeText(displayName);
  const full = [first, last].filter(Boolean).join(' ');
  return boundedSet(
    [user, first, last, full, compactText(full), display, compactText(display)],
    16,
  );
}

/** Candidate arrays for one account. */
function buildSearchTokens(identity) {
  const terms = searchTermsFor(identity);
  const prefixes = boundedSet(
    terms.flatMap((t) => prefixesOf(t)),
    MAX_PREFIXES,
  );
  const grams = boundedSet(
    terms.flatMap((t) => trigramsOf(t)),
    MAX_GRAMS,
  );
  return { terms, prefixes, grams };
}

/**
 * The trigrams a QUERY should be matched by, most selective first.
 *
 * Capped because `array-contains-any` accepts at most 30 disjuncts and every
 * extra disjunct is index cost for a fuzzy fallback that only has to surface
 * candidates, not rank them.
 */
function queryGrams(raw, max = 10) {
  return trigramsOf(normalizeText(raw)).slice(0, max);
}

module.exports = {
  MAX_PREFIX,
  MIN_QUERY,
  MAX_PREFIXES,
  MAX_GRAMS,
  FOLDING_GROUPS,
  normalizeText,
  compactText,
  isAlphanumeric,
  prefixesOf,
  trigramsOf,
  searchTermsFor,
  buildSearchTokens,
  queryGrams,
};
