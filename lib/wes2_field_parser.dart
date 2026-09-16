/// One parser for every WES2 numeric entry point.
///
/// Before this existed, each path used `double.tryParse` / `int.tryParse`
/// directly, which accepts values a set field must never hold:
///   • `NaN`, `Infinity`, `-Infinity` — they became real actuals and then fed
///     the E1RM cascade;
///   • `1e3` and `0x10` — exponent and hex forms no keypad can produce, and
///     which nobody typing 1000 or 16 intended.
///
/// The rules are deliberately narrow: plain decimal digits, an optional single
/// leading `-`, one optional `.`, and the result must be finite. A partially
/// typed value such as `22.` is VALID and parses to 22 — the athlete is still
/// typing and the model must follow along. `-` and `.` alone are invalid: they
/// are not a number yet, so the model keeps whatever it had.
library;

import 'WES2_models.dart';

enum Wes2ParseKind { empty, valid, invalid }

class Wes2ParseResult<T extends num> {
  const Wes2ParseResult._(this.kind, this.value);

  const Wes2ParseResult.empty() : this._(Wes2ParseKind.empty, null);
  const Wes2ParseResult.invalid() : this._(Wes2ParseKind.invalid, null);
  const Wes2ParseResult.valid(T value) : this._(Wes2ParseKind.valid, value);

  final Wes2ParseKind kind;
  final T? value;

  bool get isEmpty => kind == Wes2ParseKind.empty;
  bool get isValid => kind == Wes2ParseKind.valid;
  bool get isInvalid => kind == Wes2ParseKind.invalid;
}

class Wes2FieldParser {
  Wes2FieldParser._();

  /// `12`, `12.`, `12.5`, `.5`, `-2.5` — nothing else.
  static final RegExp _decimal = RegExp(r'^-?(\d+\.?\d*|\.\d+)$');

  /// Reps are whole and non-negative. `08` is fine; `8.`, `0x10`, `1e3` are not.
  static final RegExp _integer = RegExp(r'^\d+$');

  static Wes2ParseResult<num> parse(Wes2FieldKey key, String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return const Wes2ParseResult<num>.empty();

    if (key == Wes2FieldKey.reps) {
      if (!_integer.hasMatch(text)) return const Wes2ParseResult<num>.invalid();
      final int? v = int.tryParse(text);
      if (v == null) return const Wes2ParseResult<num>.invalid();
      return Wes2ParseResult<num>.valid(v);
    }

    if (!_decimal.hasMatch(text)) return const Wes2ParseResult<num>.invalid();
    final double? v = double.tryParse(text);
    if (v == null || !v.isFinite) return const Wes2ParseResult<num>.invalid();
    return Wes2ParseResult<num>.valid(v);
  }

  /// The value for a repository/mutation payload: null for empty (an explicit
  /// clear) and null for invalid, which callers must treat as "do not save".
  static Object? valueOrNull(Wes2FieldKey key, String raw) {
    final Wes2ParseResult<num> r = parse(key, raw);
    if (!r.isValid) return null;
    return key == Wes2FieldKey.reps ? r.value!.toInt() : r.value!.toDouble();
  }

  /// True when non-empty text cannot be saved. Empty text is a clear, not an
  /// error, so it is NOT invalid.
  static bool isInvalidEntry(Wes2FieldKey key, String raw) =>
      parse(key, raw).isInvalid;
}
