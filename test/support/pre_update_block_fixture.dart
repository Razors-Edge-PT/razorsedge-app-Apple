// A realistic pre-update ACTIVE block, shaped like a block that was created
// and tuned on an older app build: canonical per-exercise settings with every
// field family, legacy-compatible fields (membership arrays, the retired
// plannedExerciseDetails map, blockMeta), blank-versus-zero values, a
// current_block pointer, templates NOT linked to the block by blockId, and a
// planned day. Tests open it through the current code with a completely fresh
// local cache and compare Firestore dumps byte for byte.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';

const String kFxAthlete = 'fx-athlete';
const String kFxActive = 'fx-active-block';
const String kFxOther = 'fx-other-block';

const String kFxBench = 'fxBench';
const String kFxSquat = 'fxSquat';
const String kFxRow = 'fxRow';
const String kFxCurl = 'fxCurl';
const String kFxCustom = 'fxCustomCore';

/// Catalogue exercises NOT in the block (so membership is a real subset).
const String kFxUnused = 'fxUnused';

const Map<String, String> kFxNames = {
  kFxBench: 'Bench Press, Barbell',
  kFxSquat: 'Back Squat, Barbell',
  kFxRow: 'Cable Row, Seated',
  kFxCurl: 'Dumbbell Biceps Curl',
  kFxCustom: 'Athlete Core Hold',
  kFxUnused: 'Zercher Carry',
};

final DateTime kFxStart = DateTime(2026, 9, 7); // Monday
final DateTime kFxEnd = DateTime(2026, 11, 29); // Sunday, 12 weeks

Map<String, dynamic> _rir(List<String> perSession) => {
      for (int w = 1; w <= 2; w++)
        'week$w': {
          for (int s = 0; s < perSession.length; s++)
            'session${s + 1}': {
              'set1': {'rir': perSession[s]},
              'set2': {'rir': perSession[s]},
            }
        }
    };

/// Every settings field family the app stores, per exercise.
final Map<String, Map<String, dynamic>> kFxSettings = {
  kFxBench: {
    'periodizationModel': 'DUP, By Exposure',
    'progressionModel': 'Smart Progression',
    'repTargets': {
      'week1': {'instance1': '5', 'instance2': '8', 'instance3': '3'},
      'week2': {'instance1': '6', 'instance2': '9', 'instance3': '4'},
    },
    'modelSpecificRepTargets': {
      'DUP, By Exposure': {
        'week1': {'instance1': '5', 'instance2': '8', 'instance3': '3'}
      },
      'Linear, Classic': {
        'week1': {'instance1': '8'}
      },
    },
    'rirModel': 'Static RIR',
    'rirPlan': _rir(['2', '1', '3']),
    'defaultSets': 4,
    'weeklyFrequency': 3,
    'increments': {'primary': 2.5, 'secondary': 1.25},
    'notes': 'Pause first rep. Elbows 45°.',
    'maxWeightXReps': '100 x 5',
    'showVelocityField': true,
    'velocityTarget': 0.45,
    'unknownFutureKey': {
      'nested': [1, 2, 3]
    },
  },
  kFxSquat: {
    'periodizationModel': 'Linear, Classic',
    'progressionModel': 'Linear Weight Increase',
    'repTargets': {
      'week1': {'instance1': '8', 'instance2': '8'},
    },
    'rirModel': 'Static RIR',
    'rirPlan': _rir(['2', '2']),
    'defaultSets': 3,
    'weeklyFrequency': 2,
    'increments': {'primary': 5},
    // Blank-versus-zero semantics must survive exactly.
    'notes': '',
    'maxWeightXReps': '',
    'showVelocityField': false,
  },
  kFxRow: {
    'periodizationModel': 'DUP, Signature',
    'progressionModel': 'Add Reps',
    'repTargets': {'min': '6', 'max': '12', 'repRange': '6-12'},
    'rirPlan': _rir(['0']),
    'defaultSets': 0,
    'weeklyFrequency': 1,
    'increments': {'primary': 0, 'secondary': 0.5},
    'notes': 'Zero sets is deliberate.',
  },
  kFxCurl: {
    'periodizationModel': 'DUP, By Week',
    'progressionModel': 'Linear Weight Increase',
    'repTargets': {
      'week1': {'instance1': '12'},
      'week2': {'instance1': '10'},
    },
    'rirPlan': _rir(['1']),
    'defaultSets': 2,
    'weeklyFrequency': 1,
    'increments': {'primary': 1},
    'weightUnit': 'lb',
  },
  kFxCustom: {
    'periodizationModel': 'Linear, by Exposure',
    'progressionModel': 'Linear Weight Increase',
    'repTargets': {
      'week1': {'instance1': '30'},
    },
    'defaultSets': 3,
    'weeklyFrequency': 2,
    'increments': {'primary': 0},
  },
};

