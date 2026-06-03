import 'package:flutter/material.dart';

const List<String> _kTexts = [
  'Enter a weight you can do for this exercise at the given rep target.',
  'Double tap to accept suggestion, type in to enter something different.',
  'For RIR, enter how many reps you had left in reserve, after you finish the set. 0 means no reps left, 2 means you could have done 2 more.',
];

const List<String> _kButtons = ['Got it →', 'Got it →', 'Done'];

/// Inline step-by-step tutorial banner shown between the top actions bar
/// and the exercise list in WES2. Visible only when step is 1, 2, or 3.
///
/// The border slowly cycles through colorScheme.secondary → tertiary → primary
/// for a premium glow effect. Content and layout are stable (no movement).
class Wes2TutorialBanner extends StatefulWidget {
  final int step;
  final VoidCallback onDismiss;
  /// When non-null, a compact "← back" button is shown to the left of the
  /// dismiss button. Pass null to hide it (e.g. at the first field step).
  final VoidCallback? onBack;

  const Wes2TutorialBanner({
    super.key,
    required this.step,
    required this.onDismiss,
    this.onBack,
  });

  @override
  State<Wes2TutorialBanner> createState() => _Wes2TutorialBannerState();
}

class _Wes2TutorialBannerState extends State<Wes2TutorialBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Cycles secondary → tertiary → primary → secondary over one controller period.
  Color _glowColor(ColorScheme cs) {
    final t = _ctrl.value;
    if (t < 1 / 3) {
      return Color.lerp(cs.secondary, cs.tertiary, t * 3)!;
    } else if (t < 2 / 3) {
      return Color.lerp(cs.tertiary, cs.primary, (t - 1 / 3) * 3)!;
    } else {
      return Color.lerp(cs.primary, cs.secondary, (t - 2 / 3) * 3)!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final idx = (widget.step - 1).clamp(0, 2);
    final cs = Theme.of(context).colorScheme;

    // AnimatedSwitcher handles the cross-fade when step changes.
    // AnimatedBuilder rebuilds only the container decoration on each glow tick;
    // the Row child is stable between ticks (only rebuilt when step changes).
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: AnimatedBuilder(
        key: ValueKey(widget.step),
        animation: _ctrl,
        builder: (_, child) {
          final glow = _glowColor(cs);
          return Container(
            margin: const EdgeInsets.fromLTRB(8, 4, 8, 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: cs.secondary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: glow.withValues(alpha: 0.70),
                width: 1.4,
              ),
              boxShadow: [
                BoxShadow(
                  color: glow.withValues(alpha: 0.22),
                  blurRadius: 10,
                ),
              ],
            ),
            child: child,
          );
        },
        // Stable child: only rebuilt when step changes (not on animation ticks).
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
            // Back button — hidden at first field step (onBack == null)
            if (widget.onBack != null) ...[
              TextButton(
                onPressed: widget.onBack,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: cs.secondary.withValues(alpha: 0.65),
                ),
                child: const Text(
                  '← back',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 2),
            ],
            // Dismiss button
            TextButton(
              onPressed: widget.onDismiss,
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
