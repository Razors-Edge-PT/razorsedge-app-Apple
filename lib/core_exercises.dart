import 'package:cloud_firestore/cloud_firestore.dart';

final List<Map<String, String>> coreExercises = [

 //Horizontal Press
  {
    'name': 'Bench Press, Barbell',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Incline Press, Barbell',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Flat Bench Dumbbell Press',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Incline Dumbbell Press',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Decline Bench Press, Barbell',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Decline Dumbbell Bench Press',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },

  {
    'name': 'Suspended Push Up',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Suspended, Banded Push Up',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Deficit Push Up',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Decline Push Up',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Push Up Off Bench',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Banded Push Up',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Weighted Push Up',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
  },
  {
    'name': 'Weighted Deficit Push Up',
    'category': 'Horizontal Press',
    'bodyPart': 'Chest, Triceps, Anterior Delts',
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
    'name': 'Suspended High Row',
    'category': 'Horizontal Pull',
    'bodyPart': 'Rear Delts, Mid Traps, Biceps',
  },
  {
    'name': 'Cable High Row',
    'category': 'Horizontal Pull',
    'bodyPart': 'Rear Delts, Mid Traps, Biceps',
  },
  {
    'name': 'Unilateral Cable High Row',
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
    'name': 'One Arm Row',
    'category': 'Horizontal Pull',
    'bodyPart': 'Lats, Biceps, Rhomboids',
  },
  {
    'name': 'Seated Row',
    'category': 'Horizontal Pull',
    'bodyPart': 'Lats, Rhomboids, Biceps',
  },
  {
    'name': 'Bent Over Row',
    'category': 'Horizontal Pull',
    'bodyPart': 'Lats, Rhomboids, Biceps',
  },
  {
    'name': 'Cable Low Row',
    'category': 'Horizontal Pull',
    'bodyPart': 'Lats, Rhomboids, Biceps',
  },

  //vertical Press
  {
    'name': 'Overhead Barbell Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Unilateral Overhead Dumbbell Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Overhead Dumbbell Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Hand Stand Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Deficit Hand Stand Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Circus Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Log Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Triceps Dips',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps, Shoulders',
  },
  {
    'name': 'Land Mine Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Plate Loaded Machine Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Pin Loaded Machine Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
  },
  {
    'name': 'Smith Machine Press',
    'category': 'Vertical Press',
    'bodyPart': 'Shoulders, Triceps',
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
    'name': 'Wide Arm Lat Pull Down',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Supinated Lat Pull Down',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Unilateral Lat Pull Down',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Biceps',
  },
  {
    'name': 'Straight Arm Lat Pull Down',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Triceps',
  },
  {
    'name': 'Lat Prayer',
    'category': 'Vertical Pull',
    'bodyPart': 'Lats, Triceps',
  },
  {
    'name': 'Bench Cable Straight Arm Lat Pull',
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

  //Arm Extension

  {
    'name': 'Triceps Push down',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Unilateral Triceps Push down',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Unilateral Overhead Cable Triceps Extension',
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
    'name': 'Unilateral Suspended Triceps Extension',
    'category': 'Arm Extension',
    'bodyPart': 'Triceps',
  },
  {
    'name': 'Skull Crusher',
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
    'name': 'Unilateral Cable Biceps Curl',
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

  //Hip Hinge
  {
    'name': 'Deadlift, Conventional',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Deadlift, Sumo',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Romanian Deadlift',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes, Lower Back',
  },
  {
    'name': 'Unilateral Romanian Deadlift',
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
    'name': 'Unilateral Hip Thrust, Barbell',
    'category': 'Hip Hinge',
    'bodyPart': 'Hamstrings, Glutes',
  },
  {
    'name': 'Banded Hip Thrust, Barbell',
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
    'name': 'Bulgarian Split Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Walking Lunge',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Regular Split Squat',
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
    'name': 'Unilateral Leg Press',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Hack Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Unilateral Hack Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },
  {
    'name': 'Smith Machine Squat',
    'category': 'Squat Pattern',
    'bodyPart': 'Quads, Glutes',
  },

  //Leg Extension
  {
    'name': 'Unilateral Leg Extension',
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
    'name': 'Unilateral Lying Leg Curl',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings',
  },
  {
    'name': 'Lying Leg Curl',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings',
  },

  {
    'name': 'Unilateral Seated Leg Curl',
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
    'name': 'Unilateral Suspended Leg Curl',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings, Calves',
  },
  {
    'name': 'Suspended Leg Curl',
    'category': 'Leg Curl',
    'bodyPart': 'Hamstrings, Calves',
  },

  //Hip Abduction/Adduction

  //Calf Raise
  {
    'name': 'Standing Calf Raise',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Unilateral Standing Calf Raise',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Unilateral Leg Press Calf Raise',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Leg Press Calf Raise',
    'category': 'Calf Raise',
    'bodyPart': 'Calves',
  },
  {
    'name': 'Unilateral Seated Calf Raise',
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



