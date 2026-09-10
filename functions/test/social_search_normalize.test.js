'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const normalize = require('../social/search_normalize');

// The same vector file the Dart suite reads. Asserting the generator's output
// back against the implementation looks circular, but it is not: the file is
// checked in, so this test fails the moment the implementation changes without
// the vectors being regenerated — which is exactly when the Dart client would
// start querying for terms the indexer no longer writes.
const VECTORS = JSON.parse(
  fs.readFileSync(
    path.join(__dirname, '..', 'social', 'search_normalize_vectors.json'),
    'utf8',
  ),
);

test('search normalize: checked-in vectors match the implementation', () => {
  for (const v of VECTORS.normalize) {
    assert.equal(
      normalize.normalizeText(v.input),
      v.expected,
      `normalizeText(${JSON.stringify(v.input)}) drifted from the checked-in ` +
        'vectors. Regenerate with `node scripts/gen_search_vectors.js` AND ' +
        'mirror the change in lib/social/search_normalize.dart.',
    );
  }
  for (const v of VECTORS.compact) {
    assert.equal(normalize.compactText(v.input), v.expected);
  }
  for (const v of VECTORS.queryGrams) {
    assert.deepEqual(normalize.queryGrams(v.input), v.expected);
  }
  for (const v of VECTORS.tokens) {
    assert.deepEqual(normalize.buildSearchTokens(v.identity), v.expected);
  }
});

test('search normalize: folds accents, case, punctuation and spacing', () => {
  assert.equal(normalize.normalizeText('Renée'), 'renee');
  assert.equal(normalize.normalizeText('MÜLLER'), 'muller');
  assert.equal(normalize.normalizeText('  Jean-Luc   Picard '), 'jean luc picard');
  assert.equal(normalize.normalizeText("O'Brien"), 'o brien');
});

test('search normalize: folds letters NFD does not decompose', () => {
  // These are the ones a naive NFD-only implementation silently gets wrong.
  assert.equal(normalize.normalizeText('Straße'), 'strasse');
  assert.equal(normalize.normalizeText('Søren'), 'soren');
  assert.equal(normalize.normalizeText('Ægir'), 'aegir');
  assert.equal(normalize.normalizeText('Łukasz'), 'lukasz');
  assert.equal(normalize.normalizeText('Þorsson'), 'thorsson');
  assert.equal(normalize.normalizeText('œuvre'), 'oeuvre');
});

test('search normalize: composed and decomposed accents agree', () => {
  assert.equal(
    normalize.normalizeText('café'),
    normalize.normalizeText('café'),
  );
});

test('search normalize: drops emoji and the variation selector behind it', () => {
  // Dropping the pictograph but keeping U+FE0F leaves an untypeable character
  // in the middle of the stored term, and the account stops being findable.
  assert.equal(normalize.normalizeText('\u{1F3CB}️ lifter'), 'lifter');
});

test('search normalize: never indexes the email address', () => {
  const tokens = normalize.buildSearchTokens({
    username: 'liftr',
    firstName: 'Sam',
    lastName: 'Vaughn',
    displayName: 'Sam Vaughn',
    email: 'sam.vaughn@example.com',
    emailLower: 'sam.vaughn@example.com',
  });
  const all = [...tokens.terms, ...tokens.prefixes, ...tokens.grams].join(' ');
  assert.ok(!all.includes('example'), 'email domain leaked into the index');
  assert.ok(!all.includes('vaughn@'), 'email address leaked into the index');
});

test('search normalize: arrays stay bounded for a pathological name', () => {
  const long = 'a'.repeat(400);
  const tokens = normalize.buildSearchTokens({
    username: long,
    firstName: long,
    lastName: long,
    displayName: long,
  });
  assert.ok(tokens.prefixes.length <= normalize.MAX_PREFIXES);
  assert.ok(tokens.grams.length <= normalize.MAX_GRAMS);
  assert.ok(tokens.terms.length <= 16);
});

test('search normalize: prefixes honour the minimum query length', () => {
  assert.deepEqual(normalize.prefixesOf('a'), []);
  assert.deepEqual(normalize.prefixesOf('ab'), ['ab']);
  assert.equal(
    normalize.prefixesOf('abcdefghijklmnopqrstuvwxyz').at(-1).length,
    normalize.MAX_PREFIX,
  );
});

test('search normalize: trigrams are padded so the start of a name matters', () => {
  const john = normalize.trigramsOf('john');
  assert.ok(john.includes('$jo'));
  assert.ok(john.includes('hn$'));
  // Without padding these two anagrams would produce identical gram sets.
  assert.notDeepEqual(john, normalize.trigramsOf('ohnj'));
});

test('search normalize: query grams are capped for array-contains-any', () => {
  const grams = normalize.queryGrams('a'.repeat(80));
  assert.ok(grams.length <= 10);
  assert.ok(normalize.queryGrams('anything', 30).length <= 30);
});

test('search normalize: an empty or blank identity yields empty arrays', () => {
  const tokens = normalize.buildSearchTokens({
    username: '   ',
    firstName: '',
    lastName: null,
    displayName: undefined,
  });
  assert.deepEqual(tokens.terms, []);
  assert.deepEqual(tokens.prefixes, []);
  assert.deepEqual(tokens.grams, []);
});
