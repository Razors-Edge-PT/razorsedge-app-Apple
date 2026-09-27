// The forced new-user cue replay moved from Richard's main account to the
// cue-QA test account. Each "relaunch" below is a fresh OnboardingCueService
// over the same durable store — exactly what a cold start does.

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/onboarding/onboarding_cue.dart';
import 'package:localtest222/onboarding/onboarding_cue_qa_policy.dart';
import 'package:localtest222/onboarding/onboarding_cue_repository.dart';
import 'package:localtest222/onboarding/onboarding_cue_service.dart';

const String kRichard = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';
const String kTestAccount = 'jhIB7Yi1whYwPvBSmK27KltJGn23';
const String kOrdinary = 'ordinary_user_1';

/// Durable store shared across "launches".
class CueStore implements OnboardingCueGateway {
  final Map<String, Map<String, CueRecord>> cues =
      <String, Map<String, CueRecord>>{};

  @override
  Future<CueLoadResult> load(String actorUid) async => CueLoadResult(
      cues: Map<String, CueRecord>.of(cues[actorUid] ?? const {}),
      fromServer: true);

  @override
  Future<void> writeCueComplete(
          {required String actorUid,
          required String cueId,
          required CueRecord record}) async =>
      (cues[actorUid] ??= <String, CueRecord>{})[cueId] = record;
}

/// One cold start of the app on [build].
Future<OnboardingCueService> launch(
    CueStore store, String uid, String build) async {
  final OnboardingCueService s =
      OnboardingCueService(gateway: store, buildProvider: () async => build);
  await s.ensureLoaded(uid);
  return s;
}

/// Everything a fresh account is offered on a launch.
Set<OnboardingCueId> shown(OnboardingCueService s, String uid) =>
    <OnboardingCueId>{
      for (final OnboardingCueId c in OnboardingCueId.values)
        if (s.shouldShowCue(c, uid)) c,
    };

Future<void> completeAll(OnboardingCueService s, String uid) async {
  for (final OnboardingCueId c in OnboardingCueId.values) {
    await s.markCueComplete(c, uid);
  }
}

/// Richard's production cue_state as read on 2026-09-27: every current cue
/// done, stamped with the build it was last completed on.
Map<String, CueRecord> richardProduction() => <String, CueRecord>{
      'wp_demo_video_v1': const CueRecord(done: true, build: '60'),
      'wp_planner_walkthrough_v1': const CueRecord(done: true, build: '105'),
      'wes2_field_walkthrough_v1': const CueRecord(done: true, build: '110'),
      'wes2_settings_cog_v1': const CueRecord(done: true, build: '110'),
    };

void main() {
  final Set<OnboardingCueId> replayable = <OnboardingCueId>{
    for (final OnboardingCueId c in OnboardingCueId.values)
      if (c.policy == OnboardingCuePolicy.qaReplayable) c,
  };

  test('the policy lists exactly the test account — never Richard', () {
    expect(OnboardingCueQaPolicy.replayAccounts, <String>{kTestAccount});
    expect(OnboardingCueQaPolicy.replaysCues(kRichard), isFalse);
    expect(OnboardingCueQaPolicy.replaysCues(kOrdinary), isFalse);
    expect(OnboardingCueQaPolicy.replaysCues(kTestAccount), isTrue);
    // The set Richard used to replay is the set the test account now replays.
    expect(replayable, <OnboardingCueId>{
      OnboardingCueId.wpPlannerWalkthrough,
      OnboardingCueId.wes2FieldWalkthrough,
      OnboardingCueId.wes2SettingsCog,
    });
  });

  group("Richard's main account is now ordinary", () {
    test(
        'already-seen cues do not repeat after relaunch, on this build or '
        'the next', () async {
      final CueStore store = CueStore()..cues[kRichard] = richardProduction();
      for (final String build in <String>['110', '111', '112']) {
        final OnboardingCueService s = await launch(store, kRichard, build);
        expect(shown(s, kRichard), isEmpty, reason: 'build $build');
      }
    });

    test('a cue dismissed once stays dismissed across relaunches and builds',
        () async {
      final CueStore store = CueStore();
      OnboardingCueService s = await launch(store, kRichard, '111');
      expect(shown(s, kRichard), OnboardingCueId.values.toSet(),
          reason: 'nothing recorded yet: an ordinary first run');
      await completeAll(s, kRichard);
      for (final String build in <String>['111', '112']) {
        s = await launch(store, kRichard, build);
        expect(shown(s, kRichard), isEmpty, reason: 'build $build');
      }
    });

    test('a genuinely new cue (no record yet) still appears — once', () async {
      // Models a future cue id: every other cue is done; this one has never
      // been recorded, as a newly shipped `_v2` id would not be.
      final CueStore store = CueStore()
        ..cues[kRichard] =
            (richardProduction()..remove('wes2_settings_cog_v1'));
      OnboardingCueService s = await launch(store, kRichard, '112');
      expect(shown(s, kRichard),
          <OnboardingCueId>{OnboardingCueId.wes2SettingsCog});
      await s.markCueComplete(OnboardingCueId.wes2SettingsCog, kRichard);
      s = await launch(store, kRichard, '112');
      expect(shown(s, kRichard), isEmpty);
      s = await launch(store, kRichard, '113');
      expect(shown(s, kRichard), isEmpty, reason: 'not revived by a new build');
    });
  });

  group('the test account replays the full forced set', () {
    test('on every new build, across relaunches, after completing each time',
        () async {
      final CueStore store = CueStore();
      OnboardingCueService s = await launch(store, kTestAccount, '111');
      expect(shown(s, kTestAccount), OnboardingCueId.values.toSet());
      await completeAll(s, kTestAccount);
      // Same build, relaunched: the forced QA behaviour is once per build.
      s = await launch(store, kTestAccount, '111');
      expect(shown(s, kTestAccount), isEmpty);
      for (final String build in <String>['112', '113']) {
        s = await launch(store, kTestAccount, build);
        expect(shown(s, kTestAccount), replayable, reason: 'build $build');
        await completeAll(s, kTestAccount);
      }
    });

    test("with its production state (all done on build 61) it replays now",
        () async {
      final CueStore store = CueStore()
        ..cues[kTestAccount] = <String, CueRecord>{
          for (final OnboardingCueId c in OnboardingCueId.values)
            c.id: const CueRecord(done: true, build: '61'),
        };
      final OnboardingCueService s = await launch(store, kTestAccount, '111');
      expect(shown(s, kTestAccount), replayable);
    });

    test('exactly what Richard received before the transfer', () async {
      // Richard's former state machine, reproduced: replayable cues on a new
      // build, the permanent video never again once done.
      final CueStore store = CueStore()
        ..cues[kTestAccount] = <String, CueRecord>{
          for (final MapEntry<String, CueRecord> e
              in richardProduction().entries)
            e.key: e.value,
        };
      final OnboardingCueService s = await launch(store, kTestAccount, '111');
      expect(shown(s, kTestAccount), replayable);
      expect(
          s.shouldShowCue(OnboardingCueId.wpDemoVideo, kTestAccount), isFalse);
    });
  });

  test('an ordinary account keeps once-only behaviour', () async {
    final CueStore store = CueStore();
    OnboardingCueService s = await launch(store, kOrdinary, '111');
    expect(shown(s, kOrdinary), OnboardingCueId.values.toSet());
    await completeAll(s, kOrdinary);
    for (final String build in <String>['111', '112']) {
      s = await launch(store, kOrdinary, build);
      expect(shown(s, kOrdinary), isEmpty, reason: 'build $build');
    }
  });
}
