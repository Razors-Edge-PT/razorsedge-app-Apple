import 'dart:async';

import 'package:flutter/material.dart';
import '../app_theme.dart';

/// Top action bar with "Add Exercise" and optional "Load Template" buttons.
class Wes2TopActionsBar extends StatelessWidget {
  final void Function() onAddExercise;
  final VoidCallback? onLoadTemplate;
  /// When true, draws a glowing border + "Tap here" label above Load Template.
  final bool highlightLoadTemplate;

  const Wes2TopActionsBar({
    super.key,
    required this.onAddExercise,
    this.onLoadTemplate,
    this.highlightLoadTemplate = false,
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
            child: _buildLoadTemplateButton(context),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadTemplateButton(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final button = ElevatedButton.icon(
      icon: const Icon(Icons.layers_outlined, size: 16),
      label: const Text(
        'Load Template',
        style: TextStyle(fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: cs.secondary,
        foregroundColor: cs.onSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
      ),
      onPressed: onLoadTemplate,
    );

    if (!highlightLoadTemplate) return button;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NudgingCueLabel(text: 'Tap here', color: cs.secondary),
        const SizedBox(height: 2),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.secondary, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: cs.secondary.withValues(alpha: 0.35),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
          child: button,
        ),
      ],
    );
  }
}

// ── Nudging cue label ─────────────────────────────────────────────────────────
// Gently bobs upward ~4 px every 2 seconds to draw attention without
// distracting from the button below it.
class _NudgingCueLabel extends StatefulWidget {
  final String text;
  final Color color;
  const _NudgingCueLabel({required this.text, required this.color});

  @override
  State<_NudgingCueLabel> createState() => _NudgingCueLabelState();
}

class _NudgingCueLabelState extends State<_NudgingCueLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _offsetAnim;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _offsetAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -4.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -4.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_ctrl);

    // Initial nudge shortly after the label first appears.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _ctrl.forward(from: 0);
    });
    // Repeat every 2 seconds thereafter.
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (mounted) _ctrl.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _offsetAnim,
      builder: (_, child) => Transform.translate(
        offset: Offset(0, _offsetAnim.value),
        child: child,
      ),
      child: Text(
        widget.text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: widget.color,
        ),
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
                    color: Theme.of(context)
                        .extension<GoodLiftColors>()
                        ?.quaternary ??
                        AppTheme.defaultQuaternary,
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
