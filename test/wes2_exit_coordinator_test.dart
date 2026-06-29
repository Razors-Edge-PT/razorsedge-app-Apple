import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/wes2_exit_coordinator.dart';

/// Drives the REAL [Wes2ExitCoordinator] (the same instance production
/// `_exitToPreviousRoute` / `_exitDirectlyToHome` delegate to) against a REAL
/// Navigator. No routing logic is reimplemented here: the coordinator decides
/// pop vs popUntil vs replace, owns the guard, and performs the
/// focus-then-navigate ordering.
///
/// Note: the coordinator awaits `Future.delayed(Duration.zero)` to yield one
/// event-loop turn. In the widget-test zone that timer only fires when the
/// clock is pumped, so every test captures the future, pumps, then awaits it.
void main() {
  // dropFocus that mirrors production: release the primary focus.
  void dropPrimaryFocus() => FocusManager.instance.primaryFocus?.unfocus();

  // ── exitToPreviousRoute (Back / system Back) ───────────────────────────────

  testWidgets('Back: pushed WES2 (route beneath) pops exactly once',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('HOME-BENEATH')),
    ));

    // Push a stand-in WES2 route with a focused field (keyboard up).
    final fn = FocusNode();
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: TextField(focusNode: fn, autofocus: true),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.text('HOME-BENEATH'), findsNothing);

    final coordinator = Wes2ExitCoordinator();
    var homeMarked = false;
    final actionFuture = coordinator.exitToPreviousRoute(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => homeMarked = true,
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle(); // fires the focus-yield timer + settles nav
    final action = await actionFuture;

    expect(action, Wes2ExitAction.poppedToPrevious);
    expect(homeMarked, isTrue);
    expect(find.text('HOME-BENEATH'), findsOneWidget); // back on Home
    expect(tester.testTextInput.isVisible, isFalse); // keyboard dismissed
    fn.dispose();
  });

  testWidgets('Back: Home → BB3 → WES2 returns to BB3, not Home',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      initialRoute: '/home',
      routes: {'/home': (_) => const Scaffold(body: Text('HOME-ROUTE'))},
    ));
    // Home → BB3 → WES2 (BB3 + WES2 pushed unnamed, mirroring production).
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('BB3')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    final coordinator = Wes2ExitCoordinator();
    final actionFuture = coordinator.exitToPreviousRoute(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () {},
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.poppedToPrevious);
    expect(find.text('BB3'), findsOneWidget); // exactly one route popped
    expect(find.text('HOME-ROUTE'), findsNothing);
  });

  testWidgets('Back: restored-root WES2 (nothing beneath) creates /home once',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final fn = FocusNode();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      routes: {'/home': (_) => const Scaffold(body: Text('HOME-ROUTE'))},
      // Root WES2 stand-in — Navigator.canPop() is false.
      home: Scaffold(body: TextField(focusNode: fn, autofocus: true)),
    ));
    await tester.pumpAndSettle();
    expect(navKey.currentState!.canPop(), isFalse);
    expect(tester.testTextInput.isVisible, isTrue);

    final coordinator = Wes2ExitCoordinator();
    var homeMarked = false;
    final actionFuture = coordinator.exitToPreviousRoute(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => homeMarked = true,
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.replacedWithHome);
    expect(homeMarked, isTrue);
    expect(find.text('HOME-ROUTE'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    fn.dispose();
  });

  testWidgets('Back: repeated taps cannot double-pop or duplicate exit',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('HOME-BENEATH')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    final coordinator = Wes2ExitCoordinator();
    var markCount = 0;
    // Fire two exits synchronously (e.g. two fast back taps). The guard is set
    // before the first await, so the second is ignored.
    final f1 = coordinator.exitToPreviousRoute(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => markCount++,
      navigatorOf: () => navKey.currentState,
    );
    final f2 = coordinator.exitToPreviousRoute(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => markCount++,
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final results = await Future.wait([f1, f2]);

    expect(results, contains(Wes2ExitAction.poppedToPrevious));
    expect(results, contains(Wes2ExitAction.skippedAlreadyExiting));
    expect(markCount, 1); // exactly one real exit
    expect(find.text('HOME-BENEATH'), findsOneWidget); // single pop, not empty
  });

  testWidgets('Back: still works with no focused field (no fake nav skip)',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('HOME-BENEATH')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    final coordinator = Wes2ExitCoordinator();
    final actionFuture = coordinator.exitToPreviousRoute(
      dropFocus: dropPrimaryFocus, // nothing focused → no-op
      isMounted: () => true,
      markHomeActive: () {},
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.poppedToPrevious);
    expect(find.text('HOME-BENEATH'), findsOneWidget);
  });

  testWidgets('Back: unmount during focus-yield window cancels navigation',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('HOME-BENEATH')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    final coordinator = Wes2ExitCoordinator();
    var navLookedUp = false;
    final actionFuture = coordinator.exitToPreviousRoute(
      dropFocus: () {},
      isMounted: () => false, // unmounted before navigation
      markHomeActive: () => fail('must not mark home when unmounted'),
      navigatorOf: () {
        navLookedUp = true;
        return navKey.currentState;
      },
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.skippedUnmounted);
    expect(navLookedUp, isFalse);
    expect(find.text('WES2'), findsOneWidget); // still on WES2, no navigation
  });

  testWidgets('focus is dropped BEFORE navigation begins', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('HOME-BENEATH')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    final order = <String>[];
    final coordinator = Wes2ExitCoordinator();
    final actionFuture = coordinator.exitToPreviousRoute(
      dropFocus: () => order.add('dropFocus'),
      isMounted: () => true,
      markHomeActive: () => order.add('markHome'),
      navigatorOf: () {
        order.add('navigate');
        return navKey.currentState;
      },
    );
    await tester.pumpAndSettle();
    await actionFuture;

    // dropFocus must run first; navigation lookup only after the yield.
    expect(order.first, 'dropFocus');
    expect(order.indexOf('dropFocus'), lessThan(order.indexOf('navigate')));
  });

  testWidgets('one event-loop turn is yielded before navigation',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('HOME-BENEATH')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    var navigated = false;
    final coordinator = Wes2ExitCoordinator();
    final actionFuture = coordinator.exitToPreviousRoute(
      dropFocus: () {},
      isMounted: () => true,
      markHomeActive: () {},
      navigatorOf: () {
        navigated = true;
        return navKey.currentState;
      },
    );

    // Synchronously after the call: the yield has NOT elapsed, so navigation
    // has not happened yet.
    expect(navigated, isFalse);
    await tester.pumpAndSettle();
    await actionFuture;
    expect(navigated, isTrue);
  });

  // ── exitDirectlyToHome (GoodLift logo) ──────────────────────────────────────

  testWidgets('Logo: Home → WES2 returns to the existing Home route',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      initialRoute: '/home',
      routes: {'/home': (_) => const Scaffold(body: Text('HOME-ROUTE'))},
    ));
    final fn = FocusNode();
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: TextField(focusNode: fn, autofocus: true)),
    ));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    final coordinator = Wes2ExitCoordinator();
    var homeMarked = false;
    final actionFuture = coordinator.exitDirectlyToHome(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => homeMarked = true,
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.poppedToHome);
    expect(homeMarked, isTrue);
    expect(find.text('HOME-ROUTE'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    fn.dispose();
  });

  testWidgets(
      'Logo: Home → BB3 → WES2 returns directly to Home, removing BB3 + WES2',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      initialRoute: '/home',
      routes: {'/home': (_) => const Scaffold(body: Text('HOME-ROUTE'))},
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('BB3')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    final coordinator = Wes2ExitCoordinator();
    final actionFuture = coordinator.exitDirectlyToHome(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () {},
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.poppedToHome);
    expect(find.text('HOME-ROUTE'), findsOneWidget);
    expect(find.text('BB3'), findsNothing); // BB3 removed from above Home
    expect(find.text('WES2'), findsNothing);
    // Single Home instance, can no longer pop (Home is the root).
    expect(navKey.currentState!.canPop(), isFalse);
  });

  testWidgets('Logo: restored-root WES2 replaces WES2 with /home',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final fn = FocusNode();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      routes: {'/home': (_) => const Scaffold(body: Text('HOME-ROUTE'))},
      home: Scaffold(body: TextField(focusNode: fn, autofocus: true)),
    ));
    await tester.pumpAndSettle();
    expect(navKey.currentState!.canPop(), isFalse);

    final coordinator = Wes2ExitCoordinator();
    final actionFuture = coordinator.exitDirectlyToHome(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () {},
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.replacedWithHome);
    expect(find.text('HOME-ROUTE'), findsOneWidget);
    fn.dispose();
  });

  testWidgets(
      'Logo: unexpected non-Home root → replaces root with /home, not poppedToHome',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      // Root is NOT '/home' — an unexpected root the predicate must not mistake
      // for Home.
      initialRoute: '/unexpected-root',
      routes: {
        '/unexpected-root': (_) => const Scaffold(body: Text('UNEXPECTED')),
        '/home': (_) => const Scaffold(body: Text('HOME-ROUTE')),
      },
    ));
    // /unexpected-root → BB3 → WES2 (both pushed unnamed).
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('BB3')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    final coordinator = Wes2ExitCoordinator();
    final actionFuture = coordinator.exitDirectlyToHome(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () {},
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.replacedWithHome);
    expect(find.text('HOME-ROUTE'), findsOneWidget); // Home is the sole route
    expect(find.text('UNEXPECTED'), findsNothing); // unexpected root replaced
    expect(find.text('BB3'), findsNothing);
    expect(find.text('WES2'), findsNothing);
    expect(navKey.currentState!.canPop(), isFalse);
  });

  testWidgets('Logo: rapid repeated taps create no duplicate Home / exception',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      initialRoute: '/home',
      routes: {'/home': (_) => const Scaffold(body: Text('HOME-ROUTE'))},
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('BB3')),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('WES2')),
    ));
    await tester.pumpAndSettle();

    final coordinator = Wes2ExitCoordinator();
    var markCount = 0;
    final f1 = coordinator.exitDirectlyToHome(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => markCount++,
      navigatorOf: () => navKey.currentState,
    );
    final f2 = coordinator.exitDirectlyToHome(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => markCount++,
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final results = await Future.wait([f1, f2]);

    expect(results, contains(Wes2ExitAction.poppedToHome));
    expect(results, contains(Wes2ExitAction.skippedAlreadyExiting));
    expect(markCount, 1);
    expect(find.text('HOME-ROUTE'), findsOneWidget); // single Home
    expect(navKey.currentState!.canPop(), isFalse);
  });
}
