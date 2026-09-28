import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/top_sets_screen.dart';

void main() {
  testWidgets('tapping a Top Sets entry returns its workout date',
      (WidgetTester tester) async {
    final DateTime workoutDate = DateTime(2026, 4, 17);
    DateTime? selectedDate;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSetWorkoutTile(
            workoutDate: workoutDate,
            title: const Text('Bench Press, Barbell - 17-04-2026'),
            subtitle: const Text('120 kg x 5, RIR: 2'),
            onWorkoutSelected: (DateTime date) async => selectedDate = date,
          ),
        ),
      ),
    );

    expect(find.textContaining('17-04-2026'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('top-set-workout-2026-04-17')),
    );
    await tester.pump();

    expect(selectedDate, workoutDate);
  });

  testWidgets('entry stays non-interactive without a navigator callback',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSetWorkoutTile(
            workoutDate: DateTime(2026, 4, 18),
            title: const Text('Bench Press, Barbell - 18-04-2026'),
            subtitle: const Text('100 kg x 5, RIR: 1'),
          ),
        ),
      ),
    );

    final ListTile tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.onTap, isNull);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('duplicate taps wait for the first navigation to finish',
      (WidgetTester tester) async {
    final navigation = Completer<void>();
    int calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopSetWorkoutTile(
            workoutDate: DateTime(2026, 4, 17),
            title: const Text('Chin-Up - 17-04-2026'),
            subtitle: const Text('+20 kg x 5, RIR: 1'),
            onWorkoutSelected: (_) async {
              calls++;
              await navigation.future;
            },
          ),
        ),
      ),
    );

    final tile = find.byKey(
      const ValueKey<String>('top-set-workout-2026-04-17'),
    );
    await tester.tap(tile);
    await tester.pump();
    await tester.tap(tile);
    await tester.pump();

    expect(calls, 1);
    navigation.complete();
    await tester.pump();
  });
}
