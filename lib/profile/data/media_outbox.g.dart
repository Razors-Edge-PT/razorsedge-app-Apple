// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'media_outbox.dart';

// ignore_for_file: type=lint
class $OutboxItemsTable extends OutboxItems
    with TableInfo<$OutboxItemsTable, OutboxItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OutboxItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _mediaIdMeta =
      const VerificationMeta('mediaId');
  @override
  late final GeneratedColumn<String> mediaId = GeneratedColumn<String>(
      'media_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _ownerUidMeta =
      const VerificationMeta('ownerUid');
  @override
  late final GeneratedColumn<String> ownerUid = GeneratedColumn<String>(
      'owner_uid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
      'kind', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _mediaTypeMeta =
      const VerificationMeta('mediaType');
  @override
  late final GeneratedColumn<String> mediaType = GeneratedColumn<String>(
      'media_type', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _storagePathMeta =
      const VerificationMeta('storagePath');
  @override
  late final GeneratedColumn<String> storagePath = GeneratedColumn<String>(
      'storage_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _localFilePathMeta =
      const VerificationMeta('localFilePath');
  @override
  late final GeneratedColumn<String> localFilePath = GeneratedColumn<String>(
      'local_file_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _localThumbPathMeta =
      const VerificationMeta('localThumbPath');
  @override
  late final GeneratedColumn<String> localThumbPath = GeneratedColumn<String>(
      'local_thumb_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _captionMeta =
      const VerificationMeta('caption');
  @override
  late final GeneratedColumn<String> caption = GeneratedColumn<String>(
      'caption', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _achievementFingerprintMeta =
      const VerificationMeta('achievementFingerprint');
  @override
  late final GeneratedColumn<String> achievementFingerprint =
      GeneratedColumn<String>('achievement_fingerprint', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _achievementSlotMeta =
      const VerificationMeta('achievementSlot');
  @override
  late final GeneratedColumn<String> achievementSlot = GeneratedColumn<String>(
      'achievement_slot', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
      'state', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(OutboxState.pending));
  static const VerificationMeta _attemptCountMeta =
      const VerificationMeta('attemptCount');
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
      'attempt_count', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastErrorMeta =
      const VerificationMeta('lastError');
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
      'last_error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _supersessionKeyMeta =
      const VerificationMeta('supersessionKey');
  @override
  late final GeneratedColumn<String> supersessionKey = GeneratedColumn<String>(
      'supersession_key', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _generationMeta =
      const VerificationMeta('generation');
  @override
  late final GeneratedColumn<int> generation = GeneratedColumn<int>(
      'generation', aliasedName, false,
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
  @override
  List<GeneratedColumn> get $columns => [
        mediaId,
        ownerUid,
        kind,
        mediaType,
        storagePath,
        localFilePath,
        localThumbPath,
        caption,
        achievementFingerprint,
        achievementSlot,
        state,
        attemptCount,
        lastError,
        supersessionKey,
        generation,
        createdAtMs,
        updatedAtMs
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'outbox_items';
  @override
  VerificationContext validateIntegrity(Insertable<OutboxItem> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('media_id')) {
      context.handle(_mediaIdMeta,
          mediaId.isAcceptableOrUnknown(data['media_id']!, _mediaIdMeta));
    } else if (isInserting) {
      context.missing(_mediaIdMeta);
    }
    if (data.containsKey('owner_uid')) {
      context.handle(_ownerUidMeta,
          ownerUid.isAcceptableOrUnknown(data['owner_uid']!, _ownerUidMeta));
    } else if (isInserting) {
      context.missing(_ownerUidMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
          _kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('media_type')) {
      context.handle(_mediaTypeMeta,
          mediaType.isAcceptableOrUnknown(data['media_type']!, _mediaTypeMeta));
    } else if (isInserting) {
      context.missing(_mediaTypeMeta);
    }
    if (data.containsKey('storage_path')) {
      context.handle(
          _storagePathMeta,
          storagePath.isAcceptableOrUnknown(
              data['storage_path']!, _storagePathMeta));
    } else if (isInserting) {
      context.missing(_storagePathMeta);
    }
    if (data.containsKey('local_file_path')) {
      context.handle(
          _localFilePathMeta,
          localFilePath.isAcceptableOrUnknown(
              data['local_file_path']!, _localFilePathMeta));
    } else if (isInserting) {
      context.missing(_localFilePathMeta);
    }
    if (data.containsKey('local_thumb_path')) {
      context.handle(
          _localThumbPathMeta,
          localThumbPath.isAcceptableOrUnknown(
              data['local_thumb_path']!, _localThumbPathMeta));
    }
    if (data.containsKey('caption')) {
      context.handle(_captionMeta,
          caption.isAcceptableOrUnknown(data['caption']!, _captionMeta));
    }
    if (data.containsKey('achievement_fingerprint')) {
      context.handle(
          _achievementFingerprintMeta,
          achievementFingerprint.isAcceptableOrUnknown(
              data['achievement_fingerprint']!, _achievementFingerprintMeta));
    }
    if (data.containsKey('achievement_slot')) {
      context.handle(
          _achievementSlotMeta,
          achievementSlot.isAcceptableOrUnknown(
              data['achievement_slot']!, _achievementSlotMeta));
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
    if (data.containsKey('last_error')) {
      context.handle(_lastErrorMeta,
          lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta));
    }
    if (data.containsKey('supersession_key')) {
      context.handle(
          _supersessionKeyMeta,
          supersessionKey.isAcceptableOrUnknown(
              data['supersession_key']!, _supersessionKeyMeta));
    }
    if (data.containsKey('generation')) {
      context.handle(
          _generationMeta,
          generation.isAcceptableOrUnknown(
              data['generation']!, _generationMeta));
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
  Set<GeneratedColumn> get $primaryKey => {mediaId};
  @override
  OutboxItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OutboxItem(
      mediaId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}media_id'])!,
      ownerUid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}owner_uid'])!,
      kind: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      mediaType: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}media_type'])!,
      storagePath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}storage_path'])!,
      localFilePath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_file_path'])!,
      localThumbPath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_thumb_path']),
      caption: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}caption']),
      achievementFingerprint: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}achievement_fingerprint']),
      achievementSlot: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}achievement_slot']),
      state: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}state'])!,
      attemptCount: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}attempt_count'])!,
      lastError: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_error']),
      supersessionKey: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}supersession_key']),
      generation: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}generation'])!,
      createdAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at_ms'])!,
      updatedAtMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at_ms'])!,
    );
  }

  @override
  $OutboxItemsTable createAlias(String alias) {
    return $OutboxItemsTable(attachedDatabase, alias);
  }
}

