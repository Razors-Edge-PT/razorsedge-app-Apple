// Deterministic client-message composition. Pure module. NO LLM.
//
// The draft gives the coach facts to write their own comments around:
//
//   • one short line per achievement (see praise.js selectAchievements), e.g.
//       150kg for 8 reps on the bench press
//       150kg for 8 reps on the bench press, New E1RM PB of 172.5kg
//       125kg for 4 reps on the Larsen bench press
//   • then, separately, the bodyweight lines (trend / milestone / reminder).
//
// No greetings, names, emojis, filler, closings or workout congratulations.
// Bodyweight phrase variants are fixed template tables chosen once per report
// via the persisted `variantSeed`, so regenerating the text for the same
// report never flips wording.

'use strict';

// Explicit aliases, keyed by the exercise's exact canonical stored display
// name. An alias is listed only when it unambiguously names that one exercise;
// every other exercise keeps its FULL stored name — qualifiers such as the
// variant, grip, equipment or incline after a comma are identity, never noise.
const EXERCISE_ALIASES = Object.freeze({
  'Bench Press, Barbell': 'bench press',
  'Bench Press, Larsen Press': 'Larsen bench press',
  'Back Squat, Barbell': 'squat',
  'Deadlift, Conventional': 'deadlift',
  'Romanian Deadlift': 'RDL',
  'Lat Pull Down, Supinated': 'supinated lat pull',
  'Butterfly Dumbbell Raise': "Butterfly DB's",
  'Flat Bench Dumbbell Press': 'Flat Bench DB',
  'Bulgarian Split Squat': 'BG split squat',
});

const UNNAMED_EXERCISE = 'unnamed exercise';

/** Full stored display name, trimmed. Never truncated. */
function cleanExerciseName(name) {
  const s = typeof name === 'string' ? name.trim() : '';
  return s || UNNAMED_EXERCISE;
}

/** The label a line uses: the explicit alias, else the full stored name. */
function exerciseLabel(name) {
  const full = cleanExerciseName(name);
  return Object.prototype.hasOwnProperty.call(EXERCISE_ALIASES, full)
    ? EXERCISE_ALIASES[full]
    : full;
}

/**
 * Labels for every exercise id in one message. If two DIFFERENT exercise ids
 * would read identically through an alias (e.g. a custom exercise literally
 * named "bench press" beside the barbell bench press), both fall back to
 * their full stored names so the lines stay distinguishable.
 */
function labelsFor(achievements) {
  const nameById = new Map();
  for (const a of achievements || []) {
    if (!nameById.has(a.exerciseId)) nameById.set(a.exerciseId, cleanExerciseName(a.exerciseName));
  }
  const idsByLabel = new Map();
  for (const [id, name] of nameById) {
    const label = exerciseLabel(name).toLowerCase();
    if (!idsByLabel.has(label)) idsByLabel.set(label, new Set());
    idsByLabel.get(label).add(id);
  }
  const out = new Map();
  for (const [id, name] of nameById) {
    const label = exerciseLabel(name);
    out.set(id, idsByLabel.get(label.toLowerCase()).size > 1 ? name : label);
  }
  return out;
}

/** Deterministic small hash → index, stable per (seed, salt). */
function seededIndex(variantSeed, salt, n) {
  const s = `${variantSeed || 0}|${salt}`;
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return h % n;
}

function fmtKg(v) {
  if (v == null || !Number.isFinite(Number(v))) return '?';
  return `${Math.round(Number(v) * 10) / 10}kg`;
}

/**
 * A load [v] as the athlete knows it. A bodyweight exercise's achievement
 * carries the bodyweight its totals were computed at and is shown as the load
 * ADDED to it ("+20kg", or "bodyweight"); every other load exactly as stored.
 */
function fmtLoad(bodyweightKg, v) {
  if (v == null || typeof bodyweightKg !== 'number' || !(bodyweightKg > 0)) return fmtKg(v);
  const r = Math.round((v - bodyweightKg) * 10) / 10;
  if (r === 0) return 'bodyweight';
  return `${r > 0 ? '+' : '−'}${Math.abs(r)}kg`;
}

function repsText(reps) {
  return `${reps} rep${reps === 1 ? '' : 's'}`;
}

function fmtRir(v) {
  return String(Math.round(Number(v) * 10) / 10);
}

// ── Training lines ──────────────────────────────────────────────────────────

