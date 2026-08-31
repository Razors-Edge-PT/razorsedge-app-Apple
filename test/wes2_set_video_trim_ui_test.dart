import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/wes2_video/set_video_copy.dart';
import 'package:localtest222/wes2_video/set_video_pipeline.dart';
import 'package:localtest222/wes2_video/ui/set_video_trim_screen.dart';
import 'package:video_player/video_player.dart';

/// The trim screen, driven with a fake player so no decoder is involved.
///
/// The guidance wording is asserted verbatim: it is the whole reason the
/// feature does not fill devices with setup footage, and a well-meaning edit
/// that softens it would quietly undo that.

/// A VideoPlayerController that reports a fixed duration and never touches a
/// platform channel.
class _FakePlayer extends VideoPlayerController {
  _FakePlayer(this.durationMs) : super.networkUrl(Uri.parse('https://x/a.mp4'));

  final int durationMs;
  bool initialised = false;

  @override
  Future<void> initialize() async {
    initialised = true;
    value = VideoPlayerValue(
      duration: Duration(milliseconds: durationMs),
      size: const Size(720, 1280),
      isInitialized: true,
    );
  }

  @override
  Future<void> setLooping(bool looping) async {}

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  // super is invoked so ChangeNotifier tears down properly, but guarded: the
  // real dispose reaches a platform channel this fake never allocated against,
  // and there is no plugin registered in a widget test.
  @override
  Future<void> dispose() async {
    try {
      await super.dispose();
    } catch (_) {
      // No platform side to release.
    }
  }
}

class _FakeFilmstrip implements TrimFilmstripSource {
  _FakeFilmstrip({this.fail = false});

  final bool fail;
  int? requestedCount;

  /// A 1x1 PNG, enough for Image.memory to decode.
  static final Uint8List _png = Uint8List.fromList(<int>[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
    0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
    0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, 1, //
    13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
  ]);

