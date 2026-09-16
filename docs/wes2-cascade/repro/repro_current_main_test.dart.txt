// DISPOSABLE REPRODUCTION against unmodified origin/main (abdaa477).
// Not a gate and not part of the implementation. Prints observations; the
// consolidated plan (docs/wes2-cascade/PLAN.md) records the output.
//
// Everything below calls PRODUCTION classes directly (controller, hint service,
// Drift outbox, sync engine, FirestoreWes2Repository on FakeFirebaseFirestore,
// SetVideoStore/SetVideoPipeline). Where a screen method would normally drive
// the call, the comment names the exact production line being mirrored.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_hint_service.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/wes2_sync/wes2_mutation.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';
import 'package:localtest222/wes2_video/set_video_files.dart';
import 'package:localtest222/wes2_video/set_video_pipeline.dart';
import 'package:localtest222/wes2_video/set_video_store.dart';

const _exId = 'ex_press';
const _exName = 'Seated Shoulder Dumbbell Press';
const _uid = 'u1';
const _blockId = 'b1';
final _blockStart = DateTime(2026, 1, 5);
final _blockEnd = DateTime(2026, 4, 1);
final _day = DateTime(2026, 1, 12);

Map<String, dynamic> _settings() => {
      _exId: {
        'periodizationModel': 'Linear, Classic',
        'weeklyFrequency': 1,
        'increments': {'primary': 2.5},
        'repTargets': {
          'week1': {'instance1': '10 x 3'},
          'week2': {'instance1': '10 x 3'},
        },
        'rirPlan': {
          for (final wk in const ['week1', 'week2'])
            wk: {
              'session1': {
                'set1': {'rir': '2'},
                'set2': {'rir': '2'},
                'set3': {'rir': '2'},
              }
            }
        },
      }
    };

Wes2FieldState<T> _a<T>(T? v) => Wes2FieldState<T>(
    actualValue: v, origin: v != null ? FieldOrigin.typed : FieldOrigin.empty);

Wes2SetState _set(int i, {double? w, int? r, double? rir}) => Wes2SetState(
    setIndex: i, weight: _a<double>(w), reps: _a<int>(r), rir: _a<double>(rir));

String _fmt(Wes2SetState s) {
  String f<T>(Wes2FieldState<T> x) =>
      x.actualValue != null ? '${x.actualValue}*' : '${x.hintValue}';
  final w = s.weight.actualValue ?? s.weight.hintValue;
  final r = s.reps.actualValue ?? s.reps.hintValue;
  final rir = s.rir.actualValue ?? s.rir.hintValue ?? 0.0;
  final e = (w != null && r != null)
      ? PeriodizationModelUtils.calculateE1RM(w, r.toDouble(), rir)
          .toStringAsFixed(4)
      : '-';
  return 'S${s.setIndex + 1} ${f(s.weight)} x ${f(s.reps)} @ ${f(s.rir)} e1rm=$e';
}

Wes2HintServiceImpl _svc() => Wes2HintServiceImpl(
    exerciseSettings: _settings(),
    blockStartDate: _blockStart,
    blockEndDate: _blockEnd,
    uid: _uid);

Wes2ExerciseRow _row(List<Wes2SetState> sets) => Wes2ExerciseRow(
    exerciseId: _exId,
    name: _exName,
    circuitIndex: 0,
    orderIndex: 0,
    setCount: sets.length,
    source: Wes2RowSource.wes2Manual,
    sets: sets);

