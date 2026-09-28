/// Block Planner 2 "Add exercise" picker.
///
/// Lists EXISTING exercises — the shared catalogue plus the selected
/// athlete's custom exercises (the controller's merged catalogue) — with a
/// search field. Picking one returns it; the caller adds it to the selected
/// block. Creating a brand-new custom exercise is an explicit secondary
/// action: the new exercise then appears in this list so it can be picked
/// deliberately. Nothing here writes to Firestore by itself.
library;

import 'package:flutter/material.dart';

import 'bp2_controller.dart';
import 'bp2_models.dart';

/// Secondary action: creates a custom exercise and returns it (or null).
typedef Bp2CreateCustomExercise = Future<Bp2Exercise?> Function(
    BuildContext context);

class Bp2ExercisePicker extends StatefulWidget {
  final Bp2Controller controller;
  final Bp2CreateCustomExercise onCreateCustom;

  const Bp2ExercisePicker({
    super.key,
    required this.controller,
    required this.onCreateCustom,
  });

  static const String title = 'Add exercise to block';

  static Route<Bp2Exercise> route({
    required Bp2Controller controller,
    required Bp2CreateCustomExercise onCreateCustom,
  }) =>
      MaterialPageRoute<Bp2Exercise>(
        builder: (_) => Bp2ExercisePicker(
          controller: controller,
          onCreateCustom: onCreateCustom,
        ),
      );

  @override
  State<Bp2ExercisePicker> createState() => _Bp2ExercisePickerState();
}

class _Bp2ExercisePickerState extends State<Bp2ExercisePicker> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  String? _createdId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Bp2Exercise> _visible() {
    final q = _query.trim().toLowerCase();
    return [
      for (final e in widget.controller.catalogue)
        if (!e.unresolvedReference &&
            (q.isEmpty || e.name.toLowerCase().contains(q)))
          e
    ];
  }

  Future<void> _createCustom() async {
    final created = await widget.onCreateCustom(context);
    if (!mounted || created == null) return;
    // Show the new exercise so the user can add it deliberately.
    setState(() {
      _createdId = created.id;
      _search.text = created.name;
      _query = created.name;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text(Bp2ExercisePicker.title)),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final items = _visible();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  key: const ValueKey('bp2-picker-search'),
                  controller: _search,
                  autofocus: false,
                  decoration: const InputDecoration(
                    labelText: 'Search exercises',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextButton.icon(
                    key: const ValueKey('bp2-picker-create-custom'),
                    onPressed: _createCustom,
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: const Text('Create custom exercise'),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          widget.controller.catalogueLoaded
                              ? 'No matching exercises.'
                              : 'Loading exercises…',
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey('bp2-picker-list'),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final e = items[i];
                          final inBlock =
                              widget.controller.blockHasExercise(e.id);
                          return ListTile(
                            key: ValueKey('bp2-pick-${e.id}'),
                            title: Text(e.name),
                            subtitle: Text(inBlock
                                ? 'Already in this block'
                                : [e.category, e.bodyPart]
                                    .where((s) => s.isNotEmpty)
                                    .join(' · ')),
                            selected: e.id == _createdId,
                            enabled: !inBlock,
                            trailing: inBlock
                                ? const Icon(Icons.check)
                                : const Icon(Icons.add),
                            onTap: inBlock
                                ? null
                                : () => Navigator.of(context).pop(e),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
