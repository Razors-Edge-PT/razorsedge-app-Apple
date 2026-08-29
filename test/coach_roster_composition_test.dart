import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_mode/coach_mode_models.dart';
import 'package:localtest222/coach_roster.dart';

// Roster composition must match SERVER authorization exactly
// (functions/coach/authz.js evaluateAssignmentDetail, firestore.rules
// isCoachFor).
//
// The defect these pin: _loadAssignedAthletes queried only ACTIVE canonical
// links, then unioned every legacy `approved == true` athlete. Terminal links
// were never loaded, so after an athlete revoke or a coach release a stale
// legacy approval kept the athlete in the dashboard — a row the coach could
// see but could neither read nor remove, because the server denied everything.

CoachAthleteLink link(String athleteUid, String status, {String coach = 'c1'}) =>
    CoachAthleteLink.fromMap('${coach}__$athleteUid', {
      'coachUid': coach,
      'athleteUid': athleteUid,
      'status': status,
      'athleteSnapshot': {'displayName': athleteUid, 'email': '$athleteUid@x.com'},
    });

Set<String> compose({
  List<CoachAthleteLink> links = const [],
  List<String> approved = const [],
  List<String> seeded = const [],
}) =>
    composeAuthorisedAthleteUids(
      canonicalLinks: links,
      legacyApprovedUids: approved,
      legacySeededUids: seeded,
    );

void main() {
  group('terminal-link suppression', () {
    test('a terminal link suppresses a stale legacy approval', () {
      for (final status in [
        'declined',
        'cancelled',
        'revoked_by_athlete',
        'released_by_coach',
      ]) {
        expect(
          compose(links: [link('a1', status)], approved: ['a1']),
          isEmpty,
          reason: '$status must cancel the stale legacy approval',
        );
      }
    });

    test('coach release removes the athlete even with a legacy approval', () {
      // Exactly the post-migration shape: the link was migrated FROM the
      // approval, then the coach released the athlete.
      final before = compose(
        links: [link('a1', 'active')],
        approved: ['a1'],
      );
      expect(before, {'a1'});

      final after = compose(
        links: [link('a1', 'released_by_coach')],
        approved: ['a1'],
      );
      expect(after, isEmpty,
          reason: 'no bare-UID row may survive a coach release');
    });

    test('athlete revoke removes the athlete even with a legacy approval', () {
      expect(
        compose(links: [link('a1', 'revoked_by_athlete')], approved: ['a1']),
        isEmpty,
      );
    });

    test('a terminal link for ONE athlete does not affect another', () {
      final uids = compose(
        links: [link('a1', 'released_by_coach'), link('a2', 'active')],
        approved: ['a1', 'a2', 'a3'],
      );
      expect(uids, {'a2', 'a3'});
    });

    test('a terminal link alone contributes nothing', () {
      expect(compose(links: [link('a1', 'declined')]), isEmpty);
    });
  });

  group('seeded precedence', () {
    test('a super-admin seed survives a terminal link', () {
      // Seeding is an admin-controlled compatibility path and is deliberately
      // NOT overridden — matching the server.
      expect(
        compose(links: [link('a1', 'revoked_by_athlete')], seeded: ['a1']),
        {'a1'},
      );
      expect(
        compose(links: [link('a1', 'released_by_coach')], seeded: ['a1']),
        {'a1'},
      );
    });

    test('a seed keeps the athlete even when the approval is suppressed', () {
      // Terminal link + approval + seed: the approval is cancelled, but the
      // seed still authorises, so the athlete stays exactly once.
      final uids = compose(
        links: [link('a1', 'released_by_coach')],
        approved: ['a1'],
        seeded: ['a1'],
      );
      expect(uids, {'a1'});
    });

    test('a seed alone includes the athlete', () {
      expect(compose(seeded: ['a1']), {'a1'});
    });
  });

  group('pending behaviour', () {
    test('pending neither grants nor terminates', () {
      // Grants nothing on its own...
      expect(compose(links: [link('a1', 'pending')]), isEmpty);
      // ...and does not cancel a legacy approval.
      expect(compose(links: [link('a1', 'pending')], approved: ['a1']), {'a1'});
      // ...and does not cancel a seed.
      expect(compose(links: [link('a1', 'pending')], seeded: ['a1']), {'a1'});
    });

    test('an unknown/malformed status is treated like pending', () {
      // Fails safe in BOTH directions: it neither grants access nor strips a
      // legitimate legacy approval.
      final malformed = CoachAthleteLink.fromMap('c1__a1', {
        'coachUid': 'c1',
        'athleteUid': 'a1',
        'status': {'forged': true},
      });
      expect(compose(links: [malformed]), isEmpty);
      expect(compose(links: [malformed], approved: ['a1']), {'a1'});
    });
  });

  group('active links and general composition', () {
    test('an active link includes the athlete', () {
      expect(compose(links: [link('a1', 'active')]), {'a1'});
    });

    test('all three sources union without duplication', () {
      final uids = compose(
        links: [link('a1', 'active')],
        approved: ['a2'],
        seeded: ['a3', 'a1'],
      );
      expect(uids, {'a1', 'a2', 'a3'});
    });

    test('no sources yields an empty roster', () {
      expect(compose(), isEmpty);
    });

    test('empty uids are ignored rather than producing blank rows', () {
      final blank = CoachAthleteLink.fromMap('c1__', {
        'coachUid': 'c1',
        'athleteUid': '',
        'status': 'active',
      });
      expect(compose(links: [blank], approved: [''], seeded: ['']), isEmpty);
    });
  });

  group('CoachRoster.assignedUids delegates to the same rule', () {
    test('terminal link uids suppress a legacy approval', () {
      final uids = CoachRoster.assignedUids(
        approvedAthleteUids: ['a1', 'a2'],
        seededAthletes: const {},
        activeLinkAthleteUids: const [],
        terminalLinkAthleteUids: ['a1'],
      );
      expect(uids, {'a2'});
    });

    test('a seed outranks a terminal link here too', () {
      final uids = CoachRoster.assignedUids(
        approvedAthleteUids: ['a1'],
        seededAthletes: const {'a1': {'email': 's@x.com'}},
        terminalLinkAthleteUids: ['a1'],
      );
      expect(uids, {'a1'});
    });

    test('existing behaviour is unchanged when no terminal links exist', () {
      final uids = CoachRoster.assignedUids(
        approvedAthleteUids: ['a1'],
        seededAthletes: const {'a2': {}},
        activeLinkAthleteUids: ['a3'],
      );
      expect(uids, {'a1', 'a2', 'a3'});
    });
  });

  group('link status helpers', () {
    test('linkStatusIsTerminal covers exactly the four terminal statuses', () {
      expect(linkStatusIsTerminal(CoachLinkStatus.declined), isTrue);
      expect(linkStatusIsTerminal(CoachLinkStatus.cancelled), isTrue);
      expect(linkStatusIsTerminal(CoachLinkStatus.revokedByAthlete), isTrue);
      expect(linkStatusIsTerminal(CoachLinkStatus.releasedByCoach), isTrue);

      expect(linkStatusIsTerminal(CoachLinkStatus.active), isFalse);
      expect(linkStatusIsTerminal(CoachLinkStatus.pending), isFalse);
      expect(linkStatusIsTerminal(CoachLinkStatus.unknown), isFalse);
    });

    test('active and terminal are mutually exclusive for every status', () {
      for (final s in CoachLinkStatus.values) {
        expect(linkStatusGrantsAccess(s) && linkStatusIsTerminal(s), isFalse,
            reason: '$s cannot be both');
      }
    });
  });
}
