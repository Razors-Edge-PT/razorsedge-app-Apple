/// Rep-target and RIR-target editors for Block Planner 2 (modal sheets).
///
/// Both editors read the live [Bp2Controller] resolution on every rebuild so
/// they always show the pattern required by the currently selected model, and
/// write every keystroke straight into the exercise draft (keyed by athlete +
/// exercise id), so closing the sheet never loses an edit.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../exercise_model_registry.dart';
import 'bp2_controller.dart';
import 'bp2_settings_resolver.dart';

Future<void> showBp2RepTargetEditor(
  BuildContext context, {
  required Bp2Controller controller,
  required String exerciseId,
  required String exerciseName,
}) =>
    _showSheet(
      context,
      child: _RepTargetEditor(
        controller: controller,
        exerciseId: exerciseId,
        exerciseName: exerciseName,
      ),
    );

Future<void> showBp2RirTargetEditor(
  BuildContext context, {
  required Bp2Controller controller,
  required String exerciseId,
  required String exerciseName,
}) =>
    _showSheet(
      context,
      child: _RirTargetEditor(
        controller: controller,
        exerciseId: exerciseId,
        exerciseName: exerciseName,
      ),
    );

Future<void> _showSheet(BuildContext context, {required Widget child}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: child,
      ),
    );

// ── Shared pieces ─────────────────────────────────────────────────────────────

final List<TextInputFormatter> _digitsOnly = [
  FilteringTextInputFormatter.digitsOnly,
];
final List<TextInputFormatter> _decimalOnly = [
  FilteringTextInputFormatter.allow(RegExp(r'^\d*[.,]?\d*$')),
];

/// A text field whose controller survives rebuilds but re-syncs to [value]
/// when the value changed for a reason other than this field's own typing.
class Bp2SyncedField extends StatefulWidget {
  final String value;
  final String label;
  final String semanticsLabel;
  final ValueChanged<String> onChanged;
  final bool decimal;
  final FocusNode? focusNode;
  final bool compact;

  const Bp2SyncedField({
    super.key,
    required this.value,
    required this.label,
    required this.semanticsLabel,
    required this.onChanged,
    this.decimal = false,
    this.focusNode,
    this.compact = false,
  });

  @override
  State<Bp2SyncedField> createState() => _Bp2SyncedFieldState();
}

class _Bp2SyncedFieldState extends State<Bp2SyncedField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value);
  String _lastEmitted = '';

  @override
  void initState() {
    super.initState();
    _lastEmitted = widget.value;
  }

  @override
  void didUpdateWidget(covariant Bp2SyncedField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value &&
        widget.value != _lastEmitted &&
        widget.value != _ctrl.text) {
      _ctrl.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
      _lastEmitted = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: widget.semanticsLabel,
      textField: true,
      child: TextField(
        controller: _ctrl,
        focusNode: widget.focusNode,
        keyboardType: TextInputType.numberWithOptions(decimal: widget.decimal),
        inputFormatters: widget.decimal ? _decimalOnly : _digitsOnly,
        textInputAction: TextInputAction.next,
        style: TextStyle(fontSize: widget.compact ? 13 : 14),
        decoration: InputDecoration(
          labelText: widget.label,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          isDense: true,
          filled: true,
          fillColor: theme.cardTheme.color ?? theme.colorScheme.surface,
          contentPadding: EdgeInsets.symmetric(
              horizontal: widget.compact ? 8 : 10,
              vertical: widget.compact ? 10 : 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onChanged: (v) {
          _lastEmitted = v;
          widget.onChanged(v);
        },
      ),
    );
  }
}

Widget _sheetHeader(BuildContext context, String title, String subtitle) {
  final theme = Theme.of(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: theme.textTheme.titleMedium),
      const SizedBox(height: 2),
      Text(subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7))),
      const SizedBox(height: 12),
    ],
  );
}

// ── Rep targets & set count ───────────────────────────────────────────────────

