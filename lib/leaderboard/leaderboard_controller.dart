/// Leaderboard view-model: the selected period, its top
/// [LeaderboardRepository.boardSize] rows and the loading / empty / error
/// states. No Firestore here — [LeaderboardRepository] does the reading.
///
/// Each board shows ranks 1–20 only: ONE query limited to 20, and never a
/// further page (there is no "Show more"), so rank 21 is never shown.
///
/// Each period keeps its own loaded rows, so switching This Month ⇄ All Time
/// and back does not refetch. Stale responses (a slow page for a period the
/// user has already left, or superseded by a retry) are discarded.
///
/// Each period also keeps its board's category medals, loaded BESIDE the
/// first page and never blocking it: rows show as soon as they arrive and
/// gain their medals when the (one-document) snapshot lands. A failed medal
/// load keeps whatever medals were last shown. The snapshot is read again
/// whenever an already-loaded board is selected and when the app resumes, so
/// a session never keeps a board's first (possibly empty) medals for good.
///
/// ── Optional age-adjusted view ───────────────────────────────────────────
/// RAW IS ALWAYS THE DEFAULT. The age view is local presentation state only:
/// never stored (no SharedPreferences, Firestore or restoration), and
/// [resetToRaw] — called on leaving the leaderboard tab, pushing another
/// route, app background/pause/detach and disposal — turns it off and
/// discards any age page still in flight, so a late result can never replace
/// the raw board. Each period keeps its own age board, loaded on demand from
/// the server-ranked age projection; the raw boards are untouched by it.
///
/// Each period also keeps its board extras ([LeaderboardBoardInfo]): the
/// raw-board silver set (shown on raw rows only) and the age view's counts.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'leaderboard_medals.dart';
import 'leaderboard_models.dart';
import 'leaderboard_repository.dart';

enum LeaderboardStatus { idle, loading, ready, empty, error }

class _PeriodState {
  LeaderboardStatus status = LeaderboardStatus.idle;
  List<LeaderboardEntry> entries = const <LeaderboardEntry>[];
  bool isFromCache = false;
  Object? error;
  int generation = 0;
  LeaderboardMedals? medals;
  int medalGeneration = 0;
  LeaderboardBoardInfo info = LeaderboardBoardInfo.empty;
  int infoGeneration = 0;

  // The age-adjusted view of this period.
  LeaderboardStatus ageStatus = LeaderboardStatus.idle;
  List<LeaderboardEntry> ageEntries = const <LeaderboardEntry>[];
  bool ageFromCache = false;
  Object? ageError;
  int ageGeneration = 0;
}

class LeaderboardController extends ChangeNotifier {
  LeaderboardController({
    required LeaderboardRepository repository,
    LeaderboardPeriod initialPeriod = LeaderboardPeriod.thisMonth,
  })  : _repo = repository,
        _period = initialPeriod;

  final LeaderboardRepository _repo;
  LeaderboardPeriod _period;
  final Map<LeaderboardPeriod, _PeriodState> _states =
      <LeaderboardPeriod, _PeriodState>{
    for (final LeaderboardPeriod p in LeaderboardPeriod.values)
      p: _PeriodState(),
  };
  bool _disposed = false;

  bool _ageView = false;

  LeaderboardPeriod get period => _period;
  _PeriodState get _s => _states[_period]!;

  /// True while the optional age-adjusted view is shown (never the default).
  bool get ageView => _ageView;

  LeaderboardStatus get status => _ageView ? _s.ageStatus : _s.status;
  List<LeaderboardEntry> get entries => _ageView ? _s.ageEntries : _s.entries;
  bool get isFromCache => _ageView ? _s.ageFromCache : _s.isFromCache;
  Object? get error => _ageView ? _s.ageError : _s.error;

  /// The shown board's extras (silver set, age-view counts).
  LeaderboardBoardInfo get boardInfo => _s.info;

  /// Raw-board silver for [uid]. Never in the age view.
  bool silverFor(String uid) => !_ageView && _s.info.silverUids.contains(uid);

  /// [uid]'s row on the shown period's RAW board, if loaded (the age view's
  /// medal details show the raw breakdown).
  LeaderboardEntry? rawEntryFor(String uid) {
    for (final LeaderboardEntry e in _s.entries) {
      if (e.uid == uid) return e;
    }
    return null;
  }

  /// Turns the age-adjusted view on or off for every period.
  Future<void> setAgeView(bool on) async {
    if (on == _ageView) return;
    _ageView = on;
    _notify();
    if (on && _s.ageStatus == LeaderboardStatus.idle) await _loadAge(_period);
  }

  Future<void> toggleAgeView() => setAgeView(!_ageView);

  /// Back to the raw default; any age page still loading is discarded.
  void resetToRaw() {
    for (final _PeriodState st in _states.values) {
      st.ageGeneration += 1;
      if (st.ageStatus == LeaderboardStatus.loading) {
        st.ageStatus = LeaderboardStatus.idle;
      }
    }
    if (!_ageView) return;
    _ageView = false;
    _notify();
  }

