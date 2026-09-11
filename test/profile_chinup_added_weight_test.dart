// The Chin-Up record, shown as the load ADDED to bodyweight.
//
// A Chin-Up is lifted as bodyweight plus whatever hangs from the belt, and the
// profile used to print the system total ("138.5 kg × 3") as if it were a
// barbell load. It now prints "+53.5 kg × 3, at 85 kg BW", using the
// bodyweight the server recorded for THAT lift's date.
//
// What must NOT move is pinned here just as hard as what must: the other four
// lifts print exactly what they always printed, record selection and
// fingerprints are untouched, and a missing bodyweight is said out loud rather
// than replaced with today's.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/e1rm_spec.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/core/showcase_reducer.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/ui/big_five_showcase.dart';
import 'package:localtest222/profile/ui/record_presentation.dart';
import 'package:localtest222/profile/ui/units.dart';

const String kChin = 'XM9026peNIu0R8qh7UqY';
const String kBench = 'AmfUWbF1DH3I7qPAdh5k';

ShowcaseRecord rec({
  String slot = BigFiveSlot.chinUp,
  required double weight,
  required int reps,
  String? basis = ShowcaseLoadBasis.absolute,
  double? bw,
  String dateKey = '2026-06-01',
}) =>
    ShowcaseRecord(
      slot: slot,
      exerciseId: slot == BigFiveSlot.chinUp ? kChin : kBench,
      dateKey: dateKey,
      setKey: 's0',
      weight: weight,
      reps: reps,
      e1rm: showcaseE1rm(weight, reps),
      formulaVersion: kE1rmFormulaVersion,
      fingerprint: 'fp-$slot-$dateKey-$weight-$reps',
      loadBasis: basis,
      bodyweightKg: bw,
      bodyweightDateKey: bw == null ? null : dateKey,
    );

RecordPresentation e1rmOf(ShowcaseRecord r,
        [WeightUnits units = WeightUnits.kilograms]) =>
    presentShowcaseRecord(record: r, isE1rm: true, units: units);

RecordPresentation heaviestOf(ShowcaseRecord r,
        [WeightUnits units = WeightUnits.kilograms]) =>
    presentShowcaseRecord(record: r, isE1rm: false, units: units);

