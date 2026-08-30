/// The profile page.
///
/// Deliberately thin: it wires a [ProfileController] to focused widgets and
/// owns nothing but navigation and pickers. Everything that used to make the
/// old 4,000-line page hard to change — best-lift scanning, post loading, the
/// comment list, an inline video player, body-metric editors, points
/// calculation — now lives behind repositories, or has been removed from the
/// profile entirely.
///
/// ── What is deliberately NOT here any more ──────────────────────────────────
/// Body metrics, RE / GoodLift points, competition singles, gender and height
/// are gone from this page. Their underlying data is untouched: bodyweight
/// entries, `rePoints*` fields and the demographics on the user document all
/// remain exactly where they were, and Body Weight Tracker, the leaderboard and
/// the points aggregator continue to read and write them.
library;

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../post_media.dart';
import '../post_service.dart';
import '../user_context.dart';
import 'core/media_models.dart';
import 'core/showcase_models.dart';
import 'data/identity_repository.dart';
import 'data/media_staging.dart';
import 'data/showcase_repository.dart';
import 'data/username_rules.dart';
import 'profile_controller.dart';
import 'profile_services.dart';
import 'ui/big_five_showcase.dart';
import 'ui/media_detail_page.dart';
import 'ui/media_grid.dart';
import 'ui/profile_header.dart';
import 'ui/profile_theme.dart';
import 'ui/story_viewer.dart';
import 'ui/units.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.viewedUid, this.readOnly = false});

  /// Whose profile to show. Null means the signed-in user's own.
  final String? viewedUid;

  /// Retained for call-site compatibility with the previous page. Owner-only
  /// controls are decided by [ProfileController.isOwner], so this can only ever
  /// hide controls further — never reveal them.
  final bool readOnly;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with WidgetsBindingObserver {
  ProfileController? _controller;
  final ImagePicker _picker = ImagePicker();
  WeightUnits _units = WeightUnits.kilograms;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => unawaited(_bootstrap()));
  }

  /// Builds the controller once the shared services are open.
  ///
  /// AWAITING [ProfileServices.ensureInitialised] rather than reading
  /// `.instance` is the whole point. `.instance` throws when initialisation
  /// has not finished, and it has not finished on any of the paths that reach
  /// this page early: a deep link, a notification tap, or simply opening the
  /// profile on the first frame of a cold start, while the outbox SQLite file
  /// is still being opened. app start calls ensureInitialised() too, so in the
  /// ordinary case this future is already complete and there is no extra
  /// frame.
  Future<void> _bootstrap() async {
    if (!mounted || _controller != null) return;
    // Read the context BEFORE the await: it may not be safe to touch after.
    final UserContext ctx = context.read<UserContext>();

    final ProfileServices services;
    try {
      services = await ProfileServices.ensureInitialised();
    } catch (e) {
      if (mounted) setState(() => _startupError = '$e');
      return;
    }
    if (!mounted || _controller != null) return;

    // Navigation semantics preserved from the old page:
    //   viewedUid set        → that person's profile (friend, or coach-selected)
    //   viewedUid null       → the athlete currently in focus (self, or the
    //                          athlete a coach is acting as)
    // Ownership is a SEPARATE question, answered by actorUid.
    final String target = widget.viewedUid?.trim().isNotEmpty == true
        ? widget.viewedUid!.trim()
        : ctx.actingAsUid;

    final ProfileController controller = ProfileController(
      targetUid: target,
      actorUid: ctx.actorUid,
      profiles: services.profiles,
      identity: services.identity,
      showcase: services.showcase,
      media: services.media,
      stories: services.stories,
      staging: services.staging,
      uploader: services.uploader,
    )..start();

    setState(() => _controller = controller);
    unawaited(_loadUnits(target, services));
  }

  Future<void> _loadUnits(String uid, ProfileServices services) async {
    final WeightUnits units = await services.weightUnitsFor(uid);
    if (mounted) setState(() => _units = units);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App resume is one of the four moments the outbox drains.
    if (state == AppLifecycleState.resumed) {
      unawaited(_controller?.processOutbox());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ProfileController? c = _controller;
    if (c == null) {
      final String? error = _startupError;
      return Scaffold(
        backgroundColor: ProfilePalette.navy,
        appBar: error == null
            ? null
            : AppBar(
                backgroundColor: ProfilePalette.navy,
                elevation: 0,
                foregroundColor: ProfilePalette.textPrimary,
              ),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator(color: ProfilePalette.action)
              : Padding(
                  padding: const EdgeInsets.all(ProfileSpacing.lg),
                  child: Text(
                    'Your profile could not be opened. Close the app and '
                    'reopen it, and anything still uploading will resume.',
                    textAlign: TextAlign.center,
                    style: ProfileText.recordDetail(context),
                  ),
                ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: c,
      builder: (BuildContext context, _) => Scaffold(
        backgroundColor: ProfilePalette.navy,
        appBar: AppBar(
          backgroundColor: ProfilePalette.navy,
          elevation: 0,
          foregroundColor: ProfilePalette.textPrimary,
          title: Text(c.displayName, style: ProfileText.liftName(context)),
          actions: <Widget>[
            if (c.isOwner)
              IconButton(
                tooltip: 'Add to your gallery',
                icon: const Icon(Icons.add_box_outlined),
                onPressed: () => _pickGridMedia(c),
              ),
          ],
        ),
        body: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: ProfileHeader(
                controller: c,
                onChangePhoto: () => _pickAvatar(c),
                onAddStory: () => _pickStory(c),
                onEditUsername: () => _editUsername(c),
                onViewStories: () => _openStories(c),
              ),
            ),
            SliverToBoxAdapter(
              child: BigFiveShowcase(
                view: c.showcase,
                units: _units,
                isOwner: c.isOwner,
                onAddProof: (ShowcaseRecord r) => _pickProof(c, r),
                onOpenProof: (ProofRecord p) => _openProof(c, p),
                onRemoveProof: (ShowcaseRecord r, ProofRecord p) =>
                    _removeProof(c, r, p),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  ProfileSpacing.lg,
                  ProfileSpacing.md,
                  ProfileSpacing.lg,
                  ProfileSpacing.sm,
                ),
                child:
                    Text('GALLERY', style: ProfileText.sectionTitle(context)),
              ),
            ),
            MediaGrid(
              items: c.grid,
              isOwner: c.isOwner,
              onOpen: (ProfileMediaItem i) => _openMedia(c, i),
              onRetry: (ProfileMediaItem i) => c.retryMedia(i.id),
              onDelete: (ProfileMediaItem i) => c.deleteMedia(i),
            ),
            const SliverToBoxAdapter(
                child: SizedBox(height: ProfileSpacing.xxl)),
          ],
        ),
      ),
    );
  }

  // ── Pickers ───────────────────────────────────────────────────────────────

  Future<XFile?> _pickImage() =>
      _picker.pickImage(source: ImageSource.gallery, imageQuality: 92);

  Future<void> _pickAvatar(ProfileController c) async {
    final XFile? picked = await _pickImage();
    if (picked == null) return;
    await _guard(() => c.replaceAvatar(File(picked.path)));
  }

  Future<void> _pickGridMedia(ProfileController c) async {
    final String? choice = await _chooseMediaType('Add to your gallery');
    if (choice == null) return;
    final XFile? picked = choice == MediaType.video
        ? await _picker.pickVideo(source: ImageSource.gallery)
        : await _pickImage();
    if (picked == null) return;
    if (!mounted) return;

    // The caption is asked for HERE, before the row is queued, so it travels
    // with the upload and is committed in the same write as the post. Adding
    // it afterwards would mean a second write, and a caption that is missing
    // for as long as the upload takes. It can still be edited later from the
    // post detail page.
    final String? caption = await _askForCaption();
    if (caption == null) return; // cancelled

    await _guard(() => c.addGridMedia(
          File(picked.path),
          choice,
          caption: caption.isEmpty ? null : caption,
        ));
  }

  /// Asks for an optional caption. Returns null if the user backed out, or the
  /// (possibly empty) text if they went ahead.
  Future<String?> _askForCaption({String initial = ''}) async {
    final TextEditingController field = TextEditingController(text: initial);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: ProfilePalette.surface,
        title: Text('Add a caption', style: ProfileText.liftName(ctx)),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLines: null,
          minLines: 1,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          style: ProfileText.bio(ctx),
          decoration: InputDecoration(
            hintText: 'Say something about this set (optional)',
            hintStyle:
                ProfileText.bio(ctx).copyWith(color: ProfilePalette.textMuted),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: ProfileText.button(ctx)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text('Skip', style: ProfileText.button(ctx)),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: ProfilePalette.action),
            onPressed: () => Navigator.pop(ctx, field.text.trim()),
            child: Text('Add', style: ProfileText.button(ctx)),
          ),
        ],
      ),
    );
    field.dispose();
    return result;
  }

  Future<void> _pickStory(ProfileController c) async {
    final String? choice = await _chooseMediaType('Add to your story');
    if (choice == null) return;
    final XFile? picked = choice == MediaType.video
        ? await _picker.pickVideo(source: ImageSource.gallery)
        : await _pickImage();
    if (picked == null) return;
    await _guard(() => c.addStory(File(picked.path), choice));
    if (!mounted) return;
    _toast('Story queued. Its 24 hours start once it publishes.');
  }

  Future<void> _pickProof(ProfileController c, ShowcaseRecord record) async {
    final XFile? picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    if (!mounted) return;
    final String? caption = await _askForCaption();
    if (caption == null) return;
    await _guard(
      () => c.addProof(
        record,
        File(picked.path),
        MediaType.video,
        caption: caption.isEmpty ? null : caption,
      ),
    );
    if (!mounted) return;
    _toast(
      c.showcase.oneVideoCoversBoth(record.slot)
          ? 'Proof queued — it covers both results for this lift.'
          : 'Proof queued.',
    );
  }

  Future<String?> _chooseMediaType(String title) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: ProfilePalette.surface,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(ProfileSpacing.lg),
              child: Text(title, style: ProfileText.sectionTitle(ctx)),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined,
                  color: ProfilePalette.textSecondary),
              title: Text('Photo', style: ProfileText.button(ctx)),
              onTap: () => Navigator.pop(ctx, MediaType.image),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined,
                  color: ProfilePalette.textSecondary),
              title: Text('Video', style: ProfileText.button(ctx)),
              onTap: () => Navigator.pop(ctx, MediaType.video),
            ),
            const SizedBox(height: ProfileSpacing.sm),
          ],
        ),
      ),
    );
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _editUsername(ProfileController c) async {
    final TextEditingController field =
        TextEditingController(text: c.displayName);
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: ProfilePalette.surface,
        title: Text('Change username', style: ProfileText.liftName(ctx)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: field,
              autofocus: true,
              style: ProfileText.bio(ctx),
              decoration: InputDecoration(
                hintText: 'New username',
                hintStyle: ProfileText.bio(ctx)
                    .copyWith(color: ProfilePalette.textMuted),
              ),
            ),
            const SizedBox(height: ProfileSpacing.md),
            Text(
              // Said up front, because it is a real constraint rather than a
              // failure: uniqueness needs a transaction, and transactions
              // cannot queue offline.
              kUsernameNeedsConnectionMessage,
              style: ProfileText.caption(ctx),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: ProfileText.button(ctx)),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: ProfilePalette.action),
            onPressed: () => Navigator.pop(ctx, field.text.trim()),
            child: Text('Save', style: ProfileText.button(ctx)),
          ),
        ],
      ),
    );
    field.dispose();

    if (entered == null || entered.isEmpty) return;
    final UsernameChangeResult result = await c.changeUsername(entered);
    if (!mounted) return;

    if (result.isSuccess) {
      _toast(result.outcome == UsernameChangeOutcome.unchanged
          ? 'That is already your username.'
          : 'Username updated everywhere.');
    } else {
      _toast(result.message ?? 'That username could not be saved.');
    }
  }

  Future<void> _openStories(ProfileController c) async {
    if (c.stories.isEmpty) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StoryViewer(
        stories: c.stories,
        username: c.displayName,
        isOwner: c.isOwner,
        onDelete: c.isOwner ? (StoryItem s) => _deleteStory(c, s) : null,
      ),
    ));
  }

  Future<void> _deleteStory(ProfileController c, StoryItem story) async {
    await ProfileServices.instance.stories.delete(c.targetUid, story.id);
  }

  /// Opens a grid tile.
  ///
  /// A PUBLISHED tile opens the app's real post experience — the same
  /// PostDetailPage the home feed opens, with caption, likes, GoodLifts,
  /// comments, caption editing and owner deletion — rather than the thin
  /// viewer this page used to draw. Tapping your own photo in the grid and
  /// getting a page with no comments and no like button was the single most
  /// obvious way the rebuilt profile felt less finished than the feed.
  ///
  /// A PENDING tile keeps the simplified local viewer: there is no post
  /// document to like or comment on yet, and its bytes are still only on this
  /// device.
  Future<void> _openMedia(ProfileController c, ProfileMediaItem item) async {
    if (item.pending) {
      await _openLocalPreview(c, item);
      return;
    }

    final Post? post = await _loadPost(item);
    if (!mounted) return;
    if (post == null) {
      // The document could not be read (offline with a cold cache, or it has
      // just been deleted). The simplified viewer still shows the media rather
      // than failing the tap outright.
      await _openLocalPreview(c, item);
      return;
    }

    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PostDetailPage(
        post: post,
        onToggleLike: (Post p) => PostService.instance.toggleLike(p.id),
        onToggleGoodLift: (Post p) => PostService.instance
            .toggleGoodLift(p.id, isVideo: p.mediaType == MediaType.video),
        onAddComment: (Post p, String text) => PostService.instance.addComment(
          p.id,
          text,
          usernameFallback: c.displayName,
        ),
        canDelete: c.isOwner,
      ),
    ));
  }

  /// Reads the post document behind a grid tile.
  Future<Post?> _loadPost(ProfileMediaItem item) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap =
          await FirebaseFirestore.instance
              .collection('posts')
              .doc(item.id)
              .get();
      if (!snap.exists) return null;
      return Post.fromSnap(snap);
    } catch (_) {
      return null;
    }
  }

  /// The thin viewer, for media with no post document behind it.
  Future<void> _openLocalPreview(
      ProfileController c, ProfileMediaItem item) async {
    final String url = item.smallUrl.isNotEmpty ? item.smallUrl : item.thumbUrl;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MediaDetailPage(
        title: c.displayName,
        mediaType: item.mediaType,
        url: url,
        localFilePath: item.pending ? item.localFilePath : null,
        caption: item.caption,
        badge:
            item.isProof ? _proofBadgeText(c, item.proof!.fingerprint) : null,
      ),
    ));
  }

  Future<void> _openProof(ProfileController c, ProofRecord proof) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MediaDetailPage(
        title: c.displayName,
        mediaType: proof.mediaType,
        url: proof.thumbUrl,
        badge: _proofBadgeText(c, proof.fingerprint),
      ),
    ));
  }

  /// Describes exactly which performance a proof is attached to.
  String? _proofBadgeText(ProfileController c, String fingerprint) {
    for (final ShowcaseLiftSnapshot lift
        in ShowcaseRepository.orderedLifts(c.showcase.showcase)) {
      for (final ShowcaseRecord? r in <ShowcaseRecord?>[
        lift.bestE1rm,
        lift.heaviest,
      ]) {
        if (r != null && r.fingerprint == fingerprint) {
          return '${lift.lift?.displayName ?? ''} · '
              '${_units.format(r.weight)} × ${r.reps} · '
              '${_units.formatDate(r.dateKey)}';
        }
      }
    }
    return null;
  }

  Future<void> _removeProof(
    ProfileController c,
    ShowcaseRecord record,
    ProofRecord proof,
  ) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: ProfilePalette.surface,
        title: Text('Remove this proof?', style: ProfileText.liftName(ctx)),
        content: Text(
          'The video stays in your gallery. It just stops being shown as '
          'proof of this record.',
          style: ProfileText.recordDetail(ctx),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Keep', style: ProfileText.button(ctx)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove',
                style: ProfileText.button(ctx)
                    .copyWith(color: ProfilePalette.danger)),
          ),
        ],
      ),
    );
    if (ok == true) await c.removeProof(record.fingerprint);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on MediaRejected catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('That could not be added right now.');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
