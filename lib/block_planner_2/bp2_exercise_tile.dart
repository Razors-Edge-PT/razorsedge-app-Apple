/// One catalogue row of Block Planner 2 and its inline settings panel.
library;

import '../units/weight_unit.dart';
import 'package:flutter/material.dart';

import '../exercise_catalog.dart';
import '../exercise_model_registry.dart';
import 'bp2_controller.dart';
import 'bp2_models.dart';
import 'bp2_settings_resolver.dart';
import 'bp2_target_editors.dart';

class Bp2ExerciseTile extends StatelessWidget {
  final Bp2Exercise exercise;
  final bool expanded;
  final bool dirty;
  final Bp2Controller controller;

  const Bp2ExerciseTile({
    super.key,
    required this.exercise,
    required this.expanded,
    required this.dirty,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleParts = <String>[
      if (exercise.category.isNotEmpty) exercise.category,
      if (exercise.source == ExerciseSource.custom) 'Custom',
      if (exercise.unresolvedReference) 'Not in catalogue',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: ValueKey('bp2-row-${exercise.id}'),
          dense: true,
          minVerticalPadding: 10,
          title:
              Text(exercise.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: subtitleParts.isEmpty
              ? null
              : Text(subtitleParts.join(' · '),
                  style: theme.textTheme.bodySmall),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (dirty)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.circle,
                      size: 8,
                      color: theme.colorScheme.primary,
                      semanticLabel: 'Unsaved changes'),
                ),
              Icon(expanded ? Icons.expand_less : Icons.expand_more),
            ],
          ),
          onTap: () => controller.toggleExpanded(exercise.id),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Bp2ExerciseSettingsPanel(
              key: ValueKey('bp2-panel-${exercise.id}'),
              exercise: exercise,
              controller: controller,
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

/// Exactly four two-field rows:
///   Increments / Weekly frequency
///   Rep periodization model / Rep targets & set count
///   RIR periodization model / RIR targets
///   Progression model / Velocity
class Bp2ExerciseSettingsPanel extends StatelessWidget {
  final Bp2Exercise exercise;
  final Bp2Controller controller;

  const Bp2ExerciseSettingsPanel({
    super.key,
    required this.exercise,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final id = exercise.id;
    final r = controller.resolvedFor(id);
    final draft = controller.draftFor(id);
    final errors = {
      for (final e in Bp2SettingsResolver.validate(draft)) e.field: e.message
    };

    String wfText() => draft.has(Bp2Field.weeklyFrequency)
        ? (draft[Bp2Field.weeklyFrequency] ?? '')
        : (r.weeklyFrequency?.toString() ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WeightUnitField(
          key: ValueKey('bp2-weight-unit-$id'),
          value: r.weightUnit,
          onChanged: (u) =>
              controller.edit(id, Bp2Field.weightUnit, u.storageValue),
        ),
        const SizedBox(height: 10),
        _twoUp(
          left: _IncrementsField(
            unit: r.weightUnit,
            primary: r.incrementPrimary,
            secondary: r.incrementSecondary,
            errorText: errors[Bp2Field.incrementPrimary] ??
                errors[Bp2Field.incrementSecondary],
            onPrimary: (t) => controller.edit(id, Bp2Field.incrementPrimary, t),
            onSecondary: (t) =>
                controller.edit(id, Bp2Field.incrementSecondary, t),
          ),
          right: _Labelled(
            label: 'Weekly frequency',
            errorText: errors[Bp2Field.weeklyFrequency],
            child: Bp2SyncedField(
              value: wfText(),
              label: 'Sessions / week',
              semanticsLabel: 'Weekly frequency',
              onChanged: (t) =>
                  controller.edit(id, Bp2Field.weeklyFrequency, t),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _twoUp(
          left: _ModelDropdown(
            label: 'Rep periodization model',
            value: r.periodizationModel,
            options: ExerciseModelRegistry.repModels,
            onChanged: (v) =>
                controller.edit(id, Bp2Field.periodizationModel, v),
          ),
          right: _SummaryTile(
            label: 'Rep targets & set count',
            summary: r.repSummary,
            semanticsLabel: 'Edit rep targets and set count',
            errorText: _firstErrorWithPrefix(errors, 'rep.') ??
                errors[Bp2Field.defaultSets],
            onTap: () => showBp2RepTargetEditor(
              context,
              controller: controller,
              exerciseId: id,
              exerciseName: exercise.name,
            ),
          ),
        ),
        const SizedBox(height: 10),
        _twoUp(
          left: _ModelDropdown(
            label: 'RIR periodization model',
            value: r.rirModel,
            options: ExerciseModelRegistry.rirModels,
            onChanged: (v) => controller.edit(id, Bp2Field.rirModel, v),
          ),
          right: _SummaryTile(
            label: 'RIR targets',
            summary: r.rirSummary,
            semanticsLabel: 'Edit RIR targets',
            errorText: _firstErrorWithPrefix(errors, 'rir.'),
            onTap: () => showBp2RirTargetEditor(
              context,
              controller: controller,
              exerciseId: id,
              exerciseName: exercise.name,
            ),
          ),
        ),
        const SizedBox(height: 10),
        _twoUp(
          left: _ModelDropdown(
            label: 'Progression model',
            value: r.progressionModel,
            options: ExerciseModelRegistry.progressionModels,
            onChanged: (v) => controller.edit(id, Bp2Field.progressionModel, v),
          ),
          right: _Labelled(
            label: 'Velocity',
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Show velocity input',
                        style: TextStyle(fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                  Semantics(
                    label: 'Show velocity input',
                    child: Switch.adaptive(
                      value: r.showVelocity,
                      onChanged: (v) => controller.edit(
                          id, Bp2Field.showVelocityField, v ? 'true' : 'false'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String? _firstErrorWithPrefix(Map<String, String> errors, String p) {
    for (final e in errors.entries) {
      if (e.key.startsWith(p)) return e.value;
    }
    return null;
  }

  static Widget _twoUp({required Widget left, required Widget right}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: left),
          const SizedBox(width: 8),
          Expanded(child: right),
        ],
      );
}

class _Labelled extends StatelessWidget {
  final String label;
  final Widget child;
  final String? errorText;
  const _Labelled({required this.label, required this.child, this.errorText});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        child,
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(errorText!,
                style: TextStyle(fontSize: 11, color: theme.colorScheme.error)),
          ),
      ],
    );
  }
}

class _IncrementsField extends StatelessWidget {
  final ExerciseWeightUnit unit;
  final String primary;
  final String secondary;
  final String? errorText;
  final ValueChanged<String> onPrimary;
  final ValueChanged<String> onSecondary;
  const _IncrementsField({
    this.unit = ExerciseWeightUnit.kg,
    required this.primary,
    required this.secondary,
    required this.errorText,
    required this.onPrimary,
    required this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return _Labelled(
      label:
          unit == ExerciseWeightUnit.kg ? 'Increments' : 'Increments (lb)',
      errorText: errorText,
      child: Row(
        children: [
          Expanded(
            child: Bp2SyncedField(
              value: primary,
              label: 'Primary',
              semanticsLabel: 'Primary increment',
              decimal: true,
              onChanged: onPrimary,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Bp2SyncedField(
              value: secondary,
              label: '2nd',
              semanticsLabel: 'Secondary increment',
              decimal: true,
              onChanged: onSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelDropdown extends StatelessWidget {
  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  const _ModelDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Labelled(
      label: label,
      child: SizedBox(
        height: 48,
        child: DropdownButtonFormField<String>(
          // Re-created whenever the resolved value changes externally.
          key: ValueKey('dropdown-$label-$value'),
          initialValue: ExerciseModelRegistry.knownOrNull(value, options),
          isExpanded: true,
          isDense: true,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: theme.cardTheme.color ?? theme.colorScheme.surface,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          ),
          hint: const Text('Select', style: TextStyle(fontSize: 13)),
          items: [
            for (final o in options)
              DropdownMenuItem(
                value: o,
                child: Text(o,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final String summary;
  final String semanticsLabel;
  final String? errorText;
  final VoidCallback onTap;
  const _SummaryTile({
    required this.label,
    required this.summary,
    required this.semanticsLabel,
    required this.errorText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Labelled(
      label: label,
      errorText: errorText,
      child: Semantics(
        button: true,
        label: semanticsLabel,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: theme.cardTheme.color ?? theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: theme.colorScheme.outline),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(summary,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ),
                const Icon(Icons.edit_outlined, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Kilograms (kg) / Pounds (lb) for one exercise — the same
/// `exerciseSettings.weightUnit` leaf the WES2 settings cog edits.
class _WeightUnitField extends StatelessWidget {
  final ExerciseWeightUnit value;
  final ValueChanged<ExerciseWeightUnit> onChanged;
  const _WeightUnitField({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return _Labelled(
      label: 'Weight unit',
      child: SizedBox(
        height: 48,
        child: DropdownButtonFormField<ExerciseWeightUnit>(
          key: ValueKey('bp2-unit-dropdown-${value.storageValue}'),
          initialValue: value,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          ),
          items: [
            for (final u in ExerciseWeightUnit.values)
              DropdownMenuItem(value: u, child: Text(u.choiceLabel)),
          ],
          onChanged: (u) {
            if (u != null) onChanged(u);
          },
        ),
      ),
    );
  }
}
