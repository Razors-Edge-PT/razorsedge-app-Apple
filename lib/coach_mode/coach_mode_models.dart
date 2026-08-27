// Pure Coach Mode domain model for the Flutter client.
//
// Mirrors functions/coach/coach_mode_model.js exactly: the same enums, the
// same length limits and the same state machines. Keeping the two in step is
// what makes client-side validation a UX convenience rather than a second,
// divergent source of truth — the server revalidates everything.
//
// Nothing in this file touches Firebase, so all of it is unit testable.

import 'package:flutter/foundation.dart';

/// The single hard-coded super admin, identical to firestore.rules
/// isSuperAdmin(), functions/coach/coach_mode_model.js SUPER_ADMIN_UID and
/// functions/coach/authz.js. Super admin is never an entitlement, an
/// application or a purchase.
const String kSuperAdminUid = 'yoVAqScwLMQLAgNHh8v9IK49fBw2'; // Richard

// ── Collections ─────────────────────────────────────────────────────────────
const String kColCoachApplications = 'coachApplications';
const String kColAccountEntitlements = 'accountEntitlements';
const String kColCoachProfiles = 'coachProfiles';
const String kColCoachAthleteLinks = 'coachAthleteLinks';

/// Deterministic link document id — must match the server's linkId().
String coachLinkId(String coachUid, String athleteUid) =>
    '${coachUid}__$athleteUid';

// ── Application enums ───────────────────────────────────────────────────────

const List<String> kAthleteCountBands = ['0', '1-5', '6-15', '16-30', '31+'];
const List<String> kExperienceBands = ['less_than_1', '1-3', '4-7', '8+'];
const List<String> kCoachingFocus = [
  'powerlifting',
  'bodybuilding',
  'general_strength',
  'other',
];
const List<String> kCompetitionExperience = [
  'none',
  'powerlifting',
  'bodybuilding',
];

/// Length limits — identical to the server's LIMITS.
class CoachApplicationLimits {
  static const int qualifications = 500;
  static const int competitionDetails = 500;
  static const int intendedUse = 600;
  static const int profileUrl = 300;
  static const int reason = 500;
  static const int intendedUseMin = 20;
}

/// Human labels for the enum values, kept next to the values themselves so a
/// new option can never be added to one list and forgotten in the other.
const Map<String, String> kAthleteCountBandLabels = {
  '0': 'None yet',
  '1-5': '1–5 athletes',
  '6-15': '6–15 athletes',
  '16-30': '16–30 athletes',
  '31+': '31+ athletes',
};

const Map<String, String> kExperienceBandLabels = {
  'less_than_1': 'Less than 1 year',
  '1-3': '1–3 years',
  '4-7': '4–7 years',
  '8+': '8+ years',
};

const Map<String, String> kCoachingFocusLabels = {
  'powerlifting': 'Powerlifting',
  'bodybuilding': 'Bodybuilding',
  'general_strength': 'General strength',
  'other': 'Other',
};

const Map<String, String> kCompetitionExperienceLabels = {
  'none': 'Have not competed',
  'powerlifting': 'Powerlifting',
  'bodybuilding': 'Bodybuilding',
};

// ── Application status ──────────────────────────────────────────────────────

enum CoachApplicationStatus {
  none,
  submitted,
  moreInfoRequested,
  approved,
  declined,
  withdrawn,
}

CoachApplicationStatus coachApplicationStatusFrom(Object? raw) {
  switch (raw) {
    case 'submitted':
      return CoachApplicationStatus.submitted;
    case 'more_info_requested':
      return CoachApplicationStatus.moreInfoRequested;
    case 'approved':
      return CoachApplicationStatus.approved;
    case 'declined':
      return CoachApplicationStatus.declined;
    case 'withdrawn':
      return CoachApplicationStatus.withdrawn;
    default:
      return CoachApplicationStatus.none;
  }
}

/// Mirrors the server's APPLICATION_TRANSITIONS: which statuses allow a new
/// submission. Drives whether the form is shown or a status card is.
bool canSubmitFromStatus(CoachApplicationStatus status) {
  switch (status) {
    case CoachApplicationStatus.none:
    case CoachApplicationStatus.moreInfoRequested:
    case CoachApplicationStatus.declined:
    case CoachApplicationStatus.withdrawn:
      return true;
    case CoachApplicationStatus.submitted:
    case CoachApplicationStatus.approved:
      return false;
  }
}

// ── Entitlement ─────────────────────────────────────────────────────────────

