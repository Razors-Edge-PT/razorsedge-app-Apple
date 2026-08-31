import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Proof that the set-video machinery is CONNECTED to the application.
///
/// Every isolated unit test in this repository passed against e52184f, and the
/// feature was still inert: SetVideoReconciler was constructed only inside
/// tests, its three interfaces had only test fakes, confirmPublished() had no
/// caller, finalizeExpiredDeletions() and sweepTemporary() had no caller, and
/// the camera tap never persisted the identity it minted. Nothing in a
/// class-level test could detect any of that.
///
/// These assertions read the production sources and require the call sites to
/// exist. That is a blunt instrument, and deliberately so: it is the only kind
/// of test that fails when a wire is cut but every class still behaves
/// correctly on its own. They complement — never replace — the behavioural
/// suites in wes2_set_video_service_test.dart and friends.
///
/// If a call site is legitimately moved, update the expectation here; do not
/// delete it.

/// Marker returned for a production file that does not exist.
///
/// A missing file is reported per-test rather than aborting the whole suite, so
/// running these against an older revision names each disconnected wire
/// individually instead of collapsing into one setUpAll failure.
const String kMissingSource = '<<file-not-present>>';

/// Reads a production source file, from the repository root.
String _source(String relativePath) {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    final File f = File('${dir.path}/$relativePath');
    if (f.existsSync()) return f.readAsStringSync();
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  return kMissingSource;
}

/// The body of a named method, delimited by real brace matching.
///
/// Picks the occurrence that actually has a BODY, so an abstract declaration of
/// the same name in an interface above the implementation is skipped, and stops
/// at the closing brace so a neighbouring method cannot satisfy an assertion.
String _method(String source, String signatureStart) {
  if (source == kMissingSource) {
    fail('the file declaring $signatureStart does not exist');
  }
  int from = 0;
  while (true) {
    final int start = source.indexOf(signatureStart, from);
    if (start < 0) {
      fail('method with a body not found: $signatureStart');
    }

    // Walk to the end of the parameter list, then decide: '{' is a body,
    // ';' is an abstract declaration and we keep looking.
    int i = start;
    int parens = 0;
    bool sawParen = false;
    while (i < source.length) {
      final String ch = source[i];
      if (ch == '(') {
        parens++;
        sawParen = true;
      } else if (ch == ')') {
        parens--;
        if (sawParen && parens == 0) break;
      }
      i++;
    }

    // Skip whitespace, `async`, and arrow bodies.
    int j = i + 1;
    while (j < source.length && source[j] != '{' && source[j] != ';') {
      j++;
    }
    if (j >= source.length || source[j] == ';') {
      from = start + signatureStart.length;
      continue; // abstract declaration; try the next occurrence
    }

    int depth = 0;
    int k = j;
    while (k < source.length) {
      if (source[k] == '{') depth++;
      if (source[k] == '}') {
        depth--;
        if (depth == 0) break;
      }
      k++;
    }
    return source.substring(start, k < source.length ? k + 1 : source.length);
  }
}

