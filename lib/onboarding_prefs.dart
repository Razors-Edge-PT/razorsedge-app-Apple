import 'package:shared_preferences/shared_preferences.dart';

/// Per-logged-in-user onboarding completion flags.
/// All keys are keyed on the Firebase Auth actor UID (never the impersonated athlete UID).
class OnboardingPrefs {
  static String _kWpDone(String uid)  => 'ob.$uid.wpDemoComplete';
  static String _kWesDone(String uid) => 'ob.$uid.wes2TutorialComplete';

  static Future<bool> getWpDone(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kWpDone(uid)) ?? false;
  }

  static Future<bool> getWesDone(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kWesDone(uid)) ?? false;
  }

  /// Marks the Workout Planner demo as complete. Idempotent — safe to call multiple times.
  static Future<void> setWpDone(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWpDone(uid), true);
  }

  /// Marks the WES2 field tutorial as complete. Idempotent — safe to call multiple times.
  static Future<void> setWesDone(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWesDone(uid), true);
  }

  static String _kWpWalkthroughDone(String uid) =>
      'ob.$uid.wpPlannerWalkthroughComplete';

  static Future<bool> getWpPlannerWalkthroughComplete(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kWpWalkthroughDone(uid)) ?? false;
  }

  /// Marks the Workout Planner in-screen walkthrough as complete. Idempotent.
  static Future<void> setWpPlannerWalkthroughComplete(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWpWalkthroughDone(uid), true);
  }

  static String _kWesCogCueDone(String uid) => 'ob.$uid.wesCogCueDone';

  static Future<bool> getWesCogCueDone(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kWesCogCueDone(uid)) ?? false;
  }

  /// Marks the WES2 settings cog tutorial cue as seen. Idempotent.
  static Future<void> setWesCogCueDone(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWesCogCueDone(uid), true);
  }

  static String _kWesCogCueQualifiedDays(String uid) =>
      'ob.$uid.wesCogCueQualifiedDays';

  /// Returns the set of calendar date keys (yyyy-MM-dd) on which this actor
  /// has logged a qualifying workout (≥ 2 sets with weight AND reps).
  static Future<Set<String>> getWesCogCueQualifiedDays(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kWesCogCueQualifiedDays(uid)) ?? []).toSet();
  }

  /// Adds [dateKey] to the qualifying-day set. Idempotent — the same date
  /// is never counted twice even if called repeatedly.
  static Future<void> addWesCogCueQualifiedDay(
      String uid, String dateKey) async {
    final prefs = await SharedPreferences.getInstance();
    final current =
        (prefs.getStringList(_kWesCogCueQualifiedDays(uid)) ?? []).toSet();
    if (current.add(dateKey)) {
      await prefs.setStringList(
          _kWesCogCueQualifiedDays(uid), current.toList());
    }
  }
}
