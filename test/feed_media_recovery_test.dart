/// The home feed's media: it must load itself.
///
/// The reported defect: posts under the calendar came up as "Couldn't load"
/// with a Retry button, several at a time; tapping Retry eventually produced
/// the picture, slowly; leaving the page and coming back produced the same
/// blank cards again. The same feed inside the Buddy Hub behaved better.
///
/// These pin the contract that makes that impossible, at the level the bug
/// actually lives at — which operations run, in what order, how many times,
/// and what is left on disk afterwards. Nothing here depends on real network
/// timing: every store is scripted, so a failure means the ORDER or the COUNT
/// changed, not that a download was slow today.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/profile/core/media_models.dart';
import 'package:localtest222/profile/data/media_url_refresh.dart';
import 'package:localtest222/profile/ui/cached_network_image.dart';
import 'package:localtest222/social/feed_repository.dart';
import 'package:localtest222/social/feed_view.dart';
import 'package:localtest222/social/home_feed_section.dart';
import 'package:localtest222/social/ui/feed_card.dart';
import 'package:localtest222/social/user_search_repository.dart';
import 'package:table_calendar/table_calendar.dart';

const String kOwner = 'owner-uid';
const String kPath = 'users/owner-uid/posts/m1/original.jpg';
const String kKey = 'glmedia|owner-uid|small|$kPath';
const String kStaleUrl = 'https://firebasestorage.googleapis.com/v0/b/b/o/'
    'users%2Fowner-uid%2Fposts%2Fm1%2Foriginal.jpg?alt=media&token=stale';
const String kFreshUrl = 'https://firebasestorage.googleapis.com/v0/b/b/o/'
    'users%2Fowner-uid%2Fposts%2Fm1%2Foriginal.jpg?alt=media&token=fresh';

