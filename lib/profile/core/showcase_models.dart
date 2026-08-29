import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'big_five.dart';
import 'e1rm_spec.dart';

/// Schema version of the compact snapshot mirrored into `users_public`.
/// Bump when the mirrored SHAPE changes (not when the E1RM curve changes —
/// that is [kE1rmFormulaVersion]).
const String kProfileShowcaseSchema = 'profileShowcaseV1';

/// The two lifetime achievements shown per lift.
class ShowcaseRecordKind {
  static const String e1rm = 'e1rm';
  static const String heaviest = 'heaviest';
}

/// A single completed set, normalised out of a workout document.
class ShowcaseSet {
  const ShowcaseSet({
    required this.setKey,
    required this.weight,
    required this.reps,
  });

  /// Stable identity of this set inside its day: the row's own set id when the
  /// document carries one, otherwise the deterministic `r{row}s{set}` index.
  final String setKey;
  final double weight;
  final int reps;

  double get e1rm => showcaseE1rm(weight, reps);
}

/// One lifetime record with full provenance back to the exact source set.
class ShowcaseRecord {
  const ShowcaseRecord({
    required this.slot,
    required this.exerciseId,
    required this.dateKey,
    required this.setKey,
    required this.weight,
    required this.reps,
    required this.e1rm,
    required this.formulaVersion,
    required this.fingerprint,
  });

  final String slot;

  /// Catalogue exercise id in its best-known original casing.
  final String exerciseId;

  /// `YYYY-MM-DD` workout document id.
  final String dateKey;
  final String setKey;
  final double weight;
  final int reps;
  final double e1rm;
  final int formulaVersion;

  /// Stable key identifying the SOURCE PERFORMANCE (see [recordFingerprint]).
  final String fingerprint;

  Map<String, Object?> toMap() => <String, Object?>{
        'slot': slot,
        'exerciseId': exerciseId,
        'dateKey': dateKey,
        'setKey': setKey,
        'weight': weight,
        'reps': reps,
        'e1rm': e1rm,
        'formulaVersion': formulaVersion,
        'fingerprint': fingerprint,
      };

  static ShowcaseRecord? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final Object? slot = raw['slot'];
    final Object? fp = raw['fingerprint'];
    if (slot is! String || fp is! String) return null;
    return ShowcaseRecord(
      slot: slot,
      exerciseId: (raw['exerciseId'] as String?) ?? '',
      dateKey: (raw['dateKey'] as String?) ?? '',
      setKey: (raw['setKey'] as String?) ?? '',
      weight: (raw['weight'] as num?)?.toDouble() ?? 0,
      reps: (raw['reps'] as num?)?.toInt() ?? 0,
      e1rm: (raw['e1rm'] as num?)?.toDouble() ?? 0,
      formulaVersion: (raw['formulaVersion'] as num?)?.toInt() ?? 0,
      fingerprint: fp,
    );
  }
}

/// Everything shown for one lift.
class ShowcaseLiftSnapshot {
  const ShowcaseLiftSnapshot(
      {required this.slot, this.bestE1rm, this.heaviest});

  final String slot;
  final ShowcaseRecord? bestE1rm;
  final ShowcaseRecord? heaviest;

  bool get isEmpty => bestE1rm == null && heaviest == null;

  /// True when one uploaded video can stand as proof of both achievements.
  bool get sharesOneSource =>
      bestE1rm != null &&
      heaviest != null &&
      bestE1rm!.fingerprint == heaviest!.fingerprint;

  BigFiveLift? get lift => bigFiveBySlot(slot);

  Map<String, Object?> toMap() => <String, Object?>{
        'slot': slot,
        if (bestE1rm != null) ShowcaseRecordKind.e1rm: bestE1rm!.toMap(),
        if (heaviest != null) ShowcaseRecordKind.heaviest: heaviest!.toMap(),
      };

