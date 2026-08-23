// progression_history_store.dart
//
// Canonical, per-athlete progression-history snapshot.
//
// WHY THIS EXISTS
// ---------------
// Progression hints used to be fed by three different, racing history loaders:
//
//   * WarmupService seeded PeriodizationModelUtils.savedWorkoutsList cache-first
//     ("cache is non-empty → assume the whole collection is cached"), then built
//     a NAME-keyed top-set map.
//   * WES2 re-fetched only [blockStart .. selectedDate] from the server and
//     rebuilt an ID-keyed top-set map from that bounded window, discarding every
//     older workout the earlier loader had provided.
//   * Progression models and the default/baseline weight each resolved exercise
//     identity independently, so they could disagree about what "history" meant.
//
// The result was progression baselines that silently degraded to the generic
// no-history default (5 kg dumbbell / 20 kg barbell) even for exercises with
// years of top sets, and a partial Firestore cache that could masquerade as a
// complete athlete history.
//
// THIS STORE
// ----------
//   * hydrates an athlete's workout history exactly once per app session
//     (deduplicated by an in-flight Future keyed on UID),
//   * never treats an arbitrary Firestore cache read as complete — a cached
//     snapshot is authoritative only when WE previously recorded a complete
//     server hydration for that UID and the cache still holds at least as many
//     documents,
//   * publishes the snapshot through PeriodizationModelUtils.applyHistorySnapshot,
//     which builds every derived index (top sets by exerciseId, used combos,
//     DUP exposure dates) in a single pass,
//   * supports targeted invalidation (one day document) instead of
//     re-downloading everything after each edit.
//
// No progression code path performs Firestore I/O. All network work lives here.

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'periodization_model_utils.dart';

/// One athlete's hydrated workout history.
class ProgressionHistorySnapshot {
  ProgressionHistorySnapshot({
    required this.uid,
    required this.docsByDay,
    required this.hydratedAt,
    required this.authoritative,
  });

  final String uid;

  /// yyyy-MM-dd → workout document. One entry per workout day, which is the
  /// natural key of `users/{uid}/workouts`.
  final Map<String, Map<String, dynamic>> docsByDay;

  final DateTime hydratedAt;

  /// True only when this snapshot came from a complete server read, or from a
  /// Firestore cache read that a previously recorded complete server hydration
  /// vouches for. A partial cache is NEVER authoritative.
  final bool authoritative;

  int get workoutCount => docsByDay.length;

  /// Cached newest-first projection handed to PeriodizationModelUtils, so a
  /// re-publish of the same snapshot is an identity check, not a rebuild.
  List<Map<String, dynamic>>? publishedList;

  /// Newest-first list, the ordering every downstream history consumer expects.
  List<Map<String, dynamic>> toWorkoutList() {
    final keys = docsByDay.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final k in keys) docsByDay[k]!];
  }
}

class ProgressionHistoryStore {
  ProgressionHistoryStore._();

  static final ProgressionHistoryStore instance = ProgressionHistoryStore._();

  /// How long a hydrated snapshot is served without a background refresh.
  /// Inside this window, reopening WES2 for the same athlete performs ZERO
  /// history network work.
  static const Duration freshFor = Duration(minutes: 15);

  static const String _markerPrefix = 'progression_history_complete:';

  final Map<String, ProgressionHistorySnapshot> _snapshots = {};
  final Map<String, Future<void>> _inFlight = {};
  final Map<String, Set<String>> _dirtyDays = {};
  final Set<String> _forcedStale = {};

  /// Instrumentation (tests + diagnostics): how many hydration operations —
  /// full or day-patch — this store has performed.
  int hydrationCount = 0;
  int fullHydrationCount = 0;
  int dayPatchCount = 0;

  // ── Test seams ────────────────────────────────────────────────────────────
  // Set in unit tests so the store can be exercised without Firebase.
  @visibleForTesting
  Future<List<Map<String, dynamic>>> Function(String uid)? debugServerFetch;
  @visibleForTesting
  Future<List<Map<String, dynamic>>> Function(String uid)? debugCacheFetch;
  @visibleForTesting
  Future<Map<String, dynamic>?> Function(String uid, String ymd)? debugDayFetch;

  @visibleForTesting
  void debugReset() {
    _snapshots.clear();
    _inFlight.clear();
    _dirtyDays.clear();
    _forcedStale.clear();
    hydrationCount = 0;
    fullHydrationCount = 0;
    dayPatchCount = 0;
  }

  ProgressionHistorySnapshot? snapshotFor(String uid) => _snapshots[uid];

  /// A refresh already running for [uid], or null. Callers that were served an
  /// existing snapshot can await this to re-apply hints once fresher history
  /// lands — without ever blocking the first paint on it.
  Future<void>? pendingRefresh(String uid) => _inFlight[uid];

