import 'package:flutter/material.dart';
import '../WES2_models.dart';

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

class Wes2SetRow extends StatefulWidget {
  final Wes2SetState set;
  final bool showVelocity;
  final void Function(Wes2FieldKey fieldKey, String rawText) onFieldChanged;
  final void Function(Wes2FieldKey fieldKey, String rawText) onFieldUnfocused;

  const Wes2SetRow({
    super.key,
    required this.set,
    required this.showVelocity,
    required this.onFieldChanged,
    required this.onFieldUnfocused,
  });

  @override
  State<Wes2SetRow> createState() => _Wes2SetRowState();
}

class _Wes2SetRowState extends State<Wes2SetRow> {
  late TextEditingController _weightCtrl;
  late TextEditingController _repsCtrl;
  late TextEditingController _rirCtrl;
  late TextEditingController _velocityCtrl;
  late FocusNode _weightFocus;
  late FocusNode _repsFocus;
  late FocusNode _rirFocus;
  late FocusNode _velocityFocus;

  static String _fmtWeight(double v) =>
      v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  static String _fmtInt(int v) => v.toString();
  static String _fmtDouble(double v) => v.toStringAsFixed(1);

  static String _fromActual<T extends Object>(
    Wes2FieldState<T> f,
    String Function(T) fmt,
  ) {
    final v = f.actualValue;
    return v != null ? fmt(v) : '';
  }

  @override
  void initState() {
    super.initState();
    _weightCtrl = TextEditingController(
      text: _fromActual(widget.set.weight, _fmtWeight),
    );
    _repsCtrl = TextEditingController(
      text: _fromActual(widget.set.reps, _fmtInt),
    );
    _rirCtrl = TextEditingController(
      text: _fromActual(widget.set.rir, _fmtDouble),
    );
    _velocityCtrl = TextEditingController(
      text: _fromActual(widget.set.velocity, _fmtDouble),
    );
    _weightFocus = FocusNode()..addListener(_onWeightFocusChange);
    _repsFocus = FocusNode()..addListener(_onRepsFocusChange);
    _rirFocus = FocusNode()..addListener(_onRirFocusChange);
    _velocityFocus = FocusNode()..addListener(_onVelocityFocusChange);
  }

  void _onWeightFocusChange() {
    if (!_weightFocus.hasFocus) {
      widget.onFieldUnfocused(Wes2FieldKey.weight, _weightCtrl.text);
    }
  }

  void _onRepsFocusChange() {
    if (!_repsFocus.hasFocus) {
      widget.onFieldUnfocused(Wes2FieldKey.reps, _repsCtrl.text);
    }
  }

  void _onRirFocusChange() {
    if (!_rirFocus.hasFocus) {
      widget.onFieldUnfocused(Wes2FieldKey.rir, _rirCtrl.text);
    }
  }

  void _onVelocityFocusChange() {
    if (!_velocityFocus.hasFocus) {
      widget.onFieldUnfocused(Wes2FieldKey.velocity, _velocityCtrl.text);
    }
  }

  @override
  void didUpdateWidget(covariant Wes2SetRow old) {
    super.didUpdateWidget(old);
    _sync(
      _weightCtrl,
      _weightFocus,
      old.set.weight.actualValue,
      widget.set.weight.actualValue,
      _fmtWeight,
    );
    _sync(
      _repsCtrl,
      _repsFocus,
      old.set.reps.actualValue,
      widget.set.reps.actualValue,
      _fmtInt,
    );
    _sync(
      _rirCtrl,
      _rirFocus,
      old.set.rir.actualValue,
      widget.set.rir.actualValue,
      _fmtDouble,
    );
    _sync(
      _velocityCtrl,
      _velocityFocus,
      old.set.velocity.actualValue,
      widget.set.velocity.actualValue,
      _fmtDouble,
    );
  }

