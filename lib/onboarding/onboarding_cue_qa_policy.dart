/// The one place that decides which accounts replay onboarding cues for QA.
///
/// A cue with [OnboardingCuePolicy.qaReplayable] is once-only for everyone,
/// except the accounts listed here: for them it becomes eligible again once
/// per installed build, so a new build can be walked through from scratch.
///
/// This is a cue-testing override ONLY. It grants no other privilege — not
/// profile access, not messaging, not admin. Screens never test these UIDs;
/// they ask OnboardingCueService.
library;

import 'onboarding_cue.dart';

class OnboardingCueQaPolicy {
  const OnboardingCueQaPolicy._();

  /// The dedicated cue-testing account (Richard's test login).
  static const String testAccountUid = 'jhIB7Yi1whYwPvBSmK27KltJGn23';

  /// Every account that replays [OnboardingCuePolicy.qaReplayable] cues.
  static const Set<String> replayAccounts = <String>{testAccountUid};

  static bool replaysCues(String actorUid) => replayAccounts.contains(actorUid);
}
