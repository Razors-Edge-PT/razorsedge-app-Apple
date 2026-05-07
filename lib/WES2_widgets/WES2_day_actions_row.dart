import 'package:flutter/material.dart';

/// Top action bar with "Add Exercise" button.
/// Inactive in Phase 5 — exercise picker not yet implemented.
class Wes2TopActionsBar extends StatelessWidget {
  const Wes2TopActionsBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 5, top: 4, right: 5, bottom: 4),
      child: Row(
        children: [
          Flexible(
            flex: 4,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text(
                'Add Exercise',
                style: TextStyle(fontSize: 14),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
              ),
              onPressed: null, // inactive — exercise picker not yet implemented
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom action row: read-only summary label + "Add Circuit" button + 55px spacer.
/// "Add Circuit" is inactive in Phase 5 — structural add not yet implemented.
class Wes2BottomActionsRow extends StatelessWidget {
  /// Total sets with any actual (logged) value across all exercise rows.
  final int setsLogged;

  const Wes2BottomActionsRow({super.key, required this.setsLogged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, left: 8, right: 8, bottom: 0),
          child: Row(
            children: [
              Text(
                setsLogged > 0
                    ? '$setsLogged set${setsLogged == 1 ? '' : 's'} logged'
                    : 'No sets logged yet',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
              const Spacer(),
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
                onPressed:
                    null, // inactive — structural add not yet implemented
              ),
            ],
          ),
        ),
        const SizedBox(height: 55),
      ],
    );
  }
}