  static ShowcaseLiftSnapshot fromMap(String slot, Object? raw) {
    if (raw is! Map) return ShowcaseLiftSnapshot(slot: slot);
    return ShowcaseLiftSnapshot(
      slot: slot,
      bestE1rm: ShowcaseRecord.fromMap(raw[ShowcaseRecordKind.e1rm]),
      heaviest: ShowcaseRecord.fromMap(raw[ShowcaseRecordKind.heaviest]),
    );
  }
}

/// The compact, presentation-ready Big Five snapshot mirrored into
/// `users_public/{uid}.profileShowcaseV1`.
class ProfileShowcase {
  const ProfileShowcase({
    required this.lifts,
    this.schema = kProfileShowcaseSchema,
    this.formulaVersion = kE1rmFormulaVersion,
    this.updatedAtMs,
  });

  final Map<String, ShowcaseLiftSnapshot> lifts;
  final String schema;
  final int formulaVersion;
  final int? updatedAtMs;

  static const ProfileShowcase empty =
      ProfileShowcase(lifts: <String, ShowcaseLiftSnapshot>{});

  ShowcaseLiftSnapshot forSlot(String slot) =>
      lifts[slot] ?? ShowcaseLiftSnapshot(slot: slot);

  bool get hasAnything =>
      lifts.values.any((ShowcaseLiftSnapshot s) => !s.isEmpty);

  /// Every fingerprint currently standing as a live record. A proof whose
  /// fingerprint is absent from this set is stale and must not be displayed.
  Set<String> get liveFingerprints => <String>{
        for (final ShowcaseLiftSnapshot s in lifts.values) ...<String>[
          if (s.bestE1rm != null) s.bestE1rm!.fingerprint,
          if (s.heaviest != null) s.heaviest!.fingerprint,
        ],
      };

  Map<String, Object?> toMap() => <String, Object?>{
        'schema': schema,
        'formulaVersion': formulaVersion,
        'lifts': <String, Object?>{
          for (final MapEntry<String, ShowcaseLiftSnapshot> e in lifts.entries)
            e.key: e.value.toMap(),
        },
      };

  static ProfileShowcase fromMap(Object? raw) {
    if (raw is! Map) return ProfileShowcase.empty;
    final Object? lifts = raw['lifts'];
    final Map<String, ShowcaseLiftSnapshot> out =
        <String, ShowcaseLiftSnapshot>{};
    if (lifts is Map) {
      for (final String slot in BigFiveSlot.ordered) {
        final Object? v = lifts[slot];
        if (v == null) continue;
        final ShowcaseLiftSnapshot snap = ShowcaseLiftSnapshot.fromMap(slot, v);
        if (!snap.isEmpty) out[slot] = snap;
      }
    }
    final Object? updated = raw['updatedAtMs'];
    return ProfileShowcase(
      lifts: out,
      schema: (raw['schema'] as String?) ?? kProfileShowcaseSchema,
      formulaVersion:
          (raw['formulaVersion'] as num?)?.toInt() ?? kE1rmFormulaVersion,
      updatedAtMs: updated is num ? updated.toInt() : null,
    );
  }
}

/// Deterministic fingerprint of a SOURCE PERFORMANCE.
///
/// Deliberately covers only what identifies the performance itself — slot,
/// folded exercise id, date, set identity, weight and reps. It does NOT include
/// the E1RM value, the formula version, or which of the two achievements the
/// record satisfies, because:
///
///   * one video must be able to prove BOTH achievements when they come from
///     the same set, and
///   * bumping the E1RM curve must not orphan every attached proof.
///
/// Editing the source set's weight or reps DOES change the fingerprint, which
/// is exactly the behaviour that retires a proof for a record that no longer
/// exists.
String recordFingerprint({
  required String slot,
  required String exerciseId,
  required String dateKey,
  required String setKey,
  required double weight,
  required int reps,
}) {
  // Weight is canonicalised to 3 decimal places so float representation noise
  // can never produce two fingerprints for one performance.
  final String payload = <String>[
    slot,
    exerciseId.toLowerCase(),
    dateKey,
    setKey,
    weight.toStringAsFixed(3),
    reps.toString(),
  ].join('|');
  return sha256.convert(utf8.encode(payload)).toString().substring(0, 32);
}
