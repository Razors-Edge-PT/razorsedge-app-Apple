/// The reusable GoodLift action service behind Aurelian 2.0.
///
/// One envelope in, one structured result out. For every action it:
///   1. requires a signed-in GoodLift account and re-checks coach access for
///      the athlete being acted on (never trusting anything the planner said
///      about identity — envelopes carry no user ids);
///   2. deduplicates by idempotency key (a retried request returns the first
///      result instead of running twice);
///   3. resolves spoken names conservatively, returning `ambiguous` or
///      `not_found` rather than guessing;
///   4. asks for confirmation (a single-use token bound to the exact request)
///      before removing or overwriting logged data;
///   5. runs the SAME operation the screen's own controls run, through the
///      ports (action_ports.dart);
///   6. reads the state back and reports success only when it matches;
///   7. journals an inverse for "undo that" that re-checks its precondition,
///      so undo never overwrites a change made after the voice action.
///
/// No Android, Firebase, widget or AI dependency: fully unit tested with fakes.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math';

import '../../WES2_models.dart' show Wes2FieldKey;
import '../../units/weight_unit.dart';
import '../aurelian_command.dart';
import '../aurelian_exercise_match.dart';
import '../aurelian_set_entry.dart';
import 'action_envelope.dart';
import 'action_ports.dart';
import 'action_result.dart';
import 'athlete_match.dart';
import 'exercise_resolution.dart';

typedef WorkoutOpener = Future<bool> Function();

class _Cached {
  _Cached(this.fingerprint, this.result, this.at);
  final String fingerprint;
  final AurelianActionResult result;
  final DateTime at;
}

class _PendingConfirmation {
  _PendingConfirmation(this.fingerprint, this.expires);
  final String fingerprint;
  final DateTime expires;
}

class _UndoEntry {
  _UndoEntry({
    required this.token,
    required this.actingUid,
    required this.date,
    required this.label,
    required this.run,
  });

  final String token;

  /// Who and which day it was done for; undo refuses elsewhere. [date] is
  /// null for an athlete switch (not tied to a day).
  final String actingUid;
  final DateTime? date;
  final String label;
  final Future<AurelianActionResult> Function() run;
}

