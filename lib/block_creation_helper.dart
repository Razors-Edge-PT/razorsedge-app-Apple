import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// Shared block-creation constants and helpers.
/// Used by home_screen, planned_blocks_screen, create_new_account_screen, Block_Planner.
const int kDefaultBlockWeeks = 26;

/// Inclusive end date for a 26-week block: day 0 = startDate, last day = startDate + 181.
DateTime blockEndDate(DateTime start) =>
    start.add(const Duration(days: kDefaultBlockWeeks * 7 - 1));

/// Loads all exercise IDs from the Firestore exercises collection.
Future<List<String>> loadAllExerciseIds() async {
  final snap = await FirebaseFirestore.instance.collection('exercises').get();
  return snap.docs.map((d) => d.id).toList();
}

/// Scaffolds week/day subcollection docs for an already-created block document.
/// Never creates block docs — only subcollection docs under the supplied [blockRef].
/// Fire-and-forget safe: catches all errors, sets scaffoldReady on success, idempotent.
Future<void> scaffoldBlockInBackground(
  DocumentReference<Map<String, dynamic>> blockRef,
  DateTime startDate, {
  int startWeek = 0,
  int totalWeeks = 26,
}) async {
  try {
    debugPrint('🧱 [scaffold] start: ${blockRef.id} weeks $startWeek–${totalWeeks - 1}');
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const weekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    final batch = FirebaseFirestore.instance.batch();
    for (int week = startWeek; week < totalWeeks; week++) {
      final weekRef = blockRef.collection('weeks').doc('week_$week');
      batch.set(weekRef, {'exists': true}, SetOptions(merge: true));
      for (int day = 0; day < 7; day++) {
        final date = startDate.add(Duration(days: week * 7 + day));
        batch.set(weekRef.collection('days').doc('day_$day'), {
          'date': Timestamp.fromDate(date),
          'circuitStartIndices': [0],
          'exercises': [],
          'workoutName': '${weekdays[day]} ${date.day} ${months[date.month - 1]} - Week ${week + 1}',
          'exists': true,
        }, SetOptions(merge: true));
      }
    }
    batch.set(blockRef, {'scaffoldReady': true}, SetOptions(merge: true));
    await batch.commit();
    debugPrint('🧱 [scaffold] done: ${blockRef.id}');
  } catch (e, st) {
    debugPrint('❌ [scaffold] failed for ${blockRef.id}: $e\n$st');
  }
}

/// Sex-derived candidate pool for templateCandidateExerciseIds.
/// These are the exercises for which defaults are pre-seeded in exerciseSettings.
List<String> computeTemplateCandidateIds({required bool isFemale}) {
  return [
    ..._baseExercises,
    if (isFemale) ..._femaleSpecificExercises else ..._maleSpecificExercises,
  ];
}

// ── Exercise constants (canonical source — consolidated from all creation sites) ─