  /// The shown board's medals; null until its snapshot has loaded.
  LeaderboardMedals? get medals => _s.medals;

  /// [uid]'s medals on the shown board, in category order (none until loaded).
  List<LeaderboardMedal> medalsFor(String uid) =>
      _s.medals?.forUid(uid) ?? const <LeaderboardMedal>[];

  /// Reads the all-time record line for a medal's detail.
  Future<String?> medalRecordSource(LeaderboardMedal medal) =>
      _repo.fetchMedalRecordSource(medal);

  /// The key of the period being shown ('YYYY-MM' or 'all_time').
  String get periodKey => _repo.periodKey(_period);

  /// Loads the current period if it has not been loaded yet.
  Future<void> start() async {
    if (_s.status == LeaderboardStatus.idle) await _loadFirst(_period);
  }

  /// Reads the shown board's medal snapshot again (one document). The rows
  /// are not refetched; a failed read keeps the medals already shown.
  Future<void> reloadMedals() async {
    if (_s.status == LeaderboardStatus.idle) return;
    await _loadMedals(_period);
  }

  Future<void> selectPeriod(LeaderboardPeriod next) async {
    if (next == _period) return;
    _period = next;
    _notify();
    // A board loaded earlier keeps its rows, but its medals are read again:
    // they may have been empty or older when it was first shown.
    unawaited(reloadMedals());
    await start();
    if (_ageView && _s.ageStatus == LeaderboardStatus.idle) {
      await _loadAge(_period);
    }
  }

  Future<void> retry() => _ageView ? _loadAge(_period) : _loadFirst(_period);

  Future<void> refresh() => _ageView ? _loadAge(_period) : _loadFirst(_period);

  Future<void> _loadFirst(LeaderboardPeriod p) async {
    final _PeriodState s = _states[p]!;
    final int gen = ++s.generation;
    s.status = LeaderboardStatus.loading;
    s.error = null;
    _notify();
    unawaited(_loadMedals(p));
    unawaited(_loadInfo(p));
    try {
      final LeaderboardPageResult page =
          await _repo.fetchPage(p, limit: LeaderboardRepository.boardSize);
      if (gen != s.generation) return;
      // The server's order, ranks 1–20; never a row beyond the board.
      s.entries = List<LeaderboardEntry>.unmodifiable(page.entries
          .where(
              (LeaderboardEntry e) => e.rank <= LeaderboardRepository.boardSize)
          .take(LeaderboardRepository.boardSize));
      s.isFromCache = page.isFromCache;
      s.status = page.entries.isEmpty
          ? LeaderboardStatus.empty
          : LeaderboardStatus.ready;
    } catch (e) {
      if (gen != s.generation) return;
      s.error = e;
      s.status = LeaderboardStatus.error;
    }
    _notify();
  }

  Future<void> _loadAge(LeaderboardPeriod p) async {
    final _PeriodState s = _states[p]!;
    final int gen = ++s.ageGeneration;
    s.ageStatus = LeaderboardStatus.loading;
    s.ageError = null;
    _notify();
    unawaited(_loadInfo(p));
    try {
      final LeaderboardPageResult page =
          await _repo.fetchAgePage(p, limit: LeaderboardRepository.boardSize);
      // Superseded, or the view was reset to raw meanwhile: never shown.
      if (gen != s.ageGeneration) return;
      s.ageEntries = List<LeaderboardEntry>.unmodifiable(page.entries
          .where((LeaderboardEntry e) =>
              e.ageAdjusted && e.rank <= LeaderboardRepository.boardSize)
          .take(LeaderboardRepository.boardSize));
      s.ageFromCache = page.isFromCache;
      s.ageStatus = s.ageEntries.isEmpty
          ? LeaderboardStatus.empty
          : LeaderboardStatus.ready;
    } catch (e) {
      if (gen != s.ageGeneration) return;
      s.ageError = e;
      s.ageStatus = LeaderboardStatus.error;
    }
    _notify();
  }

  Future<void> _loadInfo(LeaderboardPeriod p) async {
    final _PeriodState s = _states[p]!;
    final int gen = ++s.infoGeneration;
    try {
      final LeaderboardBoardInfo info = await _repo.fetchBoardInfo(p);
      if (gen != s.infoGeneration) return;
      s.info = info;
      _notify();
    } catch (_) {
      // Keep the last extras shown; rows are unaffected.
    }
  }

  Future<void> _loadMedals(LeaderboardPeriod p) async {
    final _PeriodState s = _states[p]!;
    final int gen = ++s.medalGeneration;
    try {
      final LeaderboardMedals m = await _repo.fetchMedals(p);
      if (gen != s.medalGeneration) return;
      s.medals = m;
      _notify();
    } catch (_) {
      // Keep the last medals shown; the board itself is unaffected.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