enum CoachEntitlementState { none, active, suspended, revoked }

CoachEntitlementState coachEntitlementStateFrom(Object? raw) {
  switch (raw) {
    case 'active':
      return CoachEntitlementState.active;
    case 'suspended':
      return CoachEntitlementState.suspended;
    case 'revoked':
      return CoachEntitlementState.revoked;
    default:
      return CoachEntitlementState.none;
  }
}

enum CoachEntitlementSource { unknown, manualReview, superAdminGrant, iap }

CoachEntitlementSource coachEntitlementSourceFrom(Object? raw) {
  switch (raw) {
    case 'manual_review':
      return CoachEntitlementSource.manualReview;
    case 'super_admin_grant':
      return CoachEntitlementSource.superAdminGrant;
    // Future coach IAP activates this same entitlement with source 'iap' —
    // no authorization redesign is required to switch a coach over.
    case 'iap':
      return CoachEntitlementSource.iap;
    default:
      return CoachEntitlementSource.unknown;
  }
}

@immutable
class CoachEntitlement {
  final CoachEntitlementState state;
  final CoachEntitlementSource source;
  final String reason;

  const CoachEntitlement({
    this.state = CoachEntitlementState.none,
    this.source = CoachEntitlementSource.unknown,
    this.reason = '',
  });

  static const CoachEntitlement none = CoachEntitlement();

  /// The only definition of "this account has Coach Mode" on the client.
  /// Suspended and revoked are explicitly NOT active.
  bool get isActive => state == CoachEntitlementState.active;

  bool get isSuspended => state == CoachEntitlementState.suspended;
  bool get isRevoked => state == CoachEntitlementState.revoked;

  /// Parses accountEntitlements/{uid}. Tolerates missing/partial documents:
  /// anything that is not an explicit active state resolves to no access.
  factory CoachEntitlement.fromMap(Map<String, dynamic>? data) {
    if (data == null) return CoachEntitlement.none;
    final coach = data['coach'];
    if (coach is! Map) return CoachEntitlement.none;
    final state = coachEntitlementStateFrom(coach['state']);
    final source = coachEntitlementSourceFrom(coach['source']);
    String reason = '';
    if (state == CoachEntitlementState.suspended) {
      reason = (coach['suspensionReason'] ?? '').toString();
    } else if (state == CoachEntitlementState.revoked) {
      reason = (coach['revocationReason'] ?? '').toString();
    }
    return CoachEntitlement(state: state, source: source, reason: reason);
  }
}

// ── Resolved role ───────────────────────────────────────────────────────────

enum CoachRole { athlete, coach, superAdmin }

/// The client's single role resolution.
///
/// * super admin is the hard-coded UID and outranks everything — it can never
///   be suspended or revoked, and never depends on an entitlement document.
/// * an ordinary coach needs an ACTIVE entitlement. The mirrored `isCoach`
///   custom claim is only a fast-routing hint: it is honoured while the
///   entitlement document has not loaded yet, but an explicitly suspended or
///   revoked entitlement always wins over a stale claim.
CoachRole resolveCoachRole({
  required String uid,
  required CoachEntitlement entitlement,
  bool claimIsCoach = false,
}) {
  if (uid == kSuperAdminUid) return CoachRole.superAdmin;
  if (entitlement.isActive) return CoachRole.coach;
  if (entitlement.state != CoachEntitlementState.none) {
    // Explicitly suspended or revoked — a stale claim must not resurrect it.
    return CoachRole.athlete;
  }
  return claimIsCoach ? CoachRole.coach : CoachRole.athlete;
}

// ── Relationship status ─────────────────────────────────────────────────────

enum CoachLinkStatus {
  unknown,
  pending,
  active,
  declined,
  cancelled,
  revokedByAthlete,
  releasedByCoach,
}

CoachLinkStatus coachLinkStatusFrom(Object? raw) {
  switch (raw) {
    case 'pending':
      return CoachLinkStatus.pending;
    case 'active':
      return CoachLinkStatus.active;
    case 'declined':
      return CoachLinkStatus.declined;
    case 'cancelled':
      return CoachLinkStatus.cancelled;
    case 'revoked_by_athlete':
      return CoachLinkStatus.revokedByAthlete;
    case 'released_by_coach':
      return CoachLinkStatus.releasedByCoach;
    default:
      return CoachLinkStatus.unknown;
  }
}

