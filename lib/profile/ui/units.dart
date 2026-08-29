/// Weight and date presentation for the showcase.
///
/// CANONICAL STORAGE IS KILOGRAMS. Every record — the E1RM, the heaviest load,
/// the fingerprint's weight component — is computed and persisted in kg on both
/// the client and the server. This class converts for DISPLAY only, so changing
/// a user's preferred unit can never change a stored record, a fingerprint, or
/// which set holds a record.
library;

import 'package:intl/intl.dart';

/// The unit a profile is displayed in.
enum WeightUnit { kg, lb }

class WeightUnits {
  const WeightUnits(this.unit);

  /// The app has always displayed and stored training loads in kilograms;
  /// this is the default for every account that has not chosen otherwise.
  static const WeightUnits kilograms = WeightUnits(WeightUnit.kg);
  static const WeightUnits pounds = WeightUnits(WeightUnit.lb);

  final WeightUnit unit;

  static const double _kgPerLb = 0.45359237;

  /// Reads the preference from a user document. Anything unrecognised — and
  /// the overwhelmingly common case of the field being absent — is kilograms.
  static WeightUnits fromUserData(Map<String, dynamic>? data) {
    final Object? raw = data?['weightUnit'];
    if (raw is String) {
      final String v = raw.trim().toLowerCase();
      if (v == 'lb' || v == 'lbs' || v == 'pound' || v == 'pounds') {
        return pounds;
      }
    }
    return kilograms;
  }

  String get suffix => unit == WeightUnit.lb ? 'lb' : 'kg';

  /// Converts a canonical kilogram value for display.
  double convert(double kg) => unit == WeightUnit.lb ? kg / _kgPerLb : kg;

  /// "180 kg", "182.5 kg", "400 lb". Trailing ".0" is dropped so whole numbers
  /// read as whole numbers.
  String format(double kg) {
    final double value = convert(kg);
    final String text = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text $suffix';
  }

  /// A record's `YYYY-MM-DD` date key, rendered for humans. Falls back to the
  /// raw key rather than showing nothing if it is ever malformed.
  String formatDate(String dateKey) {
    final DateTime? parsed = DateTime.tryParse(dateKey);
    if (parsed == null) return dateKey;
    return DateFormat('d MMM yyyy').format(parsed);
  }
}
