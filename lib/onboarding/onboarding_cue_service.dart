import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'onboarding_cue.dart';
import 'onboarding_cue_repository.dart';

/// Resolves the installed build number. Injectable so tests can simulate
/// build "40"/"41" without a platform channel.
typedef BuildNumberProvider = Future<String> Function();

Future<String> _defaultBuildProvider() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.buildNumber; // e.g. "40" — treated as an opaque string.
  } catch (_) {
    return '';
  }
}

/// Central, UID-based durable onboarding cue guard.
///
/// Responsibilities:
///  - own build-number loading (cached for the process lifetime; never blocks
///    app startup — resolved lazily inside [ensureLoaded] / [markCueComplete]);
///  - hold actor-scoped cue state seeded from the repository;
///  - answer eligibility ([shouldShowCue]) with fail-closed behaviour;
///  - record completion ([markCueComplete]) idempotently and durably.
///
/// All decisions key on the authenticated ACTOR UID. Callers must pass the
/// actor UID (FirebaseAuth.currentUser.uid / UserContext.actorUid), never the
/// impersonated athlete UID.
class OnboardingCueService {
  OnboardingCueService({
    OnboardingCueGateway? gateway,
    BuildNumberProvider? buildProvider,
  })  : _gateway = gateway ?? FirestoreOnboardingCueRepository(),
        _buildProvider = buildProvider ?? _defaultBuildProvider;

  /// App-wide singleton used by screens.
  static final OnboardingCueService instance = OnboardingCueService();

  /// The one test account that replays build-eligible cues. Kept here so no
  /// screen hard-codes it.
  static const String richardUid = 'yoVAqScwLMQLAgNHh8v9IK49fBw2';

  final OnboardingCueGateway _gateway;
  final BuildNumberProvider _buildProvider;

  String? _build; // cached for process lifetime
  Future<String>? _buildFuture;

  final Map<String, Map<String, CueRecord>> _state = {}; // actorUid → cues
  final Set<String> _established =
      {}; // actors with a usable (server or cache) result
  final Set<String> _serverLoaded =
      {}; // actors whose state came from the server
  final Map<String, Future<void>> _loading = {}; // coalesce concurrent loads
  final Map<String, Map<String, CueRecord>> _pendingWrites =
      {}; // light retry queue

  /// Installed build number, or '' if not yet resolved / unavailable.
  String get buildNumber => _build ?? '';

  /// True when a reliable eligibility result has been established for [actorUid]
  /// (server load succeeded, or a non-empty local cache is present, or a cue was
  /// just completed this session). Decisions fail closed until this is true.
  bool isLoaded(String actorUid) => _established.contains(actorUid);

  Future<String> _resolveBuild() {
    final cached = _build;
    if (cached != null) return Future.value(cached);
    return _buildFuture ??= _buildProvider().then((b) {
      _build = b;
      return b;
    });
  }

  /// Establishes durable state for [actorUid]. Idempotent; coalesces concurrent
  /// calls. Re-attempts the server while only a cache result exists, and flushes
  /// any queued completion writes. Never blocks on more than one in-flight load.
  Future<void> ensureLoaded(String actorUid) async {
    if (actorUid.isEmpty) return;
    await _resolveBuild();

    if (_serverLoaded.contains(actorUid)) {
      await _flushPending(actorUid);
      return;
    }
    final existing = _loading[actorUid];
    if (existing != null) return existing;

    final fut = _doLoad(actorUid);
    _loading[actorUid] = fut;
    try {
      await fut;
    } finally {
      _loading.remove(actorUid);
    }
  }

  Future<void> _doLoad(String actorUid) async {
    final result = await _gateway.load(actorUid);
    _state[actorUid] = Map<String, CueRecord>.of(result.cues);
    if (result.fromServer) {
      _serverLoaded.add(actorUid);
      _established.add(actorUid);
    } else if (result.cues.isNotEmpty) {
      // Offline but we have a cached result we can act on (anti-replay).
      _established.add(actorUid);
    }
    await _flushPending(actorUid);
  }

  /// Eligibility decision. Fail-closed: returns false until state is loaded.
  bool shouldShowCue(OnboardingCueId cue, String actorUid) {
    if (!_established.contains(actorUid)) {
      return false; // not loaded → don't show
    }
    final rec = _state[actorUid]?[cue.id];

    final isRichardReplay = actorUid == richardUid &&
        cue.policy == OnboardingCuePolicy.richardReplayable;
    if (isRichardReplay) {
      final b = buildNumber;
      if (b.isEmpty) return false; // unknown build → fail closed for replay
      return rec == null || rec.build != b;
    }

    // Normal users, and permanent cues for everyone (incl. Richard's video).
    return rec == null ? true : rec.done != true;
  }

  /// True when the cue is permanently complete, ignoring build/replay logic.
  /// Used for prerequisites (e.g. the WP video gate) and derived home glows.
  bool isPermanentlyComplete(OnboardingCueId cue, String actorUid) {
    return _state[actorUid]?[cue.id]?.done == true;
  }

  /// Records completion for [cue] under [actorUid]. Idempotent and merge-safe.
  /// Updates in-memory + local cache immediately so the cue does not re-show
  /// this session; persists to Firestore safely. A failed write is queued for a
  /// single light retry on the next [ensureLoaded] (no aggressive loop).
  Future<void> markCueComplete(OnboardingCueId cue, String actorUid) async {
    if (actorUid.isEmpty) return;
    final b = await _resolveBuild();
    final rec = CueRecord(done: true, build: b.isEmpty ? null : b);

    (_state[actorUid] ??= <String, CueRecord>{})[cue.id] = rec;
    _established.add(actorUid); // completing a cue establishes usable state

    try {
      await _gateway.writeCueComplete(
        actorUid: actorUid,
        cueId: cue.id,
        record: rec,
      );
    } catch (_) {
      (_pendingWrites[actorUid] ??= <String, CueRecord>{})[cue.id] = rec;
    }
  }

  Future<void> _flushPending(String actorUid) async {
    final pend = _pendingWrites[actorUid];
    if (pend == null || pend.isEmpty) return;
    final entries = Map<String, CueRecord>.of(pend);
    for (final e in entries.entries) {
      try {
        await _gateway.writeCueComplete(
          actorUid: actorUid,
          cueId: e.key,
          record: e.value,
        );
        pend.remove(e.key);
      } catch (_) {
        // Keep queued; retried on the next ensureLoaded.
      }
    }
    if (pend.isEmpty) _pendingWrites.remove(actorUid);
  }

  /// Clears in-process state (tests only).
  @visibleForTesting
  void debugReset() {
    _state.clear();
    _established.clear();
    _serverLoaded.clear();
    _loading.clear();
    _pendingWrites.clear();
    _build = null;
    _buildFuture = null;
  }
}
