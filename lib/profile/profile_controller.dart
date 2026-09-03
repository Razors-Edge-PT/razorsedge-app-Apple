/// State for the profile page.
///
/// Holds every stream, every edit controller and the ownership decision, so the
/// screen itself is a thin composition of widgets and the rules live in one
/// testable place.
///
/// ── Ownership ───────────────────────────────────────────────────────────────
/// Owner-only controls appear when the AUTHENTICATED ACTOR is the profile
/// being viewed. A coach acting as an athlete is NOT the owner: they are
/// operating someone else's identity and must never get avatar, username, bio,
/// story or media controls. [isOwner] is derived from `actorUid`, never from
/// `actingAsUid`, which is what makes that guarantee structural rather than a
/// series of remembered checks at each call site.
///
/// ── Not overwriting the editor ──────────────────────────────────────────────
/// A background snapshot arriving mid-typing must not yank text out from under
/// the user. [_syncEditors] writes into a TextEditingController only when that
/// field is not being edited, so a remote change is adopted the moment the user
/// stops and never while they are typing.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../wes2_video/set_video_coordinator.dart';

import 'core/media_models.dart';
import 'core/showcase_models.dart';
import 'data/identity_repository.dart';
import 'data/media_repository.dart';
import 'data/media_staging.dart';
import 'data/media_uploader.dart';
import 'data/profile_repository.dart';
import 'data/showcase_repository.dart';
import 'data/story_repository.dart';

class ProfileController extends ChangeNotifier {
  ProfileController({
    required this.targetUid,
    required this.actorUid,
    required ProfileRepository profiles,
    required IdentityRepository identity,
    required ShowcaseRepository showcase,
    required MediaRepository media,
    required StoryRepository stories,
    required MediaStaging staging,
    required MediaUploader uploader,
    DateTime Function()? clock,
  })  : _now = clock ?? DateTime.now,
        _profiles = profiles,
        _identity = identity,
        _showcase = showcase,
        _media = media,
        _stories = stories,
        _staging = staging,
        _uploader = uploader;

  /// Whose profile is on screen.
  final String targetUid;

  /// The signed-in user. NOT the "acting as" athlete.
  final String actorUid;

  final ProfileRepository _profiles;
  final IdentityRepository _identity;
  final ShowcaseRepository _showcase;
  final MediaRepository _media;
  final StoryRepository _stories;
  final MediaStaging _staging;
  final MediaUploader _uploader;

  /// True only when the signed-in user owns this profile.
  bool get isOwner => actorUid == targetUid;

  // ── Editors ───────────────────────────────────────────────────────────────

  final TextEditingController bioController = TextEditingController();
  final FocusNode bioFocus = FocusNode();

  bool _bioDirty = false;
  bool get bioDirty => _bioDirty;

  int get bioRemaining => kBioMaxLength - bioController.text.characters.length;

  // ── Observable state ──────────────────────────────────────────────────────

  ProfileIdentity _identityState = ProfileIdentity.empty('');
  ProfileIdentity get profile => _identityState;

  ShowcaseView _showcaseView = ShowcaseView.empty;
  ShowcaseView get showcase => _showcaseView;

  List<ProfileMediaItem> _published = const <ProfileMediaItem>[];
  List<ProfileMediaItem> _pending = const <ProfileMediaItem>[];
  List<ProfileMediaItem> get grid =>
      MediaRepository.mergeGrid(_published, _pending);

  List<StoryItem> _liveStories = const <StoryItem>[];
  List<StoryItem> _pendingStories = const <StoryItem>[];

  /// Stories to show right now: published ones that are STILL live at this
  /// instant, plus the owner's own not-yet-published uploads.
  ///
  /// The liveness filter is applied here rather than only when the snapshot
  /// arrived, because a profile can sit open for hours — see
  /// [_scheduleStoryExpiry] for the timer that repaints at the exact moment
  /// the answer changes.
  List<StoryItem> get stories => <StoryItem>[
        ..._liveStories.where((StoryItem s) => s.isLiveAt(_now())),
        ..._pendingStories,
      ];

