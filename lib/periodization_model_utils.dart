import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart'; // Import for date formatting
import 'package:localtest222/workout_model.dart';
import 'exercise_selection_screen.dart';
import 'template_model.dart';
import 'templates.dart';
import 'exercise_details_screen.dart'; // Import your exercise details screen
import 'top_sets_screen.dart';

class PeriodizationModelUtils {
  static final Map<String, List<double>> exercisePreviousE1RMs = {}; // ✅ E1RM history per exercise
  static final Map<String, List<int>> exercisePreviousTopSetReps = {}; // ✅ Tracks reps per exercise


  // ✅ Global function to calculate E1RM based on weight, reps, and RIR
  static double calculateE1RM(double? weight, double? reps, double? rir) {
    double w = weight ?? 0.0;
    double r = reps ?? 0.0;
    double rValue = rir ?? 0.5; // ✅ Default RIR if missing
    double totalReps = r + rValue;

    if (totalReps <= 6) {
      return w * (36 / (37 - totalReps)); // ✅ Brzycki Formula
    } else {
      return w * (1 + (0.0333 * totalReps)); // ✅ Epley Formula
    }
  }



  static double getAverageE1RM(String exerciseName) {
    if (!exercisePreviousE1RMs.containsKey(exerciseName) || exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      return 0.0; // ✅ Default if no history
    }

    List<double> recentE1RMs = exercisePreviousE1RMs[exerciseName]!.take(4).toList();
    return recentE1RMs.reduce((a, b) => a + b) / recentE1RMs.length;
  }

  //Last two E1RM's combined
  static double getCombinedE1RM(String exerciseName) {
    if (!exercisePreviousE1RMs.containsKey(exerciseName) || exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      return 0.0; // ✅ Default if no history
    }

    // ✅ Get the last 2 E1RMs (or fewer if there aren't 2)
    List<double> recentE1RMs = exercisePreviousE1RMs[exerciseName]!.take(2).toList();

    // ✅ Sum them together
    return recentE1RMs.reduce((a, b) => a + b);
  }

  static int getThirdMostRecentTopSetReps(String exerciseName) {
    if (!exercisePreviousTopSetReps.containsKey(exerciseName) ||
        exercisePreviousTopSetReps[exerciseName]!.length < 6) {
      return 0; // ✅ Default to 0 if there aren’t enough past workouts
    }

    return exercisePreviousTopSetReps[exerciseName]![5]; // ✅ Index 2 = 3rd most recent
  }


  //Last set top set reps
  static int getLastTopSetReps(String exerciseName) {
    if (!exercisePreviousTopSetReps.containsKey(exerciseName) || exercisePreviousTopSetReps[exerciseName]!.isEmpty) {
      return 0; // ✅ Default to 0 if no history
    }

    // ✅ Get the last top set reps (most recent)
    return exercisePreviousTopSetReps[exerciseName]!.first;
  }

  static List<int> getAllStoredTopSetReps(String exerciseName) {
    if (!exercisePreviousTopSetReps.containsKey(exerciseName) ||
        exercisePreviousTopSetReps[exerciseName]!.isEmpty) {
      return []; // ✅ Return empty list if no data
    }

    return exercisePreviousTopSetReps[exerciseName]!; // ✅ Return full list of stored reps
  }


  static Future<void> fetchLastWorkoutTopSetReps() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('workouts')
        .orderBy('date', descending: true) // ✅ Fetch newest first
        .limit(12) // ✅ Get last 12 workouts
        .get();

