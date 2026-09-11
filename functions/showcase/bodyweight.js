// Bodyweight context for bodyweight-loaded Big Five lifts (the Chin-Up).
//
// Pure module: no Firebase. The Firestore adapter supplies weigh-in entries;
// everything here is deterministic over its inputs, so the trigger, the
// backfill and the tests all compute the same annotation from the same data.
//
// ── Why the showcase needs this ─────────────────────────────────────────────
// A Chin-Up record is a SYSTEM load: the athlete's bodyweight plus whatever is
// hanging from the belt. The profile presents it as the ADDED load ("+53.5 kg
// × 3, at 85 kg BW"), and that subtraction needs two facts the reducer alone
// does not have:
//
//   1. WHICH BODYWEIGHT. The one recorded for that lift's own date — never
//      today's, and never a weigh-in taken after the lift. Each record gets its
//      own, because the best-E1RM set and the heaviest set are usually on
//      different days.
//
//   2. WHAT THE STORED NUMBER MEANS. The legacy workout screen converted the
//      athlete's added load to an absolute load before saving (bodyweight +
//      added). WES2 saves exactly what was typed, which for a bodyweight
//      exercise is the ADDED load. Both shapes are in production history. WES2
//      is the only writer that stamps `setIndex` on a set, so a set carrying
//      one is `added`, and every other set is `absolute`. The basis is carried
//      on the record so presentation never has to guess.
//
// Neither fact takes part in record SELECTION or in the fingerprint. Which set
// holds a record, and which proof video is attached to it, are exactly what
// they were before this module existed.

'use strict';

const { localDateKey } = require('../coach/coverage');
const { bigFiveBySlot } = require('./big_five');

/** How a stored set weight relates to the athlete's bodyweight. */
const LoadBasis = {
  /** Stored weight is bodyweight + added load (legacy workout screen). */
  ABSOLUTE: 'absolute',
  /** Stored weight is the added load alone (WES2). */
  ADDED: 'added',
};

/**
 * Calendar in which a weigh-in's day is read.
 *
 * Weigh-ins are stamped at device-local noon, and the server does not know the
 * device's zone. Reading them in Pacific/Auckland — the zone the coach module
 * already defaults to — is the SAFE direction to be wrong in: for every zone
 * west of New Zealand a noon stamp falls on the same or a LATER Auckland date,
 * never an earlier one. So a weigh-in can occasionally look a day newer than
 * it was (and be skipped for a lift on its own date), but a weigh-in from after
 * the lift can never be mistaken for one before it.
 */
const BODYWEIGHT_TZ = 'Pacific/Auckland';

/**
 * How many recent weigh-ins before the cutoff are examined. A day holds at most
 * an AM and a PM entry in practice; the margin absorbs duplicates and the
 * handful of entries between the UTC cutoff and the Auckland date boundary.
 */
const BODYWEIGHT_QUERY_LIMIT = 12;

/** Snapshot record fields owned by this module. */
const ANNOTATION_FIELDS = ['loadBasis', 'bodyweightKg', 'bodyweightDateKey'];

/** True for a slot whose stored loads include the athlete's bodyweight. */
function isBodyweightSlot(slot) {
  const lift = bigFiveBySlot(slot);
  return !!(lift && lift.bodyweightLoaded);
}

/** The load basis of one stored set map (see the header). */
function setLoadBasis(setMap) {
  const idx = setMap && setMap.setIndex;
  return typeof idx === 'number' && Number.isFinite(idx)
    ? LoadBasis.ADDED
    : LoadBasis.ABSOLUTE;
}

/**
 * Exclusive upper bound for the weigh-in query, as epoch millis.
 *
 * Every instant whose Auckland date is on or before [dateKey] lies before
 * 12:00 UTC on that date, so midnight UTC after it is a sufficient bound; the
 * exact Auckland-date filter is applied in [pickBodyweightAsOf].
 */
function bodyweightCutoffMillis(dateKey) {
  const [y, m, d] = String(dateKey).split('-').map(Number);
  return Date.UTC(y, m - 1, d + 1);
}

function isKg(unit) {
  if (unit === undefined || unit === null || unit === '') return true;
  return typeof unit === 'string' && unit.trim().toLowerCase() === 'kg';
}

