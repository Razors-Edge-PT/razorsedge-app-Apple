/// Version 1 of the Aurelian → GoodLift action envelope (Aurelian 2.0).
///
/// Aurelian's planner turns speech into a short, ordered list of actions from a
/// CLOSED catalogue ([AurelianAction]); each one reaches GoodLift as one
/// envelope over the authenticated bridge (`execute_action`, see
/// docs/aurelian_bridge.md). This file is the strict gate: an envelope that
/// is not exactly one of these shapes is refused before anything runs.
///
/// There is no free-form payload: no user id (GoodLift always acts for its own
/// signed-in account), no document path, no field name, no code. Names are
/// spoken text that GoodLift resolves itself against what the account may see.
/// The catalogue is mirrored by Aurelian's `orchestration/ToolCatalog.kt` and
/// the Worker's `schema/aurelian-tools.v1.json`; docs/aurelian_capabilities.md
/// is the human contract.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

const int kAurelianActionSchemaVersion = 1;

/// Largest envelope accepted (UTF-16 code units of the JSON text).
const int kAurelianMaxEnvelope = 4096;
const int kActionMaxName = 80;
const int kActionMaxText = 500;
const int kActionMaxChoices = 8;
const int kActionMaxSet = 99;
const int kActionMaxCircuit = 20;

final RegExp _requestIdPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');
final RegExp _idempotencyPattern = RegExp(r'^[A-Za-z0-9-]{8,64}$');
final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9]{16,64}$');
final RegExp _isoDatePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// How an action is treated (docs/aurelian_capabilities.md, "Risk classes").
enum ActionRisk {
  readOnly,
  navigation,

  /// Adds or updates ordinary workout values: no confirmation.
  personalMutation,

  /// May remove or overwrite logged data: confirmation when data exists.
  destructive,

  /// Changes who the session acts for: coach authorisation required.
  coachMutation,
}

enum _ArgType {
  name,
  text,
  setNumber,
  circuit,
  weight,
  reps,
  rir,
  velocity,
  unit,
  isoDate,
  boolean,
  token,
  choices
}

class _Arg {
  const _Arg(this.type, {this.required = false});
  final _ArgType type;
  final bool required;
}

const _Arg _exerciseOpt = _Arg(_ArgType.name);
const _Arg _exerciseReq = _Arg(_ArgType.name, required: true);
const _Arg _setReq = _Arg(_ArgType.setNumber, required: true);
const _Arg _choices = _Arg(_ArgType.choices);

/// The closed catalogue. [wire] is the name on the wire and in the planner's
/// tool definitions.
enum AurelianAction {
  athleteSwitch('athlete.switch', ActionRisk.coachMutation, <String, _Arg>{
    'query': _Arg(_ArgType.name, required: true),
    'choices': _choices,
  }),
  athleteCurrent('athlete.current', ActionRisk.readOnly, <String, _Arg>{}),
  workoutOpen('workout.open', ActionRisk.navigation, <String, _Arg>{
    'date': _Arg(_ArgType.isoDate),
  }),
  workoutRead('workout.read', ActionRisk.readOnly, <String, _Arg>{}),
  templateLoad('template.load', ActionRisk.destructive, <String, _Arg>{
    'template': _Arg(_ArgType.name),
    'choices': _choices,
  }),
  exerciseAdd('exercise.add', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseReq,
    'circuit': _Arg(_ArgType.circuit),
    'choices': _choices,
  }),
  exerciseDelete('exercise.delete', ActionRisk.destructive, <String, _Arg>{
    'exercise': _exerciseReq,
    'choices': _choices,
  }),
  exerciseReplace('exercise.replace', ActionRisk.destructive, <String, _Arg>{
    'exercise': _exerciseReq,
    'replacement': _Arg(_ArgType.name, required: true),
    'choices': _choices,
  }),
  exerciseMove('exercise.move', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseReq,
    'circuit': _Arg(_ArgType.circuit, required: true),
    'choices': _choices,
  }),
  exerciseNote('exercise.note', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'text': _Arg(_ArgType.text, required: true),
    'choices': _choices,
  }),
  exerciseComplete(
      'exercise.complete', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'completed': _Arg(_ArgType.boolean, required: true),
    'choices': _choices,
  }),
  circuitAdd('circuit.add', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseReq,
    'choices': _choices,
  }),
  circuitRename('circuit.rename', ActionRisk.personalMutation, <String, _Arg>{
    'circuit': _Arg(_ArgType.circuit, required: true),
    'name': _Arg(_ArgType.name, required: true),
  }),
  circuitDelete('circuit.delete', ActionRisk.destructive, <String, _Arg>{
    'circuit': _Arg(_ArgType.circuit, required: true),
  }),
  setUpdate('set.update', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'set': _setReq,
    'weight': _Arg(_ArgType.weight),
    'unit': _Arg(_ArgType.unit),
    'reps': _Arg(_ArgType.reps),
    'rir': _Arg(_ArgType.rir),
    'velocity': _Arg(_ArgType.velocity),
    'choices': _choices,
  }),
  setNote('set.note', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'set': _setReq,
    'text': _Arg(_ArgType.text, required: true),
    'choices': _choices,
  }),
  setAdd('set.add', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'choices': _choices,
  }),
  setDelete('set.delete', ActionRisk.destructive, <String, _Arg>{
    'exercise': _exerciseOpt,
    'set': _setReq,
    'choices': _choices,
  }),
  setClear('set.clear', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'set': _setReq,
    'choices': _choices,
  }),
  setCopy('set.copy', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'set': _setReq,
    'toSet': _Arg(_ArgType.setNumber),
    'choices': _choices,
  }),
  exerciseTimerStart(
      'timer.exercise.start', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'set': _setReq,
    'choices': _choices,
  }),
  exerciseTimerStop(
      'timer.exercise.stop', ActionRisk.personalMutation, <String, _Arg>{
    'exercise': _exerciseOpt,
    'choices': _choices,
  }),
  generalTimerStart(
      'timer.general.start', ActionRisk.navigation, <String, _Arg>{}),
  generalTimerStop(
      'timer.general.stop', ActionRisk.navigation, <String, _Arg>{}),
  undo('undo', ActionRisk.personalMutation, <String, _Arg>{
    'undoToken': _Arg(_ArgType.token, required: true),
  });

  const AurelianAction(this.wire, this.risk, this._args);
  final String wire;
  final ActionRisk risk;
  final Map<String, _Arg> _args;

  Set<String> get argumentNames => _args.keys.toSet();

  static AurelianAction? fromWire(Object? wire) {
    for (final AurelianAction a in values) {
      if (a.wire == wire) return a;
    }
    return null;
  }

  /// Actions that act on the WES2 workout (WES2 is brought up first).
  bool get needsWorkout => !const <AurelianAction>{
        AurelianAction.athleteSwitch,
        AurelianAction.athleteCurrent,
        AurelianAction.undo,
      }.contains(this);

  /// Changes something, so it is journaled for "undo that" and deduplicated.
  bool get isMutation =>
      risk != ActionRisk.readOnly && this != AurelianAction.workoutOpen;
}

