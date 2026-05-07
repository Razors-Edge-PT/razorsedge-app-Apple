import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'user_context.dart';
import 'WES2_controller.dart';
import 'WES2_repository.dart';
import 'WES2_widgets/WES2_day_header.dart';
import 'WES2_widgets/WES2_empty_state.dart';
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

  /// Load the current day from Firestore. Safe to call again for manual refresh.
  /// beginLoad() increments the epoch; stale completions are discarded via
  /// the epoch check inside setRows/setLoadError.
  Future<void> _loadDay() async {
    final epoch = _controller.beginLoad();
    try {
      final rows = await _repository.loadDay(
        uid: _controller.actingUid,
        date: _controller.selectedDate,
      );
      if (!mounted) return;
      _controller.setRows(rows, epoch);
    } catch (e) {
      if (!mounted) return;
      _controller.setLoadError(e.toString(), epoch);
    }
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
                onSelectDate: null, // Phase 4+
              ),
              const Divider(height: 1),
              Expanded(child: _buildBody(controller)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(Wes2SessionController controller) {
    switch (controller.loadState) {
      case Wes2LoadState.idle:
      case Wes2LoadState.loading:
        return const Center(child: Wes2WaitForIt());
      case Wes2LoadState.empty:
        return const Wes2EmptyState();
      case Wes2LoadState.loaded:
        return ListView.builder(
          itemCount: controller.rows.length,
          itemBuilder: (_, i) => Wes2ExerciseCard(row: controller.rows[i]),
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
