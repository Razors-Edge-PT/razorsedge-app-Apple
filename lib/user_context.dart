// user_context.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
// ⬇️ Bring in your existing classes (names taken from your snippets)
import 'block_repository.dart';   // BlockRepository().fetchActiveBlockId(...)
import 'warmup_service.dart';                  // WarmupService.instance.warmWES(...)

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

  // Fetch from server quietly; if different, update+persist+notify; also kick warmup
  Future<void> _refreshFromServerInBackground(String uid) async {
    // ⚠️ MUST NOT throw; never block UI
    try {
      final repo = BlockRepository();
      final id = await repo.fetchActiveBlockId(uid);
      if (id == null || id.isEmpty) return;

      // Load meta (dates)
      final fs = FirebaseFirestore.instance;
      final doc = await fs
          .collection('planned_blocks')
          .doc(uid)
          .collection('blocks')
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

  /// Public bootstrap that pages/app root can call.
  /// - Hydrates from prefs immediately (if available) so pages can read.
  /// - Starts a background server refresh + warmup (non-blocking).
  Future<void> bootstrapBlockMeta({required String uid}) async {
    // 1) Instant prefs hydrate (publish if found)
    await _hydrateFromPrefs(uid);

    // 2) Fire background refresh (does persistence + warmup on success)
    //    DO NOT await – we never block app open.
    // ignore: unawaited_futures
    _refreshFromServerInBackground(uid);

    // 3) If we already have a cached id, nudge warmup immediately (best-effort)
    if (_activeBlockId != null && _activeBlockId!.isNotEmpty) {
      // ignore: unawaited_futures
      WarmupService.instance.warmWES(
        uid,
        activeBlockId: _activeBlockId,
        selectedDate: DateTime.now(),
      );
    }
  }

  /// Coach switches athlete – publish UID immediately, then do the same bootstrap
  void switchAthlete(String newUid) {
    actingAsUid = newUid;
    notifyListeners(); // let UI update the selected athlete immediately

    // Kick a lightweight bootstrap for the new athlete (non-blocking for UI)
    // 1) Prefs hydrate (fast) → publishes cached block info if any
    // 2) Background refresh + warmup (best-effort)
    // ignore: unawaited_futures
    (() async {
      await _hydrateFromPrefs(newUid);
      // Fire warmup with whatever we have right now (best-effort)
      if (_activeBlockId != null && _activeBlockId!.isNotEmpty) {
        WarmupService.instance.warmWES(
          newUid,
          activeBlockId: _activeBlockId,
          selectedDate: DateTime.now(),
        );
      }
      // And get authoritative values in the background
      await _refreshFromServerInBackground(newUid);
    })();
  }
}
