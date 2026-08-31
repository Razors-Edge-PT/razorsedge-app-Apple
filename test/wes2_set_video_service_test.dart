import 'dart:io';

import 'package:flutter/services.dart';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/profile/core/big_five.dart';
import 'package:localtest222/profile/core/showcase_models.dart';
import 'package:localtest222/profile/data/media_outbox.dart';
import 'package:localtest222/profile/data/media_staging.dart';
import 'package:localtest222/wes2_video/set_video_files.dart';
import 'package:localtest222/wes2_video/set_video_pipeline.dart';
import 'package:localtest222/wes2_video/set_video_publication.dart';
import 'package:localtest222/wes2_video/set_video_reconciler.dart';
import 'package:localtest222/wes2_video/set_video_service.dart';
import 'package:localtest222/wes2_video/set_video_store.dart';
import 'package:path/path.dart' as p;

/// The PRODUCTION set-video service and its three real adapters.
///
/// Every test here fails against e52184f, where SetVideoService did not exist,
/// the reconciler was constructed only inside tests, its three interfaces had
/// only test fakes, and confirmPublished() had no caller anywhere. Footage was
/// captured and stored and then no pass ever ran.
///
/// These drive the REAL adapters — the real Wes2Repository read, the real
/// users_public projection read, the real MediaStaging queue — rather than
/// substituting interfaces for them.

const String _uid = 'owner-1';
const String _coach = 'coach-9';
const String _dateKey = '2026-08-31';
final BigFiveLift _bench = bigFiveBySlot(BigFiveSlot.bench)!;

const SetVideoActor _self =
    SetVideoActor(authenticatedUid: _uid, actingUid: _uid);

String _fp({double weight = 180, int reps = 2, String setKey = 'sid-1'}) =>
    recordFingerprint(
      slot: BigFiveSlot.bench,
      exerciseId: _bench.exerciseId,
      dateKey: _dateKey,
      setKey: setKey,
      weight: weight,
      reps: reps,
    );

Map<String, Object?> _showcaseMap(String fingerprint) => <String, Object?>{
      'schema': 'profileShowcaseV1',
      'formulaVersion': 1,
      'lifts': <String, Object?>{
        BigFiveSlot.bench: <String, Object?>{
          'e1rm': <String, Object?>{
            'slot': BigFiveSlot.bench,
            'exerciseId': _bench.exerciseId,
            'dateKey': _dateKey,
            'setKey': 'sid-1',
            'weight': 180,
            'reps': 2,
            'e1rm': 190,
            'formulaVersion': 1,
            'fingerprint': fingerprint,
          },
        },
      },
    };

/// A trim engine that never runs; the pipeline is only used here for its
/// sweep/finalise behaviour.
class _NoTrim implements SetVideoTrimEngine {
  @override
  Future<File?> trim({
    required File source,
    required TrimSelection selection,
    bool includeAudio = true,
  }) async =>
      null;

  @override
  Future<void> clearCache() async {}
}

/// A repository that answers only [savedPerformanceForSet], from a map keyed
/// by stable set id — so an index-based lookup could not possibly satisfy it.
class _FakeRepo implements Wes2Repository {
  _FakeRepo(this.bySetId);

  final Map<String, Wes2SavedSetPerformance> bySetId;
  int calls = 0;
  String? lastSetId;

  @override
  Future<Wes2SavedSetPerformance?> savedPerformanceForSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String setId,
  }) async {
    calls++;
    lastSetId = setId;
    return bySetId[setId];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used here');
}