/// Only `active` is a real relationship. Everything else — including pending —
/// grants no training access at all.
bool linkStatusGrantsAccess(CoachLinkStatus status) =>
    status == CoachLinkStatus.active;

String coachLinkStatusLabel(CoachLinkStatus status) {
  switch (status) {
    case CoachLinkStatus.pending:
      return 'Invitation pending';
    case CoachLinkStatus.active:
      return 'Active';
    case CoachLinkStatus.declined:
      return 'Declined';
    case CoachLinkStatus.cancelled:
      return 'Cancelled';
    case CoachLinkStatus.revokedByAthlete:
      return 'Revoked by athlete';
    case CoachLinkStatus.releasedByCoach:
      return 'Released by coach';
    case CoachLinkStatus.unknown:
      return 'Unknown';
  }
}

@immutable
class CoachAthleteLink {
  final String id;
  final String coachUid;
  final String athleteUid;
  final CoachLinkStatus status;
  final String coachDisplayName;
  final String coachEmail;
  final String athleteDisplayName;
  final String athleteEmail;
  final DateTime? requestedAt;
  final DateTime? respondedAt;
  final DateTime? endedAt;

  const CoachAthleteLink({
    required this.id,
    required this.coachUid,
    required this.athleteUid,
    required this.status,
    this.coachDisplayName = '',
    this.coachEmail = '',
    this.athleteDisplayName = '',
    this.athleteEmail = '',
    this.requestedAt,
    this.respondedAt,
    this.endedAt,
  });

  bool get isActive => linkStatusGrantsAccess(status);
  bool get isPending => status == CoachLinkStatus.pending;

  /// Best label for the athlete side of this link.
  String get athleteLabel => _label(athleteDisplayName, athleteEmail, athleteUid);

  /// Best label for the coach side of this link.
  String get coachLabel => _label(coachDisplayName, coachEmail, coachUid);

  static String _label(String name, String email, String uid) {
    if (name.trim().isNotEmpty) return name.trim();
    if (email.trim().isNotEmpty) return email.trim();
    return uid;
  }

  /// Parses a coachAthleteLinks document, tolerating missing/legacy fields.
  /// `toDate` converts a backend timestamp; callers pass a Firestore-aware
  /// converter so this file stays free of Firebase imports.
  factory CoachAthleteLink.fromMap(
    String id,
    Map<String, dynamic>? data, {
    DateTime? Function(Object?)? toDate,
  }) {
    final d = data ?? const <String, dynamic>{};
    String s(Object? v) => v == null ? '' : v.toString();
    Map<String, dynamic> snap(Object? v) =>
        v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

    final coachSnap = snap(d['coachSnapshot']);
    final athleteSnap = snap(d['athleteSnapshot']);
    DateTime? dt(Object? v) => toDate == null ? null : toDate(v);

    return CoachAthleteLink(
      id: id,
      coachUid: s(d['coachUid']),
      athleteUid: s(d['athleteUid']),
      status: coachLinkStatusFrom(d['status']),
      coachDisplayName: s(coachSnap['displayName']),
      coachEmail: s(coachSnap['email']),
      athleteDisplayName: s(athleteSnap['displayName']),
      athleteEmail: s(athleteSnap['email']),
      requestedAt: dt(d['requestedAt']),
      respondedAt: dt(d['respondedAt']),
      endedAt: dt(d['endedAt']),
    );
  }
}

// ── Roster composition ──────────────────────────────────────────────────────

/// Splits a coach's links into the two lists the dashboard renders.
/// Terminated relationships (declined / cancelled / revoked / released) appear
/// in neither — they are history, not roster.
@immutable
class CoachRosterSplit {
  final List<CoachAthleteLink> active;
  final List<CoachAthleteLink> pending;

  const CoachRosterSplit({required this.active, required this.pending});

  bool get isEmpty => active.isEmpty && pending.isEmpty;
}

CoachRosterSplit splitCoachRoster(Iterable<CoachAthleteLink> links) {
  final active = <CoachAthleteLink>[];
  final pending = <CoachAthleteLink>[];
  for (final l in links) {
    if (l.isActive) {
      active.add(l);
    } else if (l.isPending) {
      pending.add(l);
    }
  }
  int byLabel(CoachAthleteLink a, CoachAthleteLink b) {
    final c = a.athleteLabel.toLowerCase().compareTo(b.athleteLabel.toLowerCase());
    return c != 0 ? c : a.athleteUid.compareTo(b.athleteUid);
  }

  active.sort(byLabel);
  pending.sort(byLabel);
  return CoachRosterSplit(active: active, pending: pending);
}

