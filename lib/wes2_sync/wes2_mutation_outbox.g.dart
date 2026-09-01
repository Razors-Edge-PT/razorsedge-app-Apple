// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'wes2_mutation_outbox.dart';

// ignore_for_file: type=lint
class $Wes2MutationsTable extends Wes2Mutations
    with TableInfo<$Wes2MutationsTable, Wes2MutationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $Wes2MutationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
      'seq', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _actorUidMeta =
      const VerificationMeta('actorUid');
  @override
  late final GeneratedColumn<String> actorUid = GeneratedColumn<String>(
      'actor_uid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _athleteUidMeta =
      const VerificationMeta('athleteUid');
  @override
  late final GeneratedColumn<String> athleteUid = GeneratedColumn<String>(
      'athlete_uid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _dateKeyMeta =
      const VerificationMeta('dateKey');
  @override
  late final GeneratedColumn<String> dateKey = GeneratedColumn<String>(
      'date_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _exerciseIdMeta =
      const VerificationMeta('exerciseId');
  @override
  late final GeneratedColumn<String> exerciseId = GeneratedColumn<String>(
      'exercise_id', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _setIndexMeta =
      const VerificationMeta('setIndex');
  @override
  late final GeneratedColumn<int> setIndex = GeneratedColumn<int>(
      'set_index', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _payloadJsonMeta =
      const VerificationMeta('payloadJson');
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
      'payload_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
      'state', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(Wes2MutationState.pending));
  static const VerificationMeta _attemptCountMeta =
      const VerificationMeta('attemptCount');
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
      'attempt_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _nextAttemptAtMsMeta =
      const VerificationMeta('nextAttemptAtMs');
  @override
  late final GeneratedColumn<int> nextAttemptAtMs = GeneratedColumn<int>(
      'next_attempt_at_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastErrorMeta =
      const VerificationMeta('lastError');
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
      'last_error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMsMeta =
      const VerificationMeta('createdAtMs');
  @override
  late final GeneratedColumn<int> createdAtMs = GeneratedColumn<int>(
      'created_at_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMsMeta =
      const VerificationMeta('updatedAtMs');
  @override
  late final GeneratedColumn<int> updatedAtMs = GeneratedColumn<int>(
      'updated_at_ms', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        seq,
        actorUid,
        athleteUid,
        dateKey,
        kind,
        exerciseId,
        setIndex,
        payloadJson,
        state,
        attemptCount,
        nextAttemptAtMs,
        lastError,
        createdAtMs,
        updatedAtMs
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'wes2_mutations';
  @override
  VerificationContext validateIntegrity(Insertable<Wes2MutationRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
          _seqMeta, seq.isAcceptableOrUnknown(data['seq']!, _seqMeta));
    } else if (isInserting) {
      context.missing(_seqMeta);
    }
    if (data.containsKey('actor_uid')) {
      context.handle(_actorUidMeta,
          actorUid.isAcceptableOrUnknown(data['actor_uid']!, _actorUidMeta));
    } else if (isInserting) {
      context.missing(_actorUidMeta);
    }
    if (data.containsKey('athlete_uid')) {
      context.handle(
          _athleteUidMeta,
          athleteUid.isAcceptableOrUnknown(
              data['athlete_uid']!, _athleteUidMeta));
    } else if (isInserting) {
      context.missing(_athleteUidMeta);
    }
    if (data.containsKey('date_key')) {
      context.handle(_dateKeyMeta,
          dateKey.isAcceptableOrUnknown(data['date_key']!, _dateKeyMeta));
    } else if (isInserting) {
      context.missing(_dateKeyMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('exercise_id')) {
      context.handle(
          _exerciseIdMeta,
          exerciseId.isAcceptableOrUnknown(
              data['exercise_id']!, _exerciseIdMeta));
    }
    if (data.containsKey('set_index')) {
      context.handle(_setIndexMeta,
          setIndex.isAcceptableOrUnknown(data['set_index']!, _setIndexMeta));
    }
    if (data.containsKey('payload_json')) {
      context.handle(
          _payloadJsonMeta,
          payloadJson.isAcceptableOrUnknown(
              data['payload_json']!, _payloadJsonMeta));
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
          _stateMeta, state.isAcceptableOrUnknown(data['state']!, _stateMeta));
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
          _attemptCountMeta,
          attemptCount.isAcceptableOrUnknown(
              data['attempt_count']!, _attemptCountMeta));
    }
    if (data.containsKey('next_attempt_at_ms')) {
      context.handle(
          _nextAttemptAtMsMeta,
          nextAttemptAtMs.isAcceptableOrUnknown(
              data['next_attempt_at_ms']!, _nextAttemptAtMsMeta));
    }
    if (data.containsKey('last_error')) {
      context.handle(_lastErrorMeta,
          lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta));
    }
    if (data.containsKey('created_at_ms')) {
      context.handle(
          _createdAtMsMeta,
          createdAtMs.isAcceptableOrUnknown(
              data['created_at_ms']!, _createdAtMsMeta));
    } else if (isInserting) {
      context.missing(_createdAtMsMeta);
    }
    if (data.containsKey('updated_at_ms')) {
      context.handle(
          _updatedAtMsMeta,
          updatedAtMs.isAcceptableOrUnknown(
              data['updated_at_ms']!, _updatedAtMsMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Wes2MutationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Wes2MutationRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      seq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}seq'])!,
      actorUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}actor_uid'])!,
      athleteUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}athlete_uid'])!,
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      exerciseId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}exercise_id'])!,
      setIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}set_index']),
      payloadJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}payload_json'])!,
      state: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}state'])!,
      attemptCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}attempt_count'])!,
      nextAttemptAtMs: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}next_attempt_at_ms'])!,
      lastError: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_error']),
      createdAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at_ms'])!,
      updatedAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at_ms'])!,
    );
  }

  @override
  $Wes2MutationsTable createAlias(String alias) {
    return $Wes2MutationsTable(attachedDatabase, alias);
  }
}