void main() {
  late Directory tmp;
  late _TestStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('feed_media');
    store = _TestStore(tmp);
    profileImageStore = store;
  });

  tearDown(() {
    resetProfileImageCache();
    resetProfileUrlRefresher();
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows holds the file while a decoded image still references it.
    }
  });

  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  Widget image({
    ProfileImageStore? from,
    String url = kStaleUrl,
    String key = kKey,
    String storagePath = kPath,
    StorageUrlRefresher? refresher,
    Duration read = const Duration(milliseconds: 100),
    Duration download = const Duration(milliseconds: 300),
  }) =>
      CachedProfileImage(
        url: url,
        cacheKey: key,
        storagePath: storagePath,
        urlRefresher: refresher,
        store: from,
        readTimeout: read,
        downloadTimeout: download,
        placeholder: const Text('loading'),
        errorBuilder: (BuildContext c, MediaLoadFailure f, VoidCallback retry) =>
            Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Text(f == MediaLoadFailure.offline ? 'offline' : 'failed'),
          TextButton(onPressed: retry, child: const Text('Retry')),
        ]),
      );

  // ── A stale URL recovers itself, exactly once ─────────────────────────────
  group('a stale or revoked URL recovers without the user', () {
    testWidgets('it is refreshed through the canonical path and reloaded, '
        'with no Retry tapped', (WidgetTester t) async {
      int lookups = 0;
      store.fail(const _Status(403), times: 1);
      await t.pumpWidget(wrap(image(
        from: store,
        refresher: StorageUrlRefresher(lookup: (String p) async {
          lookups++;
          expect(p, kPath, reason: 'the canonical object, not a guess');
          return kFreshUrl;
        }),
      )));
      await t.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget,
          reason: 'the tile recovered on its own');
      expect(find.text('Retry'), findsNothing);
      expect(lookups, 1, reason: 'exactly one canonical refresh');
      expect(store.downloadUrls, <String>[kStaleUrl, kFreshUrl],
          reason: 'the known-bad URL is never attempted twice');
      expect(store.downloadKeys, <String>[kKey, kKey],
          reason: 'a refreshed URL is the same object, so the same entry');
    });

    testWidgets('an object that is genuinely gone settles, with no loop',
        (WidgetTester t) async {
      int lookups = 0;
      // Storage answers 403 for a deleted object too — only the canonical
      // lookup can tell "revoked" from "gone".
      store.fail(const _Status(403));
      await t.pumpWidget(wrap(image(
        from: store,
        refresher: StorageUrlRefresher(lookup: (_) async {
          lookups++;
          return null;
        }),
      )));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 2));

      expect(find.text('failed'), findsOneWidget);
      expect(lookups, 1);
      expect(store.downloadUrls, <String>[kStaleUrl],
          reason: 'no second attempt at a URL known to be refused');
    });

    testWidgets('a 404 is never refreshed and never retried',
        (WidgetTester t) async {
      int lookups = 0;
      store.fail(const _Status(404));
      await t.pumpWidget(wrap(image(
        from: store,
        refresher: StorageUrlRefresher(lookup: (_) async {
          lookups++;
          return kFreshUrl;
        }),
      )));
      await t.pumpAndSettle();

      expect(find.text('failed'), findsOneWidget);
      expect(lookups, 0, reason: 'no Storage call is spent on a missing object');
      expect(store.downloadUrls, hasLength(1));
    });
  });

  // ── The reported failure: one transient hiccup, one permanent blank ───────
  group('a transient failure does not become a permanent blank card', () {
    testWidgets('a dropped connection is retried once, automatically',
        (WidgetTester t) async {
      // Exactly what package:http hands back when a pooled connection dies:
      // an HttpException re-thrown as a ClientException, which is neither a
      // SocketException nor a status code.
      store.fail(
          _Transport('Connection closed before full header was received'),
          times: 1);
      await t.pumpWidget(wrap(image(from: store)));
      await t.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget,
          reason: 'the card recovered without the user tapping anything');
      expect(find.text('Retry'), findsNothing);
      expect(store.downloadUrls, hasLength(2), reason: 'one retry, not a loop');
    });

    testWidgets('a slow transfer that outruns the timeout is waited for, '
        'not restarted', (WidgetTester t) async {
      // The first attempt times out at 300ms; the transfer it started lands at
      // 500ms. The bytes arrived, so the card must show them.
      store.delay(const Duration(milliseconds: 500));
      await t.pumpWidget(wrap(image(from: store)));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(store.downloadUrls, hasLength(1),
          reason: 'the transfer already running is joined, never duplicated');
    });

    testWidgets('after a genuine failure the card offers Retry, and it works',
        (WidgetTester t) async {
      store.fail(const SocketException('no route'));
      await t.pumpWidget(wrap(image(from: store)));
      await t.pumpAndSettle();
      expect(find.text('offline'), findsOneWidget);
      expect(store.downloadUrls, hasLength(1),
          reason: 'no automatic retry while the device is offline');

      store.healthy();
      await t.tap(find.text('Retry'));
      await t.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
    });
  });

  // ── The cache is what makes the second visit free ─────────────────────────
  group('persistent caching', () {
    testWidgets('a cached file renders with no network at all',
        (WidgetTester t) async {
      store.seed(kKey);
      await t.pumpWidget(wrap(image(from: store)));
      await t.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(store.downloadUrls, isEmpty);
    });

    testWidgets('media recovered on the first visit comes off disk on the '
        'second, with no network', (WidgetTester t) async {
      store.fail(_Transport('Connection reset'), times: 1);
      await t.pumpWidget(wrap(image(from: store)));
      await t.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      final int afterFirst = store.downloadUrls.length;

      // Leave the page and come back: a brand-new widget, same disk.
      await t.pumpWidget(wrap(const SizedBox.shrink()));
      await t.pumpAndSettle();
      await t.pumpWidget(wrap(image(from: store)));
      await t.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget,
          reason: 'coming back must not re-open the same hole');
      expect(store.downloadUrls, hasLength(afterFirst),
          reason: 'the second visit is free');
    });

    testWidgets('a rebuilt store over the same directory still has the bytes',
        (WidgetTester t) async {
      // A process restart, modelled the only way that means anything: the
      // cache instance is thrown away and a new one is built over the same
      // files, with every fetch guaranteed to fail.
      await t.pumpWidget(wrap(image(from: store)));
      await t.pumpAndSettle();
      expect(store.downloadUrls, hasLength(1));

      final _TestStore restarted = _TestStore(tmp)
        ..fail(const SocketException('no route'));
      profileImageStore = restarted;
      await t.pumpWidget(wrap(const SizedBox.shrink()));
      await t.pumpAndSettle();
      await t.pumpWidget(wrap(image(from: restarted)));
      await t.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(restarted.downloadUrls, isEmpty,
          reason: 'a disk hit must not go to the network at all');
    });

    testWidgets('cached bytes still render when the device is offline',
        (WidgetTester t) async {
      store.seed(kKey);
      store.fail(const SocketException('no route'));
      await t.pumpWidget(wrap(image(from: store)));
      await t.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(store.downloadUrls, isEmpty);
    });

    testWidgets('two cards showing the same media download it once',
        (WidgetTester t) async {
      store.delay(const Duration(milliseconds: 100));
      await t.pumpWidget(wrap(Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(width: 40, height: 40, child: image(from: store)),
          SizedBox(width: 40, height: 40, child: image(from: store)),
        ],
      )));
      await t.pumpAndSettle();

      expect(find.byType(Image), findsNWidgets(2));
      expect(store.downloadUrls, hasLength(1),
          reason: 'one operation per media and variant, joined by both cards');
    });

    testWidgets('a card disposed mid-download is safe, and its bytes still '
        'land for the next one', (WidgetTester t) async {
      store.delay(const Duration(milliseconds: 200));
      await t.pumpWidget(wrap(image(from: store)));
      await t.pump(const Duration(milliseconds: 50));
      await t.pumpWidget(wrap(const SizedBox.shrink()));
      await t.pump(const Duration(milliseconds: 400));
      expect(t.takeException(), isNull);

      await t.pumpWidget(wrap(image(from: store)));
      await t.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(store.downloadUrls, hasLength(1),
          reason: 'the abandoned transfer finished the job');
    });
  });

  // ── What a card is allowed to fetch ───────────────────────────────────────
  group('a feed card fetches the smallest thing that will do', () {
    FeedItem video({String thumbUrl = '', String thumbPath = ''}) => FeedItem(
          id: 'o__v1',
          ownerUid: kOwner,
          postId: 'v1',
          mediaType: MediaType.video,
          thumbUrl: thumbUrl,
          thumbStoragePath: thumbPath,
          smallUrl: 'https://firebasestorage.googleapis.com/v0/b/b/o/'
              'users%2Fowner-uid%2Fposts%2Fv1%2Foriginal?alt=media&token=t',
          storagePath: 'users/owner-uid/posts/v1/original.mp4',
          createdAt: DateTime.utc(2026, 5, 1),
        );

    testWidgets('a video tile draws its poster and never touches the clip',
        (WidgetTester t) async {
      store.seedAll();
      await t.pumpWidget(wrap(SizedBox(
        width: 300,
        child: FeedCard(
          item: video(
            thumbUrl: 'https://firebasestorage.googleapis.com/v0/b/b/o/'
                'users%2Fowner-uid%2Fposts%2Fv1%2Fthumb.jpg?alt=media&token=t',
            thumbPath: 'users/owner-uid/posts/v1/thumb.jpg',
          ),
          now: DateTime.utc(2026, 5, 1),
        ),
      )));
      await t.pumpAndSettle();

      expect(store.requestedKeys, hasLength(1));
      expect(store.requestedKeys.single, contains('thumb'));
      expect(store.downloadUrls.where((String u) => u.contains('original')),
          isEmpty,
          reason: 'a feed tile must never fetch a video');
    });

    testWidgets('a video with no poster shows a quiet placeholder, not a '
        'useless Retry', (WidgetTester t) async {
      store.seedAll();
      await t.pumpWidget(wrap(SizedBox(
        width: 300,
        child: FeedCard(item: video(), now: DateTime.utc(2026, 5, 1)),
      )));
      await t.pumpAndSettle();

      expect(store.requestedKeys, isEmpty,
          reason: 'there is nothing safe to fetch, so nothing is fetched');
      expect(find.text('Retry'), findsNothing,
          reason: 'retrying cannot conjure a poster that was never uploaded');
    });

    testWidgets('a photo tile draws the small variant', (WidgetTester t) async {
      store.seedAll();
      await t.pumpWidget(wrap(SizedBox(
        width: 300,
        child: FeedCard(
          item: FeedItem(
            id: 'o__p1',
            ownerUid: kOwner,
            postId: 'm1',
            mediaType: MediaType.image,
            smallUrl: kStaleUrl,
            thumbUrl: 'https://example.test/ignored-original.jpg',
            storagePath: kPath,
            createdAt: DateTime.utc(2026, 5, 1),
          ),
          now: DateTime.utc(2026, 5, 1),
        ),
      )));
      await t.pumpAndSettle();

      expect(store.requestedKeys.single, kKey);
    });
  });

  // ── The embedded home feed ────────────────────────────────────────────────
  group('the feed under the calendar', () {
    Future<ScrollController> pumpHome(
      WidgetTester t, {
      required FeedRepository feed,
      required UserSearchRepository search,
      void Function(FeedItem item)? onOpenPost,
    }) async {
      t.view.physicalSize = const Size(400, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final ScrollController host = ScrollController();
      addTearDown(host.dispose);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: host,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TableCalendar<int>(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2100, 12, 31),
                  focusedDay: DateTime.utc(2026, 5, 15),
                  availableCalendarFormats: const <CalendarFormat, String>{
                    CalendarFormat.month: 'Month',
                  },
                  headerStyle: const HeaderStyle(
                      formatButtonVisible: false, titleCentered: true),
                ),
                const SizedBox(height: 8),
                HomeBuddyFeedSection(
                  scrollController: host,
                  feed: feed,
                  search: search,
                  onOpenProfile: (_) {},
                  onOpenPost: onOpenPost ?? (_) {},
                ),
              ],
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      return host;
    }

    Future<FakeFirebaseFirestore> seedFeed(int n) async {
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      for (int i = 0; i < n; i++) {
        await db
            .collection('users')
            .doc('me')
            .collection('feed')
            .doc('o__p$i')
            .set(<String, Object?>{
          'ownerUid': kOwner,
          'postId': 'p$i',
          'createdAt': Timestamp.fromDate(
              DateTime.utc(2026, 5, 1).subtract(Duration(hours: i))),
          'mediaType': MediaType.image,
          'smallUrl': 'https://firebasestorage.googleapis.com/v0/b/b/o/'
              'users%2Fowner-uid%2Fposts%2Fp$i%2Foriginal.jpg?alt=media&token=t',
          'storagePathOriginal': 'users/owner-uid/posts/p$i/original.jpg',
          'caption': 'caption $i',
        });
      }
      return db;
    }

    testWidgets('mounting it does not fetch the whole feed at once',
        (WidgetTester t) async {
      store.seedAll();
      final FakeFirebaseFirestore db = await seedFeed(12);
      await pumpHome(
        t,
        feed: FeedRepository(firestore: db, overrideUid: 'me'),
        search: UserSearchRepository(firestore: db),
      );

      expect(find.byType(FeedCard), findsNWidgets(12),
          reason: 'the cards themselves are all there');
      expect(store.requestedKeys, isNotEmpty,
          reason: 'the first card still loads by itself');
      expect(store.requestedKeys.length, lessThanOrEqualTo(4),
          reason: 'only what is on screen, or about to be, asks for media — '
              'got ${store.requestedKeys.length}');
    });

    testWidgets('later posts load as they come into view',
        (WidgetTester t) async {
      store.seedAll();
      final FakeFirebaseFirestore db = await seedFeed(12);
      await pumpHome(
        t,
        feed: FeedRepository(firestore: db, overrideUid: 'me'),
        search: UserSearchRepository(firestore: db),
      );
      final int atRest = store.requestedKeys.length;

      for (int i = 0; i < 6; i++) {
        await t.dragFrom(const Offset(200, 820), const Offset(0, -600));
        await t.pumpAndSettle();
      }

      expect(store.requestedKeys.length, greaterThan(atRest),
          reason: 'scrolling brings later posts in');
      expect(store.downloadKeys.toSet().length, store.downloadKeys.length,
          reason: 'and never downloads the same media twice');
    });

    testWidgets('the Buddy Hub feed and the home feed resolve media the same '
        'way', (WidgetTester t) async {
      store.seedAll();
      final FakeFirebaseFirestore db = await seedFeed(2);

      List<String> drawn(WidgetTester t) => t
          .widgetList<CachedProfileImage>(find.byType(CachedProfileImage))
          .map((CachedProfileImage i) =>
              '${i.cacheKey}|${i.url}|${i.storagePath}')
          .toList(growable: false);

      await pumpHome(
        t,
        feed: FeedRepository(firestore: db, overrideUid: 'me'),
        search: UserSearchRepository(firestore: db),
      );
      final List<String> home = drawn(t);

      // The Buddy Hub host: the same view, owning its own scroll.
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BuddyFeedView(
            feed: FeedRepository(firestore: db, overrideUid: 'me'),
            search: UserSearchRepository(firestore: db),
          ),
        ),
      ));
      await t.pumpAndSettle();

      expect(home, isNotEmpty);
      expect(drawn(t), home,
          reason: 'the same posts resolve to the same URL, cache identity and '
              'canonical path in both hosts');
    });

    testWidgets('paging and opening a post still work', (WidgetTester t) async {
      store.seedAll();
      final FakeFirebaseFirestore db = await seedFeed(12);
      FeedItem? opened;
      await pumpHome(
        t,
        feed: FeedRepository(firestore: db, overrideUid: 'me', pageSize: 3),
        search: UserSearchRepository(firestore: db),
        onOpenPost: (FeedItem i) => opened = i,
      );
      for (int i = 0; i < 20; i++) {
        await t.dragFrom(const Offset(200, 820), const Offset(0, -700));
        await t.pumpAndSettle();
      }
      expect(find.byType(FeedCard), findsNWidgets(12),
          reason: 'every page still arrives');

      await t.dragFrom(const Offset(200, 400), const Offset(0, 6000));
      await t.pumpAndSettle();
      await t.tap(find.byType(FeedCard).first);
      await t.pump();
      expect(opened?.postId, 'p0');
    });
  });

  // ── The first mount can precede a restored session ────────────────────────
  group('a feed that mounts before the account is ready', () {
    testWidgets('loads itself once the account arrives, with no Retry',
        (WidgetTester t) async {
      store.seedAll();
      final FakeFirebaseFirestore db = FakeFirebaseFirestore();
      await db
          .collection('users')
          .doc('me')
          .collection('feed')
          .doc('o__p1')
          .set(<String, Object?>{
        'ownerUid': kOwner,
        'postId': 'p1',
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 5, 1)),
        'mediaType': MediaType.image,
        'smallUrl': kStaleUrl,
        'storagePathOriginal': kPath,
        'caption': 'after sign-in',
      });

      final _LateAuth auth = _LateAuth();
      addTearDown(auth.dispose);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BuddyFeedView(
            feed: FeedRepository(firestore: db, auth: auth),
            search: UserSearchRepository(firestore: db),
          ),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.text('Nothing here yet'), findsNothing,
          reason: 'an unfinished sign-in is not an empty feed');

      auth.signIn('me');
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      await t.pumpAndSettle();

      expect(find.byType(FeedCard), findsOneWidget);
      expect(find.text('after sign-in'), findsOneWidget);
    });
  });
}

