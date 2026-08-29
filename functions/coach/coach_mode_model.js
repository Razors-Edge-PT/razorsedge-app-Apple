// Pure Coach Mode domain model: application validation, entitlement state,
// relationship state machine and deterministic identifiers.
//
// Everything here is side-effect free so the security-relevant rules
// (enum validation, length limits, allowed transitions, link ids) are unit
// testable without an emulator, and so the callables in coach_mode.js stay
// thin authorisation + persistence wrappers.

'use strict';

// ── Super admin ─────────────────────────────────────────────────────────────
// The single hard-coded super admin, identical to firestore.rules
// isSuperAdmin(), functions/coach/authz.js SUPER_ADMIN_UIDS and the Flutter
// UserContext.isSuperAdmin. Super admin is NEVER an entitlement, an
// application or a purchase — it is this constant and nothing else.
const SUPER_ADMIN_UID = 'yoVAqScwLMQLAgNHh8v9IK49fBw2'; // Richard

function isSuperAdminUid(uid) {
  return typeof uid === 'string' && uid === SUPER_ADMIN_UID;
}

// ── Collections ─────────────────────────────────────────────────────────────
const COL_APPLICATIONS = 'coachApplications';
const COL_ENTITLEMENTS = 'accountEntitlements';
const COL_PROFILES = 'coachProfiles';
const COL_LINKS = 'coachAthleteLinks';
const COL_AUDIT = 'coachAdminAudit';

// ── Application enums ───────────────────────────────────────────────────────
const ATHLETE_COUNT_BANDS = Object.freeze(['0', '1-5', '6-15', '16-30', '31+']);
const EXPERIENCE_BANDS = Object.freeze(['less_than_1', '1-3', '4-7', '8+']);
const COACHING_FOCUS = Object.freeze([
  'powerlifting', 'bodybuilding', 'general_strength', 'other',
]);
const COMPETITION_EXPERIENCE = Object.freeze(['none', 'powerlifting', 'bodybuilding']);

// Length limits — enforced identically on client and server.
const LIMITS = Object.freeze({
  qualifications: 500,
  competitionDetails: 500,
  intendedUse: 600,
  profileUrl: 300,
  reason: 500,
  note: 500,
  displayName: 120,
  email: 254,
});

// Minimum length for the required free-text "how will you use GoodLift" answer.
const INTENDED_USE_MIN = 20;

// ── Application status machine ──────────────────────────────────────────────
const APPLICATION_STATUSES = Object.freeze([
  'submitted', 'more_info_requested', 'approved', 'declined', 'withdrawn',
]);

// From-status to allowed next statuses. `null` means "no application document".
const APPLICATION_TRANSITIONS = Object.freeze({
  null: ['submitted'],
  submitted: ['approved', 'declined', 'more_info_requested', 'withdrawn'],
  more_info_requested: ['submitted', 'approved', 'declined', 'withdrawn'],
  declined: ['submitted'],           // may re-apply
  withdrawn: ['submitted'],          // may re-apply
  approved: [],                      // terminal; access is managed via entitlement
});

function canTransitionApplication(from, to) {
  const key = from == null ? 'null' : String(from);
  const allowed = APPLICATION_TRANSITIONS[key];
  return Array.isArray(allowed) && allowed.includes(to);
}

/** Statuses from which the applicant may (re)submit an application. */
function canSubmitApplication(currentStatus) {
  return canTransitionApplication(currentStatus == null ? null : currentStatus, 'submitted');
}

// ── Entitlement state machine ───────────────────────────────────────────────
const ENTITLEMENT_STATES = Object.freeze(['active', 'suspended', 'revoked']);
const ENTITLEMENT_SOURCES = Object.freeze(['manual_review', 'super_admin_grant', 'iap']);

const ENTITLEMENT_TRANSITIONS = Object.freeze({
  null: ['active'],
  active: ['suspended', 'revoked'],
  suspended: ['active', 'revoked'],
  revoked: ['active'],
});

function canTransitionEntitlement(from, to) {
  const key = from == null ? 'null' : String(from);
  const allowed = ENTITLEMENT_TRANSITIONS[key];
  return Array.isArray(allowed) && allowed.includes(to);
}

