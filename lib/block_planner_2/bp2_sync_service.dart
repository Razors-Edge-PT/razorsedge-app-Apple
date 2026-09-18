/// Cache ⇄ Firestore synchronisation for Block Planner 2.
///
/// Freshness contract (per collection, per athlete):
///   * Each cached collection stores `{count, syncedAt, items}`.
///   * A refresh issues ONE aggregate `count()` (1 billed read) per collection.
///     The collection is re-downloaded only when the server count differs from
///     the cached count, when the cached copy is older than its max age, or
///     when nothing is cached. Otherwise the cached items are kept and no
///     document reads occur.
///   * The max age bounds staleness for in-place edits that a count cannot
///     see (e.g. a renamed exercise), without pretending a local timestamp
///     proves freshness.
///   * The block being edited is a single document read on open, because the
///     WES2 cog can change its `exerciseSettings` at any time.
///   * Deleted custom exercises / templates / blocks change the count and are
///     therefore dropped from the cache on the next refresh.
///
/// The shared catalogue is cached once under [sharedScope] (it is identical
/// for every athlete); every athlete-specific collection is keyed by UID.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../exercise_catalog.dart';
import 'bp2_cache.dart';
import 'bp2_date_utils.dart';
import 'bp2_local_draft.dart';
import 'bp2_models.dart';
import 'bp2_repository.dart';

class Bp2CatalogueSnapshot {
  final List<CatalogExercise> shared;
  final List<CatalogExercise> custom;
  final List<Bp2TemplateSummary> templates;
  final List<Bp2BlockSummary> blocks;
  final String? athleteLabel;

  const Bp2CatalogueSnapshot({
    required this.shared,
    required this.custom,
    required this.templates,
    required this.blocks,
    required this.athleteLabel,
  });

  bool get hasCatalogue => shared.isNotEmpty || custom.isNotEmpty;

  Bp2CatalogueSnapshot copyWith({
    List<CatalogExercise>? shared,
    List<CatalogExercise>? custom,
    List<Bp2TemplateSummary>? templates,
    List<Bp2BlockSummary>? blocks,
    String? athleteLabel,
  }) =>
      Bp2CatalogueSnapshot(
        shared: shared ?? this.shared,
        custom: custom ?? this.custom,
        templates: templates ?? this.templates,
        blocks: blocks ?? this.blocks,
        athleteLabel: athleteLabel ?? this.athleteLabel,
      );
}

class Bp2RefreshResult {
  final Bp2CatalogueSnapshot snapshot;

  /// Collections whose documents were actually re-downloaded.
  final Set<String> refetched;
  const Bp2RefreshResult(this.snapshot, this.refetched);
}

class _Cached<T> {
  final int count;
  final DateTime syncedAt;
  final List<T> items;
  const _Cached(this.count, this.syncedAt, this.items);
}

class Bp2SyncService {
  final Bp2Repository repo;
  final Bp2CacheStore cache;
  final DateTime Function() now;

  /// Max age before a collection is re-downloaded even when its count is
  /// unchanged.
  final Duration sharedMaxAge;
  final Duration athleteMaxAge;

  Bp2SyncService({
    required this.repo,
    required this.cache,
    DateTime Function()? now,
    this.sharedMaxAge = const Duration(hours: 24),
    this.athleteMaxAge = const Duration(hours: 6),
  }) : now = now ?? DateTime.now;

  static const String sharedScope = '_shared';
  static const String kShared = 'catalogue.shared';
  static const String kCustom = 'catalogue.custom';
  static const String kTemplates = 'templates';
  static const String kBlocks = 'blocks';
  static const String kAthleteLabel = 'athlete.label';
  static const String kPendingDraft = 'draft.pending';
  static String kBlock(String id) => 'block.$id';
  static String kDraft(String id) => 'draft.$id';

  // ── Generic cached-collection helpers ─────────────────────────────────────

  Future<_Cached<T>?> _readCollection<T>(
    String uid,
    String key,
    T Function(Map<String, dynamic>) decode,
  ) async {
    final raw = await cache.read(uid, key);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final items = ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => decode(Map<String, dynamic>.from(e)))
          .toList();
      return _Cached<T>(
        (m['count'] as num?)?.toInt() ?? items.length,
        DateTime.tryParse((m['syncedAt'] ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        items,
      );
    } catch (e) {
      debugPrint('[BP2Sync] corrupt cache $key: $e');
      return null;
    }
  }

