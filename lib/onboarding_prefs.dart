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
}
