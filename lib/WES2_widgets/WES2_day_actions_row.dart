import 'package:flutter/material.dart';

/// Top action bar with "Add Exercise" and optional "Load Template" buttons.
class Wes2TopActionsBar extends StatelessWidget {
  final void Function() onAddExercise;
  final VoidCallback? onLoadTemplate;

  const Wes2TopActionsBar({
    super.key,
    required this.onAddExercise,
    this.onLoadTemplate,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 5, top: 4, right: 5, bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text(
                'Add Exercise',
                style: TextStyle(fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
              ),
              onPressed: onAddExercise,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.layers_outlined, size: 16),
              label: const Text(
                'Load Template',
                style: TextStyle(fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.secondary,
                foregroundColor: Theme.of(context).colorScheme.onSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
              ),
              onPressed: onLoadTemplate,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom action row: Summary · sets logged · Add Circuit + 55px spacer.
class Wes2BottomActionsRow extends StatelessWidget {
  final int setsLogged;
  final void Function() onAddCircuit;
  final VoidCallback? onSummary;
  final VoidCallback? onSaveAsTemplate;

  const Wes2BottomActionsRow({
    super.key,
    required this.setsLogged,
    required this.onAddCircuit,
    this.onSummary,
    this.onSaveAsTemplate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, left: 8, right: 8, bottom: 0),
          child: Row(
            children: [
              if (onSummary != null) ...[
                TextButton(
                  onPressed: onSummary,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text(
                    'Summary',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(
                  setsLogged > 0
                      ? '$setsLogged set${setsLogged == 1 ? '' : 's'} logged'
                      : 'No sets logged yet',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              ElevatedButton.icon(
                icon: Icon(
                  Icons.add,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
                label: Text(
                  'Add Circuit',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  foregroundColor: Theme.of(context).colorScheme.tertiary,
                ),
                onPressed: onAddCircuit,
              ),
            ],
          ),
        ),
        if (onSaveAsTemplate != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 8, right: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.bookmark_add_outlined, size: 14),
                  label: const Text(
                    'Save as Template',
                    style: TextStyle(fontSize: 12),
                  ),
                  onPressed: onSaveAsTemplate,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white54,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 55),
      ],
    );
  }
}