class OutboxItem extends DataClass implements Insertable<OutboxItem> {
  /// Deterministic media id, chosen on the client BEFORE any upload. It is
  /// what makes the Storage path and the Firestore document id predictable,
  /// which is what makes a retry idempotent.
  final String mediaId;
  final String ownerUid;

  /// [OutboxKind].
  final String kind;

  /// 'image' | 'video'.
  final String mediaType;

  /// Fully-qualified Storage object path, decided up front.
  final String storagePath;

  /// Copy of the picked file inside application support — NOT the picker's
  /// temporary path, which the OS may delete at any time.
  final String localFilePath;

  /// Locally generated thumbnail, if any.
  final String? localThumbPath;
  final String? caption;

  /// Record fingerprint this upload is proof of, for [OutboxKind.proof].
  final String? achievementFingerprint;

  /// Big Five slot for a proof upload.
  final String? achievementSlot;

  /// [OutboxState].
  final String state;
  final int attemptCount;
  final String? lastError;

  /// Identity of a replaceable asset (e.g. 'avatar:<uid>'). Null for
  /// append-only media, which is never superseded.
  final String? supersessionKey;

  /// Monotonic generation within a supersession key. Higher always wins.
  final int generation;
  final int createdAtMs;
  final int updatedAtMs;
  const OutboxItem(
      {required this.mediaId,
      required this.ownerUid,
      required this.kind,
      required this.mediaType,
      required this.storagePath,
      required this.localFilePath,
      this.localThumbPath,
      this.caption,
      this.achievementFingerprint,
      this.achievementSlot,
      required this.state,
      required this.attemptCount,
      this.lastError,
      this.supersessionKey,
      required this.generation,
      required this.createdAtMs,
      required this.updatedAtMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['media_id'] = Variable<String>(mediaId);
    map['owner_uid'] = Variable<String>(ownerUid);
    map['kind'] = Variable<String>(kind);
    map['media_type'] = Variable<String>(mediaType);
    map['storage_path'] = Variable<String>(storagePath);
    map['local_file_path'] = Variable<String>(localFilePath);
    if (!nullToAbsent || localThumbPath != null) {
      map['local_thumb_path'] = Variable<String>(localThumbPath);
    }
    if (!nullToAbsent || caption != null) {
      map['caption'] = Variable<String>(caption);
    }
    if (!nullToAbsent || achievementFingerprint != null) {
      map['achievement_fingerprint'] = Variable<String>(achievementFingerprint);
    }
    if (!nullToAbsent || achievementSlot != null) {
      map['achievement_slot'] = Variable<String>(achievementSlot);
    }
    map['state'] = Variable<String>(state);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    if (!nullToAbsent || supersessionKey != null) {
      map['supersession_key'] = Variable<String>(supersessionKey);
    }
    map['generation'] = Variable<int>(generation);
    map['created_at_ms'] = Variable<int>(createdAtMs);
    map['updated_at_ms'] = Variable<int>(updatedAtMs);
    return map;
  }

  OutboxItemsCompanion toCompanion(bool nullToAbsent) {
    return OutboxItemsCompanion(
      mediaId: Value(mediaId),
      ownerUid: Value(ownerUid),
      kind: Value(kind),
      mediaType: Value(mediaType),
      storagePath: Value(storagePath),
      localFilePath: Value(localFilePath),
      localThumbPath: localThumbPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localThumbPath),
      caption: caption == null && nullToAbsent
          ? const Value.absent()
          : Value(caption),
      achievementFingerprint: achievementFingerprint == null && nullToAbsent
          ? const Value.absent()
          : Value(achievementFingerprint),
      achievementSlot: achievementSlot == null && nullToAbsent
          ? const Value.absent()
          : Value(achievementSlot),
      state: Value(state),
      attemptCount: Value(attemptCount),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      supersessionKey: supersessionKey == null && nullToAbsent
          ? const Value.absent()
          : Value(supersessionKey),
      generation: Value(generation),
      createdAtMs: Value(createdAtMs),
      updatedAtMs: Value(updatedAtMs),
    );
  }

