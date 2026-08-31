import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../WES2_models.dart';
import '../periodization_model_utils.dart';
import '../wes2_video/set_video_copy.dart';

/// Height of the trailing icon slots.
///
/// 48 is the platform-recommended minimum touch dimension. The row cannot also
/// be 48 WIDE per control — six columns at 48 overflows every phone narrower
/// than a tablet — so the target is 48 on the axis where there is room and
/// [kWes2RowIconSlotWidth] on the other. That is 28x48 rather than the former
/// 24x36 — not the full recommendation, but the largest that fits a dense
/// six-column row, and the whole cluster is NARROWER than the 86pt it replaced,
/// so the accessibility gain costs no horizontal room.
const double kWes2RowIconSlotHeight = 48;

/// Width of one trailing icon slot.
const double kWes2RowIconSlotWidth = 28;

/// Total width the trailing icon cluster reserves (remove + note + camera).
///
/// The column headers reserve the SAME width so the two stay aligned when the
/// flexible E1RM column narrows on a small screen. A header that did not
/// reserve it would drift out of line exactly when space is tightest.
const double kWes2RowTrailingWidth = kWes2RowIconSlotWidth * 3;

/// Wraps a row cell in [Flexible], but only where the row's width is bounded.
///
/// A [Flexible] inside a [Row] whose incoming width constraints are UNBOUNDED
/// asserts at layout time — which is exactly what happens when a set row is
/// placed inside a horizontal scrollable. Where the width is unbounded there is
/// by definition no shortage of space, so the cell simply keeps its natural
/// size and nothing needs to yield.
Widget flexibleWhenBounded({required bool bounded, required Widget child}) =>
    bounded ? Flexible(child: child) : child;

class _E1rmDisplay {
  final String text;
  final bool isActual; // true → white normal; false → grey
  final bool isHint;   // true → grey italic (projected); false → grey plain (dash)

  const _E1rmDisplay(this.text, {this.isActual = false, this.isHint = false});
}

const _kHeaderStyle = TextStyle(
  fontSize: 10.0,
  color: Colors.white70,
  fontWeight: FontWeight.bold,
);

/// Column-label row rendered once above the first set row, matching WES layout.
/// Widths: Weight=76, Reps=50, RIR=50, E1RM=55, Vel.=45.
/// Timed BW-only: BW=90, Time=70. Timed weighted: Weight=76, Time=70, E1RM=55.
class Wes2SetColumnHeaders extends StatelessWidget {
  final bool showVelocity;
  final Wes2ExerciseEntryMode entryMode;

  const Wes2SetColumnHeaders({
    super.key,
    required this.showVelocity,
    this.entryMode = Wes2ExerciseEntryMode.normal,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) =>
          _build(context, c.maxWidth.isFinite),
    );
  }

  Widget _build(BuildContext context, bool bounded) {
    if (entryMode == Wes2ExerciseEntryMode.timedBodyweight) {
      return const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 40),
          SizedBox(
            width: 90,
            child: Padding(
              padding: EdgeInsets.only(left: 3),
              child: Text('Weight', style: _kHeaderStyle),
            ),
          ),
          SizedBox(width: 4),
          SizedBox(
            width: 70,
            child: Padding(
              padding: EdgeInsets.only(left: 2),
              child: Text('Time', style: _kHeaderStyle),
            ),
          ),
          Spacer(),
          SizedBox(width: kWes2RowTrailingWidth),
        ],
      );
    }

    if (entryMode == Wes2ExerciseEntryMode.timedWeighted) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(width: 40),
          const SizedBox(
            width: 76,
            child: Padding(
              padding: EdgeInsets.only(left: 3),
              child: Text('Weight', style: _kHeaderStyle),
            ),
          ),
          const SizedBox(width: 4),
          const SizedBox(
            width: 70,
            child: Padding(
              padding: EdgeInsets.only(left: 2),
              child: Text('Time', style: _kHeaderStyle),
            ),
          ),
          const SizedBox(width: 4),
          flexibleWhenBounded(
            bounded: bounded,
            child: const SizedBox(
                width: 55, child: Text('E1RM', style: _kHeaderStyle)),
          ),
          const SizedBox(width: kWes2RowTrailingWidth),
        ],
      );
    }

    // Normal mode
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
        // Mirrors the row: the derived E1RM column is the one that yields.
        flexibleWhenBounded(
          bounded: bounded,
          child: const SizedBox(
            width: 55,
            child: Text('E1RM', style: _kHeaderStyle),
          ),
        ),
        if (showVelocity) ...[
          const SizedBox(width: 4),
          flexibleWhenBounded(
            bounded: bounded,
            child: const SizedBox(
              width: 45,
              child: Text('Vel.', style: _kHeaderStyle),
            ),
          ),
        ],
        const SizedBox(width: kWes2RowTrailingWidth),
      ],
    );
  }
}

