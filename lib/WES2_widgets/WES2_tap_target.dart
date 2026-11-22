import 'package:flutter/material.dart';

/// Height of the WES2 set-row cell area (matches the trailing icon slots).
const double kWes2CellTapHeight = 48;

/// Height of a visible editable cell inside that area.
const double kWes2CellVisibleHeight = 36;

/// Gives a bottom-aligned [child] of [kWes2CellVisibleHeight] the full
/// [kWes2CellTapHeight] of the row as its tap target, without moving,
/// resizing or restyling it.
///
/// The row is 48 high while its editable cells are 36 and sit on the bottom
/// edge, so ~12 logical pixels above each cell were dead. Those pixels become
/// an invisible sibling ABOVE the child rather than a wrapper around it, which
/// matters: nothing is layered over the editor, so cursor placement,
/// selection, long press, double tap, keyboard input and any ancestor
/// horizontal drag keep working exactly as before — the dead strip simply
/// forwards a tap to [onTap]. It is excluded from semantics so screen readers
/// still see one control per cell, not two.
class Wes2CellTapTarget extends StatelessWidget {
  /// Width of the cell; the dead strip matches it exactly. The gaps between
  /// cells are owned separately by [Wes2CellGapTapTarget].
  final double width;

  /// Invoked for a tap in the dead strip — normally "focus my editor".
  final VoidCallback onTap;

  /// Optional long press, for cells whose visible child handles one.
  final VoidCallback? onLongPress;

  /// The unchanged, bottom-aligned visible cell.
  final Widget child;

  const Wes2CellTapTarget({
    super.key,
    required this.width,
    required this.onTap,
    required this.child,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: kWes2CellTapHeight,
      child: Column(
        children: [
          Expanded(
            child: ExcludeSemantics(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                onLongPress: onLongPress,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Width of the gap between neighbouring WES2 set-row cells. Unchanged by the
/// tap-target work; it is only given an owner.
const double kWes2CellGapWidth = 4;

/// Occupies the existing [kWes2CellGapWidth] gap between two set-row cells and
/// hands its dead pixels to the editable cell(s) either side, without moving,
/// resizing or restyling anything.
///
/// It is the horizontal counterpart of [Wes2CellTapTarget], built on the same
/// rule: the dead space becomes an invisible SIBLING of the visible cells, laid
/// out exactly where the plain gap box used to be, never a wrapper or overlay
/// on top of an editor. So each TextField still owns every pixel it owned
/// before — cursor placement, selection, long press, the double tap that
/// accepts a hint, and the card's horizontal drag all behave as before — and a
/// tap in the gap simply forwards to the neighbour's [onTapLeading] /
/// [onTapTrailing].
///
/// The gap is split into two disjoint strips, so two cells can never answer
/// the same tap:
/// * both neighbours editable → each gets half;
/// * only one editable (the other read-only, such as E1RM) → it gets it all;
/// * [leadingWidth] overrides the split, e.g. to leave a half that borders a
///   non-text control (the timed cell) inert.
///
/// It is [kWes2CellTapHeight] tall — the height every set row already has — so
/// the row's height is unchanged. Excluded from semantics: screen readers still
/// see one control per cell.
class Wes2CellGapTapTarget extends StatelessWidget {
  /// Focuses the cell to the LEFT of the gap; null leaves that side inert.
  final VoidCallback? onTapLeading;

  /// Focuses the cell to the RIGHT of the gap; null leaves that side inert.
  final VoidCallback? onTapTrailing;

  /// Width given to the leading strip. Defaults to half the gap when both
  /// sides are editable, the whole gap when only the leading one is, else 0.
  final double? leadingWidth;

  /// Total width: the gap being replaced.
  final double width;

  const Wes2CellGapTapTarget({
    super.key,
    this.onTapLeading,
    this.onTapTrailing,
    this.leadingWidth,
    this.width = kWes2CellGapWidth,
  });

  double get _leading {
    final double? explicit = leadingWidth;
    if (explicit != null) return explicit.clamp(0.0, width);
    if (onTapLeading == null) return 0;
    return onTapTrailing == null ? width : width / 2;
  }

  static Widget _strip(double width, VoidCallback? onTap) => SizedBox(
        width: width,
        height: kWes2CellTapHeight,
        child: onTap == null
            ? null
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: const SizedBox.expand(),
              ),
      );

  @override
  Widget build(BuildContext context) {
    final double leading = _leading;
    final double trailing = width - leading;
    return SizedBox(
      width: width,
      height: kWes2CellTapHeight,
      child: ExcludeSemantics(
        child: Row(
          children: <Widget>[
            if (leading > 0) _strip(leading, onTapLeading),
            if (trailing > 0) _strip(trailing, onTapTrailing),
          ],
        ),
      ),
    );
  }
}
