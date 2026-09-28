// Fresh device / app update through WES2: a populated pre-update block on the
// server (whose week-1 RIR plans are incomplete by the canonical rule),
// nothing cached locally. Exercises the real WES2 block-settings paths — the
// hint pass (Wes2HintLoadRunner → FirestoreWes2PlanService, with the
// production in-memory defaults projection) and the settings cog
// (Wes2ExerciseSettingsDialog) — and proves:
//   * opening, viewing, cancelling and leaving write nothing;
//   * a failed or incomplete load cannot save;
//   * an explicit Save persists the heal/repair (+ edits) for the selected
//     exercise only, deleting nothing anywhere.
//
// fake_cloud_firestore drops OTHER top-level fields on a
// `SetOptions(mergeFields: [...])` write (real Firestore keeps them — pinned by
// functions/test-emulator/block_settings_guard.spec.js), so after a save this
// file compares the exerciseSettings entries, not the whole document.

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_controller.dart';
import 'package:localtest222/WES2_models.dart';
import 'package:localtest222/WES2_plan_service.dart';
import 'package:localtest222/WES2_widgets/WES2_exercise_settings_dialog.dart';
import 'package:localtest222/block_exercise_defaults_repository.dart';
import 'package:localtest222/exercise_catalog.dart';
import 'package:localtest222/periodization_model_utils.dart';
import 'package:localtest222/settings_merge.dart';
import 'package:localtest222/units/exercise_unit_registry.dart';
import 'package:localtest222/wes2_hint_load_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/pre_update_block_fixture.dart';

String _enc(Object? o) => jsonEncode(o,
    toEncodable: (v) =>
        v is Timestamp ? v.millisecondsSinceEpoch : v.toString());

Map<String, dynamic> _copy(Map<String, dynamic> m) =>
    jsonDecode(_enc(m)) as Map<String, dynamic>;

/// What WES2 shows (and an explicit Save stores) for one stored entry:
/// week-1 RIR heal, then the conservative shadow repair.
Map<String, dynamic> _healedInMemory(Map<String, dynamic> stored) {
  final m = _copy(stored);
  final rir = BlockExerciseDefaultsRepository.healWeek1RirPlan(m);
  if (rir != null) m['rirPlan'] = rir;
  return SettingsMerge.repairShadows(m).$1;
}

/// True when every leaf of [original] is still present, unchanged, in
/// [after] (nothing deleted or overwritten; additions allowed).
bool _containsAllLeaves(Object? original, Object? after) {
  if (original is Map) {
    if (after is! Map) return false;
    for (final e in original.entries) {
      if (!after.containsKey(e.key)) return false;
      if (!_containsAllLeaves(e.value, after[e.key])) return false;
    }
    return true;
  }
  return _enc(original) == _enc(after);
}

/// The real service, except loading settings fails (offline, no cache).
class _FailingLoadPlanService extends FirestoreWes2PlanService {
  _FailingLoadPlanService(FirebaseFirestore db) : super(firestore: db);
  @override
  Future<Map<String, dynamic>> loadExerciseSettings(
          {required String uid, required String blockId}) async =>
      throw StateError('unavailable: offline with no cache');
}

/// The real service, except loading settings comes back empty (incomplete).
class _EmptyLoadPlanService extends FirestoreWes2PlanService {
  _EmptyLoadPlanService(FirebaseFirestore db) : super(firestore: db);
  @override
  Future<Map<String, dynamic>> loadExerciseSettings(
          {required String uid, required String blockId}) async =>
      const <String, dynamic>{};
}