class Wes2SetRow extends StatefulWidget {
  final Wes2SetState set;
  final bool showVelocity;
  final Wes2ExerciseEntryMode entryMode;
  /// Non-null only for timedBodyweight mode. Display-only; never saved as weight.
  final String? bwDisplayText;
  final void Function(Wes2FieldKey fieldKey, String rawText) onFieldChanged;
  final void Function(Wes2FieldKey fieldKey, String rawText) onFieldUnfocused;
  final VoidCallback? onRemoveSet;
  final VoidCallback? onNoteTap;

  /// Opens the set-video flow. Null hides the control entirely, which is how
  /// rows that cannot carry footage (a plan preview, a read-only view) opt out.
  final VoidCallback? onVideoTap;

  /// True when this set already has a recording attached. Drives the icon's
  /// filled state, its tooltip and its semantic label, so the state is
  /// announced rather than left to a colour difference alone.
  final bool hasVideo;

  final bool isPlanNoteRead;
  /// Phase 21F: original planned/model RIR hint captured at session load.
  /// Used to compute the green/amber direction cue on the RIR field.
  final double? baselineRirHint;
  /// Required only for timedWeighted E1RM display. Passed from the exercise card.
  final String? uid;
  final DateTime? selectedDate;
  /// Active tutorial step (1=weight, 2=reps, 3=RIR). 0 = inactive — no change
  /// to rendering. Only set on the first set row of the first exercise card.
  final int tutorialStep;
  /// Fires when the reps hint is double-tap accepted (field was empty + hint
  /// was filled). Only wired on the first set row when tutorial is at reps step.
  final VoidCallback? onTutorialRepsAccepted;

