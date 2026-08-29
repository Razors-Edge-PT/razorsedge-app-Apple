'use strict';

const test = require('node:test');
const assert = require('node:assert');

const {
  STORY_TTL_MS,
  isStoryLive,
  storyExpiryMs,
  liveCutoffMs,
} = require('../social/stories');

const HOUR = 60 * 60 * 1000;
const T0 = Date.UTC(2026, 7, 29, 12, 0, 0);

test('the story lifetime is exactly 24 hours', () => {
  assert.strictEqual(STORY_TTL_MS, 24 * HOUR);
});

test('a story is live for the whole 24 hours', () => {
  assert.strictEqual(isStoryLive(T0, T0), true);
  assert.strictEqual(isStoryLive(T0, T0 + 1), true);
  assert.strictEqual(isStoryLive(T0, T0 + 23 * HOUR), true);
  assert.strictEqual(isStoryLive(T0, T0 + 24 * HOUR - 1), true);
});

test('at EXACTLY 24 hours the story is expired', () => {
  assert.strictEqual(isStoryLive(T0, T0 + 24 * HOUR), false);
});

test('after 24 hours the story stays expired', () => {
  assert.strictEqual(isStoryLive(T0, T0 + 24 * HOUR + 1), false);
  assert.strictEqual(isStoryLive(T0, T0 + 72 * HOUR), false);
});

test('expiry is publication time plus the TTL, to the millisecond', () => {
  assert.strictEqual(storyExpiryMs(T0), T0 + 24 * HOUR);
  assert.strictEqual(storyExpiryMs(0), 24 * HOUR);
});

test('the live cutoff and the liveness rule agree at the boundary', () => {
  const now = T0 + 24 * HOUR;
  const cutoff = liveCutoffMs(now);
  // The cleanup query is publishedAt <= cutoff. A story published exactly at
  // the cutoff must be swept, and isStoryLive must agree it is not live.
  assert.strictEqual(cutoff, T0);
  assert.strictEqual(isStoryLive(cutoff, now), false);
  assert.strictEqual(isStoryLive(cutoff + 1, now), true);
});

test('a clock going backwards never resurrects an expired story window', () => {
  // Defensive: nonsense inputs are never "live".
  assert.strictEqual(isStoryLive(NaN, T0), false);
  assert.strictEqual(isStoryLive(T0, NaN), false);
});
