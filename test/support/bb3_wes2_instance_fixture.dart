// Shared fixture for the BB3 ⇄ WES2 prescription and active-instance
// regression suites.
//
// A DUP, By Exposure exercise whose three rep-target instances and three RIR
// sessions are all DISTINGUISHABLE, so a test can tell which instance and which
// session a hint actually used:
//
//   repTargets.week1  instance1 '12 x 2'   instance2 '5 x 4'   instance3 '3 x 5'
//   rirPlan.week1     session1  2.5/3/3    session2  1.0/1.5/2.0/2.5
//                     session3  0.5/1/1.5/2/2.5
//
// The block starts on Monday 2026-01-05. The selected date is SUNDAY
// 2026-01-25: block day 20, so `days % 7 == 6` — a weekday position with no
// matching `instance7` / `session7`, which is exactly the shape of the
// production report (the weekday path silently falls back to instance1 /
// session1).
//
// Completed history (valid performed sets) before the selected date:
//   2026-01-06, 01-09, 01-13, 01-16   → exposure position 4
// Canonical contract (option A): position 4 → rep slot 4 % 3 = 1 (instance2,
// '5 x 4') and RIR session 4 % 3 = 1 (session2, Set-1 RIR 1.0).
library;

import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/periodization_model_utils.dart';

const String kExId = 'ex_contract_pulldown';
const String kExName = 'Contract Test Pulldown';
const String kUid = 'u_contract';
const String kBlockId = 'b_contract';

final DateTime kBlockStart = DateTime(2026, 1, 5); // Monday
final DateTime kBlockEnd = DateTime(2026, 3, 29);
final DateTime kSelected = DateTime(2026, 1, 25); // Sunday, days % 7 == 6

/// The completed exposure dates strictly before [kSelected].
const List<String> kPriorExposureDates = <String>[
  '2026-01-06',
  '2026-01-09',
  '2026-01-13',
  '2026-01-16',
];

/// Distinguishable Set-N RIR per session (1-based session, 1-based set).
const Map<int, List<double>> kSessionRir = <int, List<double>>{
  1: <double>[2.5, 3.0, 3.0],
  2: <double>[1.0, 1.5, 2.0, 2.5],
  3: <double>[0.5, 1.0, 1.5, 2.0, 2.5],
};

/// Deliberately different rep target in instance1 — the value a weekday /
/// missing-key fallback lands on. It must never replace a history solve.
const int kFallbackInstance1Reps = 12;

Map<String, dynamic> exerciseSettingsFor({
  String model = 'DUP, By Exposure',
  String progressionModel = 'Smart Progression',
  Object? increments,
  Map<String, dynamic>? repTargetsWeek1,
  Map<int, List<double>>? sessionRir,
  int weeklyFrequency = 3,
}) {
  final Map<int, List<double>> rir = sessionRir ?? kSessionRir;
  return <String, dynamic>{
    'periodizationModel': model,
    'progressionModel': progressionModel,
    'rirModel': 'Static RIR',
    'weeklyFrequency': weeklyFrequency,
    'defaultSets': 3,
    'increments': increments ?? <String, dynamic>{'primary': 2.5},
    'repTargets': <String, dynamic>{
      'week1': repTargetsWeek1 ??
          <String, dynamic>{
            'instance1': '$kFallbackInstance1Reps x 2',
            'instance2': '5 x 4',
            'instance3': '3 x 5',
          },
    },
    'rirPlan': <String, dynamic>{
      'week1': <String, dynamic>{
        for (final MapEntry<int, List<double>> s in rir.entries)
          'session${s.key}': <String, dynamic>{
            for (int i = 0; i < s.value.length; i++)
              'set${i + 1}': <String, dynamic>{'rir': s.value[i].toString()},
          },
      },
    },
  };
}

Map<String, dynamic> allSettings({
  String exerciseId = kExId,
  Map<String, dynamic>? settings,
}) =>
    <String, dynamic>{exerciseId: settings ?? exerciseSettingsFor()};

