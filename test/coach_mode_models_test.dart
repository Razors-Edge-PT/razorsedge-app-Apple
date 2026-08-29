import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_mode/coach_mode_models.dart';
import 'package:localtest222/coach_mode/coach_mode_service.dart';
import 'package:localtest222/coach_roster.dart';
import 'package:localtest222/user_context.dart';

// Client-side Coach Mode model tests.
//
// The Dart model mirrors functions/coach/coach_mode_model.js — same enums,
// same limits, same state machines — so these pin the client half of that
// contract: application form validation, entitlement/role resolution,
// relationship status mapping, roster composition, pending-versus-active
// display, and suspended/revoked handling.

CoachApplicationDraft validDraft({
  String? athleteCountBand = '6-15',
  String? experienceBand = '4-7',
  Set<String> coachingFocus = const {'powerlifting'},
  Set<String> competitionExperience = const {'none'},
  String qualifications = '',
  String competitionDetails = '',
  String intendedUse =
      'Programming blocks and reviewing weekly check-ins for my athletes.',
  String profileUrl = '',
  bool agrees = true,
}) {
  return CoachApplicationDraft(
    athleteCountBand: athleteCountBand,
    experienceBand: experienceBand,
    coachingFocus: coachingFocus,
    competitionExperience: competitionExperience,
    qualifications: qualifications,
    competitionDetails: competitionDetails,
    intendedUse: intendedUse,
    profileUrl: profileUrl,
    agreesToAthleteConsent: agrees,
  );
}

Set<String> errorFields(CoachApplicationDraft d) =>
    d.validate().map((e) => e.field).toSet();

