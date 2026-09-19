import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/block_planner_2/bp2_screen.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';

import 'bp2_test_support.dart';

/// Rendering of the three exercise groups, in particular that the
/// "All other exercises" category is always present and reachable.
void main() {
  const athlete = 'athlete-uid';

  Future<void> pump(WidgetTester tester, Harness h,
      {double bottomInset = 48}) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final uc = UserContext(actorUid: athlete, isCoach: false)
      ..debugSetBlockMeta(activeBlockId: 'active1');
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: uc,
      child: MaterialApp(
        // Edge-to-edge: content is drawn under the system navigation bar.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(bottom: bottomInset),
            viewPadding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: child!,
        ),
        home: Bp2Screen(controller: h.controller),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder scrollable() => find
      .descendant(
          of: find.byKey(const ValueKey('bp2-scroll')),
          matching: find.byType(Scrollable))
      .first;

  Future<void> scrollToEnd(WidgetTester tester) async {
    final state = tester.state<ScrollableState>(scrollable());
    // Lazy slivers refine their extent while scrolling; iterate to the end.
    for (var i = 0; i < 50; i++) {
      final p = state.position;
      if (p.pixels >= p.maxScrollExtent) break;
      p.jumpTo(p.maxScrollExtent);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<Harness> baseline() async {
    final h = Harness();
    await h.seedUser(athlete, username: 'richard');
    await h.seedBlock(athlete, 'active1', isActive: true);
    await h.seedBlock(athlete, 'old1', isActive: false);
    await h.seedBlock(athlete, 'future1', isActive: false);
    return h;
  }

  testWidgets(
      'populated All other exercises: shared and athlete-custom, '
      'alphabetical, after a long Other blocks list, reachable at the bottom',
      (tester) async {
    final h = await baseline();
    // 300 shared exercises; 200 of them live in other-block templates.
    for (var i = 0; i < 300; i++) {
      final n = i.toString().padLeft(3, '0');
      await h.seedShared('g$n', 'Exercise $n');
    }
    await h.seedCustom(athlete, 'cz', 'zz Athlete Custom');
    await h.seedTemplate(athlete, 't-active', 'active1', [
      {'exerciseId': 'g000', 'name': 'Exercise 000'},
    ]);
    await h.seedTemplate(athlete, 't-old', 'old1', [
      for (var i = 0; i < 120; i++)
        {'exerciseId': 'g${i.toString().padLeft(3, '0')}'},
    ]);
    await h.seedTemplate(athlete, 't-future', 'future1', [
      for (var i = 100; i < 200; i++)
        {'exerciseId': 'g${i.toString().padLeft(3, '0')}'},
    ]);
    // Not attached to any planned block → must not count as Other blocks.
    await h.seedTemplate(athlete, 't-loose', null, [
      for (var i = 250; i < 300; i++)
        {'exerciseId': 'g${i.toString().padLeft(3, '0')}'},
    ]);

    await pump(tester, h);
    final g = h.controller.grouping;
    expect(g.currentBlock.map((e) => e.id), ['g000']);
    expect(g.otherBlocks.length, 199, reason: 'g001–g199, deduped');
    expect(g.allOther.length, 101, reason: 'g200–g299 + athlete custom');
    expect(g.allOther.first.id, 'g200');
    expect(g.allOther.last.id, 'cz');
    expect(g.allOther.any((e) => e.id == 'g250'), isTrue,
        reason: 'unassigned template does not pull exercises into Other');

    await scrollToEnd(tester);
    // The last exercise of the final section is on screen and tappable,
    // clear of the 48 px system navigation inset.
    // At the absolute bottom the category heading is still on screen.
    expect(find.text('All other exercises').hitTestable(), findsOneWidget);
    expect(find.text('Exercises in templates').hitTestable(), findsNothing,
        reason: 'the previous category heading has scrolled away');
    final last = find.text('zz Athlete Custom');
    expect(last.hitTestable(), findsOneWidget);
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(915 - 48));

    // Scrolling back up reaches the All other exercises heading, which sits
    // after the whole Other blocks group and before its first exercise.
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('bp2-section-all-other')), -300,
        scrollable: scrollable());
    await tester.pumpAndSettle();
    expect(find.text('All other exercises'), findsOneWidget);
    expect(find.text('Exercise 199'), findsNothing,
        reason: 'no Other-blocks rows between the heading and its group');
  });

  testWidgets(
      'genuinely empty All other exercises still shows heading and '
      'empty state at the bottom', (tester) async {
    final h = await baseline();
    await h.seedShared('a', 'Alpha');
    await h.seedShared('b', 'Bravo');
    await h.seedCustom(athlete, 'c', 'Charlie Custom');
    await h.seedTemplate(athlete, 't1', 'active1', [
      {'exerciseId': 'a'}
    ]);
    await h.seedTemplate(athlete, 't2', 'old1', [
      {'exerciseId': 'b'},
      {'exerciseId': 'c'},
      {'exerciseId': 'a'},
    ]);

    await pump(tester, h);
    final g = h.controller.grouping;
    expect(g.currentBlock.map((e) => e.id), ['a']);
    expect(g.otherBlocks.map((e) => e.id), ['b', 'c']);
    expect(g.allOther, isEmpty);

    await scrollToEnd(tester);
    expect(find.text('All other exercises').hitTestable(), findsOneWidget);
    expect(find.text('No exercises outside planned blocks.').hitTestable(),
        findsOneWidget);
  });

  testWidgets('empty Current and Other groups keep clear empty states',
      (tester) async {
    final h = await baseline();
    await h.seedShared('a', 'Alpha');
    await pump(tester, h, bottomInset: 0);
    expect(find.text('Current block'), findsOneWidget);
    expect(find.text("No exercises in the current block's templates."),
        findsOneWidget);
    expect(find.text('Other blocks'), findsOneWidget);
    expect(
        find.text("No exercises in other blocks' templates."), findsOneWidget);
    expect(find.text('All other exercises'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets(
      'All other exercises uses the top-level heading style, not the '
      'blue subgroup style', (tester) async {
    final h = await baseline();
    await h.seedShared('a', 'Alpha');
    await pump(tester, h, bottomInset: 0);
    TextStyle? style(String t) => tester.widget<Text>(find.text(t)).style;
    expect(style('All other exercises'), style('Exercises in templates'));
    expect(style('All other exercises'), isNot(style('Other blocks')));
    // Order: templates heading → Current → Other → All other.
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Exercises in templates'), lessThan(y('Current block')));
    expect(y('Current block'), lessThan(y('Other blocks')));
    expect(y('Other blocks'), lessThan(y('All other exercises')));
  });
}
