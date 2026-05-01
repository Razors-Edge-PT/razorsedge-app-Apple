// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'isar_wes_init.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetWESInitSnapshotCollection on Isar {
  IsarCollection<WESInitSnapshot> get wESInitSnapshots => this.collection();
}

const WESInitSnapshotSchema = CollectionSchema(
  name: r'WESInitSnapshot',
  id: 7126131446228311812,
  properties: {
    r'blockId': PropertySchema(
      id: 0,
      name: r'blockId',
      type: IsarType.string,
    ),
    r'cachedAt': PropertySchema(
      id: 1,
      name: r'cachedAt',
      type: IsarType.dateTime,
    ),
    r'dateYmd': PropertySchema(
      id: 2,
      name: r'dateYmd',
      type: IsarType.string,
    ),
    r'hintsInputsHash': PropertySchema(
      id: 3,
      name: r'hintsInputsHash',
      type: IsarType.string,
    ),
    r'hintsJson': PropertySchema(
      id: 4,
      name: r'hintsJson',
      type: IsarType.string,
    ),
    r'hintsReady': PropertySchema(
      id: 5,
      name: r'hintsReady',
      type: IsarType.bool,
    ),
    r'plannedExercisesJson': PropertySchema(
      id: 6,
      name: r'plannedExercisesJson',
      type: IsarType.string,
    ),
    r'previousWorkoutJson': PropertySchema(
      id: 7,
      name: r'previousWorkoutJson',
      type: IsarType.string,
    ),
    r'schemaVersion': PropertySchema(
      id: 8,
      name: r'schemaVersion',
      type: IsarType.long,
    ),
    r'topSetHistoryJson': PropertySchema(
      id: 9,
      name: r'topSetHistoryJson',
      type: IsarType.string,
    ),
    r'uid': PropertySchema(
      id: 10,
      name: r'uid',
      type: IsarType.string,
    ),
    r'updatedAt': PropertySchema(
      id: 11,
      name: r'updatedAt',
      type: IsarType.dateTime,
    ),
    r'wesPlannedExercisesJson': PropertySchema(
      id: 12,
      name: r'wesPlannedExercisesJson',
      type: IsarType.string,
    )
  },
  estimateSize: _wESInitSnapshotEstimateSize,
  serialize: _wESInitSnapshotSerialize,
  deserialize: _wESInitSnapshotDeserialize,
  deserializeProp: _wESInitSnapshotDeserializeProp,
  idName: r'id',
  indexes: {},
  links: {},
  embeddedSchemas: {},
  getId: _wESInitSnapshotGetId,
  getLinks: _wESInitSnapshotGetLinks,
  attach: _wESInitSnapshotAttach,
  version: '3.3.2',
);

int _wESInitSnapshotEstimateSize(
  WESInitSnapshot object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.blockId.length * 3;
  bytesCount += 3 + object.dateYmd.length * 3;
  {
    final value = object.hintsInputsHash;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  bytesCount += 3 + object.hintsJson.length * 3;
  bytesCount += 3 + object.plannedExercisesJson.length * 3;
  bytesCount += 3 + object.previousWorkoutJson.length * 3;
  bytesCount += 3 + object.topSetHistoryJson.length * 3;
  bytesCount += 3 + object.uid.length * 3;
  bytesCount += 3 + object.wesPlannedExercisesJson.length * 3;
  return bytesCount;
}

void _wESInitSnapshotSerialize(
  WESInitSnapshot object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.blockId);
  writer.writeDateTime(offsets[1], object.cachedAt);
  writer.writeString(offsets[2], object.dateYmd);
  writer.writeString(offsets[3], object.hintsInputsHash);
  writer.writeString(offsets[4], object.hintsJson);
  writer.writeBool(offsets[5], object.hintsReady);
  writer.writeString(offsets[6], object.plannedExercisesJson);
  writer.writeString(offsets[7], object.previousWorkoutJson);
  writer.writeLong(offsets[8], object.schemaVersion);
  writer.writeString(offsets[9], object.topSetHistoryJson);
  writer.writeString(offsets[10], object.uid);
  writer.writeDateTime(offsets[11], object.updatedAt);
  writer.writeString(offsets[12], object.wesPlannedExercisesJson);
}

WESInitSnapshot _wESInitSnapshotDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = WESInitSnapshot();
  object.blockId = reader.readString(offsets[0]);
  object.cachedAt = reader.readDateTime(offsets[1]);
  object.dateYmd = reader.readString(offsets[2]);
  object.hintsInputsHash = reader.readStringOrNull(offsets[3]);
  object.hintsJson = reader.readString(offsets[4]);
  object.hintsReady = reader.readBoolOrNull(offsets[5]);
  object.id = id;
  object.plannedExercisesJson = reader.readString(offsets[6]);
  object.previousWorkoutJson = reader.readString(offsets[7]);
  object.schemaVersion = reader.readLongOrNull(offsets[8]);
  object.topSetHistoryJson = reader.readString(offsets[9]);
  object.uid = reader.readString(offsets[10]);
  object.updatedAt = reader.readDateTimeOrNull(offsets[11]);
  object.wesPlannedExercisesJson = reader.readString(offsets[12]);
  return object;
}