  bool get hasStoryRing => stories.isNotEmpty;

  /// Injectable clock, so expiry behaviour is testable without waiting.
  final DateTime Function() _now;

  Timer? _storyExpiryTimer;

  /// Repaints at the EXACT instant the next story expires.
  ///
  /// Nothing else would. The Firestore listener only fires when a document
  /// changes, and an expiring story does not change — it just gets older. The
  /// hourly server sweep does delete it eventually, but until then the ring
  /// and the viewer would keep offering a story that is already over, for up
  /// to an hour, and a rebuild triggered by something unrelated would make it
  /// vanish at an arbitrary moment instead.
  ///
  /// One timer, set to the earliest expiry among the live stories, is enough:
  /// when it fires it rebuilds and schedules the next one.
  void _scheduleStoryExpiry() {
    _storyExpiryTimer?.cancel();
    _storyExpiryTimer = null;

    final DateTime now = _now();
    DateTime? next;
    for (final StoryItem s in _liveStories) {
      final DateTime? expires = s.expiresAt;
      if (expires == null) continue;
      if (!expires.isAfter(now)) continue; // already gone
      if (next == null || expires.isBefore(next)) next = expires;
    }
    if (next == null) return;

    // A microsecond past the boundary, so the rebuild happens when the story
    // is expired rather than in the instant it is still live.
    final Duration delay =
        next.difference(now) + const Duration(microseconds: 1);
    _storyExpiryTimer = Timer(delay, () {
      // Drop what has expired so the list does not have to be re-filtered
      // forever, then repaint and arm the next boundary.
      _liveStories = _liveStories
          .where((StoryItem s) => s.isLiveAt(_now()))
          .toList(growable: false);
      notifyListeners();
      _scheduleStoryExpiry();
    });
  }

  String? _pendingAvatarPath;

  /// Local preview of an avatar the owner has chosen but that has not finished
  /// uploading. Shown only to the owner, and only until the upload commits.
  String? get pendingAvatarPath => _pendingAvatarPath;

  SaveState _bioSaveState = SaveState.idle;
  SaveState get bioSaveState => _bioSaveState;

  String? _lastError;
  String? get lastError => _lastError;

  bool _loaded = false;

  /// True once anything at all has been rendered — including from cache, which
  /// is what makes a warm reopen feel instant and work offline.
  bool get loaded => _loaded;

  /// True when what is on screen came from the local cache rather than the
  /// server.
  bool get isOffline => _identityState.isFromCache;

  /// Live subscriptions, by name, so a failed one can be REPLACED rather than
  /// added to. A retry that appended would leave the dead subscription in the
  /// list and, after a few retries, deliver every snapshot several times over.
  final Map<String, StreamSubscription<Object?>> _subs =
      <String, StreamSubscription<Object?>>{};

  /// How to (re-)establish each subscription, for [retryGrid] and [onResumed].
  final Map<String, StreamSubscription<Object?> Function()> _binders =
      <String, StreamSubscription<Object?> Function()>{};

  /// Names of subscriptions that ended in an error and have not been re-bound.
  final Set<String> _failed = <String>{};

  bool _sawServerSnapshot = false;

  static const String _kGrid = 'grid';
  static const String _kProfile = 'profile';
  static const String _kShowcase = 'showcase';
  static const String _kStories = 'stories';
  static const String _kPending = 'pending';
  static const String _kPendingStories = 'pendingStories';
  static const String _kPendingAvatar = 'pendingAvatar';

  String? _gridError;

  /// Set when the gallery listener FAILED - a rules change, a missing index, a
  /// dropped stream.
  ///
  /// Deliberately not the same thing as having no content: [grid] still holds
  /// whatever last arrived, so a refresh failure never blanks a gallery that is
  /// already on screen, and "could not refresh" stays distinguishable from
  /// "nothing shared yet".
  String? get gridError => _gridError;

