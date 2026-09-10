'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const idx = require('../social/search_index');

const publicProfile = (over) => ({
  username: 'IronSam',
  usernameLower: 'ironsam',
  fullName: 'Samantha Vaughn',
  displayName: 'Sam',
  photoURL: 'https://example.test/avatar.jpg?alt=media&token=abc',
  // Everything below is present on real users_public documents and must NOT
  // reach the projection.
  emailLower: 'samantha.vaughn@example.com',
  email: 'Samantha.Vaughn@example.com',
  phone: '+15551234567',
  dob: '1994-02-11',
  sex: 'F',
  isCoach: true,
  stripeCustomerId: 'cus_123',
  profileShowcaseV1: { bench: { weight: 100 } },
  ...over,
});

// ── Privacy ─────────────────────────────────────────────────────────────────

test('search index: the projection carries no private fields', () => {
  const doc = idx.buildSearchIndexDoc('u1', publicProfile());
  const allowed = new Set([
    'uid',
    'username',
    'usernameLower',
    'displayName',
    'fullName',
    'firstName',
    'lastName',
    'photoURL',
    'terms',
    'prefixes',
    'grams',
  ]);
  for (const key of Object.keys(doc)) {
    assert.ok(allowed.has(key), `projection leaked field "${key}"`);
  }
});

test('search index: the email address is not indexed or stored', () => {
  // The legacy search ran a prefix range over emailLower and returned the
  // matched email to the client, which made it an enumeration primitive.
  const doc = idx.buildSearchIndexDoc('u1', publicProfile());
  const blob = JSON.stringify(doc).toLowerCase();
  assert.ok(!blob.includes('example.com'), 'email domain reached the index');
  assert.ok(!blob.includes('samantha.vaughn@'), 'email reached the index');
  assert.ok(!blob.includes('cus_123'), 'billing id reached the index');
  assert.ok(!blob.includes('5551234567'), 'phone number reached the index');
});

// ── Name derivation ─────────────────────────────────────────────────────────

test('search index: first and last are derived from the single fullName', () => {
  assert.deepEqual(idx.splitFullName('Samantha Vaughn'), {
    firstName: 'Samantha',
    lastName: 'Vaughn',
  });
  // A one-word name is a first name, not a surname.
  assert.deepEqual(idx.splitFullName('Cher'), {
    firstName: 'Cher',
    lastName: '',
  });
  assert.deepEqual(idx.splitFullName('Anna Maria de la Cruz'), {
    firstName: 'Anna Maria de la',
    lastName: 'Cruz',
  });
  assert.deepEqual(idx.splitFullName('   '), { firstName: '', lastName: '' });
  assert.deepEqual(idx.splitFullName(null), { firstName: '', lastName: '' });
});

test('search index: an account is findable by each part of its name', () => {
  const doc = idx.buildSearchIndexDoc('u1', publicProfile());
  for (const q of ['ironsam', 'samantha', 'vaughn', 'samantha vaughn', 'samanthavaughn']) {
    assert.ok(
      doc.terms.includes(q) || doc.prefixes.includes(q),
      `"${q}" would not find this account`,
    );
  }
});

// ── Absence and edge cases ──────────────────────────────────────────────────

test('search index: a deleted account produces no document', () => {
  assert.equal(idx.buildSearchIndexDoc('u1', null), null);
  assert.equal(idx.buildSearchIndexDoc('', publicProfile()), null);
});

test('search index: an account with nothing to match on is not indexed', () => {
  // A nameless row would surface in front of anyone whose query produced no
  // tokens.
  assert.equal(
    idx.buildSearchIndexDoc('u1', {
      username: '',
      fullName: '   ',
      displayName: '',
    }),
    null,
  );
});

test('search index: a missing avatar is an empty string, never undefined', () => {
  const doc = idx.buildSearchIndexDoc('u1', {
    username: 'sam',
    fullName: 'Sam V',
  });
  for (const [k, v] of Object.entries(doc)) {
    assert.notEqual(v, undefined, `field ${k} was undefined`);
  }
  assert.equal(doc.photoURL, '');
});

test('search index: usernameLower is derived when the stored one is missing', () => {
  const doc = idx.buildSearchIndexDoc('u1', {
    username: 'IronSam',
    fullName: 'Sam V',
  });
  assert.equal(doc.usernameLower, 'ironsam');
});

// ── Change detection ────────────────────────────────────────────────────────

test('search index: an identical rebuild compares equal', () => {
  const a = idx.buildSearchIndexDoc('u1', publicProfile());
  const b = idx.buildSearchIndexDoc('u1', publicProfile());
  assert.equal(idx.sameIndexDoc(a, b), true);
});

test('search index: a rename, a new avatar and a new name all compare unequal', () => {
  const base = idx.buildSearchIndexDoc('u1', publicProfile());
  assert.equal(
    idx.sameIndexDoc(base, idx.buildSearchIndexDoc('u1', publicProfile({ username: 'SteelSam', usernameLower: 'steelsam' }))),
    false,
  );
  assert.equal(
    idx.sameIndexDoc(base, idx.buildSearchIndexDoc('u1', publicProfile({ photoURL: 'https://example.test/new.jpg' }))),
    false,
  );
  assert.equal(
    idx.sameIndexDoc(base, idx.buildSearchIndexDoc('u1', publicProfile({ fullName: 'Samantha Vaughn-Reed' }))),
    false,
  );
});

test('search index: comparison never treats a missing document as equal', () => {
  const base = idx.buildSearchIndexDoc('u1', publicProfile());
  assert.equal(idx.sameIndexDoc(base, null), false);
  assert.equal(idx.sameIndexDoc(null, base), false);
  assert.equal(idx.sameIndexDoc(null, null), false);
});

test('search index: an accented name is findable unaccented', () => {
  const doc = idx.buildSearchIndexDoc('u2', {
    username: 'renee',
    fullName: 'Renée Åström',
  });
  assert.ok(doc.terms.includes('renee astrom'));
  assert.ok(doc.prefixes.includes('astrom'));
});
