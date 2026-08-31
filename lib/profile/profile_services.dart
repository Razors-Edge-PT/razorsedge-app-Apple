/// Wiring for the profile feature.
///
/// One lazily-initialised set of repositories shared by every profile the user
/// opens. The media outbox in particular MUST be a singleton: two SQLite
/// handles on the same file would let one processor upload a row another
/// processor has already committed.
///
/// [ensureInitialised] is called once at app start so the outbox opens (and its
/// backlog drains) before any profile is opened — that is what makes an upload
/// interrupted by yesterday's crash resume today.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'data/identity_repository.dart';
import 'data/media_outbox.dart';
import 'data/media_repository.dart';
import 'data/media_staging.dart';
import 'data/media_uploader.dart';
import 'data/profile_repository.dart';
import 'data/showcase_repository.dart';
import 'data/story_repository.dart';
import 'ui/units.dart';
import '../wes2_video/set_video_publication.dart';
import '../wes2_video/set_video_service.dart';

class ProfileServices {
  ProfileServices._({
    required this.outbox,
    required this.profiles,
    required this.identity,
    required this.showcase,
    required this.media,
    required this.stories,
    required this.staging,
    required this.uploader,
    required this.setVideo,
  });

  static ProfileServices? _instance;
  static Future<ProfileServices>? _initialising;

  /// The initialised services. Throws if used before [ensureInitialised]
  /// completes, which would be a wiring bug rather than a runtime condition.
  ///
  /// Prefer [ensureInitialised] anywhere the timing is not already guaranteed.
  /// Opening a profile from a notification, a deep link, or a fast tap on the
  /// very first frame all reach the page BEFORE the app-start initialisation
  /// has finished opening the SQLite file, and this getter cannot wait.
  static ProfileServices get instance {
    final ProfileServices? i = _instance;
    if (i == null) {
      throw StateError(
        'ProfileServices.ensureInitialised() must complete before use.',
      );
    }
    return i;
  }

  static bool get isReady => _instance != null;

  final MediaOutbox outbox;
  final ProfileRepository profiles;
  final IdentityRepository identity;
  final ShowcaseRepository showcase;
  final MediaRepository media;
  final StoryRepository stories;
  final MediaStaging staging;
  final MediaUploader uploader;

  /// Set-video store, pipeline and reconciler.
  ///
  /// Lives here because this is already the place that guarantees exactly one
  /// SQLite handle per file, and because the set-video maintenance pass has the
  /// same triggers as the outbox drain: start, resume, and reconnection.
  ///
  /// Nullable: a failure to open the set-video database must never stop the
  /// profile or the workout logger from working. Everything else keeps going
  /// and set video is simply unavailable for the session.
  final SetVideoService? setVideo;

  /// Opens the outbox and builds the repositories.
  ///
  /// Idempotent, and safe to call concurrently: overlapping calls await the
  /// SAME initialisation, which is what stops two SQLite handles being opened
  /// on one file. Two handles would let one processor upload a row another
  /// processor had already committed.
  ///
  /// ── Failure is not sticky ───────────────────────────────────────────────
  /// A failed build clears the in-flight future instead of leaving it cached,
  /// so a transient failure (the support directory not yet available on a cold
  /// start, say) can be retried by the next caller. Caching the rejected
  /// future would make one unlucky moment at launch break the profile page for
  /// the rest of the session.
  static Future<ProfileServices> ensureInitialised() {
    final ProfileServices? existing = _instance;
    if (existing != null) return Future<ProfileServices>.value(existing);
    final Future<ProfileServices>? inFlight = _initialising;
    if (inFlight != null) return inFlight;
    final Future<ProfileServices> started = _build();
    _initialising = started;
    return started;
  }

  static Future<ProfileServices> _build() async {
    try {
      return await _buildInner();
    } catch (_) {
      // Let the next caller try again rather than caching the rejection.
      _initialising = null;
      rethrow;
    }
  }