  Future<void> _writeCollection<T>(
    String uid,
    String key,
    List<T> items,
    Map<String, dynamic> Function(T) encode,
  ) =>
      cache.write(
        uid,
        key,
        jsonEncode({
          'count': items.length,
          'syncedAt': now().toIso8601String(),
          'items': items.map(encode).toList(),
        }),
      );

  /// Count-check one collection; fetch only when stale. Returns the items and
  /// whether a download happened.
  Future<(List<T>, bool)> _sync<T>({
    required String scope,
    required String key,
    required Duration maxAge,
    required bool force,
    required Future<int> Function() count,
    required Future<List<T>> Function() fetch,
    required T Function(Map<String, dynamic>) decode,
    required Map<String, dynamic> Function(T) encode,
  }) async {
    final cached = await _readCollection<T>(scope, key, decode);
    var stale = force || cached == null;
    if (!stale) {
      final remoteCount = await count();
      stale = remoteCount != cached.count ||
          now().difference(cached.syncedAt) > maxAge;
    }
    if (!stale) return (cached!.items, false);
    final items = await fetch();
    await _writeCollection<T>(scope, key, items, encode);
    return (items, true);
  }

  // ── Encoders ──────────────────────────────────────────────────────────────

  static Map<String, dynamic> _encodeExercise(CatalogExercise e) => {
        'id': e.id,
        'name': e.name,
        'category': e.category,
        'bodyParts': e.bodyParts,
        if (e.type != null) 'type': e.type,
        if (e.ownerUid != null) 'ownerUid': e.ownerUid,
      };

  static CatalogExercise _decodeShared(Map<String, dynamic> m) =>
      CatalogExercise.fromMap((m['id'] ?? '').toString(), m,
          source: ExerciseSource.global);

  static CatalogExercise _decodeCustom(Map<String, dynamic> m) =>
      CatalogExercise.fromMap((m['id'] ?? '').toString(), m,
          source: ExerciseSource.custom, ownerUid: m['ownerUid'] as String?);

  // ── Public API ────────────────────────────────────────────────────────────

  /// Cached snapshot only — no network. Null when nothing is cached yet.
  Future<Bp2CatalogueSnapshot?> readCached(String uid) async {
    final shared = await _readCollection(sharedScope, kShared, _decodeShared);
    final custom = await _readCollection(uid, kCustom, _decodeCustom);
    final templates =
        await _readCollection(uid, kTemplates, Bp2TemplateSummary.fromJson);
    final blocks =
        await _readCollection(uid, kBlocks, Bp2BlockSummary.fromJson);
    final label = await cache.read(uid, kAthleteLabel);
    if (shared == null &&
        custom == null &&
        templates == null &&
        blocks == null) {
      return null;
    }
    return Bp2CatalogueSnapshot(
      shared: shared?.items ?? const [],
      custom: custom?.items ?? const [],
      templates: templates?.items ?? const [],
      blocks: blocks?.items ?? const [],
      athleteLabel: label,
    );
  }

  /// One-shot freshness check + selective download. Throws on network failure
  /// so the caller can keep showing cached data with a Retry affordance.
  Future<Bp2RefreshResult> refresh(String uid, {bool force = false}) async {
    final refetched = <String>{};

    final (shared, s1) = await _sync<CatalogExercise>(
      scope: sharedScope,
      key: kShared,
      maxAge: sharedMaxAge,
      force: force,
      count: repo.countGlobalExercises,
      fetch: repo.fetchGlobalExercises,
      decode: _decodeShared,
      encode: _encodeExercise,
    );
    if (s1) refetched.add(kShared);

    final (custom, s2) = await _sync<CatalogExercise>(
      scope: uid,
      key: kCustom,
      maxAge: athleteMaxAge,
      force: force,
      count: () => repo.countCustomExercises(uid),
      fetch: () => repo.fetchCustomExercises(uid),
      decode: _decodeCustom,
      encode: _encodeExercise,
    );
    if (s2) refetched.add(kCustom);

    final (templates, s3) = await _sync<Bp2TemplateSummary>(
      scope: uid,
      key: kTemplates,
      maxAge: athleteMaxAge,
      force: force,
      count: () => repo.countTemplates(uid),
      fetch: () => repo.fetchTemplates(uid),
      decode: Bp2TemplateSummary.fromJson,
      encode: (t) => t.toJson(),
    );
    if (s3) refetched.add(kTemplates);

    final (blocks, s4) = await _sync<Bp2BlockSummary>(
      scope: uid,
      key: kBlocks,
      maxAge: athleteMaxAge,
      force: force,
      count: () => repo.countBlocks(uid),
      fetch: () => repo.fetchBlockSummaries(uid),
      decode: Bp2BlockSummary.fromJson,
      encode: (b) => b.toJson(),
    );
    if (s4) refetched.add(kBlocks);

    var label = await cache.read(uid, kAthleteLabel);
    if (label == null || force) {
      label = await repo.fetchAthleteLabel(uid);
      await cache.write(uid, kAthleteLabel, label);
      refetched.add(kAthleteLabel);
    }

    return Bp2RefreshResult(
      Bp2CatalogueSnapshot(
        shared: shared,
        custom: custom,
        templates: templates,
        blocks: blocks,
        athleteLabel: label,
      ),
      refetched,
    );
  }