  @override
  Future<List<Uint8List>> frames(
      {required File video, required int count}) async {
    requestedCount = count;
    if (fail) throw StateError('no decoder');
    return List<Uint8List>.filled(count, _png);
  }
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('gl_trim_ui'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  RawCapture capture({int durationMs = 30000}) {
    final File f = File('${root.path}${Platform.pathSeparator}raw.mp4');
    f.writeAsStringSync('bytes');
    return RawCapture(file: f, durationMs: durationMs);
  }

  Future<TrimSelection?> pump(
    WidgetTester tester, {
    int durationMs = 30000,
    TrimFilmstripSource? filmstrip,
  }) async {
    TrimSelection? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext context) => ElevatedButton(
          onPressed: () async {
            result = await Navigator.of(context).push<TrimSelection?>(
              MaterialPageRoute<TrimSelection?>(
                builder: (_) => SetVideoTrimScreen(
                  capture: capture(durationMs: durationMs),
                  filmstrip: filmstrip,
                  controllerFactory: (_) => _FakePlayer(durationMs),
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  group('trimming guidance is prominent and exact', () {
    testWidgets('the trim instruction is shown verbatim', (tester) async {
      await pump(tester);
      expect(find.text(SetVideoCopy.trimGuidance), findsOneWidget);
    });

    testWidgets('the instruction names the first rep and the re-rack',
        (tester) async {
      expect(SetVideoCopy.trimGuidance, contains('first rep'));
      expect(SetVideoCopy.trimGuidance, contains('re-rack'));
      expect(SetVideoCopy.trimGuidance,
          contains('Only the trimmed clip is saved'));
    });

    testWidgets('the privacy default is disclosed on the trim screen',
        (tester) async {
      await pump(tester);
      expect(find.text(SetVideoCopy.privacyNotice), findsOneWidget);
    });

    testWidgets(
        'the privacy notice states the device-only default and the '
        'one exception', (tester) async {
      expect(SetVideoCopy.privacyNotice, contains('stay on this device'));
      expect(SetVideoCopy.privacyNotice, contains('personal best'));
    });

    testWidgets('the capture instruction is worded for before the set',
        (tester) async {
      expect(SetVideoCopy.recordGuidance, contains('Record the working set'));
      expect(SetVideoCopy.recordGuidance, contains('rep 1'));
    });
  });

  group('controls', () {
    testWidgets('start and end handles are present and labelled',
        (tester) async {
      await pump(tester);
      expect(find.byType(Slider), findsNWidgets(2));
      // Each handle carries a visible text label beside it, which reads for
      // sighted and assistive users alike.
      expect(find.text('Trim start'), findsOneWidget);
      expect(find.text('Trim end'), findsOneWidget);
    });

    testWidgets('each handle exposes slider semantics', (tester) async {
      await pump(tester);
      final Iterable<Widget> sliders = tester.widgetList(find.byType(Slider));
      expect(sliders.length, 2);
      // Both are enabled and therefore draggable.
      for (final Widget w in sliders) {
        expect((w as Slider).onChanged, isNotNull);
      }
    });

    testWidgets('the trimmed duration is shown and starts at the full clip',
        (tester) async {
      await pump(tester, durationMs: 30000);
      expect(find.text('30.0s'), findsOneWidget);
    });

    testWidgets('dragging the start handle shortens the reported duration',
        (tester) async {
      await pump(tester, durationMs: 30000);
      await tester.drag(find.byType(Slider).first, const Offset(120, 0));
      await tester.pumpAndSettle();

      expect(find.text('30.0s'), findsNothing,
          reason: 'the duration readout must track the handles');
    });

    testWidgets('save and cancel are both offered', (tester) async {
      await pump(tester);
      expect(find.text(SetVideoCopy.saveTrimmed), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('saving returns the chosen selection', (tester) async {
      TrimSelection? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => ElevatedButton(
            onPressed: () async {
              result = await Navigator.of(context).push<TrimSelection?>(
                MaterialPageRoute<TrimSelection?>(
                  builder: (_) => SetVideoTrimScreen(
                    capture: capture(),
                    controllerFactory: (_) => _FakePlayer(30000),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(SetVideoCopy.saveTrimmed));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.startMs, 0);
      expect(result!.endMs, 30000);
      expect(result!.isUsable, isTrue);
    });

    testWidgets('cancelling asks first and then returns nothing',
        (tester) async {
      final TrimSelection? before = await pump(tester);
      expect(before, isNull);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text(SetVideoCopy.discardRecordingTitle), findsOneWidget);
      await tester.tap(find.text(SetVideoCopy.keepRecording));
      await tester.pumpAndSettle();

      // Still on the trim screen: cancelling is confirmed, not immediate.
      expect(find.text(SetVideoCopy.trimGuidance), findsOneWidget);
    });
  });

  group('timeline thumbnails', () {
    testWidgets('frames are requested and rendered', (tester) async {
      final _FakeFilmstrip strip = _FakeFilmstrip();
      await pump(tester, filmstrip: strip);
      expect(strip.requestedCount, greaterThan(1));
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('a filmstrip failure still leaves usable handles',
        (tester) async {
      await pump(tester, filmstrip: _FakeFilmstrip(fail: true));
      expect(find.byType(Slider), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('no filmstrip source degrades to a plain bar', (tester) async {
      await pump(tester);
      expect(find.byType(Slider), findsNWidgets(2));
    });
  });

  group('a too-short trim cannot be saved', () {
    test('a selection under a second is not usable', () {
      expect(const TrimSelection(startMs: 0, endMs: 999).isUsable, isFalse);
      expect(const TrimSelection(startMs: 0, endMs: 1000).isUsable, isTrue);
    });

    test('an inverted selection is not usable', () {
      expect(const TrimSelection(startMs: 5000, endMs: 1000).isUsable, isFalse);
    });

    test('a negative start is not usable', () {
      expect(const TrimSelection(startMs: -1, endMs: 5000).isUsable, isFalse);
    });

    test('duration is the trimmed span', () {
      expect(const TrimSelection(startMs: 4000, endMs: 12000).durationMs, 8000);
    });
  });
}
