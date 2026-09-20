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
  /// Width of the cell; the dead strip matches it exactly, so the inert gaps
  /// between cells stay inert.
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
