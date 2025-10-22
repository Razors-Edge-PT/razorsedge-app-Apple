// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'isar_bb2_merged_day.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetBB2MergedDayCollection on Isar {
  IsarCollection<BB2MergedDay> get bB2MergedDays => this.collection();
}

const BB2MergedDaySchema = CollectionSchema(
  name: r'BB2MergedDay',
  id: 1555437971137981839,
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
    r'circuitStartIndicesJson': PropertySchema(
      id: 2,
      name: r'circuitStartIndicesJson',
      type: IsarType.string,
    ),
    r'dayIndex': PropertySchema(
      id: 3,
      name: r'dayIndex',
      type: IsarType.long,
    ),
    r'hintsJson': PropertySchema(
      id: 4,
      name: r'hintsJson',
      type: IsarType.string,
    ),
    r'inputsHash': PropertySchema(
      id: 5,
      name: r'inputsHash',
      type: IsarType.string,
    ),
    r'mergedExercisesJson': PropertySchema(
      id: 6,
      name: r'mergedExercisesJson',
      type: IsarType.string,
    ),
    r'plannerUpdatedAt': PropertySchema(
      id: 7,
      name: r'plannerUpdatedAt',
      type: IsarType.dateTime,
    ),
    r'schemaVersion': PropertySchema(
      id: 8,
      name: r'schemaVersion',
      type: IsarType.long,
    ),
    r'uid': PropertySchema(
      id: 9,
      name: r'uid',
      type: IsarType.string,
    ),
    r'weekIndex': PropertySchema(
      id: 10,
      name: r'weekIndex',
      type: IsarType.long,
    ),
    r'workoutsUpdatedAt': PropertySchema(
      id: 11,
      name: r'workoutsUpdatedAt',
      type: IsarType.dateTime,
    )
  },
  estimateSize: _bB2MergedDayEstimateSize,
  serialize: _bB2MergedDaySerialize,
  deserialize: _bB2MergedDayDeserialize,
  deserializeProp: _bB2MergedDayDeserializeProp,
  idName: r'id',
  indexes: {},
  links: {},
  embeddedSchemas: {},
  getId: _bB2MergedDayGetId,
  getLinks: _bB2MergedDayGetLinks,
  attach: _bB2MergedDayAttach,
  version: '3.1.0+1',
);

int _bB2MergedDayEstimateSize(
  BB2MergedDay object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.blockId.length * 3;
  bytesCount += 3 + object.circuitStartIndicesJson.length * 3;
  bytesCount += 3 + object.hintsJson.length * 3;
  bytesCount += 3 + object.inputsHash.length * 3;
  bytesCount += 3 + object.mergedExercisesJson.length * 3;
  bytesCount += 3 + object.uid.length * 3;
  return bytesCount;
}

void _bB2MergedDaySerialize(
  BB2MergedDay object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.blockId);
  writer.writeDateTime(offsets[1], object.cachedAt);
  writer.writeString(offsets[2], object.circuitStartIndicesJson);
  writer.writeLong(offsets[3], object.dayIndex);
  writer.writeString(offsets[4], object.hintsJson);
  writer.writeString(offsets[5], object.inputsHash);
  writer.writeString(offsets[6], object.mergedExercisesJson);
  writer.writeDateTime(offsets[7], object.plannerUpdatedAt);
  writer.writeLong(offsets[8], object.schemaVersion);
  writer.writeString(offsets[9], object.uid);
  writer.writeLong(offsets[10], object.weekIndex);
  writer.writeDateTime(offsets[11], object.workoutsUpdatedAt);
}

BB2MergedDay _bB2MergedDayDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = BB2MergedDay();
  object.blockId = reader.readString(offsets[0]);
  object.cachedAt = reader.readDateTime(offsets[1]);
  object.circuitStartIndicesJson = reader.readString(offsets[2]);
  object.dayIndex = reader.readLong(offsets[3]);
  object.hintsJson = reader.readString(offsets[4]);
  object.id = id;
  object.inputsHash = reader.readString(offsets[5]);
  object.mergedExercisesJson = reader.readString(offsets[6]);
  object.plannerUpdatedAt = reader.readDateTimeOrNull(offsets[7]);
  object.schemaVersion = reader.readLong(offsets[8]);
  object.uid = reader.readString(offsets[9]);
  object.weekIndex = reader.readLong(offsets[10]);
  object.workoutsUpdatedAt = reader.readDateTimeOrNull(offsets[11]);
  return object;
}

