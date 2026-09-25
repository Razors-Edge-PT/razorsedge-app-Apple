/// Which unit each of an athlete's exercises is shown in.
///
/// The setting lives in the athlete's own `exerciseSettings[exerciseId]
/// .weightUnit` (planned block), edited from Block Planner 2 and the WES2
/// settings cog. The server publishes each explicit choice — only the 'kg' /
/// 'lb' value — to `users_public/{uid}.exerciseWeightUnits`, which anyone
/// allowed to see the profile can read. So a friend always sees the OWNER's
/// unit for each exercise, never their own.
///
/// Effective unit for an exercise, most specific first:
///   1. a choice made on this device this session (shown at once, before the
///      server has published it — and offline)
///   2. the explicit value in the block being viewed/edited
///   3. the owner's published choice (their last explicit choice, which also
///      carries a unit into a new block that has none yet)
///   4. kilograms
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'weight_unit.dart';

/// The field on users_public holding the published units.
const String kPublicExerciseUnitsField = 'exerciseWeightUnits';

/// One athlete's resolved units.
@immutable
class ExerciseUnits {
  const ExerciseUnits({
    this.blockSettings = const <String, dynamic>{},
    this.published = const <String, ExerciseWeightUnit>{},
    this.local = const <String, ExerciseWeightUnit>{},
  });

  /// Everything in kilograms — legacy profiles and every unset exercise.
  static const ExerciseUnits kilograms = ExerciseUnits();

  /// The block's `exerciseSettings` map (exerciseId → settings).
  final Map<String, dynamic> blockSettings;

  /// users_public.exerciseWeightUnits, parsed.
  final Map<String, ExerciseWeightUnit> published;

  /// Choices made on this device this session.
  final Map<String, ExerciseWeightUnit> local;

  /// The unit [exerciseId]'s loads are shown and entered in.
  ExerciseWeightUnit unitFor(String? exerciseId) {
    if (exerciseId == null || exerciseId.isEmpty) return ExerciseWeightUnit.kg;
    final ExerciseWeightUnit? mine = local[exerciseId];
    if (mine != null) return mine;
    final Object? settings = blockSettings[exerciseId];
    if (settings is Map) {
      final ExerciseWeightUnit? explicit =
          ExerciseWeightUnit.parseOrNull(settings[kWeightUnitField]);
      if (explicit != null) return explicit;
    }
    return published[exerciseId] ?? ExerciseWeightUnit.kg;
  }

  ExerciseUnits withBlockSettings(Map<String, dynamic>? settings) =>
      ExerciseUnits(
        blockSettings: settings ?? const <String, dynamic>{},
        published: published,
        local: local,
      );

  /// Parses users_public.exerciseWeightUnits; invalid entries are dropped.
  static Map<String, ExerciseWeightUnit> parsePublished(Object? raw) {
    final Map<String, ExerciseWeightUnit> out = <String, ExerciseWeightUnit>{};
    if (raw is! Map) return out;
    raw.forEach((Object? k, Object? v) {
      final ExerciseWeightUnit? u = ExerciseWeightUnit.parseOrNull(v);
      if (k is String && u != null) out[k] = u;
    });
    return out;
  }
}

/// Keeps each viewed athlete's published units current, and this device's own
/// just-made choices, for every screen that shows an exercise's loads.
class ExerciseUnitRegistry extends ChangeNotifier {
  ExerciseUnitRegistry({FirebaseFirestore? firestore}) : _firestore = firestore;

  static ExerciseUnitRegistry shared = ExerciseUnitRegistry();

  final FirebaseFirestore? _firestore;
  final Map<String, Map<String, ExerciseWeightUnit>> _published =
      <String, Map<String, ExerciseWeightUnit>>{};
  final Map<String, Map<String, ExerciseWeightUnit>> _local =
      <String, Map<String, ExerciseWeightUnit>>{};
  final Map<String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>
      _subs =
      <String, StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>>{};

  /// [uid]'s units (starting a live watch on first use).
  ExerciseUnits unitsFor(String uid, {Map<String, dynamic>? blockSettings}) {
    if (uid.isEmpty) {
      return ExerciseUnits.kilograms.withBlockSettings(blockSettings);
    }
    ensureWatching(uid);
    return ExerciseUnits(
      blockSettings: blockSettings ?? const <String, dynamic>{},
      published: _published[uid] ?? const <String, ExerciseWeightUnit>{},
      local: _local[uid] ?? const <String, ExerciseWeightUnit>{},
    );
  }

  /// Records a choice the owner just saved here, so every screen reflects it
  /// immediately (and offline) — the server publishes it in the background.
  void noteLocalChoice(String uid, String exerciseId, ExerciseWeightUnit unit) {
    (_local[uid] ??= <String, ExerciseWeightUnit>{})[exerciseId] = unit;
    notifyListeners();
  }

  /// Seeds published units directly (tests, and a caller that already holds
  /// the users_public document).
  void seedPublished(String uid, Object? raw) {
    _published[uid] = ExerciseUnits.parsePublished(raw);
    notifyListeners();
  }

  void ensureWatching(String uid) {
    if (_subs.containsKey(uid)) return;
    FirebaseFirestore db;
    try {
      db = _firestore ?? FirebaseFirestore.instance;
    } catch (_) {
      return; // No Firebase (unit tests): published units stay as seeded.
    }
    _subs[uid] = db.collection('users_public').doc(uid).snapshots().listen(
      (DocumentSnapshot<Map<String, dynamic>> snap) {
        final Map<String, ExerciseWeightUnit> next =
            ExerciseUnits.parsePublished(
                snap.data()?[kPublicExerciseUnitsField]);
        if (mapEquals(next, _published[uid])) return;
        _published[uid] = next;
        notifyListeners();
      },
      onError: (Object _) {},
    );
  }

  @override
  void dispose() {
    for (final StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> s
        in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    super.dispose();
  }
}
