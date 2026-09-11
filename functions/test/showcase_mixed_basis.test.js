'use strict';

// Chin-Up records across MIXED storage bases.
//
// Production holds two shapes for the same lift:
//   legacy workout screen  weight = bodyweight + added   (plus weightAdded,
//                          the load the athlete typed, on most sets)
//   WES2                   weight = the added load alone (setIndex stamped)
// Comparing the raw numbers ranked an old 138.5 kg total above a newer +60 kg
// WES2 set forever. These tests pin the corrected rule: every Chin-Up set is
// normalised through ONE boundary to its added load, its total load and the
// bodyweight recorded for its own date, and records are chosen on those.
//
// Written against the pre-fix code first (every Chin-Up expectation below is
// red on 5eac4f18); only the golden other-lift test was green there, because
// the golden IS that code's output.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { buildShowcase, recordFingerprint } = require('../showcase/reducer');
const {
  applyWorkoutDay,
  rebuildAll,
  refreshBodyweight,
  memoryStore,
} = require('../showcase/store');
const { pickBodyweightAsOf } = require('../showcase/bodyweight');
const { showcaseE1rm } = require('../showcase/e1rm_spec');

const CHIN = 'XM9026peNIu0R8qh7UqY';
const OLD = '2026-05-01';
const NEW = '2026-08-10';

const chinDay = (sets) => ({ exercises: [{ exerciseId: CHIN, name: 'Chin-Up', sets }] });
/** A legacy-screen set: total stored, typed added load alongside. */
const legacy = (total, added, reps) => ({ weight: total, weightAdded: added, addedWeight: added, reps });
/** A legacy set from before the typed field existed: the total alone. */
const legacyUntyped = (total, reps) => ({ weight: total, reps });
/** A WES2 set: the added load, verbatim. */
const wes2 = (added, reps, setIndex = 0) => ({ setIndex, weight: added, reps });

const bw = (weightKg, dateKey) => ({ weightKg, dateKey });

function chinOf(history, bodyweightByDate) {
  return buildShowcase(history, { bodyweightByDate }).lifts.chinUp;
}

