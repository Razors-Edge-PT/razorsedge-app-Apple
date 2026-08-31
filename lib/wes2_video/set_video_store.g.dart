// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'set_video_store.dart';

// ignore_for_file: type=lint
class $SetVideosTable extends SetVideos
    with TableInfo<$SetVideosTable, SetVideoRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SetVideosTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _ownerUidMeta =
      const VerificationMeta('ownerUid');
  @override
  late final GeneratedColumn<String> ownerUid = GeneratedColumn<String>(
      'owner_uid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _dateKeyMeta =
      const VerificationMeta('dateKey');
  @override
  late final GeneratedColumn<String> dateKey = GeneratedColumn<String>(
      'date_key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _exerciseIdMeta =
      const VerificationMeta('exerciseId');
  @override
  late final GeneratedColumn<String> exerciseId = GeneratedColumn<String>(
      'exercise_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _setIdMeta = const VerificationMeta('setId');
  @override
  late final GeneratedColumn<String> setId = GeneratedColumn<String>(
      'set_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _setIndexMeta =
      const VerificationMeta('setIndex');
  @override
  late final GeneratedColumn<int> setIndex = GeneratedColumn<int>(
      'set_index', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _localVideoPathMeta =
      const VerificationMeta('localVideoPath');
  @override
  late final GeneratedColumn<String> localVideoPath = GeneratedColumn<String>(
      'local_video_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _localPosterPathMeta =
      const VerificationMeta('localPosterPath');
  @override
  late final GeneratedColumn<String> localPosterPath = GeneratedColumn<String>(
      'local_poster_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _durationMsMeta =
      const VerificationMeta('durationMs');
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
      'duration_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _sizeBytesMeta =
      const VerificationMeta('sizeBytes');
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
      'size_bytes', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
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
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
      'state', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(SetVideoState.local));
  static const VerificationMeta _liftSlotMeta =
      const VerificationMeta('liftSlot');
  @override
  late final GeneratedColumn<String> liftSlot = GeneratedColumn<String>(
      'lift_slot', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _fingerprintMeta =
      const VerificationMeta('fingerprint');
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
      'fingerprint', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _mediaIdMeta =
      const VerificationMeta('mediaId');
  @override
  late final GeneratedColumn<String> mediaId = GeneratedColumn<String>(
      'media_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _postIdMeta = const VerificationMeta('postId');
  @override
  late final GeneratedColumn<String> postId = GeneratedColumn<String>(
      'post_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _suppressedMeta =
      const VerificationMeta('suppressed');
  @override
  late final GeneratedColumn<bool> suppressed = GeneratedColumn<bool>(
      'suppressed', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("suppressed" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _deletedAtMsMeta =
      const VerificationMeta('deletedAtMs');
  @override
  late final GeneratedColumn<int> deletedAtMs = GeneratedColumn<int>(
      'deleted_at_ms', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _supersededVideoPathMeta =
      const VerificationMeta('supersededVideoPath');
  @override
  late final GeneratedColumn<String> supersededVideoPath =
      GeneratedColumn<String>('superseded_video_path', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _supersededPosterPathMeta =
      const VerificationMeta('supersededPosterPath');
  @override
  late final GeneratedColumn<String> supersededPosterPath =
      GeneratedColumn<String>('superseded_poster_path', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _generationMeta =
      const VerificationMeta('generation');
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
      'generation', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        ownerUid,
        dateKey,
        exerciseId,
        setId,
        setIndex,
        localVideoPath,
        localPosterPath,
        durationMs,
        sizeBytes,
        createdAtMs,
        updatedAtMs,
        state,
        liftSlot,
        fingerprint,
        mediaId,
        postId,
        suppressed,
        deletedAtMs,
        supersededVideoPath,
        supersededPosterPath,
        generation
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'set_videos';
  @override
  VerificationContext validateIntegrity(Insertable<SetVideoRecord> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('owner_uid')) {
      context.handle(_ownerUidMeta,
          ownerUid.isAcceptableOrUnknown(data['owner_uid']!, _ownerUidMeta));
    } else if (isInserting) {
      context.missing(_ownerUidMeta);
    }
    if (data.containsKey('date_key')) {
      context.handle(_dateKeyMeta,
          dateKey.isAcceptableOrUnknown(data['date_key']!, _dateKeyMeta));
    } else if (isInserting) {
      context.missing(_dateKeyMeta);
    }
    if (data.containsKey('exercise_id')) {
      context.handle(
          _exerciseIdMeta,
          exerciseId.isAcceptableOrUnknown(
              data['exercise_id']!, _exerciseIdMeta));
    } else if (isInserting) {
      context.missing(_exerciseIdMeta);
    }
    if (data.containsKey('set_id')) {
      context.handle(
          _setIdMeta, setId.isAcceptableOrUnknown(data['set_id']!, _setIdMeta));
    } else if (isInserting) {
      context.missing(_setIdMeta);
    }
    if (data.containsKey('set_index')) {
      context.handle(_setIndexMeta,
          setIndex.isAcceptableOrUnknown(data['set_index']!, _setIndexMeta));
    }
    if (data.containsKey('local_video_path')) {
      context.handle(
          _localVideoPathMeta,
          localVideoPath.isAcceptableOrUnknown(
              data['local_video_path']!, _localVideoPathMeta));
    } else if (isInserting) {
      context.missing(_localVideoPathMeta);
    }
    if (data.containsKey('local_poster_path')) {
      context.handle(
          _localPosterPathMeta,
          localPosterPath.isAcceptableOrUnknown(
              data['local_poster_path']!, _localPosterPathMeta));
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
          _durationMsMeta,
          durationMs.isAcceptableOrUnknown(
              data['duration_ms']!, _durationMsMeta));
    }
    if (data.containsKey('size_bytes')) {
      context.handle(_sizeBytesMeta,
          sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta));
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
    if (data.containsKey('state')) {
      context.handle(
          _stateMeta, state.isAcceptableOrUnknown(data['state']!, _stateMeta));
    }
    if (data.containsKey('lift_slot')) {
      context.handle(_liftSlotMeta,
          liftSlot.isAcceptableOrUnknown(data['lift_slot']!, _liftSlotMeta));
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
          _fingerprintMeta,
          fingerprint.isAcceptableOrUnknown(
              data['fingerprint']!, _fingerprintMeta));
    }
    if (data.containsKey('media_id')) {
      context.handle(_mediaIdMeta,
          mediaId.isAcceptableOrUnknown(data['media_id']!, _mediaIdMeta));
    }
    if (data.containsKey('post_id')) {
      context.handle(_postIdMeta,
          postId.isAcceptableOrUnknown(data['post_id']!, _postIdMeta));
    }
    if (data.containsKey('suppressed')) {
      context.handle(
          _suppressedMeta,
          suppressed.isAcceptableOrUnknown(
              data['suppressed']!, _suppressedMeta));
    }
    if (data.containsKey('deleted_at_ms')) {
      context.handle(
          _deletedAtMsMeta,
          deletedAtMs.isAcceptableOrUnknown(
              data['deleted_at_ms']!, _deletedAtMsMeta));
    }
    if (data.containsKey('superseded_video_path')) {
      context.handle(
          _supersededVideoPathMeta,
          supersededVideoPath.isAcceptableOrUnknown(
              data['superseded_video_path']!, _supersededVideoPathMeta));
    }
    if (data.containsKey('superseded_poster_path')) {
      context.handle(
          _supersededPosterPathMeta,
          supersededPosterPath.isAcceptableOrUnknown(
              data['superseded_poster_path']!, _supersededPosterPathMeta));
    }
    if (data.containsKey('generation')) {
      context.handle(
          _generationMeta,
          generation.isAcceptableOrUnknown(
              data['generation']!, _generationMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SetVideoRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SetVideoRecord(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      ownerUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}owner_uid'])!,
      dateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}date_key'])!,
      exerciseId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}exercise_id'])!,
      setId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}set_id'])!,
      setIndex: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}set_index'])!,
      localVideoPath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_video_path'])!,
      localPosterPath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_poster_path']),
      durationMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}duration_ms'])!,
      sizeBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}size_bytes'])!,
      createdAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at_ms'])!,
      updatedAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at_ms'])!,
      state: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}state'])!,
      liftSlot: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}lift_slot']),
      fingerprint: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}fingerprint']),
      mediaId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}media_id']),
      postId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}post_id']),
      suppressed: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}suppressed'])!,
      deletedAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deleted_at_ms']),
      supersededVideoPath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}superseded_video_path']),
      supersededPosterPath: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}superseded_poster_path']),
      generation: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}generation'])!,
    );
  }

  @override
  $SetVideosTable createAlias(String alias) {
    return $SetVideosTable(attachedDatabase, alias);
  }
}

