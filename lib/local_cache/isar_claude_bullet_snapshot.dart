// lib/local_cache/isar_claude_bullet_snapshot.dart
//
// NEW Isar entity for Claude_bullet "resume-like" UI snapshot.
// Stores per-exercise, per-set visible state (typed vs hint vs empty)
// so WES can restore the exact page look within a 2-hour window.
//
// This is intentionally separate from existing WESInitSnapshot / BlockDay
// collections -- it captures UI truth (controller text + hint text) rather
// than data-model truth.

import 'package:isar/isar.dart';

part 'isar_claude_bullet_snapshot.g.dart';

@collection
class ClaudeBulletSnapshot {
  /// Stable Id derived from dateYmd (one snapshot per date).
  Id id = Isar.autoIncrement;

  /// "yyyy-MM-dd" of the workout day.
  @Index(unique: true, replace: true)
  late String dateYmd;
  late String uidDateKey;

  /// Epoch millis (UTC) of the last edit / save.
  late int lastEditedAt;

  /// Optional workout name shown in the header.
  String? workoutName;

  /// JSON-encoded payload containing the full per-exercise / per-set state.
  ///
  /// Structure:
  /// ```json
  /// {
  ///   "exercises": [
  ///     {
  ///       "instanceKey": "exerciseId|circuitIndex",
  ///       "exerciseId": "...",
  ///       "name": "...",
  ///       "circuitIndex": 0,
  ///       "sets": [
  ///         {
  ///           "setIdx": 0,
  ///           "weight": { "origin": "typed", "display": "66.5" },
  ///           "reps":   { "origin": "hint",  "display": "15" },
  ///           "rir":    { "origin": "hint",  "display": "2.5" },
  ///           "velocity": { "origin": "empty", "display": "" },
  ///           "notes":    { "origin": "empty", "display": "" }
  ///         }
  ///       ],
  ///       "set1_weight_num": 66.5,
  ///       "set1_reps_num": 15,
  ///       "set1_rir_num": 2.5,
  ///       "set1_weight_typed": false,
  ///       "set1_reps_typed": true,
  ///       "set1_rir_typed": true
  ///     }
  ///   ]
  /// }
  /// ```
  late String snapshotJson;

  /// When this snapshot was first created.
  DateTime cachedAt = DateTime.now();
}