void main() {
  late String screen;
  late String services;
  late String coordinator;
  late String service;
  late String repository;
  late String controller;

  setUpAll(() {
    screen = _source('lib/WES2_screen.dart');
    services = _source('lib/profile/profile_services.dart');
    coordinator = _source('lib/wes2_video/set_video_coordinator.dart');
    service = _source('lib/wes2_video/set_video_service.dart');
    repository = _source('lib/WES2_repository.dart');
    controller = _source('lib/WES2_controller.dart');
  });

  group('the production files exist at all', () {
    test('the set-video service file is present', () {
      expect(service, isNot(kMissingSource),
          reason: 'lib/wes2_video/set_video_service.dart did not exist at '
              'e52184f, which is why nothing ever ran a pass');
    });
  });

  group('blocker 1: reconciliation has real production callers', () {
    test('ProfileServices constructs the set-video service', () {
      expect(services, contains('SetVideoService.ensureInitialised('),
          reason: 'nothing constructed it against e52184f');
      expect(services, contains('final SetVideoService? setVideo;'));
    });

    test('draining the outbox also runs the maintenance pass', () {
      final String body = _method(services, 'Future<void> processOutbox(');
      expect(body, contains('uploader.processAll()'));
      expect(body, contains('runSetVideoMaintenance('),
          reason: 'app start, resume and reconnect all arrive through here');
    });

    test('the maintenance entry point builds a real actor and runs the pass',
        () {
      final String body =
          _method(services, 'Future<void> runSetVideoMaintenance(');
      expect(body, contains('service.runMaintenance('));
      expect(body, contains('SetVideoActor('),
          reason: 'the gate needs authenticated and acting uids');
    });

    test('the service is constructed with the three REAL adapters', () {
      expect(service, contains('Wes2SetPerformanceSource('));
      expect(service, contains('FirestoreShowcaseProjectionSource('));
      expect(service, contains('OutboxProofUploadQueue('));
      expect(service, contains('SetVideoReconciler('));
    });

    test('the showcase adapter reads the authoritative server projection', () {
      expect(service, contains("collection('users_public')"));
      expect(service, contains("data['profileShowcaseV1']"));
      expect(service, contains('Source.server'),
          reason: 'a cached projection can be arbitrarily stale');
    });

    test('the upload adapter goes through the existing staging/outbox', () {
      expect(service, contains('_staging.queueProof('),
          reason: 'no parallel uploader');
    });

    test('confirmPublished is reached from durable recovery', () {
      expect(service, contains('reconciler.confirmPublished('),
          reason: 'it had zero callers against e52184f');
    });

    test('upload completion is recovered durably, not from a callback', () {
      final String body = _method(service, 'Future<int> _recoverQueued(');
      expect(body, contains('_outbox.byId('),
          reason: 'a surviving row means the upload is still owed');
      expect(body, contains("collection('proofs')"),
          reason: 'the proof pointer carries the published postId');
      expect(body, contains('markLocalOnly('),
          reason: 'dropped work returns to local so it can retry');
      expect(body, isNot(contains("collection('posts')")),
          reason: 'reading a MISSING posts/{id} is denied by the rules, not '
              'not-found — see functions/test-rules/set_video_paths.spec.js');
    });

    test('a WES2 set save triggers reconciliation', () {
      expect(screen, contains('_maybeReconcileAfterSetSave()'));
      final String saveBody =
          _method(screen, 'Future<void> _saveFieldSilently(');
      expect(saveBody, contains('_maybeReconcileAfterSetSave()'),
          reason: 'a confirmed weight/reps write is what creates a PB');
    });

    test('the app start path drains the outbox, which now reconciles', () {
      final String main = _source('lib/main.dart');
      expect(main, contains('ProfileServices.ensureInitialised()'));
      expect(main, contains('processOutbox()'));
    });

    test('overlapping passes are guarded', () {
      expect(service, contains('if (_running) return'),
          reason: 'concurrent triggers must not double-queue one clip');
    });
  });

  group('blocker 2: setId is persisted before any recording', () {
    late String tap;
    setUpAll(() => tap = _method(screen, 'Future<void> _onSetVideoTap('));

    test('the identity is minted from the live controller', () {
      expect(tap, contains('_controller.ensureSetId('));
    });

    test('it is written to the local draft, and awaited, before capture', () {
      expect(tap, contains('await _localStore.saveDraft('),
          reason: 'against e52184f nothing was persisted at all');
      final int draft = tap.indexOf('await _localStore.saveDraft(');
      final int capture = tap.indexOf('coordinator.handleTap(');
      expect(draft, greaterThanOrEqualTo(0));
      expect(capture, greaterThan(draft),
          reason: 'the draft write must complete BEFORE the camera opens');
    });

    test('a failed local write refuses to record', () {
      expect(tap, contains('SetVideoCopy.identityNotSaved'));
      expect(tap, contains('return;'));
    });

    test('it is also written additively to Firestore', () {
      expect(tap, contains('_saveSetIdToServer('));
      final String server = _method(screen, 'Future<void> _saveSetIdToServer(');
      expect(server, contains('_repository.saveSetId('));
    });

    test('the coordinator receives the REFRESHED row, not a stale capture', () {
      expect(tap, contains('_controller.rows.firstWhere('),
          reason: 'the row captured before minting has no setId on it');
      final int refresh = tap.indexOf('_controller.rows.firstWhere(');
      final int handle = tap.indexOf('coordinator.handleTap(');
      expect(refresh, lessThan(handle));
      expect(tap, contains('row: current'));
    });

    test('the repository write is additive and never overwrites an id', () {
      final String save = _method(repository, 'Future<void> saveSetId(');
      expect(save, contains('SetOptions(merge: true)'));
      expect(save, contains('readStableSetId('),
          reason: 'an existing id must win; replacing it moves a fingerprint');
      expect(save, contains('...sets[pos]'),
          reason: 'every other key on the set is preserved');
    });

    test('the saved-performance read is identity-only', () {
      final String read = _method(repository,
          'Future<Wes2SavedSetPerformance?> savedPerformanceForSet(');
      expect(read, contains('readStableSetId(rawSet) != wanted'));
      expect(read, isNot(contains('setIndex ==')),
          reason: 'an index match after a reindex is a DIFFERENT performance');
    });

    test('the controller still mints lazily and without costing an undo', () {
      final String ensure = _method(controller, 'String? ensureSetId(');
      expect(ensure, isNot(contains('_pushUndo()')));
      expect(ensure, contains('setIdGenerator()'));
    });
  });

  group('blocker 3: structural operations are video-aware', () {
    test('removing a set soft-deletes before the controller renumbers', () {
      final String body = _method(screen, 'Future<void> _onRemoveSet(');
      expect(body, contains('_videoSoftDeleteSets('));
      final int soft = body.indexOf('_videoSoftDeleteSets(');
      final int remove = body.indexOf('_controller.removeSet(');
      expect(soft, greaterThanOrEqualTo(0));
      expect(remove, greaterThan(soft),
          reason: 'after compaction the removed identity is unreachable');
    });

    test('removing the only set handles the exercise footage', () {
      final String body = _method(screen, 'Future<void> _onRemoveSet(');
      expect(body, contains('_videoSoftDeleteExercise('));
    });

    test('deleting an exercise soft-deletes all of its recordings', () {
      final String body = _method(screen, 'Future<void> _onDeleteExercise(');
      expect(body, contains('_videoSoftDeleteExercise('));
      final int soft = body.indexOf('_videoSoftDeleteExercise(');
      final int del = body.indexOf('_controller.deleteExercise(');
      expect(soft, lessThan(del));
    });

    test('replacing an exercise does not orphan its footage', () {
      final String body = _method(screen, 'Future<void> _onReplaceExercise(');
      expect(body, contains('_videoSoftDeleteExercise('));
    });

    test('template and whole-day replacement sweep orphans', () {
      expect(screen, contains('_videoSoftDeleteOrphans()'));
      // Both the template apply and the delete-all path.
      expect('_videoSoftDeleteOrphans()'.allMatches(screen).length,
          greaterThanOrEqualTo(1));
      expect(screen, contains('survivingExerciseIds:'));
    });

    test('undo restores the same records rather than minting new ones', () {
      final String body = _method(screen, 'void _performUndo()');
      expect(body, contains('_videoUndoStructuralDelete()'));
      final String undo =
          _method(screen, 'Future<void> _videoUndoStructuralDelete()');
      expect(undo, contains('undoStructuralDelete('));
      expect(coordinator, contains('_store.undoDelete(id)'));
    });

    test('the structural API is keyed on stable identity', () {
      expect(coordinator, contains('Future<List<String>> softDeleteForSets('));
      expect(coordinator, contains('required Iterable<String> setIds'));
      expect(coordinator, contains('Future<List<String>> softDeleteOrphans('));
    });
  });

  group('blocker 4: cleanup and finalisation are invoked', () {
    test('the maintenance pass sweeps and finalises', () {
      final String body =
          _method(service, 'Future<SetVideoMaintenanceReport> runMaintenance(');
      expect(body, contains('pipeline.sweepTemporary('),
          reason: 'no production caller existed against e52184f');
      expect(body, contains('pipeline.finalizeExpiredDeletions('));
    });

    test('both are owner scoped', () {
      final String body =
          _method(service, 'Future<SetVideoMaintenanceReport> runMaintenance(');
      expect(body, contains('actor.ownsSelf(ownerUid)'));
      expect(body, contains('ownerUid: ownerUid'));
    });

    test('the WES2 undo snackbar finalises when it closes without undo', () {
      final String body = _method(screen, 'void _showUndoSnackBar(');
      expect(body, contains('controller.closed'));
      expect(body, contains('SnackBarClosedReason.action'));
      expect(body, contains('_runSetVideoMaintenance()'));
    });

    test('deleting an attached video finalises when its snackbar closes', () {
      expect(coordinator, contains('bar.closed'));
      expect(coordinator, contains('finalizeDeletion('));
    });

    test('finalisation removes bytes and uses the central deletion path', () {
      final String body =
          _method(coordinator, 'Future<void> finalizeDeletion(');
      expect(body, contains('deletePostEverywhere('),
          reason: 'published media goes through the one shared implementation');
      expect(body, contains('cancelPending('),
          reason: 'an unpublished upload is cancelled, not left to happen');
      expect(body, contains('finalizeExpiredDeletions('),
          reason: 'the local video and poster bytes are unlinked');
    });
  });

  group('blocker 5 and 6: layout and platform', () {
    test('the icon slot constants are the corrected geometry', () {
      final String row = _source('lib/WES2_widgets/WES2_set_row.dart');
      expect(row, contains('kWes2RowIconSlotHeight = 48'));
      expect(row, contains('kWes2RowIconSlotWidth = 28'));
    });

    test('the derived columns yield instead of overflowing', () {
      final String row = _source('lib/WES2_widgets/WES2_set_row.dart');
      expect(row, contains('flexibleWhenBounded('));
      expect(row, contains('kWes2RowTrailingWidth'),
          reason:
              'the header reserves the same width, keeping columns aligned');
    });

    test('permission_handler is gone and the camera owns authorisation', () {
      final String pubspec = _source('pubspec.yaml');
      expect(pubspec, isNot(contains('permission_handler')),
          reason: 'it forced compileSdk 37 and an iOS Podfile step');
      final String capture =
          _source('lib/wes2_video/ui/set_video_capture_screen.dart');
      expect(capture, contains('classifyCameraError('));
      expect(capture, contains('CameraAccessDeniedWithoutPrompt'));
    });

    test('Android camera and microphone stay optional', () {
      final String manifest =
          _source('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('android.permission.CAMERA'));
      expect(manifest, contains('android.permission.RECORD_AUDIO'));
      expect(manifest, contains('android:required="false"'),
          reason: 'the app must install on devices without a camera');
    });

    test('no broader permission is requested than the feature needs', () {
      final String manifest =
          _source('android/app/src/main/AndroidManifest.xml');
      expect(manifest, isNot(contains('WRITE_EXTERNAL_STORAGE')));
      expect(manifest, isNot(contains('READ_MEDIA_VIDEO')));
    });
  });

  group('one database handle', () {
    test('only the service opens the set-video store', () {
      expect(service, contains('SetVideoDatabase.open()'));
      expect(coordinator, isNot(contains('SetVideoDatabase.open()')),
          reason: 'a second handle let two passes claim the same row');
      expect(coordinator, contains('services.setVideo'));
    });

    test('WES2 tolerates the store failing to open', () {
      final String tap = _method(screen, 'Future<void> _onSetVideoTap(');
      expect(tap, contains('SetVideoCopy.storeUnavailable'),
          reason: 'logging a workout must never depend on set video');
      expect(services, contains('setVideo = null'));
    });
  });
}
