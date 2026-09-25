// profileShowcaseV2 on the client: parsing the server's output, the V1
// fallback, the default (highest-scoring) exercise per category, and the
// category card's dropdown — identical for the owner and a friend.
//
// The V2 snapshot used here is functions/test/fixtures/showcase_v2_sample.json,
// which functions/test/showcase_v2.test.js asserts is exactly what the server
// reducer builds. So these tests parse genuine server output.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/re_catalog.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/core/showcase_v2_models.dart';
import 'package:localtest222/profile/data/showcase_repository.dart';
import 'package:localtest222/profile/ui/big_five_showcase.dart';
import 'package:localtest222/profile/ui/units.dart';

const String kBench = 'AmfUWbF1DH3I7qPAdh5k';
const String kDbBench = 'kTs5fLSTKjUkUZL10iii';
const String kChin = 'XM9026peNIu0R8qh7UqY';
const String kLat = '1XOIXxeLFhgmgjZS9Cyq';
const String kOhpDb = 'RdsGazgdH0xgpjek0n3u';
const String kOhpBb = 'lVDG90yN6Z8aPjRNV2wc';
const String kDip = 'FtayDmR5BVnGS1FXlXLL';
const String kDeadlift = 'MsGl7e9yanDeEnYX0e4X';
const String kSumo = '10pEctikt6PP8eAg9Eip';
const String kHipThrust = 'LGhFj8o0sG3X12296UAh';
const String kBssBb = 'VUEvvjuo4cxBghNuux66';

