/// State/controller for Block Planner 2 (Provider `ChangeNotifier`).
///
/// Owns: selected-athlete binding, the block draft (name/dates), per-exercise
/// raw drafts, dirty tracking, catalogue grouping, cache/freshness
/// orchestration, save/exit-save and activation. Presentation lives in
/// `bp2_screen.dart`; every pure transformation lives in the resolver /
/// classifier / date utils.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../block_creation_helper.dart' show kDefaultBlockWeeks;
import '../block_exercise_defaults_repository.dart';
import '../exercise_catalog.dart';
import 'bp2_date_utils.dart';
import 'bp2_exercise_classifier.dart';
import 'bp2_local_draft.dart';
import 'bp2_models.dart';
import 'bp2_repository.dart';
import 'bp2_settings_resolver.dart';
import 'bp2_sync_service.dart';

class Bp2FieldFocus {
  final String? exerciseId; // null → block name
  final String field;
  const Bp2FieldFocus({this.exerciseId, required this.field});
}

class Bp2SaveOutcome {
  final bool success;
  final bool nothingToSave;
  final bool offlineQueued;
  final String? error;
  final Bp2FieldFocus? focus;

  const Bp2SaveOutcome._({
    required this.success,
    this.nothingToSave = false,
    this.offlineQueued = false,
    this.error,
    this.focus,
  });

  static const nothing = Bp2SaveOutcome._(success: true, nothingToSave: true);
  static const busy =
      Bp2SaveOutcome._(success: false, error: 'Save already in progress.');
  factory Bp2SaveOutcome.ok({bool offline = false}) =>
      Bp2SaveOutcome._(success: true, offlineQueued: offline);
  factory Bp2SaveOutcome.invalid(String message, Bp2FieldFocus focus) =>
      Bp2SaveOutcome._(success: false, error: message, focus: focus);
  factory Bp2SaveOutcome.failed(String message) =>
      Bp2SaveOutcome._(success: false, error: message);
}

class Bp2ActivationOutcome {
  final bool success;
  final String? error;
  const Bp2ActivationOutcome(this.success, [this.error]);
}

class Bp2Controller extends ChangeNotifier {
  final Bp2SyncService sync;
  final Bp2Repository repo;
  final DateTime Function() _now;
  final int defaultWeeks;
  final Duration draftDebounce;

  /// How long a Firestore write may take before it is treated as queued
  /// offline (the write itself stays durable in Firestore's local queue).
  final Duration writeTimeout;

  Bp2Controller({
    required this.sync,
    required this.repo,
    DateTime Function()? now,
    this.defaultWeeks = kDefaultBlockWeeks,
    this.draftDebounce = const Duration(milliseconds: 400),
    this.writeTimeout = const Duration(seconds: 8),
  }) : _now = now ?? DateTime.now;

  // ── Athlete binding / generation guard ────────────────────────────────────

  String? _uid;
  String? _requestedBlockId;
  int _gen = 0;
  bool _disposed = false;

  String? get uid => _uid;
  bool _live(int gen) => !_disposed && gen == _gen;

  // ── Block state ───────────────────────────────────────────────────────────

  Bp2BlockRecord? _block;
  String _persistedName = '';
  Bp2DateRange? _persistedRange;
  bool _nameIsAuto = true;
  bool _blockTouched = false;
  String? _nameError;
  bool _blockLoaded = false;

  Bp2BlockRecord? get block => _block;
  bool get blockLoaded => _blockLoaded;
  bool get nameIsAuto => _nameIsAuto;
  String? get nameError => _nameError;
  String get name => _block?.name ?? '';
  Bp2DateRange? get range => _block?.range;
  int get totalWeeks => _block?.range.weeks ?? defaultWeeks;

  // ── Catalogue / grouping ──────────────────────────────────────────────────

  Bp2CatalogueSnapshot? _snapshot;
  String? _activeBlockPointer;
  List<Bp2Exercise> _catalogue = const [];
  Map<String, Bp2Exercise> _byId = const {};
  Bp2Grouping _grouping = Bp2Grouping.empty;
  bool _catalogueLoaded = false;
  Bp2SyncStatus _syncStatus = Bp2SyncStatus.idle;

