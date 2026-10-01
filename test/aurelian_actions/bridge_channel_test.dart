// Aurelian 2.0 over the real channel binding: an execute_action command
// reaches the action service only once the bridge is ready, and its result
// travels back as bounded JSON beside the transport status.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/aurelian/actions/action_service.dart';
import 'package:localtest222/aurelian/aurelian_bus.dart';
import 'package:localtest222/aurelian/aurelian_command.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('test/aurelian-actions');
  late AurelianCommandBus bus;
  late FakeWorkout workout;

  setUp(() {
    bus = AurelianCommandBus();
    workout = FakeWorkout(
        rows: <FakeExercise>[FakeExercise('bench_bb', 'Bench Press, Barbell')]);
    AurelianActionService.instance
      ..athletePort = FakeAthletes()
      ..registerWorkout(workout);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);
    AurelianBridgeChannel.bindTo(bus, channel);
  });

  tearDown(() {
    AurelianActionService.instance
      ..athletePort = null
      ..unregisterWorkout(workout);
  });

  Future<Map<Object?, Object?>> send(Map<String, Object?> args) async {
    final ByteData? reply = await TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec()
                .encodeMethodCall(MethodCall('command', args)),
            (_) {});
    return const StandardMethodCodec().decodeEnvelope(reply!)
        as Map<Object?, Object?>;
  }

  Map<String, Object?> command(String envelopeJson) => <String, Object?>{
        'protocol': kAurelianProtocolVersion,
        'requestId': 'abc-1',
        'command': 'execute_action',
        'args': <String, Object?>{'envelope': envelopeJson},
      };

  test('refused until a root scope makes the bridge ready', () async {
    final Map<Object?, Object?> r =
        await send(command(envelope('set.add', <String, Object?>{})));
    expect(r['status'], 'unavailable');
    expect(workout.calls, isEmpty);
  });

  test('runs the action and returns its result JSON', () async {
    bus.register(AurelianScopeKind.root, (AurelianCommand c) async => null);
    final Map<Object?, Object?> r = await send(command(envelope('set.update',
        <String, Object?>{'set': 1, 'weight': 150, 'reps': 5, 'rir': 1})));
    expect(r['status'], 'ok');
    final Map<String, dynamic> result =
        jsonDecode(r['result']! as String) as Map<String, dynamic>;
    expect(result['status'], 'success');
    expect(result['summary'],
        'Bench Press, Barbell · Set 1: 150 kg · 5 reps · RIR 1');
    expect(result['verified'], isTrue);
  });

  test(
      'an envelope without its argument, or an oversized one, is refused before the service',
      () async {
    bus.register(AurelianScopeKind.root, (AurelianCommand c) async => null);
    final Map<Object?, Object?> missing = await send(<String, Object?>{
      'protocol': kAurelianProtocolVersion,
      'requestId': 'abc-2',
      'command': 'execute_action',
      'args': <String, Object?>{},
    });
    expect(missing['status'], 'invalid');
    final Map<Object?, Object?> big =
        await send(command('{"x":"${'y' * 5000}"}'));
    expect(big['status'], 'invalid');
    expect(workout.calls, isEmpty);
  });
}
