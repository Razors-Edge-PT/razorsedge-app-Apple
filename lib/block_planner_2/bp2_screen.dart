/// Block Planner 2 — page presentation only. All state lives in
/// [Bp2Controller]; all pure logic in the resolver / classifier / date utils.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../add_exercise_dialog.dart';
import '../exercise_catalog.dart';
import '../user_context.dart';
import 'bp2_controller.dart';
import 'bp2_date_utils.dart';
import 'bp2_exercise_tile.dart';
import 'bp2_models.dart';
import 'bp2_warmup.dart';

/// The canonical custom-exercise creation flow (injectable for tests).
typedef Bp2AddExerciseFlow = Future<AddExerciseResult?> Function(
  BuildContext context, {
  required String ownerUid,
  required String actorUid,
});

/// Typed route arguments for Block Planner 2.
///
/// [athleteUid] is the SELECTED athlete whose block is edited (never inferred
/// from the signed-in coach). [blockId] is the exact block to open; null opens
/// a new draft.
@immutable
class Bp2RouteArgs {
  final String athleteUid;
  final String? blockId;
  const Bp2RouteArgs({required this.athleteUid, this.blockId});

  @override
  bool operator ==(Object other) =>
      other is Bp2RouteArgs &&
      other.athleteUid == athleteUid &&
      other.blockId == blockId;

  @override
  int get hashCode => Object.hash(athleteUid, blockId);

  @override
  String toString() => 'Bp2RouteArgs($athleteUid, $blockId)';
}

class Bp2Screen extends StatefulWidget {
  /// Existing block to edit; null opens a new draft.
  final String? blockId;

  /// Selected athlete that owns [blockId]. Null → `UserContext.currentUid`.
  final String? athleteUid;

  /// Test seams. Production wiring is built from [Bp2Warmup.instance.sync].
  final Bp2Controller? controller;
  final Bp2AddExerciseFlow? addExerciseFlow;

  const Bp2Screen({
    super.key,
    this.blockId,
    this.athleteUid,
    this.controller,
    this.addExerciseFlow,
  });

  static const String title = 'Block Planner 2';
  static const String routeName = '/block_planner_2';

  /// The internal Block Planner 2 route (with or without a selected block).
  static Route<void> route({
    required UserContext userContext,
    required Bp2RouteArgs args,
    Bp2Controller? controller,
  }) =>
      MaterialPageRoute<void>(
        settings: RouteSettings(name: routeName, arguments: args),
        builder: (_) => ChangeNotifierProvider<UserContext>.value(
          value: userContext,
          child: Bp2Screen(
            blockId: args.blockId,
            athleteUid: args.athleteUid,
            controller: controller,
          ),
        ),
      );

  @override
  State<Bp2Screen> createState() => _Bp2ScreenState();
}