  const Wes2SetRow({
    super.key,
    required this.set,
    required this.showVelocity,
    this.entryMode = Wes2ExerciseEntryMode.normal,
    this.bwDisplayText,
    required this.onFieldChanged,
    required this.onFieldUnfocused,
    this.onRemoveSet,
    this.onNoteTap,
    this.onVideoTap,
    this.hasVideo = false,
    this.isPlanNoteRead = false,
    this.baselineRirHint,
    this.uid,
    this.selectedDate,
    this.tutorialStep = 0,
    this.onTutorialRepsAccepted,
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
  /// Velocity: preserve up to 3 decimal places, strip trailing zeros.
  /// 0.734 → "0.734", 0.700 → "0.7", 1.000 → "1".
  static String _fmtVelocity(double v) {
    final s = v.toStringAsFixed(3);
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

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
      text: _fromActual(widget.set.velocity, _fmtVelocity),
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
      _fmtVelocity,
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

  _E1rmDisplay _resolveE1rmDisplay(Wes2SetState set) {
    // Use the currently visible value for each field: actual if present, else hint.
    final currentWeight = set.weight.actualValue ?? set.weight.hintValue;
    final currentReps = set.reps.actualValue ?? set.reps.hintValue;
    if (currentWeight == null || currentReps == null) {
      return const _E1rmDisplay('—');
    }
    final currentRir = (set.rir.actualValue ?? set.rir.hintValue) ?? 0.0;
    final e1rm = PeriodizationModelUtils.calculateE1RM(
      currentWeight,
      currentReps.toDouble(),
      currentRir,
    );
    if (e1rm <= 0) return const _E1rmDisplay('—');
    // White/actual style only when all three fields are user-entered actuals.
    final isActual = set.weight.actualValue != null &&
        set.reps.actualValue != null &&
        set.rir.actualValue != null;
    return _E1rmDisplay(e1rm.toStringAsFixed(1), isActual: isActual, isHint: !isActual);
  }

  _E1rmDisplay _resolveTimedWeightedE1rmDisplay(Wes2SetState set) {
    final seconds = set.reps.actualValue ?? set.reps.hintValue;
    final addedKg = set.weight.actualValue ?? set.weight.hintValue;
    if (seconds == null || seconds <= 0 || addedKg == null || widget.uid == null) {
      return const _E1rmDisplay('—');
    }
    final bw = PeriodizationModelUtils.bodyweightKgForDate(
      uid: widget.uid!,
      asOf: widget.selectedDate,
    );
    final repEquivalent = seconds / 5.0;
    final absoluteLoad = bw + addedKg;
    final absoluteTimedE1rm = PeriodizationModelUtils.calculateE1RM(
      absoluteLoad,
      repEquivalent,
      0.0,
    );
    final absoluteFiveSecondMax = PeriodizationModelUtils.reverseCalculateWeight(
      targetE1RM: absoluteTimedE1rm,
      reps: 1,
      rir: 0.0,
    );
    final displayAdded = absoluteFiveSecondMax - bw;
    if (displayAdded <= 0) return const _E1rmDisplay('—');
    final isActual =
        set.weight.actualValue != null && set.reps.actualValue != null;
    return _E1rmDisplay(
      '+${displayAdded.toStringAsFixed(1)}',
      isActual: isActual,
      isHint: !isActual,
    );
  }

  /// Phase 21C: blue border for weight — BB3 override hint is locked and the
  /// free model would have placed weight meaningfully differently.
  /// Only fires on hint fields (actualValue == null).
  Color? _weightBorderColor() {
    final s = widget.set;
    if (!s.weightLockedByBb3OverrideCue) return null;
    if (s.weight.actualValue != null) return null;
    return Colors.lightBlueAccent.withValues(alpha: 0.65);
  }

  /// Phase 21C: blue border for reps — same logic as weight.
  Color? _repsBorderColor() {
    final s = widget.set;
    if (!s.repsLockedByBb3OverrideCue) return null;
    if (s.reps.actualValue != null) return null;
    return Colors.lightBlueAccent.withValues(alpha: 0.65);
  }

  /// Phase 21F/21C: border color for the RIR field.
  /// Priority: blue (BB3 RIR locked, model would have moved it) >
  ///           green/amber (free RIR hint shifted from baseline by >= 0.5).
  /// Blue takes priority because the RIR did not actually move — the BB3
  /// override held it. Green/amber applies only to freely moving model RIR.
  Color? _rirBorderColor() {
    final s = widget.set;
    // BB3 RIR locked — model would have changed it, but BB3 override won.
    if (s.rirLockedByBb3OverrideCue && s.rir.actualValue == null) {
      return Colors.lightBlueAccent.withValues(alpha: 0.65);
    }
    // Free-moving model RIR: green = higher than baseline, amber = lower.
    if (s.weight.actualValue == null) return null;
    if (s.reps.actualValue == null) return null;
    if (s.rir.actualValue != null) return null;
    final bRir = widget.baselineRirHint;
    final cRir = s.rir.hintValue;
    if (bRir == null || cRir == null) return null;
    final delta = cRir - bRir;
    if (delta.abs() < 0.5) return null;
    if (delta <= -2.5) return Colors.redAccent.withValues(alpha: 0.8);
    if (cRir == 0.0 && delta <= -1.0) return Colors.redAccent.withValues(alpha: 0.8);
    return delta > 0
        ? Colors.greenAccent.withValues(alpha: 0.65)
        : Colors.amberAccent.withValues(alpha: 0.75);
  }

  Color _noteIconColor() {
    final s = widget.set;
    if (s.executionNote != null) return Colors.lightBlueAccent;
    if (s.planNote != null) return widget.isPlanNoteRead ? Colors.white30 : Colors.amber;
    return Colors.white12;
  }

  String _noteTooltip() {
    final s = widget.set;
    if (s.executionNote != null && s.planNote != null) return 'Notes (plan + execution)';
    if (s.executionNote != null) return 'Execution note';
    if (s.planNote != null) return 'Plan note';
    return 'Add note';
  }

  Color _videoIconColor() =>
      widget.hasVideo ? Colors.lightBlueAccent : Colors.white12;

  String _videoTooltip() => widget.hasVideo
      ? SetVideoCopy.recordedSetTooltip
      : SetVideoCopy.recordSetTooltip;

  /// The set-video control, rendered immediately to the RIGHT of the note icon
  /// in every row variant.
  ///
  /// Returns an empty box rather than a disabled button when [onVideoTap] is
  /// null, so a row that cannot carry footage keeps its existing alignment
  /// instead of showing a dead control.
  ///
  /// The tap target is the full 36pt row height while staying 24pt wide: that
  /// doubles the reachable area versus the note icon beside it without moving
  /// a single pixel of the row's horizontal layout.
  Widget _videoIcon() {
    if (widget.onVideoTap == null) return const SizedBox.shrink();
    final int setNumber = widget.set.setIndex + 1;
    return Semantics(
      button: true,
      label: widget.hasVideo
          ? SetVideoCopy.recordedSemanticLabel(setNumber)
          : SetVideoCopy.recordSemanticLabel(setNumber),
      child: SizedBox(
        width: kWes2RowIconSlotWidth,
        height: kWes2RowIconSlotHeight,
        child: Align(
          alignment: Alignment.center,
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
                width: kWes2RowIconSlotWidth,
                height: kWes2RowIconSlotHeight),
            icon: Icon(
              widget.hasVideo ? Icons.videocam : Icons.videocam_outlined,
              size: 16,
              color: _videoIconColor(),
            ),
            tooltip: _videoTooltip(),
            onPressed: widget.onVideoTap,
          ),
        ),
      ),
    );
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

  void _acceptHint(
    TextEditingController ctrl,
    Wes2FieldKey fieldKey,
    String? hintText,
  ) {
    if (ctrl.text.trim().isNotEmpty) return;
    final hint = hintText?.trim();
    if (hint == null || hint.isEmpty) return;
    ctrl.text = hint;
    ctrl.selection = TextSelection.collapsed(offset: hint.length);
    widget.onFieldChanged(fieldKey, hint);
    widget.onFieldUnfocused(fieldKey, hint);
    // Notify tutorial logic of a genuine reps double-tap accept (after save).
    if (fieldKey == Wes2FieldKey.reps) widget.onTutorialRepsAccepted?.call();
  }

  Widget _field({
    required TextEditingController ctrl,
    required FocusNode focus,
    required Wes2FieldKey fieldKey,
    required String? hintText,
    required double width,
    bool decimal = false,
    Color? activeBorderColor,
    VoidCallback? onDoubleTap,
  }) {
    final enabledBorder = activeBorderColor != null
        ? UnderlineInputBorder(
            borderSide: BorderSide(color: activeBorderColor, width: 1))
        : _kEnabledBorder;
    final field = SizedBox(
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
            enabledBorder: enabledBorder,
            focusedBorder: _kFocusedBorder,
            isDense: true,
          ),
          onChanged: (v) => widget.onFieldChanged(fieldKey, v),
          style: _kFieldStyle,
        ),
      ),
    );
    if (onDoubleTap == null) return field;
    return GestureDetector(onDoubleTap: onDoubleTap, child: field);
  }

  // ── Timed row builders ───────────────────────────────────────────────────

  Widget _setLabel(Wes2SetState s) => SizedBox(
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
      );

  Widget _removeAndNoteIcons() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.onRemoveSet != null) ...[
            SizedBox(
              width: kWes2RowIconSlotWidth,
              height: kWes2RowIconSlotHeight,
              child: Align(
                alignment: Alignment.center,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                      width: kWes2RowIconSlotWidth,
                      height: kWes2RowIconSlotHeight),
                  icon: const Icon(
                    Icons.remove_circle_outline,
                    size: 16,
                    color: Colors.white38,
                  ),
                  tooltip: 'Remove set',
                  onPressed: widget.onRemoveSet,
                ),
              ),
            ),
          ],
          SizedBox(
            width: kWes2RowIconSlotWidth,
            height: kWes2RowIconSlotHeight,
            child: Align(
              alignment: Alignment.center,
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                    width: kWes2RowIconSlotWidth,
                    height: kWes2RowIconSlotHeight),
                icon: Icon(
                  Icons.sticky_note_2,
                  size: 16,
                  color: _noteIconColor(),
                ),
                tooltip: _noteTooltip(),
                onPressed: widget.onNoteTap,
              ),
            ),
          ),
          _videoIcon(),
        ],
      );

  Widget _buildTimedBodyweightRow(Wes2SetState s) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _setLabel(s),
          // BW display — context only, not editable, not saved as weight
          SizedBox(
            width: 90,
            height: 36,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                height: 36,
                padding: const EdgeInsets.only(left: 2, bottom: 8),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.white30, width: 1),
                  ),
                ),
                child: Text(
                  widget.bwDisplayText ?? 'BW',
                  style: _kHintStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _Wes2TimedCell(
            storedSeconds: s.reps.actualValue,
            hintSeconds: s.reps.hintValue,
            width: 70,
            onChanged: (t) => widget.onFieldChanged(Wes2FieldKey.reps, t),
            onUnfocused: (t) => widget.onFieldUnfocused(Wes2FieldKey.reps, t),
          ),
          _removeAndNoteIcons(),
        ],
      ),
    );
  }

  Widget _buildTimedWeightedRow(
      Wes2SetState s, String? weightHint, bool bounded) {
    final weightBorderColor = _weightBorderColor();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _setLabel(s),
          _field(
            ctrl: _weightCtrl,
            focus: _weightFocus,
            fieldKey: Wes2FieldKey.weight,
            hintText: weightHint,
            width: 76,
            decimal: true,
            activeBorderColor: weightBorderColor,
            onDoubleTap: () =>
                _acceptHint(_weightCtrl, Wes2FieldKey.weight, weightHint),
          ),
          const SizedBox(width: 4),
          _Wes2TimedCell(
            storedSeconds: s.reps.actualValue,
            hintSeconds: s.reps.hintValue,
            width: 70,
            onChanged: (t) => widget.onFieldChanged(Wes2FieldKey.reps, t),
            onUnfocused: (t) => widget.onFieldUnfocused(Wes2FieldKey.reps, t),
          ),
          const SizedBox(width: 4),
          // Same rule as the normal row: the derived column yields first.
          flexibleWhenBounded(
            bounded: bounded,
            child: SizedBox(
            width: 55,
            height: 36,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Builder(
                builder: (context) {
                  final e1rm = _resolveTimedWeightedE1rmDisplay(s);
                  return Container(
                    height: 36,
                    padding: const EdgeInsets.only(left: 2, bottom: 8),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Colors.white, width: 1),
                      ),
                    ),
                    alignment: Alignment.bottomLeft,
                    child: Text(
                      e1rm.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      strutStyle: const StrutStyle(
                        fontSize: 12,
                        height: 1.0,
                        forceStrutHeight: true,
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.0,
                        color: e1rm.isActual ? Colors.white : Colors.grey,
                        fontStyle: e1rm.isHint
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          ),
          _removeAndNoteIcons(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) =>
          _buildRow(context, c.maxWidth.isFinite),
    );
  }

  Widget _buildRow(BuildContext context, bool bounded) {
    final s = widget.set;
    final weightHint =
        s.weight.hintValue != null ? _fmtWeight(s.weight.hintValue!) : null;

    if (widget.entryMode == Wes2ExerciseEntryMode.timedBodyweight) {
      return _buildTimedBodyweightRow(s);
    }
    if (widget.entryMode == Wes2ExerciseEntryMode.timedWeighted) {
      return _buildTimedWeightedRow(s, weightHint, bounded);
    }

    final repsHint =
        s.reps.hintValue != null ? _fmtInt(s.reps.hintValue!) : null;
    final rirHint =
        s.rir.hintValue != null ? _fmtDouble(s.rir.hintValue!) : null;
    final rirBorderColor = _rirBorderColor();
    final weightBorderColor = _weightBorderColor();
    final repsBorderColor = _repsBorderColor();
    // Tutorial highlight takes priority over existing border colours on the targeted
    // field while tutorialStep > 0. Reverts exactly to existing logic when 0.
    final tutorialHighlight = widget.tutorialStep > 0
        ? Theme.of(context).colorScheme.secondary
        : null;
    final velocityHint =
        s.velocity.hintValue != null ? _fmtVelocity(s.velocity.hintValue!) : null;

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
            activeBorderColor: widget.tutorialStep == 1
                ? tutorialHighlight
                : weightBorderColor,
            onDoubleTap: () => _acceptHint(_weightCtrl, Wes2FieldKey.weight, weightHint),
          ),
          const SizedBox(width: 4),
          _field(
            ctrl: _repsCtrl,
            focus: _repsFocus,
            fieldKey: Wes2FieldKey.reps,
            hintText: repsHint,
            width: 50,
            activeBorderColor: widget.tutorialStep == 2
                ? tutorialHighlight
                : repsBorderColor,
            onDoubleTap: () => _acceptHint(_repsCtrl, Wes2FieldKey.reps, repsHint),
          ),
          const SizedBox(width: 4),
          _field(
            ctrl: _rirCtrl,
            focus: _rirFocus,
            fieldKey: Wes2FieldKey.rir,
            hintText: rirHint,
            width: 50,
            decimal: true,
            activeBorderColor: widget.tutorialStep == 3
                ? tutorialHighlight
                : rirBorderColor,
            onDoubleTap: () => _acceptHint(_rirCtrl, Wes2FieldKey.rir, rirHint),
          ),
          const SizedBox(width: 4),
          // E1RM — calculated from actuals (or hints when no actuals present).
          // Yields when the row cannot fit: it is a DERIVED display, so
          // narrowing it costs the user nothing they typed, whereas overflowing
          // paints a render error across the row on every phone 360dp and
          // under.
          flexibleWhenBounded(
            bounded: bounded,
            child: SizedBox(
            width: 55,
            height: 36,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Builder(
                builder: (context) {
                  final e1rm = _resolveE1rmDisplay(s);
                  return Container(
                    height: 36,
                    padding: const EdgeInsets.only(left: 2, bottom: 8),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Colors.white, width: 1),
                      ),
                    ),
                    alignment: Alignment.bottomLeft,
                    child: Text(
                      e1rm.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      strutStyle: const StrutStyle(
                        fontSize: 12,
                        height: 1.0,
                        forceStrutHeight: true,
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.0,
                        color: e1rm.isActual ? Colors.white : Colors.grey,
                        fontStyle: e1rm.isHint
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                    ),
                  );
                },
              ),
            ),
            ),
          ),
          if (widget.showVelocity) ...[
            const SizedBox(width: 4),
            // Optional column: yields alongside E1RM rather than overflowing
            // when it is enabled on the narrowest screens.
            flexibleWhenBounded(
              bounded: bounded,
              child: _field(
              ctrl: _velocityCtrl,
              focus: _velocityFocus,
              fieldKey: Wes2FieldKey.velocity,
              hintText: velocityHint,
              width: 45,
              decimal: true,
            ),
            ),
          ],
          if (widget.onRemoveSet != null) ...[
            SizedBox(
              width: kWes2RowIconSlotWidth,
              height: kWes2RowIconSlotHeight,
              child: Align(
                alignment: Alignment.center,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                      width: kWes2RowIconSlotWidth,
                      height: kWes2RowIconSlotHeight),
                  icon: const Icon(
                    Icons.remove_circle_outline,
                    size: 16,
                    color: Colors.white38,
                  ),
                  tooltip: 'Remove set',
                  onPressed: widget.onRemoveSet,
                ),
              ),
            ),
          ],
          SizedBox(
            width: kWes2RowIconSlotWidth,
            height: kWes2RowIconSlotHeight,
            child: Align(
              alignment: Alignment.center,
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                    width: kWes2RowIconSlotWidth,
                    height: kWes2RowIconSlotHeight),
                icon: Icon(
                  Icons.sticky_note_2,
                  size: 16,
                  color: _noteIconColor(),
                ),
                tooltip: _noteTooltip(),
                onPressed: widget.onNoteTap,
              ),
            ),
          ),
          _videoIcon(),
        ],
      ),
    );
  }
}