void main() {
  setUp(() {
    PeriodizationModelUtils.savedWorkoutsList = [];
    PeriodizationModelUtils.topSetsByExercise.clear();
  });

  group('R-HINT literal fixtures through current computeRowHints', () {
    test('predecessor 40x10@2 -> Set 2 free hint', () {
      final out = _svc().computeRowHints(
          row: _row([_set(0, w: 40, r: 10, rir: 2), _set(1), _set(2)]),
          blockId: _blockId,
          uid: _uid,
          date: _day);
      for (final s in out.sets) {
        print('R-HINT-1 ${_fmt(s)}');
      }
    });
    test('predecessor 20x20@0 -> Set 2 free hint', () {
      final out = _svc().computeRowHints(
          row: _row([_set(0, w: 20, r: 20, rir: 0), _set(1), _set(2)]),
          blockId: _blockId,
          uid: _uid,
          date: _day);
      for (final s in out.sets) {
        print('R-HINT-2 ${_fmt(s)}');
      }
    });
    test('predecessor 40x7@2, Set 2 weight 20 -> reps hint', () {
      final out = _svc().computeRowHints(
          row: _row([_set(0, w: 40, r: 7, rir: 2), _set(1, w: 20), _set(2)]),
          blockId: _blockId,
          uid: _uid,
          date: _day);
      for (final s in out.sets) {
        print('R-HINT-3 ${_fmt(s)}');
      }
    });
    test('stale own rep hint 30 moves the current Set 2 search centre', () {
      final s1 = _set(1).copyWith(
          reps: const Wes2FieldState<int>(
              hintValue: 30, hintOrigin: FieldOrigin.modelHint,
              origin: FieldOrigin.modelHint));
      final out = _svc().computeRowHints(
          row: _row([_set(0, w: 20, r: 20, rir: 0), s1, _set(2)]),
          blockId: _blockId,
          uid: _uid,
          date: _day);
      print('R-HINT-4 with stale own hint 30: ${_fmt(out.sets[1])}');
    });
    test('accepted 40x10 at Set 2 through the controller edit path', () {
      for (final order in const ['weight-then-reps', 'reps-then-weight']) {
        final svc = _svc();
        final c = Wes2SessionController(_day)
          ..initIdentity(
              actorUid: _uid,
              actingUid: _uid,
              isCoach: false,
              activeBlockId: _blockId,
              blockStartDate: _blockStart,
              blockEndDate: _blockEnd);
        final e = c.beginLoad();
        c.setRows([_row([_set(0, w: 40, r: 10, rir: 2), _set(1), _set(2)])], e);
        // Mirrors WES2_screen.dart:816-851 synchronous tail.
        for (final r in c.rows.toList()) {
          c.applyModelHints(r.exerciseId,
              svc.computeRowHints(row: r, blockId: _blockId, uid: _uid, date: _day));
        }
        c.captureBaselineHintRows();
        c.setHintService(svc, _blockId);
        print('R-HINT-5 [$order] free: ${c.rows.first.sets.map(_fmt).join(' | ')}');
        void t(Wes2FieldKey k, String v) => c.updateSetField(
            exerciseId: _exId, setIndex: 1, fieldKey: k, rawText: v);
        if (order == 'weight-then-reps') {
          t(Wes2FieldKey.weight, '40');
          print('R-HINT-5 [$order] after w=40: ${_fmt(c.rows.first.sets[1])}');
          final shown = c.rows.first.sets[1].reps.hintValue;
          t(Wes2FieldKey.reps, '$shown');
        } else {
          t(Wes2FieldKey.reps, '10');
          print('R-HINT-5 [$order] after r=10: ${_fmt(c.rows.first.sets[1])}');
          final shown = c.rows.first.sets[1].weight.hintValue;
          t(Wes2FieldKey.weight, '$shown');
        }
        print('R-HINT-5 [$order] accepted: ${c.rows.first.sets.map(_fmt).join(' | ')}');
      }
    });
  });

  test('R-PARSE non-finite text becomes an actual', () {
    final c = Wes2SessionController(_day);
    final e = c.beginLoad();
    c.setRows([_row([_set(0), _set(1)])], e);
    for (final t in const ['NaN', 'Infinity', '-Infinity', '.', '-']) {
      c.updateSetField(
          exerciseId: _exId, setIndex: 0, fieldKey: Wes2FieldKey.weight, rawText: '25');
      c.updateSetField(
          exerciseId: _exId, setIndex: 0, fieldKey: Wes2FieldKey.weight, rawText: t);
      print('R-PARSE "$t" -> weight actual=${c.rows.first.sets[0].weight.actualValue}');
    }
  });

  test('R-HINTORIGIN draft JSON drops hintOrigin (BB3 lock lost)', () {
    final s = const Wes2SetState(
        setIndex: 0,
        weight: Wes2FieldState<double>(
            hintValue: 50, hintOrigin: FieldOrigin.bb3Hint, origin: FieldOrigin.bb3Hint));
    final back = Wes2SetState.fromJson(s.toJson());
    print('R-HINTORIGIN before=${s.weight.hintOrigin} after=${back.weight.hintOrigin} '
        'hint=${back.weight.hintValue}');
  });

  group('R-SYNC through real outbox + engine + repository', () {
    late Wes2MutationDatabase db;
    late Wes2MutationOutbox outbox;
    late FakeFirebaseFirestore fs;
    final date = DateTime(2026, 5, 4);
    const ex = 'bench';

    Future<void> seed(List<double> ws) => fs
            .collection('users')
            .doc('a')
            .collection('workouts')
            .doc('2026-05-04')
            .set({
          'userId': 'a',
          'date': '2026-05-04',
          'exercises': [
            {
              'exerciseId': ex,
              'name': 'Bench',
              'circuitIndex': 0,
              'orderIndex': 0,
              'setCount': ws.length,
              'sets': [
                for (int i = 0; i < ws.length; i++) {'setIndex': i, 'weight': ws[i]}
              ],
            }
          ],
          'wesPlannedExercises': [],
        });

    setUp(() {
      db = Wes2MutationDatabase.memory();
      outbox = Wes2MutationOutbox(db);
      fs = FakeFirebaseFirestore();
    });
    tearDown(() => db.close());

    test('Undo after an applied removal is not durable', () async {
      await seed([50, 60, 70]);
      final repo = FirestoreWes2Repository(firestore: fs);
      final engine = Wes2SyncEngine(
          outbox: outbox,
          repository: repo,
          currentActorUid: () => 'a',
          autoStartTimer: false,
          autoProcessOnSubmit: false);
      final c = Wes2SessionController(date)
        ..initIdentity(actorUid: 'a', actingUid: 'a', isCoach: false);
      final e = c.beginLoad();
      c.setRows(await repo.loadDay(uid: 'a', date: date), e);
      // Mirrors WES2_screen.dart:2917-2932 (_onRemoveSet, no video).
      c.removeSet(ex, 1);
      await engine.submit(Wes2Mutation.removeSet(
          actorUid: 'a', athleteUid: 'a', date: date, exerciseId: ex,
          setIndex: 1, expectedSetCountBefore: 3, localSeq: 1));
      await engine.processNow();
      // Mirrors WES2_screen.dart:2158-2168 (_performUndo): controller only.
      c.undo();
      print('R-UNDO local after undo: '
          '${c.rows.first.sets.map((s) => s.weight.actualValue).toList()}');
      print('R-UNDO queue after undo: ${(await outbox.totalCount())} rows');
      final reloaded = await repo.loadDay(uid: 'a', date: date);
      print('R-UNDO server reload: '
          '${reloaded.first.sets.map((s) => s.weight.actualValue).toList()}');
      await engine.dispose();
    });

    test('localSeq reuse across screen visits collapses two removals', () async {
      // _localMutationSeq is a State field (WES2_screen.dart:2703/2953), so a
      // new visit starts from 1 again.
      await outbox.enqueue(Wes2Mutation.removeSet(
          actorUid: 'a', athleteUid: 'a', date: date, exerciseId: ex,
          setIndex: 1, expectedSetCountBefore: 3, localSeq: 1));
      await outbox.enqueue(Wes2Mutation.removeSet(
          actorUid: 'a', athleteUid: 'a', date: date, exerciseId: ex,
          setIndex: 1, expectedSetCountBefore: 2, localSeq: 1));
      final rows = await outbox.pendingForDay(
          actorUid: 'a', athleteUid: 'a', dateKey: '2026-05-04');
      print('R-SEQ queued removals: ${rows.length} '
          '${rows.map((r) => '${r.id} ${r.payloadJson}').toList()}');
    });

    test('saveSetId ignores the injected Firestore', () async {
      await seed([50, 60, 70]);
      final repo = FirestoreWes2Repository(firestore: fs);
      try {
        await repo.saveSetId(
            uid: 'a', date: date, exerciseId: ex, setIndex: 0, setId: 'sid-1');
        print('R-SETID completed without throwing');
      } catch (err) {
        print('R-SETID threw: ${err.runtimeType}: $err');
      }
    });
  });

  test('R-MEDIA zero-window finalisation purges an unrelated structural soft delete',
      () async {
    final root = await Directory.systemTemp.createTemp('wes2_repro_media');
    final vdb = SetVideoDatabase.memory();
    final store = SetVideoStore(vdb);
    final files = AppSupportSetVideoFiles(supportDirectory: () async => root);
    final pipeline =
        SetVideoPipeline(store: store, files: files, trimmer: _NoTrim());
    final dir = await files.videoDir('a');
    Future<String> clip(String name) async {
      final f = File('${dir.path}/$name.mp4')..writeAsStringSync('bytes-$name');
      await store.put(
          ownerUid: 'a', dateKey: '2026-05-04', exerciseId: 'bench',
          setId: name, localVideoPath: f.path);
      return f.path;
    }

    final structuralPath = await clip('setB'); // removed set, Undo still offered
    final otherPath = await clip('setC'); // user deletes this video directly
    // WES2_screen.dart:3076 (structural remove) then coordinator.dart:341.
    await store.softDelete('a|2026-05-04|bench|setB');
    await store.softDelete('a|2026-05-04|bench|setC');
    // coordinator.dart:411 — finalizeDeletion(setC) runs this owner-wide call.
    final n = await pipeline.finalizeExpiredDeletions(
        ownerUid: 'a', undoWindow: Duration.zero);
    print('R-MEDIA finalised=$n '
        'structuralFileExists=${File(structuralPath).existsSync()} '
        'structuralRow=${await store.byId('a|2026-05-04|bench|setB')} '
        'otherFileExists=${File(otherPath).existsSync()}');
    await vdb.close();
    await root.delete(recursive: true);
  });
}

class _NoTrim implements SetVideoTrimEngine {
  @override
  Future<void> clearCache() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
