// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'isar_claude_bullet_snapshot.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetClaudeBulletSnapshotCollection on Isar {
  IsarCollection<ClaudeBulletSnapshot> get claudeBulletSnapshots =>
      this.collection();
}

const ClaudeBulletSnapshotSchema = CollectionSchema(
  name: r'ClaudeBulletSnapshot',
  id: -2523306501280984785,
  properties: {
    r'cachedAt': PropertySchema(
      id: 0,
      name: r'cachedAt',
      type: IsarType.dateTime,
    ),
    r'dateYmd': PropertySchema(
      id: 1,
      name: r'dateYmd',
      type: IsarType.string,
    ),
    r'lastEditedAt': PropertySchema(
      id: 2,
      name: r'lastEditedAt',
      type: IsarType.long,
    ),
    r'snapshotJson': PropertySchema(
      id: 3,
      name: r'snapshotJson',
      type: IsarType.string,
    ),
    r'uidDateKey': PropertySchema(
      id: 4,
      name: r'uidDateKey',
      type: IsarType.string,
    ),
    r'workoutName': PropertySchema(
      id: 5,
      name: r'workoutName',
      type: IsarType.string,
    )
  },
  estimateSize: _claudeBulletSnapshotEstimateSize,
  serialize: _claudeBulletSnapshotSerialize,
  deserialize: _claudeBulletSnapshotDeserialize,
  deserializeProp: _claudeBulletSnapshotDeserializeProp,
  idName: r'id',
  indexes: {
    r'dateYmd': IndexSchema(
      id: -1092129815763616414,
      name: r'dateYmd',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'dateYmd',
          type: IndexType.hash,
          caseSensitive: true,
        )
      ],
    )
  },
  links: {},
  embeddedSchemas: {},
  getId: _claudeBulletSnapshotGetId,
  getLinks: _claudeBulletSnapshotGetLinks,
  attach: _claudeBulletSnapshotAttach,
  version: '3.3.2',
);

int _claudeBulletSnapshotEstimateSize(
  ClaudeBulletSnapshot object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.dateYmd.length * 3;
  bytesCount += 3 + object.snapshotJson.length * 3;
  bytesCount += 3 + object.uidDateKey.length * 3;
  {
    final value = object.workoutName;
    if (value != null) {
      bytesCount += 3 + value.length * 3;
    }
  }
  return bytesCount;
}

void _claudeBulletSnapshotSerialize(
  ClaudeBulletSnapshot object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeDateTime(offsets[0], object.cachedAt);
  writer.writeString(offsets[1], object.dateYmd);
  writer.writeLong(offsets[2], object.lastEditedAt);
  writer.writeString(offsets[3], object.snapshotJson);
  writer.writeString(offsets[4], object.uidDateKey);
  writer.writeString(offsets[5], object.workoutName);
}

ClaudeBulletSnapshot _claudeBulletSnapshotDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = ClaudeBulletSnapshot();
  object.cachedAt = reader.readDateTime(offsets[0]);
  object.dateYmd = reader.readString(offsets[1]);
  object.id = id;
  object.lastEditedAt = reader.readLong(offsets[2]);
  object.snapshotJson = reader.readString(offsets[3]);
  object.uidDateKey = reader.readString(offsets[4]);
  object.workoutName = reader.readStringOrNull(offsets[5]);
  return object;
}