void main() {
  late FakeFirebaseFirestore db;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PeriodizationModelUtils.savedWorkoutsList = <Map<String, dynamic>>[];
    PeriodizationModelUtils.topSetsByExercise.clear();
    db = FakeFirebaseFirestore();
    await seedPreUpdateBlock(db);
    BlockExerciseDefaultsRepository.debugFirestoreOverride = db;
    ExerciseCatalog.debugFirestoreOverride = db;
    ExerciseUnitRegistry.shared = ExerciseUnitRegistry(firestore: db);
  });

  tearDown(() {
    BlockExerciseDefaultsRepository.debugFirestoreOverride = null;
    ExerciseCatalog.debugFirestoreOverride = null;
  });

  Future<String> blockJson() async => _enc(await fxBlock(db));
  Future<Map<String, dynamic>> storedSettings() async =>
      Map<String, dynamic>.from((await fxBlock(db))['exerciseSettings'] as Map);

  Wes2ExerciseRow row(String id, int order) => Wes2ExerciseRow(
        exerciseId: id,
        name: kFxNames[id]!,
        circuitIndex: 0,
        orderIndex: order,
        setCount: 3,
        source: Wes2RowSource.bb3Planned,
        sets: List<Wes2SetState>.generate(
            3, (int i) => Wes2SetState(setIndex: i)),
      );

  ({Wes2SessionController controller, Wes2HintLoadRunner runner}) runnerFor(
      Wes2PlanService plan) {
    final c = Wes2SessionController(DateTime(2026, 9, 28))
      ..initIdentity(
        actorUid: kFxAthlete,
        actingUid: kFxAthlete,
        isCoach: false,
        activeBlockId: kFxActive,
        blockStartDate: kFxStart,
        blockEndDate: kFxEnd,
      );
    final epoch = c.beginLoad();
    c.setRows(
        [for (int i = 0; i < kFxMembers.length; i++) row(kFxMembers[i], i)],
        epoch);
    // Wired exactly as WES2_screen wires it (in-memory defaults projection).
    final runner = Wes2HintLoadRunner(
      controller: c,
      planService: plan,
      projectDefaults: (String id, Map<String, dynamic>? existing) =>
          BlockExerciseDefaultsRepository.projectExerciseDefaults(
              uid: kFxAthlete, exerciseId: id, existing: existing),
      isSettingsUsable: BlockExerciseDefaultsRepository.isSettingsUsable,
    );
    return (controller: c, runner: runner);
  }

  Future<void> openCog(
      WidgetTester tester, Wes2PlanService plan, String exerciseId) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open-cog'),
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => Wes2ExerciseSettingsDialog(
                uid: kFxAthlete,
                blockId: kFxActive,
                exerciseId: exerciseId,
                exerciseName: kFxNames[exerciseId]!,
                weekIndex: 0,
                dayIndex: 0,
                totalBlockWeeks: 12,
                planService: plan,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open-cog')));
    await tester.pumpAndSettle();
  }

  TextField fieldFor(WidgetTester tester, String label) =>
      tester.widget<TextField>(find.ancestor(
          of: find.text(label), matching: find.byType(TextField)));

  test('fixture really is incomplete by the canonical week-1 RIR rule', () {
    final incomplete = [
      for (final id in kFxMembers)
        if (BlockExerciseDefaultsRepository.healWeek1RirPlan(
                _copy(kFxSettings[id]!)) !=
            null)
          id
    ];
    expect(incomplete, isNotEmpty);
  });

  test(
      '1. opening and leaving WES2 (hint pass, fresh cache) writes nothing; '
      'the screen gets the healed settings in memory', () async {
    final before = await blockJson();
    final b = runnerFor(FirestoreWes2PlanService(firestore: db));

    await b.runner.run();

    expect(await blockJson(), before, reason: 'opening WES2 wrote nothing');
    final loaded = b.controller.exerciseSettings;
    expect(loaded.keys.toSet(), kFxMembers.toSet());
    for (final id in kFxMembers) {
      final healedRir = BlockExerciseDefaultsRepository.healWeek1RirPlan(
          _copy(kFxSettings[id]!));
      final expected = _copy(kFxSettings[id]!);
      if (healedRir != null) expected['rirPlan'] = healedRir;
      expect(_enc(loaded[id]), _enc(expected), reason: '$id (in memory)');
    }
    b.runner.dispose();
    expect(await blockJson(), before, reason: 'leaving wrote nothing');
  });

  testWidgets(
      '2. opening and cancelling the settings panel for every exercise '
      'writes nothing', (tester) async {
    final before = await blockJson();
    final plan = FirestoreWes2PlanService(firestore: db);
    for (final id in kFxMembers) {
      await openCog(tester, plan, id);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await blockJson(), before, reason: 'cog for $id wrote');
    }
  });

  testWidgets('3a. a failed settings load cannot save', (tester) async {
    final before = await blockJson();
    final plan = _FailingLoadPlanService(db);

    final b = runnerFor(plan);
    await b.runner.run();
    expect(b.controller.exerciseSettings, isEmpty);

    await openCog(tester, plan, kFxBench);
    expect(find.text('Save'), findsNothing, reason: 'only Close is offered');
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(await blockJson(), before);
  });

  testWidgets(
      '3b. an incomplete (empty) load cannot save — never an empty map, never '
      'defaults over real settings', (tester) async {
    final before = await blockJson();
    final plan = _EmptyLoadPlanService(db);

    final b = runnerFor(plan);
    await b.runner.run();
    expect(await blockJson(), before);

    await openCog(tester, plan, kFxBench);
    expect(find.text('Save'), findsNothing,
        reason: 'the server has usable settings the load did not return');
    expect(find.textContaining('could not be loaded'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(await blockJson(), before);
  });

  testWidgets(
      '4-6. explicit Save persists the heal (+ the edit) for the selected '
      'exercise only; nothing is deleted anywhere', (tester) async {
    final beforeBlock = await fxBlock(db);
    final plan = FirestoreWes2PlanService(firestore: db);

    await openCog(tester, plan, kFxSquat);
    expect(fieldFor(tester, 'Primary Increment').controller!.text, '5');
    await tester.enterText(
        find.ancestor(
            of: find.text('Primary Increment'),
            matching: find.byType(TextField)),
        '2.5');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final after = await storedSettings();
    // 4. The selected exercise: healed/repaired + the explicit edit.
    final expectedSquat = _healedInMemory(kFxSettings[kFxSquat]!);
    (expectedSquat['increments'] as Map)['primary'] = 2.5;
    expect(_enc(after[kFxSquat]), _enc(expectedSquat));
    expect(
        BlockExerciseDefaultsRepository.healWeek1RirPlan(
            Map<String, dynamic>.from(after[kFxSquat] as Map)),
        isNull,
        reason: 'the stored week-1 RIR is now complete');
    // 6. Nothing of the squat's original data was deleted, except the
    //    shadow repair's designed removal of non-week-1 template-scope
    //    `weekN` shadows OF THIS EXERCISE (week 1 is the template).
    final origSquat = _copy(kFxSettings[kFxSquat]!)..remove('increments');
    final removedByRepair = <String>[
      for (final field in ['rirPlan', 'repTargets'])
        for (final wk in ((origSquat[field] as Map?) ?? const {}).keys)
          if (!(((after[kFxSquat] as Map)[field] as Map?) ?? const {})
              .containsKey(wk))
            '$field.$wk'
    ];
    expect(removedByRepair.every((k) => !k.endsWith('.week1')), isTrue,
        reason: 'week 1 is never removed: $removedByRepair');
    for (final k in removedByRepair) {
      final parts = k.split('.');
      (origSquat[parts[0]] as Map).remove(parts[1]);
    }
    expect(_containsAllLeaves(origSquat, after[kFxSquat]), isTrue,
        reason: 'every other original leaf is preserved');
    expect(((after[kFxSquat] as Map)['increments'] as Map).keys, ['primary']);
    // 5. Every other exercise byte-identical (incl. unknown nested fields).
    for (final id in kFxMembers.where((id) => id != kFxSquat)) {
      expect(_enc(after[id]), _enc(kFxSettings[id]), reason: id);
    }
    expect(after.keys.toSet(), kFxMembers.toSet());
    // Block fields: see the file header — the fake drops them on a
    // mergeFields write; real Firestore keeps them (emulator spec).
    expect(beforeBlock['name'], isNotNull);
  });

  testWidgets(
      '4b. Save with no field change persists only that exercise\'s heal; '
      'a no-op Save on complete settings writes nothing', (tester) async {
    final plan = FirestoreWes2PlanService(firestore: db);

    await openCog(tester, plan, kFxBench);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final after = await storedSettings();
    expect(
        _enc(after[kFxBench]), _enc(_healedInMemory(kFxSettings[kFxBench]!)));
    for (final id in kFxMembers.where((id) => id != kFxBench)) {
      expect(_enc(after[id]), _enc(kFxSettings[id]), reason: id);
    }

    // Now complete: opening + Save again changes nothing.
    final settled = _enc(await storedSettings());
    await openCog(tester, plan, kFxBench);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_enc(await storedSettings()), settled);
  });
}
