import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/wes2_video/set_video_publication.dart';
import 'package:localtest222/wes2_video/set_video_reconciler.dart';
import 'package:localtest222/wes2_video/set_video_store.dart';
import 'package:path/path.dart' as p;

/// The reconciliation pass.
///
/// It runs on save, at startup, on resume, on reconnect and after an
/// interrupted upload, so idempotence is the property that matters most:
/// running it repeatedly must produce exactly one upload, or none.

const String _uid = 'owner-1';
const String _coach = 'coach-9';
const String _dateKey = '2026-08-31';

final BigFiveLift _bench = bigFiveBySlot(BigFiveSlot.bench)!;

const SetVideoActor _self =
    SetVideoActor(authenticatedUid: _uid, actingUid: _uid);

class _Performances implements SetPerformanceSource {
  _Performances(this.value);

  SetPerformance? value;
  int calls = 0;

  @override
  Future<SetPerformance?> performanceFor({
    required String ownerUid,
    required String dateKey,
    required String exerciseId,
    required String setId,
  }) async {
    calls++;
    return value;
  }
}

class _Projections implements ShowcaseProjectionSource {
  _Projections(this.value);

  ProfileShowcase? value;

  @override
  Future<ProfileShowcase?> current(String ownerUid) async => value;
}

class _Uploads implements ProofUploadQueue {
  final List<String> fingerprints = <String>[];
  final List<String> slots = <String>[];
  int calls = 0;

  @override
  Future<String> queueProof({
    required String ownerUid,
    required File file,
    required String fingerprint,
    required String slot,
  }) async {
    calls++;
    fingerprints.add(fingerprint);
    slots.add(slot);
    return 'media-$calls';
  }
}