  /// Non-blocking first-use warm: downloads only what is not cached yet.
  Future<void> warm(String uid) async {
    try {
      await refresh(uid);
    } catch (e) {
      debugPrint('[BP2Sync] warm($uid) skipped: $e');
    }
  }

  // ── Custom exercise added locally ─────────────────────────────────────────

  /// Inserts one freshly created custom exercise into the cached custom pool
  /// (count bumped) so the next refresh does not re-download the collection.
  Future<List<CatalogExercise>> addCustomExerciseToCache(
      String uid, CatalogExercise e) async {
    final cached = await _readCollection(uid, kCustom, _decodeCustom);
    final items = [...?cached?.items]..removeWhere((x) => x.id == e.id);
    items.add(e);
    await _writeCollection<CatalogExercise>(
        uid, kCustom, items, _encodeExercise);
    return items;
  }

  /// Same for an admin-created GLOBAL exercise (shared scope).
  Future<List<CatalogExercise>> addSharedExerciseToCache(
      CatalogExercise e) async {
    final cached = await _readCollection(sharedScope, kShared, _decodeShared);
    final items = [...?cached?.items]..removeWhere((x) => x.id == e.id);
    items.add(e);
    await _writeCollection<CatalogExercise>(
        sharedScope, kShared, items, _encodeExercise);
    return items;
  }

  /// Replaces the cached block summaries (after save/activation).
  Future<void> writeBlockSummaries(String uid, List<Bp2BlockSummary> blocks) =>
      _writeCollection<Bp2BlockSummary>(
          uid, kBlocks, blocks, (b) => b.toJson());

  // ── Single block ──────────────────────────────────────────────────────────

  Future<Bp2BlockRecord?> readCachedBlock(String uid, String blockId) async {
    final raw = await cache.read(uid, kBlock(blockId));
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final start = DateTime.parse(m['start'] as String);
      final end = DateTime.parse(m['end'] as String);
      return Bp2BlockRecord(
        id: blockId,
        name: (m['name'] ?? '').toString(),
        range: Bp2DateUtils.normalizeRange(start, end),
        isActive: m['isActive'] == true,
        exerciseSettings:
            Bp2Repository.parseExerciseSettings(m['exerciseSettings']),
        existsRemotely: m['existsRemotely'] == true,
      );
    } catch (e) {
      debugPrint('[BP2Sync] corrupt block cache $blockId: $e');
      return null;
    }
  }

  Future<void> writeBlock(String uid, Bp2BlockRecord block) => cache.write(
        uid,
        kBlock(block.id),
        jsonEncode({
          'name': block.name,
          'start': block.range.start.toIso8601String(),
          'end': block.range.end.toIso8601String(),
          'isActive': block.isActive,
          'exerciseSettings': block.exerciseSettings,
          'existsRemotely': block.existsRemotely,
        }),
      );

  /// One document read; caches the result.
  Future<Bp2BlockRecord?> refreshBlock(String uid, String blockId) async {
    final block = await repo.fetchBlock(uid, blockId);
    if (block != null) await writeBlock(uid, block);
    return block;
  }

  // ── Durable drafts ────────────────────────────────────────────────────────

  Future<Bp2LocalDraft?> readDraft(String uid, String blockId) async {
    final raw = await cache.read(uid, kDraft(blockId));
    if (raw == null) return null;
    try {
      return Bp2LocalDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeDraft(String uid, Bp2LocalDraft draft) =>
      cache.write(uid, kDraft(draft.blockId), jsonEncode(draft.toJson()));

  Future<void> clearDraft(String uid, String blockId) =>
      cache.delete(uid, kDraft(blockId));

  Future<String?> readPendingDraftId(String uid) =>
      cache.read(uid, kPendingDraft);
  Future<void> writePendingDraftId(String uid, String id) =>
      cache.write(uid, kPendingDraft, id);
  Future<void> clearPendingDraftId(String uid) =>
      cache.delete(uid, kPendingDraft);
}
