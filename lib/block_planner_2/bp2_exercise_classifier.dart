/// Pure catalogue merge + template-derived grouping for Block Planner 2.
///
/// No I/O. Identity is always the canonical exercise document id; display
/// names are used only as a legacy fallback when a template row carries no id.
library;

import '../exercise_catalog.dart';
import 'bp2_models.dart';

class Bp2ExerciseClassifier {
  Bp2ExerciseClassifier._();

  /// Case-insensitive name order with the stable id as deterministic
  /// tie-breaker.
  static int compare(Bp2Exercise a, Bp2Exercise b) {
    final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (c != 0) return c;
    return a.id.compareTo(b.id);
  }

  /// Deduplicated, alphabetised union of the shared catalogue and the selected
  /// athlete's custom exercises. When an id appears in both pools the shared
  /// entry wins (custom docs can never shadow a global id).
  static List<Bp2Exercise> mergeCatalogue({
    required Iterable<CatalogExercise> shared,
    required Iterable<CatalogExercise> custom,
  }) {
    final byId = <String, Bp2Exercise>{};
    for (final e in custom) {
      if (e.id.isEmpty) continue;
      byId[e.id] = Bp2Exercise.fromCatalog(e);
    }
    for (final e in shared) {
      if (e.id.isEmpty) continue;
      byId[e.id] = Bp2Exercise.fromCatalog(e);
    }
    final list = byId.values.toList()..sort(compare);
    return list;
  }

  /// Resolves one template reference against the catalogue.
  ///
  /// Order: canonical id → exact (case-insensitive) name → unresolved
  /// fallback row that keeps the reference visible.
  static Bp2Exercise? resolveRef(
    Bp2TemplateRef ref, {
    required Map<String, Bp2Exercise> byId,
    required Map<String, Bp2Exercise> byLowerName,
  }) {
    final id = ref.exerciseId.trim();
    final name = ref.name.trim();
    if (id.isNotEmpty && id != name) {
      final hit = byId[id];
      if (hit != null) return hit;
    }
    if (name.isNotEmpty) {
      final hit = byLowerName[name.toLowerCase()];
      if (hit != null) return hit;
    }
    if (id.isNotEmpty || name.isNotEmpty) {
      final fallbackId = id.isNotEmpty ? id : name;
      return Bp2Exercise(
        id: fallbackId,
        name: name.isNotEmpty ? name : id,
        category: '',
        bodyPart: '',
        source: ExerciseSource.global,
        unresolvedReference: true,
      );
    }
    return null;
  }

  /// Splits [catalogue] into the three display groups.
  ///
  /// * `currentBlock` — union of exercises in templates whose `blockId` equals
  ///   [activeBlockId] (the canonical active-block pointer).
  /// * `otherBlocks`  — union of exercises in templates connected to any block
  ///   in [otherBlockIds], minus anything already in `currentBlock`.
  /// * `allOther`     — every remaining catalogue exercise.
  ///
  /// Templates with no block are not template-derived groups and contribute
  /// nothing. Unresolvable references are kept visible as fallback rows.
  static Bp2Grouping classify({
    required List<Bp2Exercise> catalogue,
    required List<Bp2TemplateSummary> templates,
    required String? activeBlockId,
    required Set<String> otherBlockIds,
  }) {
    final byId = <String, Bp2Exercise>{for (final e in catalogue) e.id: e};
    final byLowerName = <String, Bp2Exercise>{};
    for (final e in catalogue) {
      // First alphabetical/id-ordered entry wins for duplicate names.
      byLowerName.putIfAbsent(e.name.toLowerCase(), () => e);
    }

    final current = <String, Bp2Exercise>{};
    final other = <String, Bp2Exercise>{};

    for (final t in templates) {
      final blockId = t.blockId;
      if (blockId == null || blockId.isEmpty) continue;
      final isCurrent = activeBlockId != null && blockId == activeBlockId;
      final isOther = !isCurrent && otherBlockIds.contains(blockId);
      if (!isCurrent && !isOther) continue;
      for (final ref in t.refs) {
        final ex = resolveRef(ref, byId: byId, byLowerName: byLowerName);
        if (ex == null) continue;
        if (isCurrent) {
          current[ex.id] = ex;
        } else {
          other[ex.id] = ex;
        }
      }
    }
    for (final id in current.keys) {
      other.remove(id);
    }

    final rest = catalogue
        .where((e) => !current.containsKey(e.id) && !other.containsKey(e.id))
        .toList();

    return Bp2Grouping(
      currentBlock: current.values.toList()..sort(compare),
      otherBlocks: other.values.toList()..sort(compare),
      allOther: rest..sort(compare),
    );
  }
}
