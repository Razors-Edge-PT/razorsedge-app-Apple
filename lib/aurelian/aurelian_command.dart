/// Typed commands from Aurelian's voice bridge, and their typed results.
///
/// The native bridge (android/.../AurelianBridgeCore.kt) has already checked the
/// caller (Aurelian, by package and signing certificate), the protocol version
/// and the argument types and sizes; [AurelianCommand.fromBridge] checks them
/// again, so nothing untyped ever reaches a screen. There is no free-form
/// payload: a command is one of [AurelianCommandKind] with a fixed set of typed
/// fields. See docs/aurelian_bridge.md.
library;

import 'package:flutter/foundation.dart';

import '../units/weight_unit.dart';

const int kAurelianProtocolVersion = 1;
const int kAurelianMaxName = 80;
const int kAurelianMaxCandidates = 8;
const int kAurelianMaxMessage = 200;

/// A spoken list of exercise names ("add bench press, rows and back squats").
const int kAurelianMaxPhrase = 200;

/// Labels picked in answer to earlier "which one?" questions for one command.
const int kAurelianMaxChoices = 8;

/// Exercises one "add …" may name.
const int kAurelianMaxAdd = 10;
const int kAurelianMaxCircuit = 20;

enum AurelianCommandKind {
  openWorkout('open_workout'),
  openAnalytics('open_analytics'),
  addExercise('add_exercise'),
  selectExercise('select_exercise'),
  nextExercise('next_exercise'),
  previousExercise('previous_exercise'),
  setFields('set_fields'),
  openSetNote('open_set_note'),
  openExerciseNote('open_exercise_note'),
  addSet('add_set'),
  markExerciseDone('mark_exercise_done'),
  analyticsMetric('analytics_metric'),
  // Voice UX expansion (still protocol v1).
  navigate('navigate'),
  workoutAction('workout_action'),
  addExercises('add_exercises'),
  clearSet('clear_set'),
  removeSet('remove_set'),
  deleteExercise('delete_exercise'),
  replaceExercise('replace_exercise'),
  addExerciseToCircuit('add_exercise_to_circuit'),
  moveToCircuit('move_to_circuit');

  const AurelianCommandKind(this.wire);
  final String wire;

  static AurelianCommandKind? fromWire(Object? wire) {
    for (final AurelianCommandKind k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }

  /// Commands that act on the WES2 workout: they bring WES2 up first if needed.
  bool get needsWorkout => const <AurelianCommandKind>{
        AurelianCommandKind.addExercise,
        AurelianCommandKind.nextExercise,
        AurelianCommandKind.previousExercise,
        AurelianCommandKind.setFields,
        AurelianCommandKind.openSetNote,
        AurelianCommandKind.openExerciseNote,
        AurelianCommandKind.addSet,
        AurelianCommandKind.markExerciseDone,
        AurelianCommandKind.workoutAction,
        AurelianCommandKind.addExercises,
        AurelianCommandKind.clearSet,
        AurelianCommandKind.removeSet,
        AurelianCommandKind.deleteExercise,
        AurelianCommandKind.replaceExercise,
        AurelianCommandKind.addExerciseToCircuit,
        AurelianCommandKind.moveToCircuit,
      }.contains(this);

  /// Commands that remove or restructure workout data: a fuzzy exercise match
  /// is never good enough for these (see aurelian_exercise_match.dart).
  bool get isDestructive => const <AurelianCommandKind>{
        AurelianCommandKind.clearSet,
        AurelianCommandKind.removeSet,
        AurelianCommandKind.deleteExercise,
        AurelianCommandKind.replaceExercise,
        AurelianCommandKind.moveToCircuit,
      }.contains(this);
}

enum AurelianMetric { e1rm, velocity }

/// The Home screen's cards and top-bar controls a voice command can open.
/// Each one runs the same handler as tapping it.
enum AurelianDestination {
  bodyWeightTracker('body_weight_tracker', 'Body Weight Tracker'),
  workoutPlanner('workout_planner', 'Workout Planner'),
  profile('profile', 'Profile'),
  blockPlanner2('block_planner_2', 'Block Planner 2'),
  weekPlanner('week_planner', 'Week Planner'),
  settings('settings', 'Settings'),
  coachDashboard('coach_dashboard', 'Coach Dashboard'),
  coaching('coaching', 'Coaching'),
  feed('feed', 'Feed'),
  leaderboard('leaderboard', 'Leaderboard'),
  buddyHub('buddy_hub', 'Buddy Hub'),
  messages('messages', 'Messages'),
  menu('menu', 'Menu');

