/// Stable identity + policy registry for durable onboarding cues.
///
/// Each cue has a STABLE string id (e.g. `wp_demo_video_v1`). The `_vN` suffix
/// is the per-cue version handle: a substantially changed cue ships as a new id
/// (e.g. `_v2`) so it appears for everyone without reviving the old id.
///
/// No UI lives here. Screens never branch on the Richard UID or the build
/// number directly — they call OnboardingCueService, which consults this map.
library;

enum OnboardingCueId {
  /// Workout Planner demo video.
  wpDemoVideo,

  /// Workout Planner interactive walkthrough.
  wpPlannerWalkthrough,

  /// WES2 linked field walkthrough (Load Template → first template → weight →
  /// reps → RIR). One durable group matching the existing linked completion.
  wes2FieldWalkthrough,

  /// WES2 settings-cog cue (unlocked after the 3-day qualification gate).
  wes2SettingsCog,
}

enum OnboardingCuePolicy {
  /// Once-only for everyone, forever. Never replays on a new build.
  permanent,

  /// Once-only for normal users; for the Richard test account it becomes
  /// eligible again once per installed build.
  richardReplayable,
}

class OnboardingCueSpec {
  final String id;
  final OnboardingCuePolicy policy;
  const OnboardingCueSpec(this.id, this.policy);
}

/// The single source of truth mapping each cue to its stable id + policy.
const Map<OnboardingCueId, OnboardingCueSpec> kOnboardingCues = {
  // Permanent for everyone — including Richard (special video exception).
  OnboardingCueId.wpDemoVideo:
      OnboardingCueSpec('wp_demo_video_v1', OnboardingCuePolicy.permanent),

  OnboardingCueId.wpPlannerWalkthrough: OnboardingCueSpec(
      'wp_planner_walkthrough_v1', OnboardingCuePolicy.richardReplayable),

  OnboardingCueId.wes2FieldWalkthrough: OnboardingCueSpec(
      'wes2_field_walkthrough_v1', OnboardingCuePolicy.richardReplayable),

  OnboardingCueId.wes2SettingsCog: OnboardingCueSpec(
      'wes2_settings_cog_v1', OnboardingCuePolicy.richardReplayable),
};

extension OnboardingCueIdX on OnboardingCueId {
  String get id => kOnboardingCues[this]!.id;
  OnboardingCuePolicy get policy => kOnboardingCues[this]!.policy;
}

/// Durable completion record for one cue.
///
/// [done] — permanently complete (authoritative for normal users + permanent
/// cues). [build] — the installed build number captured at completion time,
/// used only for Richard's per-build replay comparison. Treated as an opaque
/// string; never parsed numerically.
class CueRecord {
  final bool done;
  final String? build;

  const CueRecord({required this.done, this.build});

  factory CueRecord.fromMap(Map<dynamic, dynamic> data) => CueRecord(
        done: data['done'] == true,
        build: data['build'] as String?,
      );

  /// Compact JSON for the local SharedPreferences mirror.
  Map<String, dynamic> toCacheJson() => {
        'done': done,
        if (build != null) 'build': build,
      };

  factory CueRecord.fromCacheJson(Map<String, dynamic> data) =>
      CueRecord.fromMap(data);
}