  /// True when the gallery could not be refreshed.
  bool get gridFailed => _gridError != null;

  /// Re-establishes the gallery listener after a failure.
  ///
  /// User-triggered. There is no automatic retry timer on purpose: a listener
  /// that fails because of a rules change or a missing index fails again
  /// immediately, and a timer wrapped around that is a retry storm against
  /// production. Reconnect and resume go through [onResumed] instead, which
  /// are real signals rather than a guess.
  void retryGrid() => _rebind(_kGrid);

  /// Called when the app returns to the foreground, and when the server answers
  /// again after a period offline.
  ///
  /// Re-binds only what actually failed, so an ordinary resume does not churn
  /// healthy listeners.
  void onResumed() {
    if (_failed.isEmpty) return;
    for (final String name in _failed.toList()) {
      _rebind(name);
    }
  }

  /// Subscribes under [name], remembering how, and replacing any existing
  /// subscription of that name.
  void _bind(String name, StreamSubscription<Object?> Function() subscribe) {
    _binders[name] = subscribe;
    _rebind(name);
  }

  void _rebind(String name) {
    final StreamSubscription<Object?> Function()? make = _binders[name];
    if (make == null) return;
    final StreamSubscription<Object?>? existing = _subs.remove(name);
    if (existing != null) unawaited(existing.cancel());
    _failed.remove(name);
    if (name == _kGrid) _gridError = null;
    _subs[name] = make();
    notifyListeners();
  }

