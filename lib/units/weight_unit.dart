/// Per-exercise weight units — the ONE place loads are converted.
///
/// ── Canonical kilograms ─────────────────────────────────────────────────────
/// Every stored and computed load — workout sets, plans, increments, history,
/// E1RM, bodyweight-loaded totals, profile records, RE Points — is kilograms.
/// A unit only decides how an exercise's loads are SHOWN and ENTERED:
///
///   entered pounds  → [ExerciseWeightUnit.toKg] once, before storing/computing
///   stored kg       → [ExerciseWeightUnit.fromKg] once, for display
///
/// Nothing is ever stored in pounds, twice, or as a formatted string, and the
/// canonical kg value is never rounded here. Display text is rounded only when
/// formatted, so reopening and saving an unchanged pound value re-derives the
/// same kilograms — no cumulative drift.
///
/// APIs that take or return canonical loads say so in their names (`weightKg`,
/// [WeightKg]); display numbers travel as [DisplayWeight], which always
/// carries its unit, so a pound number cannot be compared with a kilogram one
/// by accident.
///
/// Pinned mirror of functions/showcase/weight_unit.js (the parser).
library;

import 'package:flutter/foundation.dart';

/// Exact: the international avoirdupois pound.
const double kKgPerLb = 0.45359237;

/// 1 / [kKgPerLb].
const double kLbPerKg = 2.2046226218487757;

/// The `exerciseSettings[exerciseId]` leaf that stores the unit.
const String kWeightUnitField = 'weightUnit';

/// The unit one exercise's loads are shown and entered in.
enum ExerciseWeightUnit {
  kg,
  lb;

  /// The stored value: 'kg' | 'lb'.
  String get storageValue => this == ExerciseWeightUnit.lb ? 'lb' : 'kg';

  /// The short label shown beside a number.
  String get suffix => storageValue;

  /// The choice shown in a selector.
  String get choiceLabel =>
      this == ExerciseWeightUnit.lb ? 'Pounds (lb)' : 'Kilograms (kg)';

  /// A display number in this unit → canonical kilograms.
  double toKg(double displayValue) =>
      this == ExerciseWeightUnit.lb ? displayValue * kKgPerLb : displayValue;

  /// Canonical kilograms → a display number in this unit.
  double fromKg(double weightKg) =>
      this == ExerciseWeightUnit.lb ? weightKg * kLbPerKg : weightKg;

  /// The unit for a stored value. Missing, null, malformed or legacy values
  /// are [fallback] — kilograms unless a caller has a better default.
  static ExerciseWeightUnit parse(Object? raw,
      {ExerciseWeightUnit fallback = ExerciseWeightUnit.kg}) {
    return parseOrNull(raw) ?? fallback;
  }

  /// The unit for a VALID stored value, else null.
  static ExerciseWeightUnit? parseOrNull(Object? raw) {
    if (raw is! String) return null;
    switch (raw.trim().toLowerCase()) {
      case 'kg':
        return ExerciseWeightUnit.kg;
      case 'lb':
        return ExerciseWeightUnit.lb;
    }
    return null;
  }
}

/// Trims a number for display: at most [maxDecimals] places, no trailing
/// zeros, no trailing point. 225.00000000000003 → "225", 16.25 → "16.25".
String formatWeightNumber(double value, {int maxDecimals = 3}) {
  if (!value.isFinite) return '';
  String t = value.toStringAsFixed(maxDecimals);
  if (t.contains('.')) {
    t = t.replaceFirst(RegExp(r'0+$'), '');
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  }
  if (t == '-0') t = '0';
  return t;
}

/// A canonical load.
@immutable
class WeightKg implements Comparable<WeightKg> {
  const WeightKg(this.kg);

  final double kg;

  /// This load in [unit], for display.
  DisplayWeight inUnit(ExerciseWeightUnit unit) =>
      DisplayWeight(unit.fromKg(kg), unit);

  WeightKg operator +(WeightKg other) => WeightKg(kg + other.kg);
  WeightKg operator -(WeightKg other) => WeightKg(kg - other.kg);
  WeightKg operator *(double factor) => WeightKg(kg * factor);

  @override
  int compareTo(WeightKg other) => kg.compareTo(other.kg);

  @override
  bool operator ==(Object other) => other is WeightKg && other.kg == kg;

  @override
  int get hashCode => kg.hashCode;

  @override
  String toString() => 'WeightKg($kg)';
}

/// A load expressed in a unit, as shown to (or typed by) a person. It always
/// carries its unit; comparing or storing it goes through [toKg].
@immutable
class DisplayWeight {
  const DisplayWeight(this.value, this.unit);

  /// Parses typed text in [unit]. Null for text that is not a number.
  static DisplayWeight? tryParse(String text, ExerciseWeightUnit unit) {
    final double? v = double.tryParse(text.trim());
    return v == null ? null : DisplayWeight(v, unit);
  }

  final double value;
  final ExerciseWeightUnit unit;

  WeightKg toKg() => WeightKg(unit.toKg(value));

  /// "225", "102.5" — the number only.
  String number({int maxDecimals = 3}) =>
      formatWeightNumber(value, maxDecimals: maxDecimals);

  /// "225 lb", "102.5 kg".
  String label({int maxDecimals = 1}) =>
      '${number(maxDecimals: maxDecimals)} ${unit.suffix}';

  @override
  bool operator ==(Object other) =>
      other is DisplayWeight && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => label(maxDecimals: 3);
}

/// Formats a canonical load for [unit]: "102.5 kg", "225 lb".
String formatWeightKg(double weightKg, ExerciseWeightUnit unit,
        {int maxDecimals = 1, bool withSuffix = true}) =>
    withSuffix
        ? WeightKg(weightKg).inUnit(unit).label(maxDecimals: maxDecimals)
        : WeightKg(weightKg).inUnit(unit).number(maxDecimals: maxDecimals);

/// Typed text in [unit] → canonical kilograms, or null when not a number.
double? parseDisplayToKg(String text, ExerciseWeightUnit unit) =>
    DisplayWeight.tryParse(text, unit)?.toKg().kg;

/// The safe path for any cross-exercise inference: read each exercise's
/// canonical loads, calculate in KILOGRAMS, and only then express the result
/// in the TARGET exercise's unit (labelled with it). The calculation never
/// sees a display number, so a pound value can never be compared with, or
/// scaled as, a kilogram one.
DisplayWeight deriveForExercise({
  required WeightKg source,
  required WeightKg Function(WeightKg sourceKg) calculateKg,
  required ExerciseWeightUnit targetUnit,
}) =>
    calculateKg(source).inUnit(targetUnit);
