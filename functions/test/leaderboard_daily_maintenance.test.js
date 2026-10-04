'use strict';

// The ONE daily leaderboard schedule (leaderboardReconcileDaily, 03:30
// Pacific/Auckland) runs the raw reconciliation and then the age maintenance.
// The age maintenance has no schedule, export or job of its own.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const lbFs = require('../leaderboard/firestore_store');
const ageFs = require('../leaderboard/age_firestore');
const age = require('../leaderboard/age');
const { runAgeReconciliation } = ageFs;

const P = 10000;
const AUCKLAND_MS = (iso) => Date.parse(iso);

function okRaw() {
  return { counts: { processed: 0 }, failures: [] };
}
function okAge() {
  return { counts: { checked: 0, recomputed: 0, deleted: 0, failed: 0 }, failures: [] };
}

test('the existing daily function runs raw, then age, with the same clock', async () => {
  const calls = [];
  const out = await lbFs.runDailyLeaderboardMaintenance(1234, {
    raw: async (at) => { calls.push(['raw', at]); return okRaw(); },
    age: async (at) => { calls.push(['age', at]); return okAge(); },
  });
  assert.deepStrictEqual(calls, [['raw', 1234], ['age', 1234]]);
  assert.deepStrictEqual(out.errors, []);
  assert.ok(out.raw && out.age);
});

test('a raw failure still attempts the age maintenance, then fails the run', async () => {
  const calls = [];
  await assert.rejects(
    lbFs.runDailyLeaderboardMaintenance(1, {
      raw: async () => { calls.push('raw'); throw new Error('raw boom'); },
      age: async () => { calls.push('age'); return okAge(); },
    }),
    (err) => {
      assert.match(err.message, /raw/);
      assert.doesNotMatch(err.message, /age/);
      assert.deepStrictEqual(err.failures.map((f) => f.path), ['raw']);
      assert.strictEqual(err.failures[0].error.message, 'raw boom');
      return true;
    },
  );
  assert.deepStrictEqual(calls, ['raw', 'age']);
});

test('an age failure is reported after the raw maintenance has completed', async () => {
  const calls = [];
  await assert.rejects(
    lbFs.runDailyLeaderboardMaintenance(1, {
      raw: async () => { calls.push('raw'); return okRaw(); },
      age: async () => { calls.push('age'); throw new Error('age boom'); },
    }),
    (err) => {
      assert.deepStrictEqual(err.failures.map((f) => f.path), ['age']);
      return true;
    },
  );
  assert.deepStrictEqual(calls, ['raw', 'age']);
});

test('both failing are both attempted and both reported', async () => {
  await assert.rejects(
    lbFs.runDailyLeaderboardMaintenance(1, {
      raw: async () => { throw new Error('r'); },
      age: async () => { throw new Error('a'); },
    }),
    (err) => {
      assert.match(err.message, /raw and age/);
      assert.strictEqual(err.failures.length, 2);
      return true;
    },
  );
});

test('per-athlete failures are returned, not thrown, and do not stop the other path', async () => {
  const out = await lbFs.runDailyLeaderboardMaintenance(1, {
    raw: async () => ({ counts: { failed: 1 }, failures: [{ uid: 'r', error: 'x' }] }),
    age: async () => ({ counts: { failed: 1 }, failures: [{ uid: 'a', error: 'y' }] }),
  });
  assert.strictEqual(out.raw.failures.length, 1);
  assert.strictEqual(out.age.failures.length, 1);
  assert.deepStrictEqual(out.errors, []);
});

// ── The schedule itself ─────────────────────────────────────────────────────

test('leaderboardReconcileDaily keeps its existing 03:30 Auckland schedule', () => {
  const t = lbFs.leaderboardReconcileDaily.__endpoint.scheduleTrigger;
  assert.strictEqual(t.schedule, 'every day 03:30');
  assert.strictEqual(t.timeZone, 'Pacific/Auckland');
  assert.strictEqual(t.retryConfig.retryCount, 1);
  assert.strictEqual(lbFs.leaderboardReconcileDaily.__endpoint.timeoutSeconds, 540);
});