/// A validated action payload. Only the fields its action allows are set.
@immutable
class ActionPayload {
  const ActionPayload._(this._values);

  final Map<String, Object> _values;

  String? string(String key) => _values[key] as String?;
  int? integer(String key) => _values[key] as int?;
  double? number(String key) => _values[key] as double?;
  bool? boolean(String key) => _values[key] as bool?;
  List<String> get choices =>
      (_values['choices'] as List<String>?) ?? const <String>[];

  bool has(String key) => _values.containsKey(key);

  /// Canonical JSON (sorted keys): the fingerprint for idempotency and
  /// confirmation tokens.
  String canonical() {
    final List<String> keys = _values.keys.toList()..sort();
    return jsonEncode(
        <String, Object>{for (final String k in keys) k: _values[k]!});
  }

  Map<String, Object> toMap() => Map<String, Object>.unmodifiable(_values);
}

@immutable
class AurelianActionEnvelope {
  const AurelianActionEnvelope({
    required this.requestId,
    required this.idempotencyKey,
    required this.action,
    required this.payload,
    this.confirmationToken,
  });

  final String requestId;
  final String idempotencyKey;
  final AurelianAction action;
  final ActionPayload payload;
  final String? confirmationToken;

  /// What identifies "the same request": action and payload, not ids.
  String get fingerprint => '${action.wire}|${payload.canonical()}';
}

/// A refused envelope: [requestId] is known when it was readable.
@immutable
class EnvelopeError {
  const EnvelopeError(this.message, {this.requestId});
  final String message;
  final String? requestId;

  @override
  String toString() => 'EnvelopeError($message)';
}

