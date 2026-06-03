import 'package:flutter/material.dart';

const List<String> _kTexts = [
  'Enter a weight you can do for this exercise at the given rep target.',
  'Double tap to accept suggestion, type in to enter something different.',
  'Enter how many reps you want to leave in reserve. 0 means no reps left, 2 means you could have done 2 more.',
];

const List<String> _kButtons = ['Got it →', 'Got it →', 'Done'];

/// Inline step-by-step tutorial banner shown between the top actions bar
/// and the exercise list in WES2. Visible only when step is 1, 2, or 3.
class Wes2TutorialBanner extends StatelessWidget {
  final int step;
  final VoidCallback onDismiss;

  const Wes2TutorialBanner({
    super.key,
    required this.step,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final idx = (step - 1).clamp(0, 2);
    final cs = Theme.of(context).colorScheme;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Container(
        key: ValueKey(step),
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: cs.secondary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: cs.secondary.withValues(alpha: 0.35),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // Step indicator dots
            Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) => Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == idx
                      ? cs.secondary
                      : cs.secondary.withValues(alpha: 0.28),
                ),
              )),
            ),
            const SizedBox(width: 8),
            // Step text
            Expanded(
              child: Text(
                _kTexts[idx],
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Colors.white70,
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Dismiss button
            TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: cs.secondary,
              ),
              child: Text(
                _kButtons[idx],
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