class _RepTargetEditor extends StatelessWidget {
  final Bp2Controller controller;
  final String exerciseId;
  final String exerciseName;
  const _RepTargetEditor({
    required this.controller,
    required this.exerciseId,
    required this.exerciseName,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final r = controller.resolvedFor(exerciseId);
        final draft = controller.draftFor(exerciseId);
        final children = <Widget>[
          _sheetHeader(context, 'Rep targets & set count', exerciseName),
        ];

        if (r.repShape == RepTargetShape.repRange) {
          final range = (r.projected['repTargets'] as Map?)?['repRange'];
          String v(String key, dynamic canonical) => draft.has(key)
              ? (draft[key] ?? '')
              : (canonical?.toString() ?? '');
          children.add(Row(children: [
            Expanded(
              child: Bp2SyncedField(
                value: v(Bp2Field.repMin, (range as Map?)?['min']),
                label: 'Min reps',
                semanticsLabel: 'Minimum reps',
                onChanged: (t) =>
                    controller.edit(exerciseId, Bp2Field.repMin, t),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Bp2SyncedField(
                value: v(Bp2Field.repMax, range?['max']),
                label: 'Max reps',
                semanticsLabel: 'Maximum reps',
                onChanged: (t) =>
                    controller.edit(exerciseId, Bp2Field.repMax, t),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Bp2SyncedField(
                value: v(Bp2Field.defaultSets, r.defaultSets),
                label: 'Sets',
                semanticsLabel: 'Default set count',
                onChanged: (t) =>
                    controller.edit(exerciseId, Bp2Field.defaultSets, t),
              ),
            ),
          ]));
        } else if (r.sessions.isEmpty) {
          children.add(const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Set weekly frequency to populate rep targets.'),
          ));
        } else {
          for (final s in r.sessions) {
            children.add(_RepSessionRow(
              key: ValueKey('rep-${s.session}'),
              controller: controller,
              exerciseId: exerciseId,
              session: s.session,
              reps: s.reps?.toString() ?? '',
              sets: s.sets.toString(),
            ));
          }
        }
        children.add(const SizedBox(height: 8));
        children.add(Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ));
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      },
    );
  }
}

/// `Session N: [reps] × [sets]` — both halves are kept as raw text so a
/// half-typed value is never re-rendered underneath the user.
class _RepSessionRow extends StatefulWidget {
  final Bp2Controller controller;
  final String exerciseId;
  final int session;
  final String reps;
  final String sets;
  const _RepSessionRow({
    super.key,
    required this.controller,
    required this.exerciseId,
    required this.session,
    required this.reps,
    required this.sets,
  });

  @override
  State<_RepSessionRow> createState() => _RepSessionRowState();
}

class _RepSessionRowState extends State<_RepSessionRow> {
  late String _reps = widget.reps;
  late String _sets = widget.sets;

  @override
  void didUpdateWidget(covariant _RepSessionRow old) {
    super.didUpdateWidget(old);
    // Only re-sync from the resolver when we are not the source of the change.
    final key = Bp2Field.repInstance(widget.session);
    final draftText = widget.controller.draftFor(widget.exerciseId)[key];
    if (draftText == null || draftText != _combined()) {
      _reps = widget.reps;
      _sets = widget.sets;
    }
  }

  String _combined() => '$_reps x $_sets';

  void _emit() {
    final key = Bp2Field.repInstance(widget.session);
    if (_reps.trim().isEmpty && _sets.trim().isEmpty) {
      widget.controller.edit(widget.exerciseId, key, null);
    } else {
      widget.controller.edit(widget.exerciseId, key, _combined());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text('Session ${widget.session}:',
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          Expanded(
            child: Bp2SyncedField(
              value: _reps,
              label: 'Reps',
              semanticsLabel: 'Session ${widget.session} reps',
              onChanged: (t) {
                _reps = t;
                _emit();
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('×'),
          ),
          Expanded(
            child: Bp2SyncedField(
              value: _sets,
              label: 'Sets',
              semanticsLabel: 'Session ${widget.session} sets',
              onChanged: (t) {
                _sets = t;
                _emit();
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ── RIR targets ───────────────────────────────────────────────────────────────

class _RirTargetEditor extends StatelessWidget {
  final Bp2Controller controller;
  final String exerciseId;
  final String exerciseName;
  const _RirTargetEditor({
    required this.controller,
    required this.exerciseId,
    required this.exerciseName,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final r = controller.resolvedFor(exerciseId);
        final theme = Theme.of(context);
        final children = <Widget>[
          _sheetHeader(context, 'RIR targets', exerciseName),
        ];
        if (r.sessions.isEmpty) {
          children.add(const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Set weekly frequency to populate RIR targets.'),
          ));
        }
        for (final s in r.sessions) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child:
                Text('Session ${s.session}', style: theme.textTheme.labelLarge),
          ));
          // Up to three set fields per row keeps phone widths comfortable.
          for (var start = 0; start < s.sets; start += 3) {
            final end = (start + 3).clamp(0, s.sets);
            children.add(Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  for (var i = start; i < end; i++) ...[
                    Expanded(
                      child: Bp2SyncedField(
                        key: ValueKey('rir-${s.session}-${i + 1}'),
                        value: s.rir[i],
                        label: 'Set ${i + 1}',
                        semanticsLabel: 'Session ${s.session} set ${i + 1} RIR',
                        decimal: true,
                        compact: true,
                        onChanged: (t) => controller.edit(
                            exerciseId, Bp2Field.rir(s.session, i + 1), t),
                      ),
                    ),
                    if (i < end - 1) const SizedBox(width: 8),
                  ],
                  for (var pad = end - start; pad < 3; pad++) ...[
                    const SizedBox(width: 8),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ],
              ),
            ));
          }
        }
        children.add(Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ));
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      },
    );
  }
}