List<String> get kFxMembers => kFxSettings.keys.toList();

/// Seeds the catalogue, the athlete, the pre-update active block (and an
/// unrelated second block), the current_block pointer, unlinked templates
/// and one planned day. [allExercisesAvailable] switches between the two
/// historical membership shapes.
Future<void> seedPreUpdateBlock(
  FakeFirebaseFirestore db, {
  bool allExercisesAvailable = false,
}) async {
  for (final e in kFxNames.entries) {
    if (e.key == kFxCustom) continue;
    await db.collection('exercises').doc(e.key).set({
      'name': e.value,
      'category': e.key == kFxSquat ? 'Squat Pattern' : 'Horizontal Press',
      'bodyParts': ['Chest'],
      'bodyPart': 'Chest',
    });
  }
  await db
      .collection('users')
      .doc(kFxAthlete)
      .collection('customExercises')
      .doc(kFxCustom)
      .set({
    'name': kFxNames[kFxCustom],
    'category': 'Core',
    'bodyParts': ['Abs'],
    'ownerUid': kFxAthlete,
    'source': 'custom',
  });
  await db.collection('users').doc(kFxAthlete).set({
    'username': 'fixture',
    'sex': 'M',
  });

  final blocks =
      db.collection('users').doc(kFxAthlete).collection('planned_blocks');
  await blocks.doc(kFxActive).set({
    'name': 'Pre-update block',
    'isActive': true,
    'createdAt': Timestamp.fromDate(DateTime(2026, 9, 1)),
    'startDate': Timestamp.fromDate(kFxStart),
    'endDate': Timestamp.fromDate(kFxEnd),
    'selectedDays': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
    'exerciseSettings': kFxSettings,
    if (allExercisesAvailable) ...{
      'allExercisesAvailable': true,
      'excludedExerciseIds': [kFxUnused],
    } else ...{
      'exercises': kFxMembers,
      'plannedExercises': kFxMembers,
    },
    'templateCandidateExerciseIds': [kFxBench, kFxSquat],
    // Retired-but-present legacy structures must be left untouched.
    'plannedExerciseDetails': {
      kFxBench: {'repTargets': kFxSettings[kFxBench]!['repTargets']},
      'blockMeta': {'blockStartDate': kFxStart.toIso8601String()},
    },
    'blockMeta': {'blockStartDate': kFxStart.toIso8601String()},
    'ownerUid': kFxAthlete,
  });
  await blocks.doc(kFxOther).set({
    'name': 'Other block',
    'isActive': false,
    'createdAt': Timestamp.fromDate(DateTime(2026, 6, 1)),
    'startDate': Timestamp.fromDate(DateTime(2026, 6, 1)),
    'endDate': Timestamp.fromDate(DateTime(2026, 8, 30)),
    'exerciseSettings': {
      kFxSquat: {'defaultSets': 5, 'notes': 'other block'}
    },
  });
  await db
      .collection('users')
      .doc(kFxAthlete)
      .collection('block_planner')
      .doc('current_block')
      .set({'blockId': kFxActive, 'blockName': 'Pre-update block'});
  // Templates exist but are NOT linked to the block by blockId (the shape
  // that made Block Planner 2 show an empty current block).
  await db
      .collection('users')
      .doc(kFxAthlete)
      .collection('templates')
      .doc('tplA')
      .set({
    'name': 'Upper',
    'exercises': [
      {'exerciseId': kFxBench, 'name': kFxNames[kFxBench]}
    ],
  });
  await blocks
      .doc(kFxActive)
      .collection('weeks')
      .doc('week_0')
      .collection('days')
      .doc('day_0')
      .set({
    'exercises': [
      {
        'exerciseId': kFxBench,
        'name': kFxNames[kFxBench],
        'circuitIndex': 0,
        'orderIndex': 0,
        'sets': [
          {'weight': 100.0, 'reps': 5},
          {},
        ],
        'plannedByCoach': true, // unknown day-row field
      }
    ],
  });
}

Future<Map<String, dynamic>> fxBlock(FakeFirebaseFirestore db,
        [String id = kFxActive]) async =>
    (await db
            .collection('users')
            .doc(kFxAthlete)
            .collection('planned_blocks')
            .doc(id)
            .get())
        .data()!;
