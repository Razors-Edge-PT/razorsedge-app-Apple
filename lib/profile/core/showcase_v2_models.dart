/// The profile showcase as five CATEGORIES of approved exercises, each with
/// its own lifetime records and RE Points.
///
/// Read from `users_public/{uid}.profileShowcaseV2`, maintained server-side by
/// functions/showcase/store_v2.js BESIDE profileShowcaseV1. When V2 is absent
/// or malformed (an account not yet rebuilt), [ProfileShowcaseV2.resolve]
/// falls back to the V1 snapshot, presented through the same categories with
/// just the one V1 lift in each and no points — exactly what V1 showed.
///
/// One shape, one selection rule, for every viewer: the owner, a friend, and
/// a cached/offline profile all go through [ProfileShowcaseV2] and
/// [ShowcaseCategorySnapshot.defaultExercise]. Picking another exercise in the
/// UI is presentation state only — nothing here is written.
library;

import 'big_five.dart';
import 're_catalog.dart';
import 'showcase_models.dart';

/// Schema of the V2 snapshot.
const String kProfileShowcaseV2Schema = 'profileShowcaseV2';

/// One exercise inside a category: its records (possibly none) and points.
class ShowcaseExerciseSnapshot {
  const ShowcaseExerciseSnapshot({
    required this.exercise,
    required this.records,
    this.rePoints,
    this.pointsRecord,
  });

  /// A configured exercise with no result yet.
  factory ShowcaseExerciseSnapshot.placeholder(ReExercise exercise) =>
      ShowcaseExerciseSnapshot(
        exercise: exercise,
        records: ShowcaseLiftSnapshot(slot: exercise.slot),
      );

  final ReExercise exercise;

  /// The lifetime Best E1RM and Heaviest records, keyed by [ReExercise.slot]
  /// exactly as V1 records are keyed by their lift slot.
  final ShowcaseLiftSnapshot records;

  /// The exercise's lifetime Best RE Points. Null when unavailable — no
  /// bodyweight recorded on or before any of its sets, or a V1 fallback —
  /// which is NOT zero.
  final double? rePoints;

  /// The set that scored [rePoints] — selected INDEPENDENTLY of Best E1RM:
  /// every set is scored, so a lighter set at a lower bodyweight can hold it.
  /// Carries its own date, set identity and fingerprint (for its proof).
  final ShowcaseRecord? pointsRecord;

  /// True when the points set is a different set from both other records, so
  /// the card shows its source and proof separately.
  bool get pointsSetIsDistinct {
    final String? fp = pointsRecord?.fingerprint;
    if (fp == null) return false;
    return fp != bestE1rm?.fingerprint && fp != heaviest?.fingerprint;
  }
  String get exerciseId => exercise.exerciseId;
  bool get hasRecord => !records.isEmpty;
  ShowcaseRecord? get bestE1rm => records.bestE1rm;
  ShowcaseRecord? get heaviest => records.heaviest;
  bool get sharesOneSource => records.sharesOneSource;
}

/// One category card's data: every configured exercise, in catalogue order,
/// and which one is shown by default.
class ShowcaseCategorySnapshot {
  const ShowcaseCategorySnapshot({
    required this.category,
    required this.exercises,
    required this.defaultExerciseId,
  });

  final ReCategory category;

  /// Selectable exercises in catalogue (preference) order. Untrained ones are
  /// placeholders with no records.
  final List<ShowcaseExerciseSnapshot> exercises;

  /// The highest scorer (see [selectDefaultExerciseId]).
  final String defaultExerciseId;

  /// More than one exercise can be displayed — the card offers a dropdown.
  bool get hasChoice => exercises.length > 1;

  ShowcaseExerciseSnapshot get defaultExercise =>
      exerciseById(defaultExerciseId) ?? exercises.first;

  ShowcaseExerciseSnapshot? exerciseById(String? exerciseId) {
    if (exerciseId == null) return null;
    for (final ShowcaseExerciseSnapshot e in exercises) {
      if (e.exerciseId == exerciseId) return e;
    }
    return null;
  }

  static ShowcaseCategorySnapshot build(
    ReCategory category,
    List<ShowcaseExerciseSnapshot> exercises,
  ) {
    final Map<String, ShowcaseExerciseSnapshot> byId =
        <String, ShowcaseExerciseSnapshot>{
      for (final ShowcaseExerciseSnapshot e in exercises) e.exerciseId: e,
    };
    final String defaultId = selectDefaultExerciseId(
          category.key,
          hasRecord: (String id) => byId[id]?.hasRecord ?? false,
          pointsOf: (String id) => byId[id]?.rePoints,
        ) ??
        exercises.first.exerciseId;
    // A V1 fallback category holds only its V1 lift; the catalogue's primary
    // may not be among them.
    final String shown =
        byId.containsKey(defaultId) ? defaultId : exercises.first.exerciseId;
    return ShowcaseCategorySnapshot(
      category: category,
      exercises: exercises,
      defaultExerciseId: shown,
    );
  }
}