/**
 * The bodyweight recorded for a lift on [dateKey].
 *
 * `entries` mirror users/{uid}/weights documents:
 *   { id, weight, unit, tod, tsMillis }
 *
 * Rules, in order:
 *   * only kilogram entries with a finite, positive weight and a timestamp
 *     count (pound entries are ignored exactly as the app's own bodyweight
 *     history ignores them);
 *   * the entry's day is read in [BODYWEIGHT_TZ]; days AFTER [dateKey] are
 *     excluded, the lift's own day is included;
 *   * the latest qualifying day wins; on that day an AM entry is preferred
 *     (a missing `tod` is AM, as BodyWeightTracker treats it), then the latest
 *     timestamp, then the document id — so the choice is deterministic.
 *
 * Returns `{ weightKg, dateKey }` or null when nothing qualifies.
 */
function pickBodyweightAsOf(entries, dateKey, timeZone) {
  const tz = timeZone || BODYWEIGHT_TZ;
  let best = null;
  for (const e of entries || []) {
    if (!e || !isKg(e.unit)) continue;
    const w = typeof e.weight === 'number' ? e.weight : Number.NaN;
    if (!Number.isFinite(w) || w <= 0) continue;
    if (typeof e.tsMillis !== 'number' || !Number.isFinite(e.tsMillis)) continue;
    const day = localDateKey(new Date(e.tsMillis), tz);
    if (day > dateKey) continue;
    const cand = {
      weightKg: w,
      dateKey: day,
      am: !(typeof e.tod === 'string' && e.tod.trim().toLowerCase() === 'pm'),
      ts: e.tsMillis,
      id: typeof e.id === 'string' ? e.id : '',
    };
    if (!best || better(cand, best)) best = cand;
  }
  return best ? { weightKg: best.weightKg, dateKey: best.dateKey } : null;
}

function better(a, b) {
  if (a.dateKey !== b.dateKey) return a.dateKey > b.dateKey;
  if (a.am !== b.am) return a.am;
  if (a.ts !== b.ts) return a.ts > b.ts;
  return a.id < b.id;
}

/** [record] carrying exactly the bodyweight fields [bw] implies. */
function withBodyweight(record, bw) {
  const out = Object.assign({}, record);
  delete out.bodyweightKg;
  delete out.bodyweightDateKey;
  if (bw) {
    out.bodyweightKg = bw.weightKg;
    out.bodyweightDateKey = bw.dateKey;
  }
  return out;
}

/**
 * Returns [lifts] with every bodyweight-loaded record annotated with the
 * bodyweight for its own date. Other slots are returned untouched (same
 * object), so their published shape cannot change.
 *
 * [resolve] is `async (dateKey) => { weightKg, dateKey } | null`. Each distinct
 * date is resolved once, so a lift whose two records share a day costs one
 * lookup.
 */
async function annotateLifts(lifts, resolve, slots) {
  const out = Object.assign({}, lifts || {});
  if (typeof resolve !== 'function') return out;
  const cache = new Map();
  const lookup = async (dateKey) => {
    if (!cache.has(dateKey)) cache.set(dateKey, await resolve(dateKey));
    return cache.get(dateKey);
  };
  const targets = slots ? [...slots] : Object.keys(out);
  for (const slot of targets) {
    if (!isBodyweightSlot(slot)) continue;
    const snap = out[slot];
    if (!snap || (!snap.e1rm && !snap.heaviest)) continue;
    const next = Object.assign({}, snap);
    for (const kind of ['e1rm', 'heaviest']) {
      const r = snap[kind];
      if (!r || typeof r.dateKey !== 'string') continue;
      next[kind] = withBodyweight(r, await lookup(r.dateKey));
    }
    out[slot] = next;
  }
  return out;
}

/**
 * A copy of [snapshot] with every field this module adds removed.
 *
 * Used to prove that a rebuild changed NOTHING about record selection: the
 * stripped snapshot must equal the one published before annotations existed.
 */
function stripBodyweightAnnotations(snapshot) {
  if (!snapshot || typeof snapshot !== 'object') return snapshot;
  const copy = JSON.parse(JSON.stringify(snapshot));
  const lifts = copy.lifts || {};
  for (const slot of Object.keys(lifts)) {
    for (const kind of ['e1rm', 'heaviest']) {
      const r = lifts[slot] && lifts[slot][kind];
      if (!r) continue;
      for (const f of ANNOTATION_FIELDS) delete r[f];
    }
  }
  return copy;
}

module.exports = {
  LoadBasis,
  BODYWEIGHT_TZ,
  BODYWEIGHT_QUERY_LIMIT,
  ANNOTATION_FIELDS,
  isBodyweightSlot,
  setLoadBasis,
  bodyweightCutoffMillis,
  pickBodyweightAsOf,
  withBodyweight,
  annotateLifts,
  stripBodyweightAnnotations,
};
