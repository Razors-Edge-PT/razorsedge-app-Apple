// In-memory fakes of the Aurelian action ports. They model only what the
// service observes (the read model) and record every call, so tests can assert
// that nothing broader than the requested change ran.

import 'dart:convert';

import 'package:localtest222/WES2_models.dart' show Wes2FieldKey;
import 'package:localtest222/aurelian/actions/action_envelope.dart';
import 'package:localtest222/aurelian/actions/action_ports.dart';
import 'package:localtest222/units/weight_unit.dart';

class FakeAthletes implements AthleteActionPort {
  FakeAthletes(
      {String actor = 'coach',
      bool coach = true,
      List<AthleteCandidate>? roster})
      : actor = actor,
        hasCoachMode = coach,
        acting = actor,
        roster = roster ??
            <AthleteCandidate>[
              const AthleteCandidate(
                  uid: 'coach', username: 'richard', isSelf: true),
              const AthleteCandidate(
                  uid: 'ruby',
                  username: 'rubycakes',
                  fullName: 'Ruby Cakes',
                  email: 'ruby@example.com'),
              const AthleteCandidate(
                  uid: 'walker', username: 'jw88', fullName: 'John Walker'),
              const AthleteCandidate(
                  uid: 'coded', username: 'codednz7', displayName: 'Coded NZ'),
              const AthleteCandidate(
                  uid: 'sean1', username: 'seanb', fullName: 'Sean Brown'),
              const AthleteCandidate(
                  uid: 'sean2', username: 'seanw', fullName: 'Sean White'),
            ];

  String? actor;
  @override
  bool hasCoachMode;
  String acting;
  List<AthleteCandidate> roster;
  final List<String> switches = <String>[];

  /// When set, the switch "doesn't take" (read-back failure).
  bool ignoreSwitch = false;

  @override
  String? get actorUid => actor;

  @override
  String get actingUid => acting;

  @override
  Future<List<AthleteCandidate>> authorisedAthletes() async => roster;

  @override
  Future<String> switchTo(String uid) async {
    switches.add(uid);
    if (!ignoreSwitch) acting = uid;
    return acting;
  }
}

class FakeExercise {
  FakeExercise(this.id, this.name,
      {this.circuit = 0,
      int sets = 3,
      this.timed = false,
      this.unit = ExerciseWeightUnit.kg,
      this.bb3 = false})
      : setCount = sets;
  final String id;
  String name;
  int circuit;
  int setCount;
  final bool timed;
  final ExerciseWeightUnit unit;
  final bool bb3;
  final Map<int, Map<Wes2FieldKey, Object>> values =
      <int, Map<Wes2FieldKey, Object>>{};
  final Map<int, String> notes = <int, String>{};
  String? note;
  bool done = false;

  WorkoutExerciseView view() => WorkoutExerciseView(
        exerciseId: id,
        name: name,
        circuitIndex: circuit,
        setCount: setCount,
        sets: <WorkoutSetView>[
          for (int i = 0; i < setCount; i++)
            WorkoutSetView(
              index: i,
              weightKg: values[i]?[Wes2FieldKey.weight] as double?,
              reps: values[i]?[Wes2FieldKey.reps] as int?,
              rir: values[i]?[Wes2FieldKey.rir] as double?,
              velocity: values[i]?[Wes2FieldKey.velocity] as double?,
              note: notes[i],
            ),
        ],
        note: note,
        done: done,
        timed: timed,
        unit: unit,
        bb3Planned: bb3,
      );
}

class FakeWorkout implements WorkoutActionPort {
  FakeWorkout({this.uid = 'coach', DateTime? day, List<FakeExercise>? rows})
      : day = day ?? DateTime(2026, 10, 1),
        rows = rows ?? <FakeExercise>[];

