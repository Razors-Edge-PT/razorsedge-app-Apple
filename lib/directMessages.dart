import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';
import 'dart:math';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'dart:io';

import 'profile/data/identity_repository.dart';
import 'profile/ui/live_identity.dart';
import 'social/dm_unread_service.dart';
import 'social/social_activity_service.dart';
import 'social/ui/user_row.dart' show LiveBuddyAvatar;
import 'main.dart' show routeObserver;
import 'push/foreground_conversation.dart';
import 'push/foreground_focus.dart';

/// How much of a message row must be on screen for a reaction to it to count
/// as seen.
const double kMessageSeenFraction = 0.5;

/// Deterministic conversation id for a pair of users.
/// Ensures both users always open the same thread, no query needed.
String convIdFor(String a, String b) {
  final list = [a, b]..sort();
  return '${list[0]}_${list[1]}';
}

class BuddyPickerPage extends StatelessWidget {
  const BuddyPickerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(
        title: const Text("New Message"),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('buddyAssignments')
            .doc(uid)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snap.hasData || !snap.data!.exists) {
            return const Center(child: Text("No gym buddies yet"));
          }

          final data = snap.data!.data() as Map<String, dynamic>? ?? {};
          final allBuddies = Map<String, dynamic>.from(data['athletes'] ?? {});
          // Only confirmed (accepted) friends may be messaged.
          final buddies = Map<String, dynamic>.fromEntries(
            allBuddies.entries.where(
              (e) => e.value is Map && (e.value as Map)['status'] == 'accepted',
            ),
          );
          if (buddies.isEmpty) {
            return const Center(child: Text("No gym buddies yet"));
          }

          return ListView(
            children: buddies.entries.map((entry) {
              final buddyUid = entry.key; // 👈 this IS the other user’s uid
              final buddyData = entry.value as Map<String, dynamic>? ?? {};
              // buddyAssignments carries the name the buddy had when they were
              // added. Keep it only as a fallback; the row itself resolves the
              // CURRENT name by uid, so a rename shows up here immediately.
              final fallbackName =
                  (buddyData['displayName'] ?? buddyData['email'] ?? '')
                      .toString();

              return ListTile(
                  // The buddy's own picture, live and cached — not a generic
                  // placeholder, and never the signed-in user's.
                  leading: LiveBuddyAvatar(uid: buddyUid, size: 40),
                  title: LiveUserName(
                    uid: buddyUid,
                    fallback: fallbackName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onTap: () async {
                    final convId = convIdFor(uid, buddyUid);
                    final convRef = FirebaseFirestore.instance
                        .collection('conversations')
                        .doc(convId);

                    // ⚡ Bootstrap/touch conversation without a transaction (snappier local echo)
                    final now = FieldValue.serverTimestamp();
                    try {
                      // If it exists, just touch updatedAt (won't overwrite lastMessage/participantState)
                      await convRef.update({'updatedAt': now});
                    } catch (_) {
                      // If missing, create with the same initial shape you had before
                      await convRef.set({
                        'participants': {uid: true, buddyUid: true},
                        'participantList': ([uid, buddyUid]..sort()),
                        'createdAt': now,
                        'updatedAt': now,
                        'lastMessage': null,
                        'participantState': {
                          uid: {'unreadCount': 0},
                          buddyUid: {'unreadCount': 0},
                        },
                      }, SetOptions(merge: false));
                    }

                    if (!context.mounted) return;
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => ConversationPage(
                          convId: convId,
                          otherUid: buddyUid,
                        ),
                      ),
                    );
                  });
            }).toList(),
          );
        },
      ),
    );
  }
}

class DirectMessages extends StatelessWidget {
  const DirectMessages({
    super.key,
    this.unreadService,
    this.identity,
  });

  /// Injectable for tests; production uses the shared instances. The list
  /// itself always comes from [unreadService] (or [DmUnreadService.instance]),
  /// which already resolves the signed-in account — see its build() comment.
  final DmUnreadService? unreadService;
  final IdentityRepository? identity;