/// A store whose every operation the test decides, backed by real files in a
/// real directory — so "is it on disk?" stays a real question, and a second
/// instance over the same directory is a real restart.
class _TestStore implements ProfileImageStore {
  _TestStore(this._dir);

  final Directory _dir;

  final List<String> requestedKeys = <String>[];
  final List<String> downloadKeys = <String>[];
  final List<String> downloadUrls = <String>[];

  Object? _error;
  int _errorsLeft = 0;
  Duration _delay = Duration.zero;
  bool _seedAll = false;

  void fail(Object error, {int times = 1 << 30}) {
    _error = error;
    _errorsLeft = times;
  }

  void healthy() {
    _error = null;
    _errorsLeft = 0;
  }

  void delay(Duration d) => _delay = d;

  /// Pretend everything asked for is already on disk — for tests about WHICH
  /// media a card asks for, rather than about fetching it.
  void seedAll() => _seedAll = true;

  void seed(String key) => _write(key);

  void reset() {
    requestedKeys.clear();
    downloadKeys.clear();
    downloadUrls.clear();
  }

  File _fileFor(String key) =>
      File('${_dir.path}/${key.hashCode.toUnsigned(32)}.jpg');

  File _write(String key) {
    final File f = _fileFor(key)..createSync(recursive: true);
    f.writeAsBytesSync(_onePixelJpeg);
    return f;
  }