  const AurelianDestination(this.wire, this.label);
  final String wire;
  final String label;

  static AurelianDestination? fromWire(Object? wire) {
    for (final AurelianDestination d in values) {
      if (d.wire == wire) return d;
    }
    return null;
  }
}

/// WES2 controls a voice command can press (each runs the button's own handler).
enum AurelianWorkoutAction {
  loadTemplate('load_template'),
  selectDate('select_date'),
  previousDay('previous_day'),
  nextDay('next_day'),
  addCircuit('add_circuit'),
  exerciseSettings('exercise_settings'),
  exerciseDetails('exercise_details'),
  topSets('top_sets'),
  currentExercise('current_exercise');

  const AurelianWorkoutAction(this.wire);
  final String wire;

  static AurelianWorkoutAction? fromWire(Object? wire) {
    for (final AurelianWorkoutAction a in values) {
      if (a.wire == wire) return a;
    }
    return null;
  }
}

@immutable
class AurelianCommand {
  const AurelianCommand(
    this.kind, {
    this.requestId = '',
    this.setNumber,
    this.weight,
    this.weightUnit,
    this.reps,
    this.rir,
    this.velocity,
    this.name,
    this.choice,
    this.metric,
    this.exercise,
    this.replacement,
    this.phrase,
    this.choices = const <String>[],
    this.destination,
    this.action,
    this.circuit,
  });

  final AurelianCommandKind kind;
  final String requestId;

  /// 1-based, as spoken ("set one"). WES2's own setIndex is [setNumber] - 1.
  final int? setNumber;
  final double? weight;

  /// The unit that was SAID; null means "this exercise's own GoodLift unit".
  final ExerciseWeightUnit? weightUnit;
  final int? reps;
  final double? rir;
  final double? velocity;

  /// Spoken exercise name for [AurelianCommandKind.selectExercise].
  final String? name;

  /// The candidate chosen in answer to an earlier "which one?".
  final String? choice;
  final AurelianMetric? metric;

  /// The exercise the command names ("… of bench press"); null = the current one.
  final String? exercise;

  /// The exercise to swap in, for [AurelianCommandKind.replaceExercise].
  final String? replacement;

  /// The spoken list for [AurelianCommandKind.addExercises].
  final String? phrase;

  /// Labels picked, in order, in answer to this command's earlier "which one?"
  /// questions. Each is re-checked against the candidates GoodLift finds now.
  final List<String> choices;
  final AurelianDestination? destination;
  final AurelianWorkoutAction? action;

  /// 1-based circuit number, as spoken.
  final int? circuit;

  bool get hasSetValues =>
      weight != null || reps != null || rir != null || velocity != null;