Map<String, dynamic> workout(
  String ymd, {
  String exerciseId = kExId,
  String name = kExName,
  double weight = 100,
  int reps = 5,
  double rir = 2,
}) {
  final List<String> p = ymd.split('-');
  return <String, dynamic>{
    'date': DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2])),
    'exercises': <Map<String, dynamic>>[
      <String, dynamic>{
        'exerciseId': exerciseId,
        'name': name,
        'sets': <Map<String, dynamic>>[
          <String, dynamic>{'weight': weight, 'reps': reps, 'rir': rir},
          <String, dynamic>{'weight': weight, 'reps': reps, 'rir': rir + 1},
        ],
      },
    ],
  };
}

/// Real history: the four prior exposures (progressing), plus optional extra
/// workouts (a same-day or later one) added by a test.
List<Map<String, dynamic>> history({
  List<Map<String, dynamic>> extra = const <Map<String, dynamic>>[],
  String exerciseId = kExId,
  String name = kExName,
}) =>
    <Map<String, dynamic>>[
      workout('2026-01-06', exerciseId: exerciseId, name: name, weight: 95),
      workout('2026-01-09', exerciseId: exerciseId, name: name, weight: 97.5),
      workout('2026-01-13', exerciseId: exerciseId, name: name, weight: 100),
      workout('2026-01-16', exerciseId: exerciseId, name: name, weight: 102.5),
      ...extra,
    ];

void seedHistory(List<Map<String, dynamic>> workouts) {
  PeriodizationModelUtils.savedWorkoutsList = workouts;
  PeriodizationModelUtils.topSetsByExercise.clear();
}

void clearHistory() {
  PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
  PeriodizationModelUtils.topSetsByExercise.clear();
}

Wes2HintServiceImpl hintService(Map<String, dynamic> settings) =>
    Wes2HintServiceImpl(
      exerciseSettings: settings,
      blockStartDate: kBlockStart,
      blockEndDate: kBlockEnd,
      uid: kUid,
    );

/// An empty planned row (no actuals). [setCount] slots.
Wes2ExerciseRow plannedRow({
  int setCount = 4,
  String exerciseId = kExId,
  String name = kExName,
  String? exerciseType,
}) =>
    Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: name,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: setCount,
      source: Wes2RowSource.bb3Planned,
      exerciseType: exerciseType,
      sets: List<Wes2SetState>.generate(
          setCount, (int i) => Wes2SetState(setIndex: i)),
    );

/// [row] with Set 1 actuals typed in WES2.
Wes2ExerciseRow withTypedSet1(
  Wes2ExerciseRow row, {
  double? weight,
  int? reps,
  double? rir,
}) {
  final Wes2SetState s = row.sets.first;
  final Wes2SetState typed = s.copyWith(
    weight: weight == null ? s.weight : s.weight.withActual(weight),
    reps: reps == null ? s.reps : s.reps.withActual(reps),
    rir: rir == null ? s.rir : s.rir.withActual(rir),
  );
  return row.copyWith(sets: <Wes2SetState>[typed, ...row.sets.skip(1)]);
}

/// Positional BB3 prescription for Set 1 only.
Wes2Prescriptions set1Prescription({double? weight, int? reps, double? rir}) =>
    Wes2Prescriptions(sets: <Wes2PrescribedSet>[
      Wes2PrescribedSet(weight: weight, reps: reps, rir: rir),
    ]);

Wes2ExerciseRow resolve(
  Wes2HintServiceImpl svc,
  Wes2ExerciseRow row, {
  Wes2Prescriptions prescriptions = Wes2Prescriptions.none,
  DateTime? date,
}) =>
    svc.resolveRow(
      row: row,
      prescriptions: prescriptions,
      uid: kUid,
      date: date ?? kSelected,
    );

/// What a field shows: the actual when present, else the hint.
T? shown<T extends Object>(Wes2FieldState<T> f) => f.actualValue ?? f.hintValue;

double e1rm(double w, num reps, double rir) =>
    PeriodizationModelUtils.calculateE1RM(w, reps.toDouble(), rir);
