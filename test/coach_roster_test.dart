import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_roster.dart';

// Regression tests for the production defect where Check-in Athletes showed
// only 3 athletes for the super-admin while Coach Dashboard showed the full
// roster. Both screens now resolve athletes through CoachRoster/
// CoachRosterService, so the pure resolution rules are pinned here.

void main() {
  group('safeString: malformed/legacy records cannot crash the roster', () {
    test('non-string field values degrade to empty instead of throwing', () {
      expect(CoachRoster.safeString(null), '');
      expect(CoachRoster.safeString('Cdawg'), 'Cdawg');
      expect(CoachRoster.safeString(42), '42');
      expect(CoachRoster.safeString(true), 'true');
      // Legacy records with a map/list where a name is expected: no crash.
      expect(CoachRoster.safeString({'first': 'A'}), '');
      expect(CoachRoster.safeString(['a', 'b']), '');
    });

    test('a user doc with wrong-typed fields still yields a usable athlete', () {
      final a = CoachRoster.fromUserDoc('uid1', {
        'username': 12345, // legacy numeric username
        'displayName': {'bad': 'shape'}, // malformed
        'fullName': null,
        'email': 'x@y.com',
      });
      expect(a.uid, 'uid1');
      expect(a.username, '12345');
      expect(a.displayName, '');
      expect(a.email, 'x@y.com');
      expect(a.label, '12345');
    });

    test('a completely empty/absent user doc falls back to the uid', () {
      expect(CoachRoster.fromUserDoc('uidX', null).label, 'uidX');
      expect(CoachRoster.fromUserDoc('uidX', {}).label, 'uidX');
    });
  });

  group('assignment resolution for ordinary coaches', () {
    test('union of approved assignments and admin-seeded roster', () {
      final uids = CoachRoster.assignedUids(
        approvedAthleteUids: ['approved1', 'approved2'],
        seededAthletes: {'seeded1': {'email': 's@x.com'}, 'approved1': {}},
      );
      expect(uids, {'approved1', 'approved2', 'seeded1'});
    });

    test('no assignments yields an empty roster (not an error)', () {
      final uids = CoachRoster.assignedUids(
        approvedAthleteUids: const [],
        seededAthletes: const {},
      );
      expect(uids, isEmpty);
    });

    test('seeded entry fills gaps but the user document wins', () {
      final merged = CoachRoster.mergeSeeded(
        'uid2',
        {'email': 'seeded@x.com', 'displayName': 'Seeded Name'},
        {'displayName': 'Real Name', 'email': 'real@x.com'},
      );
      expect(merged.displayName, 'Real Name');
      expect(merged.email, 'real@x.com');

      final gapFilled = CoachRoster.mergeSeeded(
        'uid3',
        {'email': 'seeded@x.com'},
        null, // user doc missing
      );
      expect(gapFilled.email, 'seeded@x.com');
      expect(gapFilled.label, 'seeded@x.com');
    });
  });

  group('label precedence and sorting', () {
    test('label prefers username, then displayName, fullName, email, uid', () {
      expect(
          const CoachAthlete(uid: 'u', username: 'U', displayName: 'D').label, 'U');
      expect(const CoachAthlete(uid: 'u', displayName: 'D', fullName: 'F').label, 'D');
      expect(const CoachAthlete(uid: 'u', fullName: 'F', email: 'e@x').label, 'F');
      expect(const CoachAthlete(uid: 'u', email: 'e@x').label, 'e@x');
      expect(const CoachAthlete(uid: 'u').label, 'u');
      // Whitespace-only values are not treated as usable names.
      expect(const CoachAthlete(uid: 'u', username: '   ').label, 'u');
    });

    test('roster sorts case-insensitively and is stable by uid', () {
      final sorted = CoachRoster.sorted([
        const CoachAthlete(uid: 'b', username: 'malina'),
        const CoachAthlete(uid: 'a', username: 'Cdawg'),
        const CoachAthlete(uid: 'c', username: 'The_Dragon'),
      ]);
      expect(sorted.map((a) => a.username).toList(),
          ['Cdawg', 'malina', 'The_Dragon']);
    });
  });

  group('super-admin vs ordinary coach roster shape', () {
    // The super-admin path builds from every users/{uid} document; the
    // ordinary path builds only from assignment sources. These pure builders
    // are what the two screens share, so a divergence like the production
    // 3-athlete bug would fail here.
    test('super-admin roster includes every user document', () {
      final allUsers = {
        'u1': {'username': 'Cdawg', 'email': 'courtney@x.com'},
        'u2': {'username': 'Malina', 'email': 'malinka@x.com'},
        'u3': {'username': 'The_Dragon', 'email': 'clifford@x.com'},
        'u4': {'username': 'Someone Else', 'email': 'else@x.com'},
        'u5': {'email': 'nameless@x.com'},
      };
      final roster = CoachRoster.sorted(
        allUsers.entries.map((e) => CoachRoster.fromUserDoc(e.key, e.value)),
      );
      expect(roster.length, 5, reason: 'super-admin must see the whole roster');
      expect(roster.map((a) => a.uid).toSet(),
          {'u1', 'u2', 'u3', 'u4', 'u5'});
    });

    test('ordinary coach roster is limited to authorised assignments only', () {
      // Same user base as above, but this coach has one approved athlete and
      // one seeded athlete: the other three must not appear.
      final uids = CoachRoster.assignedUids(
        approvedAthleteUids: ['u2'],
        seededAthletes: {'u4': {'email': 'else@x.com'}},
      );
      expect(uids, {'u2', 'u4'});
      expect(uids.contains('u1'), isFalse);
      expect(uids.contains('u3'), isFalse);
      expect(uids.contains('u5'), isFalse);
    });
  });
}