  Bp2Grouping get grouping => _grouping;
  List<Bp2Exercise> get catalogue => _catalogue;
  bool get catalogueLoaded => _catalogueLoaded;
  Bp2SyncStatus get syncStatus => _syncStatus;
  String? get athleteLabel => _snapshot?.athleteLabel;
  Bp2Exercise? exerciseById(String id) => _byId[id];

  /// Canonical active-block id: the pointer supplied by `UserContext`, else
  /// the cached `isActive` flag.
  String? get activeBlockId {
    final p = _activeBlockPointer;
    if (p != null && p.isNotEmpty) return p;
    for (final b in _snapshot?.blocks ?? const <Bp2BlockSummary>[]) {
      if (b.isActive) return b.id;
    }
    return null;
  }

  bool get isEditingActiveBlock =>
      _block != null && (_block!.isActive || _block!.id == activeBlockId);

  // ── Drafts ────────────────────────────────────────────────────────────────

  final Map<String, Bp2ExerciseDraft> _drafts = {};
  final Map<String, Map<String, dynamic>> _defaults = {};
  String? _expandedId;
  bool _saving = false;
  Timer? _draftTimer;

  String? get expandedExerciseId => _expandedId;
  bool get saving => _saving;
  Bp2ExerciseDraft draftFor(String exerciseId) =>
      _drafts[exerciseId] ?? Bp2ExerciseDraft.empty;

  // ── Binding ───────────────────────────────────────────────────────────────

  /// Binds the controller to [uid] (the SELECTED athlete). Any previous
  /// athlete's state is cleared synchronously before the new athlete hydrates.
  Future<void> bind({
    required String uid,
    String? blockId,
    String? activeBlockId,
  }) async {
    if (_uid == uid && _requestedBlockId == blockId) {
      setActiveBlockPointer(activeBlockId);
      return;
    }
    _flushDraftNow();
    final gen = ++_gen;
    _uid = uid;
    _requestedBlockId = blockId;
    _activeBlockPointer = activeBlockId;
    _resetState();
    notifyListeners();

    await _hydrate(gen, uid, blockId);
  }

  void _resetState() {
    _block = null;
    _persistedName = '';
    _persistedRange = null;
    _nameIsAuto = true;
    _blockTouched = false;
    _nameError = null;
    _blockLoaded = false;
    _snapshot = null;
    _catalogue = const [];
    _byId = const {};
    _grouping = Bp2Grouping.empty;
    _catalogueLoaded = false;
    _syncStatus = Bp2SyncStatus.idle;
    _drafts.clear();
    _defaults.clear();
    _expandedId = null;
    _saving = false;
    _draftTimer?.cancel();
    _draftTimer = null;
  }

  Future<void> _hydrate(int gen, String uid, String? blockId) async {
    // 1. Cached catalogue first — usable immediately.
    try {
      final cached = await sync.readCached(uid);
      if (!_live(gen)) return;
      if (cached != null) _applySnapshot(cached);
    } catch (e) {
      debugPrint('[BP2] cached snapshot read failed: $e');
    }

    // 2. The block (existing: cached copy; new: pending draft or fresh id).
    await _loadBlock(gen, uid, blockId);
    if (!_live(gen)) return;

    // 3. One-shot freshness check (non-blocking for the UI).
    await _refresh(gen, uid, force: false);
    if (!_live(gen)) return;

    // 4. Existing block: single document read so exerciseSettings are current.
    if (blockId != null) {
      try {
        final fresh = await sync.refreshBlock(uid, blockId);
        if (!_live(gen)) return;
        if (fresh != null) _mergeRemoteBlock(fresh);
      } catch (e) {
        debugPrint('[BP2] block refresh failed: $e');
      }
    }
  }

