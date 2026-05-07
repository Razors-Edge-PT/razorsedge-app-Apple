import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'WES2_controller.dart';
import 'WES2_models.dart';
import 'WES2_plan_service.dart';
import 'WES2_repository.dart';
import 'WES2_widgets/WES2_day_header.dart';
import 'WES2_widgets/WES2_empty_state.dart';
import 'WES2_widgets/WES2_day_actions_row.dart';
import 'WES2_widgets/WES2_exercise_card.dart';

/// WES2 beta route shell.
/// Receives an optional [initialDate]; defaults to today when omitted.
/// Accesses athlete identity via UserContext — never via FirebaseAuth directly.
class Wes2Screen extends StatefulWidget {
  final DateTime? initialDate;

  const Wes2Screen({super.key, this.initialDate});

  @override
  State<Wes2Screen> createState() => _Wes2ScreenState();
}

class _Wes2ScreenState extends State<Wes2Screen> {
  late final Wes2SessionController _controller;
  final Wes2Repository _repository = FirestoreWes2Repository();
  final Wes2PlanService _planService = FirestoreWes2PlanService();
  bool _loadStarted = false;

  @override
  void initState() {
    super.initState();
    final raw = widget.initialDate ?? DateTime.now();
    _controller = Wes2SessionController(raw);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // listen: false — identity is read once; UserContext.currentUid is the
    // acting athlete UID, never FirebaseAuth.currentUser.uid directly.
    final uc = UserContext.of(context, listen: false);
    _controller.initIdentity(
      actorUid: uc.actorUid,
      actingUid: uc.currentUid,
      isCoach: uc.isCoach,
      activeBlockId: uc.activeBlockId,
      blockStartDate: uc.blockStartDate,
    );
    if (!_loadStarted) {
      _loadStarted = true;
      _loadDay();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Load completed workout + BB3 planned rows for the current date, then merge.
  /// beginLoad() increments the epoch; stale completions are discarded.
  Future<void> _loadDay() async {
    final epoch = _controller.beginLoad();
    try {
      // Phase 3: completed workout document (exercises[] + wesPlannedExercises[])
      final completedRows = await _repository.loadDay(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );

      // Phase 4: BB3 planned day — skip if block context is absent or if
      // selectedDate is before blockStartDate (no negative week/day paths).
      var bb3Rows = const <Wes2ExerciseRow>[];
      final blockId = _controller.activeBlockId;
      final blockStart = _controller.blockStartDate;
      if (blockId != null &&
          blockId.isNotEmpty &&
          blockStart != null &&
          !_isBeforeBlockStart(_controller.selectedDate, blockStart)) {
        final wd = _weekDayFromDate(blockStart, _controller.selectedDate);
        bb3Rows = await _planService.loadPlannedDay(
          uid: _controller.actingUid,
          blockId: blockId,
          weekIndex: wd.weekIndex,
          dayIndex: wd.dayIndex,
        );
      }

      if (!mounted) return;
      _controller.setRows(_mergeRows(completedRows, bb3Rows), epoch);
    } catch (e) {
      if (!mounted) return;
      _controller.setLoadError(e.toString(), epoch);
    }
  }

  /// Returns true if [date] (midnight-normalised) is strictly before
  /// [blockStart] (midnight-normalised). Prevents negative week/day indices.
  static bool _isBeforeBlockStart(DateTime date, DateTime blockStart) {
    final d = DateTime(date.year, date.month, date.day);
    final b = DateTime(blockStart.year, blockStart.month, blockStart.day);
    return d.isBefore(b);
  }

  /// Converts blockStart + selected date to BB3 weekIndex / dayIndex.
  /// Matches BB3PlannedExerciseService.dateToWeekDay logic; no import needed.
  static ({int weekIndex, int dayIndex}) _weekDayFromDate(
    DateTime blockStart,
    DateTime date,
  ) {
    final base = DateTime(blockStart.year, blockStart.month, blockStart.day);
    final sel = DateTime(date.year, date.month, date.day);
    final days = sel.difference(base).inDays;
    return (weekIndex: days ~/ 7, dayIndex: days % 7);
  }

  /// Merges completed + WES2-planned rows (Phase 3) with BB3 rows (Phase 4).
  /// Priority: completedServer → wes2Manual → bb3Planned.
  /// Deduplication by exerciseId via putIfAbsent. Sorted by orderIndex.
  static List<Wes2ExerciseRow> _mergeRows(
    List<Wes2ExerciseRow> completedRows,
    List<Wes2ExerciseRow> bb3Rows,
  ) {
    final seen = <String, Wes2ExerciseRow>{};
    for (final r in completedRows) {
      seen.putIfAbsent(r.exerciseId, () => r);
    }
    for (final r in bb3Rows) {
      seen.putIfAbsent(r.exerciseId, () => r);
    }
    return seen.values.toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<Wes2SessionController>.value(
      value: _controller,
      child: Consumer<Wes2SessionController>(
        builder: (context, controller, _) => Scaffold(
          appBar: AppBar(
            title: const Text('WES2 (Beta)'),
            actions: [
              IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Undo',
                onPressed: controller.canUndo ? controller.undo : null,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: _loadDay,
              ),
            ],
          ),
          body: Column(
            children: [
              Wes2DayHeader(
                date: controller.selectedDate,
                onSelectDate: null, // Phase 5+
              ),
              const Divider(height: 1),
              Expanded(child: _buildBody(context, controller)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Wes2SessionController controller) {
    switch (controller.loadState) {
      case Wes2LoadState.idle:
      case Wes2LoadState.loading:
        return const Center(child: Wes2WaitForIt());
      case Wes2LoadState.empty:
        return const Wes2EmptyState();
      case Wes2LoadState.loaded:
        final rows = controller.rows;
        final setsLogged =
            rows.expand((r) => r.sets).where((s) => s.hasAnyActual).length;

        // Build flat item list: circuit headers inserted when circuitIndex changes.
        final items = <Widget>[];
        int? prevCi;
        for (final row in rows) {
          if (prevCi == null || row.circuitIndex != prevCi) {
            items.add(
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(
                  'Circuit ${row.circuitIndex + 1}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            );
            prevCi = row.circuitIndex;
          }
          items.add(Wes2ExerciseCard(row: row));
        }

        return Column(
          children: [
            const Wes2TopActionsBar(),
            Expanded(
              child: ListView(children: items),
            ),
            Wes2BottomActionsRow(setsLogged: setsLogged),
          ],
        );
      case Wes2LoadState.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load workout.\n${controller.loadErrorMessage ?? ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red, fontSize: 14),
            ),
          ),
        );
    }
  }
}
