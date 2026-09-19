/// Typed, immutable view models for Block Planner 2.
library;

import '../exercise_catalog.dart';
import 'bp2_date_utils.dart';

/// One catalogue entry (shared or athlete-custom) as shown by the planner.
class Bp2Exercise {
  final String id;
  final String name;
  final String category;
  final String bodyPart;
  final ExerciseSource source;

  /// True when a template referenced this id/name but the catalogue could not
  /// resolve it. The row stays visible (canonical fallback) rather than being
  /// dropped, so a block is never silently corrupted.
  final bool unresolvedReference;

  const Bp2Exercise({
    required this.id,
    required this.name,
    required this.category,
    required this.bodyPart,
    required this.source,
    this.unresolvedReference = false,
  });

  factory Bp2Exercise.fromCatalog(CatalogExercise e) => Bp2Exercise(
        id: e.id,
        name: e.name,
        category: e.category,
        bodyPart: e.bodyPart,
        source: e.source,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'bodyPart': bodyPart,
        'source': source == ExerciseSource.custom ? 'custom' : 'global',
      };

  factory Bp2Exercise.fromJson(Map<String, dynamic> m) => Bp2Exercise(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        category: (m['category'] ?? '').toString(),
        bodyPart: (m['bodyPart'] ?? '').toString(),
        source: m['source'] == 'custom'
            ? ExerciseSource.custom
            : ExerciseSource.global,
      );

  @override
  bool operator ==(Object other) =>
      other is Bp2Exercise &&
      other.id == id &&
      other.name == name &&
      other.category == category &&
      other.bodyPart == bodyPart &&
      other.source == source &&
      other.unresolvedReference == unresolvedReference;

  @override
  int get hashCode =>
      Object.hash(id, name, category, bodyPart, source, unresolvedReference);
}

/// Lightweight block summary used for grouping and the block picker.
class Bp2BlockSummary {
  final String id;
  final String name;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool isActive;

  const Bp2BlockSummary({
    required this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.isActive,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'startDate': startDate?.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'isActive': isActive,
      };

  factory Bp2BlockSummary.fromJson(Map<String, dynamic> m) => Bp2BlockSummary(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        startDate: m['startDate'] is String
            ? DateTime.tryParse(m['startDate'] as String)
            : null,
        endDate: m['endDate'] is String
            ? DateTime.tryParse(m['endDate'] as String)
            : null,
        isActive: m['isActive'] == true,
      );
}

/// A template's exercise references. Each ref carries the raw id and name
/// exactly as stored so legacy name-only rows can still be resolved.
class Bp2TemplateRef {
  final String exerciseId;
  final String name;
  const Bp2TemplateRef({required this.exerciseId, required this.name});

  Map<String, dynamic> toJson() => {'exerciseId': exerciseId, 'name': name};
  factory Bp2TemplateRef.fromJson(Map<String, dynamic> m) => Bp2TemplateRef(
        exerciseId: (m['exerciseId'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
      );
}

class Bp2TemplateSummary {
  final String id;
  final String? blockId;
  final List<Bp2TemplateRef> refs;

  const Bp2TemplateSummary({
    required this.id,
    required this.blockId,
    required this.refs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'blockId': blockId,
        'refs': refs.map((r) => r.toJson()).toList(),
      };

  factory Bp2TemplateSummary.fromJson(Map<String, dynamic> m) =>
      Bp2TemplateSummary(
        id: (m['id'] ?? '').toString(),
        blockId: m['blockId'] as String?,
        refs: ((m['refs'] as List?) ?? const [])
            .whereType<Map>()
            .map((r) => Bp2TemplateRef.fromJson(Map<String, dynamic>.from(r)))
            .toList(),
      );
}

/// Result of the pure classification step.
class Bp2Grouping {
  final List<Bp2Exercise> currentBlock;
  final List<Bp2Exercise> otherBlocks;
  final List<Bp2Exercise> allOther;

  const Bp2Grouping({
    required this.currentBlock,
    required this.otherBlocks,
    required this.allOther,
  });

  static const empty =
      Bp2Grouping(currentBlock: [], otherBlocks: [], allOther: []);

  int get total => currentBlock.length + otherBlocks.length + allOther.length;
}

/// The full block document as the planner needs it.
class Bp2BlockRecord {
  final String id;
  final String name;
  final Bp2DateRange range;
  final bool isActive;

  /// Canonical `exerciseSettings` map for this block (exerciseId → settings).
  final Map<String, Map<String, dynamic>> exerciseSettings;

  /// True when the document exists on the server (or in Firestore's offline
  /// queue); false for an unsaved new draft.
  final bool existsRemotely;

  const Bp2BlockRecord({
    required this.id,
    required this.name,
    required this.range,
    required this.isActive,
    required this.exerciseSettings,
    required this.existsRemotely,
  });

  Bp2BlockRecord copyWith({
    String? name,
    Bp2DateRange? range,
    bool? isActive,
    Map<String, Map<String, dynamic>>? exerciseSettings,
    bool? existsRemotely,
  }) =>
      Bp2BlockRecord(
        id: id,
        name: name ?? this.name,
        range: range ?? this.range,
        isActive: isActive ?? this.isActive,
        exerciseSettings: exerciseSettings ?? this.exerciseSettings,
        existsRemotely: existsRemotely ?? this.existsRemotely,
      );
}

/// Synchronisation status surfaced as a small non-blocking banner.
enum Bp2SyncState { idle, syncing, offlineQueued, error }

class Bp2SyncStatus {
  final Bp2SyncState state;
  final String? message;
  const Bp2SyncStatus(this.state, [this.message]);

  static const idle = Bp2SyncStatus(Bp2SyncState.idle);
  static const syncing = Bp2SyncStatus(Bp2SyncState.syncing);
}