  void _sync<T extends Object>(
    TextEditingController ctrl,
    FocusNode focus,
    T? oldV,
    T? newV,
    String Function(T) fmt,
  ) {
    if (oldV == newV) return;
    if (focus.hasFocus) return; // never interrupt active typing
    final t = newV != null ? fmt(newV) : '';
    if (ctrl.text != t) ctrl.text = t;
  }

  @override
  void dispose() {
    // Remove listeners before disposing FocusNodes.
    _weightFocus.removeListener(_onWeightFocusChange);
    _repsFocus.removeListener(_onRepsFocusChange);
    _rirFocus.removeListener(_onRirFocusChange);
    _velocityFocus.removeListener(_onVelocityFocusChange);
    _weightCtrl.dispose();
    _repsCtrl.dispose();
    _rirCtrl.dispose();
    _velocityCtrl.dispose();
    _weightFocus.dispose();
    _repsFocus.dispose();
    _rirFocus.dispose();
    _velocityFocus.dispose();
    super.dispose();
  }

  static const _kFieldStyle = TextStyle(color: Colors.white, fontSize: 12);
  static const _kHintStyle = TextStyle(
    color: Colors.grey,
    fontStyle: FontStyle.italic,
    fontSize: 12,
  );
  static const _kEnabledBorder = UnderlineInputBorder(
    borderSide: BorderSide(color: Colors.white, width: 1),
  );
  static const _kFocusedBorder = UnderlineInputBorder(
    borderSide: BorderSide(color: Colors.white, width: 1.5),
  );
  static const _kContentPadding = EdgeInsets.only(left: 2);

  Widget _field({
    required TextEditingController ctrl,
    required FocusNode focus,
    required Wes2FieldKey fieldKey,
    required String? hintText,
    required double width,
    bool decimal = false,
  }) {
    return SizedBox(
      width: width,
      height: 36,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: TextField(
          controller: ctrl,
          focusNode: focus,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          decoration: InputDecoration(
            contentPadding: _kContentPadding,
            hintText: hintText,
            hintStyle: _kHintStyle,
            enabledBorder: _kEnabledBorder,
            focusedBorder: _kFocusedBorder,
            isDense: true,
          ),
          onChanged: (v) => widget.onFieldChanged(fieldKey, v),
          style: _kFieldStyle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.set;
    final weightHint =
        s.weight.hintValue != null ? _fmtWeight(s.weight.hintValue!) : null;
    final repsHint =
        s.reps.hintValue != null ? _fmtInt(s.reps.hintValue!) : null;
    final rirHint =
        s.rir.hintValue != null ? _fmtDouble(s.rir.hintValue!) : null;
    final velocityHint =
        s.velocity.hintValue != null ? _fmtDouble(s.velocity.hintValue!) : null;

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Set label — bottom-aligned to match field baseline
          SizedBox(
            width: 40,
            height: 36,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text(
                  'Set ${s.setIndex + 1}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.0,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ),
          _field(
            ctrl: _weightCtrl,
            focus: _weightFocus,
            fieldKey: Wes2FieldKey.weight,
            hintText: weightHint,
            width: 76,
            decimal: true,
          ),
          const SizedBox(width: 4),
          _field(
            ctrl: _repsCtrl,
            focus: _repsFocus,
            fieldKey: Wes2FieldKey.reps,
            hintText: repsHint,
            width: 50,
          ),
          const SizedBox(width: 4),
          _field(
            ctrl: _rirCtrl,
            focus: _rirFocus,
            fieldKey: Wes2FieldKey.rir,
            hintText: rirHint,
            width: 50,
            decimal: true,
          ),
          const SizedBox(width: 4),
          // E1RM — static '—' placeholder; computed in a later phase
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
                  '—',
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
          if (widget.showVelocity) ...[
            const SizedBox(width: 4),
            _field(
              ctrl: _velocityCtrl,
              focus: _velocityFocus,
              fieldKey: Wes2FieldKey.velocity,
              hintText: velocityHint,
              width: 45,
              decimal: true,
            ),
          ],
        ],
      ),
    );
  }
}
