// user_context.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// ⬇️ Bring in your existing classes (names taken from your snippets)
import 'block_repository.dart';   // BlockRepository().fetchActiveBlockId(...)
import 'warmup_service.dart';                  // WarmupService.instance.warmWES(...)
import 'app_check_ready.dart';
import 'startup_trace.dart';

class UserContext extends ChangeNotifier {
  // Identity & roles
  final String actorUid;   // the authenticated user
  final bool isCoach;
  String actingAsUid;      // athlete in-focus (actorUid if not coaching)

  UserContext({
    required this.actorUid,
    required this.isCoach,
  }) : actingAsUid = actorUid;

  bool get isActingAsSelf => actingAsUid == actorUid;

  bool get isSuperAdmin => [
    'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard
  ].contains(actorUid);

  // ✅ Admin override (kept from your version)
  bool get isAdmin => [
    'yoVAqScwLMQLAgNHh8v9IK49fBw2', // Richard
    'wuiMe7phxYQh0MM39bfnhgv20yS2', // Campbell
    'SMTEVGPH1MXgOgbcBbJFU1HjU8G3', // Adam W
    'ejBDKEZPFfQz2Sdzd7BZlNydxZ33', // Adam@razorsedgept  ← comma was missing (string concat bug)
    'L7YjSMnm7tXD3BwyskmmrgVhKsS2', // Ruby cakes
    'ykx0RvDMc5OIuZ2R4kqWMhGbrGV2', // Google Play reviewer
    // 'Rp6gFj16KMgsmOtC9tZGlUDCNRr1', // Courtney
  ].contains(actorUid);

  String get currentUid => actingAsUid;

  // -------- Avatar single source of truth (unchanged) --------
  String? _networkPhotoUrl; // e.g., users/{uid}.photoURL from Firestore
  String? _localPhotoPath;  // on-device cached file path

  String? get networkPhotoUrl => _networkPhotoUrl;
  String? get localPhotoPath => _localPhotoPath;

  ImageProvider? get avatarImageProvider {
    if (_localPhotoPath != null) {
      final f = File(_localPhotoPath!);
      if (f.existsSync()) return FileImage(f);
    }
    if (_networkPhotoUrl != null && _networkPhotoUrl!.isNotEmpty) {
      return NetworkImage(_networkPhotoUrl!);
    }
    return null;
  }

  void setLocalPhotoPath(String? path) {
    _localPhotoPath = path;
    notifyListeners();
  }

  void setNetworkPhotoUrl(String? url) {
    _networkPhotoUrl = url;
    notifyListeners();
  }

  void clearAvatar() {
    _localPhotoPath = null;
    _networkPhotoUrl = null;
    notifyListeners();
  }
  // -----------------------------------------------------------

  // Provider helpers
  static UserContext of(BuildContext context, {bool listen = true}) {
    return listen ? context.watch<UserContext>() : context.read<UserContext>();
  }
  static UserContext? maybeOf(BuildContext context, {bool listen = true}) {
    return listen ? context.watch<UserContext?>() : context.read<UserContext?>();
  }

  // ─────────────────────────────────────────────────────────────
  // GLOBAL BLOCK META → known to all pages
  // ─────────────────────────────────────────────────────────────

  String? _activeBlockId;
  DateTime? _blockStartDate;
  DateTime? _blockEndDate;

  // Optional freshness/debug
  DateTime? _blockMetaLastRefreshedAt; // when server confirmed
  String _blockMetaSource = 'unknown'; // 'prefs' | 'server' | 'unknown'

  String?  get activeBlockId              => _activeBlockId;
  DateTime? get blockStartDate            => _blockStartDate;
  DateTime? get blockEndDate              => _blockEndDate;
  DateTime? get blockMetaLastRefreshedAt  => _blockMetaLastRefreshedAt;
  String    get blockMetaSource           => _blockMetaSource;

  // Stable prefs keys per athlete
  String _kId(String uid)  => 'block.$uid.activeId';
  String _kS(String uid)   => 'block.$uid.start';
  String _kE(String uid)   => 'block.$uid.end';

  // Set all three atomically and notify once
  void _setBlockMetaAtomic({
    required String activeBlockId,
    required DateTime? startDate,
    required DateTime? endDate,
    required String source, // 'prefs' | 'server'
  }) {
    _activeBlockId = activeBlockId;
    _blockStartDate = startDate;
    _blockEndDate = endDate;
    _blockMetaSource = source;
    _blockMetaLastRefreshedAt = DateTime.now();
    notifyListeners();
  }

  // Persist all three fields for this athlete uid
  Future<void> _persistBlockMeta({
    required String uid,
    required String activeBlockId,
    required DateTime? startDate,
    required DateTime? endDate,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kId(uid), activeBlockId);
    await p.setString(_kS(uid), startDate?.toIso8601String() ?? '');
    await p.setString(_kE(uid), endDate?.toIso8601String() ?? '');
  }

