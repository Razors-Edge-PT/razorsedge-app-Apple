import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_repository.dart';
import 'package:localtest222/WES2_widgets/WES2_exercise_card.dart';
import 'package:localtest222/WES2_widgets/WES2_set_row.dart';
import 'package:localtest222/wes2_done_coordinator.dart';
import 'package:localtest222/wes2_sync/wes2_mutation.dart';
import 'package:localtest222/wes2_sync/wes2_mutation_outbox.dart';
import 'package:localtest222/wes2_sync/wes2_sync_engine.dart';
import 'package:localtest222/workout_model.dart';
import 'package:provider/provider.dart';

/// "Type the last RIR, tap Completed? immediately."
///
/// The durable outbox already proved that a SUBMITTED mutation survives. That
/// is not the bug these pin. The bug is one step earlier: the RIR mutation was
/// never submitted at all, because Done re-keyed the card's ExpansionTile,
/// every [Wes2SetRow] was disposed, and `dispose()` removes the focus listeners
/// before the nodes report the focus loss. Done then landed on a row already in
/// `exercises[]`, which is a surgical `isMarkedDone` patch — so the RIR the
/// athlete typed was simply gone.
///
/// Everything below therefore drives the REAL widgets: a real
/// [Wes2ExerciseCard] over a real [Wes2SessionController], real [TextField]s
/// inside real [Wes2SetRow]s, focused by `enterText` and NEVER manually
/// unfocused, a real "Completed?" tap, the real [Wes2DoneCoordinator] and
/// [Wes2DurableWriteBarrier], the real [Wes2MutationOutbox] on SQLite, the real
/// [Wes2SyncEngine], and the real [FirestoreWes2Repository] over a fake
/// Firestore. A test that called `enterField(...)` then `pressDone(...)` would
/// pass against the broken code; `_control` below proves these do not.
void main() {
  const String kActor = 'actor-1';
  const String kAthlete = 'athlete-1';
  const String kExId = 'bench_press_barbell';
  const String kExName = 'Bench Press, Barbell';
  final DateTime kDate = DateTime(2026, 5, 4);

  // ── Harness ───────────────────────────────────────────────────────────────

  /// Mirrors `Wes2Screen`'s wiring for the two paths under test, and nothing
  /// else. The sequencing itself is NOT reimplemented here — it lives in
  /// [Wes2DoneCoordinator] / [Wes2DurableWriteBarrier], which production
  /// `_onToggleMarkedDone` / `_submitMutation` / `_awaitDurableWrites` delegate
  /// to, so a test that passes here cannot pass while production is broken.
  ///
  /// [sequenced] false reproduces the pre-fix Done path (toggle immediately,
  /// queue immediately) so the control test can show the loss.
  final List<({Wes2FieldKey key, int setIndex, String text})> unfocusCalls =
      <({Wes2FieldKey key, int setIndex, String text})>[];

  late Wes2SessionController controller;
  late Wes2MutationDatabase db;
  late Wes2MutationOutbox outbox;
  late Wes2SyncEngine engine;
  late FakeFirebaseFirestore firestore;
  late FirestoreWes2Repository repository;
  late Wes2DurableWriteBarrier barrier;
  late Wes2DoneCoordinator doneCoordinator;
  late _RecordingRepository recordingRepo;

  /// Every repository call the engine actually made, in order.
  late List<String> appliedOps;

  setUp(() {
    unfocusCalls.clear();
    appliedOps = <String>[];
    controller = Wes2SessionController(kDate);
    controller.initIdentity(
      actorUid: kActor,
      actingUid: kAthlete,
      isCoach: false,
    );
    db = Wes2MutationDatabase.memory();
    outbox = Wes2MutationOutbox(db);
    firestore = FakeFirebaseFirestore();
    repository = FirestoreWes2Repository(firestore: firestore);
    recordingRepo = _RecordingRepository(repository, (String op) {
      appliedOps.add(op);
    });
    engine = Wes2SyncEngine(
      outbox: outbox,
      repository: recordingRepo,
      currentActorUid: () => kActor,
      // Passes are driven explicitly so nothing races an assertion.
      autoStartTimer: false,
      autoProcessOnSubmit: false,
      baseBackoff: Duration.zero,
    );
    barrier = Wes2DurableWriteBarrier();
    doneCoordinator = Wes2DoneCoordinator();
  });

  tearDown(() async {
    controller.dispose();
    await engine.dispose();
    await db.close();
  });

  /// A BB3/preplanned row: weight and reps already entered on set 0 (so the row
  /// is real execution data), an RIR HINT of 2 and no RIR actual.
  Wes2ExerciseRow plannedRow({
    int setCount = 4,
    int entryIndex = 0,
    Wes2RowSource source = Wes2RowSource.bb3Planned,
  }) {
    final List<Wes2SetState> sets = List<Wes2SetState>.generate(
      setCount,
      (int i) => i == entryIndex
          ? Wes2SetState(
              setIndex: i,
              weight: const Wes2FieldState<double>(actualValue: 130),
              reps: const Wes2FieldState<int>(actualValue: 5),
              rir: const Wes2FieldState<double>(
                hintValue: 2,
                hintOrigin: FieldOrigin.bb3Hint,
              ),
            )
          : Wes2SetState(setIndex: i),
    );
    return Wes2ExerciseRow(
      exerciseId: kExId,
      name: kExName,
      circuitIndex: 0,
      orderIndex: 0,
      setCount: setCount,
      sets: sets,
      source: source,
    );
  }

  /// The barrier-tracked local write, exactly as `_submitMutation` does it.
  Future<void> submit(Wes2Mutation m) => barrier.track(() async {
        try {
          await engine.submit(m);
        } catch (_) {
          // Production logs and swallows: the outbox itself failing is not
          // something the athlete can act on.
        }
      }());

  /// Mirrors `Wes2Screen._onFieldUnfocused` → `_saveFieldSilently`.
  void onFieldUnfocused(
    String exerciseId,
    int setIndex,
    Wes2FieldKey fieldKey,
    String rawText,
  ) {
    unfocusCalls.add((key: fieldKey, setIndex: setIndex, text: rawText));
    final String text = rawText.trim();
    final Object? value;
    if (text.isEmpty) {
      value = null;
    } else {
      value = switch (fieldKey) {
        Wes2FieldKey.reps => int.tryParse(text),
        _ => double.tryParse(text),
      };
      if (value == null) return;
    }
    final int rowIdx =
        controller.rows.indexWhere((Wes2ExerciseRow r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    unawaited(submit(Wes2Mutation.fieldPatch(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      row: controller.rows[rowIdx],
      setIndex: setIndex,
      fieldKey: fieldKey,
      value: value,
    )));
  }

  /// Mirrors `Wes2Screen._commitMarkedDone`.
  Future<void> commitMarkedDone(String exerciseId, bool isDone) async {
    controller.toggleMarkedDone(exerciseId, isDone);
    final int rowIdx =
        controller.rows.indexWhere((Wes2ExerciseRow r) => r.exerciseId == exerciseId);
    if (rowIdx == -1) return;
    await submit(Wes2Mutation.markDone(
      actorUid: kActor,
      athleteUid: kAthlete,
      date: kDate,
      row: controller.rows[rowIdx],
      isDone: isDone,
    ));
  }

  /// Mirrors `Wes2Screen._onToggleMarkedDone`. [sequenced] false is the
  /// pre-fix path, kept only so the control test can reproduce the loss.
  void onToggleMarkedDone(String exerciseId, bool isDone,
      {bool sequenced = true}) {
    if (!sequenced) {
      unawaited(commitMarkedDone(exerciseId, isDone));
      return;
    }
    unawaited(doneCoordinator.toggleMarkedDone(
      exerciseId: exerciseId,
      dropFocus: () => FocusManager.instance.primaryFocus?.unfocus(),
      awaitDurableWrites: barrier.settle,
      commitDone: () => commitMarkedDone(exerciseId, isDone),
    ));
  }

  Future<void> pumpCard(WidgetTester tester, {bool sequenced = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ChangeNotifierProvider<Wes2SessionController>.value(
            value: controller,
            child: Consumer<Wes2SessionController>(
              builder: (BuildContext context, Wes2SessionController c, _) {
                return SingleChildScrollView(
                  child: Column(
                    children: c.rows
                        .map((Wes2ExerciseRow row) => Wes2ExerciseCard(
                              row: row,
                              onFieldUnfocused: onFieldUnfocused,
                              onToggleMarkedDone: (bool isDone) =>
                                  onToggleMarkedDone(row.exerciseId, isDone,
                                      sequenced: sequenced),
                              onAddSet: () {},
                              onSettings: () {},
                            ))
                        .toList(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The RIR TextField of one set row, located through the production key.
  Finder rirFieldOf(int setIndex) => find.descendant(
        of: find.byKey(ValueKey<String>('${kExId}_$setIndex')),
        matching: find.byType(TextField),
      ).at(2);

  /// Durable rows in application order, as `kind/setIndex/field=value`.
  Future<List<String>> queuedInOrder() async {
    final List<Wes2MutationRow> rows = await outbox.claimable(actorUid: kActor);
    return rows.map((Wes2MutationRow r) {
      final Map<String, dynamic> p = Wes2Mutation.decodePayload(r.payloadJson);
      if (r.kind == Wes2MutationKind.field) {
        return 'field/${r.setIndex}/${p['fieldKey']}=${p['value']}';
      }
      if (r.kind == Wes2MutationKind.markDone) {
        return 'markDone=${p['isDone']}';
      }
      return r.kind;
    }).toList();
  }

  Future<Map<String, dynamic>> workoutDoc() async {
    final DocumentSnapshot<Map<String, dynamic>> snap = await firestore
        .collection('users')
        .doc(kAthlete)
        .collection('workouts')
        .doc('2026-05-04')
        .get();
    return snap.data() ?? <String, dynamic>{};
  }

  Future<Map<String, dynamic>?> storedSet(int setIndex) async {
    final Map<String, dynamic> data = await workoutDoc();
    final List<Map<String, dynamic>> exercises =
        (data['exercises'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .where((Map<String, dynamic> m) => m['exerciseId'] == kExId)
            .toList();
    if (exercises.isEmpty) return null;
    final List<Map<String, dynamic>> sets =
        (exercises.first['sets'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .where((Map<String, dynamic> m) => m['setIndex'] == setIndex)
            .toList();
    return sets.isEmpty ? null : sets.first;
  }

  Future<bool> storedIsMarkedDone() async {
    final Map<String, dynamic> data = await workoutDoc();
    final List<Map<String, dynamic>> exercises =
        (data['exercises'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .where((Map<String, dynamic> m) => m['exerciseId'] == kExId)
            .toList();
    return exercises.isNotEmpty && exercises.first['isMarkedDone'] == true;
  }

  /// Seeds Firestore the way the athlete's earlier weight/reps entries would
  /// have: through the REAL repository, so the row genuinely exists in
  /// `exercises[]` and Done is a surgical patch — the state the bug needed.
  Future<void> seedWeightAndReps(WidgetTester tester, {int setIndex = 0}) async {
    await tester.runAsync(() async {
      final Wes2ExerciseRow row = controller.rows.first;
      await repository.saveFieldPatch(
        uid: kAthlete,
        date: kDate,
        row: row,
        setIndex: setIndex,
        fieldKey: Wes2FieldKey.weight,
        value: 130.0,
      );
      await repository.saveFieldPatch(
        uid: kAthlete,
        date: kDate,
        row: row,
        setIndex: setIndex,
        fieldKey: Wes2FieldKey.reps,
        value: 5,
      );
    });
  }

  /// Drains the outbox against the fake Firestore.
  Future<void> sync(WidgetTester tester) async {
    await tester.runAsync(() async {
      Wes2SyncPassResult result = await engine.process();
      while (result.applied > 0) {
        result = await engine.process();
      }
    });
  }

  /// Types [text] into the RIR field of [setIndex] and taps "Completed?"
  /// WITHOUT ever unfocusing. This is the production gesture.
  Future<void> typeRirThenDone(
    WidgetTester tester,
    String text, {
    int setIndex = 0,
  }) async {
    await tester.enterText(rirFieldOf(setIndex), text);
    await tester.pump();
    expect(find.text('Completed?'), findsOneWidget,
        reason: 'the pill only appears once weight+reps+RIR are actual');
    await tester.tap(find.text('Completed?'));
    await tester.pumpAndSettle();
  }

  // ── Control ───────────────────────────────────────────────────────────────

  testWidgets(
      'CONTROL — the pre-fix Done path loses the RIR still being typed',
      (WidgetTester tester) async {
    controller.setRows(<Wes2ExerciseRow>[plannedRow()], controller.loadEpoch);
    await pumpCard(tester, sequenced: false);
    await seedWeightAndReps(tester);

    await typeRirThenDone(tester, '0');

    // The focus listener never ran: the row was disposed with the listener
    // still attached, so no RIR mutation was ever created.
    expect(unfocusCalls, isEmpty);
    expect(await queuedInOrder(), <String>['markDone=true']);

    await sync(tester);
    expect((await storedSet(0))!['rir'], isNull,
        reason: 'this is the production defect being fixed');
    expect(await storedIsMarkedDone(), isTrue);
  });

  // ── TEST 1 ────────────────────────────────────────────────────────────────

  testWidgets(
      'TEST 1 — planned set: type RIR 0, immediate Done, RIR queued first',
      (WidgetTester tester) async {
    controller.setRows(<Wes2ExerciseRow>[plannedRow()], controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester);

    await typeRirThenDone(tester, '0');

    // The ordinary focus-loss callback ran, exactly once, for RIR.
    expect(unfocusCalls, hasLength(1));
    expect(unfocusCalls.single.key, Wes2FieldKey.rir);
    expect(unfocusCalls.single.setIndex, 0);
    expect(unfocusCalls.single.text, '0');

    // Durable ORDER: the field mutation, then Done.
    expect(await queuedInOrder(), <String>[
      'field/0/rir=0.0',
      'markDone=true',
    ]);

    await sync(tester);
    expect(appliedOps, <String>['field', 'done']);
    expect((await storedSet(0))!['rir'], 0.0);
    expect(await storedIsMarkedDone(), isTrue);
    expect(controller.rows.single.isMarkedDone, isTrue);
  });

  // ── TEST 2 ────────────────────────────────────────────────────────────────

  testWidgets(
      'TEST 2 — planned set: typing 2, the same number as the hint, persists',
      (WidgetTester tester) async {
    controller.setRows(<Wes2ExerciseRow>[plannedRow()], controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester);

    await typeRirThenDone(tester, '2');

    expect(await queuedInOrder(), <String>[
      'field/0/rir=2.0',
      'markDone=true',
    ]);

    await sync(tester);
    // Explicitly entered data, even when it equals the suggestion.
    expect((await storedSet(0))!['rir'], 2.0);
    expect(await storedIsMarkedDone(), isTrue);
  });

  // ── TEST 3 ────────────────────────────────────────────────────────────────

  testWidgets('TEST 3 — an untouched RIR hint is never materialised by Done',
      (WidgetTester tester) async {
    // Eligibility for the pill needs an RIR actual, so this row reaches Done
    // the only way it can with an untouched hint: RIR entered on ANOTHER set.
    final Wes2ExerciseRow row = plannedRow(setCount: 2).copyWith(
      sets: <Wes2SetState>[
        Wes2SetState(
          setIndex: 0,
          weight: const Wes2FieldState<double>(actualValue: 130),
          reps: const Wes2FieldState<int>(actualValue: 5),
          rir: const Wes2FieldState<double>(actualValue: 1),
        ),
        const Wes2SetState(
          setIndex: 1,
          weight: Wes2FieldState<double>(actualValue: 130),
          reps: Wes2FieldState<int>(actualValue: 5),
          // Hint only. Never touched.
          rir: Wes2FieldState<double>(
            hintValue: 2,
            hintOrigin: FieldOrigin.bb3Hint,
          ),
        ),
      ],
    );
    controller.setRows(<Wes2ExerciseRow>[row], controller.loadEpoch);
    await pumpCard(tester);
    await tester.runAsync(() async {
      for (int i = 0; i < 2; i++) {
        await repository.saveFieldPatch(
          uid: kAthlete,
          date: kDate,
          row: controller.rows.first,
          setIndex: i,
          fieldKey: Wes2FieldKey.weight,
          value: 130.0,
        );
        await repository.saveFieldPatch(
          uid: kAthlete,
          date: kDate,
          row: controller.rows.first,
          setIndex: i,
          fieldKey: Wes2FieldKey.reps,
          value: 5,
        );
      }
    });

    // Set 1 shows a suggestion and holds no actual…
    expect(controller.rows.single.sets[1].rir.hintValue, 2);
    expect(controller.rows.single.sets[1].rir.actualValue, isNull);
    // …and Done is pressed with nothing focused.
    await tester.tap(find.text('Completed?'));
    await tester.pumpAndSettle();

    expect(unfocusCalls, isEmpty);
    expect(await queuedInOrder(), <String>['markDone=true']);

    await sync(tester);
    expect((await storedSet(1))!.containsKey('rir'), isFalse,
        reason: 'a suggestion the athlete never accepted is not execution data');
    expect(await storedIsMarkedDone(), isTrue);
  });

  // ── TEST 4 ────────────────────────────────────────────────────────────────

  testWidgets('TEST 4 — an athlete-added extra set behaves identically',
      (WidgetTester tester) async {
    // Sets 0-3 planned, set 4 added by the athlete. RIR is typed on set 4.
    final Wes2ExerciseRow row = plannedRow(setCount: 5, entryIndex: 4);
    controller.setRows(<Wes2ExerciseRow>[row], controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester, setIndex: 4);

    await typeRirThenDone(tester, '0', setIndex: 4);

    expect(unfocusCalls, hasLength(1));
    expect(unfocusCalls.single.setIndex, 4);
    expect(await queuedInOrder(), <String>[
      'field/4/rir=0.0',
      'markDone=true',
    ]);

    await sync(tester);
    expect(appliedOps, <String>['field', 'done']);
    expect((await storedSet(4))!['rir'], 0.0);
    expect(await storedIsMarkedDone(), isTrue);
  });

  // ── TEST 5 ────────────────────────────────────────────────────────────────

  testWidgets(
      'TEST 5 — planned and added sets produce the same mutation, bar setIndex',
      (WidgetTester tester) async {
    // Planned set 1.
    controller.setRows(
        <Wes2ExerciseRow>[plannedRow(setCount: 5, entryIndex: 1)],
        controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester, setIndex: 1);
    await typeRirThenDone(tester, '0', setIndex: 1);
    final List<Wes2MutationRow> plannedRows =
        await outbox.claimable(actorUid: kActor);
    final Wes2MutationRow plannedField = plannedRows
        .firstWhere((Wes2MutationRow r) => r.kind == Wes2MutationKind.field);

    // Added set 4, same exercise, same day, same everything else.
    await sync(tester); // drains the queue so the next half is read cleanly
    expect(await queuedInOrder(), isEmpty);
    controller.setRows(
        <Wes2ExerciseRow>[plannedRow(setCount: 5, entryIndex: 4)],
        controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester, setIndex: 4);
    await typeRirThenDone(tester, '0', setIndex: 4);
    final List<Wes2MutationRow> addedRows =
        await outbox.claimable(actorUid: kActor);
    final Wes2MutationRow addedField = addedRows
        .firstWhere((Wes2MutationRow r) => r.kind == Wes2MutationKind.field);

    expect(plannedField.kind, addedField.kind);
    expect(plannedField.exerciseId, addedField.exerciseId);
    expect(plannedField.athleteUid, addedField.athleteUid);
    expect(plannedField.dateKey, addedField.dateKey);
    expect(plannedField.setIndex, 1);
    expect(addedField.setIndex, 4);
    // The identity differs by setIndex alone — no planned/added branch exists.
    expect(plannedField.id.replaceFirst('|1|', '|<i>|'),
        addedField.id.replaceFirst('|4|', '|<i>|'));

    final Map<String, dynamic> plannedPayload =
        Wes2Mutation.decodePayload(plannedField.payloadJson);
    final Map<String, dynamic> addedPayload =
        Wes2Mutation.decodePayload(addedField.payloadJson);
    expect(plannedPayload['fieldKey'], addedPayload['fieldKey']);
    expect(plannedPayload['value'], addedPayload['value']);
  });

  // ── TEST 6 ────────────────────────────────────────────────────────────────

  testWidgets('TEST 6 — Done with nothing focused queues Done and nothing else',
      (WidgetTester tester) async {
    final Wes2ExerciseRow row = plannedRow().copyWith(
      sets: <Wes2SetState>[
        Wes2SetState(
          setIndex: 0,
          weight: const Wes2FieldState<double>(actualValue: 130),
          reps: const Wes2FieldState<int>(actualValue: 5),
          rir: const Wes2FieldState<double>(actualValue: 2),
        ),
        ...List<Wes2SetState>.generate(3, (int i) => Wes2SetState(setIndex: i + 1)),
      ],
    );
    controller.setRows(<Wes2ExerciseRow>[row], controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester);

    expect(tester.testTextInput.isVisible, isFalse,
        reason: 'no field has been focused, so no keyboard is up');
    await tester.tap(find.text('Completed?'));
    await tester.pumpAndSettle();

    expect(unfocusCalls, isEmpty, reason: 'no field was focused to save');
    expect(await queuedInOrder(), <String>['markDone=true']);
    expect(controller.rows.single.isMarkedDone, isTrue);
  });

  // ── TEST 7 ────────────────────────────────────────────────────────────────

  testWidgets('TEST 7 — a rapid double tap on Done neither throws nor reorders',
      (WidgetTester tester) async {
    controller.setRows(<Wes2ExerciseRow>[plannedRow()], controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester);

    await tester.enterText(rirFieldOf(0), '0');
    await tester.pump();
    // Two taps inside the same frame, before any rebuild can remove the button.
    await tester.tap(find.text('Completed?'), warnIfMissed: false);
    await tester.tap(find.text('Completed?'), warnIfMissed: false);
    await tester.pumpAndSettle();

    // The guard absorbed the repeat: one RIR save, one Done, in that order.
    expect(unfocusCalls, hasLength(1));
    expect(await queuedInOrder(), <String>[
      'field/0/rir=0.0',
      'markDone=true',
    ]);
    expect(controller.rows.single.isMarkedDone, isTrue);
    expect(doneCoordinator.isBusy(kExId), isFalse,
        reason: 'the guard is always released');

    await sync(tester);
    expect((await storedSet(0))!['rir'], 0.0);
    expect(await storedIsMarkedDone(), isTrue);
  });

  // ── TEST 8 ────────────────────────────────────────────────────────────────

  testWidgets('TEST 8 — offline: both survive locally, in order, and then land',
      (WidgetTester tester) async {
    controller.setRows(<Wes2ExerciseRow>[plannedRow()], controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester);

    // The network is gone. The local barrier must not care.
    recordingRepo.offline = true;

    await typeRirThenDone(tester, '0');

    expect(await queuedInOrder(), <String>[
      'field/0/rir=0.0',
      'markDone=true',
    ]);
    // Done is on screen immediately: the barrier is local, never the network.
    expect(controller.rows.single.isMarkedDone, isTrue);

    await sync(tester);
    expect(await queuedInOrder(), <String>[
      'field/0/rir=0.0',
      'markDone=true',
    ], reason: 'nothing is dropped while offline');
    expect((await storedSet(0))!.containsKey('rir'), isFalse);

    recordingRepo.offline = false;
    await sync(tester);
    expect(await queuedInOrder(), isEmpty);
    expect((await storedSet(0))!['rir'], 0.0);
    expect(await storedIsMarkedDone(), isTrue);
  });

  // ── TEST 9 ────────────────────────────────────────────────────────────────

  testWidgets('TEST 9 — process death after the local queue still replays both',
      (WidgetTester tester) async {
    controller.setRows(<Wes2ExerciseRow>[plannedRow()], controller.loadEpoch);
    await pumpCard(tester);
    await seedWeightAndReps(tester);

    recordingRepo.offline = true;
    await typeRirThenDone(tester, '0');
    expect(await queuedInOrder(), <String>[
      'field/0/rir=0.0',
      'markDone=true',
    ]);

    // The process dies. The SQLite file (here, the same in-memory database)
    // outlives it; the engine and the screen do not.
    await tester.runAsync(() async {
      await engine.dispose();
      recordingRepo = _RecordingRepository(repository, (String op) {
        appliedOps.add(op);
      });
      engine = Wes2SyncEngine(
        outbox: outbox,
        repository: recordingRepo,
        currentActorUid: () => kActor,
        autoStartTimer: false,
        autoProcessOnSubmit: false,
        baseBackoff: Duration.zero,
      );
    });

    await sync(tester);
    expect(appliedOps, <String>['field', 'done'],
        reason: 'replayed in the order they were queued');
    expect((await storedSet(0))!['rir'], 0.0);
    expect(await storedIsMarkedDone(), isTrue);
  });

  // ── TEST 11 ───────────────────────────────────────────────────────────────
  //
  // (TEST 10 and TEST 12 read the persisted document through the Top Sets
  // model; they live alongside this one because the WRITE half is this same
  // production gesture.)

  testWidgets('TEST 11 — an untouched hint reads back as a null SetDetails.rir',
      (WidgetTester tester) async {
    final Wes2ExerciseRow row = plannedRow(setCount: 1).copyWith(
      sets: <Wes2SetState>[
        const Wes2SetState(
          setIndex: 0,
          weight: Wes2FieldState<double>(actualValue: 130),
          reps: Wes2FieldState<int>(actualValue: 5),
          rir: Wes2FieldState<double>(actualValue: 1),
        ),
      ],
    );
    // Set 0 carries a real RIR so the pill exists; set 1 is the untouched one.
    final Wes2ExerciseRow twoSets = row.copyWith(
      setCount: 2,
      sets: <Wes2SetState>[
        row.sets.first,
        const Wes2SetState(
          setIndex: 1,
          weight: Wes2FieldState<double>(actualValue: 130),
          reps: Wes2FieldState<int>(actualValue: 5),
          rir: Wes2FieldState<double>(
            hintValue: 2,
            hintOrigin: FieldOrigin.bb3Hint,
          ),
        ),
      ],
    );
    controller.setRows(<Wes2ExerciseRow>[twoSets], controller.loadEpoch);
    await pumpCard(tester);
    await tester.runAsync(() async {
      for (int i = 0; i < 2; i++) {
        await repository.saveFieldPatch(
          uid: kAthlete,
          date: kDate,
          row: controller.rows.first,
          setIndex: i,
          fieldKey: Wes2FieldKey.weight,
          value: 130.0,
        );
        await repository.saveFieldPatch(
          uid: kAthlete,
          date: kDate,
          row: controller.rows.first,
          setIndex: i,
          fieldKey: Wes2FieldKey.reps,
          value: 5,
        );
      }
      await repository.saveFieldPatch(
        uid: kAthlete,
        date: kDate,
        row: controller.rows.first,
        setIndex: 0,
        fieldKey: Wes2FieldKey.rir,
        value: 1.0,
      );
    });

    await tester.tap(find.text('Completed?'));
    await tester.pumpAndSettle();
    await sync(tester);

    late Workout workout;
    await tester.runAsync(() async {
      // The document needs the `date` field Workout.fromFirestore reads; the
      // repository writes it as the yyyy-MM-dd document id.
      final DocumentSnapshot<Map<String, dynamic>> snap = await firestore
          .collection('users')
          .doc(kAthlete)
          .collection('workouts')
          .doc('2026-05-04')
          .get();
      workout = Workout.fromFirestore(snap);
    });

    final List<SetDetails> sets = workout.exercises.single.sets;
    expect(sets[0].rir, 1.0);
    expect(sets[1].rir, isNull, reason: 'the hint 2 was never invented');
    expect(await storedIsMarkedDone(), isTrue);
  });
}

/// Wraps the real repository so the engine's calls can be ordered and a total
/// network outage simulated, without reimplementing any repository behaviour.
class _RecordingRepository implements Wes2Repository {
  _RecordingRepository(this._inner, this._record);

  final Wes2Repository _inner;
  final void Function(String op) _record;

  /// When true every call fails the way a phone with no signal does.
  bool offline = false;

  Never _fail() =>
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');

  Future<T> _run<T>(String op, Future<T> Function() body) async {
    if (offline) _fail();
    final T out = await body();
    _record(op);
    return out;
  }

  @override
  Future<List<Wes2ExerciseRow>> loadDay({
    required String uid,
    required DateTime date,
  }) =>
      _run('loadDay', () => _inner.loadDay(uid: uid, date: date));

  @override
  Future<void> saveFieldPatch({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setIndex,
    required Wes2FieldKey fieldKey,
    required dynamic value,
  }) =>
      _run(
        'field',
        () => _inner.saveFieldPatch(
          uid: uid,
          date: date,
          row: row,
          setIndex: setIndex,
          fieldKey: fieldKey,
          value: value,
        ),
      );

  @override
  Future<void> setMarkedDone({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required bool isDone,
  }) =>
      _run(
        'done',
        () => _inner.setMarkedDone(
          uid: uid,
          date: date,
          row: row,
          isDone: isDone,
        ),
      );

  @override
  Future<void> saveSetCount({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
    required int setCount,
  }) =>
      _run(
        'setCount',
        () => _inner.saveSetCount(
          uid: uid,
          date: date,
          row: row,
          setCount: setCount,
        ),
      );

  @override
  Future<void> saveManualExercise({
    required String uid,
    required DateTime date,
    required Wes2ExerciseRow row,
  }) =>
      _run('manualExercise',
          () => _inner.saveManualExercise(uid: uid, date: date, row: row));

  @override
  Future<void> removeSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    int? expectedSetCountBefore,
  }) =>
      _run(
        'removeSet',
        () => _inner.removeSet(
          uid: uid,
          date: date,
          exerciseId: exerciseId,
          setIndex: setIndex,
          expectedSetCountBefore: expectedSetCountBefore,
        ),
      );

  @override
  Future<void> deleteExercise({
    required String uid,
    required DateTime date,
    required String exerciseId,
  }) =>
      _run(
        'deleteExercise',
        () => _inner.deleteExercise(
            uid: uid, date: date, exerciseId: exerciseId),
      );

  @override
  Future<void> replaceExercise({
    required String uid,
    required DateTime date,
    required String oldExerciseId,
    required String newExerciseId,
    required String newName,
  }) =>
      _run(
        'replaceExercise',
        () => _inner.replaceExercise(
          uid: uid,
          date: date,
          oldExerciseId: oldExerciseId,
          newExerciseId: newExerciseId,
          newName: newName,
        ),
      );

  @override
  Future<void> moveExerciseToCircuit({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int targetCircuitIndex,
  }) =>
      _run(
        'moveCircuit',
        () => _inner.moveExerciseToCircuit(
          uid: uid,
          date: date,
          exerciseId: exerciseId,
          targetCircuitIndex: targetCircuitIndex,
        ),
      );

  @override
  Future<void> saveExecutionNote({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String? note,
  }) =>
      _run(
        'setNote',
        () => _inner.saveExecutionNote(
          uid: uid,
          date: date,
          exerciseId: exerciseId,
          setIndex: setIndex,
          note: note,
        ),
      );

  @override
  Future<void> saveExerciseExecutionNote({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String? note,
  }) =>
      _run(
        'exerciseNote',
        () => _inner.saveExerciseExecutionNote(
          uid: uid,
          date: date,
          exerciseId: exerciseId,
          note: note,
        ),
      );

  @override
  Future<void> saveSetId({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required int setIndex,
    required String setId,
  }) =>
      _run(
        'setId',
        () => _inner.saveSetId(
          uid: uid,
          date: date,
          exerciseId: exerciseId,
          setIndex: setIndex,
          setId: setId,
        ),
      );

  @override
  Future<void> replaceAllWithTemplateRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> rows,
  }) =>
      _run(
        'templateReplaceAll',
        () => _inner.replaceAllWithTemplateRows(
            uid: uid, date: date, rows: rows),
      );

  @override
  Future<void> deleteAllExercisesForDay({
    required String uid,
    required DateTime date,
  }) =>
      _run('deleteAllForDay',
          () => _inner.deleteAllExercisesForDay(uid: uid, date: date));

  @override
  Future<void> saveCompletedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> completedRows,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> savePlannedRows({
    required String uid,
    required DateTime date,
    required List<Wes2ExerciseRow> plannedRows,
  }) =>
      throw UnimplementedError();

  @override
  Future<Wes2SavedSetPerformance?> savedPerformanceForSet({
    required String uid,
    required DateTime date,
    required String exerciseId,
    required String setId,
  }) =>
      _inner.savedPerformanceForSet(
        uid: uid,
        date: date,
        exerciseId: exerciseId,
        setId: setId,
      );
}