// ── Timed cell ───────────────────────────────────────────────────────────────

class _Wes2TimedCell extends StatefulWidget {
  final int? storedSeconds;
  final int? hintSeconds;
  final double width;
  final void Function(String rawText) onChanged;
  final void Function(String rawText) onUnfocused;

  const _Wes2TimedCell({
    required this.storedSeconds,
    required this.hintSeconds,
    required this.width,
    required this.onChanged,
    required this.onUnfocused,
  });

  @override
  State<_Wes2TimedCell> createState() => _Wes2TimedCellState();
}

class _Wes2TimedCellState extends State<_Wes2TimedCell> {
  /// Upper bound for the manual scroll-wheel editor: 59 min 59 sec. Matches the
  /// range of [CupertinoTimerPicker] in minute/second mode and is a generous
  /// ceiling for any gym timed exercise while staying a safe [int] second count.
  static const int _kMaxManualSeconds = 59 * 60 + 59;

  int _displaySeconds = 0;
  int _centiSeconds = 0;
  bool _active = false;
  bool _running = false;
  Timer? _ticker;

  static String _fmtStopped(int s) {
    final m = s ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  static String _fmtRunning(int s, int cs) {
    final m = s ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec.$cs';
  }

  @override
  void initState() {
    super.initState();
    _displaySeconds = widget.storedSeconds ?? 0;
  }

  @override
  void didUpdateWidget(_Wes2TimedCell old) {
    super.didUpdateWidget(old);
    if (!_active && !_running && widget.storedSeconds != old.storedSeconds) {
      _displaySeconds = widget.storedSeconds ?? 0;
    }
  }

  void _onTap() {
    if (!_active) {
      setState(() => _active = true);
    } else if (_running) {
      _stop();
    } else {
      _resume();
    }
  }

  void _onLongPress() {
    // Only reset when active and stopped — never while running.
    if (!_active || _running) return;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _displaySeconds = 0;
      _centiSeconds = 0;
    });
    widget.onChanged('');
    widget.onUnfocused('');
  }

  void _resume() {
    // Preserves _displaySeconds — resumes from current elapsed, not zero.
    setState(() {
      _running = true;
      _centiSeconds = 0;
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      setState(() {
        _centiSeconds++;
        if (_centiSeconds >= 10) {
          _centiSeconds = 0;
          _displaySeconds++;
        }
      });
    });
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
    setState(() => _running = false);
    final text = _displaySeconds > 0 ? _displaySeconds.toString() : '';
    widget.onChanged(text);
    widget.onUnfocused(text);
  }

  /// Opens the scroll-wheel picker to manually enter/edit the recorded time.
  /// Never available while the timer is running (the edit control is disabled),
  /// so this cannot race an active tick. Cancel changes nothing; Done routes the
  /// value through the same [onChanged] + [onUnfocused] path used by [_stop].
  Future<void> _openManualEditor() async {
    if (_running) return; // safety — control is disabled, but never race a tick
    final int base = _active
        ? _displaySeconds
        : (widget.storedSeconds ?? widget.hintSeconds ?? 0);
    final picked = await _openWes2ManualTimePicker(
      context,
      Duration(seconds: base.clamp(0, _kMaxManualSeconds)),
    );
    if (picked == null) return; // Cancel — no state change, no save
    if (!mounted) return;
    final total = picked.inSeconds.clamp(0, _kMaxManualSeconds);
    _ticker?.cancel();
    _ticker = null;
    if (total <= 0) {
      // 0:00 clears the actual value and lets any hint show through again,
      // matching how an emptied WES2 field behaves.
      setState(() {
        _displaySeconds = 0;
        _centiSeconds = 0;
        _running = false;
        _active = false;
      });
      widget.onChanged('');
      widget.onUnfocused('');
      return;
    }
    // Non-zero: land in the same "stopped with a value" state as _stop(), so a
    // subsequent tap resumes from here and long-press still resets.
    setState(() {
      _displaySeconds = total;
      _centiSeconds = 0;
      _running = false;
      _active = true;
    });
    final text = total.toString();
    widget.onChanged(text);
    widget.onUnfocused(text);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String displayText;
    final TextStyle displayStyle;
    final Color borderColor;
    final double borderWidth;
    final Color iconColor;

    const timedFieldStyle = TextStyle(color: Colors.white, fontSize: 12);
    const timedHintStyle = TextStyle(
        color: Colors.grey, fontStyle: FontStyle.italic, fontSize: 12);
    const timedRunningStyle =
        TextStyle(color: Colors.greenAccent, fontSize: 12);

    if (_running) {
      displayText = _fmtRunning(_displaySeconds, _centiSeconds);
      displayStyle = timedRunningStyle;
      borderColor = Colors.greenAccent;
      borderWidth = 1.5;
      iconColor = Colors.greenAccent;
    } else if (_active) {
      displayText = _fmtStopped(_displaySeconds);
      displayStyle = timedFieldStyle;
      borderColor = Colors.lightBlueAccent;
      borderWidth = 1.5;
      iconColor = Colors.lightBlueAccent;
    } else if (widget.storedSeconds != null) {
      displayText = _fmtStopped(widget.storedSeconds!);
      displayStyle = timedFieldStyle;
      borderColor = Colors.white;
      borderWidth = 1.0;
      iconColor = Colors.white54;
    } else if (widget.hintSeconds != null) {
      displayText = _fmtStopped(widget.hintSeconds!);
      displayStyle = timedHintStyle;
      borderColor = Colors.white24;
      borderWidth = 1.0;
      iconColor = Colors.white38;
    } else {
      displayText = '0:00';
      displayStyle = timedHintStyle;
      borderColor = Colors.white24;
      borderWidth = 1.0;
      iconColor = Colors.white38;
    }

    return TapRegion(
      onTapOutside: (_) {
        if (!_active) return;
        if (_running) _stop();
        setState(() => _active = false);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: _onTap,
            onLongPress: _onLongPress,
            child: SizedBox(
              width: widget.width,
              height: 36,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.only(left: 2, bottom: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: borderColor, width: borderWidth),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Icon(Icons.timer_outlined, size: 12, color: iconColor),
                      const SizedBox(width: 2),
                      // Flexible so the intended clip actually engages when the
                      // running value (m:ss.c) is momentarily wider than the
                      // fixed cell, instead of overflowing.
                      Flexible(
                        child: Text(
                          displayText,
                          style: displayStyle,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Manual edit control — separate from the Time tap target. Disabled
          // while the timer runs so it can never race an active tick; stop the
          // timer first, then edit.
          SizedBox(
            width: 26,
            height: 36,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 24, height: 26),
                icon: const Icon(Icons.edit_outlined, size: 13),
                color: Colors.white54,
                disabledColor: Colors.white12,
                tooltip: _running ? 'Stop timer to edit time' : 'Edit time',
                onPressed: _running ? null : _openManualEditor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal scroll-wheel (minutes:seconds) editor for a timed set. Returns the
/// chosen [Duration] on **Done**, or `null` on **Cancel** / dismissal — callers
/// must treat `null` as "no change, no save". Opening on a hint value does not,
/// by itself, persist anything; only a Done with a non-zero value saves.
Future<Duration?> _openWes2ManualTimePicker(
  BuildContext context,
  Duration initial,
) {
  return showModalBottomSheet<Duration>(
    context: context,
    backgroundColor: const Color(0xFF1C1C1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
    ),
    builder: (sheetContext) => Wes2ManualTimePickerSheet(
      initial: initial,
      onCancel: () => Navigator.of(sheetContext).pop(),
      onDone: (d) => Navigator.of(sheetContext).pop(d),
    ),
  );
}

/// Sheet body for [_openWes2ManualTimePicker]. Public only so widget tests can
/// pump it directly; not part of the WES2 public API.
class Wes2ManualTimePickerSheet extends StatefulWidget {
  final Duration initial;
  final VoidCallback onCancel;
  final ValueChanged<Duration> onDone;

  const Wes2ManualTimePickerSheet({
    super.key,
    required this.initial,
    required this.onCancel,
    required this.onDone,
  });

  @override
  State<Wes2ManualTimePickerSheet> createState() =>
      _Wes2ManualTimePickerSheetState();
}

class _Wes2ManualTimePickerSheetState extends State<Wes2ManualTimePickerSheet> {
  static const Duration _maxDuration = Duration(minutes: 59, seconds: 59);

  late Duration _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial.isNegative
        ? Duration.zero
        : (widget.initial > _maxDuration ? _maxDuration : widget.initial);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text(
                      'Cancel',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  const Text(
                    'Edit time',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  TextButton(
                    onPressed: () => widget.onDone(_selected),
                    child: const Text(
                      'Done',
                      style: TextStyle(
                        color: Colors.lightBlueAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 200,
              child: CupertinoTheme(
                data: const CupertinoThemeData(brightness: Brightness.dark),
                child: CupertinoTimerPicker(
                  mode: CupertinoTimerPickerMode.ms,
                  initialTimerDuration: _selected,
                  onTimerDurationChanged: (d) => _selected = d,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