    if (snapshot.docs.isNotEmpty) {
      // ✅ Clear ONLY if new data exists
      if (exercisePreviousTopSetReps.isNotEmpty || exercisePreviousE1RMs.isNotEmpty) {
        exercisePreviousTopSetReps.clear();
        exercisePreviousE1RMs.clear();
      }

      for (var doc in snapshot.docs) {
        final workout = Workout.fromFirestore(doc);

        for (var exercise in workout.exercises) {
          String exerciseName = exercise.name;

          SetDetails? topSet;
          double highestE1RM = 0.0;

          for (var set in exercise.sets) {
            double weight = _parseToDouble(set.weight);
            double reps = _parseToDouble(set.reps);
            double rir = _parseToDouble(set.rir);
            double totalReps = reps + rir;

            double e1rm = (totalReps <= 6)
                ? (weight * (36 / (37 - totalReps))) // Brzycki
                : (weight * (1 + (0.0333 * totalReps))); // Epley

            if (topSet == null || e1rm > highestE1RM) {
              highestE1RM = e1rm;
              topSet = set;
            }
          }

          if (topSet != null) {
            int effectiveReps = (_parseToDouble(topSet.reps) + _parseToDouble(topSet.rir)).floor();

            exercisePreviousE1RMs.putIfAbsent(exerciseName, () => []);
            exercisePreviousE1RMs[exerciseName]!.add(highestE1RM);

            // ✅ Always store the top set reps (no condition)
            exercisePreviousTopSetReps.putIfAbsent(exerciseName, () => []);
            exercisePreviousTopSetReps[exerciseName]!.add(effectiveReps);

// ✅ Ensure only last 12 are stored
            if (exercisePreviousTopSetReps[exerciseName]!.length > 12) {
              exercisePreviousTopSetReps[exerciseName] =
                  exercisePreviousTopSetReps[exerciseName]!.take(12).toList();
            }

// ✅ Then, limit E1RM storage separately (if needed)
            if (exercisePreviousE1RMs[exerciseName]!.length > 4) {
              exercisePreviousE1RMs[exerciseName] =
                  exercisePreviousE1RMs[exerciseName]!.take(4).toList();
            }

          }
        }
      }
    }
  }


  static List<int> getForbiddenRepTargets(String exerciseName) {
    List<int>? pastReps = exercisePreviousTopSetReps[exerciseName];
    if (pastReps == null) return []; // ✅ Handle missing data

    Set<int> forbiddenReps = {};

    for (int i = 0; i < pastReps.length; i++) {
      int effectiveRep = pastReps[i]; // ✅ Now includes RIR (already adjusted)

      if (i == 0) {
        forbiddenReps.addAll([
          effectiveRep,
          effectiveRep - 2,
          effectiveRep - 1,
          effectiveRep + 1,
          effectiveRep + 2
        ]);
      } else if (i == 1) {
        forbiddenReps.addAll([effectiveRep - 1, effectiveRep, effectiveRep + 1]);
      } else if (i == 2 || i == 3) {
        forbiddenReps.add(effectiveRep);
      }
    }

    return forbiddenReps.where((rep) => rep >= 1).toList(); // ✅ Remove upper limit (previously 12)
  }

  static List<int> getAvailableRepTargets(String exerciseName, {int? setIndex}) {

    List<int> allReps = List.generate(12, (index) => index + 1);
    List<int> forbiddenReps = getForbiddenRepTargets(exerciseName);

    // ✅ Get available reps by filtering out forbidden ones
    List<int> availableReps = allReps.where((rep) => !forbiddenReps.contains(rep)).toList();

    // ✅ Sort available reps so the most distant target is first
    List<int>? pastReps = exercisePreviousTopSetReps[exerciseName];

    if (pastReps != null) {
      availableReps.sort((a, b) => pastReps.contains(a) ? 1 : -1);
    }

    return availableReps;
  }

  static int getSuggestedRepTarget(
      String exerciseName, {
        String? weightText,
        String? rirText,
        required int plannedIndex,
      })
  {
    // ✅ If weight is entered, use `updateRepTarget()` to calculate reps based on weight.
    if (weightText != null && weightText.isNotEmpty) {
      return updateRepTarget(exerciseName, weightText, rirText ?? "0.5",  plannedIndex,
      );
    }

    // ✅ Step 1: Get Available Rep Targets (which removes forbidden reps)
    List<int> availableReps = getAvailableRepTargets(exerciseName);
    if (availableReps.isEmpty) return 6; // ✅ Default to 6 if all reps are blocked

    // ✅ Step 2: Get Past Top Set Reps (last 12 workouts)
    List<int>? pastReps = exercisePreviousTopSetReps[exerciseName];
    if (pastReps == null || pastReps.isEmpty) return availableReps.first; // ✅ If no history, return first available

    // ✅ Step 3: Define Rep Groups
    List<List<int>> repGroups = [
      [1, 2],
      [3, 4],
      [5, 6, 7],
      [8, 9, 10],
      [11, 12],
      [13, 14, 15, 16, 17],
      [18, 19, 20, 21, 22],
      [23, 24, 25, 26, 27, 28],
      [29, 30, 31, 32, 33, 34, 35]
    ];

    // ✅ Step 4: Identify Used Groups in History
    Set<int> usedGroups = {};
    for (int rep in pastReps) {
      for (int i = 0; i < repGroups.length; i++) {
        if (repGroups[i].contains(rep)) {
          usedGroups.add(i); // ✅ Track used group indices
          break;
        }
      }
    }

    // ✅ Step 5: Find the Least Used Group (Only Considering Available Reps)
    int? bestGroupIndex;
    for (int i = 0; i < repGroups.length; i++) {
      if (!usedGroups.contains(i) && repGroups[i].any((rep) => availableReps.contains(rep))) {
        bestGroupIndex = i; // ✅ Found an unused group with available reps
        break;
      }
    }

    // ✅ Step 6: If All Groups Have Been Used, Pick the Least Recently Used Group
    if (bestGroupIndex == null) {
      Map<int, int> groupUsage = {}; // Group Index → Last Used Position
      for (int i = 0; i < pastReps.length; i++) {
        for (int j = 0; j < repGroups.length; j++) {
          if (repGroups[j].contains(pastReps[i])) {
            groupUsage[j] = i;
            break;
          }
        }
      }

      // ✅ Find the least recently used group
      bestGroupIndex = groupUsage.entries
          .toList()
          .reduce((a, b) => a.value > b.value ? a : b) // ✅ Find least recently used group
          .key;
    }

    // ✅ Step 7: Pick the Least Recently Used Rep Within That Group (Only from Available Reps)
    List<int> candidates = repGroups[bestGroupIndex!].where((rep) => availableReps.contains(rep)).toList();
    candidates.sort((a, b) => pastReps.contains(a) ? 1 : -1); // ✅ Prioritize least recently used

    // ✅ Ensure there's at least one candidate before calling `.first`
    if (candidates.isEmpty) {
      return availableReps.first; // ✅ Fall back to first available rep if no candidates exist
    }

    return candidates.first; // ✅ Return the best available rep
  }

  static int getPlannedCountBefore(
      List<String?> plannedExercises,
      String exerciseName,
      int currentIndex,
      ) {
    int count = 0;
    for (int i = 0; i < currentIndex; i++) {
      if (plannedExercises[i] == exerciseName) {
        count++;
      }
    }
    return count;
  }


  static List<int> upcomingRepTargetSequence(String exerciseName, int count) {
    // Start with current rep history
    List<int> history = List.from(exercisePreviousTopSetReps[exerciseName] ?? []);

    List<int> result = [];

    for (int i = 0; i < count; i++) {
      // Define inner logic for forbidden reps, scoped to current history
      Set<int> forbidden = {};
      for (int j = 0; j < history.length && j < 4; j++) {
        int rep = history[j];
        if (j == 0) {
          forbidden.addAll([rep - 2, rep - 1, rep, rep + 1, rep + 2]);
        } else if (j == 1) {
          forbidden.addAll([rep - 1, rep, rep + 1]);
        } else if (j == 2 || j == 3) {
          forbidden.add(rep);
        }
      }

      // Cap rep range
      List<int> allReps = List.generate(12, (i) => i + 1);
      List<int> available = allReps.where((r) => !forbidden.contains(r)).toList();

      // Sort by least recent usage
      available.sort((a, b) {
        int aIndex = history.indexOf(a);
        int bIndex = history.indexOf(b);
        if (aIndex == -1 && bIndex == -1) return a.compareTo(b); // both unused
        if (aIndex == -1) return -1; // a is less used
        if (bIndex == -1) return 1; // b is less used
        return aIndex.compareTo(bIndex);
      });

      // Pick best candidate
      int next = available.isNotEmpty ? available.first : 6; // fallback to 6
      result.add(next);

      // Prepend to history to simulate it becoming the most recent
      history.insert(0, next);
    }

    return result;
  }


  static int updateRepTarget(String exerciseName, String weightText, String rirText, int plannedIndex)
  {
    if (exerciseName.isEmpty) return 6; // ✅ Default to 6 if no exercise is selected

    // ✅ Check if the user has entered a weight
    bool hasUserWeightInput = weightText.isNotEmpty;

    if (hasUserWeightInput) {
      double avgE1RM = getAverageE1RM(exerciseName); // ✅ Get avg E1RM
      double weight = double.tryParse(weightText) ?? 0.0;

      if (weight <= 0 || avgE1RM <= weight) {
        return 1; // ✅ If weight is too high, set to 1 rep
      }

      // ✅ Reverse Brzycki/Epley formula to calculate reps
      double rawReps = (weight / avgE1RM < 0.85)
          ? ((avgE1RM / weight) - 1) / 0.0333  // ✅ Epley formula for higher reps
          : (37 - ((weight * 36) / avgE1RM));  // ✅ Brzycki formula for lower reps

      // ✅ Get the current RIR (user input or default)
      double rir = double.tryParse(rirText) ?? 0.5;

      // ✅ Subtract RIR from calculated reps
      double finalReps = (rawReps - rir).clamp(1.0, 200.0);

      // ✅ Round reps intelligently
      finalReps = (finalReps - finalReps.floor() >= 0.652)
          ? finalReps.ceil().toDouble()
          : finalReps.floor().toDouble();

      return finalReps.toInt(); // ✅ Return final calculated reps as an integer
    }

    // ✅ If no weight entered, return default suggested rep target
    return upcomingRepTargetSequence(exerciseName, plannedIndex + 1).last;

  }



  static double getSuggestedWeight(
      String exerciseName,
      TextEditingController repsController,
      TextEditingController rirController,
      int plannedIndex,
      Map<String, List<Map<String, dynamic>>>? topSetsByExercise, // ✅ new optional param
      ) {
    if (!exercisePreviousE1RMs.containsKey(exerciseName) || exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      return 20.0;
    }

    double avgE1RM = getAverageE1RM(exerciseName);

    // ✅ Use upcoming rep target based on the planned index
    int reps = int.tryParse(repsController.text) ??
        upcomingRepTargetSequence(exerciseName, plannedIndex + 1).last;
    double rir = double.tryParse(rirController.text) ?? 0.5;
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      suggestedWeight = avgE1RM * (37 - effectiveReps) / 36;
    } else {
      suggestedWeight = avgE1RM / (1 + (0.0333 * effectiveReps));
    }

    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);
    return (suggestedWeight / 2.5).round() * 2.5;
  }


  static double getSuggestedWeightFromRep(String exerciseName, int reps, double rir) {
    final e1rms = exercisePreviousE1RMs[exerciseName];
    if (e1rms == null || e1rms.isEmpty) return 20.0;

    final recent = e1rms.take(4).toList();
    final avgE1RM = recent.reduce((a, b) => a + b) / recent.length;
    final effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      suggestedWeight = avgE1RM * (37 - effectiveReps) / 36;
    } else {
      suggestedWeight = avgE1RM / (1 + 0.0333 * effectiveReps);
    }

    return (suggestedWeight / 2.5).round() * 2.5; // round to nearest 2.5kg
  }



  static void updateWeight(
      String exerciseName,
      TextEditingController weightController,
      TextEditingController repsController,
      TextEditingController rirController,
      int plannedIndex,
      )
  {

    if (!exercisePreviousE1RMs.containsKey(exerciseName) ||
        exercisePreviousE1RMs[exerciseName]!.isEmpty) {
      weightController.text = '20.0'; // ✅ Default weight if no history
      return;
    }

    // ✅ Get the average of the last 4 E1RMs (or fewer if not available)
    double avgE1RM = getAverageE1RM(exerciseName);

    // ✅ Get reps and RIR from UI (or use defaults)
    int reps = int.tryParse(repsController.text) ??
        getSuggestedRepTarget(
          exerciseName,
          plannedIndex: plannedIndex,
        );
    double rir = double.tryParse(rirController.text) ?? 0.5; // Default RIR if none entered
    double effectiveReps = reps + rir;

    double suggestedWeight;

    if (effectiveReps <= 6) {
      // ✅ Use Brzycki formula for lower rep ranges
      suggestedWeight = avgE1RM * (37 - effectiveReps) / 36;
    } else {
      // ✅ Use Epley formula for higher rep ranges
      suggestedWeight = avgE1RM / (1 + (0.0333 * effectiveReps));
    }

    // ✅ Prevent negative or unrealistic weight
    suggestedWeight = suggestedWeight.clamp(2.5, double.infinity);

    // ✅ Round to the nearest 2.5kg increment
    suggestedWeight = (suggestedWeight / 2.5).round() * 2.5;

    // ✅ Update the weight text field dynamically
    weightController.text = suggestedWeight.toString();
  }



  /// ✅ Helper Function to Parse Any Firestore Value to a Double
  static double _parseToDouble(dynamic value) {
    if (value is double) return value; // ✅ Already a double, return it
    if (value is int) return value.toDouble(); // ✅ Convert int to double
    if (value is String) return double.tryParse(value) ?? 0; // ✅ Convert String to double
    return 0; // ✅ Default case
  }
}