/// Parses and validates envelope JSON text. Exactly one of the record's fields
/// is non-null.
({AurelianActionEnvelope? envelope, EnvelopeError? error}) parseActionEnvelope(
    String json) {
  ({AurelianActionEnvelope? envelope, EnvelopeError? error}) fail(String m,
          [String? id]) =>
      (envelope: null, error: EnvelopeError(m, requestId: id));

  if (json.length > kAurelianMaxEnvelope) return fail('Envelope too large');
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return fail('Envelope is not JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    return fail('Envelope must be an object');
  }
  const Set<String> topLevel = <String>{
    'schemaVersion', 'requestId', 'idempotencyKey', 'action', 'payload',
    'confirmationToken', //
  };
  final Object? rawId = decoded['requestId'];
  final String? requestId =
      rawId is String && _requestIdPattern.hasMatch(rawId) ? rawId : null;
  if (requestId == null) return fail('Missing or malformed requestId');
  if (decoded.keys.any((String k) => !topLevel.contains(k))) {
    return fail('Unexpected envelope field', requestId);
  }
  if (decoded['schemaVersion'] != kAurelianActionSchemaVersion) {
    return fail('Unsupported action schema version', requestId);
  }
  final Object? key = decoded['idempotencyKey'];
  if (key is! String || !_idempotencyPattern.hasMatch(key)) {
    return fail('Missing or malformed idempotencyKey', requestId);
  }
  final AurelianAction? action = AurelianAction.fromWire(decoded['action']);
  if (action == null) return fail('Unknown action', requestId);
  final Object? token = decoded['confirmationToken'];
  if (token != null && (token is! String || !_tokenPattern.hasMatch(token))) {
    return fail('Malformed confirmationToken', requestId);
  }
  final Object? rawPayload = decoded['payload'] ?? const <String, dynamic>{};
  if (rawPayload is! Map<String, dynamic>) {
    return fail('Payload must be an object', requestId);
  }

  final Map<String, Object> values = <String, Object>{};
  for (final MapEntry<String, dynamic> e in rawPayload.entries) {
    if (e.value == null) continue; // an explicit null is an omission
    final _Arg? spec = action._args[e.key];
    if (spec == null) return fail('Unexpected argument "${e.key}"', requestId);
    final Object? v = _validate(spec.type, e.value);
    if (v == null) return fail('Bad argument "${e.key}"', requestId);
    values[e.key] = v;
  }
  for (final MapEntry<String, _Arg> e in action._args.entries) {
    if (e.value.required && !values.containsKey(e.key)) {
      return fail('Missing argument "${e.key}"', requestId);
    }
  }
  final String? shapeError = _crossFieldError(action, values);
  if (shapeError != null) return fail(shapeError, requestId);

  return (
    envelope: AurelianActionEnvelope(
      requestId: requestId,
      idempotencyKey: key,
      action: action,
      payload: ActionPayload._(Map<String, Object>.unmodifiable(values)),
      confirmationToken: token as String?,
    ),
    error: null,
  );
}

Object? _validate(_ArgType type, Object? v) {
  double? finite(Object? x) {
    if (x is int) return x.toDouble();
    if (x is double && x.isFinite) return x;
    return null;
  }

  int? whole(Object? x) {
    if (x is int) return x;
    if (x is double && x.isFinite && x == x.roundToDouble()) return x.toInt();
    return null;
  }

  switch (type) {
    case _ArgType.name:
      if (v is! String) return null;
      final String t = v.trim();
      return t.isEmpty || t.length > kActionMaxName ? null : t;
    case _ArgType.text:
      if (v is! String) return null;
      final String t = v.trim();
      return t.length > kActionMaxText ? null : t;
    case _ArgType.setNumber:
      final int? n = whole(v);
      return n != null && n >= 1 && n <= kActionMaxSet ? n : null;
    case _ArgType.circuit:
      final int? n = whole(v);
      return n != null && n >= 1 && n <= kActionMaxCircuit ? n : null;
    case _ArgType.weight:
      final double? d = finite(v);
      return d != null && d >= 0 && d <= 1000 ? d : null;
    case _ArgType.reps:
      final int? n = whole(v);
      return n != null && n >= 0 && n <= 1000 ? n : null;
    case _ArgType.rir:
      final double? d = finite(v);
      return d != null && d >= 0 && d <= 10 ? d : null;
    case _ArgType.velocity:
      final double? d = finite(v);
      return d != null && d > 0 && d <= 10 ? d : null;
    case _ArgType.unit:
      return v == 'kg' || v == 'lb' ? v : null;
    case _ArgType.isoDate:
      if (v is! String || !_isoDatePattern.hasMatch(v)) return null;
      final DateTime? d = DateTime.tryParse(v);
      // Round-trips only for a real calendar date (no 2026-02-31).
      if (d == null) return null;
      final String back = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      return back == v ? v : null;
    case _ArgType.boolean:
      return v is bool ? v : null;
    case _ArgType.token:
      return v is String && _tokenPattern.hasMatch(v) ? v : null;
    case _ArgType.choices:
      if (v is! List || v.length > kActionMaxChoices) return null;
      final List<String> out = <String>[];
      for (final Object? c in v) {
        if (c is! String) return null;
        final String t = c.trim();
        if (t.isEmpty || t.length > kActionMaxName) return null;
        out.add(t);
      }
      return List<String>.unmodifiable(out);
  }
}

String? _crossFieldError(AurelianAction action, Map<String, Object> v) {
  switch (action) {
    case AurelianAction.setUpdate:
      if (!v.containsKey('weight') &&
          !v.containsKey('reps') &&
          !v.containsKey('rir') &&
          !v.containsKey('velocity')) {
        return 'No set value given';
      }
      if (v.containsKey('unit') && !v.containsKey('weight')) {
        return 'A unit needs a weight';
      }
      return null;
    case AurelianAction.setNote:
    case AurelianAction.exerciseNote:
      return (v['text'] as String).isEmpty ? 'The note is empty' : null;
    default:
      return null;
  }
}

/// yyyy-MM-dd for [d] (local calendar date).
String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
