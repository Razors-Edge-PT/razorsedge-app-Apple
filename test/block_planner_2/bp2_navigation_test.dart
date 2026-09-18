import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/app_drawer.dart';
import 'package:localtest222/user_context.dart';
import 'package:provider/provider.dart';

/// The temporary Block Planner 2 entry sits right after the original Block
/// Planner entry, which stays exactly where and what it was.
void main() {
  Future<List<String>> drawerTitles(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(ChangeNotifierProvider<UserContext>.value(
      value: UserContext(actorUid: 'athlete-uid', isCoach: false),
      child: MaterialApp(
        home: Scaffold(
          key: scaffold,
          drawer: const AppDrawer(debugUserEmail: 'athlete@example.test'),
          body: const SizedBox.expand(),
        ),
      ),
    ));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    return tester
        .widgetList<ListTile>(find.descendant(
            of: find.byType(Drawer), matching: find.byType(ListTile)))
        .map((t) => (t.title as Text).data ?? '')
        .toList();
  }

  testWidgets('original Block Planner entry is present and unchanged',
      (tester) async {
    final titles = await drawerTitles(tester);
    expect(titles.where((t) => t == 'Block Planner').length, 1);
    final tile = tester
        .widget<ListTile>(find.widgetWithText(ListTile, 'Block Planner').first);
    expect((tile.leading as Icon).icon, Icons.extension);
  });

  testWidgets('Block Planner 2 is a separate entry directly after it',
      (tester) async {
    final titles = await drawerTitles(tester);
    final i = titles.indexOf('Block Planner');
    expect(titles[i + 1], 'Block Planner 2');
    expect(titles.where((t) => t == 'Block Planner 2').length, 1);
    expect(titles.indexOf('Planned Blocks'), i - 1);
    expect(titles.indexOf('BB3 Week Planner'), i + 2);
  });
}
