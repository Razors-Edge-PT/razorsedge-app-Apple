import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/wes2_exit_coordinator.dart';

/// Drives the REAL [Wes2ExitCoordinator] (the same instance production
/// `_exitToHome` delegates to) against a REAL Navigator. No routing logic is
/// reimplemented here: the coordinator decides pop vs replace, owns the guard,
/// and performs the focus-then-navigate ordering.
///
/// Note: the coordinator awaits `Future.delayed(Duration.zero)` to yield one
/// event-loop turn. In the widget-test zone that timer only fires when the
/// clock is pumped, so every test captures the future, pumps, then awaits it.
void main() {
  // dropFocus that mirrors production: release the primary focus.
  void dropPrimaryFocus() => FocusManager.instance.primaryFocus?.unfocus();

  testWidgets('pushed WES2 (route beneath) pops exactly once', (tester) async {
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
    final actionFuture = coordinator.exit(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => homeMarked = true,
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle(); // fires the focus-yield timer + settles nav
    final action = await actionFuture;

    expect(action, Wes2ExitAction.popped);
    expect(homeMarked, isTrue);
    expect(find.text('HOME-BENEATH'), findsOneWidget); // back on Home
    expect(tester.testTextInput.isVisible, isFalse); // keyboard dismissed
    fn.dispose();
  });

  testWidgets('restored-root WES2 (nothing beneath) creates /home once',
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
    final actionFuture = coordinator.exit(
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

  testWidgets('repeated back actions cannot double-pop or duplicate exit',
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
    final f1 = coordinator.exit(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => markCount++,
      navigatorOf: () => navKey.currentState,
    );
    final f2 = coordinator.exit(
      dropFocus: dropPrimaryFocus,
      isMounted: () => true,
      markHomeActive: () => markCount++,
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final results = await Future.wait([f1, f2]);

    expect(results, contains(Wes2ExitAction.popped));
    expect(results, contains(Wes2ExitAction.skippedAlreadyExiting));
    expect(markCount, 1); // exactly one real exit
    expect(find.text('HOME-BENEATH'), findsOneWidget); // single pop, not empty
  });

  testWidgets('exit still works with no focused field (no fake nav skip)',
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
    final actionFuture = coordinator.exit(
      dropFocus: dropPrimaryFocus, // nothing focused → no-op
      isMounted: () => true,
      markHomeActive: () {},
      navigatorOf: () => navKey.currentState,
    );
    await tester.pumpAndSettle();
    final action = await actionFuture;

    expect(action, Wes2ExitAction.popped);
    expect(find.text('HOME-BENEATH'), findsOneWidget);
  });

  testWidgets('unmount during focus-yield window cancels navigation',
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
    final actionFuture = coordinator.exit(
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
}