  Future<void> _loadBlock(int gen, String uid, String? blockId) async {
    Bp2BlockRecord? record;
    Bp2LocalDraft? draft;
    try {
      if (blockId != null) {
        record = await sync.readCachedBlock(uid, blockId);
        draft = await sync.readDraft(uid, blockId);
      } else {
        final pending = await sync.readPendingDraftId(uid);
        if (pending != null) draft = await sync.readDraft(uid, pending);
      }
    } catch (e) {
      debugPrint('[BP2] draft/block cache read failed: $e');
    }
    if (!_live(gen)) return;

    if (record == null) {
      final id = blockId ?? draft?.blockId ?? repo.newBlockId(uid);
      final range = Bp2DateUtils.defaultRange(_now(), weeks: defaultWeeks);
      record = Bp2BlockRecord(
        id: id,
        name: '',
        range: range,
        isActive: false,
        exerciseSettings: const {},
        existsRemotely: false,
      );
    }
    _block = record;
    _persistedName = record.existsRemotely ? record.name : '';
    _persistedRange = record.existsRemotely ? record.range : null;
    _nameIsAuto = !record.existsRemotely;

    if (draft != null && draft.blockId == record.id) {
      _block = record.copyWith(name: draft.name, range: draft.range);
      _nameIsAuto = draft.nameIsAuto;
      _blockTouched = draft.blockTouched;
      _drafts
        ..clear()
        ..addAll(draft.exerciseDrafts);
    }
    if (_nameIsAuto) _regenerateName();
    _blockLoaded = true;
    notifyListeners();
  }

  void _applySnapshot(Bp2CatalogueSnapshot snap) {
    _snapshot = snap;
    _catalogue = Bp2ExerciseClassifier.mergeCatalogue(
        shared: snap.shared, custom: snap.custom);
    _byId = {for (final e in _catalogue) e.id: e};
    _catalogueLoaded = true;
    _regroup();
    if (_nameIsAuto) _regenerateName(notify: false);
    notifyListeners();
  }

  void _regroup() {
    final active = activeBlockId;
    final others = <String>{
      for (final b in _snapshot?.blocks ?? const <Bp2BlockSummary>[])
        if (b.id != active) b.id,
    };
    _grouping = Bp2ExerciseClassifier.classify(
      catalogue: _catalogue,
      templates: _snapshot?.templates ?? const [],
      activeBlockId: active,
      otherBlockIds: others,
    );
  }

  Future<void> _refresh(int gen, String uid, {required bool force}) async {
    _syncStatus = Bp2SyncStatus.syncing;
    notifyListeners();
    try {
      final result = await sync.refresh(uid, force: force);
      if (!_live(gen)) return;
      if (result.refetched.isNotEmpty || _snapshot == null) {
        _applySnapshot(result.snapshot);
      }
      _syncStatus = Bp2SyncStatus.idle;
    } catch (e) {
      if (!_live(gen)) return;
      _syncStatus = Bp2SyncStatus(
        Bp2SyncState.error,
        _snapshot == null
            ? 'Could not load exercises. Check your connection.'
            : 'Showing saved data — could not check for updates.',
      );
    }
    notifyListeners();
  }

  Future<void> retrySync() async {
    final uid = _uid;
    if (uid == null) return;
    await _refresh(_gen, uid, force: false);
  }

  /// Replaces persisted (non-dirty) block state with a fresh server copy.
  /// Drafts are overlays and are never touched here.
  void _mergeRemoteBlock(Bp2BlockRecord fresh) {
    final cur = _block;
    if (cur == null || cur.id != fresh.id) return;
    final keepName = blockDirty ? cur.name : fresh.name;
    final keepRange = blockDirty ? cur.range : fresh.range;
    _block = fresh.copyWith(name: keepName, range: keepRange);
    _persistedName = fresh.name;
    _persistedRange = fresh.range;
    if (!blockDirty && _nameIsAuto) _nameIsAuto = false;
    notifyListeners();
  }