  /// Parses the map the native bridge sends, or null if anything is off.
  static AurelianCommand? fromBridge(Object? raw) {
    if (raw is! Map) return null;
    if (raw['protocol'] != kAurelianProtocolVersion) return null;
    final Object? id = raw['requestId'];
    if (id is! String || id.isEmpty || id.length > 64) return null;
    final AurelianCommandKind? kind = AurelianCommandKind.fromWire(raw['command']);
    if (kind == null) return null;
    final Object? rawArgs = raw['args'] ?? const <String, Object?>{};
    if (rawArgs is! Map) return null;
    final Map<Object?, Object?> args = rawArgs;

    // The same per-command argument sets as the native schema.
    final Set<String> allowed = _argumentsOf[kind]!;
    if (args.keys.any((Object? k) => k is! String || !allowed.contains(k))) {
      return null;
    }

    int? intArg(String k) {
      final Object? v = args[k];
      return v is int ? v : null;
    }

    double? doubleArg(String k) {
      final Object? v = args[k];
      if (v is double && v.isFinite) return v;
      if (v is int) return v.toDouble();
      return null;
    }

    String? stringArg(String k) {
      final Object? v = args[k];
      if (v is! String) return null;
      final String t = v.trim();
      if (t.isEmpty || t.length > kAurelianMaxName) return null;
      return t;
    }

    bool present(String k) => args.containsKey(k) && args[k] != null;
    // A present argument of the wrong type is a malformed command, not an omission.
    for (final String k in <String>['setNumber', 'reps', 'circuit']) {
      if (present(k) && intArg(k) == null) return null;
    }
    for (final String k in <String>['weight', 'rir', 'velocity']) {
      if (present(k) && doubleArg(k) == null) return null;
    }
    for (final String k in <String>[
      'name', 'choice', 'metric', 'weightUnit', //
      'exercise', 'replacement', 'destination', 'action',
    ]) {
      if (present(k) && stringArg(k) == null) return null;
    }
    String? phrase;
    if (present('phrase')) {
      final Object? v = args['phrase'];
      if (v is! String) return null;
      phrase = v.trim();
      if (phrase.isEmpty || phrase.length > kAurelianMaxPhrase) return null;
    }
    List<String> choices = const <String>[];
    if (present('choices')) {
      final Object? v = args['choices'];
      if (v is! List || v.length > kAurelianMaxChoices) return null;
      final List<String> out = <String>[];
      for (final Object? c in v) {
        if (c is! String || c.trim().isEmpty || c.length > kAurelianMaxName) {
          return null;
        }
        out.add(c.trim());
      }
      choices = List<String>.unmodifiable(out);
    }
    AurelianDestination? destination;
    if (present('destination')) {
      destination = AurelianDestination.fromWire(stringArg('destination'));
      if (destination == null) return null;
    }
    AurelianWorkoutAction? action;
    if (present('action')) {
      action = AurelianWorkoutAction.fromWire(stringArg('action'));
      if (action == null) return null;
    }

    ExerciseWeightUnit? unit;
    if (present('weightUnit')) {
      unit = ExerciseWeightUnit.parseOrNull(stringArg('weightUnit'));
      if (unit == null) return null;
    }
    AurelianMetric? metric;
    if (present('metric')) {
      switch (stringArg('metric')) {
        case 'e1rm':
          metric = AurelianMetric.e1rm;
        case 'velocity':
          metric = AurelianMetric.velocity;
        default:
          return null;
      }
    }

    final AurelianCommand command = AurelianCommand(
      kind,
      requestId: id,
      setNumber: intArg('setNumber'),
      weight: doubleArg('weight'),
      weightUnit: unit,
      reps: intArg('reps'),
      rir: doubleArg('rir'),
      velocity: doubleArg('velocity'),
      name: stringArg('name'),
      choice: stringArg('choice'),
      metric: metric,
      exercise: stringArg('exercise'),
      replacement: stringArg('replacement'),
      phrase: phrase,
      choices: choices,
      destination: destination,
      action: action,
      circuit: intArg('circuit'),
    );
    return command._isWellFormed ? command : null;
  }

  static const Set<String> _named = <String>{'exercise', 'choices'};
  static const Map<AurelianCommandKind, Set<String>> _argumentsOf =
      <AurelianCommandKind, Set<String>>{
    AurelianCommandKind.openWorkout: <String>{},
    AurelianCommandKind.openAnalytics: <String>{},
    AurelianCommandKind.addExercise: <String>{},
    AurelianCommandKind.nextExercise: <String>{},
    AurelianCommandKind.previousExercise: <String>{},
    AurelianCommandKind.addSet: <String>{},
    AurelianCommandKind.openExerciseNote: <String>{},
    AurelianCommandKind.markExerciseDone: _named,
    AurelianCommandKind.openSetNote: <String>{'setNumber'},
    AurelianCommandKind.analyticsMetric: <String>{'metric'},
    AurelianCommandKind.selectExercise: <String>{'name', 'choice'},
    AurelianCommandKind.setFields: <String>{
      'setNumber', 'weight', 'weightUnit', 'reps', 'rir', 'velocity', //
      'exercise', 'choices',
    },
    AurelianCommandKind.navigate: <String>{'destination'},
    AurelianCommandKind.workoutAction: <String>{'action'},
    AurelianCommandKind.addExercises: <String>{'phrase', 'choices'},
    AurelianCommandKind.clearSet: <String>{'setNumber', 'exercise', 'choices'},
    AurelianCommandKind.removeSet: <String>{'setNumber', 'exercise', 'choices'},
    AurelianCommandKind.deleteExercise: _named,
    AurelianCommandKind.replaceExercise: <String>{
      'replacement', 'exercise', 'choices',
    },
    AurelianCommandKind.addExerciseToCircuit: <String>{'circuit'},
    AurelianCommandKind.moveToCircuit: <String>{'circuit', 'exercise', 'choices'},
  };

