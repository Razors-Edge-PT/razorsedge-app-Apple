import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_checkins_logic.dart';
import 'package:localtest222/coach_weekly_review_screen.dart';

/// Coaching service tiers on the Weekly Review: the stored value contract,
/// the grouped/alphabetical recap order, and persistence through the real
/// settings write used by the Check-in Athletes screen.

AthleteReview _athlete(String uid, String name,
    {Object? service, String status = CheckInStatus.draft}) {
  final r = AthleteReview(
    uid: uid,
    settings: {
      'reportingEnabled': true,
      'goal': 'cut',
      if (service != null) CoachingService.field: service,
    },
    rosterName: name,
  );
  r.report = {
    'status': status,
    'draftIfPrevNotCopied': 'draft $name',
    'draftIfPrevCopied': 'draft $name',
    'workoutDates': const <String>[],
    'events': const <Object>[],
  };
  return r;
}

List<String> _order(Iterable<AthleteReview> reviews) => [
      for (final g in CoachRecapList.groupsOf(reviews))
        for (final a in g.items) '${g.label}|${a.displayName}|${a.uid}',
    ];

void main() {
  group('stored value contract', () {
    test('exactly four selectable tiers, in order, with the requested labels', () {
      expect(CoachingService.ordered,
          ['inPerson', 'fullOnline', 'eightWeek', 'prospective']);
      expect(CoachingService.ordered.map(CoachingService.label).toList(),
          ['In-Person', 'Full online service', '8-week program', 'Prospective']);
      expect(CoachingService.ordered, isNot(contains('unassigned')));
    });

    test('missing, legacy or unknown values normalise to Unassigned (null)', () {
      for (final v in [null, '', 'Prospective', 'in_person', 'unassigned', 3, true]) {
        expect(CoachingService.normalize(v), isNull, reason: '$v');
      }
      expect(CoachingService.normalize('eightWeek'), 'eightWeek');
    });

    test('patchFor refuses anything that is not a tier', () {
      expect(CoachingService.patchFor('prospective'), {'coachingService': 'prospective'});
      expect(() => CoachingService.patchFor('unassigned'), throwsArgumentError);
      expect(() => CoachingService.patchFor('Prospective'), throwsArgumentError);
    });
  });

  group('recap order', () {
    test('groups in tier order with Unassigned last; alphabetical; uid tie-break', () {
      final reviews = [
        _athlete('u9', 'zoe', service: 'prospective'),
        _athlete('u2', 'Ben', service: 'inPerson'),
        _athlete('u1', 'amy', service: 'inPerson'),
        _athlete('u5', 'Legacy Larry'), // no tier
        _athlete('u7', 'Cara', service: 'eightWeek'),
        _athlete('u4', 'Dan', service: 'fullOnline'),
        _athlete('u3', 'Ben', service: 'inPerson'), // identical name
        _athlete('u6', 'Abe', service: 'bogus'), // unknown value
      ];
      expect(_order(reviews), [
        'In-Person|amy|u1',
        'In-Person|Ben|u2',
        'In-Person|Ben|u3',
        'Full online service|Dan|u4',
        '8-week program|Cara|u7',
        'Prospective|zoe|u9',
        'Unassigned|Abe|u6',
        'Unassigned|Legacy Larry|u5',
      ]);
      // Input order never matters.
      expect(_order(reviews.reversed), _order(reviews));
    });

    test('uses the preferred display name (report name over settings over roster)', () {
      final a = _athlete('u1', 'Roster Zed', service: 'inPerson');
      final b = _athlete('u2', 'Roster Amy', service: 'inPerson');
      a.report!['displayName'] = 'Aaron';
      expect(_order([a, b]), ['In-Person|Aaron|u1', 'In-Person|Roster Amy|u2']);
    });

    test('no one is bulk-assigned: an all-legacy roster is one Unassigned group', () {
      final groups = CoachRecapList.groupsOf([_athlete('a', 'A'), _athlete('b', 'B')]);
      expect(groups.map((g) => g.label), ['Unassigned']);
    });

    test('filters keep the grouping; empty groups disappear', () {
      final reviews = [
        _athlete('u1', 'Amy', service: 'inPerson', status: CheckInStatus.copied),
        _athlete('u2', 'Ben', service: 'inPerson'),
        _athlete('u3', 'Cat', service: 'prospective', status: CheckInStatus.copied),
        _athlete('u4', 'Dee'),
      ];
      final ready = reviews.where((a) => a.status == CheckInStatus.draft);
      expect(_order(ready), ['In-Person|Ben|u2', 'Unassigned|Dee|u4']);
    });

    test('reassigning a tier moves the card to its new group', () {
      final amy = _athlete('u1', 'Amy', service: 'prospective');
      final reviews = [amy, _athlete('u2', 'Ben', service: 'inPerson')];
      expect(_order(reviews), ['In-Person|Ben|u2', 'Prospective|Amy|u1']);
      amy.settings = {...amy.settings, ...CoachingService.patchFor('inPerson')};
      expect(_order(reviews), ['In-Person|Amy|u1', 'In-Person|Ben|u2']);
    });
  });

  group('recap list widget', () {
    testWidgets('renders visible group headers in order with the real cards',
        (tester) async {
      final reviews = [
        _athlete('u3', 'Cara'),
        _athlete('u2', 'Ben', service: 'fullOnline'),
        _athlete('u1', 'Amy', service: 'inPerson'),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CoachRecapList(
            reviews: reviews,
            cardBuilder: (context, a) => CoachAthleteReviewCard(
              key: ValueKey('weeklyReviewCard_${a.uid}'),
              review: a,
              currentKey: '2026-09-14',
              busy: false,
              mutable: true,
              onCopy: () {},
              onRecopy: () {},
              onUndo: () {},
              onSkip: () {},
              onOpenPlanner: () {},
            ),
          ),
        ),
      ));

      final inPerson = find.byKey(const ValueKey('recapGroup_inPerson'));
      final online = find.byKey(const ValueKey('recapGroup_fullOnline'));
      final unassigned = find.byKey(const ValueKey('recapGroup_unassigned'));
      expect(find.text('In-Person · 1'), findsOneWidget);
      expect(find.text('Full online service · 1'), findsOneWidget);
      expect(find.text('Unassigned · 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('recapGroup_eightWeek')), findsNothing);

      double y(Finder f) => tester.getTopLeft(f).dy;
      final amy = find.byKey(const ValueKey('weeklyReviewCard_u1'));
      final ben = find.byKey(const ValueKey('weeklyReviewCard_u2'));
      final cara = find.byKey(const ValueKey('weeklyReviewCard_u3'));
      expect(y(inPerson), lessThan(y(amy)));
      expect(y(amy), lessThan(y(online)));
      expect(y(online), lessThan(y(ben)));
      expect(y(ben), lessThan(y(unassigned)));
      expect(y(unassigned), lessThan(y(cara)));
    });
  });

  group('persistence through the settings write', () {
    test('saving a tier merges only that field and survives a fresh read', () async {
      final db = FakeFirebaseFirestore();
      final ref = db.doc('coachCheckIns/coachA/athletes/ath1');
      await ref.set({
        'reportingEnabled': true,
        'goal': 'bulk',
        'messageExerciseMode': 'custom',
        'customExerciseIds': ['x', 'y'],
        'goalSetAt': 1234, // server-owned
        'lastFinalizedCoverageEnd': '2026-09-10', // server-owned
      });

      await saveCoachAthleteSettings(db,
          coachUid: 'coachA',
          athleteUid: 'ath1',
          patch: CoachingService.patchFor('eightWeek'),
          displayName: 'Ath One');

      // "Restart": a brand-new review built from a fresh document read.
      final data = (await ref.get()).data()!;
      expect(data['coachingService'], 'eightWeek');
      expect(data['reportingEnabled'], true);
      expect(data['goal'], 'bulk');
      expect(data['messageExerciseMode'], 'custom');
      expect(data['customExerciseIds'], ['x', 'y']);
      expect(data['goalSetAt'], 1234);
      expect(data['lastFinalizedCoverageEnd'], '2026-09-10');
      final reloaded = AthleteReview(uid: 'ath1', settings: data, rosterName: 'Ath One');
      expect(reloaded.coachingService, 'eightWeek');

      // Changing the goal afterwards keeps the tier.
      await saveCoachAthleteSettings(db,
          coachUid: 'coachA', athleteUid: 'ath1', patch: {'goal': 'cut'});
      expect((await ref.get()).data()!['coachingService'], 'eightWeek');
    });

    test('one coach\'s tier is stored on that coach\'s relationship only', () async {
      final db = FakeFirebaseFirestore();
      await saveCoachAthleteSettings(db,
          coachUid: 'coachA', athleteUid: 'ath1', patch: CoachingService.patchFor('inPerson'));
      await saveCoachAthleteSettings(db,
          coachUid: 'coachB', athleteUid: 'ath1', patch: CoachingService.patchFor('prospective'));
      expect((await db.doc('coachCheckIns/coachA/athletes/ath1').get()).data()!['coachingService'],
          'inPerson');
      expect((await db.doc('coachCheckIns/coachB/athletes/ath1').get()).data()!['coachingService'],
          'prospective');
    });
  });
}