/// The five categories, in display order.
class ProfileShowcaseV2 {
  const ProfileShowcaseV2({
    required this.categories,
    this.isV1Fallback = false,
  });

  final List<ShowcaseCategorySnapshot> categories;

  /// True when built from profileShowcaseV1 because V2 was absent/malformed:
  /// points are not known and are not shown.
  final bool isV1Fallback;

  bool get showsPoints => !isV1Fallback;

  /// Every fingerprint standing as a live record in any category. A proof
  /// whose fingerprint is absent from this set is stale.
  Set<String> get liveFingerprints => <String>{
        for (final ShowcaseCategorySnapshot c in categories)
          for (final ShowcaseExerciseSnapshot e in c.exercises) ...<String>[
            if (e.bestE1rm != null) e.bestE1rm!.fingerprint,
            if (e.heaviest != null) e.heaviest!.fingerprint,
            if (e.pointsRecord != null) e.pointsRecord!.fingerprint,
          ],
      };

  /// The exercise whose records are keyed by [slot], or null.
  ShowcaseExerciseSnapshot? exerciseBySlot(String slot) {
    for (final ShowcaseCategorySnapshot c in categories) {
      for (final ShowcaseExerciseSnapshot e in c.exercises) {
        if (e.exercise.slot == slot) return e;
      }
    }
    return null;
  }

  /// V2 when [rawV2] is a valid snapshot, otherwise the V1 fallback.
  static ProfileShowcaseV2 resolve(Object? rawV2, ProfileShowcase v1) =>
      fromMap(rawV2) ?? fromV1(v1);

  /// Parses `profileShowcaseV2`. Returns null when it is absent or malformed,
  /// so the caller can fall back to V1. Individual malformed entries are
  /// skipped rather than failing the whole snapshot.
  static ProfileShowcaseV2? fromMap(Object? raw) {
    if (raw is! Map) return null;
    if (raw['schema'] != kProfileShowcaseV2Schema) return null;
    final Object? cats = raw['categories'];
    if (cats is! Map) return null;

    final List<ShowcaseCategorySnapshot> out = <ShowcaseCategorySnapshot>[];
    for (final ReCategory cat in kReCategories) {
      final Object? rawCat = cats[cat.key];
      final Object? rawExercises = rawCat is Map ? rawCat['exercises'] : null;
      final List<ShowcaseExerciseSnapshot> exercises =
          <ShowcaseExerciseSnapshot>[];
      for (final ReExercise def in reExercisesOfCategory(cat.key)) {
        final Object? e =
            rawExercises is Map ? rawExercises[def.exerciseId] : null;
        exercises.add(_exerciseFromMap(def, e));
      }
      out.add(ShowcaseCategorySnapshot.build(cat, exercises));
    }
    return ProfileShowcaseV2(categories: out);
  }

  static ShowcaseExerciseSnapshot _exerciseFromMap(ReExercise def, Object? e) {
    if (e is! Map) return ShowcaseExerciseSnapshot.placeholder(def);
    final ShowcaseLiftSnapshot records =
        ShowcaseLiftSnapshot.fromMap(def.slot, e);
    // A record must belong to this exercise's slot; anything else is ignored.
    final ShowcaseRecord? best =
        records.bestE1rm?.slot == def.slot ? records.bestE1rm : null;
    final ShowcaseRecord? heavy =
        records.heaviest?.slot == def.slot ? records.heaviest : null;
    final ShowcaseRecord? pointsRaw = ShowcaseRecord.fromMap(e['points']);
    final ShowcaseRecord? pointsRec =
        pointsRaw?.slot == def.slot ? pointsRaw : null;
    final Object? p = e['rePoints'];
    return ShowcaseExerciseSnapshot(
      exercise: def,
      records:
          ShowcaseLiftSnapshot(slot: def.slot, bestE1rm: best, heaviest: heavy),
      // Points belong to their own record; without one they are unavailable.
      rePoints:
          (p is num && p.isFinite && pointsRec != null) ? p.toDouble() : null,
      pointsRecord: pointsRec,
    );
  }

  /// The V1 snapshot through the category component: each category holds only
  /// its V1 lift, with no points — the display V1 always had.
  static ProfileShowcaseV2 fromV1(ProfileShowcase v1) {
    final List<ShowcaseCategorySnapshot> out = <ShowcaseCategorySnapshot>[];
    for (final ReCategory cat in kReCategories) {
      final List<ShowcaseExerciseSnapshot> exercises =
          <ShowcaseExerciseSnapshot>[
        for (final ReExercise def in reExercisesOfCategory(cat.key))
          if (bigFiveBySlot(def.slot) != null)
            ShowcaseExerciseSnapshot(
                exercise: def, records: v1.forSlot(def.slot)),
      ];
      if (exercises.isEmpty) continue;
      out.add(ShowcaseCategorySnapshot.build(cat, exercises));
    }
    return ProfileShowcaseV2(categories: out, isV1Fallback: true);
  }
}

/// RE Points as displayed: two decimals.
String formatRePoints(double points) => points.toStringAsFixed(2);
