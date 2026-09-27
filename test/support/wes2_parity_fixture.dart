// Fixture for the origin/main ordinary-WES2 parity guard — the SAME
// definitions as the two-tree parity harness that produced the golden values
// in wes2_origin_main_golden.dart (captured from unchanged origin/main
// fdc94e41). Only APIs that exist on origin/main are used.

import 'package:localtest222/WES2_models.dart';

const String kUid = 'parity_uid';
final DateTime kBlockStart = DateTime(2026, 1, 5); // Monday
final DateTime kBlockEnd = DateTime(2026, 3, 29);

// Distinct history dates (8 exposures) so positions 0..8 all occur.
const List<String> kHistoryDates = <String>[
  '2026-01-06',
  '2026-01-08',
  '2026-01-09',
  '2026-01-12',
  '2026-01-14',
  '2026-01-16',
  '2026-01-19',
  '2026-01-21',
];

const List<String> kRepModels = <String>[
  'DUP, By Exposure',
  'DUP, Signature',
  'DUP, By Week',
  'Linear, Classic',
  'Linear, by Exposure',
];
const List<String> kProgModels = <String>[
  'Smart Progression',
  'Add Reps',
  'Linear Weight Increase',
  'None',
];

class Ex {
  const Ex(this.id, this.name, {this.type});
  final String id;
  final String name;
  final String? type;
}

const Ex kPlain = Ex('parity_pull', 'Parity Cable Pull');
const Ex kChin = Ex('XM9026peNIu0R8qh7UqY', 'Chin-Up', type: 'Body Weight');
const Ex kPlank = Ex('DTkkN5pi05RWQyNYhizQ', 'Weighted Plank');

Map<String, dynamic> settingsFor(String repModel, String prog) =>
    <String, dynamic>{
      'periodizationModel': repModel,
      'progressionModel': prog,
      'rirModel': 'Static RIR',
      'weeklyFrequency': 3,
      'defaultSets': 3,
      'increments': <String, dynamic>{'primary': 2.5},
      'repTargets': <String, dynamic>{
        'repRange': <String, dynamic>{'min': 5, 'max': 10},
        'week1': <String, dynamic>{
          'instance1': '12 x 2',
          'instance2': '5 x 4',
          'instance3': '3 x 5',
        },
        'week2': <String, dynamic>{
          'instance1': '10 x 3',
          'instance2': '6 x 4',
          'instance3': '4 x 5',
        },
      },
      'rirPlan': <String, dynamic>{
        'week1': <String, dynamic>{
          'session1': <String, dynamic>{
            for (int s = 1; s <= 5; s++)
              'set$s': <String, dynamic>{'rir': '${2.0 + s * 0.5}'},
          },
          'session2': <String, dynamic>{
            for (int s = 1; s <= 5; s++)
              'set$s': <String, dynamic>{'rir': '${0.75 + s * 0.25}'},
          },
          'session3': <String, dynamic>{
            for (int s = 1; s <= 5; s++)
              'set$s': <String, dynamic>{'rir': '${s * 0.5 - 0.25}'},
          },
        },
      },
    };

List<Map<String, dynamic>> historyFor(Ex ex, {String? extraDate}) =>
    <Map<String, dynamic>>[
      for (int i = 0; i < kHistoryDates.length; i++)
        _workout(kHistoryDates[i], ex, 90 + i * 2.5),
      if (extraDate != null) _workout(extraDate, ex, 200),
    ];

Map<String, dynamic> _workout(String ymd, Ex ex, double w) {
  final p = ymd.split('-').map(int.parse).toList();
  return <String, dynamic>{
    'date': DateTime(p[0], p[1], p[2]),
    'exercises': <Map<String, dynamic>>[
      <String, dynamic>{
        'exerciseId': ex.id,
        'name': ex.name,
        if (ex.type != null) 'type': ex.type,
        'sets': <Map<String, dynamic>>[
          <String, dynamic>{'weight': w, 'reps': 5, 'rir': 2.0},
          <String, dynamic>{'weight': w - 2.5, 'reps': 6, 'rir': 2.0},
        ],
      },
    ],
  };
}

typedef Typed = ({String name, int setIdx, double? w, int? r, double? rir});

const List<Typed> kInputs = <Typed>[
  (name: 'none', setIdx: 0, w: null, r: null, rir: null),
  (name: 's1:w', setIdx: 0, w: 96.25, r: null, rir: null),
  (name: 's1:r', setIdx: 0, w: null, r: 7, rir: null),
  (name: 's1:rir', setIdx: 0, w: null, r: null, rir: 1.25),
  (name: 's1:w+r', setIdx: 0, w: 101.25, r: 4, rir: null),
  (name: 's1:w+rir', setIdx: 0, w: 98.75, r: null, rir: 1.0),
  (name: 's1:r+rir', setIdx: 0, w: null, r: 6, rir: 1.5),
  (name: 's1:all', setIdx: 0, w: 100.0, r: 6, rir: 2.0),
  (name: 's2:w', setIdx: 1, w: 97.5, r: null, rir: null),
];

Wes2ExerciseRow rowFor(Ex ex, Typed t) {
  const int n = 5;
  return Wes2ExerciseRow(
    exerciseId: ex.id,
    name: ex.name,
    circuitIndex: 0,
    orderIndex: 0,
    setCount: n,
    source: Wes2RowSource.wes2Manual,
    exerciseType: ex.type,
    sets: List<Wes2SetState>.generate(n, (int i) {
      if (i != t.setIdx) return Wes2SetState(setIndex: i);
      Wes2FieldState<X> f<X>(X? v) => v == null
          ? Wes2FieldState<X>()
          : Wes2FieldState<X>(actualValue: v, origin: FieldOrigin.typed);
      return Wes2SetState(
          setIndex: i,
          weight: f<double>(t.w),
          reps: f<int>(t.r),
          rir: f<double>(t.rir));
    }),
  );
}

Map<String, Object?> fieldJson<X>(Wes2FieldState<X> f) => <String, Object?>{
      'a': f.actualValue,
      'h': f.hintValue,
      'o': f.origin.name,
      'ho': f.hintOrigin.name,
    };

Map<String, Object?> rowJson(Wes2ExerciseRow r) => <String, Object?>{
      'count': r.setCount,
      'sets': <Object?>[
        for (final Wes2SetState s in r.sets)
          <String, Object?>{
            'w': fieldJson<double>(s.weight),
            'r': fieldJson<int>(s.reps),
            'rir': fieldJson<double>(s.rir),
          },
      ],
    };