  /// `UserContext.activeBlockId` changed (hydration / activation elsewhere).
  void setActiveBlockPointer(String? id) {
    if (id == _activeBlockPointer) return;
    _activeBlockPointer = id;
    _regroup();
    notifyListeners();
  }

  // ── Block name / dates ────────────────────────────────────────────────────

  void _regenerateName({bool notify = true}) {
    final b = _block;
    if (b == null) return;
    final label = _snapshot?.athleteLabel ?? Bp2Repository.neutralAthleteLabel;
    _block = b.copyWith(name: Bp2DateUtils.autoBlockName(label, b.range));
    if (notify) notifyListeners();
  }

  void setName(String value) {
    final b = _block;
    if (b == null) return;
    if (value == b.name) return;
    _nameIsAuto = false;
    _blockTouched = true;
    _nameError = value.trim().isEmpty ? 'Block name cannot be empty.' : null;
    _block = b.copyWith(name: value);
    _scheduleDraftPersist();
    notifyListeners();
  }

  /// Snaps outward to Monday–Sunday and regenerates an auto name.
  void setRange(DateTime start, DateTime end) {
    final b = _block;
    if (b == null) return;
    final normalized = Bp2DateUtils.normalizeRange(start, end);
    if (normalized == b.range) return;
    _block = b.copyWith(range: normalized);
    _blockTouched = true;
    if (_nameIsAuto) _regenerateName(notify: false);
    _scheduleDraftPersist();
    notifyListeners();
  }

  // ── Exercise drafts ───────────────────────────────────────────────────────

  void toggleExpanded(String exerciseId) {
    _expandedId = _expandedId == exerciseId ? null : exerciseId;
    notifyListeners();
  }

  void edit(String exerciseId, String field, String? value) {
    final cur = draftFor(exerciseId);
    if (cur.has(field) && cur[field] == value) return;
    _drafts[exerciseId] = cur.withEdit(field, value);
    _scheduleDraftPersist();
    notifyListeners();
  }

  Map<String, dynamic> defaultsFor(String exerciseId) =>
      _defaults.putIfAbsent(exerciseId, () {
        final ex = _byId[exerciseId];
        if (ex == null || ex.unresolvedReference) return const {};
        return BlockExerciseDefaultsRepository.defaultSettingsPayload(
          name: ex.name,
          category: ex.category,
          bodyPart: ex.bodyPart,
        );
      });

  Map<String, dynamic> baseFor(String exerciseId) =>
      Bp2SettingsResolver.canonicalBase(
        _block?.exerciseSettings[exerciseId],
        defaultsFor(exerciseId),
      );

  Bp2ResolvedSettings resolvedFor(String exerciseId) =>
      Bp2SettingsResolver.resolve(
        exerciseId: exerciseId,
        base: baseFor(exerciseId),
        draft: draftFor(exerciseId),
        totalBlockWeeks: totalWeeks,
      );

  bool isExerciseDirty(String exerciseId) => !Bp2SettingsResolver.buildPatch(
        base: baseFor(exerciseId),
        draft: draftFor(exerciseId),
        totalBlockWeeks: totalWeeks,
      ).isEmpty;

  Set<String> get dirtyExerciseIds => {
        for (final id in _drafts.keys)
          if (isExerciseDirty(id)) id
      };

  bool get blockDirty {
    final b = _block;
    if (b == null) return false;
    if (!b.existsRemotely) return _blockTouched;
    return b.name != _persistedName || b.range != _persistedRange;
  }

  bool get isDirty => blockDirty || dirtyExerciseIds.isNotEmpty;

  // ── Durable local draft ───────────────────────────────────────────────────

  void _scheduleDraftPersist() {
    _draftTimer?.cancel();
    _draftTimer = Timer(draftDebounce, _flushDraftNow);
  }