  final String uid;
  DateTime day;
  final List<FakeExercise> rows;
  final List<String> calls = <String>[];
  String? target;
  Map<String, int> usage = <String, int>{};
  List<CatalogueEntry> catalogueList = const <CatalogueEntry>[
    CatalogueEntry(id: 'bench_bb', name: 'Bench Press, Barbell'),
    CatalogueEntry(id: 'bench_larsen', name: 'Bench Press, Larsen Press'),
    CatalogueEntry(id: 'larsen_bench', name: 'Larsen Bench Press'),
    CatalogueEntry(id: 'bench_narrow', name: 'Bench Press, Narrow Grip'),
    CatalogueEntry(id: 'db_flat', name: 'Flat Bench Dumbbell Press'),
    CatalogueEntry(id: 'db_incline', name: 'Incline Bench Dumbbell Press'),
    CatalogueEntry(id: 'ohp_db', name: 'Overhead Dumbbell Press'),
    CatalogueEntry(
        id: 'ohp_db_uni', name: 'Overhead Dumbbell Press, Unilateral'),
    CatalogueEntry(id: 'squat_bb', name: 'Back Squat, Barbell'),
    CatalogueEntry(id: 'plank', name: 'Plank'),
    CatalogueEntry(id: 'side_plank', name: 'Side Plank'),
  ];
  List<TemplateEntry> templateList = const <TemplateEntry>[];
  Map<String, List<FakeExercise> Function()> templateRows =
      <String, List<FakeExercise> Function()>{};
  int? dayNumber;
  String? blocked;

  bool generalRunning = false;
  int generalElapsed = 0;
  ({String id, int set})? setTimer;
  int setTimerSeconds = 45;

  /// When true, writes are silently dropped (read-back must catch it).
  bool dropWrites = false;

  FakeExercise? byId(String id) =>
      rows.where((FakeExercise r) => r.id == id).firstOrNull;

  @override
  Future<String?> prepare() async => blocked;

  @override
  DateTime get date => day;

  @override
  String get actingUid => uid;

  @override
  List<WorkoutExerciseView> get exercises =>
      rows.map((FakeExercise r) => r.view()).toList();

  @override
  String? get targetExerciseId => target;

  @override
  void setTarget(String exerciseId) => target = exerciseId;

  @override
  Map<String, int> exerciseUsage() => usage;

  @override
  Future<bool> changeDate(DateTime date) async {
    calls.add('changeDate');
    day = date;
    rows.clear();
    return true;
  }

  @override
  Future<List<CatalogueEntry>?> catalogue() async => catalogueList;

  @override
  Future<List<TemplateEntry>?> templates() async => templateList;

  @override
  int? blockDayNumber() => dayNumber;

  @override
  Future<String?> loadTemplate(String templateId) async {
    calls.add('loadTemplate:$templateId');
    rows
      ..clear()
      ..addAll(templateRows[templateId]!());
    return null;
  }

  @override
  Future<void> addExercise(CatalogueEntry exercise, int circuitIndex) async {
    calls.add('addExercise:${exercise.id}:$circuitIndex');
    if (dropWrites) return;
    rows.add(FakeExercise(exercise.id, exercise.name,
        circuit: circuitIndex, sets: 1));
  }

  @override
  Future<void> deleteExercise(String exerciseId) async {
    calls.add('deleteExercise:$exerciseId');
    if (dropWrites) return;
    rows.removeWhere((FakeExercise r) => r.id == exerciseId);
  }

  @override
  Future<void> replaceExercise(
      String exerciseId, CatalogueEntry replacement) async {
    calls.add('replaceExercise:$exerciseId:${replacement.id}');
    final FakeExercise old = byId(exerciseId)!;
    rows[rows.indexOf(old)] = FakeExercise(replacement.id, replacement.name,
        circuit: old.circuit, sets: old.setCount);
  }

  @override
  Future<void> moveExercise(String exerciseId, int circuitIndex) async {
    calls.add('moveExercise:$exerciseId:$circuitIndex');
    byId(exerciseId)!.circuit = circuitIndex;
  }

