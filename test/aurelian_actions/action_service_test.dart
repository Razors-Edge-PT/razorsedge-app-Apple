// Aurelian 2.0 — the GoodLift action service, end to end over fake ports:
// envelope validation, authentication and coach authorisation, athlete and
// exercise resolution, set/circuit/timer actions, confirmations, idempotent
// retries, read-back verification and safe undo.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart' show Wes2FieldKey;
import 'package:localtest222/aurelian/actions/action_envelope.dart';
import 'package:localtest222/aurelian/actions/action_ports.dart';
import 'package:localtest222/aurelian/actions/action_result.dart';
import 'package:localtest222/aurelian/actions/action_service.dart';
import 'package:localtest222/aurelian/actions/athlete_match.dart';
import 'package:localtest222/units/weight_unit.dart';

import 'fakes.dart';

void main() {
  late FakeAthletes athletes;
  late FakeWorkout workout;
  late AurelianActionService service;

  FakeExercise bench() => FakeExercise('bench_bb', 'Bench Press, Barbell');

  setUp(() {
    athletes = FakeAthletes();
    workout = FakeWorkout(rows: <FakeExercise>[bench()]);
    service = AurelianActionService(now: () => DateTime(2026, 10, 1, 9));
    service.athletePort = athletes;
    service.registerWorkout(workout);
  });

  Future<Map<String, dynamic>> run(String action, Map<String, Object?> payload,
      {String? key, String? token}) async {
    final String out = await service.handleJson(
        envelope(action, payload, key: key, confirmationToken: token));
    return jsonDecode(out) as Map<String, dynamic>;
  }

  group('envelope validation', () {
    test('accepts a well-formed envelope', () {
      final r = parseActionEnvelope(envelope(
          'set.update', <String, Object?>{'set': 1, 'weight': 150, 'reps': 5}));
      expect(r.error, isNull);
      expect(r.envelope!.action, AurelianAction.setUpdate);
      expect(r.envelope!.payload.number('weight'), 150.0);
    });

    test('refuses unknown actions, unexpected arguments and bad types', () {
      expect(
          parseActionEnvelope(envelope('firestore.write', <String, Object?>{}))
              .error!
              .message,
          'Unknown action');
      expect(
          parseActionEnvelope(envelope('set.update', <String, Object?>{
            'set': 1,
            'reps': 5,
            'uid': 'x'
          })).error!.message,
          contains('Unexpected argument'));
      expect(
          parseActionEnvelope(envelope(
              'set.update', <String, Object?>{'set': '1', 'reps': 5})).error,
          isNotNull);
      expect(
          parseActionEnvelope(
                  envelope('set.update', <String, Object?>{'set': 1}))
              .error!
              .message,
          'No set value given');
      expect(
          parseActionEnvelope(envelope('set.update', <String, Object?>{
            'set': 1,
            'unit': 'kg',
            'reps': 5
          })).error!.message,
          'A unit needs a weight');
      expect(
          parseActionEnvelope(envelope(
              'set.update', <String, Object?>{'set': 0, 'reps': 5})).error,
          isNotNull);
      expect(
          parseActionEnvelope(envelope(
              'set.update', <String, Object?>{'set': 1, 'rir': 11})).error,
          isNotNull);
      expect(
          parseActionEnvelope(envelope(
                  'exercise.move', <String, Object?>{'exercise': 'bench'}))
              .error!
              .message,
          'Missing argument "circuit"');
      expect(
          parseActionEnvelope(envelope(
              'workout.open', <String, Object?>{'date': '2026-02-31'})).error,
          isNotNull);
    });

    test(
        'refuses oversized envelopes, other schema versions and extra top-level fields',
        () {
      final String big =
          envelope('exercise.note', <String, Object?>{'text': 'x' * 5000});
      expect(parseActionEnvelope(big).error!.message, 'Envelope too large');
      final Map<String, dynamic> v2 =
          jsonDecode(envelope('workout.read', <String, Object?>{}))
              as Map<String, dynamic>
            ..['schemaVersion'] = 2;
      expect(parseActionEnvelope(jsonEncode(v2)).error!.message,
          contains('schema version'));
      final Map<String, dynamic> extra =
          jsonDecode(envelope('workout.read', <String, Object?>{}))
              as Map<String, dynamic>
            ..['code'] = 'rm -rf';
      expect(parseActionEnvelope(jsonEncode(extra)).error!.message,
          'Unexpected envelope field');
    });

    test('a refused envelope still answers with a well-formed result',
        () async {
      final String out =
          await service.handleJson('{"requestId":"r1","action":"nope"}');
      final Map<String, dynamic> m = jsonDecode(out) as Map<String, dynamic>;
      expect(m['status'], 'invalid');
      expect(m['requestId'], 'r1');
    });
  });

  group('authentication and coach authorisation', () {
    test('signed out: unauthorized, nothing runs', () async {
      athletes.actor = null;
      final r = await run('set.update', <String, Object?>{'set': 1, 'reps': 5});
      expect(r['status'], 'unauthorized');
      expect(workout.calls, isEmpty);
    });

    test('acting for an athlete no longer on the roster is refused', () async {
      athletes.acting = 'ruby';
      athletes.roster = athletes.roster
          .where((AthleteCandidate c) => c.uid != 'ruby')
          .toList();
      final r = await run('set.update', <String, Object?>{'set': 1, 'reps': 5});
      expect(r['status'], 'unauthorized');
      expect(workout.calls, isEmpty);
    });

    test('an athlete account cannot switch athlete', () async {
      athletes.hasCoachMode = false;
      final r =
          await run('athlete.switch', <String, Object?>{'query': 'Ruby Cakes'});
      expect(r['status'], 'unauthorized');
      expect(athletes.switches, isEmpty);
    });

    test('the open workout must belong to the session athlete', () async {
      athletes.acting = 'ruby';
      final r = await run('set.update', <String, Object?>{'set': 1, 'reps': 5});
      expect(r['status'], 'conflict');
    });
  });

  group('athlete matching', () {
    String? pick(String spoken) =>
        matchAthlete(spoken, athletes.roster).chosen?.uid;

    test(
        'full name, username, honorific + surname, business name, digits omitted',
        () {
      expect(pick('Ruby Cakes'), 'ruby');
      expect(pick('rubycakes'), 'ruby');
      expect(pick('Mr Walker'), 'walker');
      expect(pick('Coded NZ'), 'coded');
      expect(pick('codednz'), 'coded');
      expect(pick('ruby@example.com'), 'ruby');
      expect(pick('r u b y cakes'), 'ruby');
      expect(pick('me'), 'coach');
    });

    test(
        'two credible matches are asked about; nothing confident is never guessed',
        () {
      final AthleteMatch sean = matchAthlete('Sean', athletes.roster);
      expect(sean.isAmbiguous, isTrue);
      expect(sean.ask.map((AthleteCandidate c) => c.uid),
          unorderedEquals(<String>['sean1', 'sean2']));
      expect(matchAthlete('Zebedee', athletes.roster).isNone, isTrue);
      expect(
          matchAthlete('Sean', athletes.roster, choices: <String>['seanw'])
              .chosen
              ?.uid,
          'sean2');
    });
  });

  group('athlete switching', () {
    test('switches, reads back, and undo returns to the previous athlete',
        () async {
      final r =
          await run('athlete.switch', <String, Object?>{'query': 'Ruby Cakes'});
      expect(r['status'], 'success');
      expect(r['verified'], isTrue);
      expect(r['summary'], startsWith('Switched to Ruby Cakes (rubycakes)'));
      expect(r.toString(), isNot(contains('ruby@')),
          reason: 'no identifiers beyond the label');
      expect(athletes.acting, 'ruby');
      final u =
          await run('undo', <String, Object?>{'undoToken': r['undoToken']});
      expect(u['status'], 'success');
      expect(athletes.acting, 'coach');
    });

    test('ambiguity returns candidates and switches nothing', () async {
      final r = await run('athlete.switch', <String, Object?>{'query': 'Sean'});
      expect(r['status'], 'ambiguous');
      expect((r['candidates'] as List<dynamic>).length, 2);
      expect(athletes.switches, isEmpty);
    });

    test('a switch that does not take is a failure, not a success', () async {
      athletes.ignoreSwitch = true;
      final r =
          await run('athlete.switch', <String, Object?>{'query': 'Ruby Cakes'});
      expect(r['status'], 'failure');
    });

    test('undo after a manual switch elsewhere is refused', () async {
      final r =
          await run('athlete.switch', <String, Object?>{'query': 'Ruby Cakes'});
      athletes.acting = 'walker';
      final u =
          await run('undo', <String, Object?>{'undoToken': r['undoToken']});
      expect(u['status'], 'conflict');
      expect(athletes.acting, 'walker');
    });
  });

  group('exercise resolution', () {
    test(
        '"bench press" adds the normal barbell bench; "dumbbell bench" the flat DB press',
        () async {
      workout.rows.clear();
      final r = await run(
          'exercise.add', <String, Object?>{'exercise': 'bench press'});
      expect(r['status'], 'success');
      expect(workout.calls.last, 'addExercise:bench_bb:0');
      final d = await run(
          'exercise.add', <String, Object?>{'exercise': 'dumbbell bench'});
      expect(d['summary'], 'Added Flat Bench Dumbbell Press to circuit 1');
    });

    test(
        '"Larson press" adds the usual Larsen bench; history or an answer picks the other',
        () async {
      workout.rows.clear();
      final r = await run(
          'exercise.add', <String, Object?>{'exercise': 'Larson press'});
      expect(r['status'], 'success');
      expect(workout.byId('bench_larsen'), isNotNull);
      expect((r['data'] as Map<String, dynamic>)['matched'],
          contains('alias default'));
      workout.rows.clear();
      workout.usage = <String, int>{'larsen_bench': 6, 'bench_larsen': 1};
      await run('exercise.add', <String, Object?>{'exercise': 'larsen'});
      expect(workout.byId('larsen_bench'), isNotNull, reason: 'history');
      workout.rows.clear();
      workout.usage = <String, int>{};
      final c = await run('exercise.add', <String, Object?>{
        'exercise': 'Larson press',
        'choices': <String>['Larsen Bench Press'],
      });
      expect(c['status'], 'success');
      expect(workout.byId('larsen_bench'), isNotNull);
    });

    test('a destructive action never takes an alias default: it asks',
        () async {
      workout.rows
        ..clear()
        ..add(FakeExercise('bench_larsen', 'Bench Press, Larsen Press'))
        ..add(FakeExercise('larsen_bench', 'Larsen Bench Press'));
      final r =
          await run('exercise.delete', <String, Object?>{'exercise': 'larsen'});
      expect(r['status'], 'ambiguous');
      expect(workout.rows.length, 2);
    });

    test('history narrows a broad name only for a clear favourite', () async {
      final r = await run(
          'exercise.add', <String, Object?>{'exercise': 'overhead dumbbell'});
      expect(r['status'], 'ambiguous');
      workout.usage = <String, int>{'ohp_db': 6, 'ohp_db_uni': 1};
      final h = await run(
          'exercise.add', <String, Object?>{'exercise': 'overhead dumbbell'});
      expect(h['summary'], 'Added Overhead Dumbbell Press to circuit 1');
    });

    test('a misheard name never deletes a different exercise', () async {
      final r = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench prss'});
      expect(r['status'], 'not_found');
      expect(workout.byId('bench_bb'), isNotNull);
    });
  });

  group('circuits', () {
    test('adds directly to the next new circuit, refuses one that skips ahead',
        () async {
      final r = await run('exercise.add',
          <String, Object?>{'exercise': 'back squat', 'circuit': 2});
      expect(r['summary'], 'Added Back Squat, Barbell to circuit 2');
      final bad = await run(
          'exercise.add', <String, Object?>{'exercise': 'plank', 'circuit': 5});
      expect(bad['status'], 'invalid');
    });

    test('moves an exercise and undoes the move', () async {
      await run('exercise.add',
          <String, Object?>{'exercise': 'back squat', 'circuit': 2});
      final m = await run('exercise.move',
          <String, Object?>{'exercise': 'bench press', 'circuit': 2});
      expect(m['summary'], 'Bench Press, Barbell moved to circuit 2');
      expect(workout.byId('bench_bb')!.circuit, 1);
      final u =
          await run('undo', <String, Object?>{'undoToken': m['undoToken']});
      expect(u['status'], 'success');
      expect(workout.byId('bench_bb')!.circuit, 0);
    });

    test(
        'renaming is unsupported; deleting a populated circuit needs confirmation',
        () async {
      expect(
          (await run('circuit.rename',
              <String, Object?>{'circuit': 1, 'name': 'Push'}))['status'],
          'unsupported');
      workout.byId('bench_bb')!.values[0] = <Wes2FieldKey, Object>{
        Wes2FieldKey.reps: 5
      };
      final r = await run('circuit.delete', <String, Object?>{'circuit': 1});
      expect(r['status'], 'requires_confirmation');
      expect(workout.byId('bench_bb'), isNotNull);
      final ok = await run('circuit.delete', <String, Object?>{'circuit': 1},
          token: r['confirmationToken'] as String);
      expect(ok['status'], 'success');
      expect(workout.rows, isEmpty);
      final u =
          await run('undo', <String, Object?>{'undoToken': ok['undoToken']});
      expect(u['status'], 'success');
      expect(workout.byId('bench_bb')!.values[0]![Wes2FieldKey.reps], 5);
    });
  });

  group('set updates', () {
    test('combined weight, reps and RIR; never marks the exercise completed',
        () async {
      final r = await run('set.update', <String, Object?>{
        'exercise': 'bench',
        'set': 1,
        'weight': 150,
        'reps': 5,
        'rir': 1
      });
      expect(r['status'], 'success');
      expect(r['verified'], isTrue);
      expect((r['data'] as Map<String, dynamic>)['weight'], 150);
      expect(workout.byId('bench_bb')!.done, isFalse);
      expect(workout.calls.where((String c) => c.startsWith('setCompleted')),
          isEmpty);
    });

    test('partial velocity update leaves the other fields alone', () async {
      workout.byId('bench_bb')!.values[1] = <Wes2FieldKey, Object>{
        Wes2FieldKey.weight: 140.0,
        Wes2FieldKey.reps: 5
      };
      await run('set.update', <String, Object?>{
        'exercise': 'bench press',
        'set': 2,
        'velocity': 0.32
      });
      expect(workout.calls.last, 'setFields:bench_bb:1:velocity=0.32');
      expect(workout.byId('bench_bb')!.values[1], <Wes2FieldKey, Object>{
        Wes2FieldKey.weight: 140.0,
        Wes2FieldKey.reps: 5,
        Wes2FieldKey.velocity: 0.32,
      });
    });

    test("uses the exercise's configured unit unless one is said", () async {
      workout.rows
        ..clear()
        ..add(FakeExercise('bench_bb', 'Bench Press, Barbell',
            unit: ExerciseWeightUnit.lb));
      await run('set.update', <String, Object?>{'set': 1, 'weight': 225});
      final double kg =
          workout.byId('bench_bb')!.values[0]![Wes2FieldKey.weight]! as double;
      expect(kg, closeTo(102.058, 0.001));
      await run('set.update',
          <String, Object?>{'set': 2, 'weight': 100, 'unit': 'kg'});
      expect(workout.byId('bench_bb')!.values[1]![Wes2FieldKey.weight], 100.0);
    });

    test(
        '"make that 152.5" style correction is a new partial update, undo restores exactly',
        () async {
      final a = await run(
          'set.update', <String, Object?>{'set': 1, 'weight': 150, 'reps': 5});
      final b =
          await run('set.update', <String, Object?>{'set': 1, 'weight': 152.5});
      expect(workout.byId('bench_bb')!.values[0]![Wes2FieldKey.weight], 152.5);
      final u =
          await run('undo', <String, Object?>{'undoToken': b['undoToken']});
      expect(u['status'], 'success');
      expect(workout.byId('bench_bb')!.values[0]![Wes2FieldKey.weight], 150.0);
      expect(workout.byId('bench_bb')!.values[0]![Wes2FieldKey.reps], 5,
          reason: 'other fields untouched');
      expect(a['status'], 'success');
    });

    test('undo never overwrites a later manual edit', () async {
      final r =
          await run('set.update', <String, Object?>{'set': 1, 'weight': 150});
      workout.byId('bench_bb')!.values[0]![Wes2FieldKey.weight] =
          155.0; // typed by hand afterwards
      final u =
          await run('undo', <String, Object?>{'undoToken': r['undoToken']});
      expect(u['status'], 'conflict');
      expect(workout.byId('bench_bb')!.values[0]![Wes2FieldKey.weight], 155.0);
    });

    test('a set that does not exist is refused with guidance', () async {
      final r = await run('set.update', <String, Object?>{'set': 7, 'reps': 5});
      expect(r['status'], 'invalid');
      expect(r['summary'], contains('add set'));
    });

    test('read-back catches a write that did not land', () async {
      workout.dropWrites = true;
      final r = await run('set.update', <String, Object?>{'set': 1, 'reps': 5});
      expect(r['status'], 'failure');
      expect(r['undoToken'], isNull);
    });

    test('notes, add, copy, clear and delete set', () async {
      final n = await run('set.note', <String, Object?>{
        'exercise': 'bench press',
        'set': 3,
        'text': 'third rep velocity was 0.23'
      });
      expect(n['status'], 'success');
      expect(workout.byId('bench_bb')!.notes[2], 'third rep velocity was 0.23');
      await run(
          'set.update', <String, Object?>{'set': 2, 'weight': 100, 'reps': 8});
      final c = await run('set.copy', <String, Object?>{'set': 2});
      expect(c['summary'], 'Bench Press, Barbell · set 2 copied to new set 4');
      expect(workout.byId('bench_bb')!.setCount, 4);
      final cl = await run(
          'set.clear', <String, Object?>{'exercise': 'bench press', 'set': 4});
      expect(cl['status'], 'success');
      expect(workout.byId('bench_bb')!.values[3], isEmpty);
      final d = await run('set.delete', <String, Object?>{'set': 2});
      expect(d['status'], 'requires_confirmation',
          reason: 'set 2 holds logged values');
      final add = await run('set.add', <String, Object?>{});
      expect(add['summary'], 'Bench Press, Barbell · set 5 added');
    });
  });

  group('completion is explicit only', () {
    test('marks completed and incomplete; refuses before any set is logged',
        () async {
      expect(
          (await run('exercise.complete', <String, Object?>{
            'exercise': 'bench press',
            'completed': true
          }))['status'],
          'invalid');
      await run(
          'set.update', <String, Object?>{'set': 1, 'weight': 100, 'reps': 5});
      final r = await run('exercise.complete',
          <String, Object?>{'exercise': 'bench press', 'completed': true});
      expect(r['summary'], 'Bench Press, Barbell marked completed');
      expect(workout.byId('bench_bb')!.done, isTrue);
      final i = await run('exercise.complete',
          <String, Object?>{'exercise': 'bench press', 'completed': false});
      expect(i['summary'], 'Bench Press, Barbell marked not completed');
    });
  });

  group('deletion keeps the confirmation', () {
    test('an exercise without values is deleted directly', () async {
      final r = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench press'});
      expect(r['status'], 'success');
      expect(workout.rows, isEmpty);
    });

    test('a populated exercise needs a single-use token bound to the request',
        () async {
      workout.byId('bench_bb')!.values[0] = <Wes2FieldKey, Object>{
        Wes2FieldKey.weight: 100.0,
        Wes2FieldKey.reps: 5
      };
      final r = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench press'});
      expect(r['status'], 'requires_confirmation');
      expect(workout.calls.where((String c) => c.startsWith('deleteExercise')),
          isEmpty);
      final String token = r['confirmationToken'] as String;
      // A token never authorises a different request.
      final wrong = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench'},
          token: token);
      expect(wrong['status'], 'conflict');
      final again = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench press'});
      final ok = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench press'},
          token: again['confirmationToken'] as String);
      expect(ok['status'], 'success');
      expect(workout.rows, isEmpty);
      final reuse = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench press'},
          token: again['confirmationToken'] as String);
      expect(reuse['status'], 'conflict', reason: 'tokens are single-use');
      final u =
          await run('undo', <String, Object?>{'undoToken': ok['undoToken']});
      expect(u['status'], 'success');
      expect(workout.byId('bench_bb')!.values[0], <Wes2FieldKey, Object>{
        Wes2FieldKey.weight: 100.0,
        Wes2FieldKey.reps: 5
      });
    });

    test('confirmation tokens expire', () async {
      DateTime now = DateTime(2026, 10, 1, 9);
      service = AurelianActionService(now: () => now)
        ..athletePort = athletes
        ..registerWorkout(workout);
      workout.byId('bench_bb')!.values[0] = <Wes2FieldKey, Object>{
        Wes2FieldKey.reps: 5
      };
      final r = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench press'});
      now = now.add(const Duration(minutes: 2));
      final late = await run(
          'exercise.delete', <String, Object?>{'exercise': 'bench press'},
          token: r['confirmationToken'] as String);
      expect(late['status'], 'conflict');
      expect(workout.rows, isNotEmpty);
    });
  });

  group('timers', () {
    setUp(() => workout.rows.add(FakeExercise('plank', 'Plank', timed: true)));

    test('exercise set timer is distinct from the general workout timer',
        () async {
      final s = await run('timer.exercise.start',
          <String, Object?>{'exercise': 'plank', 'set': 1});
      expect(s['summary'], 'Plank · set 1 timer started');
      expect(workout.generalRunning, isFalse);
      final stop = await run(
          'timer.exercise.stop', <String, Object?>{'exercise': 'plank'});
      expect(stop['summary'], 'Plank · set 1 timer stopped at 0:45');
      expect(workout.byId('plank')!.values[0]![Wes2FieldKey.reps], 45);
      final g = await run('timer.general.start', <String, Object?>{});
      expect(g['summary'], 'Workout timer started');
      expect(workout.setTimer, isNull);
      final gs = await run('timer.general.stop', <String, Object?>{});
      expect(gs['summary'], 'Workout timer stopped at 1:01');
    });

    test(
        'a non-timed exercise cannot start a set timer; stop with none running is refused',
        () async {
      expect(
          (await run('timer.exercise.start', <String, Object?>{
            'exercise': 'bench press',
            'set': 1
          }))['status'],
          'invalid');
      expect((await run('timer.exercise.stop', <String, Object?>{}))['status'],
          'invalid');
    });

    test('undo of a set-timer start cancels without saving a time', () async {
      final s = await run('timer.exercise.start',
          <String, Object?>{'exercise': 'plank', 'set': 1});
      final u =
          await run('undo', <String, Object?>{'undoToken': s['undoToken']});
      expect(u['status'], 'success');
      expect(workout.calls.last, 'cancelSetTimer');
      expect(workout.byId('plank')!.values, isEmpty);
    });
  });

  group('idempotency', () {
    test('a retried request runs once and returns the same result', () async {
      final a = await run('set.add', <String, Object?>{}, key: 'retry-key-1');
      final b = await run('set.add', <String, Object?>{}, key: 'retry-key-1');
      expect(workout.calls.where((String c) => c.startsWith('addSet')),
          hasLength(1));
      expect(b['summary'], a['summary']);
      expect(b['undoToken'], a['undoToken']);
    });

    test('reusing a key for a different request is a conflict', () async {
      await run('set.add', <String, Object?>{}, key: 'retry-key-2');
      final r = await run('set.update', <String, Object?>{'set': 1, 'reps': 5},
          key: 'retry-key-2');
      expect(r['status'], 'conflict');
    });
  });

  group('workout and templates', () {
    test('opens a spoken date and reads the context back', () async {
      final r =
          await run('workout.open', <String, Object?>{'date': '2026-09-30'});
      expect(r['summary'], 'Workout for Wed 30 Sep open');
      expect(workout.day, DateTime(2026, 9, 30));
      final read = await run('workout.read', <String, Object?>{});
      expect((read['data'] as Map<String, dynamic>)['date'], '2026-09-30');
    });

    test("today's template loads into an empty day and undo removes it",
        () async {
      workout.rows.clear();
      workout.dayNumber = 2;
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(id: 't1', name: 'Day 1 Upper', inActiveBlock: true),
        TemplateEntry(id: 't2', name: 'Day 2 Lower', inActiveBlock: true),
      ];
      workout.templateRows['t2'] =
          () => <FakeExercise>[FakeExercise('squat_bb', 'Back Squat, Barbell')];
      final r = await run('template.load', <String, Object?>{});
      expect(r['summary'], 'Day 2 Lower loaded · 1 exercises');
      final u =
          await run('undo', <String, Object?>{'undoToken': r['undoToken']});
      expect(u['status'], 'success');
      expect(workout.rows, isEmpty);
    });

    test('never silently overwrites a populated workout', () async {
      workout.byId('bench_bb')!.values[0] = <Wes2FieldKey, Object>{
        Wes2FieldKey.reps: 5
      };
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(id: 't1', name: 'Push Day')
      ];
      workout.templateRows['t1'] =
          () => <FakeExercise>[FakeExercise('squat_bb', 'Back Squat, Barbell')];
      final r =
          await run('template.load', <String, Object?>{'template': 'push day'});
      expect(r['status'], 'requires_confirmation');
      expect(workout.calls.where((String c) => c.startsWith('loadTemplate')),
          isEmpty);
      final ok = await run(
          'template.load', <String, Object?>{'template': 'push day'},
          token: r['confirmationToken'] as String);
      expect(ok['status'], 'success');
      expect(ok['undoToken'], isNull,
          reason: 'no snapshot rewrite over logged data');
    });

    test('"load day two" selects the active block template whose day is Day 2',
        () async {
      workout.rows.clear();
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(id: 'old', name: 'Lower', day: 'Day 2'),
        TemplateEntry(
            id: 't1', name: 'Upper', day: 'Day 1', inActiveBlock: true),
        TemplateEntry(
            id: 't2', name: 'Lower', day: 'Day 2', inActiveBlock: true),
      ];
      workout.templateRows['t2'] =
          () => <FakeExercise>[FakeExercise('squat_bb', 'Back Squat, Barbell')];
      final r =
          await run('template.load', <String, Object?>{'template': 'day 2'});
      expect(r['status'], 'success');
      expect(workout.calls, contains('loadTemplate:t2'));
    });

    test('several templates for today are asked about', () async {
      workout.templateList = const <TemplateEntry>[
        TemplateEntry(id: 't1', name: 'Upper A', day: 'Thursday'),
        TemplateEntry(id: 't2', name: 'Upper B', day: 'Thursday'),
      ];
      final r = await run('template.load', <String, Object?>{});
      expect(r['status'], 'ambiguous');
      expect(r['candidates'], <String>['Upper A', 'Upper B']);
    });
  });

  group('undo ordering', () {
    test('only the latest change can be undone; a spent token is gone',
        () async {
      final a = await run('set.update', <String, Object?>{'set': 1, 'reps': 5});
      final b = await run('set.update', <String, Object?>{'set': 2, 'reps': 6});
      expect(
          (await run('undo', <String, Object?>{'undoToken': a['undoToken']}))[
              'status'],
          'conflict');
      expect(
          (await run('undo', <String, Object?>{'undoToken': b['undoToken']}))[
              'status'],
          'success');
      expect(
          (await run('undo', <String, Object?>{'undoToken': b['undoToken']}))[
              'status'],
          'not_found');
      expect(
          (await run('undo', <String, Object?>{'undoToken': a['undoToken']}))[
              'status'],
          'success');
      expect(workout.byId('bench_bb')!.values[0], isEmpty);
    });
  });

  test('a workout action with no workout open opens it first', () async {
    service.unregisterWorkout(workout);
    bool opened = false;
    service.openWorkout = () async {
      opened = true;
      service.registerWorkout(workout);
      return true;
    };
    final r = await run('set.update', <String, Object?>{'set': 1, 'reps': 5});
    expect(opened, isTrue);
    expect(r['status'], 'success');
  });

  test('results are bounded and carry the request id', () {
    final AurelianActionResult big = AurelianActionResult(
        ActionStatus.success, 'ok',
        data: <String, Object?>{'x': 'y' * 5000});
    final String text = big.encode('req-9');
    expect(text.length, lessThanOrEqualTo(kAurelianMaxResult));
    expect(jsonDecode(text)['dataOmitted'], isTrue);
    expect(jsonDecode(text)['requestId'], 'req-9');
  });
}