/**
 * The one definition of "this account currently has Coach Mode".
 * Only `state === 'active'` grants coach access — suspended and revoked
 * entitlements are inert even while relationship documents still exist.
 * Super admin is deliberately NOT considered here: it is checked separately
 * so super-admin access can never be revoked by entitlement state.
 */
function entitlementIsActive(entitlementData) {
  return !!(entitlementData
    && entitlementData.coach
    && entitlementData.coach.state === 'active');
}

// ── Relationship (coach/athlete link) state machine ──────────────────────────
const LINK_STATUSES = Object.freeze([
  'pending', 'active', 'declined', 'cancelled', 'revoked_by_athlete', 'released_by_coach',
]);

/** Statuses that grant no access at all. */
const LINK_TERMINAL_STATUSES = Object.freeze([
  'declined', 'cancelled', 'revoked_by_athlete', 'released_by_coach',
]);

const LINK_TRANSITIONS = Object.freeze({
  null: ['pending'],
  pending: ['active', 'declined', 'cancelled'],
  active: ['revoked_by_athlete', 'released_by_coach'],
  declined: ['pending'],
  cancelled: ['pending'],
  revoked_by_athlete: ['pending'],
  released_by_coach: ['pending'],
});

function canTransitionLink(from, to) {
  const key = from == null ? 'null' : String(from);
  const allowed = LINK_TRANSITIONS[key];
  return Array.isArray(allowed) && allowed.includes(to);
}

/** Who is allowed to drive a given transition. */
const LINK_TRANSITION_ACTOR = Object.freeze({
  pending: 'coach',              // coach invites
  active: 'athlete',             // athlete accepts
  declined: 'athlete',           // athlete declines
  cancelled: 'coach',            // coach cancels a pending invite
  revoked_by_athlete: 'athlete',
  released_by_coach: 'coach',
});

function actorMayDriveLink(toStatus, actorRole) {
  return LINK_TRANSITION_ACTOR[toStatus] === actorRole;
}

/** Deterministic, idempotent link document id. */
function linkId(coachUid, athleteUid) {
  return coachUid + '__' + athleteUid;
}

/** Parses a link id back into its parts; null when malformed. */
function parseLinkId(id) {
  if (typeof id !== 'string') return null;
  const parts = id.split('__');
  if (parts.length !== 2) return null;
  const coachUid = parts[0];
  const athleteUid = parts[1];
  if (!coachUid || !athleteUid) return null;
  return { coachUid, athleteUid };
}

/** Only an `active` link is a real coaching relationship. */
function linkIsActive(linkData) {
  return !!(linkData && linkData.status === 'active');
}

/**
 * A canonical link recording a DELIBERATE end to the relationship: the
 * athlete declined or revoked, or the coach cancelled or released.
 *
 * This is authoritative over a stale legacy `athleteAssignments.approved`
 * entry. After migration the two can coexist — the canonical link is the
 * newer, explicit decision, so an athlete revocation or a coach release takes
 * effect immediately instead of being silently undone by the old approval
 * flag it was migrated from.
 *
 * It deliberately does NOT override a super-admin-seeded assignment: seeding
 * is a separate, admin-controlled compatibility path (see evaluateAssignment
 * in authz.js).
 */
function linkIsTerminal(linkData) {
  return !!(linkData && LINK_TERMINAL_STATUSES.includes(linkData.status));
}

// ── Validation helpers ──────────────────────────────────────────────────────

class ValidationError extends Error {
  constructor(message, field) {
    super(message);
    this.name = 'ValidationError';
    this.field = field;
  }
}

function requireString(value, field, opts) {
  const o = opts || {};
  const max = o.max;
  const min = o.min == null ? 1 : o.min;
  const required = o.required !== false;

  if (value === undefined || value === null || value === '') {
    if (required) throw new ValidationError(field + ' is required.', field);
    return '';
  }
  if (typeof value !== 'string') {
    throw new ValidationError(field + ' must be text.', field);
  }
  const trimmed = value.trim();
  if (required && trimmed.length < min) {
    throw new ValidationError(
      min > 1
        ? field + ' must be at least ' + min + ' characters.'
        : field + ' is required.',
      field,
    );
  }
  if (trimmed.length > max) {
    throw new ValidationError(field + ' must be ' + max + ' characters or fewer.', field);
  }
  return trimmed;
}