class Wes2MutationRow extends DataClass implements Insertable<Wes2MutationRow> {
  /// Coalescing identity. See the library comment.
  final String id;

  /// Global application order. Assigned at enqueue and re-assigned when a row
  /// is coalesced, so the newest intent for a field is applied last.
  final int seq;

  /// The authenticated account that made the edit. Every claim filters on it,
  /// so a second account signing in on this device never replays the first
  /// account's queued work under its own credentials.
  final String actorUid;

  /// The athlete whose workout document is written. Differs from [actorUid] in
  /// coach mode.
  final String athleteUid;
  final String dateKey;
  final String kind;
  final String exerciseId;
  final int? setIndex;
  final String payloadJson;
  final String state;
  final int attemptCount;

  /// Earliest time a pass may attempt this row again. Backoff after a
  /// transient failure, so a phone with no signal is not asked every second.
  final int nextAttemptAtMs;
  final String? lastError;
  final int createdAtMs;
  final int updatedAtMs;
  const Wes2MutationRow(
      {required this.id,
      required this.seq,
      required this.actorUid,
      required this.athleteUid,
      required this.dateKey,
      required this.kind,
      required this.exerciseId,
      this.setIndex,
      required this.payloadJson,
      required this.state,
      required this.attemptCount,
      required this.nextAttemptAtMs,
      this.lastError,
      required this.createdAtMs,
      required this.updatedAtMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['seq'] = Variable<int>(seq);
    map['actor_uid'] = Variable<String>(actorUid);
    map['athlete_uid'] = Variable<String>(athleteUid);
    map['date_key'] = Variable<String>(dateKey);
    map['kind'] = Variable<String>(kind);
    map['exercise_id'] = Variable<String>(exerciseId);
    if (!nullToAbsent || setIndex != null) {
      map['set_index'] = Variable<int>(setIndex);
    }
    map['payload_json'] = Variable<String>(payloadJson);
    map['state'] = Variable<String>(state);
    map['attempt_count'] = Variable<int>(attemptCount);
    map['next_attempt_at_ms'] = Variable<int>(nextAttemptAtMs);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    map['created_at_ms'] = Variable<int>(createdAtMs);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    return map;
  }

  Wes2MutationsCompanion toCompanion(bool nullToAbsent) {
    return Wes2MutationsCompanion(
      id: Value(id),
      seq: Value(seq),
      actorUid: Value(actorUid),
      athleteUid: Value(athleteUid),
      dateKey: Value(dateKey),
      kind: Value(kind),
      exerciseId: Value(exerciseId),
      setIndex: setIndex == null && nullToAbsent
          ? const Value.absent()
          : Value(setIndex),
      payloadJson: Value(payloadJson),
      state: Value(state),
      attemptCount: Value(attemptCount),
      nextAttemptAtMs: Value(nextAttemptAtMs),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      createdAtMs: Value(createdAtMs),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory Wes2MutationRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Wes2MutationRow(
      id: serializer.fromJson<String>(json['id']),
      seq: serializer.fromJson<int>(json['seq']),
      actorUid: serializer.fromJson<String>(json['actorUid']),
      athleteUid: serializer.fromJson<String>(json['athleteUid']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      kind: serializer.fromJson<String>(json['kind']),
      exerciseId: serializer.fromJson<String>(json['exerciseId']),
      setIndex: serializer.fromJson<int?>(json['setIndex']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      state: serializer.fromJson<String>(json['state']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextAttemptAtMs: serializer.fromJson<int>(json['nextAttemptAtMs']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'seq': serializer.toJson<int>(seq),
      'actorUid': serializer.toJson<String>(actorUid),
      'athleteUid': serializer.toJson<String>(athleteUid),
      'dateKey': serializer.toJson<String>(dateKey),
      'kind': serializer.toJson<String>(kind),
      'exerciseId': serializer.toJson<String>(exerciseId),
      'setIndex': serializer.toJson<int?>(setIndex),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'state': serializer.toJson<String>(state),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextAttemptAtMs': serializer.toJson<int>(nextAttemptAtMs),
      'lastError': serializer.toJson<String?>(lastError),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  Wes2MutationRow copyWith(
          {String? id,
          int? seq,
          String? actorUid,
          String? athleteUid,
          String? dateKey,
          String? kind,
          String? exerciseId,
          Value<int?> setIndex = const Value.absent(),
          String? payloadJson,
          String? state,
          int? attemptCount,
          int? nextAttemptAtMs,
          Value<String?> lastError = const Value.absent(),
          int? createdAtMs,
          int? updatedAtMs}) =>
      Wes2MutationRow(
        id: id ?? this.id,
        seq: seq ?? this.seq,
        actorUid: actorUid ?? this.actorUid,
        athleteUid: athleteUid ?? this.athleteUid,
        dateKey: dateKey ?? this.dateKey,
        kind: kind ?? this.kind,
        exerciseId: exerciseId ?? this.exerciseId,
        setIndex: setIndex.present ? setIndex.value : this.setIndex,
        payloadJson: payloadJson ?? this.payloadJson,
        state: state ?? this.state,
        attemptCount: attemptCount ?? this.attemptCount,
        nextAttemptAtMs: nextAttemptAtMs ?? this.nextAttemptAtMs,
        lastError: lastError.present ? lastError.value : this.lastError,
        createdAtMs: createdAtMs ?? this.createdAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      );
  Wes2MutationRow copyWithCompanion(Wes2MutationsCompanion data) {
    return Wes2MutationRow(
      id: data.id.present ? data.id.value : this.id,
      seq: data.seq.present ? data.seq.value : this.seq,
      actorUid: data.actorUid.present ? data.actorUid.value : this.actorUid,
      athleteUid:
          data.athleteUid.present ? data.athleteUid.value : this.athleteUid,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      kind: data.kind.present ? data.kind.value : this.kind,
      exerciseId:
          data.exerciseId.present ? data.exerciseId.value : this.exerciseId,
      setIndex: data.setIndex.present ? data.setIndex.value : this.setIndex,
      payloadJson:
          data.payloadJson.present ? data.payloadJson.value : this.payloadJson,
      state: data.state.present ? data.state.value : this.state,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      nextAttemptAtMs: data.nextAttemptAtMs.present
          ? data.nextAttemptAtMs.value
          : this.nextAttemptAtMs,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      createdAtMs:
          data.createdAtMs.present ? data.createdAtMs.value : this.createdAtMs,
      updatedAtMs:
          data.updatedAtMs.present ? data.updatedAtMs.value : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Wes2MutationRow(')
          ..write('id: $id, ')
          ..write('seq: $seq, ')
          ..write('actorUid: $actorUid, ')
          ..write('athleteUid: $athleteUid, ')
          ..write('dateKey: $dateKey, ')
          ..write('kind: $kind, ')
          ..write('exerciseId: $exerciseId, ')
          ..write('setIndex: $setIndex, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('state: $state, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAtMs: $nextAttemptAtMs, ')
          ..write('lastError: $lastError, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      seq,
      actorUid,
      athleteUid,
      dateKey,
      kind,
      exerciseId,
      setIndex,
      payloadJson,
      state,
      attemptCount,
      nextAttemptAtMs,
      lastError,
      createdAtMs,
      updatedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Wes2MutationRow &&
          other.id == this.id &&
          other.seq == this.seq &&
          other.actorUid == this.actorUid &&
          other.athleteUid == this.athleteUid &&
          other.dateKey == this.dateKey &&
          other.kind == this.kind &&
          other.exerciseId == this.exerciseId &&
          other.setIndex == this.setIndex &&
          other.payloadJson == this.payloadJson &&
          other.state == this.state &&
          other.attemptCount == this.attemptCount &&
          other.nextAttemptAtMs == this.nextAttemptAtMs &&
          other.lastError == this.lastError &&
          other.createdAtMs == this.createdAtMs &&
          other.updatedAtMs == this.updatedAtMs);
}

class Wes2MutationsCompanion extends UpdateCompanion<Wes2MutationRow> {
  final Value<String> id;
  final Value<int> seq;
  final Value<String> actorUid;
  final Value<String> athleteUid;
  final Value<String> dateKey;
  final Value<String> kind;
  final Value<String> exerciseId;
  final Value<int?> setIndex;
  final Value<String> payloadJson;
  final Value<String> state;
  final Value<int> attemptCount;
  final Value<int> nextAttemptAtMs;
  final Value<String?> lastError;
  final Value<int> createdAtMs;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const Wes2MutationsCompanion({
    this.id = const Value.absent(),
    this.seq = const Value.absent(),
    this.actorUid = const Value.absent(),
    this.athleteUid = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.kind = const Value.absent(),
    this.exerciseId = const Value.absent(),
    this.setIndex = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.state = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAtMs = const Value.absent(),
    this.lastError = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  Wes2MutationsCompanion.insert({
    required String id,
    required int seq,
    required String actorUid,
    required String athleteUid,
    required String dateKey,
    required String kind,
    this.exerciseId = const Value.absent(),
    this.setIndex = const Value.absent(),
    required String payloadJson,
    this.state = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAtMs = const Value.absent(),
    this.lastError = const Value.absent(),
    required int createdAtMs,
    required int updatedAtMs,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        seq = Value(seq),
        actorUid = Value(actorUid),
        athleteUid = Value(athleteUid),
        dateKey = Value(dateKey),
        kind = Value(kind),
        payloadJson = Value(payloadJson),
        createdAtMs = Value(createdAtMs),
        updatedAtMs = Value(updatedAtMs);
  static Insertable<Wes2MutationRow> custom({
    Expression<String>? id,
    Expression<int>? seq,
    Expression<String>? actorUid,
    Expression<String>? athleteUid,
    Expression<String>? dateKey,
    Expression<String>? kind,
    Expression<String>? exerciseId,
    Expression<int>? setIndex,
    Expression<String>? payloadJson,
    Expression<String>? state,
    Expression<int>? attemptCount,
    Expression<int>? nextAttemptAtMs,
    Expression<String>? lastError,
    Expression<int>? createdAtMs,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (seq != null) 'seq': seq,
      if (actorUid != null) 'actor_uid': actorUid,
      if (athleteUid != null) 'athlete_uid': athleteUid,
      if (dateKey != null) 'date_key': dateKey,
      if (kind != null) 'kind': kind,
      if (exerciseId != null) 'exercise_id': exerciseId,
      if (setIndex != null) 'set_index': setIndex,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (state != null) 'state': state,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextAttemptAtMs != null) 'next_attempt_at_ms': nextAttemptAtMs,
      if (lastError != null) 'last_error': lastError,
      if (createdAtMs != null) 'created_at_ms': createdAtMs,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  Wes2MutationsCompanion copyWith(
      {Value<String>? id,
      Value<int>? seq,
      Value<String>? actorUid,
      Value<String>? athleteUid,
      Value<String>? dateKey,
      Value<String>? kind,
      Value<String>? exerciseId,
      Value<int?>? setIndex,
      Value<String>? payloadJson,
      Value<String>? state,
      Value<int>? attemptCount,
      Value<int>? nextAttemptAtMs,
      Value<String?>? lastError,
      Value<int>? createdAtMs,
      Value<int>? updatedAtMs,
      Value<int>? rowid}) {
    return Wes2MutationsCompanion(
      id: id ?? this.id,
      seq: seq ?? this.seq,
      actorUid: actorUid ?? this.actorUid,
      athleteUid: athleteUid ?? this.athleteUid,
      dateKey: dateKey ?? this.dateKey,
      kind: kind ?? this.kind,
      exerciseId: exerciseId ?? this.exerciseId,
      setIndex: setIndex ?? this.setIndex,
      payloadJson: payloadJson ?? this.payloadJson,
      state: state ?? this.state,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAtMs: nextAttemptAtMs ?? this.nextAttemptAtMs,
      lastError: lastError ?? this.lastError,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (actorUid.present) {
      map['actor_uid'] = Variable<String>(actorUid.value);
    }
    if (athleteUid.present) {
      map['athlete_uid'] = Variable<String>(athleteUid.value);
    }
    if (dateKey.present) {
      map['date_key'] = Variable<String>(dateKey.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (exerciseId.present) {
      map['exercise_id'] = Variable<String>(exerciseId.value);
    }
    if (setIndex.present) {
      map['set_index'] = Variable<int>(setIndex.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextAttemptAtMs.present) {
      map['next_attempt_at_ms'] = Variable<int>(nextAttemptAtMs.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (createdAtMs.present) {
      map['created_at_ms'] = Variable<int>(createdAtMs.value);
    }
    if (updatedAtMs.present) {
      map['updated_at_ms'] = Variable<int>(updatedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('Wes2MutationsCompanion(')
          ..write('id: $id, ')
          ..write('seq: $seq, ')
          ..write('actorUid: $actorUid, ')
          ..write('athleteUid: $athleteUid, ')
          ..write('dateKey: $dateKey, ')
          ..write('kind: $kind, ')
          ..write('exerciseId: $exerciseId, ')
          ..write('setIndex: $setIndex, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('state: $state, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAtMs: $nextAttemptAtMs, ')
          ..write('lastError: $lastError, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$Wes2MutationDatabase extends GeneratedDatabase {
  _$Wes2MutationDatabase(QueryExecutor e) : super(e);
  $Wes2MutationDatabaseManager get managers =>
      $Wes2MutationDatabaseManager(this);
  late final $Wes2MutationsTable wes2Mutations = $Wes2MutationsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [wes2Mutations];
}

typedef $$Wes2MutationsTableCreateCompanionBuilder = Wes2MutationsCompanion
    Function({
  required String id,
  required int seq,
  required String actorUid,
  required String athleteUid,
  required String dateKey,
  required String kind,
  Value<String> exerciseId,
  Value<int?> setIndex,
  required String payloadJson,
  Value<String> state,
  Value<int> attemptCount,
  Value<int> nextAttemptAtMs,
  Value<String?> lastError,
  required int createdAtMs,
  required int updatedAtMs,
  Value<int> rowid,
});
typedef $$Wes2MutationsTableUpdateCompanionBuilder = Wes2MutationsCompanion
    Function({
  Value<String> id,
  Value<int> seq,
  Value<String> actorUid,
  Value<String> athleteUid,
  Value<String> dateKey,
  Value<String> kind,
  Value<String> exerciseId,
  Value<int?> setIndex,
  Value<String> payloadJson,
  Value<String> state,
  Value<int> attemptCount,
  Value<int> nextAttemptAtMs,
  Value<String?> lastError,
  Value<int> createdAtMs,
  Value<int> updatedAtMs,
  Value<int> rowid,
});

class $$Wes2MutationsTableFilterComposer
    extends Composer<_$Wes2MutationDatabase, $Wes2MutationsTable> {
  $$Wes2MutationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get seq => $composableBuilder(
      column: $table.seq, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get actorUid => $composableBuilder(
      column: $table.actorUid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get athleteUid => $composableBuilder(
      column: $table.athleteUid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get exerciseId => $composableBuilder(
      column: $table.exerciseId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get setIndex => $composableBuilder(
      column: $table.setIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get nextAttemptAtMs => $composableBuilder(
      column: $table.nextAttemptAtMs,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastError => $composableBuilder(
      column: $table.lastError, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnFilters(column));
}

class $$Wes2MutationsTableOrderingComposer
    extends Composer<_$Wes2MutationDatabase, $Wes2MutationsTable> {
  $$Wes2MutationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get seq => $composableBuilder(
      column: $table.seq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get actorUid => $composableBuilder(
      column: $table.actorUid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get athleteUid => $composableBuilder(
      column: $table.athleteUid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get exerciseId => $composableBuilder(
      column: $table.exerciseId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get setIndex => $composableBuilder(
      column: $table.setIndex, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get nextAttemptAtMs => $composableBuilder(
      column: $table.nextAttemptAtMs,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastError => $composableBuilder(
      column: $table.lastError, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnOrderings(column));
}

class $$Wes2MutationsTableAnnotationComposer
    extends Composer<_$Wes2MutationDatabase, $Wes2MutationsTable> {
  $$Wes2MutationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get actorUid =>
      $composableBuilder(column: $table.actorUid, builder: (column) => column);

  GeneratedColumn<String> get athleteUid => $composableBuilder(
      column: $table.athleteUid, builder: (column) => column);

  GeneratedColumn<String> get dateKey =>
      $composableBuilder(column: $table.dateKey, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get exerciseId => $composableBuilder(
      column: $table.exerciseId, builder: (column) => column);

  GeneratedColumn<int> get setIndex =>
      $composableBuilder(column: $table.setIndex, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
      column: $table.payloadJson, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => column);

  GeneratedColumn<int> get nextAttemptAtMs => $composableBuilder(
      column: $table.nextAttemptAtMs, builder: (column) => column);

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => column);

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => column);
}

class $$Wes2MutationsTableTableManager extends RootTableManager<
    _$Wes2MutationDatabase,
    $Wes2MutationsTable,
    Wes2MutationRow,
    $$Wes2MutationsTableFilterComposer,
    $$Wes2MutationsTableOrderingComposer,
    $$Wes2MutationsTableAnnotationComposer,
    $$Wes2MutationsTableCreateCompanionBuilder,
    $$Wes2MutationsTableUpdateCompanionBuilder,
    (
      Wes2MutationRow,
      BaseReferences<_$Wes2MutationDatabase, $Wes2MutationsTable,
          Wes2MutationRow>
    ),
    Wes2MutationRow,
    PrefetchHooks Function()> {
  $$Wes2MutationsTableTableManager(
      _$Wes2MutationDatabase db, $Wes2MutationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$Wes2MutationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$Wes2MutationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$Wes2MutationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<int> seq = const Value.absent(),
            Value<String> actorUid = const Value.absent(),
            Value<String> athleteUid = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<String> exerciseId = const Value.absent(),
            Value<int?> setIndex = const Value.absent(),
            Value<String> payloadJson = const Value.absent(),
            Value<String> state = const Value.absent(),
            Value<int> attemptCount = const Value.absent(),
            Value<int> nextAttemptAtMs = const Value.absent(),
            Value<String?> lastError = const Value.absent(),
            Value<int> createdAtMs = const Value.absent(),
            Value<int> updatedAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              Wes2MutationsCompanion(
            id: id,
            seq: seq,
            actorUid: actorUid,
            athleteUid: athleteUid,
            dateKey: dateKey,
            kind: kind,
            exerciseId: exerciseId,
            setIndex: setIndex,
            payloadJson: payloadJson,
            state: state,
            attemptCount: attemptCount,
            nextAttemptAtMs: nextAttemptAtMs,
            lastError: lastError,
            createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required int seq,
            required String actorUid,
            required String athleteUid,
            required String dateKey,
            required String kind,
            Value<String> exerciseId = const Value.absent(),
            Value<int?> setIndex = const Value.absent(),
            required String payloadJson,
            Value<String> state = const Value.absent(),
            Value<int> attemptCount = const Value.absent(),
            Value<int> nextAttemptAtMs = const Value.absent(),
            Value<String?> lastError = const Value.absent(),
            required int createdAtMs,
            required int updatedAtMs,
            Value<int> rowid = const Value.absent(),
          }) =>
              Wes2MutationsCompanion.insert(
            id: id,
            seq: seq,
            actorUid: actorUid,
            athleteUid: athleteUid,
            dateKey: dateKey,
            kind: kind,
            exerciseId: exerciseId,
            setIndex: setIndex,
            payloadJson: payloadJson,
            state: state,
            attemptCount: attemptCount,
            nextAttemptAtMs: nextAttemptAtMs,
            lastError: lastError,
            createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$Wes2MutationsTableProcessedTableManager = ProcessedTableManager<
    _$Wes2MutationDatabase,
    $Wes2MutationsTable,
    Wes2MutationRow,
    $$Wes2MutationsTableFilterComposer,
    $$Wes2MutationsTableOrderingComposer,
    $$Wes2MutationsTableAnnotationComposer,
    $$Wes2MutationsTableCreateCompanionBuilder,
    $$Wes2MutationsTableUpdateCompanionBuilder,
    (
      Wes2MutationRow,
      BaseReferences<_$Wes2MutationDatabase, $Wes2MutationsTable,
          Wes2MutationRow>
    ),
    Wes2MutationRow,
    PrefetchHooks Function()>;

class $Wes2MutationDatabaseManager {
  final _$Wes2MutationDatabase _db;
  $Wes2MutationDatabaseManager(this._db);
  $$Wes2MutationsTableTableManager get wes2Mutations =>
      $$Wes2MutationsTableTableManager(_db, _db.wes2Mutations);
}
