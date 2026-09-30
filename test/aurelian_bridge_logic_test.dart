// Aurelian voice bridge — the pure Dart side: the typed command model, the
// command bus (routing, readiness, bringing up the workout), exercise name
// matching, set-entry planning and the WES2 voice target.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/aurelian/aurelian_bus.dart';
import 'package:localtest222/aurelian/aurelian_command.dart';
import 'package:localtest222/aurelian/aurelian_exercise_match.dart';
import 'package:localtest222/aurelian/aurelian_set_entry.dart';
import 'package:localtest222/aurelian/wes2_voice_target.dart';
import 'package:localtest222/units/weight_unit.dart';

Map<String, Object?> bridge(String command,
        [Map<String, Object?> args = const <String, Object?>{}]) =>
    <String, Object?>{
      'protocol': 1,
      'requestId': 'req-1',
      'command': command,
      'args': args,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('command model', () {
    test('parses every command with typed arguments', () {
      expect(AurelianCommand.fromBridge(bridge('open_workout'))!.kind,
          AurelianCommandKind.openWorkout);
      final AurelianCommand set = AurelianCommand.fromBridge(bridge(
          'set_fields', <String, Object?>{
        'setNumber': 1,
        'weight': 135.0,
        'weightUnit': 'lb',
        'reps': 5,
        'rir': 2.0,
      }))!;
      expect(set.setNumber, 1);
      expect(set.weight, 135.0);
      expect(set.weightUnit, ExerciseWeightUnit.lb);
      expect(set.reps, 5);
      expect(set.rir, 2.0);
      expect(AurelianCommand.fromBridge(
              bridge('select_exercise', <String, Object?>{'name': 'Bench Press, Barbell'}))!
          .name, 'Bench Press, Barbell');
      expect(AurelianCommand.fromBridge(
              bridge('analytics_metric', <String, Object?>{'metric': 'velocity'}))!
          .metric, AurelianMetric.velocity);
      expect(AurelianCommand.fromBridge(
              bridge('open_set_note', <String, Object?>{'setNumber': 12}))!
          .setNumber, 12);
    });

    test('rejects malformed commands', () {
      final List<Object?> bad = <Object?>[
        null,
        'open_workout',
        <String, Object?>{...bridge('open_workout'), 'protocol': 2},
        <String, Object?>{...bridge('open_workout'), 'requestId': ''},
        bridge('delete_workout'),
        bridge('open_workout', <String, Object?>{'evil': 'x'}),
        bridge('set_fields', <String, Object?>{'setNumber': 0, 'reps': 5}),
        bridge('set_fields', <String, Object?>{'setNumber': 1}),
        bridge('set_fields', <String, Object?>{'setNumber': '1', 'reps': 5}),
        bridge('set_fields', <String, Object?>{'setNumber': 1, 'reps': 5.5}),
        bridge('set_fields', <String, Object?>{'setNumber': 1, 'weightUnit': 'kg'}),
        bridge('set_fields', <String, Object?>{'setNumber': 1, 'weight': 50.0, 'weightUnit': 'stone'}),
        bridge('select_exercise'),
        bridge('select_exercise', <String, Object?>{'name': 'x' * 200}),
        bridge('analytics_metric', <String, Object?>{'metric': 'bench'}),
        bridge('open_set_note'),
      ];
      for (final Object? raw in bad) {
        expect(AurelianCommand.fromBridge(raw), isNull, reason: '$raw');
      }
    });

    test('results are bounded for the reply', () {
      final Map<String, Object?> map = AurelianResult.ambiguous(
              'm' * 500, List<String>.generate(20, (int i) => 'c$i' * 50))
          .toMap();
      expect((map['message']! as String).length, kAurelianMaxMessage);
      expect((map['candidates']! as List<Object?>).length, kAurelianMaxCandidates);
      expect(map['status'], 'ambiguous');
    });
  });

  group('command bus', () {
    late AurelianCommandBus bus;
    setUp(() => bus = AurelianCommandBus(
        workoutMountTimeout: const Duration(milliseconds: 200)));

    AurelianHandler handles(String name, Set<AurelianCommandKind> kinds,
            List<String> log) =>
        (AurelianCommand c) async {
          if (!kinds.contains(c.kind)) return null;
          log.add('$name:${c.kind.wire}');
          return AurelianResult.ok(name);
        };

    test('the more specific and most recent screen wins; null passes on', () async {
      final List<String> log = <String>[];
      bus.register(AurelianScopeKind.root,
          handles('root', <AurelianCommandKind>{AurelianCommandKind.openAnalytics}, log));
      bus.register(AurelianScopeKind.home,
          handles('home', <AurelianCommandKind>{AurelianCommandKind.openAnalytics, AurelianCommandKind.openWorkout}, log));
      bus.register(AurelianScopeKind.wes2,
          handles('wes2', <AurelianCommandKind>{AurelianCommandKind.openWorkout, AurelianCommandKind.selectExercise}, log));
      final Object picker = bus.register(AurelianScopeKind.picker,
          handles('picker', <AurelianCommandKind>{AurelianCommandKind.selectExercise}, log));

      expect((await bus.dispatch(const AurelianCommand(AurelianCommandKind.selectExercise, name: 'x'))).message, 'picker');
      expect((await bus.dispatch(const AurelianCommand(AurelianCommandKind.openWorkout))).message, 'wes2');
      expect((await bus.dispatch(const AurelianCommand(AurelianCommandKind.openAnalytics))).message, 'home');
      bus.unregister(picker);
      expect((await bus.dispatch(const AurelianCommand(AurelianCommandKind.selectExercise, name: 'x'))).message, 'wes2');
    });

    test('nothing to handle a select tells Aurelian to tap instead', () async {
      final AurelianResult r = await bus.dispatch(
          const AurelianCommand(AurelianCommandKind.selectExercise, name: 'save'));
      expect(r.status, AurelianStatus.notHandled);
      final AurelianResult other =
          await bus.dispatch(const AurelianCommand(AurelianCommandKind.openAnalytics));
      expect(other.status, AurelianStatus.unavailable);
    });

    test('a workout command with no workout mounted opens it, waits for it to register, then runs', () async {
      final List<String> log = <String>[];
      bus.register(AurelianScopeKind.home, (AurelianCommand c) async {
        if (c.kind != AurelianCommandKind.openWorkout) return null;
        log.add('home:open_workout');
        // WES2 mounts a little later (a real push + first frame).
        Timer(const Duration(milliseconds: 30), () {
          bus.register(AurelianScopeKind.wes2,
              handles('wes2', <AurelianCommandKind>{AurelianCommandKind.setFields}, log));
        });
        return const AurelianResult.ok('opened');
      });
      final AurelianResult r = await bus.dispatch(const AurelianCommand(
          AurelianCommandKind.setFields, setNumber: 1, reps: 5));
      expect(r.message, 'wes2');
      expect(log, <String>['home:open_workout', 'wes2:set_fields']);
    });

    test('a refused Enter Workout is returned as is (block not ready)', () async {
      bus.register(AurelianScopeKind.home, (AurelianCommand c) async =>
          c.kind == AurelianCommandKind.openWorkout
              ? const AurelianResult.unavailable('Training data is loading')
              : null);
      final AurelianResult r = await bus.dispatch(const AurelianCommand(AurelianCommandKind.addSet));
      expect(r.status, AurelianStatus.unavailable);
      expect(r.message, 'Training data is loading');
    });

    test('a workout that never mounts times out instead of hanging', () async {
      bus.register(AurelianScopeKind.home, (AurelianCommand c) async =>
          c.kind == AurelianCommandKind.openWorkout ? const AurelianResult.ok('x') : null);
      final AurelianResult r = await bus.dispatch(const AurelianCommand(AurelianCommandKind.nextExercise));
      expect(r.status, AurelianStatus.unavailable);
    });

    test('a failing handler is a failure, not a crash', () async {
      bus.register(AurelianScopeKind.wes2, (AurelianCommand c) async => throw StateError('boom'));
      expect((await bus.dispatch(const AurelianCommand(AurelianCommandKind.addSet))).status,
          AurelianStatus.failed);
    });

    test('ready only while a root scope (inside the membership gate) is mounted', () {
      final List<bool> changes = <bool>[];
      bus.onReadyChanged = changes.add;
      final Object home = bus.register(AurelianScopeKind.home, (AurelianCommand c) async => null);
      expect(bus.ready, isFalse, reason: 'a screen alone is not the gate');
      final Object root = bus.register(AurelianScopeKind.root, (AurelianCommand c) async => null);
      expect(bus.ready, isTrue);
      bus.unregister(root);
      expect(bus.ready, isFalse);
      bus.unregister(home);
      expect(changes, <bool>[true, false]);
    });

    test('the channel binding answers commands and reports readiness', () async {
      const MethodChannel channel = MethodChannel('test/aurelian');
      final List<String> nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        nativeCalls.add(call.method);
        return null;
      });
      AurelianBridgeChannel.bindTo(bus, channel);
      bus.register(AurelianScopeKind.root, (AurelianCommand c) async =>
          c.kind == AurelianCommandKind.openAnalytics ? const AurelianResult.ok('Analytics opened') : null);
      await Future<void>.delayed(Duration.zero);
      expect(nativeCalls, contains('ready'));

      Future<Map<Object?, Object?>> send(Object? args) async {
        final ByteData? reply = await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(channel.name,
                const StandardMethodCodec().encodeMethodCall(MethodCall('command', args)), (_) {});
        return const StandardMethodCodec().decodeEnvelope(reply!) as Map<Object?, Object?>;
      }

      expect((await send(bridge('open_analytics')))['status'], 'ok');
      expect((await send(bridge('rm_rf')))['status'], 'invalid');
      expect((await send(<String, Object?>{'protocol': 9}))['status'], 'invalid');
    });
  });

  group('exercise name matching', () {
    const List<String> catalogue = <String>[
      'Bench Press, Barbell',
      'Bench Press, Dumbbell',
      'Bench Press, Larsen Press',
      'Larsen Bench Press',
      'Lat Pulldown, Supinated',
      'Back Squat, Barbell',
      'Seated Cable Row',
      'Cable Row, Seated',
    ];
    ExerciseMatch<String> m(String spoken) =>
        matchExercise<String>(spoken, catalogue, (String s) => s);

    test('case, punctuation and spacing are ignored', () {
      for (final String spoken in <String>[
        'Bench Press Barbell',
        'bench press, barbell',
        'BENCH   PRESS -- BARBELL',
        'bench press barbell.',
      ]) {
        expect(m(spoken).isUnique, isTrue, reason: spoken);
        expect(m(spoken).single, 'Bench Press, Barbell');
      }
    });

    test('spacing inside a word is ignored: "lat pull down"', () {
      expect(m('Lat Pull Down Supinated').single, 'Lat Pulldown, Supinated');
    });

    test('genuinely different exercises are never merged', () {
      final ExerciseMatch<String> row = m('row cable seated');
      expect(row.isAmbiguous, isTrue,
          reason: 'two catalogued exercises share these words; ask, never guess');
      expect(row.matches, <String>['Seated Cable Row', 'Cable Row, Seated']);
      // Near-identical but different word counts stay different exercises.
      expect(m('larsen press bench').single, 'Larsen Bench Press');
      expect(m('bench press').isNone, isTrue,
          reason: 'a partial name is not "similar enough"');
      expect(m('bench press barbel').isNone, isTrue);
    });

    test('an exact name beats word order', () {
      expect(m('Larsen Bench Press').single, 'Larsen Bench Press');
    });

    test('a choice must be one of the current candidates', () {
      String? r(String choice) => resolveChoice<String>(
          'row cable seated', choice, catalogue, (String s) => s, (String s) => s);
      expect(r('Cable Row, Seated'), 'Cable Row, Seated');
      expect(r('Back Squat, Barbell'), isNull);
    });
  });

  group('set entry planning', () {
    SetEntryPlan plan(AurelianCommand c,
            {int sets = 3,
            ExerciseWeightUnit unit = ExerciseWeightUnit.kg,
            bool velocity = false,
            bool normal = true}) =>
        planSetEntry(c,
            exerciseName: 'Bench Press, Barbell',
            setCount: sets,
            displayUnit: unit,
            velocityShown: velocity,
            normalEntry: normal);

    test('kilograms pass through; set numbers are 1-based', () {
      final SetEntryPlan p = plan(const AurelianCommand(AurelianCommandKind.setFields,
          setNumber: 1, weight: 50, weightUnit: ExerciseWeightUnit.kg));
      expect(p.isValid, isTrue);
      expect(p.setIndex, 0);
      expect(p.edits, <SetFieldEdit>[const SetFieldEdit(Wes2FieldKey.weight, '50')]);
      expect(p.summary, 'Set 1: 50 kg');
    });

    test('pounds are converted once, exactly like the lb weight field', () {
      final SetEntryPlan p = plan(const AurelianCommand(AurelianCommandKind.setFields,
          setNumber: 2, weight: 135, weightUnit: ExerciseWeightUnit.lb));
      expect(p.edits.single.text, parseDisplayToKg('135', ExerciseWeightUnit.lb).toString());
      expect(double.parse(p.edits.single.text), closeTo(61.235, 0.001));
      expect(p.setIndex, 1);
    });

    test('no unit said: the exercise display unit decides', () {
      final SetEntryPlan lb = plan(const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, weight: 100),
          unit: ExerciseWeightUnit.lb);
      expect(double.parse(lb.edits.single.text), closeTo(45.359, 0.001));
      final SetEntryPlan kg = plan(const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, weight: 100));
      expect(kg.edits.single.text, '100');
      // A spoken kilogram on a pound exercise is still kilograms.
      final SetEntryPlan said = plan(
          const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, weight: 50, weightUnit: ExerciseWeightUnit.kg),
          unit: ExerciseWeightUnit.lb);
      expect(said.edits.single.text, '50');
    });

    test('combined entry is validated first and applied as a whole', () {
      final SetEntryPlan p = plan(const AurelianCommand(AurelianCommandKind.setFields,
          setNumber: 1, weight: 50, weightUnit: ExerciseWeightUnit.kg, reps: 5, rir: 2));
      expect(p.edits.map((SetFieldEdit e) => e.fieldKey),
          <Wes2FieldKey>[Wes2FieldKey.weight, Wes2FieldKey.reps, Wes2FieldKey.rir]);
      expect(p.summary, 'Set 1: 50 kg · 5 reps · RIR 2');
      final SetEntryPlan bad = plan(const AurelianCommand(AurelianCommandKind.setFields,
          setNumber: 1, weight: 50, reps: 5, rir: 12));
      expect(bad.isValid, isFalse);
      expect(bad.edits, isEmpty, reason: 'nothing half-applied');
    });

    test('RIR decimals and arbitrary set numbers', () {
      final SetEntryPlan p = plan(const AurelianCommand(AurelianCommandKind.setFields, setNumber: 7, rir: 1.5), sets: 8);
      expect(p.edits.single, const SetFieldEdit(Wes2FieldKey.rir, '1.5'));
      expect(p.setIndex, 6);
    });

    test('a set beyond the exercise is refused with a useful message', () {
      final SetEntryPlan p = plan(const AurelianCommand(AurelianCommandKind.setFields, setNumber: 5, reps: 5), sets: 3);
      expect(p.isValid, isFalse);
      expect(p.error, contains('add set'));
    });

    test('velocity only where the exercise shows it; timed exercises refused', () {
      const AurelianCommand v = AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, velocity: 0.32);
      expect(plan(v).isValid, isFalse);
      expect(plan(v, velocity: true).edits.single, const SetFieldEdit(Wes2FieldKey.velocity, '0.32'));
      expect(plan(const AurelianCommand(AurelianCommandKind.setFields, setNumber: 1, reps: 30), normal: false).isValid, isFalse);
    });
  });

  group('voice target', () {
    test('first exercise, select, next, previous, removal', () {
      final Wes2VoiceTarget t = Wes2VoiceTarget();
      expect(t.resolve(<String>[]), isNull);
      expect(t.resolve(<String>['a', 'b', 'c']), 'a');
      expect(t.next(<String>['a', 'b', 'c']), 'b');
      expect(t.next(<String>['a', 'b', 'c']), 'c');
      expect(t.next(<String>['a', 'b', 'c']), isNull, reason: 'already last');
      expect(t.exerciseId, 'c');
      expect(t.previous(<String>['a', 'b', 'c']), 'b');
      t.select('a');
      expect(t.previous(<String>['a', 'b', 'c']), isNull);
      t.select('gone');
      expect(t.resolve(<String>['a', 'b']), 'a', reason: 'a deleted target falls back to the first');
      t.select('b');
      expect(t.next(<String>['a', 'b', 'new']), 'new', reason: 'a newly added exercise is next in order');
    });
  });
}