const List<String> _baseExercises = [
  'AmfUWbF1DH3I7qPAdh5k', // Bench Press, Barbell
  'kTs5fLSTKjUkUZL10iii', // Flat Bench Dumbbell Press
  'heeBViVINHO6tUScSd6y', // Back Squat, Barbell
  'y5q9OU9OBzZQMkfPzFrf', // Romanian Deadlift
  'v2XlZUvFfBUhogOdKtJ8', // Leg Press
  'lVDG90yN6Z8aPjRNV2wc', // Overhead Barbell Press
  '2yJSfLMfOnNDSeZ7DqZT', // Overhead Dumbbell Press
  '9siQpXF2KLCj7M9kCy2m', // Seated Shoulder Dumbbell Press
  '1XOIXxeLFhgmgjZS9Cyq', // Lat Pull Down, Supinated
  'Url65Q2RxZa00dkDpUdl', // Lat Pull Down, Wide Arm
  'JbthLLjMF6xRvvaUY8PU', // Lat Pull Down, Unilateral
  'ETm055bydWtUCxTMu3MR', // Seated Leg Curl
  'wIcMsf2J9cswJRs1GuYX', // Lying Leg Curl
  'QkEgE8gnIva2kkNJEfxw', // Leg Extension
  'ZKpGshMxFl2dxNmYSATj', // Leg Extension, Unilateral
  'ci3KpMTEacH4bw8ZumJW', // Standing Calf Raise
  'spGqXXReJNHMcc62YgZX', // Seated Calf Raise
  'WPb8rtRTupKIBzgydB5k', // Cable Biceps Curl
  '0dZrCqZ8M7Q1sAn0zeeb', // Dumbbell Biceps Curl
  'zn5PgKNRrWo1MTE4wnCy', // Bayesian Biceps Curl
  'E6jPE8YYR0KA3xtVaKJo', // Triceps Push Down
  'QacImADmlpljltUvB0dD', // Overhead Cable Triceps Extension
  'eeEXnmSXv90q0rUgGECq', // KP Face Pull
  'KPewxxYYrhsOp84lIQr5', // Suspended High Row
  'P88Vj5pBydqmiEzFowag', // Hanging Straight Leg Raise
  'uY8uJaSFK9czKIX4TLc4', // Machine Chest Press
  'FtayDmR5BVnGS1FX1XLL', // Triceps Dip
  'OJaMXFKgMnM0X5xttBE1', // Cable Face Pull
  '6SGWrCKfe7KQLThRYXQ6', // One Arm Row, Dumbbell
  'Z1LpfaEBvHBDMsJ54pgw', // Hack Squat
  'z5gs1ilr4DpKlSZaRNG5', // Overhead Cable Triceps Extension, Unilateral
  'LVMQEQl6ZWBcgEUdk2tP', // Leg Press Calf Raise
  'ISXQqOEXLjMrPEs0xjgJ', // Bulgarian Split Squat
  'ocNWJv7xLrlinGmjG6cV', // Machine Row, Supported
  'eyh76KELuuO805rZBpMa', // 45 Degree Hip Extension
  'RdsGazgdH0xgpjek0n3u', // Overhead Dumbbell Press, Unilateral
  'xWpCQO504iGfU3LKLZlD', // Cable High Row, Unilateral
  'XM9026peNIu0R8qh7UqY', // Chin-Up
];

const List<String> _maleSpecificExercises = [
  '6d9Ud7ffAHpljWsSKrFe', // Seated Face Pull
  'TBSudbow1OLdX6mSCC6S', // Machine Chest Fly
  '72HAT6Od4iJodEFxzw62', // Machine Reverse Fly
  'igNo9pSuaOFt0GVX0zBG', // Cable Lateral Raise
  'ZKrfhPhJIiC1hRuwBEw1', // Bayesian Fly
  'RcC48r0oLsNCH798d3jc', // Butterfly Dumbbell Raise
  'ewJBWuDzj1CxfQ3vI3QS', // Reverse Bayesian Fly
  '8saP9lWMoQffuh30A99K', // Lat Prayer
  '0s4yMXygBXZZJH66Yi6h', // Seated Face Pull, Unilateral
];

const List<String> _femaleSpecificExercises = [
  'vrSYibzR5DHzl6Gzp4ER', // Machine Shoulder Press, Pin Loaded
  '3dWgorRmtgzsV0U4qu47', // Glute Cable Kick Back
  'kxgQUX7Cr75l1kOwRaqc', // Spider-Girl Plank
  'YaQ0FCQEUAk4ALwAPhv2', // Machine Hip Thrust
  'visub8iG0LIXYYCv5Qom', // Hip Thrust, Unilateral
  'LGhFj8o0sG3X12296UAh', // Hip Thrust, Barbell
  'hCpQR1NgeEAp31lVRWLw', // Machine Hip Adduction
  '7WBffXwK7vJcMi3mtJTF', // Machine Hip Abduction
  't66qeWQqnuEtaoyZqRp0', // Triceps Dip Machine
  'zpNb7HgXjtcrzR14F3iF', // Cable One Arm Row
  '8CIXN12uS2xwF4JzVLq3', // Long Lever Plank
  'SoHQVtsCQreaHM8LUI5F', // Bicycle Crunch
  'qU2wXMth4duOhhzTUWet', // Decline Crunch
];
