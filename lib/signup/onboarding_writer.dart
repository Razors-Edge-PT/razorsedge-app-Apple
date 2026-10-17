/// The Firestore writes behind Page 2's Finish (signup) and Save Changes
/// (edit from Templates / the drawer).
///
/// Extracted verbatim from `OnboardingPageTwo._finish()` so that both modes
/// run ONE implementation and so the signup coordinator can retry it. Every
/// write is a field-level merge, so replaying the whole sequence after a
/// partial failure converges on the same document; paths and field names are
/// unchanged.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../periodization_model_utils.dart';
import 'onboarding_models.dart';

/// Writes users/{uid}/profile/fitness_onboarding (and the users/{uid}
/// weeklyFrequency mirror) for [submission].
Future<void> writeFitnessOnboarding(
  FirebaseFirestore db,
  String uid,
  OnboardingSubmission submission,
) async {
  final onbRef = db
      .collection('users')
      .doc(uid)
      .collection('profile')
      .doc('fitness_onboarding');

  // Clear old painNow entries so deselected injuries don't linger.
  await onbRef.set({'painNow': FieldValue.delete()}, SetOptions(merge: true));

  // Fresh onboarding answers (including the new painNow map).
  await onbRef.set(submission.answers().toJson(), SetOptions(merge: true));

  // Shoulder / elbow pain detail flags (flat keys).
  final painDetailFlags = submission.painDetailFlags();
  if (painDetailFlags.isNotEmpty) {
    await onbRef.set(painDetailFlags, SetOptions(merge: true));
  }

  await onbRef.set(
      {'bodyFocusLevel': submission.bodyFocusLevel}, SetOptions(merge: true));

  // Child/sub-group levels (explicit zeros kept).
  final children = submission.bodyFocusChildren;
  if (children.isNotEmpty) {
    await onbRef.set({'bodyFocusChildren': children}, SetOptions(merge: true));
  }

  // Final goals order + the "not important" bin.
  await onbRef.set({
    'goalsRanked': submission.goalsRanked,
    'goalsNotImportant': submission.goalsNotImportant,
  }, SetOptions(merge: true));

  // Equipment snapshot.
  await onbRef.set({
    'environment': submission.environment, // 'commercial' | 'powerlifting' | 'home' | 'travelling'
    'equipment': {
      'items': submission.equipmentItems,
      'dumbbellsMax': submission.dumbbellsMax, // nullable int (-1 = None)
    },
  }, SetOptions(merge: true));

  // PT experience (if answered): selection 0..3 → stable bucket + canonical text.
  final pt = submission.ptHistoryIndex;
  if (pt != null) {
    const buckets = ['none', 'lt3', '4to16', 'gt16'];
    const canonicalText = ['No', '<3 sessions', '4–16 sessions', '16+ sessions'];
    await onbRef.set({
      'ptHistory': {
        'index': pt,
        'bucket': buckets[pt],
        'text': canonicalText[pt],
        'savedAt': FieldValue.serverTimestamp(),
      },
    }, SetOptions(merge: true));
  }

  // Weekly training frequency (explicit mirror of minTrainingDaysPerWeek).
  await onbRef.set({
    'weeklyFrequency': submission.weeklyFrequency,
    'minTrainingDaysPerWeek': submission.weeklyFrequency, // legacy alias
    'weeklyFrequencySavedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  // Also surfaced on the top-level users doc for fast reads.
  await db.collection('users').doc(uid).set({
    'weeklyFrequency': submission.weeklyFrequency,
  }, SetOptions(merge: true));
}

/// liftKey (from [OnboardingFormData.collectBestEfforts]) → exercise id.
const Map<String, String> kBestEffortLiftKeyToExerciseId = {
  // Bench variants
  'bench_barbell': 'AmfUWbF1DH3I7qPAdh5k', // Bench Press, Barbell
  'bench_db': 'kTs5fLSTKjUkUZL10iii', // Flat Bench Dumbbell Press
  'chest_press': 'uY8uJaSFK9czKIX4TLc4', // Machine Chest Press
  // Squat variants
  'back_squat': 'heeBViVINHO6tUScSd6y', // Back Squat, Barbell
  'leg_press': 'v2XlZUvFfBUhogOdKtJ8', // Leg Press
  // Pull variants
  'lat_pulldown_supinated': '1XOIXxeLFhgmgjZS9Cyq', // Lat Pull Down, Supinated
  'lat_pulldown_wide': 'Url65Q2RxZa00dkDpUdl', // Lat Pull Down, Wide Arm
  // Deadlift
  'deadlift': 'MsGl7e9yanDeEnYX0e4X', // Deadlift, Conventional
};

/// Writes best-effort PRs into the current block's exerciseSettings. A no-op
/// when nothing was entered or there is no current block pointer.
Future<void> writeBestEffortsToCurrentBlock(
  FirebaseFirestore db,
  String uid,
  List<BestEffort> bestEfforts,
) async {
  final currentBlockSnap = await db
      .collection('users')
      .doc(uid)
      .collection('block_planner')
      .doc('current_block')
      .get();

  final String? blockIdToUse =
      (currentBlockSnap.data() ?? const {})['blockId'] as String?;

  if (blockIdToUse == null || blockIdToUse.trim().isEmpty) {
    debugPrint('❌ [Onboarding Finish] No current blockId found after seeding.');
    return;
  }

  // 150.0 -> "150", 45.5 -> "45.5"
  String fmtWeight(double w) => w % 1 == 0 ? w.toInt().toString() : w.toString();

  final Map<String, dynamic> updates = {};
  for (final be in bestEfforts) {
    final exerciseId = kBestEffortLiftKeyToExerciseId[be.liftKey];
    if (exerciseId == null) {
      debugPrint('⚠️ [Onboarding Finish] Unknown liftKey: ${be.liftKey}');
      continue;
    }
    final weight = be.weightKg;
    if (weight == null) continue; // skip if weight missing

    final int reps = (be.reps == null || be.reps! <= 0) ? 1 : be.reps!;
    final manual = '${fmtWeight(weight)} X $reps';
    final double e1rm = PeriodizationModelUtils.calculateE1RM(
      weight,
      reps.toDouble(),
      0.0, // ignore RIR, default 0
    );

    final settings = (updates['exerciseSettings'] ??= <String, dynamic>{})
        as Map<String, dynamic>;
    final perExercise = settings.putIfAbsent(exerciseId, () => <String, dynamic>{})
        as Map<String, dynamic>;
    perExercise['maxWeightByReps_manual'] = manual;
    perExercise['e1rm'] = e1rm;
  }

  if (updates.isNotEmpty) {
    await db
        .collection('users')
        .doc(uid)
        .collection('planned_blocks')
        .doc(blockIdToUse)
        .set(updates, SetOptions(merge: true));
    debugPrint('✅ [Onboarding Finish] Wrote best-efforts into block=$blockIdToUse');
  } else {
    debugPrint('ℹ️ [Onboarding Finish] No best-effort values provided; skipping block writes.');
  }
}