test('the standalone age schedule is gone: no export, no trigger, no source schedule', () => {
  assert.strictEqual(ageFs.leaderboardAgeReconcileDaily, undefined);
  assert.strictEqual(typeof ageFs.runDailyAgeMaintenance, 'function');
  assert.strictEqual(ageFs.runDailyAgeMaintenance.__endpoint, undefined, 'a plain helper, not a function');
  const scheduled = Object.entries(ageFs)
    .filter(([, v]) => v && v.__endpoint && v.__endpoint.scheduleTrigger)
    .map(([k, v]) => [k, v.__endpoint.scheduleTrigger.schedule]);
  // Only the hourly public publisher remains scheduled in the age module.
  assert.deepStrictEqual(scheduled, [['leaderboardPublicPublisher', '0 * * * *']]);
  const root = path.join(__dirname, '..');
  const index = fs.readFileSync(path.join(root, 'index.js'), 'utf8');
  assert.ok(!/leaderboardAgeReconcileDaily/.test(index));
  const src = fs.readFileSync(path.join(root, 'leaderboard', 'age_firestore.js'), 'utf8');
  assert.ok(!/03:45/.test(src));
});

test('the hourly publisher does not run the daily maintenance', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'leaderboard', 'age_firestore.js'), 'utf8');
  const publisher = src.slice(src.indexOf('const leaderboardPublicPublisher'), src.indexOf('/** A snapshot older'));
  assert.ok(publisher.length > 0);
  assert.ok(!/runAgeReconciliation|runDailyAgeMaintenance|runReconciliation/.test(publisher));
});

test('no circular import: the age module does not load the raw daily module', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'leaderboard', 'age_firestore.js'), 'utf8');
  assert.ok(!/require\(['"]\.\/firestore_store['"]\)/.test(src));
});

// ── Age maintenance through the combined run: rollover, birthdays, leap days ─

/** An in-memory age board world driven by the real age rules. */
function world(rawByBoard, dob) {
  const ages = new Map(); // `${board}/${uid}` → age entry
  const silverRuns = [];
  const recompute = (nowMs) => async (uid, board) => {
    const todayKey = new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Pacific/Auckland', year: 'numeric', month: '2-digit', day: '2-digit',
    }).format(new Date(nowMs));
    const raw = (rawByBoard[board] || []).find((r) => r.uid === uid);
    const key = `${board}/${uid}`;
    if (!raw) { ages.delete(key); return 'deleted'; }
    const silver = age.silverEligible(dob[uid], todayKey, board, raw.totalPointsUnits);
    silverRuns.push([board, uid, todayKey, silver]);
    const next = { uid, ageModelVersion: age.AGE_MODEL_VERSION, rawTotalPointsUnits: raw.totalPointsUnits,
      tieBreakDateKey: raw.tieBreakDateKey || null, leaderboardFormulaVersion: raw.formulaVersion || null,
      silverEligible: silver };
    const prev = ages.get(key);
    ages.set(key, next);
    return prev && JSON.stringify(prev) === JSON.stringify(next) ? 'unchanged' : 'set';
  };
  const ageDeps = (nowMs) => ({
    boards: () => ageFs.liveBoards(nowMs),
    listRawEntries: async (board) => rawByBoard[board] || [],
    listAgeEntries: async (board) => [...ages.entries()]
      .filter(([k]) => k.startsWith(`${board}/`)).map(([, v]) => v),
    recompute: recompute(nowMs),
  });
  return {
    ages,
    silverRuns,
    run: (nowMs) => lbFs.runDailyLeaderboardMaintenance(nowMs, {
      raw: async () => okRaw(),
      age: async (at) => runAgeReconciliation(ageDeps(at)),
    }),
  };
}

test('month rollover: the daily run moves to the new Auckland month', async () => {
  const raw = {
    '2026-10': [{ uid: 'a', totalPointsUnits: 50 * P, tieBreakDateKey: '2026-10-30', formulaVersion: 'f' }],
    '2026-11': [{ uid: 'a', totalPointsUnits: 10 * P, tieBreakDateKey: '2026-11-01', formulaVersion: 'f' }],
    all_time: [{ uid: 'a', totalPointsUnits: 60 * P, tieBreakDateKey: '2026-11-01', formulaVersion: 'f' }],
  };
  const w = world(raw, { a: '1980-01-01' });
  // 03:30 on 31 Oct and 1 Nov, Auckland (NZDT, UTC+13).
  await w.run(AUCKLAND_MS('2026-10-30T14:30:00Z'));
  assert.ok(w.ages.has('2026-10/a') && w.ages.has('all_time/a'));
  assert.ok(!w.ages.has('2026-11/a'));
  await w.run(AUCKLAND_MS('2026-10-31T14:30:00Z'));
  assert.ok(w.ages.has('2026-11/a'));
});

