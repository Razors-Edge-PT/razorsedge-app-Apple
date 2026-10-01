// Aurelian bridge smoke-test harness — DEBUG/EMULATOR USE ONLY.
//
// An alternative Dart entrypoint for GoodLift's real Android shell: the real
// MainActivity, the real native AurelianBridge (caller proof, signing
// certificate, request parsing, queue, one-shot reply), the real Dart channel
// binding and the real AurelianActionService — but with in-memory FAKE ports
// (test/aurelian_actions/fakes.dart) instead of Firebase, UserContext and WES2.
// No Firebase is initialised and no user data exists, so Aurelian's
// instrumented GoodLiftBridgeHarnessSmokeTest can exercise execute_action end
// to end without touching production.
//
// It is never part of a normal build (those use lib/main.dart). Build and
// install it only on an emulator, and reinstall the normal debug build after:
//
//   flutter build apk --debug -t tool/aurelian_bridge_harness/main.dart
//   adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
//
// Fake data: "Harness Bench" (3 empty sets), "Harness Squat" (set 1 logged:
// 100 kg x 5, so deleting it needs confirmation) and "Harness Ghost" (writes
// are silently dropped, so read-back verification must fail).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localtest222/WES2_models.dart' show Wes2FieldKey;
import 'package:localtest222/aurelian/actions/action_ports.dart';
import 'package:localtest222/aurelian/actions/action_service.dart';
import 'package:localtest222/aurelian/aurelian_bus.dart';
import 'package:localtest222/aurelian/aurelian_command.dart';

import '../../test/aurelian_actions/fakes.dart';

/// Drops every set write to "Harness Ghost" so read-back verification fails.
class _HarnessWorkout extends FakeWorkout {
  _HarnessWorkout(List<FakeExercise> rows) : super(rows: rows);

  @override
  Future<void> setFields(
      String exerciseId, int setIndex, List<FieldEdit> edits) async {
    if (exerciseId == 'harness_ghost') {
      calls.add('setFields(dropped):$exerciseId');
      return;
    }
    return super.setFields(exerciseId, setIndex, edits);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final FakeExercise squat = FakeExercise('harness_squat', 'Harness Squat')
    ..values[0] = <Wes2FieldKey, Object>{
      Wes2FieldKey.weight: 100.0,
      Wes2FieldKey.reps: 5
    };
  final _HarnessWorkout workout = _HarnessWorkout(<FakeExercise>[
    FakeExercise('harness_bench', 'Harness Bench'),
    squat,
    FakeExercise('harness_ghost', 'Harness Ghost'),
  ])
    ..catalogueList = const <CatalogueEntry>[
      CatalogueEntry(id: 'harness_row', name: 'Harness Row'),
    ];
  AurelianActionService.instance
    ..athletePort = FakeAthletes()
    ..registerWorkout(workout);
  AurelianBridgeChannel.attach();
  runApp(const _HarnessApp());
}

class _HarnessApp extends StatefulWidget {
  const _HarnessApp();

  @override
  State<_HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<_HarnessApp> {
  @override
  void initState() {
    super.initState();
    // A root scope makes the native bridge "ready" (as AurelianBridgeScope does
    // inside the membership gate in the real app). It handles no v1 commands.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AurelianCommandBus.instance
          .register(AurelianScopeKind.root, (AurelianCommand c) async => null);
    });
  }

  @override
  Widget build(BuildContext context) => const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'AURELIAN BRIDGE TEST HARNESS\n'
                'Fake in-memory data · no Firebase · debug only',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
}