function requireEnum(value, field, allowed) {
  if (typeof value !== 'string' || !allowed.includes(value)) {
    throw new ValidationError(field + ' must be one of: ' + allowed.join(', ') + '.', field);
  }
  return value;
}

function requireEnumList(value, field, allowed, opts) {
  const o = opts || {};
  const min = o.min == null ? 1 : o.min;
  const max = o.max == null ? allowed.length : o.max;

  if (!Array.isArray(value)) {
    throw new ValidationError(field + ' must be a list.', field);
  }
  const unique = Array.from(new Set(value));
  if (unique.length < min) {
    throw new ValidationError('Select at least ' + min + ' option for ' + field + '.', field);
  }
  if (unique.length > max) {
    throw new ValidationError('Select at most ' + max + ' options for ' + field + '.', field);
  }
  for (const v of unique) {
    if (typeof v !== 'string' || !allowed.includes(v)) {
      throw new ValidationError(field + ' contains an unsupported value.', field);
    }
  }
  // Stable order so stored documents are comparable across submissions.
  return allowed.filter((a) => unique.includes(a));
}

/** Conservative URL check — http(s) only, no credentials, bounded length. */
function optionalUrl(value, field, max) {
  const s = requireString(value, field, { max: max, required: false });
  if (!s) return '';
  if (!/^https?:\/\/[^\s@]+\.[^\s]{2,}$/i.test(s)) {
    throw new ValidationError('Enter a valid http(s) link.', field);
  }
  return s;
}