P _wESInitSnapshotDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readDateTime(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readStringOrNull(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readBoolOrNull(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readString(offset)) as P;
    case 8:
      return (reader.readLongOrNull(offset)) as P;
    case 9:
      return (reader.readString(offset)) as P;
    case 10:
      return (reader.readString(offset)) as P;
    case 11:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 12:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _wESInitSnapshotGetId(WESInitSnapshot object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _wESInitSnapshotGetLinks(WESInitSnapshot object) {
  return [];
}

void _wESInitSnapshotAttach(
    IsarCollection<dynamic> col, Id id, WESInitSnapshot object) {
  object.id = id;
}

extension WESInitSnapshotQueryWhereSort
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QWhere> {
  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension WESInitSnapshotQueryWhere
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QWhereClause> {
  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterWhereClause> idEqualTo(
      Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterWhereClause>
      idNotEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterWhereClause> idLessThan(
      Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: lowerId,
        includeLower: includeLower,
        upper: upperId,
        includeUpper: includeUpper,
      ));
    });
  }
}

extension WESInitSnapshotQueryFilter
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QFilterCondition> {
  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'blockId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'blockId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'blockId',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'blockId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'blockId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'blockId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'blockId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockId',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      blockIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'blockId',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      cachedAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'cachedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      cachedAtGreaterThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'cachedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      cachedAtLessThan(
    DateTime value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'cachedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      cachedAtBetween(
    DateTime lower,
    DateTime upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'cachedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'dateYmd',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'dateYmd',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'dateYmd',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'dateYmd',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'dateYmd',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'dateYmd',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'dateYmd',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'dateYmd',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'dateYmd',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      dateYmdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'dateYmd',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'hintsInputsHash',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'hintsInputsHash',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hintsInputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'hintsInputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'hintsInputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'hintsInputsHash',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'hintsInputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'hintsInputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'hintsInputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'hintsInputsHash',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hintsInputsHash',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsInputsHashIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'hintsInputsHash',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hintsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'hintsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'hintsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'hintsJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'hintsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'hintsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'hintsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'hintsJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hintsJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'hintsJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsReadyIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'hintsReady',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsReadyIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'hintsReady',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      hintsReadyEqualTo(bool? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hintsReady',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      idGreaterThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'id',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'plannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'plannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'plannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'plannedExercisesJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'plannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'plannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'plannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'plannedExercisesJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'plannedExercisesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      plannedExercisesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'plannedExercisesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'previousWorkoutJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'previousWorkoutJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'previousWorkoutJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'previousWorkoutJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'previousWorkoutJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'previousWorkoutJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'previousWorkoutJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'previousWorkoutJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'previousWorkoutJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      previousWorkoutJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'previousWorkoutJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      schemaVersionIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'schemaVersion',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      schemaVersionIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'schemaVersion',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      schemaVersionEqualTo(int? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'schemaVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      schemaVersionGreaterThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'schemaVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      schemaVersionLessThan(
    int? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'schemaVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      schemaVersionBetween(
    int? lower,
    int? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'schemaVersion',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'topSetHistoryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'topSetHistoryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'topSetHistoryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'topSetHistoryJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'topSetHistoryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'topSetHistoryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'topSetHistoryJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'topSetHistoryJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'topSetHistoryJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      topSetHistoryJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'topSetHistoryJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'uid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'uid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'uid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'uid',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'uid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'uid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'uid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'uid',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'uid',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      uidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'uid',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      updatedAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'updatedAt',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      updatedAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'updatedAt',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      updatedAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'updatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      updatedAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'updatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      updatedAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'updatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      updatedAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'updatedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'wesPlannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'wesPlannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'wesPlannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'wesPlannedExercisesJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'wesPlannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'wesPlannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonContains(String value,
          {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'wesPlannedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonMatches(String pattern,
          {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'wesPlannedExercisesJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'wesPlannedExercisesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterFilterCondition>
      wesPlannedExercisesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'wesPlannedExercisesJson',
        value: '',
      ));
    });
  }
}

extension WESInitSnapshotQueryObject
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QFilterCondition> {}

extension WESInitSnapshotQueryLinks
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QFilterCondition> {}

extension WESInitSnapshotQuerySortBy
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QSortBy> {
  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> sortByBlockId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockId', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByBlockIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockId', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByCachedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> sortByDateYmd() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateYmd', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByDateYmdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateYmd', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByHintsInputsHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsInputsHash', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByHintsInputsHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsInputsHash', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByHintsJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByHintsJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsJson', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByHintsReady() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsReady', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByHintsReadyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsReady', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByPlannedExercisesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'plannedExercisesJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByPlannedExercisesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'plannedExercisesJson', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByPreviousWorkoutJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'previousWorkoutJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByPreviousWorkoutJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'previousWorkoutJson', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortBySchemaVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByTopSetHistoryJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'topSetHistoryJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByTopSetHistoryJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'topSetHistoryJson', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> sortByUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> sortByUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByWesPlannedExercisesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'wesPlannedExercisesJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      sortByWesPlannedExercisesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'wesPlannedExercisesJson', Sort.desc);
    });
  }
}

