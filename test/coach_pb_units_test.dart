// Coach Weekly Review PB lines in the ATHLETE's per-exercise unit. Events carry
// canonical kilograms; kilograms read exactly as before, pounds are converted
// only for display.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_weekly_review_screen.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';

const String _bench = 'AmfUWbF1DH3I7qPAdh5k';
const String _chin = 'XM9026peNIu0R8qh7UqY';

AthleteReview _review() {
  final r = AthleteReview(
    uid: 'athlete1',
    settings: const {'reportingEnabled': true},
    rosterName: 'Ann Athlete',
  );
  r.report = <String, dynamic>{
    'status': 'draft',
    'draftIfPrevNotCopied': 'x',
    'draftIfPrevCopied': 'x',
    'coverageStart': '2026-08-24',
    'coverageEnd': '2026-09-07',
    'workoutDates': const ['2026-09-01'],
    'events': <Map<String, dynamic>>[
      {
        'type': 'maxWeightPB',
        'dateKey': '2026-09-01',
        'exerciseId': _bench,
        'exerciseName': 'Bench Press, Barbell',
        'weightKg': 100,
        'prevWeightKg': 95,
        'reps': 1,
      },
      {
        'type': 'e1rmPB',
        'dateKey': '2026-09-01',
        'exerciseId': _bench,
        'exerciseName': 'Bench Press, Barbell',
        'e1rmKg': 110,
        'prevE1rmKg': 105,
      },
      {
        'type': 'maxWeightPB',
        'dateKey': '2026-09-01',
        'exerciseId': _chin,
        'exerciseName': 'Chin-Up',
        'weightKg': 100,
        'prevWeightKg': 95,
        'bodyweightKg': 80,
        'reps': 1,
      },
    ],
  };
  return r;
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: CoachAthleteReviewCard(
          review: _review(),
          currentKey: '2026-09-07',
          adherence: null,
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
  await tester.pump();
}

void main() {
  setUp(() => ExerciseUnitRegistry.shared = ExerciseUnitRegistry());

  testWidgets('kilograms (the default) read exactly as before', (tester) async {
    await _pump(tester);
    expect(find.textContaining('all-time heaviest 100kg × 1'), findsOneWidget);
    expect(find.textContaining('(prev 95kg)'), findsOneWidget);
    expect(find.textContaining('110.0kg'), findsOneWidget);
    expect(find.textContaining('all-time heaviest +20kg × 1'), findsOneWidget);
    expect(find.textContaining('(prev 95kg total)'), findsOneWidget);
  });

  testWidgets('pounds: heaviest, E1RM and bodyweight-loaded PBs convert',
      (tester) async {
    ExerciseUnitRegistry.shared.seedPublished(
        'athlete1', <String, Object?>{_bench: 'lb', _chin: 'lb'});
    await _pump(tester);
    expect(
        find.textContaining('all-time heaviest 220.5lb × 1'), findsOneWidget);
    expect(find.textContaining('(prev 209.4lb)'), findsOneWidget);
    expect(find.textContaining('242.5lb'), findsOneWidget); // 110 kg E1RM
    expect(find.textContaining('(prev 231.5lb'), findsOneWidget); // 105 kg
    // +20 kg added over bodyweight → +44.1 lb; the previous is a total.
    expect(
        find.textContaining('all-time heaviest +44.1lb × 1'), findsOneWidget);
    expect(find.textContaining('(prev 209.4lb total)'), findsOneWidget);
  });

  testWidgets('one exercise in lb leaves the other in kg', (tester) async {
    ExerciseUnitRegistry.shared
        .seedPublished('athlete1', <String, Object?>{_chin: 'lb'});
    await _pump(tester);
    expect(find.textContaining('all-time heaviest 100kg × 1'), findsOneWidget);
    expect(
        find.textContaining('all-time heaviest +44.1lb × 1'), findsOneWidget);
  });
}