/** One achievement → one line (without the bullet). */
function achievementLine(a, label) {
  const name = label || exerciseLabel(a.exerciseName);
  const e1 = a.e1rm;
  const e1Bw = e1 && typeof e1.bodyweightKg === 'number' ? e1.bodyweightKg : a.bodyweightKg;
  const e1Text = e1 ? `New E1RM PB of ${fmtLoad(e1Bw, e1.e1rmKg)}` : null;

  if (a.weightKg == null || a.reps == null) {
    // Legacy E1RM event without its contributing set.
    return `${e1Text} on the ${name}`;
  }

  const parts = [`${fmtLoad(a.bodyweightKg, a.weightKg)} for ${repsText(a.reps)} on the ${name}`];
  if (a.maxWeight) parts.push('all-time heaviest');
  if (a.rirMatch && !a.maxWeight && !a.rep) {
    parts.push(`matched PB at RIR ${fmtRir(a.rirMatch.rir)} (previously RIR ${fmtRir(a.rirMatch.prevRir)})`);
  }
  if (e1Text) parts.push(e1Text);
  return parts.join(', ');
}

/** Achievements → lines, in the order selectAchievements returned. */
function trainingLines(achievements) {
  const list = achievements || [];
  const labels = labelsFor(list);
  return list.map((a) => achievementLine(a, labels.get(a.exerciseId)));
}

// ── Bodyweight lines ────────────────────────────────────────────────────────

const WEIGH_IN_REMINDER = 'Can I get you to weigh in please?';

const BW_LINES = {
  cut_onTrack: ['Nice work on the diet, weight coming down'],
  cut_offTrack: [
    'Body weight not going down at the moment, how is the diet going?',
    "Body weight hasn't really moved down, anywhere you're struggling with the diet?",
    'How are you going with the diet?',
  ],
  bulk_onTrack: ['Nice work on the diet, weight going up'],
  bulk_offTrack: [
    'Body weight not going up at the moment, how is the diet going?',
    'How are you going with the diet?',
  ],
  maintain_stable: ['Body weight holding stable'],
  maintain_driftUp: [
    'Body weight has been creeping up a little, how are you going with the diet?',
  ],
  maintain_driftDown: [
    'Body weight has been dipping a little, how are you going with the diet?',
  ],
};

function milestoneSentence(goal, milestoneId) {
  if (!milestoneId) return null;
  const boundary = Number(String(milestoneId).split('_')[1]);
  if (!Number.isFinite(boundary)) return null;
  if (goal === 'cut') return `Under ${boundary}kg now, great milestone`;
  if (goal === 'bulk') return `Reached the ${boundary}kg mark, great milestone`;
  return null;
}

function trendLineKey(goal, trend) {
  if (goal === 'cut') return trend === 'onTrack' ? 'cut_onTrack' : 'cut_offTrack';
  if (goal === 'bulk') return trend === 'onTrack' ? 'bulk_onTrack' : 'bulk_offTrack';
  if (goal === 'maintain') {
    if (trend === 'stable') return 'maintain_stable';
    if (trend === 'driftUp') return 'maintain_driftUp';
    if (trend === 'driftDown') return 'maintain_driftDown';
  }
  return null;
}

/**
 * Bodyweight lines: goal trend, a newly reached milestone, and at most ONE
 * weigh-in reminder.
 * @param {Object} bw { goal, trend, weighInStatus, newMilestoneId }
 */
function bodyweightLines(bw, seed) {
  if (!bw) return [];
  const lines = [];
  if (bw.trend && bw.trend !== 'insufficient') {
    const key = trendLineKey(bw.goal, bw.trend);
    if (key && BW_LINES[key]) {
      const options = BW_LINES[key];
      lines.push(options[seededIndex(seed, key, options.length)]);
    }
    const m = milestoneSentence(bw.goal, bw.newMilestoneId);
    if (m) lines.push(m);
  }
  if (bw.weighInStatus === 'due' || bw.weighInStatus === 'overdue') {
    lines.push(WEIGH_IN_REMINDER);
  }
  return lines;
}

/** Bodyweight block as text, or null. */
function bodyweightParagraph(bw, seed) {
  const lines = bodyweightLines(bw, seed);
  return lines.length ? lines.join('\n') : null;
}

// ── Full draft ──────────────────────────────────────────────────────────────

/**
 * Achievement bullets, then (separately) the bodyweight lines. Returns null
 * when there is genuinely nothing to say.
 */
function composeDraft({ achievements, bodyweight, variantSeed }) {
  const training = trainingLines(achievements);
  const bw = bodyweightParagraph(bodyweight, variantSeed);
  const blocks = [];
  if (training.length) blocks.push(training.map((l) => `• ${l}`).join('\n'));
  if (bw) blocks.push(bw);
  return blocks.length ? blocks.join('\n\n') : null;
}

module.exports = {
  EXERCISE_ALIASES,
  WEIGH_IN_REMINDER,
  exerciseLabel,
  cleanExerciseName,
  labelsFor,
  seededIndex,
  achievementLine,
  trainingLines,
  bodyweightLines,
  bodyweightParagraph,
  composeDraft,
  milestoneSentence,
};
