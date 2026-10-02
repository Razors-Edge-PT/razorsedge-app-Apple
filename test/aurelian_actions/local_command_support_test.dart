// GoodLift's side of Aurelian's local command layer: athlete matching by
// e-mail / username / full name with strict ambiguity, the shared Coach
// Dashboard search, "which exercise?" instead of a silent default, the next
// set, set read-back, and catalogue matching order.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart' show Wes2FieldKey;
import 'package:localtest222/athlete_search.dart';
import 'package:localtest222/aurelian/actions/action_ports.dart';
import 'package:localtest222/aurelian/actions/action_service.dart';
import 'package:localtest222/aurelian/actions/athlete_match.dart';
import 'package:localtest222/aurelian/actions/exercise_resolution.dart';

import 'fakes.dart';

const List<AthleteCandidate> _roster = <AthleteCandidate>[
  AthleteCandidate(uid: 'coach', username: 'richard', isSelf: true),
  AthleteCandidate(
      uid: 'mh',
      username: 'Helpzie',
      fullName: 'Michael Helps',
      email: 'chicken_911@gmail.com'),
  AthleteCandidate(
      uid: 'ms',
      username: 'mike_s',
      fullName: 'Michael Smith',
      email: 'ms@example.com'),
  AthleteCandidate(
      uid: 'jd',
      username: 'jdoe',
      fullName: 'Jane Doe',
      email: 'jane9113@gmail.com'),
];

String? pick(String spoken, {List<AthleteCandidate> roster = _roster}) =>
    matchAthlete(spoken, roster).chosen?.uid;

