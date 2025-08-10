import 'package:cloud_firestore/cloud_firestore.dart';

final List<Map<String, String>> coreExercises = [

 //Horizontal Press
  {
    'name': 'Bench Press, Barbell',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Bench Press, Narrow Grip',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Bench Press, Larsen Press',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Bench Press, Long Pause',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Bench Press, Banded',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Bench Press, Pin Press',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Bench Press, Touch n Go',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Incline Press, Barbell',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Flat Bench Dumbbell Press',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Incline Bench Dumbbell Press',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Decline Bench Press, Barbell',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Decline Dumbbell Bench Press',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },

  {
    'name': 'Push Up, Suspended ',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Banded Push Up, Suspended',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Push Up, Deficit',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Push Up, Decline',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Push Up Off Bench',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Push Up, Banded',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Push Up, Weighted',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Weighted Push Up, Deficit ',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Machine Chest Press, Plate Loaded',
    'category': 'Vertical Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Machine Chest Press, Pin Loaded',
    'category': 'Vertical Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Chest Press, Smith Machine',
    'category': 'Vertical Press',
    'bodyPart': 'Chest, Anterior Delts, Triceps',
  },
  {
    'name': 'Cable Fly',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts',
  },
  {
    'name': 'Bayesian Fly',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts',
  },
  {
    'name': 'Suspended Fly',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Anterior Delts',
  },


  //Horizontal Pull
  {
    'name': 'High Row, Suspended',
    'category': 'Horizontal Pull',
    'bodyPart': 'Rear Delts, Mid Traps, Biceps',
  },
  {
    'name': 'Cable High Row',
    'category': 'Horizontal Pull',
    'bodyPart': 'Rear Delts, Mid Traps, Biceps',
  },
  {
    'name': 'Cable High Row, Unilateral',
    'category': 'Horizontal Pull',
    'bodyPart': 'Rear Delts, Mid Traps, Biceps',
  },
  {
    'name': 'KP Face Pull',
    'category': 'Horizontal Pull',
    'bodyPart': 'Rear Delts, Mid Traps, Biceps',
  },
  {
    'name': 'Reverse Bayesian Fly',
    'category': 'Horizontal Pull',
    'bodyPart': 'Rear Delts, Mid Traps',
  },
  {
    'name': 'Suspended Reverse Fly',
    'category': 'Horizontal Pull',
    'bodyPart': 'Rear Delts, Mid Traps',
  },
  {
    'name': 'One Arm Row, Dumbbell',
    'category': 'Horizontal Pull',
    'bodyPart': 'Lats, Biceps, Rhomboids',
  },
  {
    'name': 'Seated Row, Cable',
    'category': 'Horizontal Pull',
    'bodyPart': 'Lats, Rhomboids, Biceps',
  },
  {
    'name': 'Bent Over Row, Barbell',
    'category': 'Horizontal Pull',
    'bodyPart': 'Lats, Rhomboids, Biceps',
  },
  {
    'name': 'Cable Low Row, Unilateral',
    'category': 'Horizontal Pull',
    'bodyPart': 'Lats, Rhomboids, Biceps',
  },

  //vertical Press
  {
    'name': 'Overhead Barbell Press',
    'category': 'Vertical Press',
    'bodyPart': 'Anterior Delts, Lateral Delts, Triceps',
  },
  {
    'name': 'Overhead Dumbbell Press, Unilateral',
    'category': 'Vertical Press',
    'bodyPart': 'Lateral Delts, Anterior Delts, Triceps',
  },
  {
    'name': 'Overhead Dumbbell Press',
    'category': 'Vertical Press',
    'bodyPart': 'Lateral Delts, Anterior Delts, Triceps',
  },
  {
    'name': 'Hand Stand Press Up',
    'category': 'Vertical Press',
    'bodyPart': 'Anterior Delts, Lateral Delts, Triceps',
  },
  {
    'name': 'Deficit Hand Stand Press Up',
    'category': 'Vertical Press',
    'bodyPart': 'Anterior Delts, Lateral Delts, Triceps',
  },
  {
    'name': 'Circus Dumbbell Press',
    'category': 'Vertical Press',
    'bodyPart': 'Lateral Delts, Anterior Delts, Triceps',
  },
  {
    'name': 'Log Press',
    'category': 'Vertical Press',
    'bodyPart': 'Anterior Delts, Lateral Delts, Triceps',
  },
  {
    'name': 'Triceps Dip',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps, Chest',
  },
  {
    'name': 'Land Mine Press',
    'category': 'Vertical Press',
    'bodyPart': 'Lateral Delts, Anterior Delts, Triceps',
  },
  {
    'name': 'Machine Shoulder Press, Plate Loaded',
    'category': 'Vertical Press',
    'bodyPart': 'Anterior Delts, Lateral Delts, Triceps',
  },
  {
    'name': 'Machine Shoulder Press, Pin Loaded',
    'category': 'Vertical Press',
    'bodyPart': 'Anterior Delts, Lateral Delts, Triceps',
  },
  {
    'name': 'Shoulder Press, Smith Machine',
    'category': 'Vertical Press',
    'bodyPart': 'Anterior Delts, Lateral Delts, Triceps',
  },


  //vertical Pull
  {
    'name': 'Chin-Up',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Pull-Up',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Lat Pull Down, Wide Arm ',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Lat Pull Down, Supinated',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Lat Pull Down, Unilateral ',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Machine Lat Pull Down',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Lat Pull Over, Machine',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Lat Pull Down, Straight Arm',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Triceps',
  },
  {
    'name': 'Lat Prayer',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Triceps',
  },
  {
    'name': 'Bench Lat Pull Down, Straight Arm',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Triceps',
  },


//Lateral Raise
  {
    'name': 'Dumbbell Lateral Raise',
    'category': 'Lateral Raise',
    'bodyPart': 'Lateral Delts, Anterior Delts',
  },
  {
    'name': 'Cable Lateral Raise',
    'category': 'Lateral Raise',
    'bodyPart': 'Lateral Delts, Anterior Delts',
  },
  {
    'name': 'Butterfly Dumbbell Raise',
    'category': 'Lateral Raise',
    'bodyPart': 'Lateral Delts, Anterior Delts',
  },
  {
    'name': 'Seated Dumbbell Raise',
    'category': 'Lateral Raise',
    'bodyPart': 'Lateral Delts, Anterior Delts',
  },
  {
    'name': 'Reverse Seated Dumbbell Raise',
    'category': 'Lateral Raise',
    'bodyPart': 'Lateral Delts, Anterior Delts',
  },
  {
    'name': 'Seated Lateral Raise Machine',
    'category': 'Lateral Raise',
    'bodyPart': 'Lateral Delts, Anterior Delts',
  },
  {
    'name': 'Standing Lateral Raise Machine',
    'category': 'Lateral Raise',
    'bodyPart': 'Lateral Delts, Anterior Delts',
  },

  //Arm Extension

  {
    'name': 'Triceps Push down',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Triceps Push down, Unilateral',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Overhead Cable Triceps Extension, Unilateral',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Overhead Cable Triceps Extension',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Suspended Triceps Extension',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Suspended Triceps Extension, Unilateral',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Skull Crusher, Barbell',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Skull Crusher, Dumbbells',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },


  //Arm Curl
  {
    'name': 'Barbell Biceps Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Dumbbell Biceps Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Bayesian Biceps Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Cable Biceps Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Cable Biceps Curl, Unilateral',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Preacher Biceps Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Dumbbell Biceps Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Cable High Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Hammer Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },
  {
    'name': 'Machine Biceps Curl',
    'category': 'Arm Curl',
    'bodyPart': 'Biceps',
  },

  //Hip Hinge
  {
    'name': 'Deadlift, Conventional',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Deadlift, Deficit',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Deadlift, Sumo',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Deadlift, Sumo, Deficit',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Romanian Deadlift',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Romanian Deadlift, Unilateral',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': '45 Degree Hip Extension',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Single Leg Deadlift',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Hip Thrust, Barbell',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes',
  },
  {
    'name': 'Hip Thrust, Barbell, Unilateral',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes',
  },
  {
    'name': 'Banded Hip Thrust, Barbell',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes',
  },
  {
    'name': 'Machine Hip Thrust',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes',
  },


  //Squat Pattern
  {
    'name': 'Back Squat, Barbell',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Back Squat, Low bar',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Back Squat, Pin Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Back Squat, Paused Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Back Squat, Banded',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Bulgarian Split Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Bulgarian Split Squat, Deficit',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Walking Lunge',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Split Squat, Standard',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Front Squat, Barbell',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Goblet Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Sissy Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },

  {
    'name': 'Leg Press',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Leg Press, Unilateral',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Hack Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Hack Squat, Unilateral',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Smith Machine Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Smith Machine Leg Press',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },

  //Leg Extension
  {
    'name': 'Leg Extension, Unilateral',
    'category': 'Leg Extension',
    'bodyPart': 'Quads',
  },
  {
    'name': 'Leg Extension',
    'category': 'Leg Extension',
    'bodyPart': 'Quads',
  },
  //Leg Curl

  {
    'name': 'Lying Leg Curl, Unilateral',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings',
  },
  {
    'name': 'Lying Leg Curl',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings',
  },

  {
    'name': 'Seated Leg Curl, Unilateral',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings',
  },
  {
    'name': 'Seated Leg Curl',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings',
  },

  {
    'name': 'Standing Leg Curl',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings',
  },

  {
    'name': 'Suspended Leg Curl, Unilateral',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings, Calves',
  },
  {
    'name': 'Suspended Leg Curl',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings, Calves',
  },

  //Hip Abduction/Adduction
  {
    'name': 'Machine Hip Abduction',
    'category': 'Hip Abduction',
    'bodyPart': 'Glutes',
  },
  {
    'name': 'Machine Hip Adduction',
    'category': 'Hip Adduction',
    'bodyPart': 'Inner Thigh',
  },
  //Calf Raise
  {
    'name': 'Standing Calf Raise',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Standing Calf Raise, Unilateral',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Leg Press Calf Raise, Unilateral',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Leg Press Calf Raise',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Seated Calf Raise, Unilateral',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Seated Calf Raise',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },

  //Core
  {
    'name': 'Plank',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Weighted Plank',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Long Lever Plank',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Weighted Long Lever Plank',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Alternating Plank',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Side Plank',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Hanging Leg Raise',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Hanging Knee Raise',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Decline Crunch',
    'category': 'Core',
    'bodyPart': 'Core',
  },
  {
    'name': 'Russian Twist',
    'category': 'Core',
    'bodyPart': 'Core',
  },

];

Future<void> uploadCoreExercisesToFirestore() async {
  final FirebaseFirestore firestore = FirebaseFirestore.instance;
  final CollectionReference exercisesCollection = firestore.collection('exercises');

  for (final exercise in coreExercises) {
    final name = exercise['name'];
    final category = exercise['category'];
    final bodyPart = exercise['bodyPart'];

    if (name == null || category == null || bodyPart == null) continue;

    // Check for existing exercise by name
    final existing = await exercisesCollection.where('name', isEqualTo: name).get();

    if (existing.docs.isEmpty) {
      await exercisesCollection.add({
        'name': name,
        'category': category,
        'bodyPart': bodyPart,
      });
      print('✅ Uploaded: $name');
    } else {
      print('⚠️ Skipped duplicate: $name');
    }
  }

  print('🎉 Upload complete!');
}



