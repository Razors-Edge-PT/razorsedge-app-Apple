import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/wes2_exit_coordinator.dart';
import 'package:localtest222/wes2_sync/wes2_mutation.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_pending_overlay.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';

/// Product semantics that must survive the durability work.
///
/// The rule the previous attempt got wrong: a HINT is a suggestion, and Mark as
/// Done is a checkmark. Neither may ever become logged execution data. Only a
/// value the athlete actually entered is saved — and, thanks to the outbox, it
/// is saved reliably.
///
/// Also pins the reconciliation rules: a stale draft no longer beats a
/// confirmed server value, but genuinely pending intent does.

const String kActor = 'athlete-1';
const String kExId = 'bench_press_barbell';
final DateTime kDate = DateTime(2026, 5, 4);
const String kDocId = '2026-05-04';

Wes2FieldState<double> _d({double? actual, double? hint}) =>
    Wes2FieldState<double>(
      actualValue: actual,
      hintValue: hint,
      origin: actual != null ? FieldOrigin.typed : FieldOrigin.bb3Hint,
      hintOrigin: hint != null ? FieldOrigin.bb3Hint : FieldOrigin.empty,
    );

Wes2FieldState<int> _i({int? actual, int? hint}) => Wes2FieldState<int>(
      actualValue: actual,
      hintValue: hint,
      origin: actual != null ? FieldOrigin.typed : FieldOrigin.bb3Hint,
      hintOrigin: hint != null ? FieldOrigin.bb3Hint : FieldOrigin.empty,
    );

/// A BB3-planned set: hints always present, actuals only where logged.
Wes2SetState _set(
  int i, {
  double? weight,
  int? reps,
  double? rir,
  double weightHint = 130,
  int repsHint = 5,
  double? rirHint = 2.0,
}) =>
    Wes2SetState(
      setIndex: i,
      weight: _d(actual: weight, hint: weightHint),
      reps: _i(actual: reps, hint: repsHint),
      rir: _d(actual: rir, hint: rirHint),
    );

Wes2ExerciseRow _row(List<Wes2SetState> sets, {String exerciseId = kExId}) =>
    Wes2ExerciseRow(
      exerciseId: exerciseId,
      name: 'Bench Press, Barbell',
      circuitIndex: 0,
      orderIndex: 0,
      setCount: sets.length,
      sets: sets,
      source: Wes2RowSource.bb3Planned,
    );

DocumentReference<Map<String, dynamic>> _dayRef(FakeFirebaseFirestore db) =>
    db.collection('users').doc(kActor).collection('workouts').doc(kDocId);

Future<List<Map<String, dynamic>>> _storedSets(FakeFirebaseFirestore db) async {
  final snap = await _dayRef(db).get();
  final rows = (snap.data()?['exercises'] as List<dynamic>? ?? <dynamic>[])
      .cast<Map<String, dynamic>>();
  final row = rows.firstWhere((r) => r['exerciseId'] == kExId);
  return (row['sets'] as List<dynamic>).cast<Map<String, dynamic>>();
}

Future<Map<String, dynamic>> _storedRow(FakeFirebaseFirestore db) async {
  final snap = await _dayRef(db).get();
  final rows = (snap.data()?['exercises'] as List<dynamic>? ?? <dynamic>[])
      .cast<Map<String, dynamic>>();
  return rows.firstWhere((r) => r['exerciseId'] == kExId);
}