  // Read last-known block meta for this athlete uid (fast)
  Future<bool> _hydrateFromPrefs(String uid) async {
    try {
      final p = await SharedPreferences.getInstance();
      final id  = p.getString(_kId(uid));
      final sd  = p.getString(_kS(uid));
      final ed  = p.getString(_kE(uid));
      final start = (sd != null && sd.isNotEmpty) ? DateTime.tryParse(sd) : null;
      final end   = (ed != null && ed.isNotEmpty) ? DateTime.tryParse(ed) : null;

      if (id != null && id.isNotEmpty) {
        _setBlockMetaAtomic(
          activeBlockId: id,
          startDate: start,
          endDate: end,
          source: 'prefs',
        );
        return true;
      }
    } catch (_) {/* ignore */}
    return false;
  }

  // Fetch from server quietly; if different, update+persist+notify; also kick warmup.
  // [_attempt] is internal — callers always use the default.
  Future<void> _refreshFromServerInBackground(String uid, {int attempt = 1}) async {
    // ⚠️ MUST NOT throw; never block UI
    try {
      // Sequence Firestore behind App Check (settles even on failure/timeout).
      await appCheckReady;
      final repo = BlockRepository();
      final id = await repo.fetchActiveBlockId(uid);
      if (id == null || id.isEmpty) {
        if (attempt < 3) {
          debugPrint('⚠️ [UC] no active block for $uid (attempt $attempt/2) — retry in 4s');
          await Future.delayed(const Duration(seconds: 4));
          return _refreshFromServerInBackground(uid, attempt: attempt + 1);
        }
        debugPrint('⚠️ [UC] no active block for $uid after $attempt attempts — stopping');
        return;
      }

      // Load meta (dates)
      final fs = FirebaseFirestore.instance;
      final doc = await fs
          .collection('users')
          .doc(uid)
          .collection('planned_blocks')
          .doc(id)
          .get(const GetOptions(source: Source.server));
      final data = doc.data() ?? const {};
      final tsStart = data['startDate'] as Timestamp?;
      final tsEnd   = data['endDate']   as Timestamp?;
      final start   = tsStart?.toDate();
      final end     = tsEnd?.toDate();

      final changed =
          _activeBlockId != id ||
              _blockStartDate?.toIso8601String() != start?.toIso8601String() ||
              _blockEndDate?.toIso8601String()   != end?.toIso8601String();

      if (changed) {
        _setBlockMetaAtomic(
          activeBlockId: id,
          startDate: start,
          endDate: end,
          source: 'server',
        );
        await _persistBlockMeta(uid: uid, activeBlockId: id, startDate: start, endDate: end);
      }

      // Kick warmup best-effort now that we know a definitive block id.
      // Do not await; WarmupService has its own cooldowns.
      WarmupService.instance.warmWES(
        uid,
        activeBlockId: id,
        selectedDate: DateTime.now(),
      );
    } catch (_) {/* ignore */}
  }

  // The UID whose local (SharedPreferences) block-meta hydration has completed
  // for this UserContext instance, or null if none yet. UID-aware because a
  // coach can change the acting UID at runtime — a bool would let the previous
  // athlete's hydration satisfy the new athlete and expose the wrong block.
  // "Hydrated" means: we finished reading whatever cached block meta exists for
  // THAT uid (or confirmed there is none). Home must not decide new-user vs
  // existing-user for an acting UID until that UID is hydrated, otherwise a
  // pending prefs read makes activeBlockId transiently null and an existing
  // user is wrongly pushed into first-time setup.
  String? _blockMetaHydratedForUid;

  /// True only when local block-meta hydration has completed for [uid] exactly.
  bool isBlockMetaHydratedFor(String uid) => _blockMetaHydratedForUid == uid;

  /// Clears in-memory block meta (no notify — callers control notification).
  /// Used when the acting UID changes so the previous athlete's block is never
  /// exposed as the new athlete's while the new prefs hydrate.
  void _clearBlockMeta() {
    _activeBlockId = null;
    _blockStartDate = null;
    _blockEndDate = null;
    _blockMetaSource = 'unknown';
  }

