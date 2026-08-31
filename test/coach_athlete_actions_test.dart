import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/coach_home_screen.dart';

/// Tests the REAL production [CoachAthleteActions] - the exact trailing widget
/// the coach dashboard renders on each athlete row - without mounting
/// CoachHomeScreen (whose roster load needs Firestore, Auth and UserContext).
///
/// Covers the three-dot menu (copy email / copy username), that missing values
/// disable rather than crash, and that the pre-existing remove-athlete button
/// is untouched by the menu.

void main() {
  late List<MethodCall> clipboardCalls;
  late int removeCount;

  setUp(() {
    clipboardCalls = <MethodCall>[];
    removeCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardCalls.add(call);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget wrap({
    required String? email,
    required String? username,
    bool busy = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: CoachAthleteActions(
            email: email,
            username: username,
            onRemove: busy ? null : () => removeCount++,
          ),
        ),
      ),
    );
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  testWidgets('copies the athlete email and confirms it', (tester) async {
    await tester.pumpWidget(
      wrap(email: 'athlete@example.com', username: 'liftercam'),
    );
    await openMenu(tester);

    await tester.tap(find.text('Copy email'));
    await tester.pumpAndSettle();

    expect(clipboardCalls, hasLength(1));
    expect(clipboardCalls.single.arguments['text'], 'athlete@example.com');
    expect(find.text('Email copied'), findsOneWidget);
  });

  testWidgets('copies the athlete username and confirms it', (tester) async {
    await tester.pumpWidget(
      wrap(email: 'athlete@example.com', username: 'liftercam'),
    );
    await openMenu(tester);

    await tester.tap(find.text('Copy username'));
    await tester.pumpAndSettle();

    expect(clipboardCalls, hasLength(1));
    expect(clipboardCalls.single.arguments['text'], 'liftercam');
    expect(find.text('Username copied'), findsOneWidget);
  });

  testWidgets('a missing username disables its item and copies nothing',
      (tester) async {
    await tester.pumpWidget(
      wrap(email: 'athlete@example.com', username: null),
    );
    await openMenu(tester);

    final item = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Copy username'),
    );
    expect(item.enabled, isFalse);

    await tester.tap(find.text('Copy username'));
    await tester.pumpAndSettle();

    expect(clipboardCalls, isEmpty);
    expect(find.text('Username copied'), findsNothing);
  });

  testWidgets('a missing email disables its item and copies nothing',
      (tester) async {
    await tester.pumpWidget(wrap(email: null, username: 'liftercam'));
    await openMenu(tester);

    final item = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Copy email'),
    );
    expect(item.enabled, isFalse);

    await tester.tap(find.text('Copy email'));
    await tester.pumpAndSettle();

    expect(clipboardCalls, isEmpty);
    expect(find.text('Email copied'), findsNothing);
  });

  testWidgets('menu offers exactly the two copy actions', (tester) async {
    await tester.pumpWidget(
      wrap(email: 'athlete@example.com', username: 'liftercam'),
    );
    await openMenu(tester);

    expect(find.byType(PopupMenuItem<String>), findsNWidgets(2));
    expect(find.text('Copy email'), findsOneWidget);
    expect(find.text('Copy username'), findsOneWidget);
  });

  testWidgets('remove button still fires and is not part of the menu',
      (tester) async {
    await tester.pumpWidget(
      wrap(email: 'athlete@example.com', username: 'liftercam'),
    );

    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    expect(removeCount, 1);
    expect(clipboardCalls, isEmpty);
  });

  testWidgets('remove is disabled while busy but copying still works',
      (tester) async {
    await tester.pumpWidget(
      wrap(email: 'athlete@example.com', username: 'liftercam', busy: true),
    );

    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
    );
    expect(button.onPressed, isNull);

    await openMenu(tester);
    await tester.tap(find.text('Copy email'));
    await tester.pumpAndSettle();

    expect(removeCount, 0);
    expect(clipboardCalls.single.arguments['text'], 'athlete@example.com');
  });
}
