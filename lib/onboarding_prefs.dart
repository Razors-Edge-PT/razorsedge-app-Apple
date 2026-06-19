import 'package:shared_preferences/shared_preferences.dart';

/// Local-only onboarding helpers keyed on the Firebase Auth actor UID.
///
/// IMPORTANT: durable cue COMPLETION now lives in Firestore via
/// `OnboardingCueService` (`lib/onboarding/`). The old SharedPreferences
/// completion flags (wpDemoComplete, wpPlannerWalkthroughComplete,
/// wes2TutorialComplete, wesCogCueDone) have been intentionally removed and are
/// NOT migrated — the first release with the new guard establishes a fresh
/// baseline.
///
/// What remains here is only the settings-cog qualifying-day LOCAL CACHE. The
/// durable authority for the 3-day unlock is the membership doc
/// (`users/{actorUid}/profile/membership.qualifiedWorkoutDates` /
/// `qualifiedWorkoutDaysCount`), so the gate survives reinstall / device change.
class OnboardingPrefs {
  static String _kWesCogCueQualifiedDays(String uid) =>
      'ob.$uid.wesCogCueQualifiedDays';

  /// Returns the cached set of calendar date keys (yyyy-MM-dd) on which this
  /// actor has logged a qualifying workout. Cache only — not authoritative.
  static Future<Set<String>> getWesCogCueQualifiedDays(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kWesCogCueQualifiedDays(uid)) ?? []).toSet();
  }

  /// Adds [dateKey] to the local qualifying-day cache. Idempotent.
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
