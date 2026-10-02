/// What the Aurelian action service needs from GoodLift, as narrow interfaces.
///
/// The service ([AurelianActionService]) holds all decisions — validation,
/// matching, confirmation, idempotency, undo and read-back — and talks to the
/// app only through these ports. The production implementations are thin
/// adapters over the code the screens already use (UserContext and
/// CoachRosterService for athletes; the WES2 screen's own handlers for the
/// workout), so voice and touch run the same canonical operations. Tests use
/// in-memory fakes; nothing here imports Flutter widgets, Firebase or Android.
library;

import '../../WES2_models.dart' show Wes2FieldKey;
import '../../units/weight_unit.dart';

/// An athlete the signed-in coach may act on (never chosen by the planner:
/// only matched against this list).
class AthleteCandidate {
  const AthleteCandidate({
    required this.uid,
    this.username = '',
    this.displayName = '',
    this.fullName = '',
    this.email = '',
    this.isSelf = false,
  });

  final String uid;
  final String username;
  final String displayName;
  final String fullName;
  final String email;

  /// The signed-in account itself ("switch back to me").
  final bool isSelf;

  /// What is said back to the user (never the uid).
  String get label {
    for (final String v in <String>[username, fullName, displayName, email]) {
      if (v.trim().isNotEmpty) return v.trim();
    }
    return 'this athlete';
  }

  /// A spoken label that carries both ways of saying who it is: "Michael Helps
  /// (Helpzie)" when the full name and username differ, else [label].
  String get voiceLabel {
    final String full = fullName.trim();
    final String user = username.trim();
    if (full.isNotEmpty &&
        user.isNotEmpty &&
        full.toLowerCase() != user.toLowerCase()) {
      return '$full ($user)';
    }
    return label;
  }
}

abstract class AthleteActionPort {
  /// The authenticated GoodLift account; null when signed out.
  String? get actorUid;

  /// Server-resolved Coach Mode (CoachRole), not merely the mirrored claim.
  bool get hasCoachMode;

  /// The athlete GoodLift currently acts for (Coach Dashboard's selection).
  String get actingUid;

  /// Athletes this coach may act on, from the same roster rules as Coach
  /// Dashboard (firestore.rules isCoachFor). Includes the coach themself.
  Future<List<AthleteCandidate>> authorisedAthletes();

  /// Switches the selected athlete through the Coach Dashboard's own state and
  /// refreshes the current page for them. Returns the acting uid read back
  /// afterwards.
  Future<String> switchTo(String uid);
}

/// One logged set as the workout shows it. Weight is canonical kilograms.
class WorkoutSetView {
  const WorkoutSetView({
    required this.index,
    this.weightKg,
    this.reps,
    this.rir,
    this.velocity,
    this.note,
  });

  /// 0-based (spoken set number - 1).
  final int index;
  final double? weightKg;
  final int? reps;
  final double? rir;
  final double? velocity;
  final String? note;

  bool get hasValues =>
      weightKg != null || reps != null || rir != null || velocity != null;
  bool get hasNote => note?.trim().isNotEmpty == true;
  bool get isEmpty => !hasValues && !hasNote;

  Object? valueOf(Wes2FieldKey key) => switch (key) {
        Wes2FieldKey.weight => weightKg,
        Wes2FieldKey.reps => reps,
        Wes2FieldKey.rir => rir,
        Wes2FieldKey.velocity => velocity,
      };
}

class WorkoutExerciseView {
  const WorkoutExerciseView({
    required this.exerciseId,
    required this.name,
    required this.circuitIndex,
    required this.setCount,
    this.sets = const <WorkoutSetView>[],
    this.note,
    this.done = false,
    this.timed = false,
    this.velocityShown = true,
    this.bb3Planned = false,
    this.unit = ExerciseWeightUnit.kg,
  });

  final String exerciseId;
  final String name;

  /// 0-based (spoken circuit number - 1).
  final int circuitIndex;
  final int setCount;
  final List<WorkoutSetView> sets;
  final String? note;
  final bool done;

  /// Entered with the set stopwatch (plank) rather than weight × reps.
  final bool timed;
  final bool velocityShown;
  final bool bb3Planned;

  /// The athlete's display unit for this exercise.
  final ExerciseWeightUnit unit;

  WorkoutSetView set(int index) =>
      sets.firstWhere((WorkoutSetView s) => s.index == index,
          orElse: () => WorkoutSetView(index: index));