P _claudeBulletSnapshotDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readDateTime(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    case 2:
      return (reader.readLong(offset)) as P;
    case 3:
      return (reader.readString(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readStringOrNull(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _claudeBulletSnapshotGetId(ClaudeBulletSnapshot object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _claudeBulletSnapshotGetLinks(
    ClaudeBulletSnapshot object) {
  return [];
}

void _claudeBulletSnapshotAttach(
    IsarCollection<dynamic> col, Id id, ClaudeBulletSnapshot object) {
  object.id = id;
}

extension ClaudeBulletSnapshotByIndex on IsarCollection<ClaudeBulletSnapshot> {
  Future<ClaudeBulletSnapshot?> getByDateYmd(String dateYmd) {
    return getByIndex(r'dateYmd', [dateYmd]);
  }

  ClaudeBulletSnapshot? getByDateYmdSync(String dateYmd) {
    return getByIndexSync(r'dateYmd', [dateYmd]);
  }

  Future<bool> deleteByDateYmd(String dateYmd) {
    return deleteByIndex(r'dateYmd', [dateYmd]);
  }

  bool deleteByDateYmdSync(String dateYmd) {
    return deleteByIndexSync(r'dateYmd', [dateYmd]);
  }

  Future<List<ClaudeBulletSnapshot?>> getAllByDateYmd(
      List<String> dateYmdValues) {
    final values = dateYmdValues.map((e) => [e]).toList();
    return getAllByIndex(r'dateYmd', values);
  }

  List<ClaudeBulletSnapshot?> getAllByDateYmdSync(List<String> dateYmdValues) {
    final values = dateYmdValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'dateYmd', values);
  }

  Future<int> deleteAllByDateYmd(List<String> dateYmdValues) {
    final values = dateYmdValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'dateYmd', values);
  }

  int deleteAllByDateYmdSync(List<String> dateYmdValues) {
    final values = dateYmdValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'dateYmd', values);
  }

  Future<Id> putByDateYmd(ClaudeBulletSnapshot object) {
    return putByIndex(r'dateYmd', object);
  }

  Id putByDateYmdSync(ClaudeBulletSnapshot object, {bool saveLinks = true}) {
    return putByIndexSync(r'dateYmd', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByDateYmd(List<ClaudeBulletSnapshot> objects) {
    return putAllByIndex(r'dateYmd', objects);
  }

  List<Id> putAllByDateYmdSync(List<ClaudeBulletSnapshot> objects,
      {bool saveLinks = true}) {
    return putAllByIndexSync(r'dateYmd', objects, saveLinks: saveLinks);
  }
}

extension ClaudeBulletSnapshotQueryWhereSort
    on QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QWhere> {
  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterWhere>
      anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension ClaudeBulletSnapshotQueryWhere
    on QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QWhereClause> {
  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterWhereClause>
      idEqualTo(Id id) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(
        lower: id,
        upper: id,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterWhereClause>
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterWhereClause>
      idGreaterThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterWhereClause>
      idLessThan(Id id, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterWhereClause>
      idBetween(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterWhereClause>
      dateYmdEqualTo(String dateYmd) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IndexWhereClause.equalTo(
        indexName: r'dateYmd',
        value: [dateYmd],
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterWhereClause>
      dateYmdNotEqualTo(String dateYmd) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'dateYmd',
              lower: [],
              upper: [dateYmd],
              includeUpper: false,
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'dateYmd',
              lower: [dateYmd],
              includeLower: false,
              upper: [],
            ));
      } else {
        return query
            .addWhereClause(IndexWhereClause.between(
              indexName: r'dateYmd',
              lower: [dateYmd],
              includeLower: false,
              upper: [],
            ))
            .addWhereClause(IndexWhereClause.between(
              indexName: r'dateYmd',
              lower: [],
              upper: [dateYmd],
              includeUpper: false,
            ));
      }
    });
  }
}

extension ClaudeBulletSnapshotQueryFilter on QueryBuilder<ClaudeBulletSnapshot,
    ClaudeBulletSnapshot, QFilterCondition> {
  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> cachedAtEqualTo(DateTime value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'cachedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> cachedAtGreaterThan(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> cachedAtLessThan(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> cachedAtBetween(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> dateYmdEqualTo(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> dateYmdGreaterThan(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> dateYmdLessThan(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> dateYmdBetween(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> dateYmdStartsWith(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> dateYmdEndsWith(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
          QAfterFilterCondition>
      dateYmdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'dateYmd',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
          QAfterFilterCondition>
      dateYmdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'dateYmd',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> dateYmdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'dateYmd',
        value: '',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> dateYmdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'dateYmd',
        value: '',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> idEqualTo(Id value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'id',
        value: value,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> idGreaterThan(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> idLessThan(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> idBetween(
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

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> lastEditedAtEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'lastEditedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> lastEditedAtGreaterThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'lastEditedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> lastEditedAtLessThan(
    int value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'lastEditedAt',
        value: value,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> lastEditedAtBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'lastEditedAt',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> snapshotJsonEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'snapshotJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> snapshotJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'snapshotJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> snapshotJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'snapshotJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> snapshotJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'snapshotJson',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> snapshotJsonStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'snapshotJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> snapshotJsonEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'snapshotJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
          QAfterFilterCondition>
      snapshotJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'snapshotJson',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
          QAfterFilterCondition>
      snapshotJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'snapshotJson',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> snapshotJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'snapshotJson',
        value: '',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> snapshotJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'snapshotJson',
        value: '',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> uidDateKeyEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'uidDateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> uidDateKeyGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'uidDateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> uidDateKeyLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'uidDateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> uidDateKeyBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'uidDateKey',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> uidDateKeyStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'uidDateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> uidDateKeyEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'uidDateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
          QAfterFilterCondition>
      uidDateKeyContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'uidDateKey',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
          QAfterFilterCondition>
      uidDateKeyMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'uidDateKey',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> uidDateKeyIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'uidDateKey',
        value: '',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> uidDateKeyIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'uidDateKey',
        value: '',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameIsNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNull(
        property: r'workoutName',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameIsNotNull() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(const FilterCondition.isNotNull(
        property: r'workoutName',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameEqualTo(
    String? value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'workoutName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameGreaterThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        include: include,
        property: r'workoutName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameLessThan(
    String? value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.lessThan(
        include: include,
        property: r'workoutName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameBetween(
    String? lower,
    String? upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.between(
        property: r'workoutName',
        lower: lower,
        includeLower: includeLower,
        upper: upper,
        includeUpper: includeUpper,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameStartsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.startsWith(
        property: r'workoutName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameEndsWith(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.endsWith(
        property: r'workoutName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
          QAfterFilterCondition>
      workoutNameContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.contains(
        property: r'workoutName',
        value: value,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
          QAfterFilterCondition>
      workoutNameMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.matches(
        property: r'workoutName',
        wildcard: pattern,
        caseSensitive: caseSensitive,
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.equalTo(
        property: r'workoutName',
        value: '',
      ));
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot,
      QAfterFilterCondition> workoutNameIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(FilterCondition.greaterThan(
        property: r'workoutName',
        value: '',
      ));
    });
  }
}

extension ClaudeBulletSnapshotQueryObject on QueryBuilder<ClaudeBulletSnapshot,
    ClaudeBulletSnapshot, QFilterCondition> {}

extension ClaudeBulletSnapshotQueryLinks on QueryBuilder<ClaudeBulletSnapshot,
    ClaudeBulletSnapshot, QFilterCondition> {}

extension ClaudeBulletSnapshotQuerySortBy
    on QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QSortBy> {
  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByCachedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByDateYmd() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateYmd', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByDateYmdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateYmd', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByLastEditedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastEditedAt', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByLastEditedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastEditedAt', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortBySnapshotJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'snapshotJson', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortBySnapshotJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'snapshotJson', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByUidDateKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uidDateKey', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByUidDateKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uidDateKey', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByWorkoutName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'workoutName', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      sortByWorkoutNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'workoutName', Sort.desc);
    });
  }
}

extension ClaudeBulletSnapshotQuerySortThenBy
    on QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QSortThenBy> {
  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByCachedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'cachedAt', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByDateYmd() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateYmd', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByDateYmdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'dateYmd', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByLastEditedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastEditedAt', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByLastEditedAtDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'lastEditedAt', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenBySnapshotJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'snapshotJson', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenBySnapshotJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'snapshotJson', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByUidDateKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uidDateKey', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByUidDateKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'uidDateKey', Sort.desc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByWorkoutName() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'workoutName', Sort.asc);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QAfterSortBy>
      thenByWorkoutNameDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'workoutName', Sort.desc);
    });
  }
}

extension ClaudeBulletSnapshotQueryWhereDistinct
    on QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QDistinct> {
  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QDistinct>
      distinctByCachedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'cachedAt');
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QDistinct>
      distinctByDateYmd({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'dateYmd', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QDistinct>
      distinctByLastEditedAt() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'lastEditedAt');
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QDistinct>
      distinctBySnapshotJson({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'snapshotJson', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QDistinct>
      distinctByUidDateKey({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'uidDateKey', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, ClaudeBulletSnapshot, QDistinct>
      distinctByWorkoutName({bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'workoutName', caseSensitive: caseSensitive);
    });
  }
}

extension ClaudeBulletSnapshotQueryProperty on QueryBuilder<
    ClaudeBulletSnapshot, ClaudeBulletSnapshot, QQueryProperty> {
  QueryBuilder<ClaudeBulletSnapshot, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, DateTime, QQueryOperations>
      cachedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'cachedAt');
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, String, QQueryOperations>
      dateYmdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'dateYmd');
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, int, QQueryOperations>
      lastEditedAtProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'lastEditedAt');
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, String, QQueryOperations>
      snapshotJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'snapshotJson');
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, String, QQueryOperations>
      uidDateKeyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'uidDateKey');
    });
  }

  QueryBuilder<ClaudeBulletSnapshot, String?, QQueryOperations>
      workoutNameProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'workoutName');
    });
  }
}
