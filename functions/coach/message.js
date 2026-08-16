// Deterministic client-message composition. Pure module. NO LLM.
//
// Greetings, exercise aliases and phrase variants are fixed template tables.
// Random choices (male greeting, bench alias) are made once per report via a
// persisted `variantSeed`, so rebuilding a screen or regenerating the text
// for the same report never flips wording.

'use strict';

// Alias table keyed by the exercise's canonical stored display name. Workout
// rows persist both exerciseId and the canonical name, and exercise-catalog
// document ids are environment-generated, so the stable cross-environment key
// is the canonical name string (resolved from the id at event time).
const EXERCISE_ALIASES = {
  'Bench Press, Barbell': ['bench', 'bench press'], // variant chosen by seed
  'Back Squat, Barbell': ['squat'],
  'Deadlift, Conventional': ['deadlift'],
  'Romanian Deadlift': ['RDL'],
  'Lat Pull Down, Supinated': ['supinated lat pull'],
  'Butterfly Dumbbell Raise': ["Butterfly DB's"],
  'Flat Bench Dumbbell Press': ['Flat Bench DB'],
  'Bulgarian Split Squat': ['BG split squat'],
};

/** Conservative cleanup for names not in the alias table: drop the comma
 *  qualifier ("Seated Row, Cable" → "Seated Row") and nothing cleverer. */
function cleanExerciseName(name) {
  if (!name) return 'that lift';
  const base = String(name).split(',')[0].trim();
  return base || String(name);
}

/** Display alias for an exercise, stable under variantSeed. */
function exerciseAlias(name, variantSeed) {
  const aliases = EXERCISE_ALIASES[name];
  if (aliases && aliases.length) {
    return aliases[seededIndex(variantSeed, name, aliases.length)];
  }
  return cleanExerciseName(name);
}

const MALE_GREETINGS = ['Hey bro', 'Hey man'];

/**
 * Greeting for the combined check-in.
 * gender: 'male' | 'female' | null/other.
 */
function greeting(gender, firstName, variantSeed) {
  if (gender === 'male') {
    return MALE_GREETINGS[seededIndex(variantSeed, 'greeting', MALE_GREETINGS.length)];
  }
  if (gender === 'female' && firstName) return `Hi ${firstName}`;
  return firstName ? `Hi ${firstName}` : 'Hi';
}

/** Weigh-in-prompt greeting ("Heya Sarah" style for female athletes). */
function weighInGreeting(gender, firstName, variantSeed) {
  if (gender === 'male') {
    return MALE_GREETINGS[seededIndex(variantSeed, 'greeting', MALE_GREETINGS.length)];
  }
  if (firstName) return `Heya ${firstName}`;
  return 'Heya';
}

/** Deterministic small hash → index, stable per (seed, salt). */
function seededIndex(variantSeed, salt, n) {
  const s = `${variantSeed || 0}|${salt}`;
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return h % n;
}

function fmtKg(v) {
  if (v == null) return '?';
  const r = Math.round(v * 10) / 10;
  return Number.isInteger(r) ? `${r}kg` : `${r}kg`;
}

// ── Training sentences ──────────────────────────────────────────────────────

function repPBSentence(praise, seed, { lead }) {
  const ev = praise.event;
  const alias = exerciseAlias(ev.exerciseName, seed);
  let s;
  if (lead) {
    s = `nice work hitting ${fmtKg(ev.weightKg)} for ${ev.reps} on the ${alias}, new ${ev.reps} rep target PB 💪`;
  } else {
    s = `${fmtKg(ev.weightKg)} for ${ev.reps} on the ${alias} also a new rep target PB`;
  }
  if (praise.alsoE1rm) {
    s += lead
      ? ` (that's a new E1RM PB too, ${fmtKg(praise.alsoE1rm.e1rmKg)} excluding RIR)`
      : ` — new E1RM PB as well, ${fmtKg(praise.alsoE1rm.e1rmKg)} excluding RIR`;
  }
  return s;
}

/** All-time heaviest weight on the exercise — the top-ranked achievement.
 *  Deliberately factual: weight, reps, exercise, no inferred claim. */
function maxWeightPBSentence(praise, seed, { lead }) {
  const ev = praise.event;
  const alias = exerciseAlias(ev.exerciseName, seed);
  let s;
  if (lead) {
    s = `new all-time heaviest lift on the ${alias}: ${fmtKg(ev.weightKg)} for ${ev.reps} — huge work 💪`;
  } else {
    s = `${fmtKg(ev.weightKg)} for ${ev.reps} on the ${alias} is a new all-time heaviest lift too`;
  }
  if (praise.alsoE1rm) {
    s += lead
      ? ` (that's a new E1RM PB too, ${fmtKg(praise.alsoE1rm.e1rmKg)} excluding RIR)`
      : ` — new E1RM PB as well, ${fmtKg(praise.alsoE1rm.e1rmKg)} excluding RIR`;
  }
  return s;
}

/** Matched an existing PB at a strictly lower logged RIR. Framed as EFFORT —
 *  the athlete took the same performance closer to failure — never as a
 *  strength improvement, because the weight and reps did not change. */
function rirMatchPBSentence(praise, seed, { lead }) {
  const ev = praise.event;
  const alias = exerciseAlias(ev.exerciseName, seed);
  if (lead) {
    return `matched your ${fmtKg(ev.weightKg)} for ${ev.reps} PB on the ${alias} at a lower logged RIR — strong effort 💪`;
  }
  return `matched your ${fmtKg(ev.weightKg)} for ${ev.reps} PB on the ${alias} at a lower logged RIR too — strong effort`;
}