  bool get hasLoggedData =>
      done ||
      note?.trim().isNotEmpty == true ||
      sets.any((WorkoutSetView s) => !s.isEmpty);
  bool get hasSetValues => sets.any((WorkoutSetView s) => s.hasValues);
}

class CatalogueEntry {
  const CatalogueEntry({required this.id, required this.name, this.label});
  final String id;
  final String name;

  /// How a "which one?" names it (custom duplicates are told apart).
  final String? label;
  String get display => label ?? name;
}

class TemplateEntry {
  const TemplateEntry(
      {required this.id,
      required this.name,
      this.day,
      this.inActiveBlock = false});
  final String id;
  final String name;
  final String? day;
  final bool inActiveBlock;
}

/// One field edit exactly as the set row reports it on leaving the field:
/// canonical kilogram text for weight, '' to clear.
class FieldEdit {
  const FieldEdit(this.key, this.text);
  final Wes2FieldKey key;
  final String text;
}

/// The general Enter Workout timer (three-dot menu), not a set stopwatch.
class GeneralTimerView {
  const GeneralTimerView(
      {required this.visible, required this.running, required this.elapsedMs});
  final bool visible;
  final bool running;
  final int elapsedMs;
}

/// A timed set's stopwatch.
class SetTimerView {
  const SetTimerView(
      {required this.exerciseId,
      required this.setIndex,
      required this.running});
  final String exerciseId;
  final int setIndex;
  final bool running;
}

/// The open WES2 day. Every mutating method runs the SAME handler the screen's
/// own controls run (typed-entry save path, Delete/Replace/Move cores, the Done
/// coordinator, the note save, the template load), and returns once the local
/// model reflects it; the durable outbox carries it to the server.
abstract class WorkoutActionPort {
  /// Brings the workout to the front (never dismissing a dialog that may hold
  /// unsaved text) and waits for the day to load. Null when ready, otherwise
  /// the reason it is not.
  Future<String?> prepare();

  DateTime get date;

  /// The athlete this workout belongs to (must equal the session's acting uid).
  String get actingUid;

  List<WorkoutExerciseView> get exercises;

  /// The exercise voice commands act on when none is named.
  String? get targetExerciseId;
  void setTarget(String exerciseId);

  /// How often the athlete has done each exercise (history, no I/O).
  Map<String, int> exerciseUsage();

  Future<bool> changeDate(DateTime date);

  Future<List<CatalogueEntry>?> catalogue();
  Future<List<TemplateEntry>?> templates();

  /// The block's week/day index of [date], when a block is active.
  int? blockDayNumber();

  /// Replaces the day with the template (the Load Template core). Null = done.
  Future<String?> loadTemplate(String templateId);

  Future<void> addExercise(CatalogueEntry exercise, int circuitIndex);
  Future<void> deleteExercise(String exerciseId);
  Future<void> replaceExercise(String exerciseId, CatalogueEntry replacement);
  Future<void> moveExercise(String exerciseId, int circuitIndex);
  Future<void> setFields(
      String exerciseId, int setIndex, List<FieldEdit> edits);
  Future<void> setNote(String exerciseId, int setIndex, String? note);
  Future<void> exerciseNote(String exerciseId, String? note);
  Future<void> setCompleted(String exerciseId, bool done);
  Future<void> addSet(String exerciseId);
  Future<void> removeSet(String exerciseId, int setIndex);

  GeneralTimerView get generalTimer;
  Future<void> startGeneralTimer();
  Future<void> stopGeneralTimer();

  SetTimerView? get runningSetTimer;

  /// Starts the stopwatch of one timed set (it must be on screen to run).
  Future<bool> startSetTimer(String exerciseId, int setIndex);

  /// Stops it; the time is saved through the set's own stop path.
  Future<bool> stopSetTimer();

  /// Stops it WITHOUT saving (undo of a start).
  Future<bool> cancelSetTimer();
}

/// A workout screen that can be left through its own exit, which saves it
/// (WES2's Home route: focus dropped, the latest field saved, the draft kept).
abstract class ExitableWorkout {
  /// Leaves the workout for Home the ordinary way; false when it could not.
  Future<bool> exitToHome();
}

/// A workout screen that can reopen itself for another athlete after an
/// athlete switch (WES2 reads its identity once, when it opens).
abstract class ReloadableWorkout {
  /// Replaces the open workout with a fresh one for the same day.
  Future<void> reopenForCurrentAthlete();
}