  factory OutboxItem.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OutboxItem(
      mediaId: serializer.fromJson<String>(json['mediaId']),
      ownerUid: serializer.fromJson<String>(json['ownerUid']),
      kind: serializer.fromJson<String>(json['kind']),
      mediaType: serializer.fromJson<String>(json['mediaType']),
      storagePath: serializer.fromJson<String>(json['storagePath']),
      localFilePath: serializer.fromJson<String>(json['localFilePath']),
      localThumbPath: serializer.fromJson<String?>(json['localThumbPath']),
      caption: serializer.fromJson<String?>(json['caption']),
      achievementFingerprint:
          serializer.fromJson<String?>(json['achievementFingerprint']),
      achievementSlot: serializer.fromJson<String?>(json['achievementSlot']),
      state: serializer.fromJson<String>(json['state']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      supersessionKey: serializer.fromJson<String?>(json['supersessionKey']),
      generation: serializer.fromJson<int>(json['generation']),
      createdAtMs: serializer.fromJson<int>(json['createdAtMs']),
      updatedAtMs: serializer.fromJson<int>(json['updatedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'mediaId': serializer.toJson<String>(mediaId),
      'ownerUid': serializer.toJson<String>(ownerUid),
      'kind': serializer.toJson<String>(kind),
      'mediaType': serializer.toJson<String>(mediaType),
      'storagePath': serializer.toJson<String>(storagePath),
      'localFilePath': serializer.toJson<String>(localFilePath),
      'localThumbPath': serializer.toJson<String?>(localThumbPath),
      'caption': serializer.toJson<String?>(caption),
      'achievementFingerprint':
          serializer.toJson<String?>(achievementFingerprint),
      'achievementSlot': serializer.toJson<String?>(achievementSlot),
      'state': serializer.toJson<String>(state),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'lastError': serializer.toJson<String?>(lastError),
      'supersessionKey': serializer.toJson<String?>(supersessionKey),
      'generation': serializer.toJson<int>(generation),
      'createdAtMs': serializer.toJson<int>(createdAtMs),
      'updatedAtMs': serializer.toJson<int>(updatedAtMs),
    };
  }

  OutboxItem copyWith(
          {String? mediaId,
          String? ownerUid,
          String? kind,
          String? mediaType,
          String? storagePath,
          String? localFilePath,
          Value<String?> localThumbPath = const Value.absent(),
          Value<String?> caption = const Value.absent(),
          Value<String?> achievementFingerprint = const Value.absent(),
          Value<String?> achievementSlot = const Value.absent(),
          String? state,
          int? attemptCount,
          Value<String?> lastError = const Value.absent(),
          Value<String?> supersessionKey = const Value.absent(),
          int? generation,
          int? createdAtMs,
          int? updatedAtMs}) =>
      OutboxItem(
        mediaId: mediaId ?? this.mediaId,
        ownerUid: ownerUid ?? this.ownerUid,
        kind: kind ?? this.kind,
        mediaType: mediaType ?? this.mediaType,
        storagePath: storagePath ?? this.storagePath,
        localFilePath: localFilePath ?? this.localFilePath,
        localThumbPath:
            localThumbPath.present ? localThumbPath.value : this.localThumbPath,
        caption: caption.present ? caption.value : this.caption,
        achievementFingerprint: achievementFingerprint.present
            ? achievementFingerprint.value
            : this.achievementFingerprint,
        achievementSlot: achievementSlot.present
            ? achievementSlot.value
            : this.achievementSlot,
        state: state ?? this.state,
        attemptCount: attemptCount ?? this.attemptCount,
        lastError: lastError.present ? lastError.value : this.lastError,
        supersessionKey: supersessionKey.present
            ? supersessionKey.value
            : this.supersessionKey,
        generation: generation ?? this.generation,
        createdAtMs: createdAtMs ?? this.createdAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      );
  OutboxItem copyWithCompanion(OutboxItemsCompanion data) {
    return OutboxItem(
      mediaId: data.mediaId.present ? data.mediaId.value : this.mediaId,
      ownerUid: data.ownerUid.present ? data.ownerUid.value : this.ownerUid,
      kind: data.kind.present ? data.kind.value : this.kind,
      mediaType: data.mediaType.present ? data.mediaType.value : this.mediaType,
      storagePath:
          data.storagePath.present ? data.storagePath.value : this.storagePath,
      localFilePath: data.localFilePath.present
          ? data.localFilePath.value
          : this.localFilePath,
      localThumbPath: data.localThumbPath.present
          ? data.localThumbPath.value
          : this.localThumbPath,
      caption: data.caption.present ? data.caption.value : this.caption,
      achievementFingerprint: data.achievementFingerprint.present
          ? data.achievementFingerprint.value
          : this.achievementFingerprint,
      achievementSlot: data.achievementSlot.present
          ? data.achievementSlot.value
          : this.achievementSlot,
      state: data.state.present ? data.state.value : this.state,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      supersessionKey: data.supersessionKey.present
          ? data.supersessionKey.value
          : this.supersessionKey,
      generation:
          data.generation.present ? data.generation.value : this.generation,
      createdAtMs:
          data.createdAtMs.present ? data.createdAtMs.value : this.createdAtMs,
      updatedAtMs:
          data.updatedAtMs.present ? data.updatedAtMs.value : this.updatedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OutboxItem(')
          ..write('mediaId: $mediaId, ')
          ..write('ownerUid: $ownerUid, ')
          ..write('kind: $kind, ')
          ..write('mediaType: $mediaType, ')
          ..write('storagePath: $storagePath, ')
          ..write('localFilePath: $localFilePath, ')
          ..write('localThumbPath: $localThumbPath, ')
          ..write('caption: $caption, ')
          ..write('achievementFingerprint: $achievementFingerprint, ')
          ..write('achievementSlot: $achievementSlot, ')
          ..write('state: $state, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('lastError: $lastError, ')
          ..write('supersessionKey: $supersessionKey, ')
          ..write('generation: $generation, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      mediaId,
      ownerUid,
      kind,
      mediaType,
      storagePath,
      localFilePath,
      localThumbPath,
      caption,
      achievementFingerprint,
      achievementSlot,
      state,
      attemptCount,
      lastError,
      supersessionKey,
      generation,
      createdAtMs,
      updatedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OutboxItem &&
          other.mediaId == this.mediaId &&
          other.ownerUid == this.ownerUid &&
          other.kind == this.kind &&
          other.mediaType == this.mediaType &&
          other.storagePath == this.storagePath &&
          other.localFilePath == this.localFilePath &&
          other.localThumbPath == this.localThumbPath &&
          other.caption == this.caption &&
          other.achievementFingerprint == this.achievementFingerprint &&
          other.achievementSlot == this.achievementSlot &&
          other.state == this.state &&
          other.attemptCount == this.attemptCount &&
          other.lastError == this.lastError &&
          other.supersessionKey == this.supersessionKey &&
          other.generation == this.generation &&
          other.createdAtMs == this.createdAtMs &&
          other.updatedAtMs == this.updatedAtMs);
}

class OutboxItemsCompanion extends UpdateCompanion<OutboxItem> {
  final Value<String> mediaId;
  final Value<String> ownerUid;
  final Value<String> kind;
  final Value<String> mediaType;
  final Value<String> storagePath;
  final Value<String> localFilePath;
  final Value<String?> localThumbPath;
  final Value<String?> caption;
  final Value<String?> achievementFingerprint;
  final Value<String?> achievementSlot;
  final Value<String> state;
  final Value<int> attemptCount;
  final Value<String?> lastError;
  final Value<String?> supersessionKey;
  final Value<int> generation;
  final Value<int> createdAtMs;
  final Value<int> updatedAtMs;
  final Value<int> rowid;
  const OutboxItemsCompanion({
    this.mediaId = const Value.absent(),
    this.ownerUid = const Value.absent(),
    this.kind = const Value.absent(),
    this.mediaType = const Value.absent(),
    this.storagePath = const Value.absent(),
    this.localFilePath = const Value.absent(),
    this.localThumbPath = const Value.absent(),
    this.caption = const Value.absent(),
    this.achievementFingerprint = const Value.absent(),
    this.achievementSlot = const Value.absent(),
    this.state = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.supersessionKey = const Value.absent(),
    this.generation = const Value.absent(),
    this.createdAtMs = const Value.absent(),
    this.updatedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OutboxItemsCompanion.insert({
    required String mediaId,
    required String ownerUid,
    required String kind,
    required String mediaType,
    required String storagePath,
    required String localFilePath,
    this.localThumbPath = const Value.absent(),
    this.caption = const Value.absent(),
    this.achievementFingerprint = const Value.absent(),
    this.achievementSlot = const Value.absent(),
    this.state = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.lastError = const Value.absent(),
    this.supersessionKey = const Value.absent(),
    this.generation = const Value.absent(),
    required int createdAtMs,
    required int updatedAtMs,
    this.rowid = const Value.absent(),
  })  : mediaId = Value(mediaId),
        ownerUid = Value(ownerUid),
        kind = Value(kind),
        mediaType = Value(mediaType),
        storagePath = Value(storagePath),
        localFilePath = Value(localFilePath),
        createdAtMs = Value(createdAtMs),
        updatedAtMs = Value(updatedAtMs);
  static Insertable<OutboxItem> custom({
    Expression<String>? mediaId,
    Expression<String>? ownerUid,
    Expression<String>? kind,
    Expression<String>? mediaType,
    Expression<String>? storagePath,
    Expression<String>? localFilePath,
    Expression<String>? localThumbPath,
    Expression<String>? caption,
    Expression<String>? achievementFingerprint,
    Expression<String>? achievementSlot,
    Expression<String>? state,
    Expression<int>? attemptCount,
    Expression<String>? lastError,
    Expression<String>? supersessionKey,
    Expression<int>? generation,
    Expression<int>? createdAtMs,
    Expression<int>? updatedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (mediaId != null) 'media_id': mediaId,
      if (ownerUid != null) 'owner_uid': ownerUid,
      if (kind != null) 'kind': kind,
      if (mediaType != null) 'media_type': mediaType,
      if (storagePath != null) 'storage_path': storagePath,
      if (localFilePath != null) 'local_file_path': localFilePath,
      if (localThumbPath != null) 'local_thumb_path': localThumbPath,
      if (caption != null) 'caption': caption,
      if (achievementFingerprint != null)
        'achievement_fingerprint': achievementFingerprint,
      if (achievementSlot != null) 'achievement_slot': achievementSlot,
      if (state != null) 'state': state,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (lastError != null) 'last_error': lastError,
      if (supersessionKey != null) 'supersession_key': supersessionKey,
      if (generation != null) 'generation': generation,
      if (createdAtMs != null) 'created_at_ms': createdAtMs,
      if (updatedAtMs != null) 'updated_at_ms': updatedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OutboxItemsCompanion copyWith(
      {Value<String>? mediaId,
      Value<String>? ownerUid,
      Value<String>? kind,
      Value<String>? mediaType,
      Value<String>? storagePath,
      Value<String>? localFilePath,
      Value<String?>? localThumbPath,
      Value<String?>? caption,
      Value<String?>? achievementFingerprint,
      Value<String?>? achievementSlot,
      Value<String>? state,
      Value<int>? attemptCount,
      Value<String?>? lastError,
      Value<String?>? supersessionKey,
      Value<int>? generation,
      Value<int>? createdAtMs,
      Value<int>? updatedAtMs,
      Value<int>? rowid}) {
    return OutboxItemsCompanion(
      mediaId: mediaId ?? this.mediaId,
      ownerUid: ownerUid ?? this.ownerUid,
      kind: kind ?? this.kind,
      mediaType: mediaType ?? this.mediaType,
      storagePath: storagePath ?? this.storagePath,
      localFilePath: localFilePath ?? this.localFilePath,
      localThumbPath: localThumbPath ?? this.localThumbPath,
      caption: caption ?? this.caption,
      achievementFingerprint:
          achievementFingerprint ?? this.achievementFingerprint,
      achievementSlot: achievementSlot ?? this.achievementSlot,
      state: state ?? this.state,
      attemptCount: attemptCount ?? this.attemptCount,
      lastError: lastError ?? this.lastError,
      supersessionKey: supersessionKey ?? this.supersessionKey,
      generation: generation ?? this.generation,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (mediaId.present) {
      map['media_id'] = Variable<String>(mediaId.value);
    }
    if (ownerUid.present) {
      map['owner_uid'] = Variable<String>(ownerUid.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (mediaType.present) {
      map['media_type'] = Variable<String>(mediaType.value);
    }
    if (storagePath.present) {
      map['storage_path'] = Variable<String>(storagePath.value);
    }
    if (localFilePath.present) {
      map['local_file_path'] = Variable<String>(localFilePath.value);
    }
    if (localThumbPath.present) {
      map['local_thumb_path'] = Variable<String>(localThumbPath.value);
    }
    if (caption.present) {
      map['caption'] = Variable<String>(caption.value);
    }
    if (achievementFingerprint.present) {
      map['achievement_fingerprint'] =
          Variable<String>(achievementFingerprint.value);
    }
    if (achievementSlot.present) {
      map['achievement_slot'] = Variable<String>(achievementSlot.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (supersessionKey.present) {
      map['supersession_key'] = Variable<String>(supersessionKey.value);
    }
    if (generation.present) {
      map['generation'] = Variable<int>(generation.value);
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
    return (StringBuffer('OutboxItemsCompanion(')
          ..write('mediaId: $mediaId, ')
          ..write('ownerUid: $ownerUid, ')
          ..write('kind: $kind, ')
          ..write('mediaType: $mediaType, ')
          ..write('storagePath: $storagePath, ')
          ..write('localFilePath: $localFilePath, ')
          ..write('localThumbPath: $localThumbPath, ')
          ..write('caption: $caption, ')
          ..write('achievementFingerprint: $achievementFingerprint, ')
          ..write('achievementSlot: $achievementSlot, ')
          ..write('state: $state, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('lastError: $lastError, ')
          ..write('supersessionKey: $supersessionKey, ')
          ..write('generation: $generation, ')
          ..write('createdAtMs: $createdAtMs, ')
          ..write('updatedAtMs: $updatedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$MediaOutboxDatabase extends GeneratedDatabase {
  _$MediaOutboxDatabase(QueryExecutor e) : super(e);
  $MediaOutboxDatabaseManager get managers => $MediaOutboxDatabaseManager(this);
  late final $OutboxItemsTable outboxItems = $OutboxItemsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [outboxItems];
}

typedef $$OutboxItemsTableCreateCompanionBuilder = OutboxItemsCompanion
    Function({
  required String mediaId,
  required String ownerUid,
  required String kind,
  required String mediaType,
  required String storagePath,
  required String localFilePath,
  Value<String?> localThumbPath,
  Value<String?> caption,
  Value<String?> achievementFingerprint,
  Value<String?> achievementSlot,
  Value<String> state,
  Value<int> attemptCount,
  Value<String?> lastError,
  Value<String?> supersessionKey,
  Value<int> generation,
  required int createdAtMs,
  required int updatedAtMs,
  Value<int> rowid,
});
typedef $$OutboxItemsTableUpdateCompanionBuilder = OutboxItemsCompanion
    Function({
  Value<String> mediaId,
  Value<String> ownerUid,
  Value<String> kind,
  Value<String> mediaType,
  Value<String> storagePath,
  Value<String> localFilePath,
  Value<String?> localThumbPath,
  Value<String?> caption,
  Value<String?> achievementFingerprint,
  Value<String?> achievementSlot,
  Value<String> state,
  Value<int> attemptCount,
  Value<String?> lastError,
  Value<String?> supersessionKey,
  Value<int> generation,
  Value<int> createdAtMs,
  Value<int> updatedAtMs,
  Value<int> rowid,
});

class $$OutboxItemsTableFilterComposer
    extends Composer<_$MediaOutboxDatabase, $OutboxItemsTable> {
  $$OutboxItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get mediaId => $composableBuilder(
      column: $table.mediaId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ownerUid => $composableBuilder(
      column: $table.ownerUid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mediaType => $composableBuilder(
      column: $table.mediaType, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get storagePath => $composableBuilder(
      column: $table.storagePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localFilePath => $composableBuilder(
      column: $table.localFilePath, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localThumbPath => $composableBuilder(
      column: $table.localThumbPath,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get caption => $composableBuilder(
      column: $table.caption, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get achievementFingerprint => $composableBuilder(
      column: $table.achievementFingerprint,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get achievementSlot => $composableBuilder(
      column: $table.achievementSlot,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastError => $composableBuilder(
      column: $table.lastError, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get supersessionKey => $composableBuilder(
      column: $table.supersessionKey,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnFilters(column));
}

class $$OutboxItemsTableOrderingComposer
    extends Composer<_$MediaOutboxDatabase, $OutboxItemsTable> {
  $$OutboxItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get mediaId => $composableBuilder(
      column: $table.mediaId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ownerUid => $composableBuilder(
      column: $table.ownerUid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind => $composableBuilder(
      column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mediaType => $composableBuilder(
      column: $table.mediaType, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get storagePath => $composableBuilder(
      column: $table.storagePath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localFilePath => $composableBuilder(
      column: $table.localFilePath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localThumbPath => $composableBuilder(
      column: $table.localThumbPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get caption => $composableBuilder(
      column: $table.caption, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get achievementFingerprint => $composableBuilder(
      column: $table.achievementFingerprint,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get achievementSlot => $composableBuilder(
      column: $table.achievementSlot,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get state => $composableBuilder(
      column: $table.state, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastError => $composableBuilder(
      column: $table.lastError, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get supersessionKey => $composableBuilder(
      column: $table.supersessionKey,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => ColumnOrderings(column));
}

class $$OutboxItemsTableAnnotationComposer
    extends Composer<_$MediaOutboxDatabase, $OutboxItemsTable> {
  $$OutboxItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get mediaId =>
      $composableBuilder(column: $table.mediaId, builder: (column) => column);

  GeneratedColumn<String> get ownerUid =>
      $composableBuilder(column: $table.ownerUid, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get mediaType =>
      $composableBuilder(column: $table.mediaType, builder: (column) => column);

  GeneratedColumn<String> get storagePath => $composableBuilder(
      column: $table.storagePath, builder: (column) => column);

  GeneratedColumn<String> get localFilePath => $composableBuilder(
      column: $table.localFilePath, builder: (column) => column);

  GeneratedColumn<String> get localThumbPath => $composableBuilder(
      column: $table.localThumbPath, builder: (column) => column);

  GeneratedColumn<String> get caption =>
      $composableBuilder(column: $table.caption, builder: (column) => column);

  GeneratedColumn<String> get achievementFingerprint => $composableBuilder(
      column: $table.achievementFingerprint, builder: (column) => column);

  GeneratedColumn<String> get achievementSlot => $composableBuilder(
      column: $table.achievementSlot, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
      column: $table.attemptCount, builder: (column) => column);

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<String> get supersessionKey => $composableBuilder(
      column: $table.supersessionKey, builder: (column) => column);

  GeneratedColumn<int> get generation => $composableBuilder(
      column: $table.generation, builder: (column) => column);

  GeneratedColumn<int> get createdAtMs => $composableBuilder(
      column: $table.createdAtMs, builder: (column) => column);

  GeneratedColumn<int> get updatedAtMs => $composableBuilder(
      column: $table.updatedAtMs, builder: (column) => column);
}

class $$OutboxItemsTableTableManager extends RootTableManager<
    _$MediaOutboxDatabase,
    $OutboxItemsTable,
    OutboxItem,
    $$OutboxItemsTableFilterComposer,
    $$OutboxItemsTableOrderingComposer,
    $$OutboxItemsTableAnnotationComposer,
    $$OutboxItemsTableCreateCompanionBuilder,
    $$OutboxItemsTableUpdateCompanionBuilder,
    (
      OutboxItem,
      BaseReferences<_$MediaOutboxDatabase, $OutboxItemsTable, OutboxItem>
    ),
    OutboxItem,
    PrefetchHooks Function()> {
  $$OutboxItemsTableTableManager(
      _$MediaOutboxDatabase db, $OutboxItemsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OutboxItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OutboxItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OutboxItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> mediaId = const Value.absent(),
            Value<String> ownerUid = const Value.absent(),
            Value<String> kind = const Value.absent(),
            Value<String> mediaType = const Value.absent(),
            Value<String> storagePath = const Value.absent(),
            Value<String> localFilePath = const Value.absent(),
            Value<String?> localThumbPath = const Value.absent(),
            Value<String?> caption = const Value.absent(),
            Value<String?> achievementFingerprint = const Value.absent(),
            Value<String?> achievementSlot = const Value.absent(),
            Value<String> state = const Value.absent(),
            Value<int> attemptCount = const Value.absent(),
            Value<String?> lastError = const Value.absent(),
            Value<String?> supersessionKey = const Value.absent(),
            Value<int> generation = const Value.absent(),
            Value<int> createdAtMs = const Value.absent(),
            Value<int> updatedAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              OutboxItemsCompanion(
            mediaId: mediaId,
            ownerUid: ownerUid,
            kind: kind,
            mediaType: mediaType,
            storagePath: storagePath,
            localFilePath: localFilePath,
            localThumbPath: localThumbPath,
            caption: caption,
            achievementFingerprint: achievementFingerprint,
            achievementSlot: achievementSlot,
            state: state,
            attemptCount: attemptCount,
            lastError: lastError,
            supersessionKey: supersessionKey,
            generation: generation,
            createdAtMs: createdAtMs,
            updatedAtMs: updatedAtMs,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String mediaId,
            required String ownerUid,
            required String kind,
            required String mediaType,
            required String storagePath,
            required String localFilePath,
            Value<String?> localThumbPath = const Value.absent(),
            Value<String?> caption = const Value.absent(),
            Value<String?> achievementFingerprint = const Value.absent(),
            Value<String?> achievementSlot = const Value.absent(),
            Value<String> state = const Value.absent(),
            Value<int> attemptCount = const Value.absent(),
            Value<String?> lastError = const Value.absent(),
            Value<String?> supersessionKey = const Value.absent(),
            Value<int> generation = const Value.absent(),
            required int createdAtMs,
            required int updatedAtMs,
            Value<int> rowid = const Value.absent(),
          }) =>
              OutboxItemsCompanion.insert(
            mediaId: mediaId,
            ownerUid: ownerUid,
            kind: kind,
            mediaType: mediaType,
            storagePath: storagePath,
            localFilePath: localFilePath,
            localThumbPath: localThumbPath,
            caption: caption,
            achievementFingerprint: achievementFingerprint,
            achievementSlot: achievementSlot,
            state: state,
            attemptCount: attemptCount,
            lastError: lastError,
            supersessionKey: supersessionKey,
            generation: generation,
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

typedef $$OutboxItemsTableProcessedTableManager = ProcessedTableManager<
    _$MediaOutboxDatabase,
    $OutboxItemsTable,
    OutboxItem,
    $$OutboxItemsTableFilterComposer,
    $$OutboxItemsTableOrderingComposer,
    $$OutboxItemsTableAnnotationComposer,
    $$OutboxItemsTableCreateCompanionBuilder,
    $$OutboxItemsTableUpdateCompanionBuilder,
    (
      OutboxItem,
      BaseReferences<_$MediaOutboxDatabase, $OutboxItemsTable, OutboxItem>
    ),
    OutboxItem,
    PrefetchHooks Function()>;

class $MediaOutboxDatabaseManager {
  final _$MediaOutboxDatabase _db;
  $MediaOutboxDatabaseManager(this._db);
  $$OutboxItemsTableTableManager get outboxItems =>
      $$OutboxItemsTableTableManager(_db, _db.outboxItems);
}