  @override
  Future<File?> cached(String url, {String? key}) async {
    final String id = key ?? url;
    requestedKeys.add(id);
    if (_seedAll) return _write(id);
    final File f = _fileFor(id);
    return f.existsSync() ? f : null;
  }

  @override
  Future<File> download(String url, {String? key}) async {
    final String id = key ?? url;
    downloadKeys.add(id);
    downloadUrls.add(url);
    if (_delay > Duration.zero) await Future<void>.delayed(_delay);
    final Object? err = _error;
    if (err != null && _errorsLeft > 0) {
      _errorsLeft--;
      if (_errorsLeft == 0) _error = null;
      throw err;
    }
    return _write(id);
  }

  @override
  Future<void> evict(String key) async {
    final File f = _fileFor(key);
    if (f.existsSync()) f.deleteSync();
  }
}

/// flutter_cache_manager's own failure shape, without importing its internals.
class _Status implements Exception {
  const _Status(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'HttpException: Invalid statusCode: $statusCode';
}

/// What package:http hands back when a connection dies under it: neither a
/// SocketException nor a status code.
class _Transport implements Exception {
  _Transport(this.message);
  final String message;
  @override
  String toString() =>
      'ClientException: $message, uri=https://example.test/a.jpg';
}

/// An account that arrives after the widget has already mounted.
class _LateAuth extends Fake implements FirebaseAuth {
  final StreamController<User?> _users = StreamController<User?>.broadcast();
  User? _current;