  static String ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Guarantees that [uid]'s history is loaded and published to
  /// PeriodizationModelUtils before progression hints are computed.
  ///
  /// * No snapshot yet → awaits ONE authoritative hydration (deduplicated, so a
  ///   Warmup pass and a WES2 pass share the same network operation).
  /// * Usable snapshot → returns immediately after re-publishing it for this
  ///   athlete, and starts a background refresh when it has gone stale or a
  ///   workout day was edited. Callers never block on that refresh.
  Future<void> ensureHydrated({required String uid}) {
    if (uid.isEmpty) return Future<void>.value();

    final existing = _snapshots[uid];
    if (existing != null && existing.authoritative) {
      _publish(existing);
      if (_needsRefresh(uid, existing)) {
        // Fire-and-forget: the caller keeps the currently valid history.
        // ignore: discarded_futures
        _startRefresh(uid);
      }
      return Future<void>.value();
    }

    final inFlight = _inFlight[uid];
    if (inFlight != null) return inFlight;
    return _startRefresh(uid);
  }

  /// Marks one workout day as edited. The next [ensureHydrated] re-reads just
  /// that day document instead of the whole collection.
  void markDayDirty({required String uid, required DateTime date}) {
    if (uid.isEmpty) return;
    _dirtyDays.putIfAbsent(uid, () => <String>{}).add(ymd(date));
  }

  /// Forces the next [ensureHydrated] to perform a full server refresh
  /// (app resume, or any event that may have added workouts elsewhere).
  void markStale(String uid) {
    if (uid.isNotEmpty) _forcedStale.add(uid);
  }

  /// Drops everything cached for [uid] (sign-out / account switch cleanup).
  void forget(String uid) {
    _snapshots.remove(uid);
    _inFlight.remove(uid);
    _dirtyDays.remove(uid);
    _forcedStale.remove(uid);
    if (PeriodizationModelUtils.historyUid == uid) {
      PeriodizationModelUtils.clearHistorySnapshot();
    }
  }

  bool _needsRefresh(String uid, ProgressionHistorySnapshot snap) {
    if (_forcedStale.contains(uid)) return true;
    if ((_dirtyDays[uid]?.isNotEmpty ?? false)) return true;
    return DateTime.now().difference(snap.hydratedAt) > freshFor;
  }

  Future<void> _startRefresh(String uid) {
    final running = _inFlight[uid];
    if (running != null) return running;

    final existing = _snapshots[uid];
    final dirty = _dirtyDays[uid];
    final bool dayPatchOnly = existing != null &&
        existing.authoritative &&
        !_forcedStale.contains(uid) &&
        DateTime.now().difference(existing.hydratedAt) <= freshFor &&
        dirty != null &&
        dirty.isNotEmpty;

    final future =
        (dayPatchOnly ? _patchDays(uid, existing) : _fullHydrate(uid))
            .whenComplete(() {
      _inFlight.remove(uid);
    });
    _inFlight[uid] = future;
    return future;
  }

  // ── Hydration ─────────────────────────────────────────────────────────────

  Future<void> _fullHydrate(String uid) async {
    hydrationCount++;
    fullHydrationCount++;
    // Snapshot the pending invalidations BEFORE the read starts. A day edited
    // while this fetch is in flight may not be reflected in the response, so
    // only the days we knew about up front are considered resolved by it.
    final claimedDirty = Set<String>.from(_dirtyDays[uid] ?? const <String>{});
    final claimedStale = _forcedStale.contains(uid);
    try {
      final docs = await _fetchFromServer(uid);
      await _writeCompletenessMarker(uid, docs.length);
      _dirtyDays[uid]?.removeAll(claimedDirty);
      if (_dirtyDays[uid]?.isEmpty ?? false) _dirtyDays.remove(uid);
      if (claimedStale) _forcedStale.remove(uid);
      _store(uid, docs, authoritative: true);
      debugPrint('[History] hydrated uid=$uid docs=${docs.length} (server)');
    } catch (e) {
      // Server unavailable (offline / transient). A Firestore cache read is
      // only trustworthy when a previous COMPLETE hydration vouches for it.
      debugPrint('[History] server hydration failed for $uid: $e');
      List<Map<String, dynamic>> cached = const <Map<String, dynamic>>[];
      try {
        cached = await _fetchFromCache(uid);
      } catch (_) {/* cache cold or disabled */}

      final marker = await _readCompletenessMarker(uid);
      final bool cacheVouchedFor =
          marker != null && cached.length >= marker && cached.isNotEmpty;

      if (_snapshots[uid] != null && !cacheVouchedFor) {
        // Keep whatever we already had rather than downgrading it.
        _publish(_snapshots[uid]!);
        return;
      }

      _store(uid, cached, authoritative: cacheVouchedFor);
      debugPrint('[History] uid=$uid fell back to cache docs=${cached.length} '
          'authoritative=$cacheVouchedFor (marker=$marker)');
    }
  }