extension WESInitSnapshotQuerySortThenBy
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QSortThenBy> {
  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> thenByBlockId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockId', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByBlockIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockId', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByCachedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> thenByDateYmd() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateYmd', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByDateYmdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateYmd', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByHintsInputsHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsInputsHash', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByHintsInputsHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsInputsHash', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByHintsJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByHintsJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsJson', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByHintsReady() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsReady', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByHintsReadyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsReady', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByPlannedExercisesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'plannedExercisesJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByPlannedExercisesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'plannedExercisesJson', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByPreviousWorkoutJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'previousWorkoutJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByPreviousWorkoutJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'previousWorkoutJson', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenBySchemaVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByTopSetHistoryJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'topSetHistoryJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByTopSetHistoryJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'topSetHistoryJson', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> thenByUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy> thenByUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'updatedAt', Sort.desc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByWesPlannedExercisesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'wesPlannedExercisesJson', Sort.asc);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QAfterSortBy>
      thenByWesPlannedExercisesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'wesPlannedExercisesJson', Sort.desc);
    });
  }
}

extension WESInitSnapshotQueryWhereDistinct
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct> {
  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct> distinctByBlockId(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'blockId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'cachedAt');
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct> distinctByDateYmd(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'dateYmd', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctByHintsInputsHash({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hintsInputsHash',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct> distinctByHintsJson(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hintsJson', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctByHintsReady() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hintsReady');
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctByPlannedExercisesJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'plannedExercisesJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctByPreviousWorkoutJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'previousWorkoutJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'schemaVersion');
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctByTopSetHistoryJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'topSetHistoryJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct> distinctByUid(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'uid', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctByUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'updatedAt');
    });
  }

  QueryBuilder<WESInitSnapshot, WESInitSnapshot, QDistinct>
      distinctByWesPlannedExercisesJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'wesPlannedExercisesJson',
          caseSensitive: caseSensitive);
    });
  }
}

extension WESInitSnapshotQueryProperty
    on QueryBuilder<WESInitSnapshot, WESInitSnapshot, QQueryProperty> {
  QueryBuilder<WESInitSnapshot, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<WESInitSnapshot, String, QQueryOperations> blockIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'blockId');
    });
  }

  QueryBuilder<WESInitSnapshot, DateTime, QQueryOperations> cachedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'cachedAt');
    });
  }

  QueryBuilder<WESInitSnapshot, String, QQueryOperations> dateYmdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'dateYmd');
    });
  }

  QueryBuilder<WESInitSnapshot, String?, QQueryOperations>
      hintsInputsHashProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hintsInputsHash');
    });
  }

  QueryBuilder<WESInitSnapshot, String, QQueryOperations> hintsJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hintsJson');
    });
  }

  QueryBuilder<WESInitSnapshot, bool?, QQueryOperations> hintsReadyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hintsReady');
    });
  }

  QueryBuilder<WESInitSnapshot, String, QQueryOperations>
      plannedExercisesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'plannedExercisesJson');
    });
  }

  QueryBuilder<WESInitSnapshot, String, QQueryOperations>
      previousWorkoutJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'previousWorkoutJson');
    });
  }

  QueryBuilder<WESInitSnapshot, int?, QQueryOperations>
      schemaVersionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'schemaVersion');
    });
  }

  QueryBuilder<WESInitSnapshot, String, QQueryOperations>
      topSetHistoryJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'topSetHistoryJson');
    });
  }

  QueryBuilder<WESInitSnapshot, String, QQueryOperations> uidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'uid');
    });
  }

  QueryBuilder<WESInitSnapshot, DateTime?, QQueryOperations>
      updatedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'updatedAt');
    });
  }

  QueryBuilder<WESInitSnapshot, String, QQueryOperations>
      wesPlannedExercisesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'wesPlannedExercisesJson');
    });
  }
}