Map<String, dynamic> _golden() {
  for (Directory d = Directory.current; d.parent.path != d.path; d = d.parent) {
    final File f =
        File('${d.path}/functions/test/fixtures/showcase_v2_sample.json');
    if (f.existsSync()) {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  fail('showcase_v2_sample.json not found');
}

ShowcaseRecord _v1Record(String slot, String exerciseId, double weight) =>
    ShowcaseRecord(
      slot: slot,
      exerciseId: exerciseId,
      dateKey: '2026-01-05',
      setKey: 's0',
      weight: weight,
      reps: 1,
      e1rm: weight,
      formulaVersion: 1,
      fingerprint: recordFingerprint(
        slot: slot,
        exerciseId: exerciseId,
        dateKey: '2026-01-05',
        setKey: 's0',
        weight: weight,
        reps: 1,
      ),
    );

ProfileShowcase _v1() => ProfileShowcase(lifts: <String, ShowcaseLiftSnapshot>{
      BigFiveSlot.bench: ShowcaseLiftSnapshot(
        slot: BigFiveSlot.bench,
        bestE1rm: _v1Record(BigFiveSlot.bench, kBench, 100),
        heaviest: _v1Record(BigFiveSlot.bench, kBench, 100),
      ),
    });

void main() {
  final Map<String, dynamic> golden = _golden();

  group('parsing server output', () {
    final ProfileShowcaseV2 v2 = ProfileShowcaseV2.fromMap(golden)!;

    ShowcaseCategorySnapshot cat(String key) => v2.categories
        .firstWhere((ShowcaseCategorySnapshot c) => c.category.key == key);

    test('five categories in display order, every configured exercise listed',
        () {
      expect(v2.isV1Fallback, isFalse);
      expect(v2.showsPoints, isTrue);
      expect(v2.categories.map((ShowcaseCategorySnapshot c) => c.category.key),
          kReCategories.map((ReCategory c) => c.key));
      for (final ShowcaseCategorySnapshot c in v2.categories) {
        expect(
            c.exercises.map((ShowcaseExerciseSnapshot e) => e.exerciseId),
            reExercisesOfCategory(c.category.key)
                .map((ReExercise e) => e.exerciseId));
        expect(c.hasChoice, isTrue);
      }
    });

    test('the highest scorer is the default in every category', () {
      expect(cat(ReCategoryKey.horizontalPress).defaultExerciseId, kDbBench);
      expect(cat(ReCategoryKey.verticalPull).defaultExerciseId, kChin);
      expect(cat(ReCategoryKey.overheadPress).defaultExerciseId, kOhpDb);
      // Conventional and sumo tie exactly: catalogue order decides.
      expect(cat(ReCategoryKey.hipHinge).defaultExerciseId, kDeadlift);
      expect(cat(ReCategoryKey.squatPattern).defaultExerciseId, kBssBb);
    });

    test('the client default equals the server-published bestExerciseId', () {
      final Map<String, dynamic> cats =
          golden['categories'] as Map<String, dynamic>;
      for (final ShowcaseCategorySnapshot c in v2.categories) {
        expect(c.defaultExerciseId,
            (cats[c.category.key] as Map<String, dynamic>)['bestExerciseId']);
      }
    });

    test('unavailable points are null, distinct from a record-less placeholder',
        () {
      final ShowcaseExerciseSnapshot hip =
          cat(ReCategoryKey.hipHinge).exerciseById(kHipThrust)!;
      expect(hip.hasRecord, isTrue);
      expect(hip.rePoints, isNull);
      final ShowcaseExerciseSnapshot ohpBb =
          cat(ReCategoryKey.overheadPress).exerciseById(kOhpBb)!;
      expect(ohpBb.hasRecord, isFalse);
      expect(ohpBb.rePoints, isNull);
    });

    test('bodyweight-loaded records keep their bodyweight context', () {
      final ShowcaseExerciseSnapshot dip =
          cat(ReCategoryKey.overheadPress).exerciseById(kDip)!;
      expect(dip.bestE1rm!.slot, 'tricepsDip');
      expect(dip.bestE1rm!.bodyweightKg, 80);
      expect(dip.bestE1rm!.totalKg, 80);
      expect(dip.bestE1rm!.loadBasis, ShowcaseLoadBasis.added);
    });

    test('live fingerprints cover every exercise, including new ones', () {
      final ShowcaseView view = ShowcaseView(
        showcase: ProfileShowcase.empty,
        showcaseV2: v2,
        proofsByFingerprint: <String, ProofRecord>{
          cat(ReCategoryKey.hipHinge)
              .exerciseById(kSumo)!
              .bestE1rm!
              .fingerprint: ProofRecord(
            fingerprint: cat(ReCategoryKey.hipHinge)
                .exerciseById(kSumo)!
                .bestE1rm!
                .fingerprint,
            slot: 'deadliftSumo',
            postId: 'p1',
          ),
          'retired': const ProofRecord(
              fingerprint: 'retired', slot: 'x', postId: 'p2'),
        },
      );
      expect(view.staleProofs.map((ProofRecord p) => p.fingerprint),
          <String>['retired']);
      expect(
          view.proofFor(
              cat(ReCategoryKey.hipHinge).exerciseById(kSumo)!.bestE1rm),
          isNotNull);
      expect(view.oneVideoCoversBoth('deadliftSumo'), isTrue);
    });
  });

  group('fallback to V1', () {
    test('absent or malformed V2 falls back to the V1 display', () {
      for (final Object? raw in <Object?>[
        null,
        'garbage',
        <String, Object?>{
          'schema': 'profileShowcaseV1',
          'categories': <String, Object?>{}
        },
        <String, Object?>{'schema': 'profileShowcaseV2'},
        <String, Object?>{'schema': 'profileShowcaseV2', 'categories': 7},
      ]) {
        expect(ProfileShowcaseV2.fromMap(raw), isNull, reason: '$raw');
        final ProfileShowcaseV2 r = ProfileShowcaseV2.resolve(raw, _v1());
        expect(r.isV1Fallback, isTrue);
        expect(r.showsPoints, isFalse);
      }
    });

    test('the fallback shows exactly the five V1 lifts, one per category', () {
      final ProfileShowcaseV2 r = ProfileShowcaseV2.fromV1(_v1());
      expect(
        <String>[
          for (final ShowcaseCategorySnapshot c in r.categories)
            for (final ShowcaseExerciseSnapshot e in c.exercises)
              e.exercise.slot,
        ],
        <String>['bench', 'chinUp', 'ohpUnilateral', 'deadlift', 'squat'],
      );
      for (final ShowcaseCategorySnapshot c in r.categories) {
        expect(c.hasChoice, isFalse);
      }
      expect(r.categories.first.defaultExercise.bestE1rm!.weight, 100);
    });

    test('a ShowcaseView without V2 renders the V1 fallback', () {
      final ShowcaseView view = ShowcaseView(showcase: _v1());
      expect(view.categories.isV1Fallback, isTrue);
    });

    test('a malformed exercise entry becomes a placeholder, not a crash', () {
      final Map<String, dynamic> broken =
          jsonDecode(jsonEncode(golden)) as Map<String, dynamic>;
      ((broken['categories'] as Map<String, dynamic>)['horizontalPress']
          as Map<String, dynamic>)['exercises'][kDbBench] = 'nope';
      final ProfileShowcaseV2 v2 = ProfileShowcaseV2.fromMap(broken)!;
      final ShowcaseCategorySnapshot hp = v2.categories.first;
      expect(hp.exerciseById(kDbBench)!.hasRecord, isFalse);
      expect(hp.defaultExerciseId, kBench);
    });
  });

  group('the category card', () {
    Future<void> pump(WidgetTester tester, ShowcaseView view,
        {required bool isOwner, Key? key}) async {
      tester.view.physicalSize = const Size(420, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BigFiveShowcase(
              key: key,
              view: view,
              units: WeightUnits.kilograms,
              isOwner: isOwner,
              onAddProof: (_) {},
              onOpenProof: (_) {},
              onRemoveProof: (_, __) {},
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    ShowcaseView goldenView() => ShowcaseView(
          showcase: ProfileShowcase.empty,
          showcaseV2: ProfileShowcaseV2.fromMap(golden),
        );

    Finder card(String key) =>
        find.byKey(ValueKey<String>('showcase-category-$key'));
    Finder inCard(String key, Finder f) =>
        find.descendant(of: card(key), matching: f);

    Future<void> choose(
        WidgetTester tester, String catKey, String exerciseId) async {
      await tester.tap(
          find.byKey(ValueKey<String>('showcase-exercise-picker-$catKey')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(ValueKey<String>('showcase-option-$exerciseId')).last);
      await tester.pumpAndSettle();
    }

    for (final bool isOwner in <bool>[true, false]) {
      final String who = isOwner ? 'owner' : 'friend';

      testWidgets(
          '$who: each card defaults to the highest scorer, with its points',
          (WidgetTester tester) async {
        await pump(tester, goldenView(), isOwner: isOwner);
        expect(
            inCard('horizontalPress', find.text('Flat Bench Dumbbell Press')),
            findsOneWidget);
        expect(inCard('horizontalPress', find.text('78.01')), findsOneWidget);
        expect(inCard('verticalPull', find.text('Chin-Up')), findsOneWidget);
        expect(
            inCard('overheadPress',
                find.text('Overhead Dumbbell Press, Unilateral')),
            findsOneWidget);
        expect(inCard('hipHinge', find.text('Deadlift, Conventional')),
            findsOneWidget);
        expect(
            inCard('squatPattern', find.text('Bulgarian Split Squat, Barbell')),
            findsOneWidget);
        // Proof controls: the owner can add, a friend cannot.
        expect(find.text('ADD PROOF'), isOwner ? findsWidgets : findsNothing);
      });

      testWidgets(
          '$who: the dropdown changes only that card\'s displayed exercise',
          (WidgetTester tester) async {
        await pump(tester, goldenView(), isOwner: isOwner);
        await choose(tester, 'horizontalPress', kBench);
        expect(inCard('horizontalPress', find.text('Bench Press, Barbell')),
            findsOneWidget);
        // Best RE Points is the LIGHTER 95 kg set at 65 kg bodyweight, not the
        // 100 kg Best E1RM set: its own score, its own source line.
        expect(inCard('horizontalPress', find.text('73.47')), findsOneWidget);
        expect(inCard('horizontalPress', find.text('100 kg')), findsWidgets);
        expect(
            inCard('horizontalPress',
                find.textContaining('from 95 kg × 1 · 5 Feb 2026')),
            findsOneWidget);
        // Every other card is untouched.
        expect(inCard('verticalPull', find.text('Chin-Up')), findsOneWidget);
        expect(inCard('hipHinge', find.text('Deadlift, Conventional')),
            findsOneWidget);
      });

      testWidgets(
          '$who: loads show in the owner-chosen per-exercise unit; points never change',
          (WidgetTester tester) async {
        // The owner chose pounds for Bench Press and Chin-Up only. The same
        // published choice is what a friend's view is built from.
        final ShowcaseView view = ShowcaseView(
          showcase: ProfileShowcase.empty,
          showcaseV2: ProfileShowcaseV2.fromMap(golden),
          exerciseUnits: ExerciseUnits(
            published: ExerciseUnits.parsePublished(
                <String, Object?>{kBench: 'lb', kChin: 'lb'}),
          ),
        );
        await pump(tester, view, isOwner: isOwner);
        // Bodyweight-loaded: +20 kg added load shown as +44.1 lb.
        expect(inCard('verticalPull', find.textContaining('lb')), findsWidgets);
        expect(inCard('verticalPull', find.textContaining('+44.1 lb')),
            findsWidgets);
        expect(inCard('verticalPull', find.textContaining('kg')), findsNothing);
        expect(inCard('verticalPull', find.text('66.39')), findsOneWidget);
        // An exercise left in kilograms stays in kilograms.
        expect(inCard('hipHinge', find.textContaining(' kg')), findsWidgets);
        expect(inCard('hipHinge', find.textContaining(' lb')), findsNothing);

        await choose(tester, 'horizontalPress', kBench);
        expect(inCard('horizontalPress', find.text('220.5 lb')), findsWidgets);
        expect(
            inCard('horizontalPress',
                find.textContaining('from 209.4 lb × 1 · 5 Feb 2026')),
            findsOneWidget);
        expect(inCard('horizontalPress', find.text('73.47')), findsOneWidget,
            reason: 'RE Points are scored in kg whatever the display unit');
      });
    }

    testWidgets(
        'the choice is presentation state: reopening shows the default again',
        (WidgetTester tester) async {
      final ShowcaseView view = goldenView();
      await pump(tester, view, isOwner: true, key: const ValueKey<int>(1));
      await choose(tester, 'horizontalPress', kBench);
      expect(inCard('horizontalPress', find.text('Bench Press, Barbell')),
          findsOneWidget);
      // The underlying data still names the server's best.
      expect(view.categories.categories.first.defaultExerciseId, kDbBench);
      // Reopen: a fresh widget tree.
      await pump(tester, view, isOwner: true, key: const ValueKey<int>(2));
      expect(inCard('horizontalPress', find.text('Flat Bench Dumbbell Press')),
          findsOneWidget);
    });

    testWidgets(
        'a recorded lift without a bodyweight says points are unavailable',
        (WidgetTester tester) async {
      await pump(tester, goldenView(), isOwner: false);
      await choose(tester, 'hipHinge', kHipThrust);
      expect(
          inCard('hipHinge', find.text('Hip Thrust, Barbell')), findsOneWidget);
      expect(inCard('hipHinge', find.text('—')), findsOneWidget);
      expect(
          inCard('hipHinge', find.text('No bodyweight recorded for this lift')),
          findsOneWidget);
    });

    testWidgets('an untrained alternative says "No result yet"',
        (WidgetTester tester) async {
      await pump(tester, goldenView(), isOwner: true);
      await choose(tester, 'overheadPress', kOhpBb);
      expect(inCard('overheadPress', find.text('Overhead Barbell Press')),
          findsOneWidget);
      expect(
          inCard('overheadPress', find.text('No result yet.')), findsOneWidget);
      expect(inCard('overheadPress', find.text('ADD PROOF')), findsNothing);
    });

    testWidgets('the dropdown lists every option with its points or state',
        (WidgetTester tester) async {
      await pump(tester, goldenView(), isOwner: false);
      await tester.tap(find.byKey(
          const ValueKey<String>('showcase-exercise-picker-overheadPress')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('showcase-option-$kOhpDb')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('showcase-option-$kOhpBb')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('showcase-option-$kDip')),
          findsOneWidget);
      expect(find.text('No result yet'), findsOneWidget);
      expect(find.text('51.99 pts'), findsOneWidget);
      expect(find.text('38.77 pts'), findsOneWidget);
    });

    testWidgets(
        'Triceps Dip shows the added load at its bodyweight, like Chin-Up',
        (WidgetTester tester) async {
      await pump(tester, goldenView(), isOwner: false);
      await choose(tester, 'overheadPress', kDip);
      expect(
          inCard('overheadPress', find.text('at 80 kg BW')), findsNWidgets(2));
      await choose(tester, 'verticalPull', kLat);
      expect(inCard('verticalPull', find.text('Lat Pull Down, Supinated')),
          findsOneWidget);
      expect(inCard('verticalPull', find.textContaining('BW')), findsNothing);
    });

    testWidgets('V1 fallback: the V1 lifts, no dropdown, no points',
        (WidgetTester tester) async {
      await pump(tester, ShowcaseView(showcase: _v1()), isOwner: true);
      expect(find.text('Bench Press, Barbell'), findsOneWidget);
      expect(find.text('RE POINTS'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('No completed sets logged yet.'), findsNWidgets(4));
    });
  });
}
