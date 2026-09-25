/// State/controller for Block Planner 2 (Provider `ChangeNotifier`).
///
/// Owns: selected-athlete binding, the block draft (name/dates), per-exercise
/// raw drafts, dirty tracking, catalogue grouping, cache/freshness
/// orchestration, save/exit-save and activation. Presentation lives in
/// `bp2_screen.dart`; every pure transformation lives in the resolver /
/// classifier / date utils.
library;

import '../units/exercise_unit_registry.dart';
import '../units/weight_unit.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

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
    this.defaultWeeks = kBp2DefaultDraftWeeks,
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

  /// Name exactly as stored on the block (`''` when none).
  String _persistedName = '';
  Bp2DateRange? _persistedRange;

  /// Raw Block Name field text; authoritative only when [_nameEdited].
  String _nameText = '';
  bool _nameEdited = false;
  bool _rangeTouched = false;

  /// Any user interaction with a NEW (not yet persisted) block.
  bool _blockTouched = false;
  bool _blockLoaded = false;
  String? _blockLoadError;

  Bp2BlockRecord? get block => _block;
  bool get blockLoaded => _blockLoaded;
  String? get blockLoadError => _blockLoadError;
  Bp2DateRange? get range => _block?.range;
  int get totalWeeks => _block?.range.weeks ?? defaultWeeks;

  /// Generated fallback: `<athlete username> — <start> to <end>`.
  String get generatedName {
    final r = _block?.range;
    if (r == null) return '';
    final label = _snapshot?.athleteLabel ?? Bp2Repository.neutralAthleteLabel;
    return Bp2DateUtils.autoBlockName(label, r);
  }

  /// True when the stored name is a genuine custom name: non-blank and not a
  /// materialised generated fallback for the stored dates.
  bool get _persistedIsCustom {
    final n = _persistedName.trim();
    if (n.isEmpty) return false;
    final r = _persistedRange;
    return r == null || !Bp2DateUtils.isGeneratedName(n, r);
  }

  /// Text shown in the Block Name field:
  ///  1. what the user typed (unsaved),
  ///  2. a non-empty custom name saved on the block,
  ///  3. the generated athlete/date fallback.
  String get name {
    if (_nameEdited) return _nameText;
    if (_persistedIsCustom) return _persistedName;
    return generatedName;
  }

  /// The name Save persists: blank/whitespace means "no custom name", i.e.
  /// the generated fallback.
  String get effectiveName {
    final t = name.trim();
    return t.isEmpty ? generatedName : t;
  }

  /// True while the displayed name follows the generated fallback.
  bool get nameIsAuto =>
      _nameEdited ? _nameText.trim().isEmpty : !_persistedIsCustom;

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
    _nameText = '';
    _nameEdited = false;
    _rangeTouched = false;
    _blockTouched = false;
    _blockLoaded = false;
    _blockLoadError = null;
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

    // 2. The block: an existing block is the exact stored document (cached
    //    copy first, then ONE document read); a new block is the pending
    //    local draft or a freshly allocated id.
    if (blockId != null) {
      await _loadExistingBlock(gen, uid, blockId);
    } else {
      await _loadNewDraft(gen, uid);
    }
    if (!_live(gen)) return;

    // 3. One-shot catalogue freshness check (non-blocking for the UI).
    await _refresh(gen, uid, force: false);
  }

  Future<void> _loadExistingBlock(int gen, String uid, String blockId) async {
    Bp2BlockRecord? cached;
    Bp2LocalDraft? draft;
    try {
      cached = await sync.readCachedBlock(uid, blockId);
      draft = await sync.readDraft(uid, blockId);
    } catch (e) {
      debugPrint('[BP2] block cache read failed: $e');
    }
    if (!_live(gen)) return;
    if (cached != null) _adoptPersisted(cached, draft);

    try {
      final fresh = await sync.refreshBlock(uid, blockId);
      if (!_live(gen)) return;
      if (fresh != null) {
        if (_block == null) {
          _adoptPersisted(fresh, draft);
        } else {
          _mergeRemoteBlock(fresh);
        }
      } else if (_block == null) {
        _blockLoadError = 'This block no longer exists.';
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[BP2] block refresh failed: $e');
      if (!_live(gen)) return;
      if (_block == null) {
        // Never fabricate a draft for an existing id: saving it would
        // overwrite the real block's metadata.
        _blockLoadError = 'Could not load this block. Check your connection.';
        notifyListeners();
      }
    }
  }

  Future<void> _loadNewDraft(int gen, String uid) async {
    Bp2LocalDraft? draft;
    try {
      final pending = await sync.readPendingDraftId(uid);
      if (pending != null) draft = await sync.readDraft(uid, pending);
    } catch (e) {
      debugPrint('[BP2] draft cache read failed: $e');
    }
    if (!_live(gen)) return;
    _block = Bp2BlockRecord(
      id: draft?.blockId ?? repo.newBlockId(uid),
      name: '',
      range: draft?.range ??
          Bp2DateUtils.defaultRange(_now(), weeks: defaultWeeks),
      isActive: false,
      exerciseSettings: const {},
      existsRemotely: false,
    );
    _persistedName = '';
    _persistedRange = null;
    if (draft != null) {
      _nameEdited = draft.nameEdited;
      _nameText = draft.name;
      _rangeTouched = draft.rangeTouched;
      _blockTouched = draft.blockTouched;
      _drafts
        ..clear()
        ..addAll(draft.exerciseDrafts);
    }
    _blockLoaded = true;
    notifyListeners();
  }

  /// Installs a persisted block as the baseline, then overlays any durable
  /// local draft for it (unsaved typing survives an app kill).
  void _adoptPersisted(Bp2BlockRecord record, Bp2LocalDraft? draft) {
    _block = record;
    _persistedName = record.name;
    _persistedRange = record.range;
    _blockLoadError = null;
    if (draft != null && draft.blockId == record.id) {
      if (draft.nameEdited) {
        _nameEdited = true;
        _nameText = draft.name;
      }
      if (draft.rangeTouched) {
        _rangeTouched = true;
        _block = record.copyWith(range: draft.range);
      }
      _drafts
        ..clear()
        ..addAll(draft.exerciseDrafts);
    }
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

  /// Replaces the persisted baseline with a fresh server copy. Unsaved name,
  /// date and exercise edits are overlays and are never replaced.
  void _mergeRemoteBlock(Bp2BlockRecord fresh) {
    final cur = _block;
    if (cur == null || cur.id != fresh.id) return;
    _block = fresh.copyWith(range: _rangeTouched ? cur.range : fresh.range);
    _persistedName = fresh.name;
    _persistedRange = fresh.range;
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

  /// Raw Block Name edit. Blank/whitespace is allowed and means "use the
  /// generated fallback"; a non-blank value is a custom name that later date
  /// changes never overwrite.
  void setName(String value) {
    if (_block == null) return;
    if (value == name) return;
    _nameEdited = true;
    _nameText = value;
    if (!_block!.existsRemotely) _blockTouched = true;
    _scheduleDraftPersist();
    notifyListeners();
  }

  /// Snaps outward to Monday–Sunday. A generated name follows automatically.
  void setRange(DateTime start, DateTime end) {
    final b = _block;
    if (b == null) return;
    final normalized = Bp2DateUtils.normalizeRange(start, end);
    if (normalized == b.range) return;
    _block = b.copyWith(range: normalized);
    _rangeTouched = true;
    if (!b.existsRemotely) _blockTouched = true;
    _scheduleDraftPersist();
    notifyListeners();
  }

  // ── Exercise drafts ───────────────────────────────────────────────────────

  void toggleExpanded(String exerciseId) {
    _expandedId = _expandedId == exerciseId ? null : exerciseId;
    notifyListeners();
  }

  void edit(String exerciseId, String field, String? value) {
    var cur = draftFor(exerciseId);
    if (cur.has(field) && cur[field] == value) return;
    if (field == Bp2Field.weightUnit) {
      // Switching kg ⇄ lb re-expresses any increment being edited; the
      // canonical values underneath do not change.
      final from = resolvedFor(exerciseId).weightUnit;
      final to = ExerciseWeightUnit.parseOrNull(value) ?? from;
      for (final key in const [
        Bp2Field.incrementPrimary,
        Bp2Field.incrementSecondary
      ]) {
        if (!cur.has(key)) continue;
        final kg = parseDisplayToKg(cur[key] ?? '', from);
        if (kg != null) {
          cur = cur.withEdit(key, formatWeightNumber(to.fromKg(kg)));
        }
      }
    }
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

  /// The unit an exercise without an explicit block setting is shown in: the
  /// owner's own choice made here this session, else their published choice.
  ExerciseWeightUnit fallbackUnitFor(String exerciseId) {
    final uid = _uid;
    if (uid == null || uid.isEmpty) return ExerciseWeightUnit.kg;
    return ExerciseUnitRegistry.shared.unitsFor(uid).unitFor(exerciseId);
  }

  Bp2ResolvedSettings resolvedFor(String exerciseId) =>
      Bp2SettingsResolver.resolve(
        exerciseId: exerciseId,
        base: baseFor(exerciseId),
        draft: draftFor(exerciseId),
        totalBlockWeeks: totalWeeks,
        fallbackUnit: fallbackUnitFor(exerciseId),
      );

  bool isExerciseDirty(String exerciseId) => !Bp2SettingsResolver.buildPatch(
        base: baseFor(exerciseId),
        draft: draftFor(exerciseId),
        totalBlockWeeks: totalWeeks,
        fallbackUnit: fallbackUnitFor(exerciseId),
      ).isEmpty;

  Set<String> get dirtyExerciseIds => {
        for (final id in _drafts.keys)
          if (isExerciseDirty(id)) id
      };

  bool get _rangeDirty =>
      _rangeTouched && _block != null && _block!.range != _persistedRange;

  /// A name write is needed only after a user edit or a date change; the
  /// label/date-derived fallback appearing on open is never a change.
  bool get _nameDirty =>
      (_nameEdited || _rangeDirty) && effectiveName != _persistedName;

  bool get blockDirty {
    final b = _block;
    if (b == null) return false;
    if (!b.existsRemotely) return _blockTouched;
    return _nameDirty || _rangeDirty;
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
      name: _nameText,
      nameEdited: _nameEdited,
      rangeTouched: _rangeTouched,
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
    if (uid == null || b == null) {
      return Bp2SaveOutcome.failed('Block not loaded yet.');
    }

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
      final range = b.range;

      if (needsBlockWrite) {
        final create = !b.existsRemotely;
        final writeRange = create || _rangeDirty;
        final writeName = create || _nameDirty;
        final name = effectiveName;
        try {
          await _withTimeout(repo.upsertBlock(
            uid: uid,
            blockId: b.id,
            name: writeName ? name : null,
            range: writeRange ? range : null,
            create: create,
          ));
        } catch (e) {
          if (!_isOfflineError(e)) rethrow;
          offline = true; // durable in Firestore's offline queue
        }
        if (writeRange) {
          unawaited(
              repo.ensureWeekScaffold(uid: uid, blockId: b.id, range: range));
        }
        if (writeName) _persistedName = name;
        if (writeRange) _persistedRange = range;
        b = b.copyWith(name: _persistedName, existsRemotely: true);
        _nameEdited = false;
        _nameText = '';
        _rangeTouched = false;
        _blockTouched = false;
      }

      final settings =
          Map<String, Map<String, dynamic>>.from(b.exerciseSettings);
      for (final id in dirtyIds) {
        final patch = Bp2SettingsResolver.buildPatch(
          base: baseFor(id),
          draft: draftFor(id),
          totalBlockWeeks: range.weeks,
          fallbackUnit: fallbackUnitFor(id),
        );
        if (patch.isEmpty) continue;
        final unitChoice = ExerciseWeightUnit.parseOrNull(
            patch.scalarChanges[Bp2Field.weightUnit]);
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
        if (unitChoice != null) {
          // Every screen shows the new unit at once (and offline); the
          // server publishes it for friends in the background.
          ExerciseUnitRegistry.shared.noteLocalChoice(uid, id, unitChoice);
        }
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
        if (await sync.readPendingDraftId(uid) == b.id) {
          await sync.clearPendingDraftId(uid);
        }
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

  // ── Exercise added via the canonical flow ─────────────────────────────────

  /// Refreshes only the affected pool (custom or shared) in cache + memory so
  /// the new exercise appears immediately in its alphabetical position.
  Future<void> onExerciseAdded(CatalogExercise e) async {
    final uid = _uid;
    final gen = _gen;
    if (uid == null) return;
    try {
      final snap = _snapshot ??
          const Bp2CatalogueSnapshot(
              shared: [],
              custom: [],
              templates: [],
              blocks: [],
              athleteLabel: null);
      final updated = e.source == ExerciseSource.custom
          ? snap.copyWith(custom: await sync.addCustomExerciseToCache(uid, e))
          : snap.copyWith(shared: await sync.addSharedExerciseToCache(e));
      if (!_live(gen)) return;
      _defaults.remove(e.id);
      _applySnapshot(updated);
    } catch (err) {
      debugPrint('[BP2] could not add exercise to cache: $err');
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