/// Case-insensitive roster filter over the athlete's name and email.
List<CoachAthleteLink> filterRoster(
  Iterable<CoachAthleteLink> links,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return links.toList();
  return links.where((l) {
    return l.athleteDisplayName.toLowerCase().contains(q) ||
        l.athleteEmail.toLowerCase().contains(q) ||
        l.athleteUid.toLowerCase().contains(q);
  }).toList();
}

/// The athlete-side split: invitations awaiting a response, and current coaches.
@immutable
class AthleteCoachingSplit {
  final List<CoachAthleteLink> invitations;
  final List<CoachAthleteLink> activeCoaches;

  const AthleteCoachingSplit({
    required this.invitations,
    required this.activeCoaches,
  });

  bool get isEmpty => invitations.isEmpty && activeCoaches.isEmpty;
}

AthleteCoachingSplit splitAthleteCoaching(Iterable<CoachAthleteLink> links) {
  final invitations = <CoachAthleteLink>[];
  final activeCoaches = <CoachAthleteLink>[];
  for (final l in links) {
    if (l.isActive) {
      activeCoaches.add(l);
    } else if (l.isPending) {
      invitations.add(l);
    }
  }
  int byLabel(CoachAthleteLink a, CoachAthleteLink b) =>
      a.coachLabel.toLowerCase().compareTo(b.coachLabel.toLowerCase());
  invitations.sort(byLabel);
  activeCoaches.sort(byLabel);
  return AthleteCoachingSplit(
    invitations: invitations,
    activeCoaches: activeCoaches,
  );
}

/// Merges canonical active links with the LEGACY assignment sources so a coach
/// mid-migration never loses an athlete they already had. Legacy sources are
/// removed once adoption is confirmed (see docs/coach_mode.md).
Set<String> composeAuthorisedAthleteUids({
  required Iterable<CoachAthleteLink> canonicalLinks,
  Iterable<String> legacyApprovedUids = const [],
  Iterable<String> legacySeededUids = const [],
}) {
  return <String>{
    ...canonicalLinks.where((l) => l.isActive).map((l) => l.athleteUid),
    ...legacyApprovedUids,
    ...legacySeededUids,
  };
}

// ── Application form model + validation ─────────────────────────────────────

/// One validation problem, addressed to a specific form field.
@immutable
class CoachApplicationFieldError {
  final String field;
  final String message;
  const CoachApplicationFieldError(this.field, this.message);

  @override
  String toString() => '$field: $message';
}

/// The editable application. `validate()` mirrors the server's
/// validateApplication() so the form can show errors inline; the server
/// revalidates identically and is the authority.
@immutable
class CoachApplicationDraft {
  final String? athleteCountBand;
  final String? experienceBand;
  final Set<String> coachingFocus;
  final Set<String> competitionExperience;
  final String qualifications;
  final String competitionDetails;
  final String intendedUse;
  final String profileUrl;
  final bool agreesToAthleteConsent;

  const CoachApplicationDraft({
    this.athleteCountBand,
    this.experienceBand,
    this.coachingFocus = const {},
    this.competitionExperience = const {},
    this.qualifications = '',
    this.competitionDetails = '',
    this.intendedUse = '',
    this.profileUrl = '',
    this.agreesToAthleteConsent = false,
  });

  CoachApplicationDraft copyWith({
    String? athleteCountBand,
    String? experienceBand,
    Set<String>? coachingFocus,
    Set<String>? competitionExperience,
    String? qualifications,
    String? competitionDetails,
    String? intendedUse,
    String? profileUrl,
    bool? agreesToAthleteConsent,
  }) {
    return CoachApplicationDraft(
      athleteCountBand: athleteCountBand ?? this.athleteCountBand,
      experienceBand: experienceBand ?? this.experienceBand,
      coachingFocus: coachingFocus ?? this.coachingFocus,
      competitionExperience: competitionExperience ?? this.competitionExperience,
      qualifications: qualifications ?? this.qualifications,
      competitionDetails: competitionDetails ?? this.competitionDetails,
      intendedUse: intendedUse ?? this.intendedUse,
      profileUrl: profileUrl ?? this.profileUrl,
      agreesToAthleteConsent:
          agreesToAthleteConsent ?? this.agreesToAthleteConsent,
    );
  }

