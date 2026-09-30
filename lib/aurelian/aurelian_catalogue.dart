/// How voice names catalogue exercises: the same names the Add Exercise picker
/// shows, with a custom exercise that shares a catalogue name told apart
/// ("(custom)") rather than merged.
library;

import '../exercise_catalog.dart';

String catalogueName(CatalogExercise e) => e.name.isNotEmpty ? e.name : e.id;

/// The label a voice "which one?" offers for [e] among [all].
String catalogueVoiceLabel(CatalogExercise e, Iterable<CatalogExercise> all) {
  final String name = catalogueName(e);
  final bool shared = all.any(
      (CatalogExercise o) => o.name == e.name && o.id != e.id);
  return shared && e.source == ExerciseSource.custom ? '$name (custom)' : name;
}
