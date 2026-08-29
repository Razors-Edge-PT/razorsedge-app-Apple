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

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  void _bootstrap() {
    if (!mounted || _controller != null) return;
    final UserContext ctx = context.read<UserContext>();
    final ProfileServices services = ProfileServices.instance;

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
      return const Scaffold(
        backgroundColor: ProfilePalette.navy,
        body: Center(
          child: CircularProgressIndicator(color: ProfilePalette.action),
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
    await _guard(() => c.addGridMedia(File(picked.path), choice));
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
    await _guard(
      () => c.addProof(record, File(picked.path), MediaType.video),
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

  Future<void> _openMedia(ProfileController c, ProfileMediaItem item) async {
    final String url = item.smallUrl.isNotEmpty ? item.smallUrl : item.thumbUrl;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MediaDetailPage(
        title: c.displayName,
        mediaType: item.mediaType,
        url: url,
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