class _ThrowingRepo implements Wes2Repository {
  @override
  Future<Wes2SavedSetPerformance?> savedPerformanceForSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String setId,
  }) async =>
      throw StateError('offline');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late SetVideoDatabase svDb;
  late SetVideoStore store;
  late AppSupportSetVideoFiles files;
  late MediaOutboxDatabase outboxDb;
  late MediaOutbox outbox;
  late FakeFirebaseFirestore firestore;

  setUp(() {
    root = Directory.systemTemp.createTempSync('gl_service');

    // MediaStaging reaches for application support through path_provider. The
    // real staging code is exercised; only the platform directory is supplied.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => root.path,
    );
    svDb = SetVideoDatabase.memory();
    store = SetVideoStore(svDb);
    files = AppSupportSetVideoFiles(supportDirectory: () async => root);
    outboxDb = MediaOutboxDatabase.memory();
    outbox = MediaOutbox(outboxDb);
    firestore = FakeFirebaseFirestore();
  });

  tearDown(() async {
    await svDb.close();
    await outboxDb.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  SetVideoService buildService({
    Wes2Repository? repository,
    Map<String, Wes2SavedSetPerformance>? performances,
  }) {
    final SetVideoPipeline pipeline = SetVideoPipeline(
      store: store,
      files: files,
      trimmer: _NoTrim(),
    );
    return SetVideoService(
      store: store,
      files: files,
      pipeline: pipeline,
      reconciler: SetVideoReconciler(
        store: store,
        performances: Wes2SetPerformanceSource(
          repository ??
              _FakeRepo(performances ??
                  <String, Wes2SavedSetPerformance>{
                    'sid-1': Wes2SavedSetPerformance(
                      exerciseId: _bench.exerciseId,
                      exerciseName: _bench.displayName,
                      setId: 'sid-1',
                      weight: 180,
                      reps: 2,
                    ),
                  }),
        ),
        projections: FirestoreShowcaseProjectionSource(firestore: firestore),
        uploads: OutboxProofUploadQueue(MediaStaging(outbox: outbox)),
      ),
      outbox: outbox,
      firestore: firestore,
    );
  }

  Future<SetVideoRecord> seedClip({
    String setId = 'sid-1',
    String ownerUid = _uid,
    bool onDisk = true,
  }) async {
    final Directory dir = await files.videoDir(ownerUid);
    final File f = File(p.join(dir.path, 'clip_$setId.mp4'));
    if (onDisk) f.writeAsStringSync('trimmed-bytes');
    return store.put(
      ownerUid: ownerUid,
      dateKey: _dateKey,
      exerciseId: _bench.exerciseId,
      setId: setId,
      localVideoPath: f.path,
      durationMs: 6000,
      sizeBytes: 14,
    );
  }

  /// Writes the proof pointer the uploader writes on a successful publish.
  Future<void> writeProofPointer({
    required String fingerprint,
    required String mediaId,
    String ownerUid = _uid,
  }) =>
      firestore
          .collection('users')
          .doc(ownerUid)
          .collection('proofs')
          .doc(fingerprint)
          .set(<String, Object?>{
        'fingerprint': fingerprint,
        'postId': mediaId,
        'slot': BigFiveSlot.bench,
      });

  Future<void> publishShowcase(String fingerprint) =>
      firestore.collection('users_public').doc(_uid).set(
        <String, Object?>{'profileShowcaseV1': _showcaseMap(fingerprint)},
      );

  group('the maintenance pass actually runs everything', () {
    test('a confirmed PB is queued through the real staging adapter', () async {
      await seedClip();
      await publishShowcase(_fp());

      final SetVideoMaintenanceReport report =
          await buildService().runMaintenance(actor: _self);

      expect(report.ran, isTrue);
      expect(report.reconcile!.queued, 1);

      // The REAL outbox now holds a proof row for the exact fingerprint.
      final List<OutboxItem> pending = await outbox.pendingFor(_uid);
      expect(pending, hasLength(1));
      expect(pending.single.kind, OutboxKind.proof);
      expect(pending.single.achievementFingerprint, _fp());
      expect(pending.single.achievementSlot, BigFiveSlot.bench);
      expect(pending.single.mediaType, 'video');
    });

    test('the local record is marked queued with the real media id', () async {
      final SetVideoRecord r = await seedClip();
      await publishShowcase(_fp());
      await buildService().runMaintenance(actor: _self);

      final SetVideoRecord? row = await store.byId(r.id);
      expect(row!.state, SetVideoState.queued);
      final List<OutboxItem> pending = await outbox.pendingFor(_uid);
      expect(row.mediaId, pending.single.mediaId);
    });

    test('one pass sweeps, finalises, recovers and reconciles', () async {
      // An abandoned raw capture, and a soft deletion whose window has passed.
      final Directory tmp = await files.tempDir(_uid);
      File(p.join(tmp.path, 'abandoned.mp4')).writeAsStringSync('raw');
      final SetVideoRecord doomed = await seedClip(setId: 'sid-doomed');
      await store.softDelete(doomed.id);

      await seedClip();
      await publishShowcase(_fp());

      final SetVideoMaintenanceReport report = await buildService()
          .runMaintenance(actor: _self, undoWindow: Duration.zero);

      expect(report.swept, 1, reason: 'abandoned raw capture removed');
      expect(report.finalised, 1, reason: 'expired soft delete finalised');
      expect(report.reconcile!.queued, 1);
      expect(File(p.join(tmp.path, 'abandoned.mp4')).existsSync(), isFalse);
      expect(await store.byId(doomed.id), isNull);
      expect(File(doomed.localVideoPath).existsSync(), isFalse,
          reason: 'finalisation removes the bytes, not just the row');
    });

    test('running repeatedly still produces exactly one upload', () async {
      await seedClip();
      await publishShowcase(_fp());
      final SetVideoService s = buildService();

      await s.runMaintenance(actor: _self);
      await s.runMaintenance(actor: _self);
      await s.runMaintenance(actor: _self);

      expect(await outbox.claimableCount(_uid), 1);
    });

    test('a coach acting as an athlete runs nothing at all', () async {
      await seedClip();
      await publishShowcase(_fp());

      final SetVideoMaintenanceReport report = await buildService()
          .runMaintenance(
              actor: const SetVideoActor(
                  authenticatedUid: _coach, actingUid: _uid));

      expect(report.ran, isFalse);
      expect(await outbox.pendingFor(_uid), isEmpty);
    });
  });

  group('durable upload completion, with no in-memory callback', () {
    Future<SetVideoRecord> queued() async {
      final SetVideoRecord r = await seedClip();
      await publishShowcase(_fp());
      await buildService().runMaintenance(actor: _self);
      return (await store.byId(r.id))!;
    }

    test('an outbox row still present means the upload is still owed',
        () async {
      final SetVideoRecord r = await queued();
      await buildService().runMaintenance(actor: _self);

      expect((await store.byId(r.id))!.state, SetVideoState.queued,
          reason: 'work still queued must not be resolved either way');
    });

    test('row gone plus a proof pointer means published', () async {
      final SetVideoRecord r = await queued();
      final String mediaId = r.mediaId!;

      // Exactly what the uploader does on success: proof pointer, then the
      // outbox row goes.
      await writeProofPointer(fingerprint: _fp(), mediaId: mediaId);
      await outbox.remove(mediaId);

      await buildService().runMaintenance(actor: _self);

      final SetVideoRecord? row = await store.byId(r.id);
      expect(row!.state, SetVideoState.published);
      expect(row.postId, mediaId,
          reason: 'the real published identifier, not a guess');
    });

    test('row gone with no proof pointer returns it to local for retry',
        () async {
      final SetVideoRecord r = await queued();
      await outbox.remove(r.mediaId!);

      await buildService().runMaintenance(actor: _self);

      final SetVideoRecord? row = await store.byId(r.id);
      // The pass that resolves it also immediately re-queues it, which is the
      // retry: what must NOT happen is it being lost or marked published.
      expect(row!.state, isNot(SetVideoState.published));
      expect(File(row.localVideoPath).existsSync(), isTrue,
          reason: 'the user keeps their footage either way');
    });

    test('recovery after a restart needs no prior in-process state', () async {
      final SetVideoRecord r = await queued();
      final String mediaId = r.mediaId!;
      await writeProofPointer(fingerprint: _fp(), mediaId: mediaId);
      await outbox.remove(mediaId);

      // A brand new service instance, as after a cold start.
      final SetVideoService restarted = buildService();
      await restarted.runMaintenance(actor: _self);

      expect((await store.byId(r.id))!.state, SetVideoState.published);
    });

    test('a proof pointer for a DIFFERENT media id does not count', () async {
      final SetVideoRecord r = await queued();
      await writeProofPointer(fingerprint: _fp(), mediaId: 'some-other-media');
      await outbox.remove(r.mediaId!);

      await buildService().runMaintenance(actor: _self);
      expect((await store.byId(r.id))!.state, isNot(SetVideoState.published));
    });

    test('a record queued without a fingerprint is returned to local',
        () async {
      final SetVideoRecord r = await seedClip(setId: 'sid-nofp');
      await store.markQueued(
        id: r.id,
        mediaId: 'm-x',
        fingerprint: '',
        liftSlot: BigFiveSlot.bench,
        generation: r.generation,
      );
      await buildService().runMaintenance(actor: _self);
      expect((await store.byId(r.id))!.state, isNot(SetVideoState.queued));
    });

    test('a superseded fingerprint is not attached, and the clip is kept',
        () async {
      final SetVideoRecord r = await queued();
      final String mediaId = r.mediaId!;

      // Beaten while the upload was in flight.
      await writeProofPointer(fingerprint: _fp(), mediaId: mediaId);
      await publishShowcase(_fp(weight: 200));
      await outbox.remove(mediaId);

      await buildService().runMaintenance(actor: _self);

      final SetVideoRecord? row = await store.byId(r.id);
      expect(row!.state, isNot(SetVideoState.published));
      expect(row.postId, isNull);
      expect(File(row.localVideoPath).existsSync(), isTrue);
    });
  });

  group('the real performance adapter', () {
    test('locates the set by stable identity, never by index', () async {
      final _FakeRepo repo = _FakeRepo(<String, Wes2SavedSetPerformance>{
        'sid-1': Wes2SavedSetPerformance(
          exerciseId: _bench.exerciseId,
          exerciseName: _bench.displayName,
          setId: 'sid-1',
          weight: 180,
          reps: 2,
        ),
      });
      await seedClip();
      await publishShowcase(_fp());

      await buildService(repository: repo).runMaintenance(actor: _self);

      expect(repo.calls, greaterThan(0));
      expect(repo.lastSetId, 'sid-1');
    });

    test('an unreadable workout does not become a published PB', () async {
      await seedClip();
      await publishShowcase(_fp());

      final SetVideoMaintenanceReport report =
          await buildService(repository: _ThrowingRepo())
              .runMaintenance(actor: _self);

      expect(report.reconcile!.queued, 0);
      expect(await outbox.pendingFor(_uid), isEmpty);
    });
  });

  group('the real showcase projection adapter', () {
    test('reads users_public/{uid}.profileShowcaseV1', () async {
      await publishShowcase(_fp());
      final ProfileShowcase? s =
          await FirestoreShowcaseProjectionSource(firestore: firestore)
              .current(_uid);

      expect(s, isNotNull);
      expect(s!.liveFingerprints, contains(_fp()));
    });

    test('a document with no showcase is a confirmed "no records"', () async {
      await firestore
          .collection('users_public')
          .doc(_uid)
          .set(<String, Object?>{'username': 'x'});

      final ProfileShowcase? s =
          await FirestoreShowcaseProjectionSource(firestore: firestore)
              .current(_uid);
      expect(s, isNotNull);
      expect(s!.liveFingerprints, isEmpty);
    });

    test('a missing document is not confirmable rather than "no records"',
        () async {
      final ProfileShowcase? s =
          await FirestoreShowcaseProjectionSource(firestore: firestore)
              .current(_uid);
      expect(s, isNull,
          reason: 'null means retry; empty would mean confirmed non-PB');
    });

    test('an empty uid is refused', () async {
      expect(
        await FirestoreShowcaseProjectionSource(firestore: firestore)
            .current(''),
        isNull,
      );
    });

    test('nothing is queued while the projection cannot be read', () async {
      await seedClip(); // no users_public document at all
      final SetVideoMaintenanceReport report =
          await buildService().runMaintenance(actor: _self);

      expect(report.reconcile!.queued, 0);
      expect(await outbox.pendingFor(_uid), isEmpty);
      expect((await store.publishCandidates(_uid)), hasLength(1),
          reason: 'it stays a candidate and is retried when back online');
    });

    test('reconnecting promotes the clip that was offline', () async {
      await seedClip();
      final SetVideoService s = buildService();
      expect((await s.runMaintenance(actor: _self)).reconcile!.queued, 0);

      await publishShowcase(_fp());
      expect((await s.runMaintenance(actor: _self)).reconcile!.queued, 1);
      expect(await outbox.pendingFor(_uid), hasLength(1));
    });
  });

  group('the real proof-upload adapter', () {
    test('queues through MediaStaging, keeping the container honest', () async {
      final Directory dir = await files.videoDir(_uid);
      final File mov = File(p.join(dir.path, 'clip.MOV'))
        ..writeAsStringSync('quicktime-bytes');

      final String mediaId = await OutboxProofUploadQueue(
        MediaStaging(outbox: outbox),
      ).queueProof(
        ownerUid: _uid,
        file: mov,
        fingerprint: _fp(),
        slot: BigFiveSlot.bench,
      );

      final OutboxItem? row = await outbox.byId(mediaId);
      expect(row, isNotNull);
      expect(row!.kind, OutboxKind.proof);
      expect(row.storagePath, contains('users/$_uid/posts/$mediaId/'));
      expect(row.storagePath.toLowerCase(), endsWith('.mov'),
          reason: 'a MOV is not renamed to .mp4');
    });

    test('one clip owning both record categories still uploads once', () async {
      final String fp = _fp();
      final Map<String, Object?> lift = ((_showcaseMap(fp)['lifts']
          as Map<String, Object?>)[BigFiveSlot.bench] as Map<String, Object?>);
      await firestore
          .collection('users_public')
          .doc(_uid)
          .set(<String, Object?>{
        'profileShowcaseV1': <String, Object?>{
          'schema': 'profileShowcaseV1',
          'formulaVersion': 1,
          'lifts': <String, Object?>{
            // The SAME record in both positions: one set owning both.
            BigFiveSlot.bench: <String, Object?>{
              'e1rm': lift['e1rm'],
              'heaviest': lift['e1rm'],
            },
          },
        },
      });
      await seedClip();

      await buildService().runMaintenance(actor: _self);
      expect(await outbox.claimableCount(_uid), 1);
    });
  });

  group('owner scoping', () {
    test("another account's footage is never considered", () async {
      await seedClip(ownerUid: 'someone-else', setId: 'sid-9');
      await publishShowcase(_fp());

      final SetVideoMaintenanceReport report =
          await buildService().runMaintenance(actor: _self);

      expect(report.reconcile!.considered, 0);
      expect(await outbox.pendingFor(_uid), isEmpty);
    });

    test('sweeping and finalising stay owner scoped', () async {
      final SetVideoRecord theirs =
          await seedClip(ownerUid: 'someone-else', setId: 'sid-9');
      await store.softDelete(theirs.id);

      await buildService()
          .runMaintenance(actor: _self, undoWindow: Duration.zero);

      expect(await store.byId(theirs.id), isNotNull,
          reason: "one account's pass must not finalise another's deletions");
    });
  });
}