  void signIn(String uid) {
    _current = _FakeUser(uid);
    _users.add(_current);
  }

  void dispose() => _users.close();

  @override
  User? get currentUser => _current;

  @override
  Stream<User?> authStateChanges() => _users.stream;
}

class _FakeUser extends Fake implements User {
  _FakeUser(this.uid);
  @override
  final String uid;
}

/// The smallest valid JPEG the Flutter decoder accepts: 1x1, black.
final Uint8List _onePixelJpeg = Uint8List.fromList(<int>[
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
  0x00, 0x03, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03, 0x02, 0x02, 0x02, 0x03,
  0x03, 0x03, 0x03, 0x04, 0x06, 0x04, 0x04, 0x04, 0x04, 0x04, 0x08, 0x06,
  0x06, 0x05, 0x06, 0x09, 0x08, 0x0A, 0x0A, 0x09, 0x08, 0x09, 0x09, 0x0A,
  0x0C, 0x0F, 0x0C, 0x0A, 0x0B, 0x0E, 0x0B, 0x09, 0x09, 0x0D, 0x11, 0x0D,
  0x0E, 0x0F, 0x10, 0x10, 0x11, 0x10, 0x0A, 0x0C, 0x12, 0x13, 0x12, 0x10,
  0x13, 0x0F, 0x10, 0x10, 0x10, 0xFF, 0xC9, 0x00, 0x0B, 0x08, 0x00, 0x01,
  0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xCC, 0x00, 0x06, 0x00, 0x10,
  0x10, 0x05, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
  0xD2, 0xCF, 0x20, 0xFF, 0xD9,
]);