P _bB2MergedDayDeserializeProp<P>(
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
      return (reader.readLong(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    case 7:
      return (reader.readDateTimeOrNull(offset)) as P;
    case 8:
      return (reader.readLong(offset)) as P;
    case 9:
      return (reader.readString(offset)) as P;
    case 10:
      return (reader.readLong(offset)) as P;
    case 11:
      return (reader.readDateTimeOrNull(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _bB2MergedDayGetId(BB2MergedDay object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _bB2MergedDayGetLinks(BB2MergedDay object) {
  return [];
}

void _bB2MergedDayAttach(
    IsarCollection<dynamic> col, Id id, BB2MergedDay object) {
  object.id = id;
}

extension BB2MergedDayQueryWhereSort
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QWhere> {
  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension BB2MergedDayQueryWhere
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QWhereClause> {
  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterWhereClause> idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterWhereClause> idNotEqualTo(
      Id id) {
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterWhereClause> idGreaterThan(
      Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterWhereClause> idLessThan(Id id,
      {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterWhereClause> idBetween(
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

extension BB2MergedDayQueryFilter
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QFilterCondition> {
  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      blockIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'blockId',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      blockIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'blockId',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      blockIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'blockId',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      blockIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'blockId',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      cachedAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'cachedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'circuitStartIndicesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'circuitStartIndicesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'circuitStartIndicesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'circuitStartIndicesJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'circuitStartIndicesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'circuitStartIndicesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonContains(String value,
          {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'circuitStartIndicesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonMatches(String pattern,
          {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'circuitStartIndicesJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'circuitStartIndicesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      circuitStartIndicesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'circuitStartIndicesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      dayIndexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'dayIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      dayIndexGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'dayIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      dayIndexLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'dayIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      dayIndexBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'dayIndex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      hintsJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'hintsJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      hintsJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'hintsJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      hintsJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'hintsJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      hintsJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'hintsJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> idEqualTo(
      Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> idGreaterThan(
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> idLessThan(
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> idBetween(
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'inputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'inputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'inputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'inputsHash',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'inputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'inputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'inputsHash',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'inputsHash',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'inputsHash',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      inputsHashIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'inputsHash',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'mergedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'mergedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'mergedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'mergedExercisesJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'mergedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'mergedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'mergedExercisesJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'mergedExercisesJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'mergedExercisesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      mergedExercisesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'mergedExercisesJson',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      plannerUpdatedAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'plannerUpdatedAt',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      plannerUpdatedAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'plannerUpdatedAt',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      plannerUpdatedAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'plannerUpdatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      plannerUpdatedAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'plannerUpdatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      plannerUpdatedAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'plannerUpdatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      plannerUpdatedAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'plannerUpdatedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      schemaVersionEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'schemaVersion',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      schemaVersionGreaterThan(
    int value, {
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      schemaVersionLessThan(
    int value, {
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      schemaVersionBetween(
    int lower,
    int upper, {
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> uidEqualTo(
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> uidLessThan(
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> uidBetween(
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> uidStartsWith(
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> uidEndsWith(
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

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> uidContains(
      String value,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'uid',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> uidMatches(
      String pattern,
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'uid',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition> uidIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'uid',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      uidIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'uid',
        value: '',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      weekIndexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'weekIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      weekIndexGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'weekIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      weekIndexLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'weekIndex',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      weekIndexBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'weekIndex',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      workoutsUpdatedAtIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'workoutsUpdatedAt',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      workoutsUpdatedAtIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'workoutsUpdatedAt',
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      workoutsUpdatedAtEqualTo(DateTime? value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'workoutsUpdatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      workoutsUpdatedAtGreaterThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'workoutsUpdatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      workoutsUpdatedAtLessThan(
    DateTime? value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'workoutsUpdatedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterFilterCondition>
      workoutsUpdatedAtBetween(
    DateTime? lower,
    DateTime? upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'workoutsUpdatedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }
}

extension BB2MergedDayQueryObject
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QFilterCondition> {}

extension BB2MergedDayQueryLinks
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QFilterCondition> {}

extension BB2MergedDayQuerySortBy
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QSortBy> {
  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByBlockId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockId', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByBlockIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockId', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByCachedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByCircuitStartIndicesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'circuitStartIndicesJson', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByCircuitStartIndicesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'circuitStartIndicesJson', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByDayIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dayIndex', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByDayIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dayIndex', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByHintsJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsJson', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByHintsJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsJson', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByInputsHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'inputsHash', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByInputsHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'inputsHash', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByMergedExercisesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mergedExercisesJson', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByMergedExercisesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mergedExercisesJson', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByPlannerUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'plannerUpdatedAt', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByPlannerUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'plannerUpdatedAt', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortBySchemaVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByWeekIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'weekIndex', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> sortByWeekIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'weekIndex', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByWorkoutsUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'workoutsUpdatedAt', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      sortByWorkoutsUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'workoutsUpdatedAt', Sort.desc);
    });
  }
}

extension BB2MergedDayQuerySortThenBy
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QSortThenBy> {
  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByBlockId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockId', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByBlockIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'blockId', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByCachedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByCircuitStartIndicesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'circuitStartIndicesJson', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByCircuitStartIndicesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'circuitStartIndicesJson', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByDayIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dayIndex', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByDayIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dayIndex', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByHintsJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsJson', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByHintsJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'hintsJson', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByInputsHash() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'inputsHash', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByInputsHashDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'inputsHash', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByMergedExercisesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mergedExercisesJson', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByMergedExercisesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'mergedExercisesJson', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByPlannerUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'plannerUpdatedAt', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByPlannerUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'plannerUpdatedAt', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenBySchemaVersionDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'schemaVersion', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByUid() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByUidDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uid', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByWeekIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'weekIndex', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy> thenByWeekIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'weekIndex', Sort.desc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByWorkoutsUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'workoutsUpdatedAt', Sort.asc);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QAfterSortBy>
      thenByWorkoutsUpdatedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'workoutsUpdatedAt', Sort.desc);
    });
  }
}

extension BB2MergedDayQueryWhereDistinct
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct> {
  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct> distinctByBlockId(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'blockId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct> distinctByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'cachedAt');
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct>
      distinctByCircuitStartIndicesJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'circuitStartIndicesJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct> distinctByDayIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'dayIndex');
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct> distinctByHintsJson(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'hintsJson', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct> distinctByInputsHash(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'inputsHash', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct>
      distinctByMergedExercisesJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'mergedExercisesJson',
          caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct>
      distinctByPlannerUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'plannerUpdatedAt');
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct>
      distinctBySchemaVersion() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'schemaVersion');
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct> distinctByUid(
      {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'uid', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct> distinctByWeekIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'weekIndex');
    });
  }

  QueryBuilder<BB2MergedDay, BB2MergedDay, QDistinct>
      distinctByWorkoutsUpdatedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'workoutsUpdatedAt');
    });
  }
}

extension BB2MergedDayQueryProperty
    on QueryBuilder<BB2MergedDay, BB2MergedDay, QQueryProperty> {
  QueryBuilder<BB2MergedDay, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<BB2MergedDay, String, QQueryOperations> blockIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'blockId');
    });
  }

  QueryBuilder<BB2MergedDay, DateTime, QQueryOperations> cachedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'cachedAt');
    });
  }

  QueryBuilder<BB2MergedDay, String, QQueryOperations>
      circuitStartIndicesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'circuitStartIndicesJson');
    });
  }

  QueryBuilder<BB2MergedDay, int, QQueryOperations> dayIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'dayIndex');
    });
  }

  QueryBuilder<BB2MergedDay, String, QQueryOperations> hintsJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'hintsJson');
    });
  }

  QueryBuilder<BB2MergedDay, String, QQueryOperations> inputsHashProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'inputsHash');
    });
  }

  QueryBuilder<BB2MergedDay, String, QQueryOperations>
      mergedExercisesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'mergedExercisesJson');
    });
  }

  QueryBuilder<BB2MergedDay, DateTime?, QQueryOperations>
      plannerUpdatedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'plannerUpdatedAt');
    });
  }

  QueryBuilder<BB2MergedDay, int, QQueryOperations> schemaVersionProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'schemaVersion');
    });
  }

  QueryBuilder<BB2MergedDay, String, QQueryOperations> uidProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'uid');
    });
  }

  QueryBuilder<BB2MergedDay, int, QQueryOperations> weekIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'weekIndex');
    });
  }

  QueryBuilder<BB2MergedDay, DateTime?, QQueryOperations>
      workoutsUpdatedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'workoutsUpdatedAt');
    });
  }
}