void main() {
  late FakeFirebaseFirestore db;
  late Wes2MutationDatabase mdb;
  late Wes2MutationOutbox outbox;
  late Wes2SyncEngine engine;

  setUp(() {
    db = FakeFirebaseFirestore();
    mdb = Wes2MutationDatabase.memory();
    outbox = Wes2MutationOutbox(mdb);
    engine = Wes2SyncEngine(
      outbox: outbox,
      repository: FirestoreWes2Repository(firestore: db),
      currentActorUid: () => kActor,
      autoStartTimer: false,
      autoProcessOnSubmit: false,
      baseBackoff: Duration.zero,
    );
  });

  tearDown(() async {
    await engine.dispose();
    await mdb.close();
  });

  /// The production field-save path: queue the athlete's value, then sync.
  Future<void> enterField(
    Wes2ExerciseRow row,
    int setIndex,
    Wes2FieldKey key,
    Object? value,
  ) async {
    await engine.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kActor,
      date: kDate,
      row: row,
      setIndex: setIndex,
      fieldKey: key,
      value: value,
    ));
  }

  /// The production Done path.
  Future<void> pressDone(Wes2ExerciseRow row, {bool isDone = true}) =>
      engine.submit(Wes2Mutation.markDone(
        actorUid: kActor,
        athleteUid: kActor,
        date: kDate,
        row: row,
        isDone: isDone,
      ));

  // ── TEST 2 / 14 / 30 — a hint is never execution data ────────────────────

  group('TEST 2 / 14 / 30 — an untouched RIR hint stays a hint', () {
    test('weight and reps entered, RIR hint untouched, Done pressed', () async {
      // Exactly the reported scenario: hints 130 / 5 / 2, the athlete types
      // 130 and 5, never touches RIR, then taps Done.
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        _set(0, weight: 130, reps: 5),
      ]);
      await enterField(row, 0, Wes2FieldKey.weight, 130.0);
      await enterField(row, 0, Wes2FieldKey.reps, 5);
      await pressDone(row);
      expect((await engine.process()).applied, 3);

      final List<Map<String, dynamic>> sets = await _storedSets(db);
      expect(sets.single['weight'], 130.0);
      expect(sets.single['reps'], 5);
      expect(sets.single.containsKey('rir'), isFalse,
          reason: 'the displayed RIR 2 was never entered, so it is not data');
      expect(sets.single['rir'], isNull);
      expect((await _storedRow(db))['isMarkedDone'], isTrue);
    });

    test('Done changes ONLY the completion flag on an existing row', () async {
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        _set(0, weight: 130, reps: 5),
      ]);
      await enterField(row, 0, Wes2FieldKey.weight, 130.0);
      await enterField(row, 0, Wes2FieldKey.reps, 5);
      await engine.process();

      final Map<String, dynamic> before = await _storedRow(db);
      final List<Map<String, dynamic>> setsBefore = await _storedSets(db);

      await pressDone(row);
      await engine.process();

      final Map<String, dynamic> after = await _storedRow(db);
      expect(await _storedSets(db), setsBefore,
          reason: 'no execution value may change when Done is pressed');
      expect(before['isMarkedDone'], isFalse);
      expect(after['isMarkedDone'], isTrue);
      // Everything except the flag is byte-identical.
      expect(
        Map<String, dynamic>.from(after)..remove('isMarkedDone'),
        Map<String, dynamic>.from(before)..remove('isMarkedDone'),
      );
    });

    test('Done on a row never saved before invents no execution values',
        () async {
      // Nothing has been written for the day. Done creates the row, and it must
      // carry no hint-derived values at all.
      await pressDone(_row(<Wes2SetState>[_set(0), _set(1), _set(2)]));
      await engine.process();

      final List<Map<String, dynamic>> sets = await _storedSets(db);
      for (final Map<String, dynamic> s in sets) {
        expect(s.containsKey('weight'), isFalse);
        expect(s.containsKey('reps'), isFalse);
        expect(s.containsKey('rir'), isFalse);
      }
      expect((await _storedRow(db))['isMarkedDone'], isTrue);
    });

    test('no weight, reps or velocity hint becomes an actual either', () async {
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        // Only reps was entered; weight and RIR are hints alone.
        _set(0, reps: 5),
      ]);
      await enterField(row, 0, Wes2FieldKey.reps, 5);
      await pressDone(row);
      await engine.process();

      final List<Map<String, dynamic>> sets = await _storedSets(db);
      expect(sets.single['reps'], 5);
      expect(sets.single.containsKey('weight'), isFalse);
      expect(sets.single.containsKey('rir'), isFalse);
      expect(sets.single.containsKey('velocity'), isFalse);
    });
  });

  // ── TEST 3 / 13 — an actual RIR saves, independently of Done ─────────────

  group('TEST 3 / 13 — an explicitly entered RIR', () {
    test('RIR 0 is a real value and is saved as 0', () async {
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        _set(0, weight: 130, reps: 5, rir: 0.0, rirHint: 2.0),
      ]);
      await enterField(row, 0, Wes2FieldKey.weight, 130.0);
      await enterField(row, 0, Wes2FieldKey.reps, 5);
      await enterField(row, 0, Wes2FieldKey.rir, 0.0);
      await pressDone(row);
      await engine.process();

      final List<Map<String, dynamic>> sets = await _storedSets(db);
      expect(sets.single['rir'], 0.0);
      expect(sets.single.containsKey('rir'), isTrue,
          reason: 'zero is entered data, not a missing value');
      expect((await _storedRow(db))['isMarkedDone'], isTrue);
    });

    test('RIR 2 entered by hand saves as 2 even though the hint is also 2',
        () async {
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        _set(0, weight: 130, reps: 5, rir: 2.0, rirHint: 2.0),
      ]);
      await enterField(row, 0, Wes2FieldKey.rir, 2.0);
      await engine.process();
      expect((await _storedSets(db)).single['rir'], 2.0);
    });

    test('an entered RIR reaches the server with Done never pressed at all',
        () async {
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        _set(0, weight: 130, reps: 5, rir: 1.5),
      ]);
      await enterField(row, 0, Wes2FieldKey.rir, 1.5);
      await engine.process();

      expect((await _storedSets(db)).single['rir'], 1.5);
      expect((await _storedRow(db))['isMarkedDone'], isFalse,
          reason: 'saving a field must not imply completion');
    });

    test('an entered RIR survives being offline when Done is pressed',
        () async {
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        _set(0, weight: 130, reps: 5, rir: 1.5),
      ]);
      // The engine cannot reach the server; both intents are queued.
      await enterField(row, 0, Wes2FieldKey.rir, 1.5);
      await pressDone(row);
      expect(await outbox.countFor(kActor), 2);

      await engine.process();
      expect((await _storedSets(db)).single['rir'], 1.5);
      expect((await _storedRow(db))['isMarkedDone'], isTrue);
    });
  });

  // ── TEST 12 — last field then Back ───────────────────────────────────────

  group('TEST 12 — typing the final field then leaving immediately', () {
    // The widget half asserts the ORDERING contract: focus is dropped, the
    // field's ordinary save runs, and the durability barrier completes before
    // navigation is allowed. It uses a controllable future rather than the real
    // SQLite store because `testWidgets` runs in a fake-async zone that a real
    // drift transaction cannot complete inside. The store half, below, drives
    // the same production call against the real outbox.
    testWidgets('Back drops focus, then waits for the durable write before '
        'navigating', (WidgetTester tester) async {
      final List<String> order = <String>[];
      final Wes2ExitCoordinator coordinator = Wes2ExitCoordinator();
      final Completer<void> durable = Completer<void>();

      final Wes2SessionController controller = Wes2SessionController(kDate)
        ..initIdentity(actorUid: kActor, actingUid: kActor, isCoach: false);
      controller.setRows(
        <Wes2ExerciseRow>[
          _row(<Wes2SetState>[_set(0, weight: 130, reps: 5)])
        ],
        controller.beginLoad(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (BuildContext context, Widget? _) => Wes2SetRow(
              set: controller.rows.single.sets.first,
              showVelocity: false,
              onFieldChanged: (Wes2FieldKey k, String t) =>
                  controller.updateSetField(
                exerciseId: kExId,
                setIndex: 0,
                fieldKey: k,
                rawText: t,
              ),
              onFieldUnfocused: (Wes2FieldKey k, String t) {
                order.add('queue:${k.name}=$t');
                // Stands in for _submitMutation's local write.
                durable.complete();
              },
            ),
          ),
        ),
      ));

      // Field order in normal mode: weight(0), reps(1), rir(2).
      await tester.enterText(find.byType(TextField).at(2), '1.5');
      expect(order, isEmpty, reason: 'the field still holds focus');

      // Immediately Back, with the keyboard still up.
      final Future<Wes2ExitAction> exit = coordinator.exitToPreviousRoute(
        dropFocus: () => FocusManager.instance.primaryFocus?.unfocus(),
        isMounted: () => true,
        markHomeActive: () => order.add('markHome'),
        awaitDurableWrites: () async {
          order.add('barrier');
          await durable.future;
        },
        navigatorOf: () {
          order.add('navigate');
          return null;
        },
      );
      await tester.pumpAndSettle();
      await exit;

      // Tapping Back does not unfocus a TextField on its own, so without the
      // explicit drop the last value would never have been queued at all.
      expect(order.first, 'queue:rir=1.5');
      expect(order, containsAllInOrder(<String>['barrier', 'navigate']));
      expect(controller.rows.single.sets.first.rir.actualValue, 1.5);
    });

    test('the same call really does make the value durable in the outbox',
        () async {
      final Wes2ExerciseRow row = _row(<Wes2SetState>[
        _set(0, weight: 130, reps: 5, rir: 1.5),
      ]);
      // Production's _saveFieldSilently, with no network available.
      await enterField(row, 0, Wes2FieldKey.rir, 1.5);

      expect(await outbox.countFor(kActor), 1,
          reason: 'durable before the widget tree could be torn down');
      await engine.process();
      expect((await _storedSets(db)).single['rir'], 1.5);
    });

    // A plain test: the coordinator is pure Dart, and awaiting its internal
    // event-loop yield inside a widget tester's fake-async zone would deadlock.
    test('a barrier that throws still lets the athlete leave', () async {
      final Wes2ExitCoordinator coordinator = Wes2ExitCoordinator();
      bool navigated = false;
      final Wes2ExitAction action = await coordinator.exitToPreviousRoute(
        dropFocus: () {},
        isMounted: () => true,
        markHomeActive: () {},
        awaitDurableWrites: () async => throw StateError('disk full'),
        navigatorOf: () {
          navigated = true;
          return null;
        },
      );
      expect(navigated, isTrue);
      expect(action, Wes2ExitAction.skippedUnmounted);
    });
  });

  // ── TESTS 10 / 11 — reconciliation ───────────────────────────────────────

  group('TEST 10 — a stale draft never beats a confirmed server value', () {
    test('server 130 wins over draft 125 when nothing is pending', () {
      final List<Wes2ExerciseRow> server = <Wes2ExerciseRow>[
        _row(<Wes2SetState>[_set(0, weight: 130, reps: 5)])
      ];
      final List<Wes2ExerciseRow> draft = <Wes2ExerciseRow>[
        _row(<Wes2SetState>[_set(0, weight: 125, reps: 5)])
      ];

      final List<Wes2ExerciseRow> out =
          wes2ApplyDraftWithoutOverridingServer(server, draft);
      expect(out.single.sets.first.weight.actualValue, 130,
          reason: 'the draft is a cache, not an authority');
    });

    test('a draft-only value still shows where the server holds nothing', () {
      // Upgrade safety: drafts written before the outbox existed may hold the
      // only copy of a swallowed write, and blanking those would destroy the
      // very data this work protects.
      final List<Wes2ExerciseRow> server = <Wes2ExerciseRow>[
        _row(<Wes2SetState>[_set(0, reps: 5)])
      ];
      final List<Wes2ExerciseRow> draft = <Wes2ExerciseRow>[
        _row(<Wes2SetState>[_set(0, weight: 125, reps: 5)])
      ];
      final List<Wes2ExerciseRow> out =
          wes2ApplyDraftWithoutOverridingServer(server, draft);
      expect(out.single.sets.first.weight.actualValue, 125);
    });

    test('a draft never fabricates a value the athlete cleared on the server',
        () {
      final List<Wes2ExerciseRow> server = <Wes2ExerciseRow>[
        _row(<Wes2SetState>[_set(0, weight: 130, reps: 5, rir: 1.0)])
      ];
      final List<Wes2ExerciseRow> draft = <Wes2ExerciseRow>[
        _row(<Wes2SetState>[_set(0, weight: 130, reps: 5, rir: 3.0)])
      ];
      final List<Wes2ExerciseRow> out =
          wes2ApplyDraftWithoutOverridingServer(server, draft);
      expect(out.single.sets.first.rir.actualValue, 1.0);
    });
  });

  group('TEST 11 — pending local intent overrides the server until synced', () {
    List<Wes2ExerciseRow> overlay(List<Wes2PendingChange> pending) =>
        wes2ApplyPendingOverlay(
          <Wes2ExerciseRow>[
            _row(<Wes2SetState>[_set(0, weight: 125, reps: 5, rir: 2.0)])
          ],
          pending,
        );

    test('a pending weight of 130 shows over a server value of 125', () {
      final List<Wes2ExerciseRow> out = overlay(<Wes2PendingChange>[
        Wes2PendingChange(
          seq: 1,
          kind: Wes2MutationKind.field,
          exerciseId: kExId,
          setIndex: 0,
          payload: const <String, dynamic>{'fieldKey': 'weight', 'value': 130},
        ),
      ]);
      expect(out.single.sets.first.weight.actualValue, 130);
    });

    test('a pending CLEAR blanks the field the server still holds', () {
      // The tombstone case: without it, an old server value reappears at every
      // merge and the athlete cannot delete anything offline.
      final List<Wes2ExerciseRow> out = overlay(<Wes2PendingChange>[
        Wes2PendingChange(
          seq: 1,
          kind: Wes2MutationKind.field,
          exerciseId: kExId,
          setIndex: 0,
          payload: const <String, dynamic>{'fieldKey': 'rir', 'value': null},
        ),
      ]);
      expect(out.single.sets.first.rir.actualValue, isNull);
      expect(out.single.sets.first.rir.hintValue, 2.0,
          reason: 'clearing an actual reveals the hint, it does not erase it');
    });

    test('the newest pending value for a field is the one shown', () {
      final List<Wes2ExerciseRow> out = overlay(<Wes2PendingChange>[
        Wes2PendingChange(
          seq: 9,
          kind: Wes2MutationKind.field,
          exerciseId: kExId,
          setIndex: 0,
          payload: const <String, dynamic>{'fieldKey': 'weight', 'value': 140},
        ),
        Wes2PendingChange(
          seq: 2,
          kind: Wes2MutationKind.field,
          exerciseId: kExId,
          setIndex: 0,
          payload: const <String, dynamic>{'fieldKey': 'weight', 'value': 120},
        ),
      ]);
      expect(out.single.sets.first.weight.actualValue, 140);
    });

    test('a pending Done shows as done, and pending notes show too', () {
      final List<Wes2ExerciseRow> out = overlay(<Wes2PendingChange>[
        const Wes2PendingChange(
          seq: 1,
          kind: Wes2MutationKind.markDone,
          exerciseId: kExId,
          payload: <String, dynamic>{'isDone': true},
        ),
        const Wes2PendingChange(
          seq: 2,
          kind: Wes2MutationKind.setNote,
          exerciseId: kExId,
          setIndex: 0,
          payload: <String, dynamic>{'value': 'paused'},
        ),
        const Wes2PendingChange(
          seq: 3,
          kind: Wes2MutationKind.exerciseNote,
          exerciseId: kExId,
          payload: <String, dynamic>{'value': 'shoulder ok'},
        ),
      ]);
      expect(out.single.isMarkedDone, isTrue);
      expect(out.single.sets.first.executionNote, 'paused');
      expect(out.single.exerciseExecutionNote, 'shoulder ok');
    });

    test('a pending Done does NOT touch any execution value', () {
      final List<Wes2ExerciseRow> out = overlay(<Wes2PendingChange>[
        const Wes2PendingChange(
          seq: 1,
          kind: Wes2MutationKind.markDone,
          exerciseId: kExId,
          payload: <String, dynamic>{'isDone': true},
        ),
      ]);
      final Wes2SetState s = out.single.sets.first;
      expect(s.weight.actualValue, 125);
      expect(s.reps.actualValue, 5);
      expect(s.rir.actualValue, 2.0);
    });

    test('a pending cleared note blanks a note the server still holds', () {
      final List<Wes2ExerciseRow> base = <Wes2ExerciseRow>[
        Wes2ExerciseRow(
          exerciseId: kExId,
          name: 'Bench Press, Barbell',
          circuitIndex: 0,
          orderIndex: 0,
          setCount: 1,
          source: Wes2RowSource.completedServer,
          exerciseExecutionNote: 'old exercise note',
          sets: <Wes2SetState>[
            Wes2SetState(
              setIndex: 0,
              weight: _d(actual: 130),
              reps: _i(actual: 5),
              executionNote: 'old set note',
            ),
          ],
        ),
      ];
      final List<Wes2ExerciseRow> out =
          wes2ApplyPendingOverlay(base, <Wes2PendingChange>[
        const Wes2PendingChange(
          seq: 1,
          kind: Wes2MutationKind.setNote,
          exerciseId: kExId,
          setIndex: 0,
          payload: <String, dynamic>{'value': null},
        ),
        const Wes2PendingChange(
          seq: 2,
          kind: Wes2MutationKind.exerciseNote,
          exerciseId: kExId,
          payload: <String, dynamic>{'value': null},
        ),
      ]);
      expect(out.single.sets.first.executionNote, isNull);
      expect(out.single.exerciseExecutionNote, isNull);
    });

    test('a pending setCount reveals the added set before it has synced', () {
      final List<Wes2ExerciseRow> out = overlay(<Wes2PendingChange>[
        const Wes2PendingChange(
          seq: 1,
          kind: Wes2MutationKind.setCount,
          exerciseId: kExId,
          payload: <String, dynamic>{'setCount': 3},
        ),
      ]);
      expect(out.single.setCount, 3);
      expect(out.single.sets, hasLength(3));
    });

    test('pending work for an exercise not on screen is ignored safely', () {
      final List<Wes2ExerciseRow> out = overlay(<Wes2PendingChange>[
        const Wes2PendingChange(
          seq: 1,
          kind: Wes2MutationKind.field,
          exerciseId: 'squat_barbell',
          setIndex: 0,
          payload: <String, dynamic>{'fieldKey': 'weight', 'value': 200},
        ),
      ]);
      expect(out.single.sets.first.weight.actualValue, 125);
    });
  });

  // ── Surgical replay against a real document ──────────────────────────────

  group('a replayed mutation preserves everything it does not name', () {
    test('neighbouring exercises, sets, notes and setId all survive', () async {
      await _dayRef(db).set(<String, dynamic>{
        'userId': kActor,
        'date': kDocId,
        'exercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': kExId,
            'name': 'Bench Press, Barbell',
            'circuitIndex': 0,
            'orderIndex': 0,
            'setCount': 2,
            'isMarkedDone': false,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{
                'setIndex': 0,
                'setId': 'proof-1',
                'weight': 130,
                'reps': 5,
                'executionNote': 'paused',
              },
              <String, dynamic>{'setIndex': 1, 'weight': 130, 'reps': 4},
            ],
            'exerciseExecutionNote': 'felt strong',
          },
          <String, dynamic>{
            'exerciseId': 'squat_barbell',
            'name': 'Squat, Barbell',
            'circuitIndex': 0,
            'orderIndex': 1,
            'setCount': 1,
            'isMarkedDone': true,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{'setIndex': 0, 'weight': 180, 'reps': 3},
            ],
          },
        ],
        'wesPlannedExercises': <Map<String, dynamic>>[],
      });

      await enterField(_row(<Wes2SetState>[_set(0), _set(1)]), 1,
          Wes2FieldKey.rir, 1.0);
      await engine.process();

      final List<Map<String, dynamic>> sets = await _storedSets(db);
      expect(sets[0], <String, dynamic>{
        'setIndex': 0,
        'setId': 'proof-1',
        'weight': 130,
        'reps': 5,
        'executionNote': 'paused',
      });
      expect(sets[1]['rir'], 1.0);
      expect(sets[1]['weight'], 130);
      expect((await _storedRow(db))['exerciseExecutionNote'], 'felt strong');

      final snap = await _dayRef(db).get();
      final neighbour = (snap.data()!['exercises'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((Map<String, dynamic> r) =>
              r['exerciseId'] == 'squat_barbell');
      expect(neighbour['isMarkedDone'], isTrue);
      expect((neighbour['sets'] as List<dynamic>).single,
          <String, dynamic>{'setIndex': 0, 'weight': 180, 'reps': 3});
    });

    test('an explicit clear removes the key from the stored document',
        () async {
      await _dayRef(db).set(<String, dynamic>{
        'userId': kActor,
        'date': kDocId,
        'exercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': kExId,
            'name': 'Bench Press, Barbell',
            'circuitIndex': 0,
            'orderIndex': 0,
            'setCount': 1,
            'isMarkedDone': false,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{
                'setIndex': 0,
                'weight': 130,
                'reps': 5,
                'rir': 2,
              },
            ],
          },
        ],
        'wesPlannedExercises': <Map<String, dynamic>>[],
      });

      await enterField(_row(<Wes2SetState>[_set(0)]), 0, Wes2FieldKey.rir, null);
      await engine.process();

      final List<Map<String, dynamic>> sets = await _storedSets(db);
      expect(sets.single.containsKey('rir'), isFalse,
          reason: 'the athlete deleted it; the old value must not survive');
      expect(sets.single['weight'], 130);
      expect(sets.single['reps'], 5);
    });

    test('a replayed removal cannot delete the set that took its place',
        () async {
      await _dayRef(db).set(<String, dynamic>{
        'userId': kActor,
        'date': kDocId,
        'exercises': <Map<String, dynamic>>[
          <String, dynamic>{
            'exerciseId': kExId,
            'name': 'Bench Press, Barbell',
            'circuitIndex': 0,
            'orderIndex': 0,
            'setCount': 3,
            'isMarkedDone': false,
            'sets': <Map<String, dynamic>>[
              <String, dynamic>{'setIndex': 0, 'weight': 100, 'reps': 5},
              <String, dynamic>{'setIndex': 1, 'weight': 110, 'reps': 5},
              <String, dynamic>{'setIndex': 2, 'weight': 120, 'reps': 5},
            ],
          },
        ],
        'wesPlannedExercises': <Map<String, dynamic>>[],
      });

      final Wes2Mutation removal = Wes2Mutation.removeSet(
        actorUid: kActor,
        athleteUid: kActor,
        date: kDate,
        exerciseId: kExId,
        setIndex: 1,
        expectedSetCountBefore: 3,
        localSeq: 1,
      );
      await engine.submit(removal);
      await engine.process();

      expect((await _storedSets(db)).map((Map<String, dynamic> s) => s['weight']),
          <int>[100, 120]);

      // Crash window B: the same removal is applied a second time.
      await engine.submit(removal);
      await engine.process();

      expect(
        (await _storedSets(db)).map((Map<String, dynamic> s) => s['weight']),
        <int>[100, 120],
        reason: 'the guard makes a replay a no-op instead of a second deletion',
      );
      expect((await _storedRow(db))['setCount'], 2);
    });

    test('a replayed Add Set does not duplicate the set or the count',
        () async {
      final Wes2ExerciseRow row = _row(<Wes2SetState>[_set(0), _set(1)]);
      await enterField(row, 0, Wes2FieldKey.weight, 130.0);
      await engine.process();

      final Wes2Mutation add = Wes2Mutation.setCount(
        actorUid: kActor,
        athleteUid: kActor,
        date: kDate,
        row: row,
        setCount: 2,
      );
      await engine.submit(add);
      await engine.process();
      await engine.submit(add);
      await engine.process();

      expect((await _storedRow(db))['setCount'], 2);
      expect((await _storedSets(db)).length, lessThanOrEqualTo(2));
    });
  });

  // ── TEST 28 — membership qualification signal ────────────────────────────

  test('TEST 28 — a confirmed weight/reps write announces itself exactly once',
      () async {
    // The screen hangs the membership qualifying-day check and the PB
    // reconciliation off this signal. It must fire when the write LANDS —
    // possibly long after the athlete typed it — and never for a write that
    // failed.
    final List<String> confirmations = <String>[];
    final Wes2SyncEngine e = Wes2SyncEngine(
      outbox: outbox,
      repository: FirestoreWes2Repository(firestore: db),
      currentActorUid: () => kActor,
      autoStartTimer: false,
      autoProcessOnSubmit: false,
      baseBackoff: Duration.zero,
      onConfirmed: (Wes2MutationRow r) {
        final Map<String, dynamic> p = Wes2Mutation.decodePayload(r.payloadJson);
        final Wes2FieldKey? k = Wes2Mutation.fieldKeyFrom(p);
        if (r.kind != Wes2MutationKind.field) return;
        if (p['value'] == null) return;
        if (k != Wes2FieldKey.weight && k != Wes2FieldKey.reps) return;
        confirmations.add('${r.dateKey}/${k!.name}');
      },
    );
    addTearDown(e.dispose);

    final Wes2ExerciseRow row = _row(<Wes2SetState>[_set(0, weight: 130, reps: 5)]);
    await e.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kActor,
      date: kDate,
      row: row,
      setIndex: 0,
      fieldKey: Wes2FieldKey.weight,
      value: 130.0,
    ));
    await e.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kActor,
      date: kDate,
      row: row,
      setIndex: 0,
      fieldKey: Wes2FieldKey.reps,
      value: 5,
    ));
    // RIR is not a qualifying field and must not trigger the check.
    await e.submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kActor,
      date: kDate,
      row: row,
      setIndex: 0,
      fieldKey: Wes2FieldKey.rir,
      value: 2.0,
    ));
    // Nor does Done.
    await e.submit(Wes2Mutation.markDone(
      actorUid: kActor,
      athleteUid: kActor,
      date: kDate,
      row: row,
      isDone: true,
    ));

    await e.process();
    expect(confirmations, <String>['$kDocId/weight', '$kDocId/reps']);
    expect(await outbox.countFor(kActor), 0);
  });
}