class _Bp2ScreenState extends State<Bp2Screen> {
  late final Bp2Controller _controller;
  late final bool _ownsController;
  final FocusNode _nameFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  String? _boundUid;
  String? _boundActive;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ??
        Bp2Controller(
          sync: Bp2Warmup.instance.sync,
          repo: Bp2Warmup.instance.sync.repo,
        );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uc = UserContext.of(context);
    final uid = widget.athleteUid ?? uc.currentUid;
    // The UserContext active pointer only describes the athlete it is acting
    // for; otherwise the athlete's cached isActive flag is used.
    final active = uc.currentUid == uid ? uc.activeBlockId : null;
    if (uid == _boundUid && active == _boundActive) return;
    _boundUid = uid;
    _boundActive = active;
    // bind() notifies synchronously; never do that during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.bind(
          uid: uid, blockId: widget.blockId, activeBlockId: active);
    });
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    _scroll.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showFocus(Bp2FieldFocus? focus) {
    if (focus == null) return;
    if (focus.exerciseId == null) {
      _nameFocus.requestFocus();
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      return;
    }
    if (_controller.expandedExerciseId != focus.exerciseId) {
      _controller.toggleExpanded(focus.exerciseId!);
    }
  }

  Future<void> _onSavePressed() async {
    final out = await _controller.save();
    if (!mounted) return;
    if (!out.success) {
      _showFocus(out.focus);
      _snack(out.error ?? 'Could not save.');
      return;
    }
    if (out.nothingToSave) {
      _snack('Nothing to save.');
      return;
    }
    if (out.offlineQueued) {
      _snack('Saved on this device — it will sync when you are back online.');
    } else {
      _snack('Block saved.');
    }
    if (_controller.isEditingActiveBlock) return;
    await _offerActivation();
  }

  Future<void> _offerActivation() async {
    final activate = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Activate block?'),
        content: const Text(
            'Make this the current active block? The previously active block '
            'will be retired.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Activate block'),
          ),
        ],
      ),
    );
    if (activate != true || !mounted) return;
    await _activate();
  }

  Future<void> _activate() async {
    final out = await _controller.activate();
    if (!mounted) return;
    if (out.success) {
      final uc = UserContext.of(context, listen: false);
      final b = _controller.block;
      if (b != null && uc.currentUid == _controller.uid) {
        uc.applyBlockMeta(
          uid: uc.currentUid,
          activeBlockId: b.id,
          startDate: b.range.start,
          endDate: b.range.end,
        );
      }
      _snack('Block activated.');
      return;
    }
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Activation failed'),
        content: Text(out.error ?? 'The block was saved but not activated.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
    if (retry == true && mounted) await _activate();
  }

  /// Exit auto-save: validates and saves everything dirty, never offers
  /// activation, keeps the page open on invalid data.
  Future<void> _onPopInvoked(bool didPop) async {
    if (didPop || _exiting) return;
    _exiting = true;
    try {
      final out = await _controller.save(fromExit: true);
      if (!mounted) return;
      if (!out.success) {
        _showFocus(out.focus);
        _snack(out.error ?? 'Could not save your changes.');
        return;
      }
      if (out.offlineQueued) {
        _snack('Saved on this device — it will sync when you are back online.');
      }
      Navigator.of(context).pop();
    } finally {
      _exiting = false;
    }
  }

  Future<void> _pickRange() async {
    final range = _controller.range;
    if (range == null) return;
    final today = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 2),
      lastDate: DateTime(today.year + 3, 12, 31),
      initialDateRange: DateTimeRange(start: range.start, end: range.end),
      helpText: 'Block dates (snaps to Monday–Sunday)',
    );
    if (picked == null || !mounted) return;
    _controller.setRange(picked.start, picked.end);
  }

  Future<void> _addExercise() async {
    final uc = UserContext.of(context, listen: false);
    final owner = _controller.uid ?? uc.currentUid;
    final flow = widget.addExerciseFlow ?? showAddExerciseDialog;
    final result = await flow(
      context,
      ownerUid: owner,
      actorUid: uc.actorUid,
    );
    if (!mounted || result == null) return;
    if (result.isDuplicate) {
      _snack('That exercise already exists in your list.');
      return;
    }
    final ex =
        await _controller.repo.fetchExerciseById(owner, result.exerciseId);
    if (!mounted) return;
    if (ex == null) {
      _snack('Exercise added — pull to refresh if it does not appear.');
      return;
    }
    await _controller.onExerciseAdded(ex);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final c = _controller;
        return PopScope(
          canPop: !c.isDirty && !c.saving,
          onPopInvokedWithResult: (didPop, _) => _onPopInvoked(didPop),
          child: Scaffold(
            appBar: AppBar(
              centerTitle: true,
              title: const Text(Bp2Screen.title),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: c.saving
                      ? const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : TextButton(
                          key: const ValueKey('bp2-save'),
                          onPressed: c.blockLoaded ? _onSavePressed : null,
                          child: const Text('Save'),
                        ),
                ),
              ],
            ),
            body: _Body(
              controller: c,
              nameFocus: _nameFocus,
              scroll: _scroll,
              onPickRange: _pickRange,
              onAddExercise: _addExercise,
            ),
          ),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  final Bp2Controller controller;
  final FocusNode nameFocus;
  final ScrollController scroll;
  final VoidCallback onPickRange;
  final VoidCallback onAddExercise;

  const _Body({
    required this.controller,
    required this.nameFocus,
    required this.scroll,
    required this.onPickRange,
    required this.onAddExercise,
  });

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (!c.blockLoaded) {
      return _BlockLoading(error: c.blockLoadError);
    }
    final g = c.grouping;
    final loaded = c.catalogueLoaded;
    return CustomScrollView(
      key: const ValueKey('bp2-scroll'),
      controller: scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SyncBanner(status: c.syncStatus, onRetry: c.retrySync),
                _NameField(controller: c, focusNode: nameFocus),
                const SizedBox(height: 12),
                _DateSection(controller: c, onPick: onPickRange),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(
                      key: const ValueKey('bp2-add-exercise'),
                      onPressed: onAddExercise,
                      icon: const Icon(Icons.add),
                      label: const Text('Add exercise'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (!loaded && c.syncStatus.state == Bp2SyncState.syncing)
          const SliverToBoxAdapter(child: LinearProgressIndicator()),

        // Each top-level category is a group whose heading stays pinned
        // while any of its rows are on screen, so the category being viewed
        // is always labelled — including at the very bottom of a long list.
        SliverMainAxisGroup(
          key: const ValueKey('bp2-group-templates'),
          slivers: [
            const _SectionSliver('Exercises in templates',
                key: ValueKey('bp2-section-templates')),
            const _SubSectionSliver('Current block',
                key: ValueKey('bp2-section-current')),
            ..._group(
                c,
                g.currentBlock,
                loaded
                    ? "No exercises in the current block's templates."
                    : null),
            const _SubSectionSliver('Other blocks',
                key: ValueKey('bp2-section-other')),
            ..._group(c, g.otherBlocks,
                loaded ? "No exercises in other blocks' templates." : null),
          ],
        ),
        // All other exercises: always its own top-level category after the
        // whole Other blocks subgroup, with an explicit empty state.
        SliverMainAxisGroup(
          key: const ValueKey('bp2-group-all-other'),
          slivers: [
            _SectionSliver('All other exercises',
                key: const ValueKey('bp2-section-all-other'),
                color: Theme.of(context).colorScheme.primary),
            ..._group(c, g.allOther,
                loaded ? 'No exercises outside planned blocks.' : null),
          ],
        ),

        // Clear the system navigation / gesture area (edge-to-edge).
        SliverPadding(
          padding: EdgeInsets.only(
              bottom: 32 + MediaQuery.viewPaddingOf(context).bottom),
        ),
      ],
    );
  }

  /// One exercise group: a lazily built list, or an explicit empty state.
  /// [emptyText] null means the catalogue is still loading.
  static List<Widget> _group(
      Bp2Controller c, List<Bp2Exercise> items, String? emptyText) {
    if (items.isEmpty) {
      return [_EmptyNoteSliver(emptyText ?? 'Loading…')];
    }
    return [
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final exercise = items[i];
          return Bp2ExerciseTile(
            key: ValueKey('bp2-tile-${exercise.id}'),
            exercise: exercise,
            expanded: c.expandedExerciseId == exercise.id,
            dirty: c.isExerciseDirty(exercise.id),
            controller: c,
          );
        },
      ),
    ];
  }
}