  /// Awaits ONLY local SharedPreferences hydration of cached block meta for
  /// [uid]. Touches no Firestore and no App Check, so it is safe to await
  /// before rendering Home — the cost is a couple of cached prefs reads.
  ///
  /// UID-aware + idempotent: returns immediately only when [uid] is the exact
  /// UID already hydrated. When switching to a different UID it first drops the
  /// prior UID's meta so a not-found read can't expose it as [uid]'s block.
  ///
  /// Failure-safe: any local cache/SharedPreferences exception is caught, the
  /// attempt is still marked complete (defaulting to no cached metadata), and
  /// startup is allowed to continue — a diagnostics/cache error must never
  /// prevent authentication.
  Future<void> hydrateBlockMetaFromPrefs(String uid) async {
    if (_blockMetaHydratedForUid == uid) return;
    StartupTrace.blockMetaHydrateStart();
    try {
      // Switching UID: drop the prior UID's meta first so a not-found prefs
      // read leaves "no cached block" rather than the previous athlete's block.
      if (_blockMetaHydratedForUid != null &&
          _blockMetaHydratedForUid != uid) {
        _clearBlockMeta();
      }
      await _hydrateFromPrefs(uid); // publishes cached meta if found
    } catch (e) {
      debugPrint('[UC] hydrateBlockMetaFromPrefs($uid) failed: $e');
      // Default safely to no cached metadata; do not block startup.
    } finally {
      _blockMetaHydratedForUid = uid; // attempt complete for THIS uid
      StartupTrace.blockMetaHydrateDone(_activeBlockId);
      notifyListeners();
    }
  }

  /// Fire-and-forget server refresh + warmup. NEVER awaited on the render path.
  /// Safe to call right after [hydrateBlockMetaFromPrefs].
  void refreshBlockMetaInBackground(String uid) {
    // ignore: unawaited_futures
    _refreshFromServerInBackground(uid);
    if (_activeBlockId != null && _activeBlockId!.isNotEmpty) {
      // ignore: unawaited_futures
      WarmupService.instance.warmWES(
        uid,
        activeBlockId: _activeBlockId,
        selectedDate: DateTime.now(),
      );
    }
  }

  /// Public bootstrap that pages/app root can call.
  /// - Hydrates from prefs (awaited — local only) so pages can read.
  /// - Starts a background server refresh + warmup (non-blocking).
  Future<void> bootstrapBlockMeta({required String uid}) async {
    await hydrateBlockMetaFromPrefs(uid);
    refreshBlockMetaInBackground(uid);
  }

  /// Fetches active block id + dates from Firestore and updates UserContext.
  /// Called by HomeScreen after _ensureAtLeastOneBlockExists completes so
  /// WES2 always has up-to-date block context before the user navigates there.
  Future<void> refreshBlockMetaFromServer({required String uid}) async {
    try {
      await appCheckReady;
      final repo = BlockRepository();
      final id = await repo.fetchActiveBlockId(uid);
      if (id == null || id.isEmpty) return;
      final fs = FirebaseFirestore.instance;
      final doc = await fs
          .collection('users')
          .doc(uid)
          .collection('planned_blocks')
          .doc(id)
          .get(const GetOptions(source: Source.server));
      final data = doc.data() ?? const {};
      final tsStart = data['startDate'] as Timestamp?;
      final tsEnd   = data['endDate']   as Timestamp?;
      _setBlockMetaAtomic(
        activeBlockId: id,
        startDate: tsStart?.toDate(),
        endDate: tsEnd?.toDate(),
        source: 'server',
      );
      await _persistBlockMeta(
        uid: uid,
        activeBlockId: id,
        startDate: tsStart?.toDate(),
        endDate: tsEnd?.toDate(),
      );
    } catch (_) {}
  }

  /// Called by HomeScreen after auto-creating default blocks so WES2 has
  /// block context immediately without waiting for the next server refresh.
  void applyBlockMeta({
    required String uid,
    required String activeBlockId,
    required DateTime? startDate,
    required DateTime? endDate,
  }) {
    _setBlockMetaAtomic(
      activeBlockId: activeBlockId,
      startDate: startDate,
      endDate: endDate,
      source: 'server',
    );
    unawaited(_persistBlockMeta(
      uid: uid,
      activeBlockId: activeBlockId,
      startDate: startDate,
      endDate: endDate,
    ));
  }

  /// Coach switches athlete – publish UID immediately, then re-hydrate.
  void switchAthlete(String newUid) {
    if (newUid == actingAsUid) return;
    actingAsUid = newUid;

    // Synchronously drop the previous athlete's block meta + hydration marker
    // so no listener can read the old block as belonging to the new athlete in
    // the window before the new athlete's prefs hydrate.
    _clearBlockMeta();
    _blockMetaHydratedForUid = null;
    notifyListeners(); // UI updates selected athlete; block meta now cleared

    // Re-hydrate the new athlete's cached block meta (UID-aware), then start the
    // background server refresh + warmup. Non-blocking for the UI.
    // ignore: unawaited_futures
    (() async {
      await hydrateBlockMetaFromPrefs(newUid);
      refreshBlockMetaInBackground(newUid);
    })();
  }
}