  /// Rebuilds a draft from a stored application's `answers` map, so an
  /// applicant answering a more-information request edits what they sent
  /// rather than starting again.
  factory CoachApplicationDraft.fromAnswers(Map<String, dynamic>? answers) {
    final a = answers ?? const <String, dynamic>{};
    Set<String> list(Object? v) => v is List
        ? v.map((e) => e.toString()).toSet()
        : const <String>{};
    String s(Object? v) => v == null ? '' : v.toString();
    String? enumOrNull(Object? v, List<String> allowed) {
      final str = v?.toString();
      return (str != null && allowed.contains(str)) ? str : null;
    }

    return CoachApplicationDraft(
      athleteCountBand: enumOrNull(a['athleteCountBand'], kAthleteCountBands),
      experienceBand: enumOrNull(a['experienceBand'], kExperienceBands),
      coachingFocus: list(a['coachingFocus']),
      competitionExperience: list(a['competitionExperience']),
      qualifications: s(a['qualifications']),
      competitionDetails: s(a['competitionDetails']),
      intendedUse: s(a['intendedUse']),
      profileUrl: s(a['profileUrl']),
      agreesToAthleteConsent: a['agreesToAthleteConsent'] == true,
    );
  }

  /// Every problem with the draft, in form order. Empty means submittable.
  List<CoachApplicationFieldError> validate() {
    final errors = <CoachApplicationFieldError>[];

    if (athleteCountBand == null ||
        !kAthleteCountBands.contains(athleteCountBand)) {
      errors.add(const CoachApplicationFieldError(
          'athleteCountBand', 'Choose how many athletes you currently coach.'));
    }
    if (experienceBand == null || !kExperienceBands.contains(experienceBand)) {
      errors.add(const CoachApplicationFieldError(
          'experienceBand', 'Choose how long you have been coaching.'));
    }
    if (coachingFocus.isEmpty ||
        !coachingFocus.every(kCoachingFocus.contains)) {
      errors.add(const CoachApplicationFieldError(
          'coachingFocus', 'Choose at least one coaching focus.'));
    }
    if (competitionExperience.isEmpty ||
        !competitionExperience.every(kCompetitionExperience.contains)) {
      errors.add(const CoachApplicationFieldError('competitionExperience',
          'Choose your competition experience.'));
    } else if (competitionExperience.contains('none') &&
        competitionExperience.length > 1) {
      errors.add(const CoachApplicationFieldError(
          'competitionExperience',
          'Select "Have not competed" on its own, or the disciplines you have competed in.'));
    }

    if (qualifications.trim().length > CoachApplicationLimits.qualifications) {
      errors.add(CoachApplicationFieldError('qualifications',
          'Keep this to ${CoachApplicationLimits.qualifications} characters or fewer.'));
    }
    if (competitionDetails.trim().length >
        CoachApplicationLimits.competitionDetails) {
      errors.add(CoachApplicationFieldError('competitionDetails',
          'Keep this to ${CoachApplicationLimits.competitionDetails} characters or fewer.'));
    }

    final use = intendedUse.trim();
    if (use.length < CoachApplicationLimits.intendedUseMin) {
      errors.add(CoachApplicationFieldError('intendedUse',
          'Tell us how you plan to use GoodLift (at least ${CoachApplicationLimits.intendedUseMin} characters).'));
    } else if (use.length > CoachApplicationLimits.intendedUse) {
      errors.add(CoachApplicationFieldError('intendedUse',
          'Keep this to ${CoachApplicationLimits.intendedUse} characters or fewer.'));
    }

    final url = profileUrl.trim();
    if (url.isNotEmpty) {
      if (url.length > CoachApplicationLimits.profileUrl) {
        errors.add(CoachApplicationFieldError('profileUrl',
            'Keep this to ${CoachApplicationLimits.profileUrl} characters or fewer.'));
      } else if (!RegExp(r'^https?://[^\s@]+\.[^\s]{2,}$', caseSensitive: false)
          .hasMatch(url)) {
        errors.add(const CoachApplicationFieldError(
            'profileUrl', 'Enter a valid http(s) link.'));
      }
    }

    if (!agreesToAthleteConsent) {
      errors.add(const CoachApplicationFieldError(
          'agreesToAthleteConsent',
          'Please confirm you will only invite athletes you genuinely coach.'));
    }

    return errors;
  }

  bool get isValid => validate().isEmpty;

