// Voice UX expansion: the typed command model's new commands, the exercise
// matcher's new tiers, "which one?" answers and spoken-list splitting.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/aurelian/aurelian_add_list.dart';
import 'package:localtest222/aurelian/aurelian_bus.dart';
import 'package:localtest222/aurelian/aurelian_command.dart';
import 'package:localtest222/aurelian/aurelian_exercise_match.dart';

Map<String, Object?> _raw(String command, [Map<String, Object?> args = const <String, Object?>{}]) =>
    <String, Object?>{'protocol': 1, 'requestId': 'r-1', 'command': command, 'args': args};

String _id(String s) => s;

void main() {
  group('command model', () {
    test('parses the new commands with typed, bounded arguments', () {
      final AurelianCommand nav = AurelianCommand.fromBridge(_raw('navigate', <String, Object?>{'destination': 'block_planner_2'}))!;
      expect(nav.kind, AurelianCommandKind.navigate);
      expect(nav.destination, AurelianDestination.blockPlanner2);

      final AurelianCommand action =
          AurelianCommand.fromBridge(_raw('workout_action', <String, Object?>{'action': 'load_template'}))!;
      expect(action.action, AurelianWorkoutAction.loadTemplate);

      final AurelianCommand add = AurelianCommand.fromBridge(_raw('add_exercises', <String, Object?>{
        'phrase': 'bench press, suspended high row and back squats',
        'choices': <Object?>['Bench Press, Barbell'],
      }))!;
      expect(add.phrase, 'bench press, suspended high row and back squats');
      expect(add.choices, <String>['Bench Press, Barbell']);

      final AurelianCommand set = AurelianCommand.fromBridge(_raw('set_fields',
          <String, Object?>{'setNumber': 1, 'weight': 150.0, 'reps': 5, 'rir': 1.0, 'exercise': 'bench press'}))!;
      expect(set.exercise, 'bench press');

      expect(AurelianCommand.fromBridge(_raw('clear_set', <String, Object?>{'setNumber': 1}))!.kind, AurelianCommandKind.clearSet);
      expect(AurelianCommand.fromBridge(_raw('delete_exercise'))!.exercise, isNull, reason: 'the current exercise');
      final AurelianCommand replace = AurelianCommand.fromBridge(
          _raw('replace_exercise', <String, Object?>{'exercise': 'suspended high row', 'replacement': 'kp face pull'}))!;
      expect(replace.replacement, 'kp face pull');
      expect(AurelianCommand.fromBridge(_raw('move_to_circuit', <String, Object?>{'circuit': 2}))!.circuit, 2);
      expect(AurelianCommand.fromBridge(_raw('mark_exercise_done', <String, Object?>{'exercise': 'back squat'}))!.exercise,
          'back squat');
    });

    test('refuses malformed new commands', () {
      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        _raw('navigate'),
        _raw('navigate', <String, Object?>{'destination': 'bank_account'}),
        _raw('workout_action', <String, Object?>{'action': 'delete_everything'}),
        _raw('add_exercises'),
        _raw('add_exercises', <String, Object?>{'phrase': 'x' * (kAurelianMaxPhrase + 1)}),
        _raw('add_exercises', <String, Object?>{'phrase': 'rows', 'choices': 'Row'}),
        _raw('add_exercises', <String, Object?>{'phrase': 'rows', 'choices': List<Object?>.filled(kAurelianMaxChoices + 1, 'a')}),
        _raw('add_exercises', <String, Object?>{'phrase': 'rows', 'choices': <Object?>[1]}),
        _raw('clear_set'),
        _raw('remove_set', <String, Object?>{'setNumber': 0}),
        _raw('replace_exercise', <String, Object?>{'exercise': 'rows'}),
        _raw('move_to_circuit', <String, Object?>{'circuit': 0}),
        _raw('add_exercise_to_circuit', <String, Object?>{'circuit': kAurelianMaxCircuit + 1}),
        _raw('delete_exercise', <String, Object?>{'exercise': 'x' * (kAurelianMaxName + 1)}),
        _raw('delete_exercise', <String, Object?>{'phrase': 'rows'}),
      ]) {
        expect(AurelianCommand.fromBridge(bad), isNull, reason: '$bad');
      }
    });

    test('workout commands open the workout first; destructive ones are marked', () {
      for (final AurelianCommandKind k in <AurelianCommandKind>[
        AurelianCommandKind.workoutAction,
        AurelianCommandKind.addExercises,
        AurelianCommandKind.clearSet,
        AurelianCommandKind.removeSet,
        AurelianCommandKind.deleteExercise,
        AurelianCommandKind.replaceExercise,
        AurelianCommandKind.addExerciseToCircuit,
        AurelianCommandKind.moveToCircuit,
      ]) {
        expect(k.needsWorkout, isTrue, reason: k.wire);
      }
      expect(AurelianCommandKind.navigate.needsWorkout, isFalse);
      expect(AurelianCommandKind.deleteExercise.isDestructive, isTrue);
      expect(AurelianCommandKind.replaceExercise.isDestructive, isTrue);
      expect(AurelianCommandKind.setFields.isDestructive, isFalse);
      expect(AurelianCommandKind.addExercises.isDestructive, isFalse);
    });

    test('navigate goes to whichever screen answers it (Home), never opening the workout', () async {
      final AurelianCommandBus bus = AurelianCommandBus(workoutMountTimeout: const Duration(milliseconds: 50));
      final List<String> seen = <String>[];
      bus.register(AurelianScopeKind.root, (AurelianCommand c) async => null);
      bus.register(AurelianScopeKind.home, (AurelianCommand c) async {
        seen.add(c.kind.wire);
        return c.kind == AurelianCommandKind.navigate ? AurelianResult.ok(c.destination!.label) : null;
      });
      final AurelianResult r = await bus.dispatch(AurelianCommand.fromBridge(_raw('navigate', <String, Object?>{'destination': 'leaderboard'}))!);
      expect(r.message, 'Leaderboard');
      expect(seen, <String>['navigate']);
    });
  });

  group('exercise matching tiers', () {
    const List<String> workout = <String>['Bench Press, Barbell', 'Bench Press, Dumbbell', 'Back Squat', 'Suspended High Row'];
    ExerciseMatch<String> m(String spoken, List<String> from, {bool fuzzy = false}) =>
        matchExercise<String>(spoken, from, _id, allowFuzzy: fuzzy);

    test('plurals are ignored', () {
      expect(m('back squats', workout).single, 'Back Squat');
      expect(m('back squats', workout).strength, ExerciseMatchStrength.reordered);
    });

    test('a subset of an exercise\'s words: unique is chosen, several are asked about', () {
      expect(m('suspended row', workout).single, 'Suspended High Row');
      expect(m('suspended row', workout).strength, ExerciseMatchStrength.subset);
      final ExerciseMatch<String> bench = m('bench press', workout);
      expect(bench.isAmbiguous, isTrue);
      expect(bench.matches, <String>['Bench Press, Barbell', 'Bench Press, Dumbbell']);
      // The whole name still wins over the subset tier.
      expect(m('bench press barbell', workout).single, 'Bench Press, Barbell');
    });

    test('fuzzy only when allowed, only close, and only with a clear margin', () {
      expect(m('suspended hi row', workout).isNone, isTrue, reason: 'destructive callers never pass allowFuzzy');
      expect(m('suspended hi row', workout, fuzzy: true).single, 'Suspended High Row');
      expect(m('suspended hi row', workout, fuzzy: true).strength, ExerciseMatchStrength.fuzzy);
      expect(m('bak squat', workout, fuzzy: true).single, 'Back Squat');
      // Far away: nothing.
      expect(m('deadlift', workout, fuzzy: true).isNone, isTrue);
      // Too short to guess at.
      expect(m('rw', <String>['Row'], fuzzy: true).isNone, isTrue);
      // Two candidates equally close: asked, not guessed.
      final ExerciseMatch<String> close =
          m('curl, cable', <String>['Curl, Cable A', 'Curl, Cable B'], fuzzy: true);
      expect(close.isAmbiguous, isTrue);
    });

    test('genuinely different exercises are still never merged', () {
      final ExerciseMatch<String> rows = m('row cable seated', <String>['Seated Cable Row', 'Cable Row, Seated']);
      expect(rows.isAmbiguous, isTrue);
    });

    test('edit distance', () {
      expect(editDistance('kitten', 'sitting'), 3);
      expect(editDistance('', 'abc'), 3);
      expect(editDistance('abc', 'abc'), 0);
      expect(editDistance('abcdef', 'uvwxyz', 2), 3, reason: 'stops early past the cap');
    });
  });

  group('"which one?" answers', () {
    const List<String> catalogue = <String>['Bench Press, Barbell', 'Bench Press, Dumbbell', 'Back Squat, Barbell', 'Back Squat, Safety Bar'];

    test('an answer that is one of the current candidates settles it', () {
      final NamedResolution<String> r = resolveNamed<String>('bench press', catalogue, _id, _id,
          choices: <String>['Bench Press, Dumbbell']);
      expect(r.chosen, 'Bench Press, Dumbbell');
    });

    test('answers for other names in the same command are ignored', () {
      const List<String> answers = <String>['Bench Press, Dumbbell', 'Back Squat, Safety Bar'];
      expect(resolveNamed<String>('bench press', catalogue, _id, _id, choices: answers).chosen, 'Bench Press, Dumbbell');
      expect(resolveNamed<String>('back squat', catalogue, _id, _id, choices: answers).chosen, 'Back Squat, Safety Bar');
    });

    test('a stale answer asks again', () {
      final NamedResolution<String> r =
          resolveNamed<String>('bench press', catalogue, _id, _id, choices: <String>['Bench Press, Smith']);
      expect(r.isAmbiguous, isTrue);
      expect(r.ask, <String>['Bench Press, Barbell', 'Bench Press, Dumbbell']);
    });

    test('no match is neither chosen nor asked', () {
      expect(resolveNamed<String>('zercher hover', catalogue, _id, _id).isNone, isTrue);
    });
  });

  group('spoken lists', () {
    const List<String> catalogue = <String>[
      'Bench Press, Barbell',
      'Suspended High Row',
      'Back Squat',
      'Clean and Jerk',
      'Power Clean',
      'Split Jerk',
      'Lat Pulldown',
      'KP Face Pull',
    ];
    List<String> split(String phrase) => splitSpokenList<String>(phrase, catalogue, _id).names;

    test('commas, "and" and "plus" separate names', () {
      expect(split('bench press barbell, suspended high row and back squats'),
          <String>['bench press barbell', 'suspended high row', 'back squats']);
      expect(split('lat pulldown plus kp face pull'), <String>['lat pulldown', 'kp face pull']);
      expect(split('suspended high row'), <String>['suspended high row']);
    });

    test('"and" inside a name is kept when the catalogue says so', () {
      expect(split('clean and jerk and back squat'), <String>['clean and jerk', 'back squat']);
      expect(split('power clean and split jerk'), <String>['power clean', 'split jerk']);
    });

    test('a comma and an "and" together are one separator', () {
      expect(split('bench press barbell, and back squat'), <String>['bench press barbell', 'back squat']);
    });

    test('at most ten names', () {
      final SpokenList many = splitSpokenList<String>(
          List<String>.generate(11, (int i) => 'back squat').join(', '), catalogue, _id);
      expect(many.error, contains('10'));
      expect(splitSpokenList<String>(' , and ', catalogue, _id).error, isNotNull);
    });
  });

  group('one path for touch and voice', () {
    String src(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

    test('every Home card and its voice destination call the same method', () {
      final String home = src('lib/home_screen_2.dart');
      for (final String method in <String>[
        '_openBodyWeightTracker', '_openWorkoutPlanner', '_openProfile', '_openBlockPlanner2', //
        '_openWeekPlanner', '_openSettings', '_openCoachDashboard', '_openCoaching',
      ]) {
        expect(home, contains('onTap: $method,'), reason: 'the card uses $method');
        expect(home, contains('opened = $method();'), reason: 'voice uses $method');
      }
      expect(home, contains('onTap: _openAnalytics,'));
      expect(home, contains('BuddyHubButton.open('));
      expect(home, contains('DmBadgeButton.open('));
      expect(home, contains('_scaffoldKey.currentState?.openDrawer()'));
    });

    test('the top-bar buttons open through their own static openers', () {
      expect(src('lib/social/ui/buddy_hub_button.dart'), contains('BuddyHubButton.open('));
      expect(src('lib/social/ui/dm_badge_button.dart'), contains('onPressed: () => open(context, unreadService: unread)'));
    });

    test('WES2 voice structural edits run the confirmed cores the dialogs run', () {
      final String wes2 = src('lib/WES2_screen.dart');
      for (final String core in <String>[
        '_deleteExerciseConfirmed(', '_applyReplacement(', '_moveExerciseToCircuitConfirmed(', '_removeSetConfirmed(',
      ]) {
        // Once defined, once from the touch path, at least once from voice.
        expect(core.allMatches(wes2).length, greaterThanOrEqualTo(3), reason: core);
      }
      expect(wes2, isNot(contains('simulateTap')));
    });
  });
}