  Future<void> _patchDays(
      String uid, ProgressionHistorySnapshot existing) async {
    // Days stay marked until the patch succeeds, so a day edited again while
    // its document is being re-read is simply re-patched next time rather than
    // silently dropped.
    final days = Set<String>.from(_dirtyDays[uid] ?? const <String>{});
    if (days.isEmpty) {
      _publish(existing);
      return;
    }
    hydrationCount++;
    dayPatchCount++;
    final docsByDay =
        Map<String, Map<String, dynamic>>.from(existing.docsByDay);
    try {
      for (final day in days) {
        final doc = await _fetchDay(uid, day);
        if (doc == null) {
          docsByDay.remove(day);
        } else {
          docsByDay[day] = doc;
        }
      }
      _dirtyDays[uid]?.removeAll(days);
      if (_dirtyDays[uid]?.isEmpty ?? false) _dirtyDays.remove(uid);
      _storeMap(uid, docsByDay, authoritative: existing.authoritative);
      debugPrint('[History] patched ${days.length} day(s) for uid=$uid');
    } catch (e) {
      // Patch failed — the days stay marked, so the next pass retries them,
      // and the previous (still valid) snapshot keeps serving hints.
      _publish(existing);
      debugPrint('[History] day patch failed for $uid: $e');
    }
  }

  void _store(String uid, List<Map<String, dynamic>> docs,
      {required bool authoritative}) {
    final byDay = <String, Map<String, dynamic>>{};
    for (final d in docs) {
      var key = (d['_dayKey'] ?? '').toString();
      if (key.isEmpty) {
        final raw = (d['date'] ?? '').toString();
        key = raw.length >= 10 ? raw.substring(0, 10) : raw;
      }
      if (key.isEmpty) continue;
      byDay[key] = d;
    }
    _storeMap(uid, byDay, authoritative: authoritative);
  }

  void _storeMap(String uid, Map<String, Map<String, dynamic>> byDay,
      {required bool authoritative}) {
    final snap = ProgressionHistorySnapshot(
      uid: uid,
      docsByDay: byDay,
      hydratedAt: DateTime.now(),
      authoritative: authoritative,
    );
    _snapshots[uid] = snap;
    _publish(snap);
  }

  /// Publishes into PeriodizationModelUtils. Cheap and idempotent: the index is
  /// only rebuilt when the workout list or the acting athlete actually changed.
  void _publish(ProgressionHistorySnapshot snap) {
    if (PeriodizationModelUtils.historyUid == snap.uid &&
        identical(
            PeriodizationModelUtils.savedWorkoutsList, snap.publishedList)) {
      return;
    }
    final list = snap.toWorkoutList();
    snap.publishedList = list;
    PeriodizationModelUtils.applyHistorySnapshot(uid: snap.uid, workouts: list);
  }

  // ── Firestore access (the ONLY history I/O in the app) ────────────────────

  Map<String, dynamic> _normalise(
      String uid, String docId, Map<String, dynamic> data) {
    final out = Map<String, dynamic>.from(data);
    out['date'] ??= docId;
    // uid-stamp so a coach switching athletes can never blend two histories.
    out['_uid'] = uid;
    // Stable per-document key. New documents are keyed by yyyy-MM-dd already;
    // legacy documents with an auto-id and a Timestamp date fall back to the
    // document id so they can never collide or be silently dropped.
    final rawDate = out['date'];
    final asString = rawDate is String ? rawDate : '';
    out['_dayKey'] = (asString.length >= 10 &&
            DateTime.tryParse(asString.substring(0, 10)) != null)
        ? asString.substring(0, 10)
        : docId;
    return out;
  }

  Future<List<Map<String, dynamic>>> _fetchFromServer(String uid) async {
    final override = debugServerFetch;
    if (override != null) return override(uid);
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .get(const GetOptions(source: Source.server));
    return snap.docs.map((d) => _normalise(uid, d.id, d.data())).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchFromCache(String uid) async {
    final override = debugCacheFetch;
    if (override != null) return override(uid);
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .get(const GetOptions(source: Source.cache));
    return snap.docs.map((d) => _normalise(uid, d.id, d.data())).toList();
  }

  Future<Map<String, dynamic>?> _fetchDay(String uid, String day) async {
    final override = debugDayFetch;
    if (override != null) return override(uid, day);
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('workouts')
        .doc(day)
        .get(const GetOptions(source: Source.server));
    final data = doc.data();
    if (!doc.exists || data == null) return null;
    return _normalise(uid, doc.id, data);
  }

  // ── Completeness marker ───────────────────────────────────────────────────
  //
  // Records that WE completed a full server hydration for this athlete, and how
  // many documents it contained. Without this, a Firestore local cache holding
  // an arbitrary subset of workouts (Warmup's old `limit()` prefetch left one
  // behind on every launch) could be mistaken for the full history.

  Future<void> _writeCompletenessMarker(String uid, int count) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_markerPrefix$uid',
        jsonEncode({'count': count, 'at': DateTime.now().toIso8601String()}),
      );
    } catch (_) {
      /* marker is an optimisation, never a correctness requirement */
    }
  }

  Future<int?> _readCompletenessMarker(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_markerPrefix$uid');
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['count'] is num) {
        return (decoded['count'] as num).toInt();
      }
    } catch (_) {/* treat as "never completed" */}
    return null;
  }
}