class AurelianActionService {
  AurelianActionService({
    DateTime Function()? now,
    Random? random,
    this.workoutWait = const Duration(seconds: 10),
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random.secure();

  static final AurelianActionService instance = AurelianActionService();

  static const Duration idempotencyTtl = Duration(minutes: 10);
  static const int idempotencyCapacity = 64;
  static const Duration confirmationTtl = Duration(seconds: 60);
  static const int journalCapacity = 20;

  final DateTime Function() _now;
  final Random _random;
  final Duration workoutWait;

  /// Set by the root bridge scope (inside the membership gate).
  AthleteActionPort? athletePort;

  /// Opens Enter Workout the ordinary way (Home's path) when it is not open.
  WorkoutOpener? openWorkout;

  WorkoutActionPort? _workout;
  final List<Completer<void>> _workoutWaiters = <Completer<void>>[];

  final LinkedHashMap<String, _Cached> _done = LinkedHashMap<String, _Cached>();
  final Map<String, Future<AurelianActionResult>> _running =
      <String, Future<AurelianActionResult>>{};
  final Map<String, _PendingConfirmation> _confirmations =
      <String, _PendingConfirmation>{};
  final List<_UndoEntry> _journal = <_UndoEntry>[];

  /// WES2 registers itself while mounted; returns a handle for [unregisterWorkout].
  Object registerWorkout(WorkoutActionPort port) {
    _workout = port;
    for (final Completer<void> c in List<Completer<void>>.of(_workoutWaiters)) {
      if (!c.isCompleted) c.complete();
    }
    _workoutWaiters.clear();
    return port;
  }

  void unregisterWorkout(Object? handle) {
    if (identical(handle, _workout)) _workout = null;
  }

  /// The workout currently open, if any.
  WorkoutActionPort? get workoutPort => _workout;

  /// Waits (bounded) until an open workout satisfies [test].
  Future<WorkoutActionPort?> waitForWorkout(
      bool Function(WorkoutActionPort) test, Duration timeout) async {
    final DateTime until = _now().add(timeout);
    while (true) {
      final WorkoutActionPort? w = _workout;
      if (w != null && test(w)) return w;
      final Duration left = until.difference(_now());
      if (left <= Duration.zero) return null;
      final Completer<void> next = Completer<void>();
      _workoutWaiters.add(next);
      try {
        await next.future.timeout(left);
      } on TimeoutException {
        return null;
      } finally {
        _workoutWaiters.remove(next);
      }
    }
  }

  // ── Entry points ─────────────────────────────────────────────────────────

  /// Bridge entry: envelope JSON → result JSON (always a well-formed result).
  Future<String> handleJson(String json) async {
    final parsed = parseActionEnvelope(json);
    final EnvelopeError? error = parsed.error;
    if (error != null) {
      return AurelianActionResult.invalid(error.message)
          .encode(error.requestId ?? 'unknown');
    }
    final AurelianActionEnvelope envelope = parsed.envelope!;
    final AurelianActionResult result = await execute(envelope);
    return result.encode(envelope.requestId);
  }

  Future<AurelianActionResult> execute(AurelianActionEnvelope e) async {
    _expire();
    final _Cached? cached = _done[e.idempotencyKey];
    if (cached != null) {
      return cached.fingerprint == e.fingerprint
          ? cached.result
          : const AurelianActionResult.conflict(
              'That request id was already used for something else');
    }
    final Future<AurelianActionResult>? inFlight = _running[e.idempotencyKey];
    if (inFlight != null) return inFlight;

    final Future<AurelianActionResult> run = _guarded(e);
    _running[e.idempotencyKey] = run;
    try {
      final AurelianActionResult result = await run;
      // A failure (timeout, transient error) may be retried with the same key.
      if (result.status != ActionStatus.failure) {
        _done[e.idempotencyKey] = _Cached(e.fingerprint, result, _now());
        while (_done.length > idempotencyCapacity) {
          _done.remove(_done.keys.first);
        }
      }
      return result;
    } finally {
      _running.remove(e.idempotencyKey);
    }
  }

  Future<AurelianActionResult> _guarded(AurelianActionEnvelope e) async {
    try {
      return await _execute(e);
    } catch (_) {
      return const AurelianActionResult.failure('GoodLift could not do that');
    }
  }

  void _expire() {
    final DateTime now = _now();
    _done.removeWhere((_, _Cached c) => now.difference(c.at) > idempotencyTtl);
    _confirmations
        .removeWhere((_, _PendingConfirmation p) => now.isAfter(p.expires));
  }

  // ── Authentication, authorisation, confirmation ──────────────────────────

  Future<AurelianActionResult> _execute(AurelianActionEnvelope e) async {
    final AthleteActionPort? athletes = athletePort;
    if (athletes == null || athletes.actorUid == null) {
      return const AurelianActionResult.unauthorized(
          'Sign in to GoodLift first');
    }

    bool confirmed = false;
    final String? token = e.confirmationToken;
    if (token != null) {
      final _PendingConfirmation? pending = _confirmations.remove(token);
      if (pending == null || pending.fingerprint != e.fingerprint) {
        return const AurelianActionResult.conflict(
            'That confirmation has expired — say it again');
      }
      confirmed = true;
    }

    switch (e.action) {
      case AurelianAction.athleteCurrent:
        return _currentAthlete(athletes);
      case AurelianAction.athleteSwitch:
        return _switchAthlete(e, athletes);
      case AurelianAction.undo:
        return _undo(e.payload.string('undoToken')!, athletes);
      default:
        break;
    }

    // Workout actions act for the session's current athlete: the coach must
    // still be authorised for them right now.
    final String? denied = await _authorisedFor(athletes, athletes.actingUid);
    if (denied != null) return AurelianActionResult.unauthorized(denied);

    final WorkoutActionPort? port = await _ensureWorkout();
    if (port == null) {
      return const AurelianActionResult.failure('The workout did not open');
    }
    final String? blocked = await port.prepare();
    if (blocked != null) {
      return AurelianActionResult(ActionStatus.failure, blocked);
    }
    if (port.actingUid != athletes.actingUid) {
      return const AurelianActionResult.conflict(
          'The open workout belongs to a different athlete');
    }
    return _workoutAction(e, port, athletes, confirmed);
  }

  /// Null when the signed-in account may act on [uid].
  Future<String?> _authorisedFor(AthleteActionPort athletes, String uid) async {
    if (uid == athletes.actorUid) return null;
    if (!athletes.hasCoachMode) {
      return 'Only a coach can act for another athlete';
    }
    final List<AthleteCandidate> roster = await athletes.authorisedAthletes();
    return roster.any((AthleteCandidate c) => c.uid == uid)
        ? null
        : 'You no longer coach this athlete';
  }

  AurelianActionResult _needsConfirmation(
      AurelianActionEnvelope e, String question) {
    final String token = _token();
    _confirmations[token] =
        _PendingConfirmation(e.fingerprint, _now().add(confirmationTtl));
    return AurelianActionResult(ActionStatus.requiresConfirmation, question,
        confirmationToken: token);
  }

  String _token() {
    const String alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(List<int>.generate(
        24, (_) => alphabet.codeUnitAt(_random.nextInt(alphabet.length))));
  }

  Future<WorkoutActionPort?> _ensureWorkout() async {
    final WorkoutActionPort? open = _workout;
    if (open != null) return open;
    final WorkoutOpener? opener = openWorkout;
    if (opener == null) return null;
    final Completer<void> mounted = Completer<void>();
    _workoutWaiters.add(mounted);
    if (!await opener()) {
      _workoutWaiters.remove(mounted);
      return null;
    }
    try {
      if (_workout == null) await mounted.future.timeout(workoutWait);
    } on TimeoutException {
      return null;
    } finally {
      _workoutWaiters.remove(mounted);
    }
    return _workout;
  }

  // ── Undo journal ─────────────────────────────────────────────────────────

  String _journalUndo(String actingUid, DateTime? date, String label,
      Future<AurelianActionResult> Function() run) {
    final String token = _token();
    _journal.add(_UndoEntry(
        token: token,
        actingUid: actingUid,
        date: date,
        label: label,
        run: run));
    while (_journal.length > journalCapacity) {
      _journal.removeAt(0);
    }
    return token;
  }

  Future<AurelianActionResult> _undo(
      String token, AthleteActionPort athletes) async {
    final int at = _journal.indexWhere((_UndoEntry u) => u.token == token);
    if (at == -1) {
      return const AurelianActionResult.notFound('There is nothing to undo');
    }
    if (at != _journal.length - 1) {
      return const AurelianActionResult.conflict('Undo the later change first');
    }
    final _UndoEntry entry = _journal[at];
    if (entry.date != null) {
      if (athletes.actingUid != entry.actingUid) {
        return const AurelianActionResult.conflict(
            'That change was for another athlete');
      }
      final String? denied = await _authorisedFor(athletes, entry.actingUid);
      if (denied != null) return AurelianActionResult.unauthorized(denied);
      final WorkoutActionPort? port = await _ensureWorkout();
      if (port == null) {
        return const AurelianActionResult.failure('The workout did not open');
      }
      final String? blocked = await port.prepare();
      if (blocked != null) {
        return AurelianActionResult(ActionStatus.failure, blocked);
      }
      if (!_sameDay(port.date, entry.date!) ||
          port.actingUid != entry.actingUid) {
        return const AurelianActionResult.conflict(
            'That change was on a different workout');
      }
    }
    final AurelianActionResult result = await entry.run();
    // A refused undo (the state moved on) stays refused; anything else is spent.
    if (result.status != ActionStatus.conflict) _journal.removeAt(at);
    return result;
  }

  // ── Athletes ─────────────────────────────────────────────────────────────

  Future<AurelianActionResult> _currentAthlete(
      AthleteActionPort athletes) async {
    final String acting = athletes.actingUid;
    if (acting == athletes.actorUid) {
      return const AurelianActionResult(
          ActionStatus.success, 'GoodLift is on your own account',
          data: <String, Object?>{'self': true}, verified: true);
    }
    final List<AthleteCandidate> roster = athletes.hasCoachMode
        ? await athletes.authorisedAthletes()
        : <AthleteCandidate>[];
    final AthleteCandidate? c =
        roster.where((AthleteCandidate a) => a.uid == acting).firstOrNull;
    final String label = c?.label ?? 'another athlete';
    return AurelianActionResult(ActionStatus.success, 'GoodLift is on $label',
        data: <String, Object?>{'athlete': label, 'self': false},
        verified: true);
  }

  Future<AurelianActionResult> _switchAthlete(
      AurelianActionEnvelope e, AthleteActionPort athletes) async {
    if (!athletes.hasCoachMode) {
      return const AurelianActionResult.unauthorized(
          'Only coach accounts can switch athlete');
    }
    final List<AthleteCandidate> roster = await athletes.authorisedAthletes();
    final String query = e.payload.string('query')!;
    final AthleteMatch m =
        matchAthlete(query, roster, choices: e.payload.choices);
    if (m.isNone) {
      return AurelianActionResult.notFound(
          'No athlete you coach matches "$query"');
    }
    if (m.isAmbiguous) {
      final List<String> labels = athleteLabels(m.ask).keys.toList();
      return AurelianActionResult.ambiguous(
          labels.length == 1
              ? 'Did you mean ${labels.single}?'
              : 'Which athlete? ${labels.join(', ')}',
          labels);
    }
    final AthleteCandidate target = m.chosen!;
    final String previous = athletes.actingUid;
    if (previous == target.uid) {
      return AurelianActionResult(
          ActionStatus.success, 'Already on ${target.label}',
          data: <String, Object?>{'athlete': target.label}, verified: true);
    }
    final String readBack = await athletes.switchTo(target.uid);
    if (readBack != target.uid) {
      return const AurelianActionResult.failure(
          "GoodLift didn't switch athlete");
    }
    final AthleteCandidate? before =
        roster.where((AthleteCandidate a) => a.uid == previous).firstOrNull;
    final String undo =
        _journalUndo(target.uid, null, 'athlete switch', () async {
      if (athletes.actingUid != target.uid) {
        return const AurelianActionResult.conflict(
            'The athlete has changed since — nothing undone');
      }
      final String? denied = await _authorisedFor(athletes, previous);
      if (denied != null) return AurelianActionResult.unauthorized(denied);
      final String back = await athletes.switchTo(previous);
      if (back != previous) {
        return const AurelianActionResult.failure(
            "GoodLift didn't switch back");
      }
      final String label = before?.label ?? 'the previous athlete';
      return AurelianActionResult(ActionStatus.success, 'Back on $label',
          data: <String, Object?>{'athlete': label}, verified: true);
    });
    return AurelianActionResult(
        ActionStatus.success, 'Switched to ${target.label}',
        data: <String, Object?>{'athlete': target.label},
        undoToken: undo,
        verified: true);
  }

  // ── Workout ──────────────────────────────────────────────────────────────

  Future<AurelianActionResult> _workoutAction(
      AurelianActionEnvelope e,
      WorkoutActionPort port,
      AthleteActionPort athletes,
      bool confirmed) async {
    final ActionPayload p = e.payload;
    switch (e.action) {
      case AurelianAction.workoutOpen:
        return _openDay(port, p.string('date'));
      case AurelianAction.workoutRead:
        return _read(port);
      case AurelianAction.templateLoad:
        return _loadTemplate(e, port, confirmed);
      case AurelianAction.exerciseAdd:
        return _addExercise(
            port, p.string('exercise')!, p.integer('circuit'), p.choices,
            newCircuit: false);
      case AurelianAction.circuitAdd:
        return _addExercise(port, p.string('exercise')!, null, p.choices,
            newCircuit: true);
      case AurelianAction.exerciseDelete:
        return _deleteExercise(e, port, confirmed);
      case AurelianAction.exerciseReplace:
        return _replaceExercise(e, port, confirmed);
      case AurelianAction.exerciseMove:
        return _moveExercise(port, p);
      case AurelianAction.exerciseNote:
        return _exerciseNote(port, p);
      case AurelianAction.exerciseComplete:
        return _complete(port, p);
      case AurelianAction.circuitRename:
        return const AurelianActionResult.unsupported(
            'GoodLift circuits are numbered, not named — there is nothing to rename');
      case AurelianAction.circuitDelete:
        return _deleteCircuit(e, port, confirmed);
      case AurelianAction.setUpdate:
        return _updateSet(port, p);
      case AurelianAction.setNote:
        return _setNote(port, p);
      case AurelianAction.setAdd:
        return _addSet(port, p);
      case AurelianAction.setDelete:
        return _deleteSet(e, port, confirmed);
      case AurelianAction.setClear:
        return _clearSet(port, p);
      case AurelianAction.setCopy:
        return _copySet(e, port, confirmed);
      case AurelianAction.exerciseTimerStart:
        return _startSetTimer(port, p);
      case AurelianAction.exerciseTimerStop:
        return _stopSetTimer(port, p);
      case AurelianAction.generalTimerStart:
        return _generalTimer(port, start: true);
      case AurelianAction.generalTimerStop:
        return _generalTimer(port, start: false);
      case AurelianAction.athleteSwitch:
      case AurelianAction.athleteCurrent:
      case AurelianAction.undo:
        return const AurelianActionResult.invalid('Not a workout action');
    }
  }

  WorkoutExerciseView? _row(WorkoutActionPort port, String exerciseId) =>
      port.exercises
          .where((WorkoutExerciseView r) => r.exerciseId == exerciseId)
          .firstOrNull;

  String _dayLabel(DateTime d) {
    const List<String> days = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun'
    ];
    const List<String> months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<AurelianActionResult> _openDay(
      WorkoutActionPort port, String? iso) async {
    final DateTime now = _now();
    final DateTime day = iso == null
        ? DateTime(now.year, now.month, now.day)
        : DateTime.parse(iso);
    if (!_sameDay(port.date, day)) {
      if (!await port.changeDate(day)) {
        return const AurelianActionResult.failure(
            "GoodLift couldn't open that day");
      }
      final String? blocked = await port.prepare();
      if (blocked != null) {
        return AurelianActionResult(ActionStatus.failure, blocked);
      }
    }
    if (!_sameDay(port.date, day)) {
      return const AurelianActionResult.failure(
          "GoodLift didn't open that day");
    }
    return AurelianActionResult(
        ActionStatus.success, 'Workout for ${_dayLabel(day)} open',
        data: <String, Object?>{
          'date': isoDate(day),
          'exercises': port.exercises.length
        },
        verified: true);
  }

  AurelianActionResult _read(WorkoutActionPort port) {
    final List<WorkoutExerciseView> rows = port.exercises;
    final String? target = port.targetExerciseId;
    final List<Map<String, Object?>> list = <Map<String, Object?>>[
      for (final WorkoutExerciseView r in rows.take(20))
        <String, Object?>{
          'name': r.name,
          'circuit': r.circuitIndex + 1,
          'sets': r.setCount,
          'logged': r.sets.where((WorkoutSetView s) => s.hasValues).length,
          'done': r.done,
          if (r.timed) 'timed': true,
          if (r.exerciseId == target) 'current': true,
        },
    ];
    final String summary = rows.isEmpty
        ? 'No exercises on ${_dayLabel(port.date)} yet'
        : '${rows.length} ${rows.length == 1 ? 'exercise' : 'exercises'} on ${_dayLabel(port.date)}';
    return AurelianActionResult(ActionStatus.success, summary,
        data: <String, Object?>{
          'date': isoDate(port.date),
          'exercises': list,
          'timer': port.generalTimer.running ? 'running' : 'stopped',
        },
        verified: true);
  }

  /// The exercise an action names, or the current voice target when none.
  ({WorkoutExerciseView? row, AurelianActionResult? answer}) _target(
      WorkoutActionPort port, String? spoken, List<String> choices,
      {required bool destructive}) {
    final List<WorkoutExerciseView> rows = port.exercises;
    if (rows.isEmpty) {
      return (
        row: null,
        answer: const AurelianActionResult.notFound(
            'There are no exercises in this workout yet')
      );
    }
    if (spoken == null) {
      final String? id = port.targetExerciseId;
      final WorkoutExerciseView row =
          id == null ? rows.first : _row(port, id) ?? rows.first;
      return (row: row, answer: null);
    }
    final ExerciseResolution<WorkoutExerciseView> r =
        resolveExercise<WorkoutExerciseView>(
      spoken,
      rows,
      nameOf: (WorkoutExerciseView x) => x.name,
      idOf: (WorkoutExerciseView x) => x.exerciseId,
      usage: destructive ? const <String, int>{} : port.exerciseUsage(),
      choices: choices,
      allowFuzzy: !destructive,
      useHistory: !destructive,
    );
    if (r.isAmbiguous) {
      return (
        row: null,
        answer: AurelianActionResult.ambiguous(
            'Which $spoken?', r.ask.map((WorkoutExerciseView x) => x.name)),
      );
    }
    if (r.chosen == null) {
      return (
        row: null,
        answer:
            AurelianActionResult.notFound('"$spoken" isn\'t in this workout')
      );
    }
    if (!destructive) port.setTarget(r.chosen!.exerciseId);
    return (row: r.chosen, answer: null);
  }

  AurelianActionResult _noSuchSet(WorkoutExerciseView row, int n) =>
      AurelianActionResult.invalid(
          '${row.name} has ${row.setCount} ${row.setCount == 1 ? 'set' : 'sets'} — say "add a set" for set $n');

  // ── Templates ────────────────────────────────────────────────────────────

  Future<AurelianActionResult> _loadTemplate(
      AurelianActionEnvelope e, WorkoutActionPort port, bool confirmed) async {
    final List<TemplateEntry>? all = await port.templates();
    if (all == null) {
      return const AurelianActionResult.failure('Could not load templates');
    }
    if (all.isEmpty) {
      return const AurelianActionResult.notFound(
          'There are no templates to load');
    }
    final String? spoken = e.payload.string('template');
    final ({TemplateEntry? chosen, List<TemplateEntry> ask}) pick =
        spoken == null
            ? selectTodaysTemplate(all, port.blockDayNumber(), port.date)
            : _templateNamed(spoken, all);
    if (pick.ask.isNotEmpty) {
      final List<TemplateEntry> ask = pick.ask;
      for (final String choice in e.payload.choices) {
        final List<TemplateEntry> hit =
            ask.where((TemplateEntry t) => t.name == choice).toList();
        if (hit.length == 1) {
          return _applyTemplate(e, port, hit.single, confirmed);
        }
      }
      return AurelianActionResult.ambiguous(
          ask.length == 1 ? 'Load ${ask.single.name}?' : 'Which template?',
          ask.map((TemplateEntry t) => t.name));
    }
    final TemplateEntry? chosen = pick.chosen;
    if (chosen == null) {
      return AurelianActionResult.notFound(spoken == null
          ? 'No template matches today'
          : 'No template called "$spoken"');
    }
    return _applyTemplate(e, port, chosen, confirmed);
  }

  ({TemplateEntry? chosen, List<TemplateEntry> ask}) _templateNamed(
      String spoken, List<TemplateEntry> all) {
    final ExerciseMatch<TemplateEntry> m =
        matchExercise<TemplateEntry>(spoken, all, (TemplateEntry t) => t.name);
    if (m.isUnique) return (chosen: m.single, ask: const <TemplateEntry>[]);
    if (m.isNone) return (chosen: null, ask: const <TemplateEntry>[]);
    final List<TemplateEntry> active =
        m.matches.where((TemplateEntry t) => t.inActiveBlock).toList();
    if (active.length == 1) {
      return (chosen: active.single, ask: const <TemplateEntry>[]);
    }
    return (chosen: null, ask: m.matches);
  }

  Future<AurelianActionResult> _applyTemplate(AurelianActionEnvelope e,
      WorkoutActionPort port, TemplateEntry template, bool confirmed) async {
    final List<WorkoutExerciseView> before = port.exercises;
    final bool populated =
        before.any((WorkoutExerciseView r) => r.hasLoggedData);
    if (populated && !confirmed) {
      return _needsConfirmation(e,
          'This workout has logged data. Loading ${template.name} replaces it — say yes to replace it');
    }
    final String? error = await port.loadTemplate(template.id);
    if (error != null) return AurelianActionResult.failure(error);
    final List<WorkoutExerciseView> after = port.exercises;
    if (after.isEmpty) {
      return const AurelianActionResult.failure("The template didn't load");
    }
    final DateTime day = port.date;
    final String acting = port.actingUid;
    // Undo only re-creates what was there when nothing had been logged: never a
    // snapshot rewrite over values entered since.
    String? undo;
    if (!populated) {
      final List<({String id, String name, int circuit})> prior =
          <({String id, String name, int circuit})>[
        for (final WorkoutExerciseView r in before)
          (id: r.exerciseId, name: r.name, circuit: r.circuitIndex),
      ];
      final Set<String> loaded =
          after.map((WorkoutExerciseView r) => r.exerciseId).toSet();
      undo = _journalUndo(acting, day, 'template load', () async {
        final List<WorkoutExerciseView> now = port.exercises;
        if (now.any((WorkoutExerciseView r) =>
            loaded.contains(r.exerciseId) && r.hasLoggedData)) {
          return const AurelianActionResult.conflict(
              'Values were logged since — nothing undone');
        }
        for (final WorkoutExerciseView r in now) {
          if (loaded.contains(r.exerciseId) &&
              !prior.any((x) => x.id == r.exerciseId)) {
            await port.deleteExercise(r.exerciseId);
          }
        }
        for (final x in prior) {
          if (_row(port, x.id) == null) {
            await port.addExercise(
                CatalogueEntry(id: x.id, name: x.name), x.circuit);
          }
        }
        final Set<String> ids =
            port.exercises.map((WorkoutExerciseView r) => r.exerciseId).toSet();
        final bool ok = prior.every((x) => ids.contains(x.id)) &&
            loaded
                .where((String id) => !prior.any((x) => x.id == id))
                .every((String id) => !ids.contains(id));
        return ok
            ? const AurelianActionResult(
                ActionStatus.success, 'Template removed', verified: true)
            : const AurelianActionResult.failure(
                'The template could not be fully removed');
      });
    }
    return AurelianActionResult(ActionStatus.success,
        '${template.name} loaded · ${after.length} exercises',
        data: <String, Object?>{
          'template': template.name,
          'exercises': after.length
        },
        undoToken: undo,
        verified: true);
  }

  // ── Exercises ────────────────────────────────────────────────────────────

  Future<({CatalogueEntry? entry, AurelianActionResult? answer})>
      _fromCatalogue(
          WorkoutActionPort port, String spoken, List<String> choices,
          {Set<String> exclude = const <String>{}, bool fuzzy = true}) async {
    final List<CatalogueEntry>? all = await port.catalogue();
    if (all == null) {
      return (
        entry: null,
        answer: const AurelianActionResult.failure('Could not load exercises')
      );
    }
    final List<CatalogueEntry> available =
        all.where((CatalogueEntry c) => !exclude.contains(c.id)).toList();
    final ExerciseResolution<CatalogueEntry> r =
        resolveExercise<CatalogueEntry>(
      spoken,
      available,
      nameOf: (CatalogueEntry c) => c.name,
      idOf: (CatalogueEntry c) => c.id,
      labelOf: (CatalogueEntry c) => c.display,
      usage: port.exerciseUsage(),
      choices: choices,
      allowFuzzy: fuzzy,
    );
    if (r.isAmbiguous) {
      return (
        entry: null,
        answer: AurelianActionResult.ambiguous(
            'Which $spoken?', r.ask.map((CatalogueEntry c) => c.display)),
      );
    }
    if (r.chosen == null) {
      final ExerciseResolution<CatalogueEntry> already =
          resolveExercise<CatalogueEntry>(spoken,
              all.where((CatalogueEntry c) => exclude.contains(c.id)).toList(),
              nameOf: (CatalogueEntry c) => c.name,
              idOf: (CatalogueEntry c) => c.id);
      return (
        entry: null,
        answer: already.chosen != null
            ? AurelianActionResult.invalid(
                '${already.chosen!.name} is already in this workout')
            : AurelianActionResult.notFound('No exercise called "$spoken"'),
      );
    }
    return (entry: r.chosen, answer: null);
  }

  Future<AurelianActionResult> _addExercise(
      WorkoutActionPort port, String spoken, int? circuit, List<String> choices,
      {required bool newCircuit}) async {
    final List<WorkoutExerciseView> rows = port.exercises;
    final Set<int> circuits =
        rows.map((WorkoutExerciseView r) => r.circuitIndex).toSet();
    final int next = circuits.isEmpty ? 0 : circuits.reduce(max) + 1;
    final int ci = newCircuit ? next : (circuit == null ? 0 : circuit - 1);
    if (!newCircuit &&
        circuit != null &&
        !circuits.contains(ci) &&
        ci != next) {
      return AurelianActionResult.invalid(
          'There is no circuit $circuit yet — the next new one is circuit ${next + 1}');
    }
    final found = await _fromCatalogue(port, spoken, choices,
        exclude: rows.map((WorkoutExerciseView r) => r.exerciseId).toSet());
    if (found.answer != null) return found.answer!;
    final CatalogueEntry entry = found.entry!;
    await port.addExercise(entry, ci);
    final WorkoutExerciseView? added = _row(port, entry.id);
    if (added == null || added.circuitIndex != ci) {
      return const AurelianActionResult.failure("GoodLift didn't add it");
    }
    port.setTarget(entry.id);
    final String undo =
        _journalUndo(port.actingUid, port.date, 'add exercise', () async {
      final WorkoutExerciseView? now = _row(port, entry.id);
      if (now == null) {
        return const AurelianActionResult.conflict(
            'It was already removed — nothing undone');
      }
      if (now.hasLoggedData) {
        return const AurelianActionResult.conflict(
            'Values were logged on it since — nothing undone');
      }
      await port.deleteExercise(entry.id);
      return _row(port, entry.id) == null
          ? AurelianActionResult(ActionStatus.success, 'Removed ${entry.name}',
              verified: true)
          : const AurelianActionResult.failure("GoodLift didn't remove it");
    });
    return AurelianActionResult(
        ActionStatus.success, 'Added ${entry.name} to circuit ${ci + 1}',
        data: <String, Object?>{'exercise': entry.name, 'circuit': ci + 1},
        undoToken: undo,
        verified: true);
  }

  /// Puts back a removed exercise and replays what it held, through the
  /// ordinary add, add-set, typed-entry, note and Done paths.
  Future<bool> _restoreExercise(
      WorkoutActionPort port, WorkoutExerciseView old) async {
    if (_row(port, old.exerciseId) == null) {
      await port.addExercise(
          CatalogueEntry(id: old.exerciseId, name: old.name), old.circuitIndex);
    }
    return _replay(port, old);
  }

  Future<bool> _replay(WorkoutActionPort port, WorkoutExerciseView old) async {
    WorkoutExerciseView? now = _row(port, old.exerciseId);
    if (now == null) return false;
    for (int guard = 0;
        now!.setCount < old.setCount && guard < kActionMaxSet;
        guard++) {
      await port.addSet(old.exerciseId);
      now = _row(port, old.exerciseId);
      if (now == null) return false;
    }
    for (final WorkoutSetView s in old.sets) {
      final List<FieldEdit> edits = _editsFor(s);
      if (edits.isNotEmpty) {
        await port.setFields(old.exerciseId, s.index, edits);
      }
      if (s.hasNote) await port.setNote(old.exerciseId, s.index, s.note);
    }
    if (old.note?.trim().isNotEmpty == true) {
      await port.exerciseNote(old.exerciseId, old.note);
    }
    if (old.done) await port.setCompleted(old.exerciseId, true);
    final WorkoutExerciseView? back = _row(port, old.exerciseId);
    return back != null &&
        old.sets.every((WorkoutSetView s) => _sameValues(back.set(s.index), s));
  }

  Future<AurelianActionResult> _deleteExercise(
      AurelianActionEnvelope e, WorkoutActionPort port, bool confirmed) async {
    final t = _target(port, e.payload.string('exercise'), e.payload.choices,
        destructive: true);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    if (row.hasLoggedData && !confirmed) {
      return _needsConfirmation(
          e, '${row.name} has logged values. Delete it? Say yes to delete');
    }
    await port.deleteExercise(row.exerciseId);
    if (_row(port, row.exerciseId) != null) {
      return const AurelianActionResult.failure("GoodLift didn't delete it");
    }
    final String undo =
        _journalUndo(port.actingUid, port.date, 'delete exercise', () async {
      if (_row(port, row.exerciseId) != null) {
        return const AurelianActionResult.conflict(
            'It is back in the workout already — nothing undone');
      }
      return await _restoreExercise(port, row)
          ? AurelianActionResult(ActionStatus.success, 'Restored ${row.name}',
              verified: true)
          : AurelianActionResult.failure(
              '${row.name} could only be partly restored');
    });
    return AurelianActionResult(ActionStatus.success, 'Deleted ${row.name}',
        data: <String, Object?>{'exercise': row.name},
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _replaceExercise(
      AurelianActionEnvelope e, WorkoutActionPort port, bool confirmed) async {
    final t = _target(port, e.payload.string('exercise'), e.payload.choices,
        destructive: true);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final Set<String> others = port.exercises
        .map((WorkoutExerciseView r) => r.exerciseId)
        .where((String id) => id != row.exerciseId)
        .toSet();
    final found = await _fromCatalogue(
        port, e.payload.string('replacement')!, e.payload.choices,
        exclude: others, fuzzy: false);
    if (found.answer != null) return found.answer!;
    final CatalogueEntry entry = found.entry!;
    if (entry.id == row.exerciseId) {
      return AurelianActionResult(
          ActionStatus.success, '${row.name} is already there',
          verified: true);
    }
    if (row.hasLoggedData && !confirmed) {
      return _needsConfirmation(e,
          '${row.name} has logged values that replacing it removes. Replace it with ${entry.name}? Say yes to replace');
    }
    await port.replaceExercise(row.exerciseId, entry);
    final WorkoutExerciseView? now = _row(port, entry.id);
    if (now == null || _row(port, row.exerciseId) != null) {
      return const AurelianActionResult.failure("GoodLift didn't replace it");
    }
    port.setTarget(entry.id);
    final String undo =
        _journalUndo(port.actingUid, port.date, 'replace exercise', () async {
      final WorkoutExerciseView? current = _row(port, entry.id);
      if (current == null || _row(port, row.exerciseId) != null) {
        return const AurelianActionResult.conflict(
            'The workout changed since — nothing undone');
      }
      if (current.hasLoggedData) {
        return const AurelianActionResult.conflict(
            'Values were logged since — nothing undone');
      }
      await port.replaceExercise(
          entry.id, CatalogueEntry(id: row.exerciseId, name: row.name));
      return await _replay(port, row)
          ? AurelianActionResult(ActionStatus.success, '${row.name} is back',
              verified: true)
          : AurelianActionResult.failure(
              '${row.name} could only be partly restored');
    });
    return AurelianActionResult(
        ActionStatus.success, 'Replaced ${row.name} with ${entry.name}',
        data: <String, Object?>{'exercise': entry.name, 'replaced': row.name},
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _moveExercise(
      WorkoutActionPort port, ActionPayload p) async {
    final t = _target(port, p.string('exercise'), p.choices, destructive: true);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final int circuit = p.integer('circuit')!;
    final int ci = circuit - 1;
    if (row.circuitIndex == ci) {
      return AurelianActionResult(
          ActionStatus.success, '${row.name} is already in circuit $circuit',
          verified: true);
    }
    final Set<int> circuits =
        port.exercises.map((WorkoutExerciseView r) => r.circuitIndex).toSet();
    final int next = circuits.reduce(max) + 1;
    if (!circuits.contains(ci) && ci != next) {
      return AurelianActionResult.invalid(
          'There is no circuit $circuit — the next new one is circuit ${next + 1}');
    }
    final int from = row.circuitIndex;
    await port.moveExercise(row.exerciseId, ci);
    if (_row(port, row.exerciseId)?.circuitIndex != ci) {
      return const AurelianActionResult.failure("GoodLift didn't move it");
    }
    port.setTarget(row.exerciseId);
    final String undo =
        _journalUndo(port.actingUid, port.date, 'move exercise', () async {
      final WorkoutExerciseView? now = _row(port, row.exerciseId);
      if (now == null || now.circuitIndex != ci) {
        return const AurelianActionResult.conflict(
            'It was moved again since — nothing undone');
      }
      await port.moveExercise(row.exerciseId, from);
      return _row(port, row.exerciseId)?.circuitIndex == from
          ? AurelianActionResult(
              ActionStatus.success, '${row.name} back in circuit ${from + 1}',
              verified: true)
          : const AurelianActionResult.failure("GoodLift didn't move it back");
    });
    return AurelianActionResult(
        ActionStatus.success, '${row.name} moved to circuit $circuit',
        data: <String, Object?>{'exercise': row.name, 'circuit': circuit},
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _exerciseNote(
      WorkoutActionPort port, ActionPayload p) async {
    final t =
        _target(port, p.string('exercise'), p.choices, destructive: false);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final String text = p.string('text')!;
    final String? before = row.note;
    await port.exerciseNote(row.exerciseId, text);
    if (_row(port, row.exerciseId)?.note?.trim() != text) {
      return const AurelianActionResult.failure(
          "GoodLift didn't save the note");
    }
    final String undo =
        _journalUndo(port.actingUid, port.date, 'exercise note', () async {
      if (_row(port, row.exerciseId)?.note?.trim() != text) {
        return const AurelianActionResult.conflict(
            'The note was changed since — nothing undone');
      }
      await port.exerciseNote(row.exerciseId, before);
      return AurelianActionResult(
          ActionStatus.success, 'Note on ${row.name} restored',
          verified: true);
    });
    return AurelianActionResult(
        ActionStatus.success, 'Note added to ${row.name}',
        data: <String, Object?>{'exercise': row.name, 'note': text},
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _complete(
      WorkoutActionPort port, ActionPayload p) async {
    final t =
        _target(port, p.string('exercise'), p.choices, destructive: false);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final bool done = p.boolean('completed')!;
    final String word = done ? 'completed' : 'not completed';
    if (row.done == done) {
      return AurelianActionResult(
          ActionStatus.success, '${row.name} is already $word',
          verified: true);
    }
    if (done && !row.hasSetValues) {
      return AurelianActionResult.invalid(
          'Log a set of ${row.name} before marking it completed');
    }
    await port.setCompleted(row.exerciseId, done);
    if (_row(port, row.exerciseId)?.done != done) {
      return const AurelianActionResult.failure("GoodLift didn't change it");
    }
    final String undo =
        _journalUndo(port.actingUid, port.date, 'completion', () async {
      if (_row(port, row.exerciseId)?.done != done) {
        return const AurelianActionResult.conflict(
            'It was changed since — nothing undone');
      }
      await port.setCompleted(row.exerciseId, !done);
      return AurelianActionResult(ActionStatus.success,
          '${row.name} marked ${done ? 'not completed' : 'completed'}',
          verified: true);
    });
    return AurelianActionResult(
        ActionStatus.success, '${row.name} marked $word',
        data: <String, Object?>{'exercise': row.name, 'completed': done},
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _deleteCircuit(
      AurelianActionEnvelope e, WorkoutActionPort port, bool confirmed) async {
    final int circuit = e.payload.integer('circuit')!;
    final List<WorkoutExerciseView> rows = port.exercises
        .where((WorkoutExerciseView r) => r.circuitIndex == circuit - 1)
        .toList();
    if (rows.isEmpty) {
      return AurelianActionResult.notFound('There is no circuit $circuit');
    }
    if (rows.any((WorkoutExerciseView r) => r.hasLoggedData) && !confirmed) {
      return _needsConfirmation(e,
          'Circuit $circuit has logged values. Delete all ${rows.length} of its exercises? Say yes to delete');
    }
    for (final WorkoutExerciseView r in rows) {
      await port.deleteExercise(r.exerciseId);
    }
    if (rows.any((WorkoutExerciseView r) => _row(port, r.exerciseId) != null)) {
      return const AurelianActionResult.failure(
          "GoodLift didn't delete the whole circuit");
    }
    final String undo =
        _journalUndo(port.actingUid, port.date, 'delete circuit', () async {
      if (rows
          .any((WorkoutExerciseView r) => _row(port, r.exerciseId) != null)) {
        return const AurelianActionResult.conflict(
            'The workout changed since — nothing undone');
      }
      bool ok = true;
      for (final WorkoutExerciseView r in rows) {
        ok = await _restoreExercise(port, r) && ok;
      }
      return ok
          ? AurelianActionResult(
              ActionStatus.success, 'Circuit $circuit restored', verified: true)
          : AurelianActionResult.failure(
              'Circuit $circuit could only be partly restored');
    });
    return AurelianActionResult(ActionStatus.success,
        'Deleted circuit $circuit (${rows.length} exercises)',
        data: <String, Object?>{'circuit': circuit, 'exercises': rows.length},
        undoToken: undo,
        verified: true);
  }

  // ── Sets ─────────────────────────────────────────────────────────────────

  static String _num(double v) => formatWeightNumber(v, maxDecimals: 6);

  /// The edits that write [s]'s values (canonical kilogram text for weight).
  static List<FieldEdit> _editsFor(WorkoutSetView s) => <FieldEdit>[
        if (s.weightKg != null)
          FieldEdit(Wes2FieldKey.weight, _num(s.weightKg!)),
        if (s.reps != null) FieldEdit(Wes2FieldKey.reps, '${s.reps}'),
        if (s.rir != null) FieldEdit(Wes2FieldKey.rir, _num(s.rir!)),
        if (s.velocity != null)
          FieldEdit(Wes2FieldKey.velocity, _num(s.velocity!)),
      ];

  static bool _equal(Object? a, Object? b) {
    if (a == null || b == null) return a == b;
    if (a is num && b is num) return (a - b).abs() < 1e-6;
    return a == b;
  }

  static bool _sameValues(WorkoutSetView a, WorkoutSetView b) =>
      Wes2FieldKey.values
          .every((Wes2FieldKey k) => _equal(a.valueOf(k), b.valueOf(k)));

  /// The value [text] stands for in the read model ('' = cleared).
  static Object? _expected(Wes2FieldKey key, String text) {
    if (text.isEmpty) return null;
    return key == Wes2FieldKey.reps
        ? int.tryParse(text)
        : double.tryParse(text);
  }

  /// Writes [edits] and journals an undo that restores the previous values only
  /// while every field still holds what was written.
  Future<AurelianActionResult> _writeSet(
      WorkoutActionPort port,
      WorkoutExerciseView row,
      int setIndex,
      List<FieldEdit> edits,
      String summary,
      String label) async {
    final WorkoutSetView before = row.set(setIndex);
    await port.setFields(row.exerciseId, setIndex, edits);
    final WorkoutExerciseView? now = _row(port, row.exerciseId);
    if (now == null) {
      return const AurelianActionResult.failure('The exercise disappeared');
    }
    final WorkoutSetView after = now.set(setIndex);
    for (final FieldEdit edit in edits) {
      if (!_equal(after.valueOf(edit.key), _expected(edit.key, edit.text))) {
        return const AurelianActionResult.failure(
            "GoodLift didn't keep that value");
      }
    }
    final String undo =
        _journalUndo(port.actingUid, port.date, label, () async {
      final WorkoutExerciseView? current = _row(port, row.exerciseId);
      if (current == null || current.setCount <= setIndex) {
        return const AurelianActionResult.conflict(
            'The set is gone — nothing undone');
      }
      final WorkoutSetView s = current.set(setIndex);
      if (edits.any(
          (FieldEdit e) => !_equal(s.valueOf(e.key), after.valueOf(e.key)))) {
        return const AurelianActionResult.conflict(
            'The set was changed since — nothing undone');
      }
      final List<FieldEdit> back = <FieldEdit>[
        for (final FieldEdit e in edits)
          FieldEdit(
              e.key,
              switch (before.valueOf(e.key)) {
                null => '',
                final int v => '$v',
                final double v => _num(v),
                _ => '',
              }),
      ];
      await port.setFields(row.exerciseId, setIndex, back);
      final WorkoutSetView restored =
          _row(port, row.exerciseId)?.set(setIndex) ??
              WorkoutSetView(index: setIndex);
      return edits.every((FieldEdit e) =>
              _equal(restored.valueOf(e.key), before.valueOf(e.key)))
          ? AurelianActionResult(ActionStatus.success,
              '${row.name} · set ${setIndex + 1} restored',
              verified: true)
          : const AurelianActionResult.failure('The set could not be restored');
    });
    return AurelianActionResult(ActionStatus.success, '${row.name} · $summary',
        data: _setData(row, now, setIndex), undoToken: undo, verified: true);
  }

  Map<String, Object?> _setData(
      WorkoutExerciseView row, WorkoutExerciseView now, int setIndex) {
    final WorkoutSetView s = now.set(setIndex);
    return <String, Object?>{
      'exercise': row.name,
      'set': setIndex + 1,
      'unit': row.unit.suffix,
      if (s.weightKg != null)
        'weight':
            double.parse(formatWeightNumber(row.unit.fromKg(s.weightKg!))),
      if (s.reps != null) 'reps': s.reps,
      if (s.rir != null) 'rir': s.rir,
      if (s.velocity != null) 'velocity': s.velocity,
    };
  }

  Future<AurelianActionResult> _updateSet(
      WorkoutActionPort port, ActionPayload p) async {
    final t =
        _target(port, p.string('exercise'), p.choices, destructive: false);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final int n = p.integer('set')!;
    final String? unit = p.string('unit');
    // The same validation and unit conversion as the voice and typed paths.
    final SetEntryPlan plan = planSetEntry(
      AurelianCommand(
        AurelianCommandKind.setFields,
        setNumber: n,
        weight: p.number('weight'),
        weightUnit: unit == null ? null : ExerciseWeightUnit.parseOrNull(unit),
        reps: p.integer('reps'),
        rir: p.number('rir'),
        velocity: p.number('velocity'),
      ),
      exerciseName: row.name,
      setCount: row.setCount,
      displayUnit: row.unit,
      velocityShown: row.velocityShown,
      normalEntry: !row.timed,
    );
    if (!plan.isValid) return AurelianActionResult.invalid(plan.error!);
    return _writeSet(
        port,
        row,
        plan.setIndex,
        <FieldEdit>[
          for (final SetFieldEdit e in plan.edits) FieldEdit(e.fieldKey, e.text)
        ],
        plan.summary,
        'set change');
  }

  Future<AurelianActionResult> _setNote(
      WorkoutActionPort port, ActionPayload p) async {
    final t =
        _target(port, p.string('exercise'), p.choices, destructive: false);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final int n = p.integer('set')!;
    if (n > row.setCount) return _noSuchSet(row, n);
    final String text = p.string('text')!;
    final String? before = row.set(n - 1).note;
    await port.setNote(row.exerciseId, n - 1, text);
    if (_row(port, row.exerciseId)?.set(n - 1).note?.trim() != text) {
      return const AurelianActionResult.failure(
          "GoodLift didn't save the note");
    }
    final String undo =
        _journalUndo(port.actingUid, port.date, 'set note', () async {
      if (_row(port, row.exerciseId)?.set(n - 1).note?.trim() != text) {
        return const AurelianActionResult.conflict(
            'The note was changed since — nothing undone');
      }
      await port.setNote(row.exerciseId, n - 1, before);
      return AurelianActionResult(
          ActionStatus.success, '${row.name} · set $n note restored',
          verified: true);
    });
    return AurelianActionResult(
        ActionStatus.success, '${row.name} · set $n note saved',
        data: <String, Object?>{'exercise': row.name, 'set': n, 'note': text},
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _addSet(
      WorkoutActionPort port, ActionPayload p) async {
    final t =
        _target(port, p.string('exercise'), p.choices, destructive: false);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final int count = row.setCount;
    await port.addSet(row.exerciseId);
    final WorkoutExerciseView? now = _row(port, row.exerciseId);
    if (now == null || now.setCount != count + 1) {
      return const AurelianActionResult.failure("GoodLift didn't add the set");
    }
    final String? undo = row.bb3Planned
        ? null // GoodLift cannot remove sets from BB3-planned rows yet.
        : _journalUndo(port.actingUid, port.date, 'add set', () async {
            final WorkoutExerciseView? current = _row(port, row.exerciseId);
            if (current == null ||
                current.setCount != count + 1 ||
                !current.set(count).isEmpty) {
              return const AurelianActionResult.conflict(
                  'The set was used since — nothing undone');
            }
            await port.removeSet(row.exerciseId, count);
            return _row(port, row.exerciseId)?.setCount == count
                ? AurelianActionResult(ActionStatus.success,
                    '${row.name} · set ${count + 1} removed', verified: true)
                : const AurelianActionResult.failure(
                    "GoodLift didn't remove the set");
          });
    return AurelianActionResult(
        ActionStatus.success, '${row.name} · set ${count + 1} added',
        data: <String, Object?>{'exercise': row.name, 'sets': count + 1},
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _deleteSet(
      AurelianActionEnvelope e, WorkoutActionPort port, bool confirmed) async {
    final t = _target(port, e.payload.string('exercise'), e.payload.choices,
        destructive: true);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final int n = e.payload.integer('set')!;
    if (row.bb3Planned) {
      return const AurelianActionResult.unsupported(
          "Removing sets from BB3 planned exercises isn't available yet");
    }
    if (n > row.setCount) return _noSuchSet(row, n);
    if (row.setCount <= 1) {
      return AurelianActionResult.invalid(
          "That's the only set — say \"delete ${row.name}\" to remove the exercise");
    }
    final WorkoutSetView set = row.set(n - 1);
    // GoodLift's own Remove Set confirms only when the set has logged values.
    if (set.hasValues && !confirmed) {
      return _needsConfirmation(e,
          'Set $n of ${row.name} has logged values. Remove it? Say yes to remove');
    }
    final int count = row.setCount;
    await port.removeSet(row.exerciseId, n - 1);
    if (_row(port, row.exerciseId)?.setCount != count - 1) {
      return const AurelianActionResult.failure(
          "GoodLift didn't remove the set");
    }
    // Only the LAST set can be put back exactly where it was (a middle set's
    // successors were renumbered); otherwise GoodLift's own Undo applies.
    final String? undo = n != count
        ? null
        : _journalUndo(port.actingUid, port.date, 'delete set', () async {
            final WorkoutExerciseView? current = _row(port, row.exerciseId);
            if (current == null || current.setCount != count - 1) {
              return const AurelianActionResult.conflict(
                  'The sets changed since — nothing undone');
            }
            await port.addSet(row.exerciseId);
            final List<FieldEdit> edits = _editsFor(set);
            if (edits.isNotEmpty) {
              await port.setFields(row.exerciseId, n - 1, edits);
            }
            if (set.hasNote) {
              await port.setNote(row.exerciseId, n - 1, set.note);
            }
            final WorkoutExerciseView? back = _row(port, row.exerciseId);
            return back != null &&
                    back.setCount == count &&
                    _sameValues(back.set(n - 1), set)
                ? AurelianActionResult(
                    ActionStatus.success, '${row.name} · set $n restored',
                    verified: true)
                : const AurelianActionResult.failure(
                    'The set could not be restored');
          });
    return AurelianActionResult(
        ActionStatus.success,
        undo == null
            ? '${row.name} · set $n removed (use GoodLift\'s Undo to bring it back)'
            : '${row.name} · set $n removed',
        data: <String, Object?>{'exercise': row.name, 'sets': count - 1},
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _clearSet(
      WorkoutActionPort port, ActionPayload p) async {
    final t = _target(port, p.string('exercise'), p.choices, destructive: true);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final int n = p.integer('set')!;
    if (n > row.setCount) return _noSuchSet(row, n);
    final WorkoutSetView s = row.set(n - 1);
    final List<FieldEdit> edits = <FieldEdit>[
      for (final Wes2FieldKey k in Wes2FieldKey.values)
        if (s.valueOf(k) != null) FieldEdit(k, ''),
    ];
    if (edits.isEmpty) {
      return AurelianActionResult(
          ActionStatus.success, '${row.name} · set $n is already empty',
          verified: true);
    }
    return _writeSet(port, row, n - 1, edits, 'set $n cleared', 'clear set');
  }

  Future<AurelianActionResult> _copySet(
      AurelianActionEnvelope e, WorkoutActionPort port, bool confirmed) async {
    final t = _target(port, e.payload.string('exercise'), e.payload.choices,
        destructive: false);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    final int from = e.payload.integer('set')!;
    if (from > row.setCount) return _noSuchSet(row, from);
    final WorkoutSetView source = row.set(from - 1);
    final List<FieldEdit> edits = _editsFor(source);
    if (edits.isEmpty) {
      return AurelianActionResult.invalid(
          'Set $from of ${row.name} has no values to copy');
    }
    final int? to = e.payload.integer('toSet');
    if (to != null) {
      if (to == from) {
        return const AurelianActionResult.invalid('That is the same set');
      }
      if (to > row.setCount) return _noSuchSet(row, to);
      if (row.set(to - 1).hasValues && !confirmed) {
        return _needsConfirmation(e,
            'Set $to already has values. Overwrite it with set $from? Say yes to overwrite');
      }
      // Fields the source lacks are cleared so the copy is exact.
      final List<FieldEdit> exact = <FieldEdit?>[
        for (final Wes2FieldKey k in Wes2FieldKey.values)
          edits.where((FieldEdit x) => x.key == k).firstOrNull ??
              (row.set(to - 1).valueOf(k) != null ? FieldEdit(k, '') : null),
      ].whereType<FieldEdit>().toList();
      return _writeSet(
          port, row, to - 1, exact, 'set $from copied to set $to', 'copy set');
    }
    // No target: a new set holding the copy (one undo removes it again).
    final int count = row.setCount;
    await port.addSet(row.exerciseId);
    final WorkoutExerciseView? grown = _row(port, row.exerciseId);
    if (grown == null || grown.setCount != count + 1) {
      return const AurelianActionResult.failure("GoodLift didn't add the set");
    }
    await port.setFields(row.exerciseId, count, edits);
    final WorkoutExerciseView? now = _row(port, row.exerciseId);
    if (now == null ||
        !_sameValues(
            now.set(count),
            WorkoutSetView(
                index: count,
                weightKg: source.weightKg,
                reps: source.reps,
                rir: source.rir,
                velocity: source.velocity))) {
      return const AurelianActionResult.failure(
          "GoodLift didn't keep the copied values");
    }
    final WorkoutSetView written = now.set(count);
    final String? undo = row.bb3Planned
        ? null
        : _journalUndo(port.actingUid, port.date, 'copy set', () async {
            final WorkoutExerciseView? current = _row(port, row.exerciseId);
            if (current == null ||
                current.setCount != count + 1 ||
                !_sameValues(current.set(count), written) ||
                current.set(count).hasNote) {
              return const AurelianActionResult.conflict(
                  'The new set was changed since — nothing undone');
            }
            await port.removeSet(row.exerciseId, count);
            return _row(port, row.exerciseId)?.setCount == count
                ? AurelianActionResult(
                    ActionStatus.success, 'Copied set removed', verified: true)
                : const AurelianActionResult.failure(
                    "GoodLift didn't remove the set");
          });
    return AurelianActionResult(ActionStatus.success,
        '${row.name} · set $from copied to new set ${count + 1}',
        data: _setData(row, now, count), undoToken: undo, verified: true);
  }

  // ── Timers ───────────────────────────────────────────────────────────────

  Future<AurelianActionResult> _startSetTimer(
      WorkoutActionPort port, ActionPayload p) async {
    final t =
        _target(port, p.string('exercise'), p.choices, destructive: false);
    if (t.answer != null) return t.answer!;
    final WorkoutExerciseView row = t.row!;
    if (!row.timed) {
      return AurelianActionResult.invalid(
          '${row.name} isn\'t a timed exercise — say "start a timer" for the workout timer');
    }
    final int n = p.integer('set')!;
    if (n > row.setCount) return _noSuchSet(row, n);
    final SetTimerView? running = port.runningSetTimer;
    if (running != null) {
      if (running.exerciseId == row.exerciseId && running.setIndex == n - 1) {
        return AurelianActionResult(
            ActionStatus.success, '${row.name} set $n timer is already running',
            verified: true);
      }
      return const AurelianActionResult.conflict(
          'Another set timer is running — stop it first');
    }
    if (!await port.startSetTimer(row.exerciseId, n - 1)) {
      return const AurelianActionResult.failure(
          "GoodLift couldn't start that timer");
    }
    final SetTimerView? now = port.runningSetTimer;
    if (now == null ||
        now.exerciseId != row.exerciseId ||
        now.setIndex != n - 1) {
      return const AurelianActionResult.failure("The timer didn't start");
    }
    final String undo =
        _journalUndo(port.actingUid, port.date, 'set timer start', () async {
      final SetTimerView? r = port.runningSetTimer;
      if (r == null || r.exerciseId != row.exerciseId || r.setIndex != n - 1) {
        return const AurelianActionResult.conflict(
            'That timer is no longer running — nothing undone');
      }
      await port.cancelSetTimer();
      return port.runningSetTimer == null
          ? AurelianActionResult(
              ActionStatus.success, '${row.name} set $n timer cancelled',
              verified: true)
          : const AurelianActionResult.failure("The timer didn't stop");
    });
    return AurelianActionResult(
        ActionStatus.success, '${row.name} · set $n timer started',
        data: <String, Object?>{
          'exercise': row.name,
          'set': n,
          'timer': 'running'
        },
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _stopSetTimer(
      WorkoutActionPort port, ActionPayload p) async {
    final SetTimerView? running = port.runningSetTimer;
    if (running == null) {
      return const AurelianActionResult.invalid('No set timer is running');
    }
    final WorkoutExerciseView? row = _row(port, running.exerciseId);
    if (row == null) {
      return const AurelianActionResult.failure('The timed exercise is gone');
    }
    final String? spoken = p.string('exercise');
    if (spoken != null) {
      final ExerciseResolution<WorkoutExerciseView> r =
          resolveExercise<WorkoutExerciseView>(
              spoken, <WorkoutExerciseView>[row],
              nameOf: (WorkoutExerciseView x) => x.name,
              idOf: (WorkoutExerciseView x) => x.exerciseId,
              allowFuzzy: true);
      if (r.chosen == null) {
        return AurelianActionResult.notFound(
            'The running timer is ${row.name}, not $spoken');
      }
    }
    final int? before = row.set(running.setIndex).reps;
    if (!await port.stopSetTimer() || port.runningSetTimer != null) {
      return const AurelianActionResult.failure("The timer didn't stop");
    }
    final WorkoutExerciseView? now = _row(port, row.exerciseId);
    final int? seconds = now?.set(running.setIndex).reps;
    final int n = running.setIndex + 1;
    final String undo =
        _journalUndo(port.actingUid, port.date, 'set timer stop', () async {
      final WorkoutExerciseView? current = _row(port, row.exerciseId);
      if (current == null || current.set(running.setIndex).reps != seconds) {
        return const AurelianActionResult.conflict(
            'The time was changed since — nothing undone');
      }
      await port.setFields(row.exerciseId, running.setIndex, <FieldEdit>[
        FieldEdit(Wes2FieldKey.reps, before == null ? '' : '$before')
      ]);
      return AurelianActionResult(
          ActionStatus.success, '${row.name} · set $n time restored',
          verified: true);
    });
    final String time = seconds == null
        ? 'no time'
        : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return AurelianActionResult(
        ActionStatus.success, '${row.name} · set $n timer stopped at $time',
        data: <String, Object?>{
          'exercise': row.name,
          'set': n,
          if (seconds != null) 'seconds': seconds,
          'timer': 'stopped'
        },
        undoToken: undo,
        verified: true);
  }

  Future<AurelianActionResult> _generalTimer(WorkoutActionPort port,
      {required bool start}) async {
    final GeneralTimerView before = port.generalTimer;
    if (before.running == start) {
      return AurelianActionResult(
          ActionStatus.success,
          start
              ? 'The workout timer is already running'
              : "The workout timer isn't running",
          data: <String, Object?>{'timer': start ? 'running' : 'stopped'},
          verified: true);
    }
    start ? await port.startGeneralTimer() : await port.stopGeneralTimer();
    final GeneralTimerView after = port.generalTimer;
    if (after.running != start) {
      return const AurelianActionResult.failure(
          "The workout timer didn't change");
    }
    final String undo =
        _journalUndo(port.actingUid, port.date, 'workout timer', () async {
      if (port.generalTimer.running != start) {
        return const AurelianActionResult.conflict(
            'The timer was changed since — nothing undone');
      }
      start ? await port.stopGeneralTimer() : await port.startGeneralTimer();
      return AurelianActionResult(ActionStatus.success,
          start ? 'Workout timer stopped' : 'Workout timer resumed',
          verified: true);
    });
    final int s = after.elapsedMs ~/ 1000;
    return AurelianActionResult(
        ActionStatus.success,
        start
            ? 'Workout timer started'
            : 'Workout timer stopped at ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
        data: <String, Object?>{
          'timer': start ? 'running' : 'stopped',
          'elapsedSeconds': s
        },
        undoToken: undo,
        verified: true);
  }
}

/// Today's template: one in the active block whose day matches the block day
/// number or the weekday. Several or none → ask among the active block's (or
/// all) templates.
({TemplateEntry? chosen, List<TemplateEntry> ask}) selectTodaysTemplate(
    List<TemplateEntry> all, int? blockDayNumber, DateTime date) {
  const List<String> weekdays = <String>[
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday'
  ];
  final String weekday = weekdays[date.weekday - 1];
  final List<TemplateEntry> pool = all.any((TemplateEntry t) => t.inActiveBlock)
      ? all.where((TemplateEntry t) => t.inActiveBlock).toList()
      : all;
  int? dayNumber(TemplateEntry t) {
    for (final String? s in <String?>[t.day, t.name]) {
      final RegExpMatch? m =
          RegExp(r'\bday\s*(\d+)\b', caseSensitive: false).firstMatch(s ?? '');
      if (m != null) return int.tryParse(m.group(1)!);
    }
    final RegExpMatch? lead = RegExp(r'^\s*(\d+)\b').firstMatch(t.day ?? '');
    return lead == null ? null : int.tryParse(lead.group(1)!);
  }

  final List<TemplateEntry> hits = pool.where((TemplateEntry t) {
    final String d = (t.day ?? '').trim().toLowerCase();
    if (d == weekday || t.name.toLowerCase().contains(weekday)) return true;
    return blockDayNumber != null && dayNumber(t) == blockDayNumber;
  }).toList();
  if (hits.length == 1) {
    return (chosen: hits.single, ask: const <TemplateEntry>[]);
  }
  // Nothing matches today: ask, even about a single template ("Load Day 2?").
  return (
    chosen: null,
    ask: (hits.isNotEmpty ? hits : pool).take(kActionMaxCandidates).toList()
  );
}