  void _flushDraftNow() {
    _draftTimer?.cancel();
    _draftTimer = null;
    final uid = _uid;
    final b = _block;
    if (uid == null || b == null) return;
    final draft = Bp2LocalDraft(
      blockId: b.id,
      name: b.name,
      nameIsAuto: _nameIsAuto,
      range: b.range,
      exerciseDrafts: Map.of(_drafts),
      blockTouched: _blockTouched,
    );
    unawaited(() async {
      try {
        await sync.writeDraft(uid, draft);
        if (!b.existsRemotely) await sync.writePendingDraftId(uid, b.id);
      } catch (e) {
        debugPrint('[BP2] draft persist failed: $e');
      }
    }());
  }

  // ── Save ──────────────────────────────────────────────────────────────────

  Bp2SaveOutcome? _validate() {
    final b = _block;
    if (b == null) return Bp2SaveOutcome.failed('Block not loaded yet.');
    if (b.name.trim().isEmpty) {
      _nameError = 'Block name cannot be empty.';
      notifyListeners();
      return Bp2SaveOutcome.invalid(
          _nameError!, const Bp2FieldFocus(field: 'name'));
    }
    for (final entry in _drafts.entries) {
      final errors = Bp2SettingsResolver.validate(entry.value);
      if (errors.isNotEmpty) {
        final name = _byId[entry.key]?.name ?? entry.key;
        return Bp2SaveOutcome.invalid(
          '$name: ${errors.first.message}',
          Bp2FieldFocus(exerciseId: entry.key, field: errors.first.field),
        );
      }
    }
    return null;
  }

  Future<T> _withTimeout<T>(Future<T> f) => f.timeout(writeTimeout);

  static bool _isOfflineError(Object e) {
    if (e is TimeoutException) return true;
    final s = e.toString().toLowerCase();
    return s.contains('unavailable') || s.contains('offline');
  }

  /// Validates and persists everything dirty. [fromExit] only changes how the
  /// UI reacts (no activation offer); persistence is identical.
  Future<Bp2SaveOutcome> save({bool fromExit = false}) async {
    if (_saving) return Bp2SaveOutcome.busy;
    final uid = _uid;
    final gen = _gen;
    var b = _block;
    if (uid == null || b == null)
      return Bp2SaveOutcome.failed('Block not loaded yet.');

    final invalid = _validate();
    if (invalid != null) return invalid;

    final dirtyIds = dirtyExerciseIds;
    final needsBlockWrite =
        blockDirty || (!b.existsRemotely && dirtyIds.isNotEmpty);
    if (!needsBlockWrite && dirtyIds.isEmpty) return Bp2SaveOutcome.nothing;

    _saving = true;
    _draftTimer?.cancel();
    notifyListeners();

    var offline = false;
    try {
      final name = b.name.trim();
      final range = b.range;

      if (needsBlockWrite) {
        final create = !b.existsRemotely;
        final weeksChanged = create ||
            _persistedRange?.weeks != range.weeks ||
            _persistedRange?.start != range.start;
        try {
          await _withTimeout(repo.upsertBlock(
            uid: uid,
            blockId: b.id,
            name: name,
            range: range,
            create: create,
          ));
        } catch (e) {
          if (!_isOfflineError(e)) rethrow;
          offline = true; // durable in Firestore's offline queue
        }
        if (weeksChanged) {
          unawaited(
              repo.ensureWeekScaffold(uid: uid, blockId: b.id, range: range));
        }
        b = b.copyWith(name: name, range: range, existsRemotely: true);
        _persistedName = name;
        _persistedRange = range;
        _blockTouched = false;
      }

      final settings =
          Map<String, Map<String, dynamic>>.from(b.exerciseSettings);
      for (final id in dirtyIds) {
        final patch = Bp2SettingsResolver.buildPatch(
          base: baseFor(id),
          draft: draftFor(id),
          totalBlockWeeks: range.weeks,
        );
        if (patch.isEmpty) continue;
        Map<String, dynamic> merged;
        try {
          merged = await _withTimeout(repo.saveExerciseSettings(
            uid: uid,
            blockId: b.id,
            exerciseId: id,
            patch: patch,
            defaultsPayload: defaultsFor(id),
          ));
        } catch (e) {
          if (!_isOfflineError(e)) rethrow;
          offline = true;
          merged = await repo.queueExerciseSettingsOffline(
            uid: uid,
            blockId: b.id,
            exerciseId: id,
            lastKnown: settings[id],
            patch: patch,
            defaultsPayload: defaultsFor(id),
          );
        }
        settings[id] = merged;
        _drafts.remove(id); // only the successfully persisted exercise
      }
      b = b.copyWith(exerciseSettings: settings);
      if (!_live(gen)) return Bp2SaveOutcome.ok(offline: offline);
      _block = b;

      await _afterPersist(uid, b);
      return Bp2SaveOutcome.ok(offline: offline);
    } catch (e) {
      debugPrint('[BP2] save failed: $e');
      return Bp2SaveOutcome.failed(
          'Could not save — check your connection and try again.');
    } finally {
      if (_live(gen)) {
        _saving = false;
        notifyListeners();
      }
    }
  }