function e1rmPBSentence(praise, seed, { lead }) {
  const ev = praise.event;
  const alias = exerciseAlias(ev.exerciseName, seed);
  if (lead) {
    return `saw you got a new E1RM PB on the ${alias}, nice work, ${fmtKg(ev.e1rmKg)} excluding RIR, that is huge 💪`;
  }
  return `new E1RM PB ${fmtKg(ev.e1rmKg)} excluding RIR on the ${alias} too, nice!`;
}

/**
 * Composes the training paragraph from selected praises.
 * Wording deliberately avoids "last week" — windows vary.
 */
function trainingParagraph(praises, seed) {
  if (!praises || praises.length === 0) return null;

  const SENTENCES = {
    maxWeightPB: maxWeightPBSentence,
    repPB: repPBSentence,
    e1rmPB: e1rmPBSentence,
    rirMatchPB: rirMatchPBSentence,
  };
  const pbPraises = praises.filter((p) => SENTENCES[p.kind]);
  const completion = praises.find((p) => p.kind === 'completedAll' || p.kind === 'threePlus');

  const parts = [];
  pbPraises.forEach((p, i) => {
    parts.push(SENTENCES[p.kind](p, seed, { lead: i === 0 }));
  });

  let text = '';
  const closer = (last) => (last.endsWith('!') ? '' : ', great stuff 👌');
  if (parts.length === 1) {
    text = parts[0];
  } else if (parts.length === 2) {
    text = `${parts[0]} ${parts[1]}${closer(parts[1])}`;
  } else if (parts.length >= 3) {
    text = `${parts[0]} ${parts[1]}, and ${parts[2]}${closer(parts[2])}`;
  }

  if (completion) {
    const compText = completion.kind === 'completedAll'
      ? 'nice work getting all your workouts in 👍'
      : `nice work getting in ${completion.count} workouts since the last check-in 👍`;
    text = text ? `${text} Also ${compText}` : compText;
  }

  return text || null;
}

// ── Bodyweight sentences ────────────────────────────────────────────────────

const BW_LINES = {
  cut_onTrack: ['Weigh in looking ok too, slowly coming down, keep it up 👍'],
  cut_offTrack: [
    'Body weight not going down at the moment, how is the diet going?',
    "Body weight hasn't really moved down — anywhere you're struggling with the diet?",
    'How are you going with the diet?',
  ],
  bulk_onTrack: ['Weigh in looking good too, slowly going up, keep it up 👍'],
  bulk_offTrack: [
    'Body weight not going up at the moment, how is the diet going?',
    'How are you going with the diet?',
  ],
  maintain_stable: ['Body weight seems stable too 👍'],
  maintain_driftUp: [
    'Body weight has been creeping up a little — how are you going with the diet?',
  ],
  maintain_driftDown: [
    'Body weight has been dipping a little — how are you going with the diet?',
  ],
};

function milestoneSentence(goal, milestoneId) {
  if (!milestoneId) return null;
  const boundary = Number(milestoneId.split('_')[1]);
  if (goal === 'cut') {
    return `And you've cracked under ${boundary}kg — awesome milestone, keep it rolling 🎉`;
  }
  if (goal === 'bulk') {
    return `And you've hit the ${boundary}kg mark — awesome milestone, keep it rolling 🎉`;
  }
  return null;
}

/**
 * Bodyweight paragraph.
 * @param {Object} bw { goal, trend, currentAvg, previousAvg, weighInStatus,
 *                      newMilestoneId }
 */
function bodyweightParagraph(bw, gender, firstName, seed) {
  if (!bw) return null;
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
    if (lines.length === 0) {
      // Standalone weigh-in prompt with its own greeting style.
      const g = weighInGreeting(gender, firstName, seed);
      return `${g}, could I get you to weigh in today please?`;
    }
    lines.push('Could I get you to weigh in today too please?');
  }

  return lines.length ? lines.join(' ') : null;
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

// ── Full draft ──────────────────────────────────────────────────────────────

/**
 * Combined client draft: greeting + training + bodyweight in one message.
 * Returns null when there is genuinely nothing to say (no praise, no
 * bodyweight comment, no weigh-in prompt).
 */
function composeDraft({ praises, bodyweight, gender, firstName, variantSeed }) {
  const training = trainingParagraph(praises, variantSeed);
  const bw = bodyweightParagraph(bodyweight, gender, firstName, variantSeed);

  if (!training && !bw) return null;

  if (!training && bw && (bodyweight.weighInStatus === 'due' || bodyweight.weighInStatus === 'overdue')
      && (!bodyweight.trend || bodyweight.trend === 'insufficient')) {
    // Pure weigh-in prompt already carries its own greeting.
    return bw;
  }

  const g = greeting(gender, firstName, variantSeed);
  const paragraphs = [];
  if (training) paragraphs.push(`${g}, ${training}`);
  if (bw) {
    // The celebratory bodyweight lines say "too", which only reads right
    // after a training paragraph; drop it when bodyweight opens the message.
    const standalone = training ? bw : bw.replace(' too,', ',').replace(' too ', ' ');
    paragraphs.push(training ? bw : `${g}, ${lowerFirst(standalone)}`);
  }
  return paragraphs.join('\n\n');
}

function lowerFirst(s) {
  return s ? s[0].toLowerCase() + s.slice(1) : s;
}

module.exports = {
  EXERCISE_ALIASES,
  exerciseAlias,
  cleanExerciseName,
  greeting,
  weighInGreeting,
  seededIndex,
  trainingParagraph,
  bodyweightParagraph,
  composeDraft,
  milestoneSentence,
};
