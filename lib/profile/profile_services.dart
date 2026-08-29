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

import 'data/identity_repository.dart';
import 'data/media_outbox.dart';
import 'data/media_repository.dart';
import 'data/media_staging.dart';
import 'data/media_uploader.dart';
import 'data/profile_repository.dart';
import 'data/showcase_repository.dart';
import 'data/story_repository.dart';
import 'ui/units.dart';

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
  });

  static ProfileServices? _instance;
  static Future<ProfileServices>? _initialising;

  /// The initialised services. Throws if used before [ensureInitialised]
  /// completes, which would be a wiring bug rather than a runtime condition.
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

  /// Opens the outbox and builds the repositories. Idempotent, and safe to
  /// call concurrently — overlapping calls await the same initialisation.
  static Future<ProfileServices> ensureInitialised() {
    final ProfileServices? existing = _instance;
    if (existing != null) return Future<ProfileServices>.value(existing);
    return _initialising ??= _build();
  }

  static Future<ProfileServices> _build() async {
    final MediaOutboxDatabase db = await MediaOutboxDatabase.open();
    final MediaOutbox outbox = MediaOutbox(db);

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
      staging: MediaStaging(outbox: outbox),
      uploader: MediaUploader(
        outbox: outbox,
        profiles: profiles,
        showcase: showcase,
        stories: stories,
      ),
    );
    _instance = services;
    _initialising = null;
    return services;
  }

  /// Drains the outbox. Called at app start; the profile page also calls it on
  /// open, on resume and when a server snapshot proves the connection is back.
  Future<void> processOutbox() => uploader.processAll();

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
    );
  }
}