  /// The exact payload the callable expects. Enum lists are emitted in the
  /// canonical order so repeat submissions are comparable.
  Map<String, dynamic> toCallablePayload() {
    return <String, dynamic>{
      'athleteCountBand': athleteCountBand,
      'experienceBand': experienceBand,
      'coachingFocus':
          kCoachingFocus.where(coachingFocus.contains).toList(growable: false),
      'competitionExperience': kCompetitionExperience
          .where(competitionExperience.contains)
          .toList(growable: false),
      'qualifications': qualifications.trim(),
      'competitionDetails': competitionDetails.trim(),
      'intendedUse': intendedUse.trim(),
      'profileUrl': profileUrl.trim(),
      'agreesToAthleteConsent': agreesToAthleteConsent,
    };
  }
}

/// A stored coachApplications/{uid} document.
@immutable
class CoachApplication {
  final String uid;
  final CoachApplicationStatus status;
  final CoachApplicationDraft answers;
  final String decisionReason;
  final String infoRequest;
  final String applicantDisplayName;
  final String applicantEmail;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;

  const CoachApplication({
    required this.uid,
    required this.status,
    required this.answers,
    this.decisionReason = '',
    this.infoRequest = '',
    this.applicantDisplayName = '',
    this.applicantEmail = '',
    this.submittedAt,
    this.reviewedAt,
  });

  static CoachApplication none(String uid) => CoachApplication(
        uid: uid,
        status: CoachApplicationStatus.none,
        answers: const CoachApplicationDraft(),
      );

  String get applicantLabel {
    if (applicantDisplayName.trim().isNotEmpty) return applicantDisplayName.trim();
    if (applicantEmail.trim().isNotEmpty) return applicantEmail.trim();
    return uid;
  }

  factory CoachApplication.fromMap(
    String uid,
    Map<String, dynamic>? data, {
    DateTime? Function(Object?)? toDate,
  }) {
    if (data == null) return CoachApplication.none(uid);
    final d = data;
    String s(Object? v) => v == null ? '' : v.toString();
    final snap = d['applicantSnapshot'] is Map
        ? Map<String, dynamic>.from(d['applicantSnapshot'] as Map)
        : const <String, dynamic>{};
    DateTime? dt(Object? v) => toDate == null ? null : toDate(v);

    return CoachApplication(
      uid: uid,
      status: coachApplicationStatusFrom(d['status']),
      answers: CoachApplicationDraft.fromAnswers(
        d['answers'] is Map ? Map<String, dynamic>.from(d['answers'] as Map) : null,
      ),
      decisionReason: s(d['decisionReason']),
      infoRequest: s(d['infoRequest']),
      applicantDisplayName: s(snap['displayName']),
      applicantEmail: s(snap['email']),
      submittedAt: dt(d['submittedAt']),
      reviewedAt: dt(d['reviewedAt']),
    );
  }
}

// ── Coach Mode screen state ─────────────────────────────────────────────────

/// Which state the prospective-coach screen should render. Derived once, so
/// the screen never has to re-derive precedence between entitlement and
/// application status.
enum CoachModeScreenState {
  notApplied,
  submitted,
  moreInfoRequested,
  approvedActive,
  declined,
  suspended,
  revoked,
  superAdmin,
}

CoachModeScreenState resolveCoachModeScreenState({
  required String uid,
  required CoachEntitlement entitlement,
  required CoachApplicationStatus applicationStatus,
}) {
  if (uid == kSuperAdminUid) return CoachModeScreenState.superAdmin;

  // The entitlement outranks the application: it is what actually grants or
  // withholds access.
  switch (entitlement.state) {
    case CoachEntitlementState.active:
      return CoachModeScreenState.approvedActive;
    case CoachEntitlementState.suspended:
      return CoachModeScreenState.suspended;
    case CoachEntitlementState.revoked:
      return CoachModeScreenState.revoked;
    case CoachEntitlementState.none:
      break;
  }

  switch (applicationStatus) {
    case CoachApplicationStatus.submitted:
      return CoachModeScreenState.submitted;
    case CoachApplicationStatus.moreInfoRequested:
      return CoachModeScreenState.moreInfoRequested;
    case CoachApplicationStatus.declined:
      return CoachModeScreenState.declined;
    case CoachApplicationStatus.approved:
      // Approved application but no live entitlement (suspended then cleared,
      // or mid-migration): treat as not currently active and let them re-apply.
      return CoachModeScreenState.notApplied;
    case CoachApplicationStatus.withdrawn:
    case CoachApplicationStatus.none:
      return CoachModeScreenState.notApplied;
  }
}