  /// The shared failure path for every listener.
  ///
  /// A Firestore stream that errors is finished - nothing more arrives on it -
  /// so the subscription is dropped and the name recorded as re-bindable. What
  /// is NOT done here matters as much: no cached list is cleared, no state is
  /// reset, and nothing rethrows. Losing a refresh must never lose the content
  /// the user is already looking at, and a gallery that cannot refresh must
  /// never take the profile page down with it.
  void _onStreamError(String name, Object error) {
    _failed.add(name);
    unawaited(_subs.remove(name)?.cancel());
    if (name == _kGrid) {
      _gridError = error.toString();
    } else {
      _lastError = error.toString();
    }
    notifyListeners();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Opens every listener the page needs.
  ///
  /// Every one of them registers an `onError`. Without one, a stream failure -
  /// a rules change, a missing composite index, a dropped connection - escapes
  /// to the zone as an unhandled error and the subscription simply stops: the
  /// page keeps rendering, the gallery stays exactly as it was, and nothing
  /// anywhere says it will never update again. A gallery in that state is
  /// indistinguishable from a profile that has no media.
  void start() {
    _identityState = ProfileIdentity.empty(targetUid);

    _bind(
      _kProfile,
      () => _profiles.watch(targetUid).listen(
            (ProfileIdentity next) {
              _identityState = next;
              _loaded = true;
              _syncEditors(next);
              _onSnapshotConnectivity(fromCache: next.isFromCache);
              notifyListeners();
            },
            onError: (Object e) => _onStreamError(_kProfile, e),
          ),
    );

    _bind(
      _kShowcase,
      () => _showcase.watchProofs(targetUid).listen(
            (Map<String, ProofRecord> proofs) {
              _showcaseView = ShowcaseView(
                showcase: _identityState.showcase,
                proofsByFingerprint: proofs,
              );
              notifyListeners();
            },
            onError: (Object e) => _onStreamError(_kShowcase, e),
          ),
    );

    _bind(
      _kGrid,
      () => _media.watchGrid(targetUid).listen(
            (List<ProfileMediaItem> items) {
              _published = items;
              _gridError = null;
              notifyListeners();
            },
            onError: (Object e) => _onStreamError(_kGrid, e),
          ),
    );

    _bind(
      _kStories,
      () => _stories.watchLive(targetUid, clock: _now).listen(
            (List<StoryItem> items) {
              _liveStories = items;
              _scheduleStoryExpiry();
              notifyListeners();
            },
            onError: (Object e) => _onStreamError(_kStories, e),
          ),
    );

    if (isOwner) {
      _bind(
        _kPending,
        () => _media.watchPending(targetUid).listen(
              (List<ProfileMediaItem> items) {
                _pending = items;
                notifyListeners();
              },
              onError: (Object e) => _onStreamError(_kPending, e),
            ),
      );
      _bind(
        _kPendingStories,
        () => _stories.watchPending(targetUid).listen(
              (List<StoryItem> items) {
                _pendingStories = items;
                notifyListeners();
              },
              onError: (Object e) => _onStreamError(_kPendingStories, e),
            ),
      );
      _bind(
        _kPendingAvatar,
        () => _media.watchPendingAvatarPath(targetUid).listen(
              (String? path) {
                _pendingAvatarPath = path;
                notifyListeners();
              },
              onError: (Object e) => _onStreamError(_kPendingAvatar, e),
            ),
      );
      // App start / page open is one of the four moments the outbox drains.
      unawaited(processOutbox());
    }
  }

  /// The showcase view has to be rebuilt whenever EITHER half changes.
  void _refreshShowcase() {
    _showcaseView = ShowcaseView(
      showcase: _identityState.showcase,
      proofsByFingerprint: _showcaseView.proofsByFingerprint,
    );
  }

  /// Firestore snapshot metadata is a reliable connectivity signal we already
  /// receive: a snapshot that is NOT from cache means the server answered. Used
  /// instead of adding a connectivity plugin for the same information.
  void _onSnapshotConnectivity({required bool fromCache}) {
    _refreshShowcase();
    if (fromCache) {
      _sawServerSnapshot = false;
      return;
    }
    if (!_sawServerSnapshot) {
      _sawServerSnapshot = true;
      // The server answering is the reconnect signal: anything that died while
      // the connection was down gets one attempt, now that there is something
      // to attempt against.
      onResumed();
      if (isOwner) unawaited(processOutbox());
    }
  }

  /// Called on app resume as well as on start and reconnection.
  Future<void> processOutbox() async {
    if (!isOwner) return;
    try {
      await _uploader.processAll();
    } catch (e) {
      _lastError = e.toString();
    }
  }

  /// Adopts remote values into the edit controllers, but never over an active
  /// edit.
  void _syncEditors(ProfileIdentity next) {
    final bool editing = bioFocus.hasFocus || _bioDirty;
    if (editing) return;
    final String remote = next.bio ?? '';
    if (bioController.text != remote) {
      bioController.text = remote;
    }
  }

  // ── Bio ───────────────────────────────────────────────────────────────────

  void onBioChanged(String _) {
    if (!_bioDirty) {
      _bioDirty = true;
    }
    notifyListeners();
  }

  /// Explicit save. Deliberately NOT called from dispose: a save started during
  /// teardown cannot report its result, cannot be retried, and races the
  /// controller's own disposal.
  Future<void> saveBio() async {
    if (!isOwner) return;
    final String value = ProfileRepository.clampBio(bioController.text);
    _bioSaveState = SaveState.syncing;
    notifyListeners();

    final SaveState result = await _profiles.saveBio(targetUid, value);
    _bioSaveState = result;
    _bioDirty = false;
    notifyListeners();
  }

  void discardBioEdit() {
    _bioDirty = false;
    bioController.text = _identityState.bio ?? '';
    _bioSaveState = SaveState.idle;
    notifyListeners();
  }

  // ── Username ──────────────────────────────────────────────────────────────

  /// Best display name available, falling back to the signed-in user's own
  /// name when the profile document has nothing yet.
  String get displayName {
    final String? name = _identityState.username;
    if (name != null && name.isNotEmpty) return name;
    if (isOwner) {
      final String? fallback = _identity.currentUserFallbackName;
      if (fallback != null && fallback.isNotEmpty) return fallback;
    }
    return 'GoodLift athlete';
  }

  Future<UsernameChangeResult> changeUsername(String raw) async {
    if (!isOwner) {
      return const UsernameChangeResult(
        UsernameChangeOutcome.failed,
        message: 'Only the account owner can change this username.',
      );
    }
    return _identity.changeUsername(raw);
  }

  // ── Media ─────────────────────────────────────────────────────────────────

  Future<void> addGridMedia(File file, String mediaType,
      {String? caption}) async {
    if (!isOwner) return;
    await _staging.queuePost(
      ownerUid: targetUid,
      source: file,
      mediaType: mediaType,
      caption: caption,
    );
    unawaited(processOutbox());
  }

  Future<void> addStory(File file, String mediaType) async {
    if (!isOwner) return;
    await _staging.queueStory(
      ownerUid: targetUid,
      source: file,
      mediaType: mediaType,
    );
    unawaited(processOutbox());
  }

  Future<void> replaceAvatar(File file) async {
    if (!isOwner) return;
    await _staging.queueAvatar(ownerUid: targetUid, source: file);
    unawaited(processOutbox());
  }

  Future<void> addProof(
    ShowcaseRecord record,
    File file,
    String mediaType, {
    String? caption,
  }) async {
    if (!isOwner) return;
    await _staging.queueProof(
      ownerUid: targetUid,
      source: file,
      fingerprint: record.fingerprint,
      slot: record.slot,
      mediaType: mediaType,
      caption: caption,
    );
    unawaited(processOutbox());
  }

  Future<void> removeProof(String fingerprint) async {
    if (!isOwner) return;
    await _showcase.detachProof(targetUid, fingerprint);
    // Detaching here must also stop the WES2 reconciler re-attaching it: it
    // would otherwise find the clip still local, still a live PB, and queue it
    // again on the next pass. Best-effort — a profile action must not fail
    // because a local database could not be opened.
    unawaited(_suppressLocalSetVideo(fingerprint: fingerprint));
  }

  /// Marks the local set-video record behind a published proof as suppressed,
  /// so automatic republication does not undo an explicit choice.
  Future<void> _suppressLocalSetVideo({
    String? fingerprint,
    String? postId,
  }) async {
    try {
      final SetVideoCoordinator c = await SetVideoCoordinator.instance();
      if (fingerprint != null) {
        await c.store.suppressByFingerprint(
            ownerUid: targetUid, fingerprint: fingerprint);
      }
      if (postId != null) {
        await c.store
            .suppressByPostId(ownerUid: targetUid, postId: postId);
      }
    } catch (_) {
      // No local footage on this device, or the store is unavailable. Nothing
      // to suppress, and nothing that should surface to the user.
    }
  }

  /// Attaches an EXISTING gallery item as proof, with no re-upload. This is
  /// the explicit relink path for legacy videos.
  Future<void> relinkProof(
      ShowcaseRecord record, ProfileMediaItem media) async {
    if (!isOwner) return;
    await _showcase.relinkExistingMedia(
      ownerUid: targetUid,
      record: record,
      postId: media.id,
      storagePath: media.storagePath,
      mediaType: media.mediaType,
      thumbUrl: media.thumbUrl,
    );
  }

  Future<void> deleteMedia(ProfileMediaItem item) async {
    if (!isOwner) return;
    if (item.pending) {
      await _media.cancelPending(item.id);
      unawaited(_suppressLocalSetVideo(postId: item.id));
      return;
    }
    await _media.deleteMedia(item);
    // An explicit deletion suppresses automatic resurrection. Only a new
    // recording or an explicit replace clears it again.
    unawaited(_suppressLocalSetVideo(
      postId: item.id,
      fingerprint: item.proof?.fingerprint,
    ));
  }

  Future<void> retryMedia(String mediaId) async {
    if (!isOwner) return;
    await _media.retryPending(mediaId);
    unawaited(processOutbox());
  }

  @override
  void dispose() {
    _storyExpiryTimer?.cancel();
    for (final StreamSubscription<Object?> sub in _subs.values) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _binders.clear();
    _failed.clear();
    bioController.dispose();
    bioFocus.dispose();
    super.dispose();
  }
}