  bool get _isWellFormed {
    final int? n = setNumber;
    switch (kind) {
      case AurelianCommandKind.setFields:
        return n != null && n >= 1 && n <= 99 && hasSetValues &&
            (weightUnit == null || weight != null);
      case AurelianCommandKind.openSetNote:
        return n != null && n >= 1 && n <= 99;
      case AurelianCommandKind.selectExercise:
        return name != null;
      case AurelianCommandKind.analyticsMetric:
        return metric != null;
      case AurelianCommandKind.navigate:
        return destination != null;
      case AurelianCommandKind.workoutAction:
        return action != null;
      case AurelianCommandKind.addExercises:
        return phrase != null;
      case AurelianCommandKind.clearSet:
      case AurelianCommandKind.removeSet:
        return n != null && n >= 1 && n <= 99;
      case AurelianCommandKind.replaceExercise:
        return replacement != null;
      case AurelianCommandKind.addExerciseToCircuit:
      case AurelianCommandKind.moveToCircuit:
        final int? c = circuit;
        return c != null && c >= 1 && c <= kAurelianMaxCircuit;
      case AurelianCommandKind.deleteExercise:
        return true;
      case AurelianCommandKind.openWorkout:
      case AurelianCommandKind.openAnalytics:
      case AurelianCommandKind.addExercise:
      case AurelianCommandKind.nextExercise:
      case AurelianCommandKind.previousExercise:
      case AurelianCommandKind.openExerciseNote:
      case AurelianCommandKind.addSet:
      case AurelianCommandKind.markExerciseDone:
        return true;
    }
  }

  @override
  String toString() => 'AurelianCommand(${kind.wire})';
}

enum AurelianStatus {
  ok('ok'),
  ambiguous('ambiguous'),
  notFound('not_found'),

  /// No GoodLift screen can do it; for "select" Aurelian then taps instead.
  notHandled('not_handled'),
  unavailable('unavailable'),
  unsupported('unsupported'),
  invalid('invalid'),
  failed('failed');

  const AurelianStatus(this.wire);
  final String wire;
}

@immutable
class AurelianResult {
  const AurelianResult(this.status, this.message,
      {this.candidates = const <String>[], this.context});

  const AurelianResult.ok(String message) : this(AurelianStatus.ok, message);
  const AurelianResult.unavailable(String message)
      : this(AurelianStatus.unavailable, message);
  const AurelianResult.invalid(String message)
      : this(AurelianStatus.invalid, message);
  const AurelianResult.notFound(String message)
      : this(AurelianStatus.notFound, message);
  const AurelianResult.notHandled(String message)
      : this(AurelianStatus.notHandled, message);
  const AurelianResult.failed(String message)
      : this(AurelianStatus.failed, message);

  factory AurelianResult.ambiguous(String message, List<String> candidates,
          {String? context}) =>
      AurelianResult(AurelianStatus.ambiguous, message,
          candidates: candidates, context: context);

  final AurelianStatus status;
  final String message;
  final List<String> candidates;

  /// The screen the result came from ("picker", "analytics", "wes2").
  final String? context;

  bool get isOk => status == AurelianStatus.ok;

  Map<String, Object?> toMap() => <String, Object?>{
        'status': status.wire,
        'message': message.length > kAurelianMaxMessage
            ? message.substring(0, kAurelianMaxMessage)
            : message,
        if (candidates.isNotEmpty)
          'candidates': candidates
              .take(kAurelianMaxCandidates)
              .map((String c) => c.length > kAurelianMaxName
                  ? c.substring(0, kAurelianMaxName)
                  : c)
              .toList(),
        if (context != null) 'context': context,
      };

  @override
  String toString() => 'AurelianResult(${status.wire}: $message)';
}
