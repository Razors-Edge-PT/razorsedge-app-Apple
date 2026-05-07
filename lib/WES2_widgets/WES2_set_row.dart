import 'package:flutter/material.dart';
import '../WES2_models.dart';
import 'WES2_field_cell.dart';

const _kHeaderStyle = TextStyle(
  fontSize: 10.0,
  color: Colors.white70,
  fontWeight: FontWeight.bold,
);

/// Column-label row rendered once above the first set row, matching WES layout.
/// Widths: Weight=76, Reps=50, RIR=50, E1RM=55, Vel.=45.
class Wes2SetColumnHeaders extends StatelessWidget {
  final bool showVelocity;

  const Wes2SetColumnHeaders({super.key, required this.showVelocity});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: 40), // aligns with set-label column
        const SizedBox(
          width: 76,
          child: Padding(
            padding: EdgeInsets.only(left: 3),
            child: Text('Weight', style: _kHeaderStyle),
          ),
        ),
        const SizedBox(width: 4),
        const SizedBox(
          width: 50,
          child: Padding(
            padding: EdgeInsets.only(left: 2),
            child: Text('Reps', style: _kHeaderStyle),
          ),
        ),
        const SizedBox(width: 4),
        const SizedBox(
          width: 50,
          child: Padding(
            padding: EdgeInsets.only(left: 3),
            child: Text('RIR', style: _kHeaderStyle),
          ),
        ),
        const SizedBox(width: 4),
        const SizedBox(
          width: 55,
          child: Text('E1RM', style: _kHeaderStyle),
        ),
        if (showVelocity) ...[
          const SizedBox(width: 4),
          const SizedBox(
            width: 45,
            child: Text('Vel.', style: _kHeaderStyle),
          ),
        ],
      ],
    );
  }
}

/// One data set row: set-number label + display cells for weight/reps/RIR/E1RM
/// and optionally velocity. E1RM is a static '—' placeholder (Phase 5).
class Wes2SetRow extends StatelessWidget {
  final Wes2SetState set;
  final bool showVelocity;

  const Wes2SetRow({super.key, required this.set, required this.showVelocity});

  static String _fmtWeight(double v) =>
      v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static String _fmtInt(int v) => v.toString();

  static String _fmtDouble(double v) => v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Set label — bottom-aligned to match field cell baseline
          SizedBox(
            width: 40,
            height: 36,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  'Set ${set.setIndex + 1}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.0,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ),
          Wes2FieldCell<double>(
            field: set.weight,
            width: 76,
            format: _fmtWeight,
          ),
          const SizedBox(width: 4),
          Wes2FieldCell<int>(
            field: set.reps,
            width: 50,
            format: _fmtInt,
          ),
          const SizedBox(width: 4),
          Wes2FieldCell<double>(
            field: set.rir,
            width: 50,
            format: _fmtDouble,
          ),
          const SizedBox(width: 4),
          // E1RM — static '—' placeholder; matches WES display-only cell style
          SizedBox(
            width: 55,
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
                child: const Text(
                  '—', // em dash
                  strutStyle: StrutStyle(
                    fontSize: 12,
                    height: 1.0,
                    forceStrutHeight: true,
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.0,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ),
          if (showVelocity) ...[
            const SizedBox(width: 4),
            Wes2FieldCell<double>(
              field: set.velocity,
              width: 45,
              format: _fmtDouble,
            ),
          ],
        ],
      ),
    );
  }
}
