import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import 'exercise_catalog.dart';

const List<String> kExerciseCategories = [
  'Horizontal Press',
  'Horizontal Pull',
  'Vertical Press',
  'Vertical Pull',
  'Lateral Raise',
  'Arm Extension',
  'Arm Curl',
  'Squat Pattern',
  'Hip Hinge',
  'Leg Extension',
  'Leg Curl',
  'Hip Abduction/adduction',
  'Calf Raise',
  'Core',
];

const List<String> kBodyParts = [
  'Chest',
  'Anterior Delts',
  'Lateral Delts',
  'Rear Delts',
  'Triceps',
  'Biceps',
  'Forearms',
  'Lats',
  'Rhomboids',
  'Mid Traps',
  'Upper Traps',
  'Lower Back',
  'Abs',
  'Obliques',
  'Glutes',
  'Quads',
  'Hamstrings',
  'Calves',
  'Inner Thigh',
  'Hip Abductors',
];

/// The canonical "Add Exercise" dialog shared by the exercise library, WES2
/// pickers and Block Planner 2.
///
/// Routing is unchanged from the library screen: the admin writer creates a
/// GLOBAL exercise, everyone else creates one in `/users/{ownerUid}/
/// customExercises` — [ownerUid] must be the SELECTED athlete (coach mode),
/// [actorUid] the authenticated user. Returns the [AddExerciseResult] on save
/// (including a duplicate outcome) or null when cancelled / nothing written.
Future<AddExerciseResult?> showAddExerciseDialog(
  BuildContext context, {
  required String ownerUid,
  required String actorUid,
}) {
  if (actorUid.isEmpty) return Future<AddExerciseResult?>.value(null);

  final nameCtrl = TextEditingController();
  final categoryCtrl = TextEditingController();
  final bodySearchCtrl = TextEditingController();

  String? pickedCategory;
  final List<String> pickedBodyParts = [];

// NEW: optional equipment type
  String? pickedType;
  const List<String> kExerciseTypes = [
    'Dumbbell',
    'Barbell',
    'Suspension System',
    'Machine',
    'Cable Stack',
    'Body Weight'
  ];

  final formKey = GlobalKey<FormState>();

  InputDecoration _dec(String label, {Widget? icon}) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
        filled: true,
        fillColor: Theme.of(context).cardTheme.color ??
            Theme.of(context).colorScheme.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
              color: Theme.of(context).colorScheme.secondary, width: 1.6),
        ),
        prefixIcon: icon == null
            ? null
            : IconTheme(
                data: IconThemeData(
                    color: Theme.of(context).colorScheme.secondary),
                child: icon,
              ),
      );

  FocusNode? bodyPartFocusNode; // capture the one RawAutocomplete gives us

  return showDialog<AddExerciseResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      void _addBodyPart(String bp) {
        if (!pickedBodyParts.contains(bp)) {
          pickedBodyParts.add(bp);
          bodySearchCtrl.clear();
          (ctx as Element).markNeedsBuild();
        }
      }

      Widget _chip(String text, int i) {
        return Container(
          margin: const EdgeInsets.only(right: 4, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Theme.of(ctx).cardTheme.color ??
                Theme.of(ctx).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Theme.of(ctx).colorScheme.outline),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(text,
                style: TextStyle(color: Theme.of(ctx).colorScheme.onSurface)),
            const SizedBox(width: 6),
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                constraints:
                    const BoxConstraints.tightFor(width: 22, height: 22),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.arrow_upward,
                    size: 16, color: Theme.of(ctx).colorScheme.secondary),
                onPressed: i == 0
                    ? null
                    : () {
                        final tmp = pickedBodyParts[i - 1];
                        pickedBodyParts[i - 1] = pickedBodyParts[i];
                        pickedBodyParts[i] = tmp;
                        (ctx as Element).markNeedsBuild();
                      },
              ),
              IconButton(
                constraints:
                    const BoxConstraints.tightFor(width: 28, height: 28),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.arrow_downward,
                    size: 18, color: Theme.of(ctx).colorScheme.secondary),
                onPressed: i == pickedBodyParts.length - 1
                    ? null
                    : () {
                        final tmp = pickedBodyParts[i + 1];
                        pickedBodyParts[i + 1] = pickedBodyParts[i];
                        pickedBodyParts[i] = tmp;
                        (ctx as Element).markNeedsBuild();
                      },
              ),
              IconButton(
                constraints:
                    const BoxConstraints.tightFor(width: 28, height: 28),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close,
                    size: 18, color: Theme.of(ctx).colorScheme.secondary),
                onPressed: () {
                  pickedBodyParts.removeAt(i);
                  (ctx as Element).markNeedsBuild();
                },
              ),
            ]),
          ]),
        );
      }

      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        title: Row(
          children: [
            Icon(Icons.fitness_center,
                color: Theme.of(context).colorScheme.secondary),
            const SizedBox(width: 10),
            const Text('Add Exercise'),
          ],
        ),
        content: Form(
          key: formKey,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
            child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Name
                    TextFormField(
                      controller: nameCtrl,
                      decoration:
                          _dec('Name', icon: const Icon(Icons.text_fields)),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Please enter a name'
                          : null,
                    ),
                    const SizedBox(height: 12),

                    // Category (type-ahead, canonical only)
                    RawAutocomplete<String>(
                      textEditingController: categoryCtrl,
                      focusNode: FocusNode(),
                      optionsBuilder: (TextEditingValue tev) {
                        final q = tev.text.toLowerCase().trim();
                        if (q.isEmpty) return const Iterable<String>.empty();
                        return kExerciseCategories
                            .where((c) => c.toLowerCase().contains(q));
                      },
                      onSelected: (val) => pickedCategory = val,
                      fieldViewBuilder:
                          (context, controller, focusNode, onFieldSubmitted) {
                        return TextFormField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: _dec('Category',
                              icon: const Icon(Icons.category)),
                          validator: (_) {
                            final entered = controller.text.trim();
                            if (entered.isEmpty)
                              return 'Please choose a category';

                            // Case-insensitive match against the canonical list
                            final match = kExerciseCategories.firstWhere(
                              (c) => c.toLowerCase() == entered.toLowerCase(),
                              orElse: () => '',
                            );

                            if (match.isEmpty)
                              return 'Select one of the suggestions';

                            // Canonicalize the text (correct casing) and store it
                            if (controller.text != match)
                              controller.text = match;
                            pickedCategory = match;
                            return null;
                          },
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                        );
                      },
                      optionsViewBuilder: (context, onSelected, options) {
                        return Material(
                          color: Theme.of(context).cardTheme.color ??
                              Theme.of(context).colorScheme.surface,
                          elevation: 6,
                          borderRadius: BorderRadius.circular(8),
                          child: ListView(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            shrinkWrap: true,
                            children: options
                                .map((o) => ListTile(
                                      dense: true,
                                      title: Text(o),
                                      trailing: Icon(Icons.check,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .secondary,
                                          size: 18),
                                      onTap: () => onSelected(o),
                                    ))
                                .toList(),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 14),

                    // NEW: Equipment type (optional)
                    DropdownButtonFormField<String>(
                      value: pickedType,
                      decoration: _dec(
                        'Equipment type (optional)',
                        icon: const Icon(Icons.fitness_center),
                      ),
                      items: kExerciseTypes
                          .map(
                            (t) => DropdownMenuItem<String>(
                              value: t,
                              child: Text(t),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        pickedType = value;
                      },
                      dropdownColor: Theme.of(context).cardTheme.color ??
                          Theme.of(context).colorScheme.surface,
                    ),
                    const SizedBox(height: 14),

                    // Body parts title + tooltip
                    Row(
                      children: [
                        Text('Body Parts (primary first)',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withOpacity(0.7),
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: 6),
                        Tooltip(
                          message:
                              'Put primary muscle(s) first, then others in descending order of involvement.\n'
                              'E.g., Bench Press: Chest, Anterior Delts, Triceps.',
                          child: Icon(Icons.info_outline,
                              color: Theme.of(context).colorScheme.secondary,
                              size: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Body parts search + add (type-ahead)
                    RawAutocomplete<String>(
                      textEditingController: bodySearchCtrl,
                      focusNode: bodyPartFocusNode ??= FocusNode(),
                      optionsBuilder: (TextEditingValue tev) {
                        final q = tev.text.toLowerCase().trim();
                        if (q.isEmpty) return const Iterable<String>.empty();
                        return kBodyParts
                            .where((bp) => bp.toLowerCase().contains(q))
                            .where((bp) => !pickedBodyParts.contains(bp));
                      },
                      onSelected: (val) => _addBodyPart(val),
                      fieldViewBuilder:
                          (context, controller, focusNode, onFieldSubmitted) {
                        return TextFormField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: _dec('Add body part',
                              icon: const Icon(Icons.search)),
                        );
                      },
                      optionsViewBuilder: (context, onSelected, options) {
                        return Material(
                          color: Theme.of(context).cardTheme.color ??
                              Theme.of(context).colorScheme.surface,
                          elevation: 6,
                          borderRadius: BorderRadius.circular(8),
                          child: ListView(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            shrinkWrap: true,
                            children: options
                                .map((o) => ListTile(
                                      dense: true,
                                      title: Text(o),
                                      trailing: Icon(Icons.add,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .secondary,
                                          size: 18),
                                      onTap: () => onSelected(o),
                                    ))
                                .toList(),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 10),

                    // Selected body parts chips (ordered)
                    if (pickedBodyParts.isEmpty)
                      Text(
                        'Add at least one body part',
                        style:
                            TextStyle(color: Colors.red.shade300, fontSize: 12),
                      )
                    else
                      Wrap(
                        children: List.generate(
                          pickedBodyParts.length,
                          (i) => _chip(pickedBodyParts[i], i),
                        ),
                      ),
                  ]),
            ),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              foregroundColor: Theme.of(context).colorScheme.onSecondary,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              elevation: 0,
            ),
            icon: const Icon(Icons.save),
            label: const Text('Save'),
            onPressed: () async {
              final validForm = (formKey.currentState?.validate() ?? false);
              final validBody = pickedBodyParts.isNotEmpty &&
                  pickedBodyParts.every((bp) => kBodyParts.contains(bp));
              if (!validForm || !validBody) return;

              final trimmedName = nameCtrl.text.trim();
              final category = pickedCategory ?? categoryCtrl.text.trim();

              AddExerciseResult? result;
              try {
                result = await ExerciseCatalog.addExercise(
                  ownerUid: ownerUid,
                  actorUid: actorUid,
                  name: trimmedName,
                  bodyParts: List<String>.of(pickedBodyParts),
                  category: category,
                  type: pickedType,
                );
              } catch (e) {
                debugPrint('Error adding exercise: $e');
              }
              if (ctx.mounted) Navigator.of(ctx).pop(result);
            },
          ),
        ],
      );
    },
  );
}