const close = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} ≉ ${b}`);

// ── Selection ───────────────────────────────────────────────────────────────

test('an old total-basis record loses to a newer, stronger WES2 record', () => {
  const chin = chinOf(
    { [OLD]: chinDay([legacy(138.5, 53.5, 3)]), [NEW]: chinDay([wes2(60, 3)]) },
    { [OLD]: bw(85, OLD), [NEW]: bw(85, NEW) },
  );
  // Best E1RM: +61.6 (138.5 total) against E1RM(145) − 85 = +68.5.
  assert.equal(chin.e1rm.dateKey, NEW);
  assert.equal(chin.e1rm.weight, 60, 'the stored value is untouched');
  assert.equal(chin.e1rm.loadBasis, 'added');
  assert.equal(chin.e1rm.addedKg, 60);
  assert.equal(chin.e1rm.totalKg, 145);
  close(chin.e1rm.addedE1rm, showcaseE1rm(145, 3) - 85);
  close(chin.e1rm.totalE1rm, showcaseE1rm(145, 3));
  assert.equal(chin.e1rm.bodyweightKg, 85);
  // Heaviest: +60 against +53.5 — never 138.5 against 60.
  assert.equal(chin.heaviest.dateKey, NEW);
  assert.equal(chin.heaviest.addedKg, 60);
});

test('a newer, WEAKER WES2 record does not displace the old total-basis one', () => {
  const chin = chinOf(
    { [OLD]: chinDay([legacy(138.5, 53.5, 3)]), [NEW]: chinDay([wes2(40, 3)]) },
    { [OLD]: bw(85, OLD), [NEW]: bw(85, NEW) },
  );
  assert.equal(chin.e1rm.dateKey, OLD);
  assert.equal(chin.e1rm.loadBasis, 'absolute');
  assert.equal(chin.e1rm.addedKg, 53.5);
  assert.equal(chin.e1rm.totalKg, 138.5);
  close(chin.e1rm.addedE1rm, showcaseE1rm(138.5, 3) - 85);
  assert.equal(chin.heaviest.dateKey, OLD);
  assert.equal(chin.heaviest.addedKg, 53.5);
});

test('each record uses the bodyweight recorded for its own date', () => {
  // Legacy +50 at 90 kg vs WES2 +52 at 80 kg. The raw numbers (140 vs 52)
  // say legacy; the normalised ones say WES2 on both counts.
  const chin = chinOf(
    { [OLD]: chinDay([legacy(140, 50, 3)]), [NEW]: chinDay([wes2(52, 3)]) },
    { [OLD]: bw(90, OLD), [NEW]: bw(80, NEW) },
  );
  close(showcaseE1rm(140, 3) - 90, 58.235294, 1e-5);
  close(showcaseE1rm(132, 3) - 80, 59.764706, 1e-5);
  assert.equal(chin.e1rm.dateKey, NEW);
  assert.equal(chin.e1rm.bodyweightKg, 80);
  assert.equal(chin.heaviest.dateKey, NEW);
  assert.equal(chin.heaviest.bodyweightKg, 80);
});

test('the typed added load is authoritative when the legacy screen stored one', () => {
  // The legacy total embeds whatever bodyweight the old screen had loaded
  // (here 80 kg); the athlete's weigh-in that day was 85 kg. The typed +55 is
  // what hung from the belt, and the total is rebuilt from it.
  const chin = chinOf(
    { [OLD]: chinDay([legacy(135, 55, 3)]) },
    { [OLD]: bw(85, OLD) },
  );
  assert.equal(chin.heaviest.addedKg, 55);
  assert.equal(chin.heaviest.totalKg, 140);
  close(chin.e1rm.addedE1rm, showcaseE1rm(140, 3) - 85);
});

test('equal performances: the later date wins, on both records', () => {
  const chin = chinOf(
    { [OLD]: chinDay([legacy(140, 55, 3)]), [NEW]: chinDay([wes2(55, 3)]) },
    { [OLD]: bw(85, OLD), [NEW]: bw(85, NEW) },
  );
  assert.equal(chin.e1rm.dateKey, NEW);
  assert.equal(chin.heaviest.dateKey, NEW);
});

test('rep ranges: the best E1RM and the heaviest can be different sets', () => {
  // +40 × 8 → E1RM(125, 8) − 85 = +70.2; +60 × 2 → E1RM(145, 2) − 85 = +64.1.
  const chin = chinOf(
    { [OLD]: chinDay([legacy(145, 60, 2)]), [NEW]: chinDay([wes2(40, 8)]) },
    { [OLD]: bw(85, OLD), [NEW]: bw(85, NEW) },
  );
  assert.equal(chin.e1rm.dateKey, NEW);
  assert.equal(chin.e1rm.reps, 8);
  assert.equal(chin.heaviest.dateKey, OLD);
  assert.equal(chin.heaviest.addedKg, 60);
});

test('within one day, sets are compared on the same normalised terms', () => {
  const chin = chinOf(
    { [NEW]: chinDay([wes2(30, 8, 0), wes2(45, 3, 1), wes2(50, 1, 2)]) },
    { [NEW]: bw(85, NEW) },
  );
  // E1RM(115, 8) − 85 = 57.8; E1RM(130, 3) − 85 = 52.6; E1RM(135, 1) − 85 = 50.
  assert.equal(chin.e1rm.addedKg, 30);
  assert.equal(chin.heaviest.addedKg, 50);
});

// ── Missing bodyweight ──────────────────────────────────────────────────────

test('without a recorded bodyweight, a WES2 E1RM cannot outrank a known record', () => {
  const chin = chinOf(
    { [OLD]: chinDay([legacy(138.5, 53.5, 3)]), [NEW]: chinDay([wes2(90, 3)]) },
    { [OLD]: bw(85, OLD) }, // nothing recorded on or before NEW
  );
  assert.equal(chin.e1rm.dateKey, OLD, 'unknown never outranks known');
  // Its ADDED load is known without a bodyweight, so it still competes there.
  assert.equal(chin.heaviest.dateKey, NEW);
  assert.equal(chin.heaviest.addedKg, 90);
  assert.equal('totalKg' in chin.heaviest, false);
  assert.equal('bodyweightKg' in chin.heaviest, false);
});

test('a legacy total with no typed load and no bodyweight ranks below any known record', () => {
  const chin = chinOf(
    { [OLD]: chinDay([legacyUntyped(150, 3)]), [NEW]: chinDay([wes2(20, 3)]) },
    { [NEW]: bw(85, NEW) },
  );
  assert.equal(chin.e1rm.dateKey, NEW);
  assert.equal(chin.heaviest.dateKey, NEW);
});

test('with nothing recorded at all, the choice is still deterministic', () => {
  const history = {
    '2026-01-05': chinDay([legacyUntyped(150, 3), legacyUntyped(140, 5)]),
    [NEW]: chinDay([wes2(20, 3), wes2(25, 1, 1)]),
  };
  const a = chinOf(history, {});
  const b = chinOf(JSON.parse(JSON.stringify(history)), {});
  assert.deepEqual(a, b);
  assert.equal(a.heaviest.addedKg, 25, 'known added loads still rank on their own');
});

// ── No future weigh-in ──────────────────────────────────────────────────────

const weighIn = (dateKey, weight) => {
  const [y, m, d] = dateKey.split('-').map(Number);
  return { id: `w-${dateKey}`, weight, unit: 'kg', tsMillis: Date.UTC(y, m - 1, d, 0, 0, 0) };
};

test('a weigh-in dated after the lift is never its bodyweight', async () => {
  const entries = [weighIn('2026-08-01', 80), weighIn('2026-08-20', 95)];
  const store = memoryStore({ bodyweightAsOf: async (d) => pickBodyweightAsOf(entries, d) });
  await applyWorkoutDay(store, NEW, chinDay([wes2(50, 3)]));
  const r = (await store.getSnapshot()).lifts.chinUp.e1rm;
  assert.equal(r.bodyweightKg, 80);
  assert.equal(r.bodyweightDateKey, '2026-08-01');
  assert.equal(r.totalKg, 130);
});

// ── Store paths ─────────────────────────────────────────────────────────────

test('incremental application matches a full rebuild on mixed history', async () => {
  const entries = [weighIn('2026-04-01', 85), weighIn('2026-08-01', 82)];
  const resolve = async (d) => pickBodyweightAsOf(entries, d);
  const history = {
    [OLD]: chinDay([legacy(138.5, 53.5, 3), legacy(142, 57, 2)]),
    '2026-06-15': chinDay([wes2(55, 4)]),
    [NEW]: chinDay([wes2(60, 3), wes2(40, 8, 1)]),
  };
  const inc = memoryStore({ bodyweightAsOf: resolve });
  for (const d of Object.keys(history)) await applyWorkoutDay(inc, d, history[d]);
  const reb = memoryStore({ bodyweightAsOf: resolve });
  const snap = await rebuildAll(reb, Object.entries(history));
  assert.deepEqual(snap, await inc.getSnapshot());
  // And both chose on normalised terms.
  assert.equal(snap.lifts.chinUp.heaviest.dateKey, NEW);
});

test('a weigh-in recorded later re-ranks the records it makes comparable', async () => {
  const entries = [weighIn('2026-04-01', 85)];
  const store = memoryStore({ bodyweightAsOf: async (d) => pickBodyweightAsOf(entries, d) });
  await applyWorkoutDay(store, OLD, chinDay([legacy(138.5, 53.5, 3)]));
  // Recorded bodyweight on or before NEW is the April one, so NEW is known.
  // Make NEW unknown first by using a day before any weigh-in…
  const EARLY = '2026-03-10';
  await applyWorkoutDay(store, EARLY, chinDay([wes2(70, 3)]));
  let chin = (await store.getSnapshot()).lifts.chinUp;
  assert.equal(chin.e1rm.dateKey, OLD, 'EARLY has no bodyweight yet');

  // …then the athlete back-fills a weigh-in for that week.
  entries.push(weighIn('2026-03-09', 84));
  const r = await refreshBodyweight(store);
  assert.equal(r.changed, true);
  chin = (await store.getSnapshot()).lifts.chinUp;
  assert.equal(chin.e1rm.dateKey, EARLY, 'E1RM(154) − 84 = +78 now outranks +61.6');
  assert.equal(chin.e1rm.bodyweightKg, 84);
  // A second delivery of the same weigh-in changes nothing.
  assert.equal((await refreshBodyweight(store)).changed, false);
});

test('the winning record keeps the fingerprint of its stored set', () => {
  const chin = chinOf(
    { [OLD]: chinDay([legacy(138.5, 53.5, 3)]), [NEW]: chinDay([wes2(60, 3)]) },
    { [OLD]: bw(85, OLD), [NEW]: bw(85, NEW) },
  );
  assert.equal(
    chin.e1rm.fingerprint,
    recordFingerprint({ slot: 'chinUp', exerciseId: CHIN, dateKey: NEW, setKey: 's0', weight: 60, reps: 3 }),
  );
});

// ── The other four lifts ────────────────────────────────────────────────────

test('Squat, Bench, Deadlift and the unilateral press publish exactly what they did', () => {
  const golden = JSON.parse(fs.readFileSync(
    path.join(__dirname, 'fixtures', 'showcase_other_lifts_golden.json'), 'utf8'));
  // Passing bodyweights must not matter to them either.
  const withBw = {};
  for (const d of Object.keys(golden.history)) withBw[d] = bw(85, d);
  for (const opts of [undefined, { bodyweightByDate: withBw }]) {
    const lifts = buildShowcase(golden.history, opts).lifts;
    for (const slot of Object.keys(golden.lifts)) {
      assert.deepEqual(lifts[slot], golden.lifts[slot], slot);
    }
  }
});
