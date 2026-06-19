import 'package:flutter_test/flutter_test.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:localtest222/onboarding/onboarding_cue.dart';
import 'package:localtest222/onboarding/onboarding_cue_repository.dart';
import 'package:localtest222/onboarding/onboarding_cue_service.dart';

/// In-memory gateway for service decision tests. Faithfully models the
/// repository contract: dotted writes touch only their own cue (sibling-safe),
/// and load reports whether the result is authoritative (fromServer).
class _FakeGateway implements OnboardingCueGateway {
  final Map<String, Map<String, CueRecord>> store = {};
  bool failLoad = false;
  bool failWrite = false;
  int writeCount = 0;

  @override
  Future<CueLoadResult> load(String actorUid) async {
    if (failLoad) {
      // No cache available in this fake → empty, non-authoritative.
      return const CueLoadResult(cues: {}, fromServer: false);
    }
    return CueLoadResult(
      cues: Map<String, CueRecord>.of(store[actorUid] ?? const {}),
      fromServer: true,
    );
  }

  @override
  Future<void> writeCueComplete({
    required String actorUid,
    required String cueId,
    required CueRecord record,
  }) async {
    writeCount++;
    if (failWrite) throw StateError('write failed');
    (store[actorUid] ??= {})[cueId] = record; // only this cue
  }
}

const richard = OnboardingCueService.richardUid;
const normal = 'normal_user_123';

OnboardingCueService _svc(_FakeGateway g, String build) => OnboardingCueService(
      gateway: g,
      buildProvider: () async => build,
    );