  @override
  Future<void> setFields(
      String exerciseId, int setIndex, List<FieldEdit> edits) async {
    calls.add(
        'setFields:$exerciseId:$setIndex:${edits.map((FieldEdit e) => '${e.key.name}=${e.text}').join(',')}');
    if (dropWrites) return;
    final Map<Wes2FieldKey, Object> v = byId(exerciseId)!
        .values
        .putIfAbsent(setIndex, () => <Wes2FieldKey, Object>{});
    for (final FieldEdit e in edits) {
      if (e.text.isEmpty) {
        v.remove(e.key);
      } else {
        v[e.key] = e.key == Wes2FieldKey.reps
            ? int.parse(e.text)
            : double.parse(e.text);
      }
    }
  }

  @override
  Future<void> setNote(String exerciseId, int setIndex, String? note) async {
    calls.add('setNote:$exerciseId:$setIndex');
    final FakeExercise r = byId(exerciseId)!;
    if (note == null || note.isEmpty) {
      r.notes.remove(setIndex);
    } else {
      r.notes[setIndex] = note;
    }
  }

  @override
  Future<void> exerciseNote(String exerciseId, String? note) async {
    calls.add('exerciseNote:$exerciseId');
    byId(exerciseId)!.note = note;
  }

  @override
  Future<void> setCompleted(String exerciseId, bool done) async {
    calls.add('setCompleted:$exerciseId:$done');
    byId(exerciseId)!.done = done;
  }

  @override
  Future<void> addSet(String exerciseId) async {
    calls.add('addSet:$exerciseId');
    byId(exerciseId)!.setCount++;
  }

  @override
  Future<void> removeSet(String exerciseId, int setIndex) async {
    calls.add('removeSet:$exerciseId:$setIndex');
    final FakeExercise r = byId(exerciseId)!;
    final Map<int, Map<Wes2FieldKey, Object>> shifted =
        <int, Map<Wes2FieldKey, Object>>{};
    r.values.forEach((int i, Map<Wes2FieldKey, Object> v) {
      if (i < setIndex) shifted[i] = v;
      if (i > setIndex) shifted[i - 1] = v;
    });
    r.values
      ..clear()
      ..addAll(shifted);
    r.setCount--;
  }

  @override
  GeneralTimerView get generalTimer => GeneralTimerView(
      visible: generalRunning || generalElapsed > 0,
      running: generalRunning,
      elapsedMs: generalElapsed);

  @override
  Future<void> startGeneralTimer() async {
    calls.add('startGeneralTimer');
    generalRunning = true;
  }

  @override
  Future<void> stopGeneralTimer() async {
    calls.add('stopGeneralTimer');
    generalRunning = false;
    generalElapsed = 61000;
  }

  @override
  SetTimerView? get runningSetTimer => setTimer == null
      ? null
      : SetTimerView(
          exerciseId: setTimer!.id, setIndex: setTimer!.set, running: true);

  @override
  Future<bool> startSetTimer(String exerciseId, int setIndex) async {
    calls.add('startSetTimer:$exerciseId:$setIndex');
    setTimer = (id: exerciseId, set: setIndex);
    return true;
  }

  @override
  Future<bool> stopSetTimer() async {
    calls.add('stopSetTimer');
    final ({String id, int set})? t = setTimer;
    if (t == null) return false;
    byId(t.id)!.values.putIfAbsent(
            t.set, () => <Wes2FieldKey, Object>{})[Wes2FieldKey.reps] =
        setTimerSeconds;
    setTimer = null;
    return true;
  }

  @override
  Future<bool> cancelSetTimer() async {
    calls.add('cancelSetTimer');
    setTimer = null;
    return true;
  }
}

int _seq = 0;

/// Envelope JSON for [action] with a fresh request id and idempotency key.
String envelope(String action, Map<String, Object?> payload,
    {String? key, String? confirmationToken}) {
  _seq++;
  return jsonEncode(<String, Object?>{
    'schemaVersion': kAurelianActionSchemaVersion,
    'requestId': 'req-$_seq',
    'idempotencyKey': key ?? 'idem-key-$_seq',
    'action': action,
    'payload': payload,
    if (confirmationToken != null) 'confirmationToken': confirmationToken,
  });
}

AurelianActionEnvelope parseEnvelopeOrThrow(String json) {
  final r = parseActionEnvelope(json);
  if (r.error != null) throw StateError(r.error!.message);
  return r.envelope!;
}