/** Normalized email used for exact-match athlete invitation lookups. */
function normalizeEmail(value) {
  if (typeof value !== 'string') return '';
  return value.trim().toLowerCase();
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function requireEmail(value, field) {
  const f = field || 'email';
  const email = normalizeEmail(value);
  if (!email || email.length > LIMITS.email || !EMAIL_RE.test(email)) {
    throw new ValidationError('Enter a valid email address.', f);
  }
  return email;
}

/**
 * Validates and normalizes a coach application payload.
 * Throws ValidationError on the first problem; returns the exact field set
 * that will be persisted (never spreads unknown client keys into Firestore).
 */
function validateApplication(input) {
  const d = input && typeof input === 'object' ? input : {};

  const athleteCountBand = requireEnum(d.athleteCountBand, 'athleteCountBand', ATHLETE_COUNT_BANDS);
  const experienceBand = requireEnum(d.experienceBand, 'experienceBand', EXPERIENCE_BANDS);
  const coachingFocus = requireEnumList(d.coachingFocus, 'coachingFocus', COACHING_FOCUS, { min: 1 });
  const competitionExperience = requireEnumList(
    d.competitionExperience, 'competitionExperience', COMPETITION_EXPERIENCE, { min: 1 },
  );

  // 'none' is exclusive: it cannot be combined with a competed discipline.
  if (competitionExperience.includes('none') && competitionExperience.length > 1) {
    throw new ValidationError(
      'Select "none" on its own, or the disciplines you have competed in.',
      'competitionExperience',
    );
  }

  const qualifications = requireString(d.qualifications, 'qualifications',
    { max: LIMITS.qualifications, required: false });
  const competitionDetails = requireString(d.competitionDetails, 'competitionDetails',
    { max: LIMITS.competitionDetails, required: false });
  const intendedUse = requireString(d.intendedUse, 'intendedUse',
    { max: LIMITS.intendedUse, min: INTENDED_USE_MIN, required: true });
  const profileUrl = optionalUrl(d.profileUrl, 'profileUrl', LIMITS.profileUrl);

  if (d.agreesToAthleteConsent !== true) {
    throw new ValidationError(
      'You must confirm you will only invite athletes you genuinely coach and will respect their data and privacy.',
      'agreesToAthleteConsent',
    );
  }

  return {
    athleteCountBand: athleteCountBand,
    experienceBand: experienceBand,
    coachingFocus: coachingFocus,
    competitionExperience: competitionExperience,
    qualifications: qualifications,
    competitionDetails: competitionDetails,
    intendedUse: intendedUse,
    profileUrl: profileUrl,
    agreesToAthleteConsent: true,
  };
}

/**
 * The limited, invitation-safe coach profile. Deliberately excludes every
 * application answer — an invited athlete only needs to identify their coach.
 */
function buildCoachProfile(input) {
  const d = input || {};
  return {
    uid: d.uid,
    displayName: (d.displayName || '').toString().slice(0, LIMITS.displayName),
    email: normalizeEmail(d.email).slice(0, LIMITS.email),
    photoUrl: typeof d.photoUrl === 'string' ? d.photoUrl.slice(0, LIMITS.profileUrl) : '',
  };
}

/** Snapshot embedded in a link document so a roster renders without extra reads. */
function buildPartySnapshot(input) {
  const d = input || {};
  return {
    displayName: (d.displayName || '').toString().slice(0, LIMITS.displayName),
    email: normalizeEmail(d.email).slice(0, LIMITS.email),
  };
}

// ── Custom-claim merging ────────────────────────────────────────────────────
/**
 * Produces the FULL claims object to write, preserving every unrelated claim.
 * Never call setCustomUserClaims with a bare { isCoach } object: that silently
 * destroys any other claim the account carries.
 */
function mergeCoachClaim(existingClaims, isCoach) {
  const base = (existingClaims && typeof existingClaims === 'object')
    ? Object.assign({}, existingClaims)
    : {};
  if (isCoach) {
    base.isCoach = true;
  } else {
    delete base.isCoach;
  }
  return base;
}

// ── Invitation rate limiting ────────────────────────────────────────────────
const INVITE_RATE_WINDOW_MS = 24 * 60 * 60 * 1000;
const INVITE_RATE_MAX = 25;

/**
 * Sliding-window decision for invitation creation.
 * `recentTimestampsMs` is the coach's stored recent invite times.
 * Returns { allowed, retained } where retained is the pruned window to persist.
 */
function inviteRateDecision(recentTimestampsMs, nowMs, opts) {
  const o = opts || {};
  const windowMs = o.windowMs == null ? INVITE_RATE_WINDOW_MS : o.windowMs;
  const max = o.max == null ? INVITE_RATE_MAX : o.max;

  const list = Array.isArray(recentTimestampsMs) ? recentTimestampsMs : [];
  const retained = list
    .filter((t) => typeof t === 'number' && Number.isFinite(t) && nowMs - t < windowMs)
    .sort((a, b) => a - b);
  if (retained.length >= max) return { allowed: false, retained: retained };
  return { allowed: true, retained: retained.concat([nowMs]).slice(-max) };
}

module.exports = {
  SUPER_ADMIN_UID,
  isSuperAdminUid,
  COL_APPLICATIONS,
  COL_ENTITLEMENTS,
  COL_PROFILES,
  COL_LINKS,
  COL_AUDIT,
  ATHLETE_COUNT_BANDS,
  EXPERIENCE_BANDS,
  COACHING_FOCUS,
  COMPETITION_EXPERIENCE,
  LIMITS,
  INTENDED_USE_MIN,
  APPLICATION_STATUSES,
  APPLICATION_TRANSITIONS,
  canTransitionApplication,
  canSubmitApplication,
  ENTITLEMENT_STATES,
  ENTITLEMENT_SOURCES,
  ENTITLEMENT_TRANSITIONS,
  canTransitionEntitlement,
  entitlementIsActive,
  LINK_STATUSES,
  LINK_TERMINAL_STATUSES,
  LINK_TRANSITIONS,
  LINK_TRANSITION_ACTOR,
  canTransitionLink,
  actorMayDriveLink,
  linkId,
  parseLinkId,
  linkIsActive,
  linkIsTerminal,
  ValidationError,
  requireString,
  requireEnum,
  requireEnumList,
  optionalUrl,
  normalizeEmail,
  requireEmail,
  validateApplication,
  buildCoachProfile,
  buildPartySnapshot,
  mergeCoachClaim,
  inviteRateDecision,
  INVITE_RATE_WINDOW_MS,
  INVITE_RATE_MAX,
};
