import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/WES2_widgets/WES2_app_bar.dart';

/// Tests the REAL production [Wes2AppBar] — the exact widget `Wes2Screen`
/// renders — without mounting the full WES2 screen (no Firestore/Isar/
/// UserContext). Navigation behaviour itself is covered by
/// wes2_exit_coordinator_test.dart; here we assert the AppBar surfaces the
/// controls and forwards taps via onBack / onHome.

/// Serves a valid 1×1 PNG for any asset key so the GoodLift logo decodes in the
/// test environment (the real asset isn't bundled into the test rootBundle).
class _FakeAssetBundle extends CachingAssetBundle {
  static final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  @override
  Future<ByteData> load(String key) async {
    // Serve a valid empty asset manifest so AssetImage variant resolution
    // succeeds; serve a real 1×1 PNG for the logo itself.
    if (key.contains('AssetManifest')) {
      return const StandardMessageCodec().encodeMessage(<String, Object?>{})!;
    }
    return ByteData.view(_png.buffer);
  }
}

void main() {
  late int backCount;
  late int homeCount;
  late int undoCount;
  late int refreshCount;
  late int timerCount;
  late int templatesCount;
  late int deleteAllCount;

  Future<void> pumpBar(
    WidgetTester tester, {
    String? greeting = 'Viewing',
    String? username = 'athlete_jane',
    bool canUndo = true,
    bool pushedAboveAnotherRoute = false,
  }) async {
    backCount = 0;
    homeCount = 0;
    undoCount = 0;
    refreshCount = 0;
    timerCount = 0;
    templatesCount = 0;
    deleteAllCount = 0;

    final bar = Scaffold(
      appBar: Wes2AppBar(
        onBack: () => backCount++,
        onHome: () => homeCount++,
        greeting: greeting,
        username: username,
        canUndo: canUndo,
        onUndo: () => undoCount++,
        onRefresh: () => refreshCount++,
        onToggleTimer: () => timerCount++,
        onShowTemplates: () => templatesCount++,
        onDeleteAll: () => deleteAllCount++,
      ),
      body: const SizedBox.shrink(),
    );

    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: _FakeAssetBundle(),
        child: MaterialApp(
          // When requested, place the bar on a route pushed above a root route
          // so Navigator.canPop() is true — proving the Back button is rendered
          // by us, not by the AppBar's implied leading.
          home: pushedAboveAnotherRoute
              ? const Scaffold(body: Text('ROOT'))
              : bar,
          onGenerateRoute: pushedAboveAnotherRoute
              ? (_) => MaterialPageRoute<void>(builder: (_) => bar)
              : null,
        ),
      ),
    );

    if (pushedAboveAnotherRoute) {
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute<void>(builder: (_) => bar));
    }
    await tester.pumpAndSettle();
  }

  AppBar appBarWidget(WidgetTester tester) =>
      tester.widget<AppBar>(find.byType(AppBar));

  testWidgets('explicit Back button renders when Navigator.canPop() is false',
      (tester) async {
    await pumpBar(tester); // bar is the home route → canPop() is false
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.widgetWithIcon(IconButton, Icons.arrow_back), findsOneWidget);
  });

  testWidgets('explicit Back button also renders when canPop() is true',
      (tester) async {
    await pumpBar(tester, pushedAboveAnotherRoute: true);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isTrue);

    expect(find.byTooltip('Back'), findsOneWidget);
  });

  testWidgets('automaticallyImplyLeading is false', (tester) async {
    await pumpBar(tester);
    expect(appBarWidget(tester).automaticallyImplyLeading, isFalse);
  });

  testWidgets('tapping Back invokes onBack exactly once', (tester) async {
    await pumpBar(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(backCount, 1);
    expect(homeCount, 0);
  });

  testWidgets('logo has Home tooltip and GoodLift Home semantic label',
      (tester) async {
    await pumpBar(tester);
    expect(
      find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Home'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'GoodLift Home'),
      findsOneWidget,
    );
  });

  testWidgets('tapping the logo invokes onHome exactly once', (tester) async {
    await pumpBar(tester);
    // Tap the logo's interactive region (the InkWell wrapping the image).
    await tester.tap(
      find.ancestor(of: find.byType(Image), matching: find.byType(InkWell)),
    );
    await tester.pump();
    expect(homeCount, 1);
    expect(backCount, 0);
  });

  testWidgets('logo keeps a >=48x48 interactive area at ~original image size',
      (tester) async {
    await pumpBar(tester);

    // Interactive region (the tappable Semantics subtree) is at least 48x48.
    final region = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'GoodLift Home');
    final regionSize = tester.getSize(region);
    expect(regionSize.width, greaterThanOrEqualTo(48.0));
    expect(regionSize.height, greaterThanOrEqualTo(48.0));

    // The logo image keeps its original rendered height (44).
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.height, 44);
  });

  testWidgets('greeting, username, undo, refresh and overflow menu render',
      (tester) async {
    await pumpBar(tester);

    expect(find.text('Viewing'), findsOneWidget);
    expect(find.text('athlete_jane'), findsOneWidget);
    expect(find.widgetWithIcon(IconButton, Icons.undo), findsOneWidget);
    expect(find.widgetWithIcon(IconButton, Icons.auto_awesome), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    // Overflow menu items render and forward selections.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Timer'), findsOneWidget);
    expect(find.text('Templates'), findsOneWidget);
    expect(find.text('Delete Day'), findsOneWidget);

    await tester.tap(find.text('Templates'));
    await tester.pumpAndSettle();
    expect(templatesCount, 1);
  });

  testWidgets('undo is disabled when canUndo is false', (tester) async {
    await pumpBar(tester, canUndo: false);
    final undo = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.undo),
    );
    expect(undo.onPressed, isNull);
  });

  testWidgets('greeting block is hidden when greeting is null', (tester) async {
    await pumpBar(tester, greeting: null, username: null);
    expect(find.text('Viewing'), findsNothing);
    expect(find.text('athlete_jane'), findsNothing);
    // Core controls still present.
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });
}