test('birthday: silver appears on the day AFTER the 60th birthday, via the daily run', async () => {
  const raw = { all_time: [{ uid: 'b', totalPointsUnits: 281 * P, tieBreakDateKey: 'd', formulaVersion: 'f' }] };
  const w = world(raw, { b: '1966-10-15' });
  await w.run(AUCKLAND_MS('2026-10-14T14:30:00Z')); // 15 Oct: the 60th birthday itself
  assert.strictEqual(w.ages.get('all_time/b').silverEligible, false);
  // Unchanged raw entry: still re-checked daily because it is above the threshold.
  await w.run(AUCKLAND_MS('2026-10-15T14:30:00Z')); // 16 Oct
  assert.strictEqual(w.ages.get('all_time/b').silverEligible, true);
});

test('leap-day birthday: silver from the day after the 29 Feb 60th birthday', async () => {
  const raw = { all_time: [{ uid: 'l', totalPointsUnits: 281 * P, tieBreakDateKey: 'd', formulaVersion: 'f' }] };
  const w = world(raw, { l: '29-02-1964' }); // the app's dd-mm-yyyy form; 60th birthday 29 Feb 2024
  await w.run(AUCKLAND_MS('2024-02-28T14:30:00Z')); // 29 Feb 2024, Auckland: the birthday
  assert.strictEqual(w.ages.get('all_time/l').silverEligible, false);
  await w.run(AUCKLAND_MS('2024-02-29T14:30:00Z')); // 1 Mar 2024
  assert.strictEqual(w.ages.get('all_time/l').silverEligible, true);
  // A 29 Feb birthday falls on 1 Mar in non-leap years (the existing model).
  assert.strictEqual(age.completedAge(age.parseBirthDate('1964-02-29'), '2025-02-28'), 60);
  assert.strictEqual(age.completedAge(age.parseBirthDate('1964-02-29'), '2025-03-01'), 61);
});

test('strict thresholds: exactly 280 all-time / 2,000 monthly points are not silver', async () => {
  const raw = {
    '2026-10': [{ uid: 'm', totalPointsUnits: 2000 * P, tieBreakDateKey: 'd', formulaVersion: 'f' }],
    all_time: [{ uid: 'm', totalPointsUnits: 280 * P, tieBreakDateKey: 'd', formulaVersion: 'f' }],
  };
  const w = world(raw, { m: '1950-01-01' });
  await w.run(AUCKLAND_MS('2026-10-14T14:30:00Z'));
  assert.strictEqual(w.ages.get('2026-10/m').silverEligible, false);
  assert.strictEqual(w.ages.get('all_time/m').silverEligible, false);
  raw['2026-10'][0].totalPointsUnits = 2000 * P + 1;
  raw.all_time[0].totalPointsUnits = 280 * P + 1;
  await w.run(AUCKLAND_MS('2026-10-15T14:30:00Z'));
  assert.strictEqual(w.ages.get('2026-10/m').silverEligible, true);
  assert.strictEqual(w.ages.get('all_time/m').silverEligible, true);
});

test('idempotent: a repeated (retried) daily run changes nothing and repairs orphans once', async () => {
  const raw = { all_time: [{ uid: 'x', totalPointsUnits: 10 * P, tieBreakDateKey: 'd', formulaVersion: 'f' }] };
  const w = world(raw, { x: '1990-01-01' });
  w.ages.set('all_time/orphan', { uid: 'orphan', ageModelVersion: age.AGE_MODEL_VERSION });
  const at = AUCKLAND_MS('2026-10-14T14:30:00Z');
  const first = await w.run(at);
  assert.strictEqual(first.age.counts.deleted, 1);
  assert.strictEqual(first.age.counts.recomputed, 1);
  const snapshot = JSON.stringify([...w.ages.entries()]);
  const second = await w.run(at);
  assert.strictEqual(second.age.counts.recomputed, 0);
  assert.strictEqual(second.age.counts.deleted, 0);
  assert.strictEqual(JSON.stringify([...w.ages.entries()]), snapshot);
});
