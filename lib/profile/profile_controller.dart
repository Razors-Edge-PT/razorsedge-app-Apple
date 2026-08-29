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
  })  : _profiles = profiles,
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
  List<StoryItem> get stories =>
      <StoryItem>[..._liveStories, ..._pendingStories];

  bool get hasStoryRing => stories.isNotEmpty;

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

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  bool _sawServerSnapshot = false;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void start() {
    _identityState = ProfileIdentity.empty(targetUid);

    _subs.add(_profiles.watch(targetUid).listen((ProfileIdentity next) {
      _identityState = next;
      _loaded = true;
      _syncEditors(next);
      _onSnapshotConnectivity(fromCache: next.isFromCache);
      notifyListeners();
    }));

    _subs.add(_showcase.watchProofs(targetUid).listen(
      (Map<String, ProofRecord> proofs) {
        _showcaseView = ShowcaseView(
          showcase: _identityState.showcase,
          proofsByFingerprint: proofs,
        );
        notifyListeners();
      },
    ));

    _subs
        .add(_media.watchGrid(targetUid).listen((List<ProfileMediaItem> items) {
      _published = items;
      notifyListeners();
    }));

    _subs.add(_stories.watchLive(targetUid).listen((List<StoryItem> items) {
      _liveStories = items;
      notifyListeners();
    }));

    if (isOwner) {
      _subs.add(
          _media.watchPending(targetUid).listen((List<ProfileMediaItem> items) {
        _pending = items;
        notifyListeners();
      }));
      _subs
          .add(_stories.watchPending(targetUid).listen((List<StoryItem> items) {
        _pendingStories = items;
        notifyListeners();
      }));
      _subs.add(_media.watchPendingAvatarPath(targetUid).listen((String? path) {
        _pendingAvatarPath = path;
        notifyListeners();
      }));
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
      ShowcaseRecord record, File file, String mediaType) async {
    if (!isOwner) return;
    await _staging.queueProof(
      ownerUid: targetUid,
      source: file,
      fingerprint: record.fingerprint,
      slot: record.slot,
      mediaType: mediaType,
    );
    unawaited(processOutbox());
  }

  Future<void> removeProof(String fingerprint) async {
    if (!isOwner) return;
    await _showcase.detachProof(targetUid, fingerprint);
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
      return;
    }
    await _media.deleteMedia(item);
  }

  Future<void> retryMedia(String mediaId) async {
    if (!isOwner) return;
    await _media.retryPending(mediaId);
    unawaited(processOutbox());
  }

  @override
  void dispose() {
    for (final StreamSubscription<Object?> sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    bioController.dispose();
    bioFocus.dispose();
    super.dispose();
  }
}