class SetVideoRecord extends DataClass implements Insertable<SetVideoRecord> {
  /// Deterministic: `ownerUid|dateKey|exerciseId|setId`. Chosen by the client
  /// so re-attaching to the same set is an update, never a duplicate row.
  final String id;

  /// The profile that owns the footage. Every query filters on this, so a
  /// second account signing in on the same device sees none of it.
  final String ownerUid;

  /// `yyyy-MM-dd` of the workout day, matching the WES2 document id.
  final String dateKey;
  final String exerciseId;

  /// Stable set identity. The association key — never the index.
  final String setId;

  /// Advisory display position, refreshed opportunistically. Never used to
  /// find a record.
  final int setIndex;

  /// Durable path inside application support.
  final String localVideoPath;
  final String? localPosterPath;
  final int durationMs;
  final int sizeBytes;
  final int createdAtMs;
  final int updatedAtMs;

  /// [SetVideoState].
  final String state;

  /// Canonical lift slot ([BigFiveSlot]) when the exercise is one of them.
  final String? liftSlot;

  /// The exact record fingerprint this footage was confirmed against.
  final String? fingerprint;

  /// Media id shared with the outbox once queued, so one upload serves the
  /// gallery tile and every proof slot it satisfies.
  final String? mediaId;

  /// The published post holding the media.
  final String? postId;

  /// True once the user has explicitly deleted or detached this footage.
  ///
  /// Reconciliation is idempotent and runs often, so without this flag a
  /// deleted PB video would simply be re-queued on the next pass. Only a new
  /// recording or an explicit replace clears it.
  final bool suppressed;

  /// Set while a soft delete is undoable; the files are only unlinked after it.
  final int? deletedAtMs;

  /// The previous file, kept until the replacement is proven good. Deleting
  /// this is the LAST step of a replacement, never the first.
  final String? supersededVideoPath;
  final String? supersededPosterPath;

