import 'package:flutter/material.dart';

/// Menu actions in the WES2 AppBar overflow menu.
/// [hintDebug] is debug-instrumentation only — its item renders solely when
/// the screen passes a non-null [Wes2AppBar.onHintDebugSnapshot] (kDebugMode).
enum Wes2AppBarMenuAction { timer, templates, deleteAll, hintDebug }

/// The WES2 screen AppBar, extracted from `Wes2Screen` so its navigation
/// controls can be widget-tested against the real production widget without
/// mounting the full screen (and its Firestore/Isar/UserContext dependencies).
///
/// Navigation behaviour itself lives in `Wes2ExitCoordinator`; this widget only
/// surfaces the controls and forwards taps via [onBack] / [onHome].
///
/// Back/Home design (production navigation regression fix):
///   • `automaticallyImplyLeading` is false and an explicit Back [IconButton]
///     is always rendered, so it appears even when `Navigator.canPop()` is
///     false (restored root WES2 under `PopScope(canPop:false)`, where the
///     implied back button and iOS edge-swipe are both gone).
///   • The GoodLift logo is a tappable Home control with a ≥48×48 interactive
///     area while the image keeps its original rendered size.
class Wes2AppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Invoked by the explicit Back button (routes to the previous screen).
  final VoidCallback onBack;

  /// Invoked by the GoodLift logo (routes directly Home).
  final VoidCallback onHome;

  /// Coach-view greeting line (e.g. "Viewing"); null hides the greeting block.
  final String? greeting;

  /// Athlete username shown under [greeting]; null hides the username line.
  final String? username;

  /// Whether the undo control is enabled.
  final bool canUndo;

  /// Invoked when undo is tapped (only when [canUndo] is true).
  final VoidCallback onUndo;

  /// Invoked by the refresh control.
  final VoidCallback onRefresh;

  /// Invoked by the overflow menu "Timer" item.
  final VoidCallback onToggleTimer;

  /// Invoked by the overflow menu "Templates" item.
  final VoidCallback onShowTemplates;

  /// Invoked by the overflow menu "Delete Day" item.
  final VoidCallback onDeleteAll;

  /// Debug-only: shows the "Hint debug snapshot" item when non-null.
  /// Production builds pass null, so the item never renders for customers.
  final VoidCallback? onHintDebugSnapshot;

  const Wes2AppBar({
    super.key,
    required this.onBack,
    required this.onHome,
    required this.greeting,
    required this.username,
    required this.canUndo,
    required this.onUndo,
    required this.onRefresh,
    required this.onToggleTimer,
    required this.onShowTemplates,
    required this.onDeleteAll,
    this.onHintDebugSnapshot,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      // Explicit, always-present Back button — never rely on the implied
      // leading, which Flutter hides when Navigator.canPop() is false.
      automaticallyImplyLeading: false,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: 'Back',
        onPressed: onBack,
      ),
      title: const Text(' '),
      actions: [
        if (greeting != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    greeting!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.secondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (username != null)
                    Text(
                      username!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.secondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ),
        // GoodLift logo → direct Home. Tappable with a ≥48×48 interactive area
        // while the image keeps its original rendered size.
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4),
          child: Semantics(
            button: true,
            label: 'GoodLift Home',
            child: Tooltip(
              message: 'Home',
              child: InkWell(
                onTap: onHome,
                customBorder: const CircleBorder(),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  child: Center(
                    child: Image.asset(
                      'assets/InApp/transparent_good_lift_logo_inApp.png',
                      height: 44,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.undo),
          tooltip: 'Undo',
          onPressed: canUndo ? onUndo : null,
        ),
        IconButton(
          icon: const Icon(
            Icons.auto_awesome,
            color: Colors.amberAccent,
          ),
          tooltip: 'Refresh',
          onPressed: onRefresh,
        ),
        PopupMenuButton<Wes2AppBarMenuAction>(
          icon: const Icon(Icons.more_vert),
          onSelected: (action) {
            switch (action) {
              case Wes2AppBarMenuAction.timer:
                onToggleTimer();
                break;
              case Wes2AppBarMenuAction.templates:
                onShowTemplates();
                break;
              case Wes2AppBarMenuAction.deleteAll:
                onDeleteAll();
                break;
              case Wes2AppBarMenuAction.hintDebug:
                onHintDebugSnapshot?.call();
                break;
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: Wes2AppBarMenuAction.timer,
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.timer_outlined, size: 18),
                  SizedBox(width: 10),
                  Text('Timer'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: Wes2AppBarMenuAction.templates,
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.layers_outlined, size: 18),
                  SizedBox(width: 10),
                  Text('Templates'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: Wes2AppBarMenuAction.deleteAll,
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                  SizedBox(width: 10),
                  Text('Delete Day', style: TextStyle(color: Colors.redAccent)),
                ],
              ),
            ),
            if (onHintDebugSnapshot != null)
              const PopupMenuItem(
                value: Wes2AppBarMenuAction.hintDebug,
                height: 40,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bug_report_outlined,
                        size: 18, color: Colors.orangeAccent),
                    SizedBox(width: 10),
                    Text('Hint debug snapshot',
                        style: TextStyle(color: Colors.orangeAccent)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