  Future<void> _afterPersist(String uid, Bp2BlockRecord b) async {
    try {
      await sync.writeBlock(uid, b);
      final snap = _snapshot;
      final summary = Bp2BlockSummary(
        id: b.id,
        name: b.name,
        startDate: b.range.start,
        endDate: b.range.end,
        isActive: b.isActive,
      );
      final blocks = [...?snap?.blocks]..removeWhere((x) => x.id == b.id);
      blocks.add(summary);
      await sync.writeBlockSummaries(uid, blocks);
      if (snap != null) {
        _snapshot = snap.copyWith(blocks: blocks);
        _regroup();
      }
      if (isDirty) {
        _flushDraftNow();
      } else {
        await sync.clearDraft(uid, b.id);
        await sync.clearPendingDraftId(uid);
      }
    } catch (e) {
      debugPrint('[BP2] cache update after save failed: $e');
    }
  }

  // ── Activation ────────────────────────────────────────────────────────────

  Future<Bp2ActivationOutcome> activate() async {
    final uid = _uid;
    final gen = _gen;
    final b = _block;
    if (uid == null || b == null || !b.existsRemotely) {
      return const Bp2ActivationOutcome(false, 'Save the block first.');
    }
    try {
      final result = await repo.activateBlock(uid: uid, blockId: b.id);
      if (!_live(gen)) return const Bp2ActivationOutcome(true);
      _block = b.copyWith(isActive: true);
      _activeBlockPointer = result.activeBlockId;
      final snap = _snapshot;
      if (snap != null) {
        final blocks = snap.blocks
            .map((x) => Bp2BlockSummary(
                  id: x.id,
                  name: x.name,
                  startDate: x.startDate,
                  endDate: x.endDate,
                  isActive: x.id == b.id,
                ))
            .toList();
        _snapshot = snap.copyWith(blocks: blocks);
        unawaited(sync.writeBlockSummaries(uid, blocks));
      }
      unawaited(sync.writeBlock(uid, _block!));
      _regroup();
      notifyListeners();
      return const Bp2ActivationOutcome(true);
    } catch (e) {
      debugPrint('[BP2] activation failed: $e');
      return const Bp2ActivationOutcome(
          false, 'Block saved, but it could not be activated.');
    }
  }

  // ── Custom exercise added via the canonical flow ──────────────────────────

  Future<void> onCustomExerciseAdded(CatalogExercise e) async {
    final uid = _uid;
    final gen = _gen;
    if (uid == null) return;
    try {
      final custom = await sync.addCustomExerciseToCache(uid, e);
      if (!_live(gen)) return;
      final snap = _snapshot ??
          const Bp2CatalogueSnapshot(
              shared: [],
              custom: [],
              templates: [],
              blocks: [],
              athleteLabel: null);
      _applySnapshot(snap.copyWith(custom: custom));
    } catch (err) {
      debugPrint('[BP2] could not add custom exercise to cache: $err');
    }
  }

  @override
  void dispose() {
    _flushDraftNow();
    _disposed = true;
    _draftTimer?.cancel();
    super.dispose();
  }
}