void main() {
  group('the reported example', () {
    test('best E1RM 146.6 from 138.5 × 3 at 85 kg reads +61.6 from +53.5 × 3',
        () {
      final ShowcaseRecord r = rec(weight: 138.5, reps: 3, bw: 85);
      // The stored record is the system total, and stays so.
      expect(WeightUnits.kilograms.format(r.e1rm), '146.6 kg');
      final RecordPresentation p = e1rmOf(r);
      expect(p.value, '+61.6 kg');
      expect(p.source, '+53.5 kg × 3');
      expect(p.bodyweightNote, 'at 85 kg BW');
    });

    test('heaviest 142 × 2 at 85 kg reads +57 from +57 × 2', () {
      final RecordPresentation p = heaviestOf(rec(weight: 142, reps: 2, bw: 85));
      expect(p.value, '+57 kg');
      expect(p.source, '+57 kg × 2');
      expect(p.bodyweightNote, 'at 85 kg BW');
    });
  });

  group('each column uses its own lift\'s bodyweight', () {
    test('E1RM and heaviest on different days subtract different bodyweights',
        () {
      final RecordPresentation e =
          e1rmOf(rec(weight: 138.5, reps: 3, bw: 85, dateKey: '2026-06-01'));
      final RecordPresentation h = heaviestOf(
          rec(weight: 142, reps: 2, bw: 83.4, dateKey: '2026-06-15'));
      expect(e.value, '+61.6 kg');
      expect(e.bodyweightNote, 'at 85 kg BW');
      expect(h.value, '+58.6 kg');
      expect(h.source, '+58.6 kg × 2');
      expect(h.bodyweightNote, 'at 83.4 kg BW');
    });
  });

  group('formatting', () {
    test('positive added loads carry an explicit plus sign', () {
      expect(heaviestOf(rec(weight: 95, reps: 5, bw: 85)).value, '+10 kg');
      expect(WeightUnits.kilograms.formatAdded(2.5), '+2.5 kg');
    });

    test('decimals follow the showcase format, with no float noise', () {
      // 138.6 − 85.2 is 53.39999999999999 in binary floating point.
      final RecordPresentation p =
          heaviestOf(rec(weight: 138.6, reps: 5, bw: 85.2));
      expect(p.value, '+53.4 kg');
      expect(p.source, '+53.4 kg × 5');
      expect(WeightUnits.kilograms.formatAdded(57.00000001), '+57 kg');
      expect(WeightUnits.kilograms.formatAdded(60.0), '+60 kg');
      expect(WeightUnits.kilograms.formatAdded(0.04), 'BW');
      expect(WeightUnits.kilograms.formatAdded(-0.04), 'BW');
    });

    test('bodyweight only reads as BW, never +0 or −0', () {
      final RecordPresentation h = heaviestOf(rec(weight: 85, reps: 10, bw: 85));
      expect(h.value, 'BW');
      expect(h.source, 'BW × 10');
      expect(h.bodyweightNote, 'at 85 kg BW');
      // Ten bodyweight reps still estimate a single with added load.
      expect(e1rmOf(rec(weight: 85, reps: 10, bw: 85)).value, '+28.3 kg');
    });

    test('a load below the recorded bodyweight is shown honestly, never "+-"',
        () {
      final RecordPresentation h = heaviestOf(rec(weight: 80, reps: 3, bw: 85));
      expect(h.value, '−5 kg');
      expect(h.source, '−5 kg × 3');
      for (final String s in <String>[h.value, h.source]) {
        expect(s.contains('+-'), isFalse);
        expect(s.contains('+−'), isFalse);
      }
    });

    test('pounds convert the added load and the bodyweight alike', () {
      final RecordPresentation h =
          heaviestOf(rec(weight: 138.5, reps: 3, bw: 85), WeightUnits.pounds);
      expect(h.value, '+117.9 lb');
      expect(h.bodyweightNote, 'at 187.4 lb BW');
    });
  });

  group('when the bodyweight context is missing', () {
    test('no weigh-in on or before the lift: the total, marked as such', () {
      final ShowcaseRecord r = rec(weight: 138.5, reps: 3, bw: null);
      final RecordPresentation e = e1rmOf(r);
      expect(e.value, '146.6 kg');
      expect(e.source, '138.5 kg × 3');
      expect(e.bodyweightNote, 'Total · BW not recorded');
      final RecordPresentation h = heaviestOf(rec(weight: 142, reps: 2));
      expect(h.value, '142 kg');
      expect(h.bodyweightNote, 'Total · BW not recorded');
    });

    test('a record published before it carried a basis is not converted', () {
      // Even with a bodyweight beside it, an unknown basis is not guessed at.
      final RecordPresentation e =
          e1rmOf(rec(weight: 138.5, reps: 3, basis: null, bw: 85));
      expect(e.value, '146.6 kg');
      expect(e.source, '138.5 kg × 3');
      expect(e.bodyweightNote, 'Total incl. BW');
    });

    test('an invalid bodyweight counts as none', () {
      for (final double bad in <double>[0, -85, double.nan, double.infinity]) {
        expect(heaviestOf(rec(weight: 142, reps: 2, bw: bad)).bodyweightNote,
            'Total · BW not recorded',
            reason: '$bad');
      }
    });
  });

  group('loads stored as the added part (WES2)', () {
    test('the stored load IS the added load; the E1RM is lifted at BW + added',
        () {
      final ShowcaseRecord r =
          rec(weight: 20, reps: 5, basis: ShowcaseLoadBasis.added, bw: 85);
      expect(heaviestOf(r).value, '+20 kg');
      expect(heaviestOf(r).source, '+20 kg × 5');
      // E1RM(105 × 5) = 118.125; minus 85 = 33.125.
      expect(e1rmOf(r).value, '+33.1 kg');
      expect(e1rmOf(r).bodyweightNote, 'at 85 kg BW');
    });

    test('without a bodyweight the added load stands and the E1RM is unknown',
        () {
      final ShowcaseRecord r =
          rec(weight: 20, reps: 5, basis: ShowcaseLoadBasis.added);
      expect(heaviestOf(r).value, '+20 kg');
      expect(e1rmOf(r).value, '—');
      expect(e1rmOf(r).bodyweightNote, 'BW not recorded');
    });
  });

  group('the other four lifts are untouched', () {
    const List<String> others = <String>[
      BigFiveSlot.bench,
      BigFiveSlot.squat,
      BigFiveSlot.deadlift,
      BigFiveSlot.ohpUnilateral,
    ];

    test('they print exactly the strings the showcase always printed', () {
      for (final String slot in others) {
        for (final List<num> wr in <List<num>>[
          <num>[180, 2],
          <num>[182.5, 1],
          <num>[100.25, 8],
          <num>[42.5, 12],
        ]) {
          for (final WeightUnits units in <WeightUnits>[
            WeightUnits.kilograms,
            WeightUnits.pounds,
          ]) {
            // Even a record that somehow carried bodyweight fields.
            final ShowcaseRecord r = rec(
                slot: slot,
                weight: wr[0].toDouble(),
                reps: wr[1].toInt(),
                bw: 85);
            final RecordPresentation e = e1rmOf(r, units);
            final RecordPresentation h = heaviestOf(r, units);
            final String legacySource =
                '${units.format(r.weight)} × ${r.reps}';
            expect(e.value, units.format(r.e1rm), reason: slot);
            expect(h.value, units.format(r.weight), reason: slot);
            expect(e.source, legacySource, reason: slot);
            expect(h.source, legacySource, reason: slot);
            expect(e.bodyweightNote, isNull, reason: slot);
            expect(h.bodyweightNote, isNull, reason: slot);
          }
        }
      }
    });

    test('only the Chin-Up is bodyweight-loaded, on both platforms', () {
      expect(
        kBigFive.where((BigFiveLift l) => l.bodyweightLoaded).map((l) => l.slot),
        <String>[BigFiveSlot.chinUp],
      );
      final String js =
          File('functions/showcase/big_five.js').readAsStringSync();
      expect('bodyweightLoaded: true'.allMatches(js).length, 1);
      final int chinAt = js.indexOf("slot: SLOTS.CHIN_UP");
      final int nextAt = js.indexOf('slot: SLOTS.', chinAt + 1);
      expect(js.substring(chinAt, nextAt), contains('bodyweightLoaded: true'));
    });
  });

  group('selection, storage and fingerprints are unchanged', () {
    Map<String, Object?> day(String id, List<Map<String, Object?>> sets) =>
        <String, Object?>{
          'exercises': <Object?>[
            <String, Object?>{'exerciseId': id, 'name': 'x', 'sets': sets},
          ],
        };

    test('the basis is WES2\'s setIndex stamp, exactly as the server reads it',
        () {
      expect(ShowcaseLoadBasis.ofSetMap(<String, Object?>{'setIndex': 0}),
          ShowcaseLoadBasis.added);
      expect(ShowcaseLoadBasis.ofSetMap(<String, Object?>{'weight': 138.5}),
          ShowcaseLoadBasis.absolute);
      expect(ShowcaseLoadBasis.ofSetMap(<String, Object?>{'setIndex': '1'}),
          ShowcaseLoadBasis.absolute);
      expect(ShowcaseLoadBasis.parse('added'), ShowcaseLoadBasis.added);
      expect(ShowcaseLoadBasis.parse('assisted'), isNull);
    });

    test('the same performances hold the same records with or without setIndex',
        () {
      final Map<String, Object?> legacy = <String, Object?>{
        '2026-06-01': day(kChin, <Map<String, Object?>>[
          <String, Object?>{'weight': 138.5, 'reps': 3},
          <String, Object?>{'weight': 142, 'reps': 2},
        ]),
        '2026-06-09': day(kBench, <Map<String, Object?>>[
          <String, Object?>{'weight': 120, 'reps': 3},
        ]),
      };
      final Map<String, Object?> stamped = <String, Object?>{
        '2026-06-01': day(kChin, <Map<String, Object?>>[
          <String, Object?>{'setIndex': 0, 'weight': 138.5, 'reps': 3},
          <String, Object?>{'setIndex': 1, 'weight': 142, 'reps': 2},
        ]),
        '2026-06-09': day(kBench, <Map<String, Object?>>[
          <String, Object?>{'setIndex': 0, 'weight': 120, 'reps': 3},
        ]),
      };
      final ProfileShowcase a = buildShowcase(legacy);
      final ProfileShowcase b = buildShowcase(stamped);
      for (final String kind in <String>['e1rm', 'heaviest']) {
        ShowcaseRecord pick(ProfileShowcase s) {
          final ShowcaseLiftSnapshot chin = s.forSlot(BigFiveSlot.chinUp);
          return kind == 'e1rm' ? chin.bestE1rm! : chin.heaviest!;
        }

        expect(pick(a).fingerprint, pick(b).fingerprint, reason: kind);
        expect(pick(a).weight, pick(b).weight, reason: kind);
        expect(pick(a).dateKey, pick(b).dateKey, reason: kind);
        expect(pick(a).setKey, pick(b).setKey, reason: kind);
      }
      expect(a.forSlot(BigFiveSlot.chinUp).bestE1rm!.loadBasis,
          ShowcaseLoadBasis.absolute);
      expect(b.forSlot(BigFiveSlot.chinUp).bestE1rm!.loadBasis,
          ShowcaseLoadBasis.added);
      // Bench carries no bodyweight field, so its published map is unchanged.
      expect(a.forSlot(BigFiveSlot.bench).bestE1rm!.toMap(),
          b.forSlot(BigFiveSlot.bench).bestE1rm!.toMap());
      expect(
          a.forSlot(BigFiveSlot.bench).bestE1rm!.toMap().keys,
          <String>[
            'slot',
            'exerciseId',
            'dateKey',
            'setKey',
            'weight',
            'reps',
            'e1rm',
            'formulaVersion',
            'fingerprint',
          ]);
    });

    test('annotations round-trip, and never enter the fingerprint', () {
      final ShowcaseRecord r = rec(weight: 138.5, reps: 3, bw: 85);
      final ShowcaseRecord back = ShowcaseRecord.fromMap(r.toMap())!;
      expect(back.loadBasis, ShowcaseLoadBasis.absolute);
      expect(back.bodyweightKg, 85);
      expect(back.bodyweightDateKey, '2026-06-01');
      expect(
        recordFingerprint(
          slot: r.slot,
          exerciseId: r.exerciseId,
          dateKey: r.dateKey,
          setKey: r.setKey,
          weight: r.weight,
          reps: r.reps,
        ),
        recordFingerprint(
          slot: back.slot,
          exerciseId: back.exerciseId,
          dateKey: back.dateKey,
          setKey: back.setKey,
          weight: back.weight,
          reps: back.reps,
        ),
      );
      final ShowcaseRecord? junk = ShowcaseRecord.fromMap(<String, Object?>{
        'slot': BigFiveSlot.chinUp,
        'fingerprint': 'fp',
        'loadBasis': 'assisted',
        'bodyweightKg': -1,
        'bodyweightDateKey': '',
      });
      expect(junk!.loadBasis, isNull);
      expect(junk.bodyweightKg, isNull);
      expect(junk.bodyweightDateKey, isNull);
    });

    test('a day contribution keeps the basis through storage', () {
      final ShowcaseDayContribution d = summarizeWorkoutDay(
        '2026-06-01',
        day(kChin, <Map<String, Object?>>[
          <String, Object?>{'setIndex': 0, 'weight': 20, 'reps': 5},
        ]),
      )[BigFiveSlot.chinUp]!;
      final ShowcaseDayContribution back =
          ShowcaseDayContribution.fromMap(d.toMap())!;
      expect(back.bestE1rmSet.basis, ShowcaseLoadBasis.added);
      final Map<String, Object?> bench = summarizeWorkoutDay(
        '2026-06-09',
        day(kBench, <Map<String, Object?>>[
          <String, Object?>{'weight': 120, 'reps': 3},
        ]),
      )[BigFiveSlot.bench]!
          .toMap();
      expect((bench['bestE1rm']! as Map<String, Object?>).keys,
          <String>['setKey', 'weight', 'reps']);
    });

    test('presenting a record never changes it', () {
      final ShowcaseRecord r = rec(weight: 138.5, reps: 3, bw: 85);
      final Map<String, Object?> before = r.toMap();
      e1rmOf(r);
      heaviestOf(r);
      expect(r.toMap(), before);
      expect(r.weight, 138.5, reason: 'the canonical system load is kept');
    });
  });

  group('the card', () {
    ShowcaseView viewWith(Map<String, ShowcaseLiftSnapshot> lifts) =>
        ShowcaseView(showcase: ProfileShowcase(lifts: lifts));

    Future<void> pumpShowcase(WidgetTester tester, ShowcaseView view) async {
      tester.view.physicalSize = const Size(360, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BigFiveShowcase(
              view: view,
              units: WeightUnits.kilograms,
              isOwner: false,
              onAddProof: (_) {},
              onOpenProof: (_) {},
              onRemoveProof: (_, __) {},
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('shows the added loads, each column with its own bodyweight',
        (WidgetTester tester) async {
      await pumpShowcase(
        tester,
        viewWith(<String, ShowcaseLiftSnapshot>{
          BigFiveSlot.chinUp: ShowcaseLiftSnapshot(
            slot: BigFiveSlot.chinUp,
            bestE1rm: rec(weight: 138.5, reps: 3, bw: 85, dateKey: '2026-06-01'),
            heaviest: rec(weight: 142, reps: 2, bw: 83, dateKey: '2026-06-15'),
          ),
          BigFiveSlot.bench: ShowcaseLiftSnapshot(
            slot: BigFiveSlot.bench,
            bestE1rm: rec(
                slot: BigFiveSlot.bench,
                weight: 120,
                reps: 3,
                dateKey: '2026-06-09'),
            heaviest: rec(
                slot: BigFiveSlot.bench,
                weight: 120,
                reps: 3,
                dateKey: '2026-06-09'),
          ),
        }),
      );

      expect(find.text('+61.6 kg'), findsOneWidget);
      expect(find.text('+53.5 kg × 3'), findsOneWidget);
      expect(find.text('at 85 kg BW'), findsOneWidget);
      expect(find.text('1 Jun 2026'), findsOneWidget);

      expect(find.text('+59 kg'), findsOneWidget);
      expect(find.text('+59 kg × 2'), findsOneWidget);
      expect(find.text('at 83 kg BW'), findsOneWidget);
      expect(find.text('15 Jun 2026'), findsOneWidget);

      // The absolute totals are no longer the headline for the Chin-Up.
      expect(find.text('146.6 kg'), findsNothing);
      expect(find.text('142 kg'), findsNothing);

      // Bench is exactly as it was: total loads, no bodyweight line.
      expect(find.text('120 kg × 3'), findsNWidgets(2));
      expect(find.textContaining(' BW'), findsNWidgets(2));
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
    });

    testWidgets('says so when the bodyweight is not recorded',
        (WidgetTester tester) async {
      await pumpShowcase(
        tester,
        viewWith(<String, ShowcaseLiftSnapshot>{
          BigFiveSlot.chinUp: ShowcaseLiftSnapshot(
            slot: BigFiveSlot.chinUp,
            bestE1rm: rec(weight: 138.5, reps: 3),
            heaviest: rec(weight: 142, reps: 2),
          ),
        }),
      );
      expect(find.text('Total · BW not recorded'), findsNWidgets(2));
      expect(find.text('146.6 kg'), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