  static Future<ProfileServices> _buildInner() async {
    final MediaOutboxDatabase db = await MediaOutboxDatabase.open();
    final MediaOutbox outbox = MediaOutbox(db);
    final MediaStaging staging = MediaStaging(outbox: outbox);

    // Best-effort: set video is an enhancement, and the profile and the workout
    // logger must both survive its database failing to open.
    SetVideoService? setVideo;
    try {
      setVideo = await SetVideoService.ensureInitialised(
        staging: staging,
        outbox: outbox,
      );
    } catch (_) {
      setVideo = null;
    }

    final ProfileRepository profiles = ProfileRepository();
    final ShowcaseRepository showcase = ShowcaseRepository();
    final StoryRepository stories = StoryRepository(outbox: outbox);
    final MediaRepository media = MediaRepository(outbox: outbox);

    final ProfileServices services = ProfileServices._(
      outbox: outbox,
      profiles: profiles,
      identity: IdentityRepository.shared,
      showcase: showcase,
      media: media,
      stories: stories,
      staging: staging,
      uploader: MediaUploader(
        outbox: outbox,
        profiles: profiles,
        showcase: showcase,
        stories: stories,
      ),
      setVideo: setVideo,
    );
    _instance = services;
    _initialising = null;
    return services;
  }

  /// Drains the outbox, then runs the set-video maintenance pass.
  ///
  /// Called at app start (main.dart), and by the profile page on open, on
  /// resume, and when a server snapshot proves the connection is back — which
  /// is exactly the trigger list set-video reconciliation needs, so the two
  /// ride together rather than growing a second set of lifecycle hooks.
  ///
  /// The outbox drains FIRST: it is what turns a queued upload into a published
  /// post, and the maintenance pass immediately afterwards is what records that
  /// outcome against the local set-video record.
  Future<void> processOutbox({String? actingUid}) async {
    await uploader.processAll();
    await runSetVideoMaintenance(actingUid: actingUid);
  }

  /// Runs one set-video maintenance pass for [actingUid].
  ///
  /// Publication requires the acting user to BE the owner, so the actor is
  /// built with the same uid on both sides here; a coach acting as an athlete
  /// reaches this with the athlete's uid and is rejected by the gate.
  Future<void> runSetVideoMaintenance({String? actingUid}) async {
    final SetVideoService? service = setVideo;
    final String uid = actingUid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    if (service == null || uid.isEmpty) return;
    try {
      await service.runMaintenance(
        actor: SetVideoActor(authenticatedUid: uid, actingUid: uid),
      );
    } catch (_) {
      // Maintenance is background work. It must never surface as a failure of
      // whatever the user was actually doing.
    }
  }

  /// The display unit for [uid]'s training loads.
  ///
  /// Storage stays canonical kilograms regardless; this only affects how the
  /// showcase renders. A missing preference — which is every account today —
  /// means kilograms, exactly what the app has always shown.
  Future<WeightUnits> weightUnitsFor(String uid) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      return WeightUnits.fromUserData(snap.data());
    } catch (_) {
      return WeightUnits.kilograms;
    }
  }

  /// Test seam: replaces the singleton with an explicitly constructed set.
  static void debugOverride(ProfileServices services) {
    _instance = services;
    _initialising = null;
  }

  /// Test seam: builds a service set around an already-open outbox.
  static ProfileServices debugBuild({
    required MediaOutbox outbox,
    ProfileRepository? profiles,
    IdentityRepository? identity,
    ShowcaseRepository? showcase,
    MediaRepository? media,
    StoryRepository? stories,
    MediaStaging? staging,
    MediaUploader? uploader,
    SetVideoService? setVideo,
  }) {
    final ProfileRepository p = profiles ?? ProfileRepository();
    final ShowcaseRepository s = showcase ?? ShowcaseRepository();
    final StoryRepository st = stories ?? StoryRepository(outbox: outbox);
    return ProfileServices._(
      outbox: outbox,
      profiles: p,
      identity: identity ?? IdentityRepository.shared,
      showcase: s,
      media: media ?? MediaRepository(outbox: outbox),
      stories: st,
      staging: staging ?? MediaStaging(outbox: outbox),
      uploader: uploader ??
          MediaUploader(outbox: outbox, profiles: p, showcase: s, stories: st),
      setVideo: setVideo,
    );
  }
}
