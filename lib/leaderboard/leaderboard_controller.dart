/// Leaderboard view-model: the selected period, its rows, paging and the
/// loading / empty / error states. No Firestore here — [LeaderboardRepository]
/// does the reading.
///
/// Each period keeps its own loaded rows, so switching This Month ⇄ All Time
/// and back does not refetch. Stale responses (a slow page for a period the
/// user has already left, or superseded by a retry) are discarded.
///
/// Each period also keeps its board's category medals, loaded BESIDE the
/// first page and never blocking it: rows show as soon as they arrive and
/// gain their medals when the (one-document) snapshot lands. A failed medal
/// load keeps whatever medals were last shown.
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
  Object? cursor;
  bool hasMore = false;
  bool loadingMore = false;
  bool isFromCache = false;
  Object? error;
  int generation = 0;
  LeaderboardMedals? medals;
  int medalGeneration = 0;
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

  LeaderboardPeriod get period => _period;
  _PeriodState get _s => _states[_period]!;
  LeaderboardStatus get status => _s.status;
  List<LeaderboardEntry> get entries => _s.entries;
  bool get hasMore => _s.hasMore;
  bool get loadingMore => _s.loadingMore;
  bool get isFromCache => _s.isFromCache;
  Object? get error => _s.error;

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

  Future<void> selectPeriod(LeaderboardPeriod next) async {
    if (next == _period) return;
    _period = next;
    _notify();
    await start();
  }

  Future<void> retry() => _loadFirst(_period);

  Future<void> refresh() => _loadFirst(_period);

  Future<void> loadMore() async {
    final LeaderboardPeriod p = _period;
    final _PeriodState s = _states[p]!;
    if (s.loadingMore || !s.hasMore || s.status != LeaderboardStatus.ready) {
      return;
    }
    s.loadingMore = true;
    final int gen = s.generation;
    _notify();
    try {
      final LeaderboardPageResult page = await _repo.fetchPage(
        p,
        after: s.cursor,
        startRank: s.entries.length + 1,
      );
      if (gen != s.generation) return;
      s.entries = List<LeaderboardEntry>.unmodifiable(
          <LeaderboardEntry>[...s.entries, ...page.entries]);
      s.cursor = page.cursor;
      s.hasMore = page.hasMore;
    } catch (e) {
      if (gen != s.generation) return;
      // Keep what is shown; the Load more control stays available to retry.
      s.error = e;
    } finally {
      if (gen == s.generation) {
        s.loadingMore = false;
        _notify();
      }
    }
  }

  Future<void> _loadFirst(LeaderboardPeriod p) async {
    final _PeriodState s = _states[p]!;
    final int gen = ++s.generation;
    s.status = LeaderboardStatus.loading;
    s.error = null;
    s.loadingMore = false;
    _notify();
    unawaited(_loadMedals(p));
    try {
      final LeaderboardPageResult page = await _repo.fetchPage(p);
      if (gen != s.generation) return;
      s.entries = List<LeaderboardEntry>.unmodifiable(page.entries);
      s.cursor = page.cursor;
      s.hasMore = page.hasMore;
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