void main() {
  late Directory root;
  late SetVideoDatabase db;
  late SetVideoStore store;
  late _Performances performances;
  late _Projections projections;
  late _Uploads uploads;
  late SetVideoReconciler reconciler;

  String fp({double weight = 180, int reps = 2, String setKey = 'sid-1'}) =>
      recordFingerprint(
        slot: BigFiveSlot.bench,
        exerciseId: _bench.exerciseId,
        dateKey: _dateKey,
        setKey: setKey,
        weight: weight,
        reps: reps,
      );

  ProfileShowcase showcaseWith(String fingerprint, {String? heaviest}) =>
      ProfileShowcase(
        lifts: <String, ShowcaseLiftSnapshot>{
          BigFiveSlot.bench: ShowcaseLiftSnapshot(
            slot: BigFiveSlot.bench,
            bestE1rm: ShowcaseRecord(
              slot: BigFiveSlot.bench,
              exerciseId: _bench.exerciseId,
              dateKey: _dateKey,
              setKey: 'sid-1',
              weight: 180,
              reps: 2,
              e1rm: 190,
              formulaVersion: 1,
              fingerprint: fingerprint,
            ),
            heaviest: heaviest == null
                ? null
                : ShowcaseRecord(
                    slot: BigFiveSlot.bench,
                    exerciseId: _bench.exerciseId,
                    dateKey: _dateKey,
                    setKey: 'sid-1',
                    weight: 180,
                    reps: 2,
                    e1rm: 190,
                    formulaVersion: 1,
                    fingerprint: heaviest,
                  ),
          ),
        },
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('gl_reconcile');
    db = SetVideoDatabase.memory();
    store = SetVideoStore(db);
    performances = _Performances(const SetPerformance(
      exerciseName: 'Bench Press, Barbell',
      weight: 180,
      reps: 2,
    ));
    projections = _Projections(showcaseWith(fp()));
    uploads = _Uploads();
    reconciler = SetVideoReconciler(
      store: store,
      performances: performances,
      projections: projections,
      uploads: uploads,
    );
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<SetVideoRecord> seed({
    String ownerUid = _uid,
    String setId = 'sid-1',
    String? exerciseId,
    bool onDisk = true,
  }) async {
    final File f = File(p.join(root.path, 'clip_$setId.mp4'));
    if (onDisk) f.writeAsStringSync('bytes');
    return store.put(
      ownerUid: ownerUid,
      dateKey: _dateKey,
      exerciseId: exerciseId ?? _bench.exerciseId,
      setId: setId,
      localVideoPath: f.path,
      localPosterPath: null,
      durationMs: 5000,
      sizeBytes: 5,
    );
  }

  group('a confirmed PB queues exactly one upload', () {
    test('the exact fingerprint is queued once', () async {
      await seed();
      final ReconcileReport r = await reconciler.reconcile(_self);

      expect(r.queued, 1);
      expect(uploads.calls, 1);
      expect(uploads.fingerprints.single, fp());
      expect(uploads.slots.single, BigFiveSlot.bench);
    });

    test('the record is marked queued with its media id', () async {
      final SetVideoRecord seeded = await seed();
      await reconciler.reconcile(_self);

      final SetVideoRecord? row = await store.byId(seeded.id);
      expect(row!.state, SetVideoState.queued);
      expect(row.mediaId, 'media-1');
      expect(row.fingerprint, fp());
      expect(row.liftSlot, BigFiveSlot.bench);
    });

    test('one set owning both categories still uploads once', () async {
      projections.value = showcaseWith(fp(), heaviest: fp());
      await seed();

      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(r.queued, 1);
      expect(uploads.calls, 1,
          reason:
              'both proofs share one fingerprint, so one asset serves both');
    });
  });

  group('idempotence', () {
    test('running repeatedly produces exactly one upload', () async {
      await seed();
      await reconciler.reconcile(_self);
      await reconciler.reconcile(_self);
      await reconciler.reconcile(_self);
      expect(uploads.calls, 1);
    });

    test('a second pass reports the record as already handled', () async {
      await seed();
      await reconciler.reconcile(_self);
      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(r.queued, 0);
      expect(r.considered, 0,
          reason: 'a queued record is no longer a candidate');
    });
  });

  group('nothing is uploaded when it should not be', () {
    test('a non-canonical exercise is skipped', () async {
      await seed(exerciseId: 'not-a-big-five');
      performances.value =
          const SetPerformance(exerciseName: 'Leg Press', weight: 180, reps: 2);

      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(r.queued, 0);
      expect(uploads.calls, 0);
      expect(r.skipped[SetVideoPublishDecision.notCanonical], 1);
    });

    test('a canonical lift that is not a PB is skipped', () async {
      projections.value = ProfileShowcase.empty;
      await seed();

      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(uploads.calls, 0);
      expect(r.skipped[SetVideoPublishDecision.notPersonalBest], 1);
    });

    test('a superseded candidate is skipped', () async {
      await seed();
      projections.value = showcaseWith(fp(weight: 200));

      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(uploads.calls, 0);
      expect(r.skipped[SetVideoPublishDecision.notPersonalBest], 1);
    });

    test('a suppressed record is never resurrected', () async {
      final SetVideoRecord s = await seed();
      await store.softDelete(s.id);

      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(uploads.calls, 0);
      expect(r.considered, 0);
    });

    test('a clip missing from disk is not queued', () async {
      await seed(onDisk: false);
      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(uploads.calls, 0);
      expect(r.queued, 0);
    });

    test('an unreadable projection queues nothing and changes nothing',
        () async {
      projections.value = null;
      final SetVideoRecord s = await seed();

      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(uploads.calls, 0);
      expect(r.queued, 0);
      expect((await store.byId(s.id))!.state, SetVideoState.local,
          reason: 'an unreadable projection must not look like "no records"');
    });

    test('a missing performance is incomplete, never an assumed PB', () async {
      performances.value = null;
      await seed();

      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(uploads.calls, 0);
      // The exercise still matches a canonical lift by id; what is missing is
      // the performance, so there is nothing to fingerprint.
      expect(r.skipped[SetVideoPublishDecision.incomplete], 1);
    });
  });

  group('coach mode and cross-account', () {
    test('a coach acting as an athlete uploads nothing and reads nothing',
        () async {
      await seed();
      final ReconcileReport r = await reconciler.reconcile(
          const SetVideoActor(authenticatedUid: _coach, actingUid: _uid));

      expect(uploads.calls, 0);
      expect(r.skipped[SetVideoPublishDecision.actorMismatch], 1);
      expect(performances.calls, 0,
          reason: "an athlete's footage is not even inspected by a coach");
    });

    test("another account's footage is not a candidate", () async {
      await seed(ownerUid: 'someone-else');
      final ReconcileReport r = await reconciler.reconcile(_self);
      expect(r.considered, 0);
      expect(uploads.calls, 0);
    });
  });

  group('offline capture then reconnect', () {
    test('a clip recorded while the projection was unreadable promotes later',
        () async {
      projections.value = null;
      await seed();
      expect((await reconciler.reconcile(_self)).queued, 0);

      // Reconnected: the projection now confirms the record.
      projections.value = showcaseWith(fp());
      expect((await reconciler.reconcile(_self)).queued, 1);
      expect(uploads.calls, 1);
    });
  });

  group('commit-time revalidation', () {
    test('a still-live fingerprint publishes', () async {
      final SetVideoRecord s = await seed();
      await reconciler.reconcile(_self);

      final bool ok = await reconciler.confirmPublished(
          recordId: s.id, postId: 'post-1', actor: _self);

      expect(ok, isTrue);
      final SetVideoRecord? row = await store.byId(s.id);
      expect(row!.state, SetVideoState.published);
      expect(row.postId, 'post-1');
    });

    test('a fingerprint beaten in flight keeps the clip but does not publish',
        () async {
      final SetVideoRecord s = await seed();
      await reconciler.reconcile(_self);

      projections.value = showcaseWith(fp(weight: 200));
      final bool ok = await reconciler.confirmPublished(
          recordId: s.id, postId: 'post-1', actor: _self);

      expect(ok, isFalse);
      final SetVideoRecord? row = await store.byId(s.id);
      expect(row!.state, SetVideoState.local,
          reason:
              'the user keeps their footage; the project keeps its storage');
      expect(row.postId, isNull);
      expect(File(row.localVideoPath).existsSync(), isTrue);
    });

    test('a coach cannot confirm publication for an athlete', () async {
      final SetVideoRecord s = await seed();
      await reconciler.reconcile(_self);

      final bool ok = await reconciler.confirmPublished(
        recordId: s.id,
        postId: 'post-1',
        actor: const SetVideoActor(authenticatedUid: _coach, actingUid: _uid),
      );
      expect(ok, isFalse);
      expect((await store.byId(s.id))!.postId, isNull);
    });

    test('an unknown record is refused rather than throwing', () async {
      expect(
        await reconciler.confirmPublished(
            recordId: 'nope', postId: 'p', actor: _self),
        isFalse,
      );
    });
  });

  group('replacement during a pass', () {
    test('a clip replaced before queueing is not queued under the old id',
        () async {
      final SetVideoRecord first = await seed();

      // The user replaces the clip; generation moves on.
      final File newer = File(p.join(root.path, 'newer.mp4'))
        ..writeAsStringSync('newer');
      await store.put(
        ownerUid: _uid,
        dateKey: _dateKey,
        exerciseId: _bench.exerciseId,
        setId: 'sid-1',
        localVideoPath: newer.path,
      );

      await reconciler.reconcile(_self);

      final SetVideoRecord? row = await store.byId(first.id);
      expect(row!.localVideoPath, newer.path,
          reason: 'the newer clip is the one that stands');
      expect(uploads.calls, 1);
    });
  });
}