  @override
  Widget build(BuildContext context) {
    final DmUnreadService unread = unreadService ?? DmUnreadService.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Messages"),
        actions: [
          IconButton(
            icon: Icon(Icons.edit,
                color: Theme.of(context).colorScheme.secondary),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BuddyPickerPage()),
              );
            },
          ),
        ],
      ),
      // The list comes from DmUnreadService, not a direct query: `conversations`
      // has no query this account can safely LIST (its read rule needs a
      // confirmed-friend check Firestore cannot prove from a `.where()` filter
      // alone, so any such query is denied wholesale — see dm_unread_service.dart).
      // DmUnreadService instead holds one listener per confirmed friend's
      // conversation, which is what the badge already used; sharing it here
      // means opening this screen adds no second subscription.
      body: StreamBuilder<DmUnreadSnapshot>(
        stream: unread.watch(),
        initialData: unread.snapshot,
        builder: (context, snapshot) {
          final DmUnreadSnapshot state = snapshot.data ?? DmUnreadSnapshot.empty;
          // Retries whatever is actually recoverable right now: a terminated
          // per-conversation listener (most often one that failed before its
          // conversation existed) and the friend-list listener itself if that
          // is what failed — never a duplicate of an already-healthy one.
          // `watch()` above cannot do this itself: it is a no-op once this
          // account is already subscribed, so "reopening" this screen alone
          // does not retry anything without this explicit call.
          Future<void> retry() async => unread.retryFailed();

          final List<DmConversationUnread> rows = state.conversations.values.toList()
            ..sort((a, b) {
              final int at = a.updatedAt?.millisecondsSinceEpoch ?? 0;
              final int bt = b.updatedAt?.millisecondsSinceEpoch ?? 0;
              return bt.compareTo(at);
            });

          // Nothing usable to show, and something is currently failing to
          // load: whether that is the friend projection itself (never
          // loaded at all) or every desired conversation's listener having
          // failed before reporting anything, there is nothing to show but
          // the failure and a way to retry. Checked ahead of [state.loaded]
          // so this never gets mistaken for (and hidden behind) a plain
          // "still loading" spinner, and ahead of the empty-inbox screen so
          // a total failure is never shown as "No conversations yet".
          if (state.hasFailures && rows.isEmpty) {
            return RefreshIndicator(
              onRefresh: retry,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              "Couldn't load your messages.",
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: retry,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          if (!state.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (rows.isEmpty) {
            // Reached only with no current failures (the branch above would
            // otherwise have caught it) — a genuinely empty inbox, which
            // includes a confirmed friend whose conversation document does
            // not exist yet (see dm_unread_service.dart): that is not a
            // failure, so it belongs here, not in the error screen above.
            return RefreshIndicator(
              onRefresh: retry,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(
                    height: 400,
                    child: Center(child: Text("No conversations yet")),
                  ),
                ],
              ),
            );
          }

          // Some rows loaded and at least one conversation is currently
          // unreachable (or being retried): keep every usable row on screen
          // — a failed read is never evidence anything was read — and add a
          // compact banner rather than replacing the list, so recovering
          // access never looks like a moment of "no conversations".
          final int bannerCount = state.hasFailures ? 1 : 0;
          return RefreshIndicator(
            onRefresh: retry,
            child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: rows.length + bannerCount,
            itemBuilder: (context, i) {
              if (state.hasFailures && i == 0) {
                return _PartialInboxFailureBanner(onRetry: retry);
              }
              final DmConversationUnread row = rows[i - bannerCount];
              final int unreadCount = row.unread;
              final DateTime? updatedAt = row.updatedAt;

              // A one-shot users_public read used to name this row, so a rename
              // made while the list was open never appeared, and the raw uid
              // was shown until that read landed. LiveUserName keeps it current
              // and shows something human in the meantime.
              return Builder(
                builder: (context) {
                  return ListTile(
                    // The OTHER participant's picture, resolved from the
                    // conversation's participants against the signed-in uid.
                    leading: LiveBuddyAvatar(
                      uid: row.otherUid,
                      size: 40,
                      identity: identity,
                    ),
                    title: LiveUserName(
                      uid: row.otherUid,
                      identity: identity,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      row.lastMessageText,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: unreadCount > 0
                            ? Colors.white
                            : Colors.white70, // 👈 bold white if unread
                        fontWeight: unreadCount > 0
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (updatedAt != null)
                          Text(
                            "${updatedAt.hour}:${updatedAt.minute.toString().padLeft(2, '0')}",
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                        if (unreadCount > 0)
                          Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              unreadCount.toString(),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ConversationPage(
                            convId: row.convId,
                            otherUid: row.otherUid,
                            unreadService: unread,
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
            ),
          );
        },
      ),
    );
  }
}

/// Shown above otherwise-usable rows when some — but not all — of this
/// account's conversation listeners are currently failing (or a retry has
/// re-attached one but not yet resolved it). The rows themselves keep
/// showing their last known state; this only says more may be missing.
class _PartialInboxFailureBanner extends StatelessWidget {
  const _PartialInboxFailureBanner({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black26,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              "Some conversations may be missing or out of date.",
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class ConversationPage extends StatefulWidget {
  final String convId;
  final String otherUid;

  /// A message to reveal — the one a reaction notification is about.
  final String? focusMessageId;

  /// The activity record that alert or row was about, so it can be read by id
  /// rather than found in a window that may not contain it.
  final String? focusActivityId;

  /// Injectable for tests; production uses the shared instances.
  final DmUnreadService? unreadService;
  final SocialActivityService? activityService;

  /// Injectable for tests only — production always uses the real
  /// `FirebaseFirestore.instance` / signed-in `FirebaseAuth.instance` user.
  /// Only the reads the read-acknowledgement path itself needs (the message
  /// stream backing `_displayed`, the one-time lastReadAt fetch, and the
  /// current uid) go through these; everything else in this screen — sending,
  /// reactions, media — is unaffected and keeps using the production
  /// singletons directly.
  final FirebaseFirestore? firestore;
  final String? Function()? currentUid;

  const ConversationPage({
    super.key,
    required this.convId,
    required this.otherUid,
    this.focusMessageId,
    this.focusActivityId,
    this.unreadService,
    this.activityService,
    this.firestore,
    this.currentUid,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage>
    with RouteAware, WidgetsBindingObserver {
  // ── Push: is this thread the one actually on screen? ───────────────────
  // Reported to ForegroundConversation as this route becomes visible, is
  // covered, or is popped, so a DM notification for THIS thread shows no
  // extra banner while it is really in front of the person (and still does
  // when the page is merely mounted under another screen). Read state and
  // unread counts are untouched by this.
  ModalRoute<void>? _observedRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<void>? route = ModalRoute.of(context);
    if (route != null && !identical(route, _observedRoute)) {
      if (_observedRoute != null) routeObserver.unsubscribe(this);
      _observedRoute = route;
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPush() => _becameVisible();

  @override
  void didPopNext() => _becameVisible();

  @override
  void didPushNext() => _becameHidden();

  @override
  void didPop() => _becameHidden();

  void _becameVisible() {
    ForegroundConversation.shown(widget.convId);
    _routeVisible = true;
    _acknowledgeDisplayed();
  }

  void _becameHidden() {
    ForegroundConversation.hidden(widget.convId);
    _routeVisible = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to a chat that is still on screen reads what arrived while
    // the app was away; going away never marks anything read.
    if (state == AppLifecycleState.resumed) _acknowledgeDisplayed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ForegroundFocus.requests.removeListener(_onFocusRequest);
    routeObserver.unsubscribe(this);
    ForegroundConversation.hidden(widget.convId);
    super.dispose();
  }

  /// The newest focus request this thread has acted on.
  ///
  /// Compared by SERIAL, not by target id. Comparing ids meant that tapping
  /// the same reaction alert again — after scrolling away from the message it
  /// is about — did nothing at all, for the rest of the page's life.
  int _seenFocusSerial = 0;

  void _onFocusRequest() {
    final FocusRequest? req = ForegroundFocus.requests.value;
    if (!mounted ||
        !shouldActOnFocus(
          req: req,
          subjectId: widget.convId,
          lastSerial: _seenFocusSerial,
          viewerUid: FirebaseAuth.instance.currentUser?.uid,
        )) {
      return;
    }
    _seenFocusSerial = req!.serial;
    final String? activityId = req.activityId;
    if (activityId != null) unawaited(_resolveFocusActivity(activityId));
    final String? target = req.targetId;
    if (target != null) _scrollToMessage(target);
  }

  /// Scrolls a message into view by id, if it is in the loaded thread.
  void _scrollToMessage(String messageId) {
    final int index = _displayed.indexWhere(
        (QueryDocumentSnapshot<Object?> d) => d.id == messageId);
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpToIndex(index, alignment: 0.3);
      // Being scrolled to is what reads the reaction on it.
      _acknowledgeDisplayedReactions();
    });
  }

  // 👇 avoid duplicate .snapshots() listeners per message doc
  final Set<String> _watchedMsgIds = {};

  final Map<String, DateTime> _pendingLatencyMarks = {};
  final Set<String> _localEchoPrinted = {};

  // Scrolling infra
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  bool _didInitialJump = false;
  bool _isAtBottom = true; // updated live from itemPositionsListener

  String? _lastLatestMsgId; // for "auto-scroll on my new message"
  Timestamp? _initialLastReadAt; // from my participantState at page open
  bool _gotInitialLastReadAt = false;

  // ── Reading this conversation ─────────────────────────────────────────────
  // Reading is acknowledging a POSITION that was actually displayed — the
  // highest `incomingSeq` among the incoming messages this page is showing —
  // not a blind `unreadCount = 0`. A message that arrives while the chat is
  // opening carries a higher position, so it stays unread instead of being
  // swallowed; and the acknowledgement only happens while this route is the
  // visible one and the app is in the foreground, so a chat sitting under
  // another screen, or an app in the background, reads nothing.
  bool _routeVisible = false;
  int _ackedSeq = 0;
  final Set<String> _ackedMessageIds = <String>{};
  List<QueryDocumentSnapshot<Object?>> _displayed =
      const <QueryDocumentSnapshot<Object?>>[];

  DmUnreadService get _unread => widget.unreadService ?? DmUnreadService.instance;

  SocialActivityService get _activity =>
      widget.activityService ?? SocialActivityService.instance;

  FirebaseFirestore get _db => widget.firestore ?? FirebaseFirestore.instance;

  String? get _uid =>
      (widget.currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid))();

  /// The messages actually in the viewport, by id.
  ///
  /// `_displayed` is the whole loaded thread — hundreds of messages, of which
  /// a handful are on screen. Reading a reaction means having seen the message
  /// it is about, so the scroll positions decide, not the list contents.
  Set<String> visibleMessageIds() {
    final Set<String> ids = <String>{};
    for (final ItemPosition p in _itemPositionsListener.itemPositions.value) {
      if (p.index < 0 || p.index >= _displayed.length) continue; // tail spacer
      final double extent = p.itemTrailingEdge - p.itemLeadingEdge;
      if (extent <= 0) continue;
      final double onScreen =
          p.itemTrailingEdge.clamp(0.0, 1.0) - p.itemLeadingEdge.clamp(0.0, 1.0);
      // Either enough of the row is showing, or the row is taller than the
      // viewport and fills it.
      final bool seen = onScreen / extent >= kMessageSeenFraction ||
          (p.itemLeadingEdge <= 0 && p.itemTrailingEdge >= 1);
      if (seen) ids.add(_displayed[p.index].id);
    }
    return ids;
  }

  /// Reactions to messages this account SENT, for the messages ON SCREEN.
  ///
  /// Kept apart from the message ledger above on purpose: a reaction is not an
  /// incoming message, so acknowledging one can never move the unread-message
  /// count, and reading messages can never silently swallow a reaction that is
  /// still off screen.
  /// Whether this page may acknowledge anything at all right now.
  ///
  /// Checked on every entry to the reaction path, not only on the route
  /// callbacks: the path is also reached from a scroll callback and from an
  /// await returning, and either can land after the page has been covered,
  /// the app backgrounded or the account switched.
  bool _mayAcknowledgeNow() =>
      mounted &&
      shouldAcknowledgeRead(
        routeVisible: _routeVisible,
        appResumed:
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
        signedIn: _uid != null,
      );

  void _acknowledgeDisplayedReactions() {
    final Set<String> visible = visibleMessageIds();
    // What is on screen also decides whether a reaction's banner would be
    // telling the person something they can already see. Reported whatever
    // the acknowledgement rules say, because it is a statement about the
    // viewport rather than about reading.
    ForegroundConversation.reportVisibleMessages(widget.convId, visible);
    if (!_mayAcknowledgeNow()) return;
    if (visible.isEmpty) return;
    final Map<String, SocialActivity> known = <String, SocialActivity>{
      for (final SocialActivity a in _activity.snapshot.unread) a.id: a,
      for (final SocialActivity a in _subjectActivity) a.id: a,
      ..._focusRecords,
    };
    final List<SocialActivity> presented = presentedInConversation(
      unread: known.values.toList(growable: false),
      convId: widget.convId,
      displayedMessageIds: visible,
    );
    if (presented.isNotEmpty) unawaited(_activity.acknowledge(presented));

    // A reaction older than the tracked window is not in the live view, so a
    // message on screen that nothing explains means asking this conversation
    // directly — once.
    final Set<String> explained = <String>{
      for (final SocialActivity a in known.values)
        if (a.messageId != null) a.messageId!,
      ..._askedAboutMessages,
    };
    if (!_fetchingSubjectActivity &&
        visible.any((String id) => !explained.contains(id))) {
      unawaited(_refreshSubjectActivity(visible));
    }
  }

  /// Unread reaction records for THIS conversation, from the server.
  List<SocialActivity> _subjectActivity = const <SocialActivity>[];
  bool _fetchingSubjectActivity = false;
  final Set<String> _askedAboutMessages = <String>{};

  /// The reaction records taps have named, read by id — independent of every
  /// query window, so an old reaction is still readable when it is opened.
  final Map<String, SocialActivity> _focusRecords = <String, SocialActivity>{};
  final Set<String> _focusAsked = <String>{};

  /// Rises with every focus given to this page, so an answer that arrives
  /// after a newer request cannot overwrite it.
  int _focusGeneration = 0;

  Future<void> _resolveFocusActivity([String? activityId]) async {
    final String? id = activityId ?? widget.focusActivityId;
    if (id == null || !_focusAsked.add(id)) return;
    final String? owner = _activity.snapshot.uid;
    _focusGeneration++;
    final int generation = _focusGeneration;
    try {
      final SocialActivity? found = await _activity.activityById(id);
      if (!mounted ||
          found == null ||
          _activity.snapshot.uid != owner ||
          generation != _focusGeneration) {
        if (generation != _focusGeneration) _focusAsked.remove(id);
        return;
      }
      if (found.convId != widget.convId) return;
      _focusRecords[found.id] = found;
      _acknowledgeDisplayedReactions();
    } catch (_) {
      // Offline: the live view still covers everything recent.
      _focusAsked.remove(id);
    }
  }

  Future<void> _refreshSubjectActivity(Set<String> asked) async {
    if (_fetchingSubjectActivity) return;
    _fetchingSubjectActivity = true;
    final String? owner = _activity.snapshot.uid;
    try {
      final List<SocialActivity> found = await _activity
          .unreadForSubjectFromServer(dmSubject(widget.convId));
      // A lookup outlives the conditions it started under: the thread may have
      // been covered, the app backgrounded or the account switched while it
      // was in flight, and none of those may acknowledge anything.
      if (!mounted || _activity.snapshot.uid != owner) return;
      _askedAboutMessages.addAll(asked);
      final bool changed = found.isNotEmpty &&
          found.any((SocialActivity a) =>
              !_subjectActivity.any((SocialActivity b) => b.id == a.id));
      _subjectActivity = found;
      if (changed) _acknowledgeDisplayedReactions();
    } catch (_) {
      // Offline: the live view still covers everything recent.
    } finally {
      _fetchingSubjectActivity = false;
    }
  }

  void _acknowledgeDisplayed() {
    final String? uid = _uid;
    if (!mounted ||
        !shouldAcknowledgeRead(
          routeVisible: _routeVisible,
          appResumed: WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed,
          signedIn: uid != null,
        )) {
      return;
    }

    // Reactions to my own messages travel with the same "actually displayed"
    // rule, and are counted separately from unread messages.
    _acknowledgeDisplayedReactions();

    final DmReadBoundary boundary = computeReadBoundary(
      uid: uid!,
      messages: <DmDisplayedMessage>[
        for (final QueryDocumentSnapshot<Object?> d in _displayed)
          (
            id: d.id,
            senderId: (Map<String, dynamic>.from(
                        d.data() as Map? ?? const <String, dynamic>{})['senderId'] ??
                    '')
                .toString(),
            incomingSeq: (Map<String, dynamic>.from(
                d.data() as Map? ?? const <String, dynamic>{})['incomingSeq']) as int?,
          ),
      ],
    );

    final bool nothingNew = boundary.upToSeq <= _ackedSeq &&
        boundary.incomingIds.every(_ackedMessageIds.contains);
    if (nothingNew) return;
    _ackedSeq = boundary.upToSeq > _ackedSeq ? boundary.upToSeq : _ackedSeq;
    _ackedMessageIds.addAll(boundary.incomingIds);
    // Every incoming id this boundary covers, unabridged: cancellation is
    // now by EXACT message tag (see DmUnreadService.clearConversationAlerts),
    // not a conversation-wide prefix, so an id left out here would leave that
    // one alert stuck in the tray even though its content was just read. A
    // slice of only the most recent ids — the previous behaviour — silently
    // stopped covering anything older once a thread passed 50 unread.
    final List<String> ids = boundary.incomingIds;
    unawaited(_unread.acknowledge(
      convId: widget.convId,
      upToSeq: boundary.upToSeq,
      messageIds: ids,
    ));
  }

  // ---- DEBUG: live watcher for a single message doc ----
  void _debugWatchReactions(DocumentReference<Map<String, dynamic>> docRef,
      {String tag = ''}) {
    docRef.snapshots(includeMetadataChanges: true).listen((snap) {
      final data = snap.data() ?? <String, dynamic>{};
      final reactions = Map<String, dynamic>.from(data['reactions'] ?? {});
      final src = snap.metadata.isFromCache ? 'CACHE' : 'SERVER';
      // ignore: avoid_print
      print('👀 REACT watch $tag [$src] '
          'exists=${snap.exists} keys=${data.keys.toList()} '
          'reactionsKeys=${reactions.keys.toList()} values=${reactions}');
    }, onError: (e, st) {
      // ignore: avoid_print
      print('❗ REACT watch ERROR $tag: $e');
    });
  }

  // ---- DEBUG: mirror the Firestore rule checks for reactions ----
  Future<void> _debugRulesPreflight(
    DocumentReference<Map<String, dynamic>> msgRef,
    String uid,
    String? emoji,
  ) async {
    final msgPath = msgRef.path;
    final convRef = msgRef.parent.parent!;
    final convSnap = await convRef.get(const GetOptions(source: Source.server));
    final conv = Map<String, dynamic>.from(convSnap.data() ?? {});
    final participants = Map<String, dynamic>.from(conv['participants'] ?? {});

    final beforeSnap =
        await msgRef.get(const GetOptions(source: Source.server));
    final before = Map<String, dynamic>.from(beforeSnap.data() ?? {});
    final beforeReactions =
        Map<String, dynamic>.from(before['reactions'] ?? {});

    // prospective "after" document as the rules would see it
    final Map<String, dynamic> after = Map<String, dynamic>.from(before);
    final Map<String, dynamic> afterReactions =
        Map<String, dynamic>.from(beforeReactions);
    if (emoji == null) {
      afterReactions.remove(uid);
      if (afterReactions.isEmpty) {
        after.remove(
            'reactions'); // this simulates FieldValue.delete becoming no map
      } else {
        after['reactions'] = afterReactions;
      }
    } else {
      afterReactions[uid] = emoji;
      after['reactions'] = afterReactions;
    }

    bool isSignedInCheck = FirebaseAuth.instance.currentUser != null;
    bool isParticipantCheck = participants[uid] == true;

    // top-level key diffs
    Set<String> beforeKeys = before.keys.toSet();
    Set<String> afterKeys = after.keys.toSet();
    final addedTop = afterKeys.difference(beforeKeys);
    final removedTop = beforeKeys.difference(afterKeys);
    final changedTop = afterKeys.intersection(beforeKeys).where((k) {
      final b = before[k];
      final a = after[k];
      return k == 'reactions' ? true : a != b;
    }).toSet();

    // inner map diffs
    Map<String, dynamic> oldMap =
        Map<String, dynamic>.from(before['reactions'] ?? {});
    Map<String, dynamic> newMap =
        Map<String, dynamic>.from(after['reactions'] ?? {});
    final oldKeys = oldMap.keys.toSet();
    final newKeys = newMap.keys.toSet();
    final addedInner = newKeys.difference(oldKeys);
    final removedInner = oldKeys.difference(newKeys);
    final changedInner = newKeys
        .intersection(oldKeys)
        .where((k) => newMap[k] != oldMap[k])
        .toSet();

    // rule subclauses
    final caseA = addedTop.isEmpty &&
        removedTop.isEmpty &&
        changedTop.contains('reactions') &&
        (changedTop.length == 1) &&
        addedInner.every((k) => k == uid) &&
        removedInner.every((k) => k == uid) &&
        changedInner.every((k) => k == uid);

    final caseB = addedTop.isEmpty &&
        changedTop.isEmpty &&
        removedTop.length == 1 &&
        removedTop.contains('reactions') &&
        before['reactions'] is Map &&
        (oldKeys.length == 1 && oldKeys.contains(uid));

    final emojiOk = after.containsKey('reactions')
        ? (newMap[uid] is String
            ? (newMap[uid] as String).runes.length <= 8
            : true)
        : true;

    // Print a neat summary
    print('──────── REACT RULES PREFLIGHT (${msgPath}) ────────');
    print(
        'user uid=$uid  participant? $isParticipantCheck  signedIn? $isSignedInCheck');
    print('participants map keys=${participants.keys.toList()}');
    print('TOP added=$addedTop removed=$removedTop changed=$changedTop');
    print('INN added=$addedInner removed=$removedInner changed=$changedInner');
    print(
        'CaseA_keepReactionsOnly=$caseA  CaseB_removeWholeField=$caseB  emojiOk=$emojiOk');
    print(
        'FINAL allow? ${isSignedInCheck && isParticipantCheck && (caseA || caseB) && emojiOk}');
    print('before.reactions=${beforeReactions}');
    print(
        'after .reactions=${after.containsKey('reactions') ? newMap : '(none)'}');
    print('────────────────────────────────────────────────────');
  }

  // Helper: jump to index safely
  void _jumpToIndex(int index, {double alignment = 0.1}) {
    if (!_itemScrollController.isAttached) return;
    _itemScrollController.jumpTo(index: index, alignment: alignment);
  }

  // Helper: animate to bottom
  void _scrollToBottom({bool animated = true}) {
    if (!_itemScrollController.isAttached) return;
    if (animated) {
      _itemScrollController.scrollTo(
        index: _lastItemIndex,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _itemScrollController.jumpTo(index: _lastItemIndex, alignment: 1.0);
    }
  }

  int _lastItemIndex = 0;

  // You already pass this from the composer
  void _markSendStart(String clientId, DateTime startedAt) {
    _pendingLatencyMarks[clientId] = startedAt;
  }

  //message reactions bit
  static const List<String> _reactionChoices = [
    '👍',
    '❤️',
    '😂',
    '🔥',
    '😮',
    '😢',
    '👏',
    '🙏'
  ];

  // Toggle my reaction on a message (set/remove one emoji)
  Future<void> _toggleReactionForDoc(
    DocumentReference<Map<String, dynamic>> docRef,
    String? emoji,
  ) async {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    try {
      // BEFORE (read from server to avoid stale local cache)
      final beforeSnap =
          await docRef.get(const GetOptions(source: Source.server));
      final before = beforeSnap.data() ?? <String, dynamic>{};
      final beforeReactions =
          Map<String, dynamic>.from(before['reactions'] ?? {});

      // 🔒 Skip no-op writes (avoid rule checks & flicker)
      final prev = beforeReactions[uid];
      if ((emoji == null && prev == null) || (emoji != null && prev == emoji)) {
        // ignore: avoid_print
        print('🧯 REACT noop: prev="$prev" new="$emoji" → no update sent');
        return;
      }

      // Prepare the exact write we're about to send
      final Map<String, Object?> updateData = emoji == null
          ? {'reactions.$uid': FieldValue.delete()}
          : {'reactions.$uid': emoji};

// ignore: avoid_print
      print('✍️ REACT writeIntent: doc=${docRef.path} updateData=$updateData');
      // Debug: print shapes
      // ignore: avoid_print
      print('🧪 REACT before: '
          'hasReactions=${before.containsKey('reactions')} '
          'mapKeys=${beforeReactions.keys.toList()} '
          'myPrev="${beforeReactions[uid]}" '
          'update=${updateData}');

      // SEND
      // PREFLIGHT (mirrors the rule and prints exactly which clause fails)
      await _debugRulesPreflight(docRef, uid, emoji);

      // SEND
      await docRef.update(updateData);

      print('📤 REACT writeSent (await returned OK) for ${docRef.path}');

      // AFTER (get from server so we see the committed shape)
      final afterSnap =
          await docRef.get(const GetOptions(source: Source.server));
      final after = afterSnap.data() ?? <String, dynamic>{};
      final afterReactions =
          Map<String, dynamic>.from(after['reactions'] ?? {});
      print('🔁 REACT serverEcho: keys=${afterReactions.keys.toList()} '
          'mine="${afterReactions[uid]}" fullMap=$afterReactions');
      // ignore: avoid_print
      print('✅ REACT success: '
          'nowHasReactions=${after.containsKey('reactions')} '
          'mapKeys=${afterReactions.keys.toList()} '
          'myNow="${afterReactions[uid]}"');
    } on FirebaseException catch (e) {
      print('🛑 REACT update threw BEFORE serverEcho. code=${e.code}');
      // ignore: avoid_print
      print('⛔ REACT error: code=${e.code} msg="${e.message}" '
          'details=${e.stackTrace?.toString().split('\n').first ?? ''}');

      // Optional: fetch current server doc to compare what actually exists right now
      try {
        final curr = await docRef.get(const GetOptions(source: Source.server));
        final currMap = Map<String, dynamic>.from(curr.data() ?? {});
        final currReactions =
            Map<String, dynamic>.from(currMap['reactions'] ?? {});
        // ignore: avoid_print
        print('📡 REACT server-state-now: '
            'hasReactions=${currMap.containsKey('reactions')} '
            'mapKeys=${currReactions.keys.toList()} '
            'my="${currReactions[uid]}"');
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reaction failed: ${e.code}')),
        );
      }
      return;
    }
  }

  // Bottom-sheet picker
  Future<void> _pickReactionForDoc(
      DocumentReference<Map<String, dynamic>> docRef) async {
    final chosen = await showModalBottomSheet<String?>(
      context: context,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final e in _reactionChoices)
                InkWell(
                  onTap: () => Navigator.of(context).pop(e),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardTheme.color ??
                          Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 22)),
                  ),
                ),
              InkWell(
                onTap: () => Navigator.of(context).pop(null),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.shade400,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('Remove',
                      style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    print('🎯 REACT chosen="$chosen" → calling toggle for ${docRef.path}');
    await _toggleReactionForDoc(docRef, chosen);
    print('✅ REACT toggle completed for ${docRef.path}');
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    // Reading is driven by what the message list actually displays while this
    // route is visible (see _acknowledgeDisplayed), not by an unconditional
    // write on open and not by scroll position.
    // Listen for bottom reach (you already have this if you followed earlier steps)
    _itemPositionsListener.itemPositions.addListener(() {
      final positions = _itemPositionsListener.itemPositions.value;
      if (positions.isEmpty) return;

      final last = positions.firstWhere(
        (p) => p.index == _lastItemIndex,
        orElse: () => positions.reduce((a, b) => a.index > b.index ? a : b),
      );

      // How much of the last item is on screen
      final visiblePortion =
          (last.itemTrailingEdge - last.itemLeadingEdge).clamp(0.0, 1.0);

      // Consider “at bottom” if last item’s trailing edge is basically on-screen
      final atBottomNow =
          last.itemTrailingEdge >= 0.98 || visiblePortion >= 0.98;
      if (_isAtBottom != atBottomNow) {
        _isAtBottom = atBottomNow;
      }
      // Scrolling never writes MESSAGE read state: the old "last visible item"
      // fallback treated any scroll as reaching the bottom.
      //
      // It does decide REACTIONS, though — a reaction is read once the message
      // it is about has actually been scrolled to — so each settle re-checks
      // what is on screen. Acknowledging is idempotent and skips anything
      // already recorded, so this stays cheap.
      _acknowledgeDisplayedReactions();
    });

    // A second reaction alert for this same conversation, pointing at another
    // message: the page is already open, so reveal that message rather than
    // opening a second copy of the thread.
    ForegroundFocus.requests.addListener(_onFocusRequest);

    // The reaction this page was opened for, whatever window its record is in.
    unawaited(_resolveFocusActivity());

    // 👇 One-time fetch of my lastReadAt from the conversation doc
    final uid = _uid!;
    _db
        .collection('conversations')
        .doc(widget.convId)
        .get()
        .then((snap) {
      final data = snap.data() as Map<String, dynamic>? ?? {};
      final myState =
          (data['participantState'] ?? {})[uid] as Map<String, dynamic>? ?? {};
      _initialLastReadAt = myState['lastReadAt'] as Timestamp?;
      if (mounted) setState(() => _gotInitialLastReadAt = true);
    }).catchError((_) {
      if (mounted) setState(() => _gotInitialLastReadAt = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid!;

    return Scaffold(
        appBar: AppBar(
          title: const Text("Chat"),
        ),
        body: Column(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: _db
                    .collection('conversations')
                    .doc(widget.convId)
                    .collection('messages')
                    .snapshots(includeMetadataChanges: true),
                builder: (context, snapshot) {
                  if (!_gotInitialLastReadAt ||
                      snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  // Sort by server sentAt then fallback localSentAt
                  final msgs = (snapshot.data?.docs ?? []).toList()
                    ..sort((a, b) {
                      int ts(QueryDocumentSnapshot q) {
                        final m = q.data() as Map<String, dynamic>;
                        final server =
                            (m['sentAt'] as Timestamp?)?.millisecondsSinceEpoch;
                        final local = (m['localSentAt'] as int?) ?? 0;
                        return server ?? local;
                      }

                      return ts(a).compareTo(ts(b));
                    });

                  // What this build is about to show is what may be
                  // acknowledged as read — after the frame, and only while
                  // this route is visible and the app is in front.
                  _displayed = msgs;
                  WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _acknowledgeDisplayed());

                  final int listCount =
                      msgs.length + 1; // +1 tail spacer prevents bottom cutoff
                  _lastItemIndex =
                      listCount - 1; // spacer is now the visual last item

                  // Compute "first unread" index based on the cached _initialLastReadAt
                  int firstUnreadIndex = -1;
                  if (msgs.isNotEmpty) {
                    for (var i = 0; i < msgs.length; i++) {
                      final m = msgs[i].data() as Map<String, dynamic>;
                      final sentAt = (m['sentAt'] as Timestamp?);
                      final unread = (_initialLastReadAt == null)
                          ? (sentAt !=
                              null) // if we’ve never read, consider server-timestamped items unread
                          : (sentAt != null &&
                              sentAt
                                  .toDate()
                                  .isAfter(_initialLastReadAt!.toDate()));
                      if (unread) {
                        firstUnreadIndex = i;
                        break;
                      }
                    }
                  }

                  // One-time initial jump: to the message a reaction alert
                  // pointed at, else first unread, else bottom.
                  if (!_didInitialJump && msgs.isNotEmpty) {
                    _didInitialJump = true;
                    final String? focusId = widget.focusMessageId;
                    final int focusIndex = focusId == null
                        ? -1
                        : msgs.indexWhere(
                            (QueryDocumentSnapshot<Object?> d) => d.id == focusId);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (focusIndex != -1) {
                        _jumpToIndex(focusIndex, alignment: 0.3);
                      } else if (firstUnreadIndex != -1) {
                        _jumpToIndex(firstUnreadIndex, alignment: 0.1);
                      } else {
                        _jumpToIndex(_lastItemIndex, alignment: 1.0);
                      }
                    });
                  }

                  // Auto-scroll if a brand-new last message from ME appears
                  if (msgs.isNotEmpty) {
                    final last = msgs.last;
                    final lastData = last.data() as Map<String, dynamic>;
                    final lastFromSelf =
                        (lastData['senderId']?.toString() ?? '') == uid;
                    if (lastFromSelf) {
                      final latestId = last.id;
                      if (latestId != _lastLatestMsgId) {
                        _lastLatestMsgId = latestId;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _scrollToBottom(animated: true);
                        });
                      }
                    }
                  }
                  final keyboardOpen =
                      MediaQuery.of(context).viewInsets.bottom > 0.0;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (keyboardOpen && _isAtBottom && mounted) {
                      // No animation = no jank; this keeps the last bubble visible above the keyboard.
                      _scrollToBottom(animated: false);
                    }
                  });

                  return ScrollablePositionedList.builder(
                    itemScrollController: _itemScrollController,
                    itemPositionsListener: _itemPositionsListener,
                    padding: const EdgeInsets.only(bottom: 0),
                    itemCount: listCount,
                    itemBuilder: (context, i) {
                      // Tail spacer to ensure the last real message is fully visible above the bottom edge
                      if (i == msgs.length) {
                        return const SizedBox(
                            height: 20); // 16–24 is fine; 20 is a good default
                      }

                      final qDoc = msgs[i];

                      // 👀 start live reaction watch for this msg (once)
                      if (!_watchedMsgIds.contains(qDoc.id)) {
                        _watchedMsgIds.add(qDoc.id);
                        _debugWatchReactions(
                          qDoc.reference
                              as DocumentReference<Map<String, dynamic>>,
                          tag: 'tile:${qDoc.id}',
                        );
                      }

                      final raw = qDoc.data();
                      if (raw is! Map<String, dynamic>)
                        return const SizedBox.shrink();
                      final data = raw;

                      final fromSelf =
                          (data['senderId']?.toString() ?? '') == uid;

                      // Latency prints (local-echo + server-ack)
                      final clientId = (data['clientId'] ?? '').toString();
                      if (clientId.isNotEmpty &&
                          _pendingLatencyMarks.containsKey(clientId)) {
                        final started = _pendingLatencyMarks[clientId]!;
                        final now = DateTime.now();

                        if (!_localEchoPrinted.contains(clientId)) {
                          final localMs =
                              now.difference(started).inMilliseconds;
                          _localEchoPrinted.add(clientId);
                          // ignore: avoid_print
                          print(
                              '⚡ [DM] local-echo: ${localMs} ms (clientId=$clientId)');
                        }

                        if (!qDoc.metadata.hasPendingWrites) {
                          final serverMs =
                              now.difference(started).inMilliseconds;
                          _pendingLatencyMarks.remove(clientId);
                          _localEchoPrinted.remove(clientId);
                          // ignore: avoid_print
                          print(
                              '✅ [DM] server-ack: ${serverMs} ms (clientId=$clientId)');
                        }
                      }

                      final type = (data['type'] ?? 'text') as String;

                      // --- Reactions: aggregate + "mine" ---
                      final reactionsMap =
                          Map<String, dynamic>.from(data['reactions'] ?? {});
                      // ignore: avoid_print

                      final Map<String, int> reactionCounts = {};
                      final Set<String> myReactions = {};
                      final uidForReactions = uid;

                      reactionsMap.forEach((user, emoji) {
                        if (emoji is String && emoji.isNotEmpty) {
                          reactionCounts[emoji] =
                              (reactionCounts[emoji] ?? 0) + 1;
                          if (user == uidForReactions) myReactions.add(emoji);
                        }
                      });

                      return Align(
                        alignment: fromSelf
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: GestureDetector(
                          onLongPress: () => _pickReactionForDoc(
                            qDoc.reference
                                as DocumentReference<Map<String, dynamic>>,
                          ),
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                                vertical: 4, horizontal: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: fromSelf
                                  ? Theme.of(context).colorScheme.secondary
                                  : Theme.of(context).cardTheme.color ??
                                      Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // ---- message body (text / image / video) ----
                                if (type == 'video' &&
                                    (data['videoUrl'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                  _VideoTile(url: data['videoUrl'].toString())
                                else if (type == 'image' &&
                                    (data['imageUrl'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      data['imageUrl'].toString(),
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                else
                                  Text(
                                    (data['text'] ?? '').toString(),
                                    style: TextStyle(
                                      color: fromSelf
                                          ? Theme.of(context)
                                              .colorScheme
                                              .onSecondary
                                          : Colors.white,
                                    ),
                                  ),

                                if (reactionCounts.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 6,
                                    children: reactionCounts.entries.map((e) {
                                      final emoji = e.key;
                                      final count = e.value;
                                      final mine = myReactions.contains(emoji);
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: mine
                                              ? Colors.black26
                                              : Colors.black12,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          '$emoji $count',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // Composer (unchanged)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: _MessageComposer(
                  convId: widget.convId,
                  otherUid: widget.otherUid,
                  onClientSend: _markSendStart,
                  onTapComposer: () {
                    if (_isAtBottom) _scrollToBottom(animated: false);
                  },
                ),
              ),
            ),
          ],
        ));
  }
}

class _VideoTile extends StatefulWidget {
  final String url;
  const _VideoTile({required this.url});

  @override
  State<_VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<_VideoTile> {
  late final VideoPlayerController _c;
  ChewieController? _chewie;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _c.initialize().then((_) {
      _chewie = ChewieController(
        videoPlayerController: _c,
        autoPlay: false,
        looping: false,
      );
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_chewie == null || !_c.value.isInitialized) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SizedBox(height: 220, child: Chewie(controller: _chewie!));
  }
}

class _MessageComposer extends StatefulWidget {
  final String convId;
  final String otherUid;
  final void Function(String clientId, DateTime startedAt)? onClientSend;
  final VoidCallback? onTapComposer;

  const _MessageComposer({
    super.key,
    required this.convId,
    required this.otherUid,
    this.onClientSend,
    this.onTapComposer, // 👈 add this
  });

  @override
  State<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<_MessageComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode(); // 👈 add this
  bool _sending = false; // 👈 prevents double-sends
  static const int _maxChars = 2000; // 👈 matches Firestore rule cap
  final _picker = ImagePicker();
  File? videoFile;

  Future<void> _pickAndSendImage() async {
    final x = await _picker.pickImage(source: ImageSource.gallery);
    if (x == null) return;

    final uid = FirebaseAuth.instance.currentUser!.uid;
    final convId = widget.convId;

    // 1) create a message shell
    final convRef =
        FirebaseFirestore.instance.collection('conversations').doc(convId);
    final msgRef = convRef.collection('messages').doc();

    await msgRef.set({
      'senderId': uid,
      'type': 'image',
      'text': '',
      'localSentAt': DateTime.now().millisecondsSinceEpoch,
      'sentAt': FieldValue.serverTimestamp(),
    });

    // 2) upload
    final file = await x.readAsBytes();
    final path =
        'dm/$convId/${msgRef.id}/image_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final task = FirebaseStorage.instance.ref(path).putData(file);
    final snap = await task.whenComplete(() {});
    final url = await snap.ref.getDownloadURL();

    // 3) patch message with url (and update convo preview)
    await msgRef.update({'imageUrl': url});
    final now = FieldValue.serverTimestamp();
    await convRef.update({
      'lastMessage': {'text': '📷 Photo', 'senderId': uid, 'sentAt': now},
      'updatedAt': now,
      // The legacy counter installed builds still display. This app counts
      // from the server ledger instead, which already covers media; without
      // this line a photo stayed invisible to an older recipient's badge.
      'participantState.${widget.otherUid}.unreadCount': FieldValue.increment(1),
    });
  }

  Future<void> _pickAndSendVideo() async {
    final x = await _picker.pickVideo(source: ImageSource.gallery);
    if (x == null) return;

    final uid = FirebaseAuth.instance.currentUser!.uid;
    final convId = widget.convId;

    final convRef =
        FirebaseFirestore.instance.collection('conversations').doc(convId);
    final msgRef = convRef.collection('messages').doc();

    await msgRef.set({
      'senderId': uid,
      'type': 'video',
      'text': '',
      'localSentAt': DateTime.now().millisecondsSinceEpoch,
      'sentAt': FieldValue.serverTimestamp(),
    });

    final bytes = await x.readAsBytes();
    final path =
        'dm/$convId/${msgRef.id}/video_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final snap = await FirebaseStorage.instance
        .ref(path)
        .putData(bytes)
        .whenComplete(() {});
    final url = await snap.ref.getDownloadURL();

    await msgRef.update({'videoUrl': url});
    final now = FieldValue.serverTimestamp();
    await convRef.update({
      'lastMessage': {'text': '🎬 Video', 'senderId': uid, 'sentAt': now},
      'updatedAt': now,
      // See _pickAndSendImage: legacy counter for installed builds only.
      'participantState.${widget.otherUid}.unreadCount': FieldValue.increment(1),
    });
  }

  Future<void> _sendMessage() async {
    if (_sending) return;

    // Trim + enforce rule-aligned cap (2000 code points)
    var text = _controller.text.trim();
    if (text.isEmpty) return;
    if (text.runes.length > _maxChars) {
      final runes = text.runes.toList().sublist(0, _maxChars);
      text = String.fromCharCodes(runes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Message truncated to 2000 characters.')),
        );
      }
    }

    _controller.clear();
    setState(() => _sending = true);

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final otherUid = widget.otherUid;
      final convRef = FirebaseFirestore.instance
          .collection('conversations')
          .doc(widget.convId);
      final msgRef = convRef.collection('messages').doc();

      // Generate a clientId and mark start for latency
      final rnd = Random().nextInt(1 << 32);
      final clientId = '${DateTime.now().microsecondsSinceEpoch}_$rnd';
      widget.onClientSend?.call(clientId, DateTime.now());

      if (text.isNotEmpty) {
        // 📝 TEXT MESSAGE
        await msgRef.set({
          'senderId': uid,
          'type': 'text',
          'text': text,
          'clientId': clientId,
          'localSentAt': DateTime.now().millisecondsSinceEpoch,
          'sentAt': FieldValue.serverTimestamp(),
        });
      } else if (videoFile != null) {
        // 🎥 VIDEO MESSAGE
        final bytes = await videoFile!.readAsBytes(); // File you already picked
        final path =
            'dm/${widget.convId}/${msgRef.id}/video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await FirebaseStorage.instance.ref(path).putData(bytes);
        final url = await FirebaseStorage.instance.ref(path).getDownloadURL();

        await msgRef.set({
          'senderId': uid,
          'type': 'video',
          'text': '',
          'videoUrl': url,
          'clientId': clientId,
          'localSentAt': DateTime.now().millisecondsSinceEpoch,
          'sentAt': FieldValue.serverTimestamp(),
        });
      }

      // 2) Best-effort conversation state update
      final now = FieldValue.serverTimestamp();
      await convRef.update({
        'lastMessage': {'text': text, 'senderId': uid, 'sentAt': now},
        'updatedAt': now,
        'participantState.$uid.unreadCount': 0,
        'participantState.$uid.lastReadAt': now,
        'participantState.$otherUid.unreadCount': FieldValue.increment(1),
      }).catchError((_) async {
        // Bootstrap if convo missing (e.g., deep link)
        await convRef.set({
          'participants': {uid: true, otherUid: true}, // immutable per rules
          'participantList': ([uid, otherUid]..sort()),
          'createdAt': now,
          'updatedAt': now,
          'lastMessage': {'text': text, 'senderId': uid, 'sentAt': now},
          'participantState': {
            uid: {'lastReadAt': now, 'unreadCount': 0},
            otherUid: {'lastReadAt': null, 'unreadCount': 1},
          },
        }, SetOptions(merge: true));
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // 👉 Add this right under _sendMessage()
  Future<void> _pickVideo() async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked != null) {
      setState(() {
        videoFile = File(picked.path);
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focusNode, // keep if you already have this
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline, // 👈 Enter adds a newline
            onTap: widget
                .onTapComposer, // keep bottom pinned if we were already there
            minLines: 1,
            maxLines: 35, // or null for unlimited
            decoration: const InputDecoration(
              hintText: "Type a message…",
              border: OutlineInputBorder(),
              isDense: true,
            ),

            onSubmitted: null, // 👈 disable "Done" submit
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon:
              Icon(Icons.send, color: Theme.of(context).colorScheme.secondary),
          onPressed: _sendMessage,
        ),
        IconButton(
          icon:
              Icon(Icons.photo, color: Theme.of(context).colorScheme.secondary),
          onPressed: _pickAndSendImage,
        ),
        IconButton(
          icon: Icon(Icons.videocam,
              color: Theme.of(context).colorScheme.secondary),
          onPressed: _pickAndSendVideo,
        ),
      ],
    );
  }
}
