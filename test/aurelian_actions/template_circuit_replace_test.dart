// Template loading by day, circuit semantics (circuits exist only through
// their exercises: existing or next consecutive circuit only) and replacing an
// exercise - the GoodLift side of Aurelian's local commands.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart' show Wes2FieldKey;
import 'package:localtest222/aurelian/actions/action_ports.dart';
import 'package:localtest222/aurelian/actions/action_service.dart';

import 'fakes.dart';

void main() {
  late FakeWorkout workout;
  late AurelianActionService service;

  Future<Map<String, dynamic>> run(String action, Map<String, Object?> payload,
      {String? token}) async {
    final String json = await service
        .handleJson(envelope(action, payload, confirmationToken: token));
    return jsonDecode(json) as Map<String, dynamic>;
  }

  setUp(() {
    workout = FakeWorkout(rows: <FakeExercise>[
      FakeExercise('bench_bb', 'Bench Press, Barbell'),
      FakeExercise('squat_bb', 'Back Squat, Barbell'),
    ]);
    service = AurelianActionService()..athletePort = FakeAthletes();
    service.registerWorkout(workout);
  });

  group('templates by day', () {
    setUp(() {
      workout.rows.clear();
      for (final String id in <String>['t1', 't2', 't3', 't4', 'old']) {
        workout.templateRows[id] =
            () => <FakeExercise>[FakeExercise('x_$id', 'Exercise $id')];
      }
    });

    test('day metadata or name, any form Aurelian sends, active block first',
        () async {
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(id: 'old', name: 'Upper', day: 'Day 1'),
        TemplateEntry(
            id: 't1', name: 'Upper', day: 'Day 1', inActiveBlock: true),
        TemplateEntry(
            id: 't2', name: 'Lower', day: 'Day 2', inActiveBlock: true),
      ];
      for (final String said in <String>['day 1', 'Day 1', 'the day 1']) {
        workout.rows.clear();
        final r =
            await run('template.load', <String, Object?>{'template': said});
        expect(r['summary'], 'Upper loaded · 1 exercises', reason: said);
        expect(workout.calls.last, 'loadTemplate:t1');
      }
    });

    test('a template whose name says the day is found too', () async {
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(id: 't1', name: 'Day 1 Upper', inActiveBlock: true),
        TemplateEntry(id: 't2', name: 'Day 2 Lower', inActiveBlock: true),
      ];
      final r =
          await run('template.load', <String, Object?>{'template': 'day 2'});
      expect(r['summary'], 'Day 2 Lower loaded · 1 exercises');
    });

    test('no template for that day is reported clearly', () async {
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(
            id: 't1', name: 'Upper', day: 'Day 1', inActiveBlock: true),
      ];
      final r =
          await run('template.load', <String, Object?>{'template': 'day 3'});
      expect(r['status'], 'not_found');
      expect(r['summary'], 'No template is set for day 3');
      expect(workout.calls.where((String c) => c.startsWith('loadTemplate')),
          isEmpty);
    });

    test(
        'several matches are offered by their visible names; an answer by name loads one',
        () async {
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(
            id: 't1', name: 'Lower A', day: 'Day 2', inActiveBlock: true),
        TemplateEntry(
            id: 't2', name: 'Lower B', day: 'Day 2', inActiveBlock: true),
      ];
      final r =
          await run('template.load', <String, Object?>{'template': 'day 2'});
      expect(r['status'], 'ambiguous');
      expect(r['candidates'], <String>['Lower A', 'Lower B']);
      expect(r.toString(), isNot(contains('t1')), reason: 'never internal ids');
      final ok = await run('template.load', <String, Object?>{
        'template': 'day 2',
        'choices': <String>['lower b'],
      });
      expect(ok['status'], 'success');
      expect(workout.calls.last, 'loadTemplate:t2');
    });

    test(
        'identical visible names get only the smallest distinction, never a silent pick',
        () async {
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(
            id: 't1', name: 'Lower', day: 'Day 2', inActiveBlock: true),
        TemplateEntry(
            id: 't2', name: 'Lower', day: 'Week 2 Day 2', inActiveBlock: true),
      ];
      final r =
          await run('template.load', <String, Object?>{'template': 'day 2'});
      expect(r['status'], 'ambiguous');
      expect(
          r['candidates'], <String>['Lower (Day 2)', 'Lower (Week 2 Day 2)']);
      final again = await run('template.load', <String, Object?>{
        'template': 'day 2',
        'choices': <String>['Lower'],
      });
      expect(again['status'], 'ambiguous', reason: '"Lower" fits both');
      final ok = await run('template.load', <String, Object?>{
        'template': 'day 2',
        'choices': <String>['Lower (Week 2 Day 2)'],
      });
      expect(ok['status'], 'success');
      expect(workout.calls.last, 'loadTemplate:t2');
    });

    test(
        'loading over logged data still needs confirmation; undo still works on an empty day',
        () async {
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(
            id: 't2', name: 'Lower', day: 'Day 2', inActiveBlock: true),
      ];
      final r =
          await run('template.load', <String, Object?>{'template': 'day 2'});
      expect(r['status'], 'success');
      final u =
          await run('undo', <String, Object?>{'undoToken': r['undoToken']});
      expect(u['status'], 'success');
      expect(workout.rows, isEmpty);

      workout.rows.add(FakeExercise('bench_bb', 'Bench Press, Barbell')
        ..values[0] = <Wes2FieldKey, Object>{Wes2FieldKey.reps: 5});
      final ask =
          await run('template.load', <String, Object?>{'template': 'day 2'});
      expect(ask['status'], 'requires_confirmation');
      expect(
          workout.calls.where((String c) => c == 'loadTemplate:t2').length, 1);
    });
  });

  group('circuits exist through their exercises', () {
    test('add: existing circuit or the next one; skipping is refused',
        () async {
      final r = await run(
          'exercise.add', <String, Object?>{'exercise': 'Plank', 'circuit': 2});
      expect(r['status'], 'success');
      expect(workout.byId('plank')!.circuit, 1);
      final skip = await run('exercise.add',
          <String, Object?>{'exercise': 'Side Plank', 'circuit': 4});
      expect(skip['status'], 'invalid');
      expect(skip['summary'], contains('next new one is circuit 3'));
    });

    test(
        'move: to the next circuit creates it; skipping is refused; undo is guarded',
        () async {
      final r = await run('exercise.move',
          <String, Object?>{'exercise': 'bench press', 'circuit': 2});
      expect(r['status'], 'success');
      expect(workout.byId('bench_bb')!.circuit, 1);
      final skip = await run('exercise.move',
          <String, Object?>{'exercise': 'back squat', 'circuit': 4});
      expect(skip['status'], 'invalid');
      expect(workout.byId('squat_bb')!.circuit, 0);
      // An intervening move makes the undo unsafe: refused.
      workout.byId('bench_bb')!.circuit = 0;
      final u =
          await run('undo', <String, Object?>{'undoToken': r['undoToken']});
      expect(u['status'], 'conflict');
    });

    test('move undo returns the exercise to its previous circuit', () async {
      final r = await run('exercise.move',
          <String, Object?>{'exercise': 'bench press', 'circuit': 2});
      final u =
          await run('undo', <String, Object?>{'undoToken': r['undoToken']});
      expect(u['status'], 'success');
      expect(workout.byId('bench_bb')!.circuit, 0);
    });

    test('the current exercise moves without being named; none chosen asks',
        () async {
      final ask = await run('exercise.move', <String, Object?>{'circuit': 2});
      expect(ask['status'], 'ambiguous');
      workout.target = 'squat_bb';
      final ok = await run('exercise.move', <String, Object?>{'circuit': 2});
      expect(ok['status'], 'success');
      expect(workout.byId('squat_bb')!.circuit, 1);
    });

    test('circuits are numbered, not named', () async {
      final r = await run('circuit.rename',
          <String, Object?>{'circuit': 1, 'name': 'accessories'});
      expect(r['status'], 'unsupported');
    });
  });

  group('replace', () {
    test('this exercise: the chosen one; none chosen among several: ask',
        () async {
      final ask = await run('exercise.replace',
          <String, Object?>{'replacement': 'Larsen Bench Press'});
      expect(ask['status'], 'ambiguous');
      expect(workout.calls.where((String c) => c.startsWith('replaceExercise')),
          isEmpty);
      workout.target = 'bench_bb';
      final ok = await run(
          'exercise.replace', <String, Object?>{'replacement': 'Larson press'});
      expect(ok['status'], 'success');
      expect(ok['summary'],
          'Replaced Bench Press, Barbell with Bench Press, Larsen Press');
    });

    test('a named target is never fuzzy: a misheard name replaces nothing',
        () async {
      final r = await run('exercise.replace',
          <String, Object?>{'exercise': 'bunch pass', 'replacement': 'Plank'});
      expect(r['status'], 'not_found');
      expect(workout.calls.where((String c) => c.startsWith('replaceExercise')),
          isEmpty);
    });

    test('logged data needs confirmation; undo restores the original',
        () async {
      workout.byId('bench_bb')!.values[0] = <Wes2FieldKey, Object>{
        Wes2FieldKey.reps: 5
      };
      final ask = await run('exercise.replace', <String, Object?>{
        'exercise': 'bench press',
        'replacement': 'Larson press'
      });
      expect(ask['status'], 'requires_confirmation');
      final ok = await run(
          'exercise.replace',
          <String, Object?>{
            'exercise': 'bench press',
            'replacement': 'Larson press'
          },
          token: ask['confirmationToken'] as String);
      expect(ok['status'], 'success');
      expect(workout.byId('bench_larsen'), isNotNull);
    });
  });
}