  /// Monotonic per record. An older async replacement that finishes late is
  /// rejected rather than allowed to restore a video the user already replaced.
  final int generation;
  const SetVideoRecord(
      {required this.id,
      required this.ownerUid,
      required this.dateKey,
      required this.exerciseId,
      required this.setId,
      required this.setIndex,
      required this.localVideoPath,
      this.localPosterPath,
      required this.durationMs,
      required this.sizeBytes,
      required this.createdAtMs,
      required this.updatedAtMs,
      required this.state,
      this.liftSlot,
      this.fingerprint,
      this.mediaId,
      this.postId,
      required this.suppressed,
      this.deletedAtMs,
      this.supersededVideoPath,
      this.supersededPosterPath,
      required this.generation});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['owner_uid'] = Variable<String>(ownerUid);
    map['date_key'] = Variable<String>(dateKey);
    map['exercise_id'] = Variable<String>(exerciseId);
    map['set_id'] = Variable<String>(setId);
    map['set_index'] = Variable<int>(setIndex);
    map['local_video_path'] = Variable<String>(localVideoPath);
    if (!nullToAbsent || localPosterPath != null) {
      map['local_poster_path'] = Variable<String>(localPosterPath);
    }
    map['duration_ms'] = Variable<int>(durationMs);
    map['size_bytes'] = Variable<int>(sizeBytes);
    map['created_at_ms'] = Variable<int>(createdAtMs);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || liftSlot != null) {
      map['lift_slot'] = Variable<String>(liftSlot);
    }
    if (!nullToAbsent || fingerprint != null) {
      map['fingerprint'] = Variable<String>(fingerprint);
    }
    if (!nullToAbsent || mediaId != null) {
      map['media_id'] = Variable<String>(mediaId);
    }
    if (!nullToAbsent || postId != null) {
      map['post_id'] = Variable<String>(postId);
    }
    map['suppressed'] = Variable<bool>(suppressed);
    if (!nullToAbsent || deletedAtMs != null) {
      map['deleted_at_ms'] = Variable<int>(deletedAtMs);
    }
    if (!nullToAbsent || supersededVideoPath != null) {
      map['superseded_video_path'] = Variable<String>(supersededVideoPath);
    }
    if (!nullToAbsent || supersededPosterPath != null) {
      map['superseded_poster_path'] = Variable<String>(supersededPosterPath);
    }
    map['generation'] = Variable<int>(generation);
    return map;
  }

  SetVideosCompanion toCompanion(bool nullToAbsent) {
    return SetVideosCompanion(
      id: Value(id),
      ownerUid: Value(ownerUid),
      dateKey: Value(dateKey),
      exerciseId: Value(exerciseId),
      setId: Value(setId),
      setIndex: Value(setIndex),
      localVideoPath: Value(localVideoPath),
      localPosterPath: localPosterPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPosterPath),
      durationMs: Value(durationMs),
      sizeBytes: Value(sizeBytes),
      createdAtMs: Value(createdAtMs),
      updatedAtMs: Value(updatedAtMs),
      state: Value(state),
      liftSlot: liftSlot == null && nullToAbsent
          ? const Value.absent()
          : Value(liftSlot),
      fingerprint: fingerprint == null && nullToAbsent
          ? const Value.absent()
          : Value(fingerprint),
      mediaId: mediaId == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaId),
      postId:
          postId == null && nullToAbsent ? const Value.absent() : Value(postId),
      suppressed: Value(suppressed),
      deletedAtMs: deletedAtMs == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAtMs),
      supersededVideoPath: supersededVideoPath == null && nullToAbsent
          ? const Value.absent()
          : Value(supersededVideoPath),
      supersededPosterPath: supersededPosterPath == null && nullToAbsent
          ? const Value.absent()
          : Value(supersededPosterPath),
      generation: Value(generation),
    );
  }

  factory SetVideoRecord.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SetVideoRecord(
      id: serializer.fromJson<String>(json['id']),
      ownerUid: serializer.fromJson<String>(json['ownerUid']),
      dateKey: serializer.fromJson<String>(json['dateKey']),
      exerciseId: serializer.fromJson<String>(json['exerciseId']),
      setId: serializer.fromJson<String>(json['setId']),
      setIndex: serializer.fromJson<int>(json['setIndex']),
      localVideoPath: serializer.fromJson<String>(json['localVideoPath']),
      localPosterPath: serializer.fromJson<String?>(json['localPosterPath']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
      state: serializer.fromJson<String>(json['state']),
      liftSlot: serializer.fromJson<String?>(json['liftSlot']),
      fingerprint: serializer.fromJson<String?>(json['fingerprint']),
      mediaId: serializer.fromJson<String?>(json['mediaId']),
      postId: serializer.fromJson<String?>(json['postId']),
      suppressed: serializer.fromJson<bool>(json['suppressed']),
      deletedAtMs: serializer.fromJson<int?>(json['deletedAtMs']),
      supersededVideoPath:
          serializer.fromJson<String?>(json['supersededVideoPath']),
      supersededPosterPath:
          serializer.fromJson<String?>(json['supersededPosterPath']),
      generation: serializer.fromJson<int>(json['generation']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'ownerUid': serializer.toJson<String>(ownerUid),
      'dateKey': serializer.toJson<String>(dateKey),
      'exerciseId': serializer.toJson<String>(exerciseId),
      'setId': serializer.toJson<String>(setId),
      'setIndex': serializer.toJson<int>(setIndex),
      'localVideoPath': serializer.toJson<String>(localVideoPath),
      'localPosterPath': serializer.toJson<String?>(localPosterPath),
      'durationMs': serializer.toJson<int>(durationMs),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
      'state': serializer.toJson<String>(state),
      'liftSlot': serializer.toJson<String?>(liftSlot),
      'fingerprint': serializer.toJson<String?>(fingerprint),
      'mediaId': serializer.toJson<String?>(mediaId),
      'postId': serializer.toJson<String?>(postId),
      'suppressed': serializer.toJson<bool>(suppressed),
      'deletedAtMs': serializer.toJson<int?>(deletedAtMs),
      'supersededVideoPath': serializer.toJson<String?>(supersededVideoPath),
      'supersededPosterPath': serializer.toJson<String?>(supersededPosterPath),
      'generation': serializer.toJson<int>(generation),
    };
  }

  SetVideoRecord copyWith(
          {String? id,
          String? ownerUid,
          String? dateKey,
          String? exerciseId,
          String? setId,
          int? setIndex,
          String? localVideoPath,
          Value<String?> localPosterPath = const Value.absent(),
          int? durationMs,
          int? sizeBytes,
          int? createdAtMs,
          int? updatedAtMs,
          String? state,
          Value<String?> liftSlot = const Value.absent(),
          Value<String?> fingerprint = const Value.absent(),
          Value<String?> mediaId = const Value.absent(),
          Value<String?> postId = const Value.absent(),
          bool? suppressed,
          Value<int?> deletedAtMs = const Value.absent(),
          Value<String?> supersededVideoPath = const Value.absent(),
          Value<String?> supersededPosterPath = const Value.absent(),
          int? generation}) =>
      SetVideoRecord(
        id: id ?? this.id,
        ownerUid: ownerUid ?? this.ownerUid,
        dateKey: dateKey ?? this.dateKey,
        exerciseId: exerciseId ?? this.exerciseId,
        setId: setId ?? this.setId,
        setIndex: setIndex ?? this.setIndex,
        localVideoPath: localVideoPath ?? this.localVideoPath,
        localPosterPath: localPosterPath.present
            ? localPosterPath.value
            : this.localPosterPath,
        durationMs: durationMs ?? this.durationMs,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        createdAtMs: createdAtMs ?? this.createdAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        state: state ?? this.state,
        liftSlot: liftSlot.present ? liftSlot.value : this.liftSlot,
        fingerprint: fingerprint.present ? fingerprint.value : this.fingerprint,
        mediaId: mediaId.present ? mediaId.value : this.mediaId,
        postId: postId.present ? postId.value : this.postId,
        suppressed: suppressed ?? this.suppressed,
        deletedAtMs: deletedAtMs.present ? deletedAtMs.value : this.deletedAtMs,
        supersededVideoPath: supersededVideoPath.present
            ? supersededVideoPath.value
            : this.supersededVideoPath,
        supersededPosterPath: supersededPosterPath.present
            ? supersededPosterPath.value
            : this.supersededPosterPath,
        generation: generation ?? this.generation,
      );
  SetVideoRecord copyWithCompanion(SetVideosCompanion data) {
    return SetVideoRecord(
      id: data.id.present ? data.id.value : this.id,
      ownerUid: data.ownerUid.present ? data.ownerUid.value : this.ownerUid,
      dateKey: data.dateKey.present ? data.dateKey.value : this.dateKey,
      exerciseId:
          data.exerciseId.present ? data.exerciseId.value : this.exerciseId,
      setId: data.setId.present ? data.setId.value : this.setId,
      setIndex: data.setIndex.present ? data.setIndex.value : this.setIndex,
      localVideoPath: data.localVideoPath.present
          ? data.localVideoPath.value
          : this.localVideoPath,
      localPosterPath: data.localPosterPath.present
          ? data.localPosterPath.value
          : this.localPosterPath,
      durationMs:
          data.durationMs.present ? data.durationMs.value : this.durationMs,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      createdAtMs:
          data.createdAtMs.present ? data.createdAtMs.value : this.createdAtMs,
      updatedAtMs:
          data.updatedAtMs.present ? data.updatedAtMs.value : this.updatedAtMs,
      state: data.state.present ? data.state.value : this.state,
      liftSlot: data.liftSlot.present ? data.liftSlot.value : this.liftSlot,
      fingerprint:
          data.fingerprint.present ? data.fingerprint.value : this.fingerprint,
      mediaId: data.mediaId.present ? data.mediaId.value : this.mediaId,
      postId: data.postId.present ? data.postId.value : this.postId,
      suppressed:
          data.suppressed.present ? data.suppressed.value : this.suppressed,
      deletedAtMs:
          data.deletedAtMs.present ? data.deletedAtMs.value : this.deletedAtMs,
      supersededVideoPath: data.supersededVideoPath.present
          ? data.supersededVideoPath.value
          : this.supersededVideoPath,
      supersededPosterPath: data.supersededPosterPath.present
          ? data.supersededPosterPath.value
          : this.supersededPosterPath,
      generation:
          data.generation.present ? data.generation.value : this.generation,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SetVideoRecord(')
          ..write('id: $id, ')
          ..write('ownerUid: $ownerUid, ')
          ..write('dateKey: $dateKey, ')
          ..write('exerciseId: $exerciseId, ')
          ..write('setId: $setId, ')
          ..write('setIndex: $setIndex, ')
          ..write('localVideoPath: $localVideoPath, ')
          ..write('localPosterPath: $localPosterPath, ')
          ..write('durationMs: $durationMs, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('state: $state, ')
          ..write('liftSlot: $liftSlot, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('mediaId: $mediaId, ')
          ..write('postId: $postId, ')
          ..write('suppressed: $suppressed, ')
          ..write('deletedAtMs: $deletedAtMs, ')
          ..write('supersededVideoPath: $supersededVideoPath, ')
          ..write('supersededPosterPath: $supersededPosterPath, ')
          ..write('generation: $generation')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
        id,
        ownerUid,
        dateKey,
        exerciseId,
        setId,
        setIndex,
        localVideoPath,
        localPosterPath,
        durationMs,
        sizeBytes,
        createdAtMs,
        updatedAtMs,
        state,
        liftSlot,
        fingerprint,
        mediaId,
        postId,
        suppressed,
        deletedAtMs,
        supersededVideoPath,
        supersededPosterPath,
        generation
      ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SetVideoRecord &&
          other.id == this.id &&
          other.ownerUid == this.ownerUid &&
          other.dateKey == this.dateKey &&
          other.exerciseId == this.exerciseId &&
          other.setId == this.setId &&
          other.setIndex == this.setIndex &&
          other.localVideoPath == this.localVideoPath &&
          other.localPosterPath == this.localPosterPath &&
          other.durationMs == this.durationMs &&
          other.sizeBytes == this.sizeBytes &&
          other.createdAtMs == this.createdAtMs &&
          other.updatedAtMs == this.updatedAtMs &&
          other.state == this.state &&
          other.liftSlot == this.liftSlot &&
          other.fingerprint == this.fingerprint &&
          other.mediaId == this.mediaId &&
          other.postId == this.postId &&
          other.suppressed == this.suppressed &&
          other.deletedAtMs == this.deletedAtMs &&
          other.supersededVideoPath == this.supersededVideoPath &&
          other.supersededPosterPath == this.supersededPosterPath &&
          other.generation == this.generation);
}

class SetVideosCompanion extends UpdateCompanion<SetVideoRecord> {
  final Value<String> id;
  final Value<String> ownerUid;
  final Value<String> dateKey;
  final Value<String> exerciseId;
  final Value<String> setId;
  final Value<int> setIndex;
  final Value<String> localVideoPath;
  final Value<String?> localPosterPath;
  final Value<int> durationMs;
  final Value<int> sizeBytes;
  final Value<int> createdAtMs;
  final Value<int> updatedAtMs;
  final Value<String> state;
  final Value<String?> liftSlot;
  final Value<String?> fingerprint;
  final Value<String?> mediaId;
  final Value<String?> postId;
  final Value<bool> suppressed;
  final Value<int?> deletedAtMs;
  final Value<String?> supersededVideoPath;
  final Value<String?> supersededPosterPath;
  final Value<int> generation;
  final Value<int> rowid;
  const SetVideosCompanion({
    this.id = const Value.absent(),
    this.ownerUid = const Value.absent(),
    this.dateKey = const Value.absent(),
    this.exerciseId = const Value.absent(),
    this.setId = const Value.absent(),
    this.setIndex = const Value.absent(),
    this.localVideoPath = const Value.absent(),
    this.localPosterPath = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.state = const Value.absent(),
    this.liftSlot = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.mediaId = const Value.absent(),
    this.postId = const Value.absent(),
    this.suppressed = const Value.absent(),
    this.deletedAtMs = const Value.absent(),
    this.supersededVideoPath = const Value.absent(),
    this.supersededPosterPath = const Value.absent(),
    this.generation = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SetVideosCompanion.insert({
    required String id,
    required String ownerUid,
    required String dateKey,
    required String exerciseId,
    required String setId,
    this.setIndex = const Value.absent(),
    required String localVideoPath,
    this.localPosterPath = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    required int createdAtMs,
    required int updatedAtMs,
    this.state = const Value.absent(),
    this.liftSlot = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.mediaId = const Value.absent(),
    this.postId = const Value.absent(),
    this.suppressed = const Value.absent(),
    this.deletedAtMs = const Value.absent(),
    this.supersededVideoPath = const Value.absent(),
    this.supersededPosterPath = const Value.absent(),
    this.generation = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        ownerUid = Value(ownerUid),
        dateKey = Value(dateKey),
        exerciseId = Value(exerciseId),
        setId = Value(setId),
        localVideoPath = Value(localVideoPath),
        createdAtMs = Value(createdAtMs),
        updatedAtMs = Value(updatedAtMs);
  static Insertable<SetVideoRecord> custom({
    Expression<String>? id,
    Expression<String>? ownerUid,
    Expression<String>? dateKey,
    Expression<String>? exerciseId,
    Expression<String>? setId,
    Expression<int>? setIndex,
    Expression<String>? localVideoPath,
    Expression<String>? localPosterPath,
    Expression<int>? durationMs,
    Expression<int>? sizeBytes,
    Expression<int>? createdAtMs,
    Expression<int>? updatedAtMs,
    Expression<String>? state,
    Expression<String>? liftSlot,
    Expression<String>? fingerprint,
    Expression<String>? mediaId,
    Expression<String>? postId,
    Expression<bool>? suppressed,
    Expression<int>? deletedAtMs,
    Expression<String>? supersededVideoPath,
    Expression<String>? supersededPosterPath,
    Expression<int>? generation,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (ownerUid != null) 'owner_uid': ownerUid,
      if (dateKey != null) 'date_key': dateKey,
      if (exerciseId != null) 'exercise_id': exerciseId,
      if (setId != null) 'set_id': setId,
      if (setIndex != null) 'set_index': setIndex,
      if (localVideoPath != null) 'local_video_path': localVideoPath,
      if (localPosterPath != null) 'local_poster_path': localPosterPath,
      if (durationMs != null) 'duration_ms': durationMs,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (createdAtMs != null) 'created_at_ms': createdAtMs,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (state != null) 'state': state,
      if (liftSlot != null) 'lift_slot': liftSlot,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (mediaId != null) 'media_id': mediaId,
      if (postId != null) 'post_id': postId,
      if (suppressed != null) 'suppressed': suppressed,
      if (deletedAtMs != null) 'deleted_at_ms': deletedAtMs,
      if (supersededVideoPath != null)
        'superseded_video_path': supersededVideoPath,
      if (supersededPosterPath != null)
        'superseded_poster_path': supersededPosterPath,
      if (generation != null) 'generation': generation,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SetVideosCompanion copyWith(
      {Value<String>? id,
      Value<String>? ownerUid,
      Value<String>? dateKey,
      Value<String>? exerciseId,
      Value<String>? setId,
      Value<int>? setIndex,
      Value<String>? localVideoPath,
      Value<String?>? localPosterPath,
      Value<int>? durationMs,
      Value<int>? sizeBytes,
      Value<int>? createdAtMs,
      Value<int>? updatedAtMs,
      Value<String>? state,
      Value<String?>? liftSlot,
      Value<String?>? fingerprint,
      Value<String?>? mediaId,
      Value<String?>? postId,
      Value<bool>? suppressed,
      Value<int?>? deletedAtMs,
      Value<String?>? supersededVideoPath,
      Value<String?>? supersededPosterPath,
      Value<int>? generation,
      Value<int>? rowid}) {
    return SetVideosCompanion(
      id: id ?? this.id,
      ownerUid: ownerUid ?? this.ownerUid,
      dateKey: dateKey ?? this.dateKey,
      exerciseId: exerciseId ?? this.exerciseId,
      setId: setId ?? this.setId,
      setIndex: setIndex ?? this.setIndex,
      localVideoPath: localVideoPath ?? this.localVideoPath,
      localPosterPath: localPosterPath ?? this.localPosterPath,
      durationMs: durationMs ?? this.durationMs,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      state: state ?? this.state,
      liftSlot: liftSlot ?? this.liftSlot,
      fingerprint: fingerprint ?? this.fingerprint,
      mediaId: mediaId ?? this.mediaId,
      postId: postId ?? this.postId,
      suppressed: suppressed ?? this.suppressed,
      deletedAtMs: deletedAtMs ?? this.deletedAtMs,
      supersededVideoPath: supersededVideoPath ?? this.supersededVideoPath,
      supersededPosterPath: supersededPosterPath ?? this.supersededPosterPath,
      generation: generation ?? this.generation,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (ownerUid.present) {
      map['owner_uid'] = Variable<String>(ownerUid.value);
    }
    if (dateKey.present) {
      map['date_key'] = Variable<String>(dateKey.value);
    }
    if (exerciseId.present) {
      map['exercise_id'] = Variable<String>(exerciseId.value);
    }
    if (setId.present) {
      map['set_id'] = Variable<String>(setId.value);
    }
    if (setIndex.present) {
      map['set_index'] = Variable<int>(setIndex.value);
    }
    if (localVideoPath.present) {
      map['local_video_path'] = Variable<String>(localVideoPath.value);
    }
    if (localPosterPath.present) {
      map['local_poster_path'] = Variable<String>(localPosterPath.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (createdAtMs.present) {
      map['created_at_ms'] = Variable<int>(createdAtMs.value);
    }
    if (updatedAtMs.present) {
      map['updated_at_ms'] = Variable<int>(updatedAtMs.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (liftSlot.present) {
      map['lift_slot'] = Variable<String>(liftSlot.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (mediaId.present) {
      map['media_id'] = Variable<String>(mediaId.value);
    }
    if (postId.present) {
      map['post_id'] = Variable<String>(postId.value);
    }
    if (suppressed.present) {
      map['suppressed'] = Variable<bool>(suppressed.value);
    }
    if (deletedAtMs.present) {
      map['deleted_at_ms'] = Variable<int>(deletedAtMs.value);
    }
    if (supersededVideoPath.present) {
      map['superseded_video_path'] =
          Variable<String>(supersededVideoPath.value);
    }
    if (supersededPosterPath.present) {
      map['superseded_poster_path'] =
          Variable<String>(supersededPosterPath.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SetVideosCompanion(')
          ..write('id: $id, ')
          ..write('ownerUid: $ownerUid, ')
          ..write('dateKey: $dateKey, ')
          ..write('exerciseId: $exerciseId, ')
          ..write('setId: $setId, ')
          ..write('setIndex: $setIndex, ')
          ..write('localVideoPath: $localVideoPath, ')
          ..write('localPosterPath: $localPosterPath, ')
          ..write('durationMs: $durationMs, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('state: $state, ')
          ..write('liftSlot: $liftSlot, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('mediaId: $mediaId, ')
          ..write('postId: $postId, ')
          ..write('suppressed: $suppressed, ')
          ..write('deletedAtMs: $deletedAtMs, ')
          ..write('supersededVideoPath: $supersededVideoPath, ')
          ..write('supersededPosterPath: $supersededPosterPath, ')
          ..write('generation: $generation, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$SetVideoDatabase extends GeneratedDatabase {
  _$SetVideoDatabase(QueryExecutor e) : super(e);
  $SetVideoDatabaseManager get managers => $SetVideoDatabaseManager(this);
  late final $SetVideosTable setVideos = $SetVideosTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [setVideos];
}

typedef $$SetVideosTableCreateCompanionBuilder = SetVideosCompanion Function({
  required String id,
  required String ownerUid,
  required String dateKey,
  required String exerciseId,
  required String setId,
  Value<int> setIndex,
  required String localVideoPath,
  Value<String?> localPosterPath,
  Value<int> durationMs,
  Value<int> sizeBytes,
  required int createdAtMs,
  required int updatedAtMs,
  Value<String> state,
  Value<String?> liftSlot,
  Value<String?> fingerprint,
  Value<String?> mediaId,
  Value<String?> postId,
  Value<bool> suppressed,
  Value<int?> deletedAtMs,
  Value<String?> supersededVideoPath,
  Value<String?> supersededPosterPath,
  Value<int> generation,
  Value<int> rowid,
});
typedef $$SetVideosTableUpdateCompanionBuilder = SetVideosCompanion Function({
  Value<String> id,
  Value<String> ownerUid,
  Value<String> dateKey,
  Value<String> exerciseId,
  Value<String> setId,
  Value<int> setIndex,
  Value<String> localVideoPath,
  Value<String?> localPosterPath,
  Value<int> durationMs,
  Value<int> sizeBytes,
  Value<int> createdAtMs,
  Value<int> updatedAtMs,
  Value<String> state,
  Value<String?> liftSlot,
  Value<String?> fingerprint,
  Value<String?> mediaId,
  Value<String?> postId,
  Value<bool> suppressed,
  Value<int?> deletedAtMs,
  Value<String?> supersededVideoPath,
  Value<String?> supersededPosterPath,
  Value<int> generation,
  Value<int> rowid,
});

class $$SetVideosTableFilterComposer
    extends Composer<_$SetVideoDatabase, $SetVideosTable> {
  $$SetVideosTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ownerUid => $composableBuilder(
      column: $table.ownerUid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get exerciseId => $composableBuilder(
      column: $table.exerciseId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get setId => $composableBuilder(
      column: $table.setId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get setIndex => $composableBuilder(
      column: $table.setIndex, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localVideoPath => $composableBuilder(
      column: $table.localVideoPath,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localPosterPath => $composableBuilder(
      column: $table.localPosterPath,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sizeBytes => $composableBuilder(
      column: $table.sizeBytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get liftSlot => $composableBuilder(
      column: $table.liftSlot, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get fingerprint => $composableBuilder(
      column: $table.fingerprint, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mediaId => $composableBuilder(
      column: $table.mediaId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get postId => $composableBuilder(
      column: $table.postId, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get suppressed => $composableBuilder(
      column: $table.suppressed, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deletedAtMs => $composableBuilder(
      column: $table.deletedAtMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get supersededVideoPath => $composableBuilder(
      column: $table.supersededVideoPath,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get supersededPosterPath => $composableBuilder(
      column: $table.supersededPosterPath,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => ColumnFilters(column));
}

class $$SetVideosTableOrderingComposer
    extends Composer<_$SetVideoDatabase, $SetVideosTable> {
  $$SetVideosTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ownerUid => $composableBuilder(
      column: $table.ownerUid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get dateKey => $composableBuilder(
      column: $table.dateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get exerciseId => $composableBuilder(
      column: $table.exerciseId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get setId => $composableBuilder(
      column: $table.setId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get setIndex => $composableBuilder(
      column: $table.setIndex, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localVideoPath => $composableBuilder(
      column: $table.localVideoPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localPosterPath => $composableBuilder(
      column: $table.localPosterPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
      column: $table.sizeBytes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get liftSlot => $composableBuilder(
      column: $table.liftSlot, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get fingerprint => $composableBuilder(
      column: $table.fingerprint, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mediaId => $composableBuilder(
      column: $table.mediaId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get postId => $composableBuilder(
      column: $table.postId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get suppressed => $composableBuilder(
      column: $table.suppressed, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deletedAtMs => $composableBuilder(
      column: $table.deletedAtMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get supersededVideoPath => $composableBuilder(
      column: $table.supersededVideoPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get supersededPosterPath => $composableBuilder(
      column: $table.supersededPosterPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => ColumnOrderings(column));
}

class $$SetVideosTableAnnotationComposer
    extends Composer<_$SetVideoDatabase, $SetVideosTable> {
  $$SetVideosTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get ownerUid =>
      $composableBuilder(column: $table.ownerUid, builder: (column) => column);

  GeneratedColumn<String> get dateKey =>
      $composableBuilder(column: $table.dateKey, builder: (column) => column);

  GeneratedColumn<String> get exerciseId => $composableBuilder(
      column: $table.exerciseId, builder: (column) => column);

  GeneratedColumn<String> get setId =>
      $composableBuilder(column: $table.setId, builder: (column) => column);

  GeneratedColumn<int> get setIndex =>
      $composableBuilder(column: $table.setIndex, builder: (column) => column);

  GeneratedColumn<String> get localVideoPath => $composableBuilder(
      column: $table.localVideoPath, builder: (column) => column);

  GeneratedColumn<String> get localPosterPath => $composableBuilder(
      column: $table.localPosterPath, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => column);

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get liftSlot =>
      $composableBuilder(column: $table.liftSlot, builder: (column) => column);

  GeneratedColumn<String> get fingerprint => $composableBuilder(
      column: $table.fingerprint, builder: (column) => column);

  GeneratedColumn<String> get mediaId =>
      $composableBuilder(column: $table.mediaId, builder: (column) => column);

  GeneratedColumn<String> get postId =>
      $composableBuilder(column: $table.postId, builder: (column) => column);

  GeneratedColumn<bool> get suppressed => $composableBuilder(
      column: $table.suppressed, builder: (column) => column);

  GeneratedColumn<int> get deletedAtMs => $composableBuilder(
      column: $table.deletedAtMs, builder: (column) => column);

  GeneratedColumn<String> get supersededVideoPath => $composableBuilder(
      column: $table.supersededVideoPath, builder: (column) => column);

  GeneratedColumn<String> get supersededPosterPath => $composableBuilder(
      column: $table.supersededPosterPath, builder: (column) => column);

  GeneratedColumn<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => column);
}

class $$SetVideosTableTableManager extends RootTableManager<
    _$SetVideoDatabase,
    $SetVideosTable,
    SetVideoRecord,
    $$SetVideosTableFilterComposer,
    $$SetVideosTableOrderingComposer,
    $$SetVideosTableAnnotationComposer,
    $$SetVideosTableCreateCompanionBuilder,
    $$SetVideosTableUpdateCompanionBuilder,
    (
      SetVideoRecord,
      BaseReferences<_$SetVideoDatabase, $SetVideosTable, SetVideoRecord>
    ),
    SetVideoRecord,
    PrefetchHooks Function()> {
  $$SetVideosTableTableManager(_$SetVideoDatabase db, $SetVideosTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SetVideosTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SetVideosTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SetVideosTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> ownerUid = const Value.absent(),
            Value<String> dateKey = const Value.absent(),
            Value<String> exerciseId = const Value.absent(),
            Value<String> setId = const Value.absent(),
            Value<int> setIndex = const Value.absent(),
            Value<String> localVideoPath = const Value.absent(),
            Value<String?> localPosterPath = const Value.absent(),
            Value<int> durationMs = const Value.absent(),
            Value<int> sizeBytes = const Value.absent(),
            Value<int> createdAtMs = const Value.absent(),
            Value<int> updatedAtMs = const Value.absent(),
            Value<String> state = const Value.absent(),
            Value<String?> liftSlot = const Value.absent(),
            Value<String?> fingerprint = const Value.absent(),
            Value<String?> mediaId = const Value.absent(),
            Value<String?> postId = const Value.absent(),
            Value<bool> suppressed = const Value.absent(),
            Value<int?> deletedAtMs = const Value.absent(),
            Value<String?> supersededVideoPath = const Value.absent(),
            Value<String?> supersededPosterPath = const Value.absent(),
            Value<int> generation = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SetVideosCompanion(
            id: id,
            ownerUid: ownerUid,
            dateKey: dateKey,
            exerciseId: exerciseId,
            setId: setId,
            setIndex: setIndex,
            localVideoPath: localVideoPath,
            localPosterPath: localPosterPath,
            durationMs: durationMs,
            sizeBytes: sizeBytes,
            createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs,
            state: state,
            liftSlot: liftSlot,
            fingerprint: fingerprint,
            mediaId: mediaId,
            postId: postId,
            suppressed: suppressed,
            deletedAtMs: deletedAtMs,
            supersededVideoPath: supersededVideoPath,
            supersededPosterPath: supersededPosterPath,
            generation: generation,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String ownerUid,
            required String dateKey,
            required String exerciseId,
            required String setId,
            Value<int> setIndex = const Value.absent(),
            required String localVideoPath,
            Value<String?> localPosterPath = const Value.absent(),
            Value<int> durationMs = const Value.absent(),
            Value<int> sizeBytes = const Value.absent(),
            required int createdAtMs,
            required int updatedAtMs,
            Value<String> state = const Value.absent(),
            Value<String?> liftSlot = const Value.absent(),
            Value<String?> fingerprint = const Value.absent(),
            Value<String?> mediaId = const Value.absent(),
            Value<String?> postId = const Value.absent(),
            Value<bool> suppressed = const Value.absent(),
            Value<int?> deletedAtMs = const Value.absent(),
            Value<String?> supersededVideoPath = const Value.absent(),
            Value<String?> supersededPosterPath = const Value.absent(),
            Value<int> generation = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SetVideosCompanion.insert(
            id: id,
            ownerUid: ownerUid,
            dateKey: dateKey,
            exerciseId: exerciseId,
            setId: setId,
            setIndex: setIndex,
            localVideoPath: localVideoPath,
            localPosterPath: localPosterPath,
            durationMs: durationMs,
            sizeBytes: sizeBytes,
            createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs,
            state: state,
            liftSlot: liftSlot,
            fingerprint: fingerprint,
            mediaId: mediaId,
            postId: postId,
            suppressed: suppressed,
            deletedAtMs: deletedAtMs,
            supersededVideoPath: supersededVideoPath,
            supersededPosterPath: supersededPosterPath,
            generation: generation,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SetVideosTableProcessedTableManager = ProcessedTableManager<
    _$SetVideoDatabase,
    $SetVideosTable,
    SetVideoRecord,
    $$SetVideosTableFilterComposer,
    $$SetVideosTableOrderingComposer,
    $$SetVideosTableAnnotationComposer,
    $$SetVideosTableCreateCompanionBuilder,
    $$SetVideosTableUpdateCompanionBuilder,
    (
      SetVideoRecord,
      BaseReferences<_$SetVideoDatabase, $SetVideosTable, SetVideoRecord>
    ),
    SetVideoRecord,
    PrefetchHooks Function()>;

class $SetVideoDatabaseManager {
  final _$SetVideoDatabase _db;
  $SetVideoDatabaseManager(this._db);
  $$SetVideosTableTableManager get setVideos =>
      $$SetVideosTableTableManager(_db, _db.setVideos);
}