class _SectionSliver extends StatelessWidget {
  final String title;
  final Color? color;
  const _SectionSliver(this.title, {super.key, this.color});
  @override
  Widget build(BuildContext context) => PinnedHeaderSliver(
        child: ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: _Header(title, primary: true, color: color),
        ),
      );
}

class _SubSectionSliver extends StatelessWidget {
  final String title;
  const _SubSectionSliver(this.title, {super.key});
  @override
  Widget build(BuildContext context) =>
      SliverToBoxAdapter(child: _Header(title, primary: false));
}

class _EmptyNoteSliver extends StatelessWidget {
  final String text;
  const _EmptyNoteSliver(this.text);
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      );
}

class _BlockLoading extends StatelessWidget {
  final String? error;
  const _BlockLoading({required this.error});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: error == null
            ? const CircularProgressIndicator()
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Flexible(
                      child:
                          Text(error!, key: const ValueKey('bp2-load-error'))),
                ],
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final bool primary;
  final Color? color;
  const _Header(this.title, {required this.primary, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, primary ? 16 : 8, 16, 4),
      child: Text(
        title,
        style: primary
            ? theme.textTheme.titleMedium?.copyWith(color: color)
            : theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _NameField extends StatefulWidget {
  final Bp2Controller controller;
  final FocusNode focusNode;
  const _NameField({required this.controller, required this.focusNode});

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final TextEditingController _text =
      TextEditingController(text: widget.controller.name);

  @override
  void didUpdateWidget(covariant _NameField old) {
    super.didUpdateWidget(old);
    _syncFromController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFromController();
  }

  void _syncFromController() {
    final name = widget.controller.name;
    if (name != _text.text) {
      _text.value = TextEditingValue(
        text: name,
        selection: TextSelection.collapsed(offset: name.length),
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncFromController();
    return TextField(
      key: const ValueKey('bp2-name'),
      controller: _text,
      focusNode: widget.focusNode,
      textInputAction: TextInputAction.done,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: 'Block name',
        border: const OutlineInputBorder(),
        helperText: widget.controller.nameIsAuto
            ? (widget.controller.name.trim().isEmpty
                ? 'Blank uses: ${widget.controller.generatedName}'
                : 'Auto-named from athlete and dates — edit to keep your own name.')
            : null,
        helperMaxLines: 2,
      ),
      onChanged: widget.controller.setName,
    );
  }
}

class _DateSection extends StatelessWidget {
  final Bp2Controller controller;
  final VoidCallback onPick;
  const _DateSection({required this.controller, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final range = controller.range;
    final label = range == null
        ? 'Loading…'
        : '${Bp2DateUtils.formatDate(range.start)} – ${Bp2DateUtils.formatDate(range.end)}';
    final summary = range == null ? '' : Bp2DateUtils.weekSummary(range.weeks);
    return Semantics(
      button: true,
      label: 'Block dates, $label, $summary',
      child: InkWell(
        key: const ValueKey('bp2-dates'),
        borderRadius: BorderRadius.circular(6),
        onTap: range == null ? null : onPick,
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Block dates (Monday – Sunday)',
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.date_range),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    key: const ValueKey('bp2-dates-label'),
                    style: theme.textTheme.bodyLarge),
              ),
              Text(summary,
                  key: const ValueKey('bp2-weeks'),
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SyncBanner extends StatelessWidget {
  final Bp2SyncStatus status;
  final Future<void> Function() onRetry;
  const _SyncBanner({required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (status.state) {
      case Bp2SyncState.idle:
      case Bp2SyncState.offlineQueued:
        return const SizedBox.shrink();
      case Bp2SyncState.syncing:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text('Checking for updates…', style: theme.textTheme.bodySmall),
            ],
          ),
        );
      case Bp2SyncState.error:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Icon(Icons.cloud_off, size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(status.message ?? 'Sync failed.',
                    style: theme.textTheme.bodySmall),
              ),
              TextButton(
                key: const ValueKey('bp2-retry'),
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ),
        );
    }
  }
}