void main() {
  group('athlete matching priority', () {
    test('e-mail, username and full name each select exactly one athlete', () {
      expect(pick('Michael Helps'), 'mh');
      expect(pick('michael  helps'), 'mh');
      expect(pick('Helpzie'), 'mh');
      expect(pick('helpzie'), 'mh');
      expect(pick('chicken_911@gmail.com'), 'mh');
      // The same address said without its underscore.
      expect(pick('chicken911@gmail.com'), 'mh');
      // An address with extra digits, uniquely.
      expect(pick('jane911@gmail.com'), 'jd');
      expect(pick('Jane Doe'), 'jd');
    });

    test('a first name shared by two athletes is asked about, nobody selected',
        () {
      final AthleteMatch m = matchAthlete('Michael', _roster);
      expect(m.chosen, isNull);
      expect(m.ask.map((AthleteCandidate c) => c.uid),
          unorderedEquals(<String>['mh', 'ms']));
      expect(
          athleteLabels(m.ask).keys,
          unorderedEquals(
              <String>['Michael Helps (Helpzie)', 'Michael Smith (mike_s)']));
      // The answer may be either name in the label.
      expect(
          matchAthlete('Michael', _roster,
              choices: <String>['Michael Helps (Helpzie)']).chosen?.uid,
          'mh');
    });

    test('a unique first name is enough', () {
      final List<AthleteCandidate> one =
          _roster.where((AthleteCandidate c) => c.uid != 'ms').toList();
      expect(pick('Michael', roster: one), 'mh');
    });

    test('a near spelling is only ever asked about, never selected', () {
      final AthleteMatch m = matchAthlete('Helpsie', _roster);
      expect(m.chosen, isNull);
      expect(m.ask.single.uid, 'mh');
      expect(
          matchAthlete('Helpsie', _roster,
              choices: <String>['Michael Helps (Helpzie)']).chosen?.uid,
          'mh');
    });

    test('a weak or unknown reference selects nobody', () {
      expect(matchAthlete('Zebedee', _roster).isNone, isTrue);
      expect(matchAthlete('mi', _roster).chosen, isNull);
      expect(matchAthlete('gmail', _roster).chosen, isNull);
    });
  });

  group('shared athlete search (Coach Dashboard and voice)', () {
    const AthleteSearchFields mh = AthleteSearchFields(
        username: 'Helpzie',
        fullName: 'Michael Helps',
        email: 'chicken_911@gmail.com');
    const AthleteSearchFields jd = AthleteSearchFields(
        username: 'jdoe', fullName: 'Jane Doe', email: 'jane9113@gmail.com');

    test('full name, username and e-mail, any case, spacing or punctuation',
        () {
      for (final String q in <String>[
        'Michael Helps',
        'michael helps',
        'MICHAEL   HELPS',
        'helpzie',
        'HELPZIE',
        'chicken_911@gmail.com',
        'chicken911',
        'chicken 911',
        'mic hel',
        'helps',
        'Michael',
      ]) {
        expect(athleteMatchesSearch(q, mh), isTrue, reason: q);
      }
      expect(athleteMatchesSearch('helpzie', jd), isFalse);
      expect(athleteMatchesSearch('', jd), isTrue, reason: 'empty finds all');
    });

    test('a near spelling is found by the search box', () {
      expect(athleteSearchScore('helpsie', mh), greaterThan(0));
      expect(athleteSearchScore('micheal', mh), greaterThan(0));
      expect(athleteSearchScore('zzzzzz', mh), 0);
    });

    test('exact beats prefix beats substring beats fuzzy', () {
      expect(athleteSearchScore('helpzie', mh),
          greaterThan(athleteSearchScore('help', mh)));
      expect(athleteSearchScore('help', mh),
          greaterThan(athleteSearchScore('elpzi', mh)));
      expect(athleteSearchScore('elpzi', mh),
          greaterThan(athleteSearchScore('helpsie', mh)));
    });
  });

  group('workout actions for the local planner', () {
    late FakeAthletes athletes;
    late FakeWorkout workout;
    late AurelianActionService service;

    Future<Map<String, dynamic>> run(
        String action, Map<String, Object?> payload) async {
      final String json = await service.handleJson(envelope(action, payload));
      return jsonDecode(json) as Map<String, dynamic>;
    }

    setUp(() {
      athletes = FakeAthletes();
      workout = FakeWorkout(rows: <FakeExercise>[
        FakeExercise('bench_bb', 'Bench Press, Barbell'),
        FakeExercise('squat_bb', 'Back Squat, Barbell', circuit: 1),
      ]);
      service = AurelianActionService()..athletePort = athletes;
      service.registerWorkout(workout);
    });

    test(
        'several exercises and none chosen: "which exercise?", never the first',
        () async {
      final r = await run(
          'set.update', <String, Object?>{'set': 1, 'weight': 150, 'reps': 5});
      expect(r['status'], 'ambiguous');
      expect(r['candidates'],
          <String>['Bench Press, Barbell', 'Back Squat, Barbell']);
      expect(workout.calls.where((String c) => c.startsWith('setFields')),
          isEmpty);
      final a = await run('set.update', <String, Object?>{
        'set': 1,
        'weight': 150,
        'reps': 5,
        'choices': <String>['Back Squat, Barbell'],
      });
      expect(a['status'], 'success');
      expect(workout.byId('squat_bb')!.values[0]![Wes2FieldKey.weight], 150.0);
    });

    test('the chosen exercise (inside its card, just added) is used', () async {
      workout.target = 'squat_bb';
      final r = await run('set.update', <String, Object?>{'set': 1, 'reps': 3});
      expect(r['status'], 'success');
      expect(workout.byId('squat_bb')!.values[0]![Wes2FieldKey.reps], 3);
    });

    test('a single exercise is inferred', () async {
      workout.rows.removeLast();
      final r = await run('set.update', <String, Object?>{'set': 1, 'reps': 3});
      expect(r['status'], 'success');
    });

    test('no set said: the next set without values; all full: a new set',
        () async {
      workout.target = 'bench_bb';
      workout.byId('bench_bb')!.values[0] = <Wes2FieldKey, Object>{
        Wes2FieldKey.weight: 100.0
      };
      final r = await run(
          'set.update', <String, Object?>{'weight': 150, 'reps': 5, 'rir': 2});
      expect(r['status'], 'success');
      expect((r['data'] as Map<String, dynamic>)['set'], 2);
      workout.byId('bench_bb')!.values[2] = <Wes2FieldKey, Object>{
        Wes2FieldKey.reps: 5
      };
      final full =
          await run('set.update', <String, Object?>{'weight': 150, 'reps': 5});
      expect((full['data'] as Map<String, dynamic>)['set'], 4);
      expect(workout.byId('bench_bb')!.setCount, 4);
      // Undo removes the set it added.
      final u =
          await run('undo', <String, Object?>{'undoToken': full['undoToken']});
      expect(u['status'], 'success');
      expect(workout.byId('bench_bb')!.setCount, 3);
    });

    test('the set after the last one is added; further is refused', () async {
      workout.target = 'bench_bb';
      final r =
          await run('set.update', <String, Object?>{'set': 4, 'weight': 150});
      expect(r['status'], 'success');
      expect(workout.byId('bench_bb')!.setCount, 4);
      final far =
          await run('set.update', <String, Object?>{'set': 9, 'weight': 150});
      expect(far['status'], 'invalid');
    });

    test('"same again for set four" copies into a new set', () async {
      workout.target = 'bench_bb';
      workout.byId('bench_bb')!.values[0] = <Wes2FieldKey, Object>{
        Wes2FieldKey.weight: 150.0,
        Wes2FieldKey.reps: 5
      };
      final r = await run('set.copy', <String, Object?>{'set': 1, 'toSet': 4});
      expect(r['status'], 'success');
      expect(workout.byId('bench_bb')!.setCount, 4);
      expect(workout.byId('bench_bb')!.values[3]![Wes2FieldKey.weight], 150.0);
    });

    test('set read-back: one exercise, one set, and the timers', () async {
      workout.byId('bench_bb')!.values[0] = <Wes2FieldKey, Object>{
        Wes2FieldKey.weight: 150.0,
        Wes2FieldKey.reps: 5,
        Wes2FieldKey.rir: 2.0,
      };
      final r =
          await run('workout.read', <String, Object?>{'exercise': 'bench'});
      expect(r['status'], 'success');
      final data = r['data'] as Map<String, dynamic>;
      expect(data['exercise'], 'Bench Press, Barbell');
      expect(data['unit'], 'kg');
      expect((data['sets'] as List<dynamic>).first,
          <String, dynamic>{'set': 1, 'weight': 150.0, 'reps': 5, 'rir': 2.0});
      expect((data['sets'] as List<dynamic>).length, 3);
      final one = await run(
          'workout.read', <String, Object?>{'exercise': 'bench', 'set': 1});
      expect(
          ((one['data'] as Map<String, dynamic>)['sets'] as List<dynamic>)
              .length,
          1);
      workout.generalRunning = true;
      workout.generalElapsed = 754000;
      final t = await run('workout.read', <String, Object?>{});
      expect((t['data'] as Map<String, dynamic>)['timer'], 'running');
      expect((t['data'] as Map<String, dynamic>)['timerSeconds'], 754);
    });

    test(
        'the current exercise can be moved, replaced or deleted without naming it',
        () async {
      workout.target = 'squat_bb';
      final r = await run('exercise.move', <String, Object?>{'circuit': 1});
      expect(r['status'], 'success');
      expect(workout.byId('squat_bb')!.circuit, 0);
    });
  });

  group('catalogue matching order', () {
    final List<CatalogueEntry> catalogue = <CatalogueEntry>[
      const CatalogueEntry(id: 'bench_bb', name: 'Bench Press, Barbell'),
      const CatalogueEntry(
          id: 'bench_narrow', name: 'Bench Press, Narrow Grip'),
      const CatalogueEntry(id: 'squat_bb', name: 'Back Squat, Barbell'),
      const CatalogueEntry(id: 'squat_low', name: 'Back Squat, Low bar'),
      const CatalogueEntry(id: 'lpd_wide', name: 'Lat Pull Down, Wide Arm '),
      const CatalogueEntry(id: 'lpd_sup', name: 'Lat Pull Down, Supinated'),
      const CatalogueEntry(id: 'bss', name: 'Bulgarian Split Squat'),
      const CatalogueEntry(
          id: 'bss_def', name: 'Bulgarian Split Squat, Deficit'),
      const CatalogueEntry(id: 'larsen', name: 'Bench Press, Larsen Press'),
    ];

    String? resolve(String spoken,
        {Set<String> inWorkout = const <String>{},
        Map<String, int> usage = const <String, int>{},
        bool fuzzy = true}) {
      final ExerciseResolution<CatalogueEntry> r =
          resolveExercise<CatalogueEntry>(
        spoken,
        catalogue,
        nameOf: (CatalogueEntry c) => c.name,
        idOf: (CatalogueEntry c) => c.id,
        inWorkout: inWorkout,
        usage: usage,
        allowFuzzy: fuzzy,
        useHistory: fuzzy,
      );
      return r.chosen?.id ?? (r.isAmbiguous ? 'ask' : null);
    }

    test('exact, alias, then the usual variant', () {
      expect(resolve('Bench Press, Barbell'), 'bench_bb');
      expect(resolve('bench'), 'bench_bb');
      expect(resolve('back squat'), 'squat_bb');
      expect(resolve('squats'), 'squat_bb');
      expect(resolve('pulldowns'), 'lpd_wide');
      expect(resolve('bulgarian'), 'bss');
      expect(resolve('larson'), 'larsen');
    });

    test('the open workout beats history, which beats the usual variant', () {
      expect(resolve('pulldowns', inWorkout: <String>{'lpd_sup'}), 'lpd_sup');
      expect(resolve('bulgarian', usage: <String, int>{'bss_def': 8, 'bss': 1}),
          'bss_def');
      expect(
          resolve('bulgarian',
              inWorkout: <String>{'bss'}, usage: <String, int>{'bss_def': 8}),
          'bss');
    });

    test('close spellings are found word by word; destructive never guesses',
        () {
      expect(resolve('bulgarain split squat'), 'bss');
      expect(resolve('bulgarain split squat', fuzzy: false), isNull);
      expect(resolve('pulldowns', fuzzy: false), 'ask');
    });
  });
}