void main() {
  group('Normal user', () {
    test('1. no record → cue shows', () async {
      final g = _FakeGateway();
      final s = _svc(g, '40');
      await s.ensureLoaded(normal);
      expect(s.shouldShowCue(OnboardingCueId.wpPlannerWalkthrough, normal), true);
    });

    test('2. completes → no longer shows', () async {
      final g = _FakeGateway();
      final s = _svc(g, '40');
      await s.ensureLoaded(normal);
      await s.markCueComplete(OnboardingCueId.wpPlannerWalkthrough, normal);
      expect(
          s.shouldShowCue(OnboardingCueId.wpPlannerWalkthrough, normal), false);
    });

    test('3. different build does NOT make a normal-user cue reappear', () async {
      final g = _FakeGateway();
      final s40 = _svc(g, '40');
      await s40.ensureLoaded(normal);
      await s40.markCueComplete(OnboardingCueId.wpPlannerWalkthrough, normal);

      final s41 = _svc(g, '41'); // new build, same durable store
      await s41.ensureLoaded(normal);
      expect(
          s41.shouldShowCue(OnboardingCueId.wpPlannerWalkthrough, normal), false);
    });

    test('4. a new cue id appears independently of completed ones', () async {
      final g = _FakeGateway();
      final s = _svc(g, '40');
      await s.ensureLoaded(normal);
      await s.markCueComplete(OnboardingCueId.wpDemoVideo, normal);
      // A different (still-incomplete) cue remains eligible.
      expect(s.shouldShowCue(OnboardingCueId.wes2SettingsCog, normal), true);
      expect(s.shouldShowCue(OnboardingCueId.wpDemoVideo, normal), false);
    });
  });

  group('Richard test account', () {
    test('5. sees replayable cue in build 40', () async {
      final g = _FakeGateway();
      final s = _svc(g, '40');
      await s.ensureLoaded(richard);
      expect(
          s.shouldShowCue(OnboardingCueId.wes2FieldWalkthrough, richard), true);
    });

    test('6. not again after completing in build 40', () async {
      final g = _FakeGateway();
      final s = _svc(g, '40');
      await s.ensureLoaded(richard);
      await s.markCueComplete(OnboardingCueId.wes2FieldWalkthrough, richard);
      expect(
          s.shouldShowCue(OnboardingCueId.wes2FieldWalkthrough, richard), false);
    });

    test('7. sees it again in build 41', () async {
      final g = _FakeGateway();
      final s40 = _svc(g, '40');
      await s40.ensureLoaded(richard);
      await s40.markCueComplete(OnboardingCueId.wes2FieldWalkthrough, richard);

      final s41 = _svc(g, '41');
      await s41.ensureLoaded(richard);
      expect(
          s41.shouldShowCue(OnboardingCueId.wes2FieldWalkthrough, richard), true);
    });

    test('8. completed demo video does NOT reappear in build 41', () async {
      final g = _FakeGateway();
      final s40 = _svc(g, '40');
      await s40.ensureLoaded(richard);
      await s40.markCueComplete(OnboardingCueId.wpDemoVideo, richard);

      final s41 = _svc(g, '41');
      await s41.ensureLoaded(richard);
      expect(s41.shouldShowCue(OnboardingCueId.wpDemoVideo, richard), false);
    });

    test('9. missing build number fails closed for replayable cues', () async {
      final g = _FakeGateway();
      final s = _svc(g, ''); // unavailable build
      await s.ensureLoaded(richard);
      expect(
          s.shouldShowCue(OnboardingCueId.wes2FieldWalkthrough, richard), false);
      // Permanent decisions still work from durable state.
      expect(s.shouldShowCue(OnboardingCueId.wpDemoVideo, richard), true);
    });
  });

  group('Fail-closed & resilience', () {
    test('10. not-yet-loaded fails closed', () {
      final g = _FakeGateway();
      final s = _svc(g, '40'); // ensureLoaded NOT called
      expect(s.shouldShowCue(OnboardingCueId.wpPlannerWalkthrough, normal), false);
    });

    test('14. read failure does not auto-replay a completed cue', () async {
      final g = _FakeGateway();
      // Pre-existing durable completion.
      g.store[normal] = {
        OnboardingCueId.wpPlannerWalkthrough.id:
            const CueRecord(done: true, build: '40'),
      };
      g.failLoad = true; // server unavailable, fake has no cache
      final s = _svc(g, '40');
      await s.ensureLoaded(normal);
      // Not established (no server, no cache) → fail closed → does NOT show.
      expect(
          s.shouldShowCue(OnboardingCueId.wpPlannerWalkthrough, normal), false);
    });

    test('12. repeating completion is idempotent', () async {
      final g = _FakeGateway();
      final s = _svc(g, '40');
      await s.ensureLoaded(normal);
      await s.markCueComplete(OnboardingCueId.wpDemoVideo, normal);
      await s.markCueComplete(OnboardingCueId.wpDemoVideo, normal);
      expect(s.shouldShowCue(OnboardingCueId.wpDemoVideo, normal), false);
      expect(g.store[normal]!.length, 1);
    });

    test('write failure is queued then flushed on next ensureLoaded', () async {
      final g = _FakeGateway();
      final s = _svc(g, '40');
      await s.ensureLoaded(normal);
      g.failWrite = true;
      await s.markCueComplete(OnboardingCueId.wpDemoVideo, normal);
      // In-memory suppressed despite write failure.
      expect(s.shouldShowCue(OnboardingCueId.wpDemoVideo, normal), false);
      expect(g.store[normal]?.containsKey(OnboardingCueId.wpDemoVideo.id) ?? false,
          false);
      // Recover: next ensureLoaded flushes the queued write.
      g.failWrite = false;
      await s.ensureLoaded(normal);
      expect(g.store[normal]![OnboardingCueId.wpDemoVideo.id]!.done, true);
    });
  });

  group('Repository — Firestore sibling safety (FakeFirebaseFirestore)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('11+13. completing cue B leaves cue A intact, under actor UID', () async {
      final fs = FakeFirebaseFirestore();
      final repo = FirestoreOnboardingCueRepository(firestore: fs);

      await repo.writeCueComplete(
        actorUid: normal,
        cueId: OnboardingCueId.wpDemoVideo.id,
        record: const CueRecord(done: true, build: '40'),
      );
      await repo.writeCueComplete(
        actorUid: normal,
        cueId: OnboardingCueId.wes2SettingsCog.id,
        record: const CueRecord(done: true, build: '41'),
      );

      // Path uses the actor UID.
      final doc = await fs
          .collection('users')
          .doc(normal)
          .collection('onboarding')
          .doc('cue_state')
          .get();
      final cues = (doc.data()!['cues'] as Map);

      // Cue A intact.
      expect(cues[OnboardingCueId.wpDemoVideo.id]['done'], true);
      expect(cues[OnboardingCueId.wpDemoVideo.id]['build'], '40');
      // Cue B written.
      expect(cues[OnboardingCueId.wes2SettingsCog.id]['done'], true);
      expect(cues[OnboardingCueId.wes2SettingsCog.id]['build'], '41');
    });

    test('idempotent re-write does not duplicate or wipe siblings', () async {
      final fs = FakeFirebaseFirestore();
      final repo = FirestoreOnboardingCueRepository(firestore: fs);
      await repo.writeCueComplete(
        actorUid: normal,
        cueId: OnboardingCueId.wpDemoVideo.id,
        record: const CueRecord(done: true, build: '40'),
      );
      await repo.writeCueComplete(
        actorUid: normal,
        cueId: OnboardingCueId.wpDemoVideo.id,
        record: const CueRecord(done: true, build: '40'),
      );
      final result = await repo.load(normal);
      expect(result.fromServer, true);
      expect(result.cues.length, 1);
      expect(result.cues[OnboardingCueId.wpDemoVideo.id]!.done, true);
    });
  });
}