void main() {
  group('super admin constant', () {
    test('matches the single hard-coded uid used by rules and functions', () {
      expect(kSuperAdminUid, 'yoVAqScwLMQLAgNHh8v9IK49fBw2');
    });

    test('link ids are deterministic and match the server format', () {
      expect(coachLinkId('coachA', 'athleteB'), 'coachA__athleteB');
    });
  });

  group('application form validation', () {
    test('a complete draft is valid', () {
      expect(validDraft().validate(), isEmpty);
      expect(validDraft().isValid, isTrue);
    });

    test('required single-selects must be chosen from the enum', () {
      expect(errorFields(validDraft(athleteCountBand: null)),
          contains('athleteCountBand'));
      expect(errorFields(validDraft(athleteCountBand: '100+')),
          contains('athleteCountBand'));
      expect(errorFields(validDraft(experienceBand: null)),
          contains('experienceBand'));
      expect(errorFields(validDraft(experienceBand: 'ages')),
          contains('experienceBand'));
    });

    test('multi-selects require at least one supported value', () {
      expect(errorFields(validDraft(coachingFocus: {})),
          contains('coachingFocus'));
      expect(errorFields(validDraft(coachingFocus: {'crossfit'})),
          contains('coachingFocus'));
      expect(errorFields(validDraft(competitionExperience: {})),
          contains('competitionExperience'));
      expect(errorFields(validDraft(competitionExperience: {'strongman'})),
          contains('competitionExperience'));
    });

    test("competition 'none' is exclusive, exactly as the server enforces", () {
      expect(
        errorFields(validDraft(competitionExperience: {'none', 'powerlifting'})),
        contains('competitionExperience'),
      );
      expect(validDraft(competitionExperience: {'none'}).validate(), isEmpty);
      expect(
        validDraft(competitionExperience: {'powerlifting', 'bodybuilding'})
            .validate(),
        isEmpty,
      );
    });

    test('intendedUse is required with a minimum and maximum length', () {
      expect(errorFields(validDraft(intendedUse: '')), contains('intendedUse'));
      expect(errorFields(validDraft(intendedUse: 'too short')),
          contains('intendedUse'));
      expect(
        errorFields(validDraft(
            intendedUse: 'x' * (CoachApplicationLimits.intendedUse + 1))),
        contains('intendedUse'),
      );
      // Exactly at each bound is accepted.
      expect(
        validDraft(intendedUse: 'x' * CoachApplicationLimits.intendedUseMin)
            .validate(),
        isEmpty,
      );
      expect(
        validDraft(intendedUse: 'x' * CoachApplicationLimits.intendedUse)
            .validate(),
        isEmpty,
      );
    });

    test('optional text fields are bounded but may be empty', () {
      expect(validDraft(qualifications: '').validate(), isEmpty);
      expect(
        errorFields(validDraft(
            qualifications: 'x' * (CoachApplicationLimits.qualifications + 1))),
        contains('qualifications'),
      );
      expect(
        errorFields(validDraft(
            competitionDetails:
                'x' * (CoachApplicationLimits.competitionDetails + 1))),
        contains('competitionDetails'),
      );
    });

    test('profileUrl is optional but must be a bounded http(s) link', () {
      expect(validDraft(profileUrl: '').validate(), isEmpty);
      expect(validDraft(profileUrl: 'https://example.com/me').validate(), isEmpty);
      expect(validDraft(profileUrl: 'http://example.com/me').validate(), isEmpty);
      expect(errorFields(validDraft(profileUrl: 'javascript:alert(1)')),
          contains('profileUrl'));
      expect(errorFields(validDraft(profileUrl: 'example.com')),
          contains('profileUrl'));
      expect(
        errorFields(validDraft(
            profileUrl: 'https://e.com/${'x' * CoachApplicationLimits.profileUrl}')),
        contains('profileUrl'),
      );
    });

    test('the athlete-consent confirmation is mandatory', () {
      expect(errorFields(validDraft(agrees: false)),
          contains('agreesToAthleteConsent'));
    });

    test('all problems are reported at once, in form order', () {
      final d = validDraft(
        athleteCountBand: null,
        experienceBand: null,
        coachingFocus: {},
        intendedUse: '',
        agrees: false,
      );
      final fields = d.validate().map((e) => e.field).toList();
      expect(fields, [
        'athleteCountBand',
        'experienceBand',
        'coachingFocus',
        'intendedUse',
        'agreesToAthleteConsent',
      ]);
    });
  });

  group('application payload', () {
    test('emits enum lists in the canonical server order', () {
      final payload = validDraft(
        coachingFocus: {'other', 'powerlifting', 'bodybuilding'},
        competitionExperience: {'bodybuilding', 'powerlifting'},
      ).toCallablePayload();

      expect(payload['coachingFocus'],
          ['powerlifting', 'bodybuilding', 'other']);
      expect(payload['competitionExperience'], ['powerlifting', 'bodybuilding']);
    });

    test('trims free text and carries exactly the expected keys', () {
      final payload = validDraft(
        qualifications: '  Level 2  ',
        intendedUse: '  Coaching my powerlifting athletes properly.  ',
      ).toCallablePayload();

      expect(payload['qualifications'], 'Level 2');
      expect(payload['intendedUse'], 'Coaching my powerlifting athletes properly.');
      expect(payload.keys.toSet(), {
        'athleteCountBand',
        'experienceBand',
        'coachingFocus',
        'competitionExperience',
        'qualifications',
        'competitionDetails',
        'intendedUse',
        'profileUrl',
        'agreesToAthleteConsent',
      });
    });

    test('round-trips through fromAnswers so a resubmission is pre-filled', () {
      final original = validDraft(
        coachingFocus: {'powerlifting', 'general_strength'},
        competitionExperience: {'powerlifting'},
        qualifications: 'Level 2',
        profileUrl: 'https://example.com/me',
      );
      final restored =
          CoachApplicationDraft.fromAnswers(original.toCallablePayload());

      expect(restored.athleteCountBand, original.athleteCountBand);
      expect(restored.experienceBand, original.experienceBand);
      expect(restored.coachingFocus, original.coachingFocus);
      expect(restored.competitionExperience, original.competitionExperience);
      expect(restored.qualifications, 'Level 2');
      expect(restored.profileUrl, 'https://example.com/me');
      expect(restored.agreesToAthleteConsent, isTrue);
      expect(restored.isValid, isTrue);
    });

    test('fromAnswers drops unsupported enum values instead of crashing', () {
      final d = CoachApplicationDraft.fromAnswers({
        'athleteCountBand': 'nonsense',
        'experienceBand': 42,
        'coachingFocus': 'not-a-list',
        'intendedUse': null,
      });
      expect(d.athleteCountBand, isNull);
      expect(d.experienceBand, isNull);
      expect(d.coachingFocus, isEmpty);
      expect(d.intendedUse, '');
      expect(d.isValid, isFalse);
    });

    test('fromAnswers on a null/empty map yields an empty draft', () {
      expect(CoachApplicationDraft.fromAnswers(null).isValid, isFalse);
      expect(CoachApplicationDraft.fromAnswers(const {}).isValid, isFalse);
    });
  });

  group('application parsing', () {
    test('parses a stored application document', () {
      final app = CoachApplication.fromMap('u1', {
        'status': 'more_info_requested',
        'infoRequest': 'Which gym?',
        'answers': validDraft().toCallablePayload(),
        'applicantSnapshot': {'displayName': 'Coach A', 'email': 'a@x.com'},
      });
      expect(app.status, CoachApplicationStatus.moreInfoRequested);
      expect(app.infoRequest, 'Which gym?');
      expect(app.applicantLabel, 'Coach A');
      expect(app.answers.athleteCountBand, '6-15');
    });

    test('a missing document is the none state, not an error', () {
      final app = CoachApplication.fromMap('u1', null);
      expect(app.status, CoachApplicationStatus.none);
      expect(app.applicantLabel, 'u1');
    });

    test('an unknown status string degrades to none', () {
      expect(coachApplicationStatusFrom('exploded'), CoachApplicationStatus.none);
      expect(coachApplicationStatusFrom(null), CoachApplicationStatus.none);
      expect(coachApplicationStatusFrom(42), CoachApplicationStatus.none);
    });

    test('applicant label falls back through name, email, uid', () {
      expect(
        CoachApplication.fromMap('u1', {
          'applicantSnapshot': {'email': 'only@email.com'}
        }).applicantLabel,
        'only@email.com',
      );
      expect(CoachApplication.fromMap('u1', {}).applicantLabel, 'u1');
    });

    test('resubmission is allowed from exactly the server-allowed statuses', () {
      expect(canSubmitFromStatus(CoachApplicationStatus.none), isTrue);
      expect(canSubmitFromStatus(CoachApplicationStatus.declined), isTrue);
      expect(canSubmitFromStatus(CoachApplicationStatus.withdrawn), isTrue);
      expect(canSubmitFromStatus(CoachApplicationStatus.moreInfoRequested), isTrue);
      expect(canSubmitFromStatus(CoachApplicationStatus.submitted), isFalse);
      expect(canSubmitFromStatus(CoachApplicationStatus.approved), isFalse);
    });
  });

  group('entitlement resolution', () {
    test('only an explicit active state grants Coach Mode', () {
      expect(
        CoachEntitlement.fromMap({'coach': {'state': 'active'}}).isActive,
        isTrue,
      );
      expect(
        CoachEntitlement.fromMap({'coach': {'state': 'suspended'}}).isActive,
        isFalse,
      );
      expect(
        CoachEntitlement.fromMap({'coach': {'state': 'revoked'}}).isActive,
        isFalse,
      );
    });

    test('missing, partial or malformed documents never grant access', () {
      for (final data in <Map<String, dynamic>?>[
        null,
        <String, dynamic>{},
        {'coach': null},
        {'coach': 'active'},
        {'state': 'active'},
        {'isCoach': true},
        {'coach': <String, dynamic>{}},
      ]) {
        expect(CoachEntitlement.fromMap(data).isActive, isFalse,
            reason: 'must not authorise: $data');
      }
    });

    test('suspension and revocation reasons are surfaced to the coach', () {
      final suspended = CoachEntitlement.fromMap({
        'coach': {'state': 'suspended', 'suspensionReason': 'under review'}
      });
      expect(suspended.isSuspended, isTrue);
      expect(suspended.reason, 'under review');

      final revoked = CoachEntitlement.fromMap({
        'coach': {'state': 'revoked', 'revocationReason': 'policy breach'}
      });
      expect(revoked.isRevoked, isTrue);
      expect(revoked.reason, 'policy breach');

      // An active entitlement carries no stale reason.
      final active = CoachEntitlement.fromMap({
        'coach': {'state': 'active', 'suspensionReason': 'old'}
      });
      expect(active.reason, '');
    });

    test('the source is parsed, including the future IAP source', () {
      CoachEntitlementSource src(String s) =>
          CoachEntitlement.fromMap({'coach': {'state': 'active', 'source': s}})
              .source;
      expect(src('manual_review'), CoachEntitlementSource.manualReview);
      expect(src('super_admin_grant'), CoachEntitlementSource.superAdminGrant);
      expect(src('iap'), CoachEntitlementSource.iap);
      expect(src('mystery'), CoachEntitlementSource.unknown);
    });
  });

  group('role resolution', () {
    const active = CoachEntitlement(state: CoachEntitlementState.active);
    const suspended = CoachEntitlement(state: CoachEntitlementState.suspended);
    const revoked = CoachEntitlement(state: CoachEntitlementState.revoked);

    test('the hard-coded super admin always outranks everything', () {
      expect(
        resolveCoachRole(uid: kSuperAdminUid, entitlement: CoachEntitlement.none),
        CoachRole.superAdmin,
      );
      // Even an explicitly revoked entitlement cannot demote the super admin.
      expect(
        resolveCoachRole(uid: kSuperAdminUid, entitlement: revoked),
        CoachRole.superAdmin,
      );
    });

    test('an active entitlement makes an ordinary account a coach', () {
      expect(resolveCoachRole(uid: 'u1', entitlement: active), CoachRole.coach);
    });

    test('the claim is only a fast-routing hint before the entitlement loads', () {
      expect(
        resolveCoachRole(
            uid: 'u1', entitlement: CoachEntitlement.none, claimIsCoach: true),
        CoachRole.coach,
      );
      expect(
        resolveCoachRole(
            uid: 'u1', entitlement: CoachEntitlement.none, claimIsCoach: false),
        CoachRole.athlete,
      );
    });

    test('a suspended or revoked entitlement beats a stale isCoach claim', () {
      expect(
        resolveCoachRole(uid: 'u1', entitlement: suspended, claimIsCoach: true),
        CoachRole.athlete,
      );
      expect(
        resolveCoachRole(uid: 'u1', entitlement: revoked, claimIsCoach: true),
        CoachRole.athlete,
      );
    });
  });

  group('Coach Mode screen state', () {
    const none = CoachEntitlement.none;
    const active = CoachEntitlement(state: CoachEntitlementState.active);
    const suspended = CoachEntitlement(state: CoachEntitlementState.suspended);
    const revoked = CoachEntitlement(state: CoachEntitlementState.revoked);

    CoachModeScreenState state(
      String uid,
      CoachEntitlement ent,
      CoachApplicationStatus app,
    ) =>
        resolveCoachModeScreenState(
            uid: uid, entitlement: ent, applicationStatus: app);

    test('super admin sees the super-admin state regardless of anything else', () {
      expect(state(kSuperAdminUid, none, CoachApplicationStatus.none),
          CoachModeScreenState.superAdmin);
      expect(state(kSuperAdminUid, revoked, CoachApplicationStatus.declined),
          CoachModeScreenState.superAdmin);
    });

    test('the entitlement outranks the application status', () {
      expect(state('u1', active, CoachApplicationStatus.submitted),
          CoachModeScreenState.approvedActive);
      expect(state('u1', suspended, CoachApplicationStatus.approved),
          CoachModeScreenState.suspended);
      expect(state('u1', revoked, CoachApplicationStatus.approved),
          CoachModeScreenState.revoked);
    });

    test('without an entitlement the application status drives the screen', () {
      expect(state('u1', none, CoachApplicationStatus.none),
          CoachModeScreenState.notApplied);
      expect(state('u1', none, CoachApplicationStatus.submitted),
          CoachModeScreenState.submitted);
      expect(state('u1', none, CoachApplicationStatus.moreInfoRequested),
          CoachModeScreenState.moreInfoRequested);
      expect(state('u1', none, CoachApplicationStatus.declined),
          CoachModeScreenState.declined);
      expect(state('u1', none, CoachApplicationStatus.withdrawn),
          CoachModeScreenState.notApplied);
    });

    test('an approved application with no live entitlement is not treated as active', () {
      expect(state('u1', none, CoachApplicationStatus.approved),
          CoachModeScreenState.notApplied);
    });
  });

  group('relationship status mapping', () {
    test('every server status maps to a distinct client status', () {
      expect(coachLinkStatusFrom('pending'), CoachLinkStatus.pending);
      expect(coachLinkStatusFrom('active'), CoachLinkStatus.active);
      expect(coachLinkStatusFrom('declined'), CoachLinkStatus.declined);
      expect(coachLinkStatusFrom('cancelled'), CoachLinkStatus.cancelled);
      expect(coachLinkStatusFrom('revoked_by_athlete'),
          CoachLinkStatus.revokedByAthlete);
      expect(coachLinkStatusFrom('released_by_coach'),
          CoachLinkStatus.releasedByCoach);
    });

    test('an unknown or malformed status is never treated as active', () {
      for (final raw in <Object?>['exploded', null, 42, true, '']) {
        expect(coachLinkStatusFrom(raw), CoachLinkStatus.unknown);
        expect(linkStatusGrantsAccess(coachLinkStatusFrom(raw)), isFalse);
      }
    });

    test('ONLY active grants access — pending included', () {
      expect(linkStatusGrantsAccess(CoachLinkStatus.active), isTrue);
      for (final s in [
        CoachLinkStatus.pending,
        CoachLinkStatus.declined,
        CoachLinkStatus.cancelled,
        CoachLinkStatus.revokedByAthlete,
        CoachLinkStatus.releasedByCoach,
        CoachLinkStatus.unknown,
      ]) {
        expect(linkStatusGrantsAccess(s), isFalse, reason: '$s must not grant');
      }
    });

    test('parses a link document with snapshots', () {
      final link = CoachAthleteLink.fromMap('c1__a1', {
        'coachUid': 'c1',
        'athleteUid': 'a1',
        'status': 'active',
        'coachSnapshot': {'displayName': 'Coach One', 'email': 'c1@x.com'},
        'athleteSnapshot': {'displayName': 'Athlete One', 'email': 'a1@x.com'},
      });
      expect(link.isActive, isTrue);
      expect(link.isPending, isFalse);
      expect(link.coachLabel, 'Coach One');
      expect(link.athleteLabel, 'Athlete One');
    });

    test('labels fall back to email then uid when snapshots are thin', () {
      final emailOnly = CoachAthleteLink.fromMap('c1__a1', {
        'coachUid': 'c1',
        'athleteUid': 'a1',
        'status': 'pending',
        'athleteSnapshot': {'email': 'a1@x.com'},
      });
      expect(emailOnly.athleteLabel, 'a1@x.com');
      expect(emailOnly.coachLabel, 'c1');

      final bare = CoachAthleteLink.fromMap('c1__a1', {
        'coachUid': 'c1',
        'athleteUid': 'a1',
        'status': 'pending',
      });
      expect(bare.athleteLabel, 'a1');
    });

    test('a malformed document never becomes an active relationship', () {
      final bad = CoachAthleteLink.fromMap('x', {
        'coachUid': 'c1',
        'athleteUid': 'a1',
        'status': {'forged': true},
        'coachSnapshot': 'not-a-map',
      });
      expect(bad.status, CoachLinkStatus.unknown);
      expect(bad.isActive, isFalse);
      expect(bad.coachDisplayName, '');
    });

    test('status labels are human-readable for every status', () {
      for (final s in CoachLinkStatus.values) {
        expect(coachLinkStatusLabel(s), isNotEmpty);
      }
    });
  });

  group('coach roster composition', () {
    CoachAthleteLink link(String athlete, String status, {String name = ''}) =>
        CoachAthleteLink.fromMap('c1__$athlete', {
          'coachUid': 'c1',
          'athleteUid': athlete,
          'status': status,
          'athleteSnapshot': {
            'displayName': name,
            'email': '$athlete@x.com',
          },
        });

    test('splits into active and pending, discarding terminated links', () {
      final split = splitCoachRoster([
        link('a1', 'active', name: 'Zoe'),
        link('a2', 'pending', name: 'Adam'),
        link('a3', 'declined'),
        link('a4', 'cancelled'),
        link('a5', 'revoked_by_athlete'),
        link('a6', 'released_by_coach'),
        link('a7', 'active', name: 'Ben'),
      ]);

      expect(split.active.map((l) => l.athleteUid), ['a7', 'a1']);
      expect(split.pending.map((l) => l.athleteUid), ['a2']);
      expect(split.isEmpty, isFalse);
    });

    test('a roster of only terminated links is empty', () {
      final split = splitCoachRoster([
        link('a3', 'declined'),
        link('a5', 'revoked_by_athlete'),
      ]);
      expect(split.active, isEmpty);
      expect(split.pending, isEmpty);
      expect(split.isEmpty, isTrue);
    });

    test('sorting is case-insensitive and stable by uid', () {
      final split = splitCoachRoster([
        link('b', 'active', name: 'malina'),
        link('a', 'active', name: 'Cdawg'),
        link('c', 'active', name: 'The_Dragon'),
      ]);
      expect(split.active.map((l) => l.athleteLabel),
          ['Cdawg', 'malina', 'The_Dragon']);
    });

    test('filtering matches name, email and uid', () {
      final links = [
        link('a1', 'active', name: 'Malina'),
        link('a2', 'active', name: 'Cdawg'),
      ];
      expect(filterRoster(links, 'mal').map((l) => l.athleteUid), ['a1']);
      expect(filterRoster(links, 'A2@X').map((l) => l.athleteUid), ['a2']);
      expect(filterRoster(links, 'a1').map((l) => l.athleteUid), ['a1']);
      expect(filterRoster(links, '').length, 2);
      expect(filterRoster(links, 'nobody'), isEmpty);
    });

    test('authorised uids merge canonical active links with legacy sources', () {
      final uids = composeAuthorisedAthleteUids(
        canonicalLinks: [
          link('canonical1', 'active'),
          link('pendingOne', 'pending'),
          link('revokedOne', 'revoked_by_athlete'),
        ],
        legacyApprovedUids: ['legacyApproved'],
        legacySeededUids: ['legacySeeded'],
      );
      expect(uids, {'canonical1', 'legacyApproved', 'legacySeeded'});
      expect(uids.contains('pendingOne'), isFalse,
          reason: 'a pending invitation is not a roster entry');
      expect(uids.contains('revokedOne'), isFalse);
    });

    test('CoachRoster.assignedUids unions all three sources', () {
      final uids = CoachRoster.assignedUids(
        approvedAthleteUids: ['legacyApproved'],
        seededAthletes: {'legacySeeded': {'email': 's@x.com'}},
        activeLinkAthleteUids: ['canonical1', 'legacyApproved'],
      );
      expect(uids, {'canonical1', 'legacyApproved', 'legacySeeded'});
    });

    test('CoachRoster.assignedUids still works with no canonical links', () {
      final uids = CoachRoster.assignedUids(
        approvedAthleteUids: ['a'],
        seededAthletes: {'b': {}},
      );
      expect(uids, {'a', 'b'});
    });
  });

  group('athlete coaching composition', () {
    CoachAthleteLink link(String coach, String status) =>
        CoachAthleteLink.fromMap('${coach}__a1', {
          'coachUid': coach,
          'athleteUid': 'a1',
          'status': status,
          'coachSnapshot': {'displayName': coach, 'email': '$coach@x.com'},
        });

    test('separates invitations from current coaches', () {
      final split = splitAthleteCoaching([
        link('zoeCoach', 'active'),
        link('adamCoach', 'pending'),
        link('goneCoach', 'revoked_by_athlete'),
        link('benCoach', 'active'),
      ]);
      expect(split.invitations.map((l) => l.coachUid), ['adamCoach']);
      expect(split.activeCoaches.map((l) => l.coachUid),
          ['benCoach', 'zoeCoach']);
    });

    test('an athlete may hold several active coaches at once', () {
      final split = splitAthleteCoaching([
        link('c1', 'active'),
        link('c2', 'active'),
        link('c3', 'pending'),
      ]);
      expect(split.activeCoaches.length, 2);
      expect(split.invitations.length, 1);
      expect(split.isEmpty, isFalse);
    });

    test('no links at all is an empty, non-error state', () {
      final split = splitAthleteCoaching(const []);
      expect(split.isEmpty, isTrue);
    });

    test('terminated relationships never show as current coaches', () {
      final split = splitAthleteCoaching([
        link('c1', 'declined'),
        link('c2', 'cancelled'),
        link('c3', 'released_by_coach'),
        link('c4', 'revoked_by_athlete'),
      ]);
      expect(split.activeCoaches, isEmpty);
      expect(split.invitations, isEmpty);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // CORRECTIVE PASS — client role lifecycle and entitlement replacement
  // ══════════════════════════════════════════════════════════════════════

  group('UserContext Coach Mode lifecycle', () {
    const active = CoachEntitlement(state: CoachEntitlementState.active);
    const suspended = CoachEntitlement(state: CoachEntitlementState.suspended);
    const revoked = CoachEntitlement(state: CoachEntitlementState.revoked);

    test('a newly approved coach gains Coach Mode without a restart', () {
      // Starts as an ordinary athlete: no claim, no entitlement.
      final ctx = UserContext(actorUid: 'u1', isCoach: false);
      expect(ctx.hasCoachMode, isFalse);
      expect(ctx.coachRole, CoachRole.athlete);

      var notified = 0;
      ctx.addListener(() => notified++);

      // The entitlement stream delivers the approval mid-session.
      ctx.coachEntitlement = active;

      expect(ctx.hasCoachMode, isTrue);
      expect(ctx.coachRole, CoachRole.coach);
      expect(notified, 1, reason: 'listeners must be told so the UI rebuilds');
    });

    test('a suspended coach loses Coach Mode mid-session', () {
      // Started the session with a valid claim.
      final ctx = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = active;
      expect(ctx.hasCoachMode, isTrue);

      var notified = 0;
      ctx.addListener(() => notified++);

      ctx.coachEntitlement = suspended;

      expect(ctx.hasCoachMode, isFalse,
          reason: 'a suspension must take effect during the session');
      expect(ctx.coachModeSuspendedOrRevoked, isTrue);
      expect(notified, 1);
    });

    test('a revoked coach loses Coach Mode mid-session', () {
      final ctx = UserContext(actorUid: 'u1', isCoach: true)
        ..coachEntitlement = active;
      ctx.coachEntitlement = revoked;
      expect(ctx.hasCoachMode, isFalse);
      expect(ctx.coachModeSuspendedOrRevoked, isTrue);
    });

    test('the isCoach claim is NOT authoritative once the entitlement resolves',
        () {
      // Stale claim says coach; the server says suspended.
      final ctx = UserContext(actorUid: 'u1', isCoach: true);
      expect(ctx.hasCoachMode, isTrue,
          reason: 'the claim may route the very first frame');

      ctx.coachEntitlement = suspended;
      expect(ctx.hasCoachMode, isFalse,
          reason: 'the resolved entitlement must beat the stale claim');

      ctx.coachEntitlement = revoked;
      expect(ctx.hasCoachMode, isFalse);
    });

    test('the super admin is never affected by entitlement state', () {
      final ctx = UserContext(actorUid: kSuperAdminUid, isCoach: false);
      expect(ctx.isSuperAdmin, isTrue);
      expect(ctx.hasCoachMode, isTrue);

      ctx.coachEntitlement = revoked;
      expect(ctx.hasCoachMode, isTrue,
          reason: 'super admin is the hard-coded constant, never a document');
      expect(ctx.coachModeSuspendedOrRevoked, isFalse);
      expect(ctx.coachRole, CoachRole.superAdmin);
    });

    test('setting the same entitlement does not notify', () {
      final ctx = UserContext(actorUid: 'u1', isCoach: false)
        ..coachEntitlement = active;
      var notified = 0;
      ctx.addListener(() => notified++);
      ctx.coachEntitlement =
          const CoachEntitlement(state: CoachEntitlementState.active);
      expect(notified, 0, reason: 'no spurious rebuilds');
    });

    test('a replacement UserContext can carry the resolved entitlement across',
        () {
      // Mirrors what AppRoot does when it rebuilds the context after token
      // resolution: the new context must not regress to claim-only Coach Mode.
      final oldCtx = UserContext(actorUid: 'u1', isCoach: false)
        ..coachEntitlement = suspended;

      final newCtx = UserContext(actorUid: 'u1', isCoach: true);
      expect(newCtx.hasCoachMode, isTrue,
          reason: 'claim-only, before the entitlement is carried over');

      newCtx.coachEntitlement = oldCtx.coachEntitlement;
      expect(newCtx.hasCoachMode, isFalse,
          reason: 'the resolved suspension must survive the replacement');
    });
  });

  group('roster visibility follows the resolved role', () {
    // CoachRosterService.loadRoster switches on exactly this, so the pure
    // resolution is what gets pinned here.
    CoachRole roleFor(CoachEntitlement e, {bool claim = false, String uid = 'u1'}) =>
        resolveCoachRole(uid: uid, entitlement: e, claimIsCoach: claim);

    test('suspended or revoked yields the athlete role (empty roster)', () {
      expect(
        roleFor(const CoachEntitlement(state: CoachEntitlementState.suspended),
            claim: true),
        CoachRole.athlete,
      );
      expect(
        roleFor(const CoachEntitlement(state: CoachEntitlementState.revoked),
            claim: true),
        CoachRole.athlete,
      );
    });

    test('active yields the coach role', () {
      expect(
        roleFor(const CoachEntitlement(state: CoachEntitlementState.active)),
        CoachRole.coach,
      );
    });

    test('super admin yields the super-admin role regardless', () {
      expect(
        roleFor(const CoachEntitlement(state: CoachEntitlementState.revoked),
            uid: kSuperAdminUid),
        CoachRole.superAdmin,
      );
    });

    test('unresolved entitlement is provisional on the claim only', () {
      expect(roleFor(CoachEntitlement.none, claim: true), CoachRole.coach);
      expect(roleFor(CoachEntitlement.none, claim: false), CoachRole.athlete);
    });
  });

  group('super-admin coach list is searchable by person', () {
    CoachProfileSummary summary({
      String uid = 'coach1',
      String displayName = '',
      String email = '',
    }) =>
        CoachProfileSummary(
          uid: uid,
          entitlement: const CoachEntitlement(state: CoachEntitlementState.active),
          source: CoachEntitlementSource.manualReview,
          displayName: displayName,
          email: email,
        );

    test('label prefers display name, then email, then uid', () {
      expect(summary(displayName: 'Coach Rich', email: 'r@x.com').label,
          'Coach Rich');
      expect(summary(email: 'r@x.com').label, 'r@x.com');
      expect(summary().label, 'coach1');
      expect(summary(displayName: '   ').label, 'coach1');
    });

    test('search matches name, email and uid case-insensitively', () {
      final c = summary(
          uid: 'aBcDeF', displayName: 'Coach Rich', email: 'Rich@Example.com');
      expect(c.matches(''), isTrue, reason: 'empty query matches everything');
      expect(c.matches('rich'), isTrue);
      expect(c.matches('COACH'), isTrue);
      expect(c.matches('example.com'), isTrue);
      expect(c.matches('abcdef'), isTrue);
      expect(c.matches('nobody'), isFalse);
    });

    test('a coach with no profile is still findable by uid', () {
      final c = summary(uid: 'lonelyUid');
      expect(c.label, 'lonelyUid');
      expect(c.matches('lonely'), isTrue);
    });

    test('withProfile enriches without losing entitlement state', () {
      final base = CoachProfileSummary(
        uid: 'c1',
        entitlement:
            const CoachEntitlement(state: CoachEntitlementState.suspended),
        source: CoachEntitlementSource.superAdminGrant,
      );
      final enriched =
          base.withProfile(displayName: 'Name', email: 'e@x.com');
      expect(enriched.uid, 'c1');
      expect(enriched.displayName, 'Name');
      expect(enriched.entitlement.isSuspended, isTrue);
      expect(enriched.source, CoachEntitlementSource.superAdminGrant);
    });
  });

}
