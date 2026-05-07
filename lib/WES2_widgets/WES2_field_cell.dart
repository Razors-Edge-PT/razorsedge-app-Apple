import 'package:flutter/material.dart';
import '../WES2_models.dart';

/// Read-only display cell that visually matches a WES TextField with
/// UnderlineInputBorder. Uses the same Container + bottom-border + Text
/// pattern that WES uses for its display-only E1RM column.
///
/// actualValue → white, normal weight (logged data)
/// hintValue   → grey italic (BB3-planned intent, not logged)
/// neither     → empty string; bottom border still visible
///
/// T is bounded to Object so null checks on T? narrow correctly.
class Wes2FieldCell<T extends Object> extends StatelessWidget {
  final Wes2FieldState<T> field;
  final double width;
  final String Function(T) format;

  const Wes2FieldCell({
    super.key,
    required this.field,
    required this.width,
    required this.format,
  });

  @override
  Widget build(BuildContext context) {
    final String text;
    final TextStyle style;

    final actual = field.actualValue;
    final hint = field.hintValue;

    if (actual != null) {
      text = format(actual);
      style = const TextStyle(
        color: Colors.white,
        fontSize: 12,
        height: 1.0,
      );
    } else if (hint != null) {
      text = format(hint);
      style = const TextStyle(
        color: Colors.grey,
        fontStyle: FontStyle.italic,
        fontSize: 12,
        height: 1.0,
      );
    } else {
      text = '';
      style = const TextStyle(fontSize: 12, height: 1.0);
    }

    return SizedBox(
      width: width,
      height: 36,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Container(
          height: 36,
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.white, width: 1),
            ),
          ),
          alignment: Alignment.bottomLeft,
          child: Text(
            text,
            strutStyle: const StrutStyle(
              fontSize: 12,
              height: 1.0,
              forceStrutHeight: true,
            ),
            style: style,
          ),
        ),
      ),
    );
  }
}
