// PinchZoomArea: photograph-style magnification for a scrolling screen body.
//
// Every gesture here is a genuine multi-pointer gesture driven through the
// real gesture arena (tester.startGesture per finger), not a call into the
// widget's state.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localtest222/pinch_zoom_area.dart';

class Probe {
  int presses = 0;
  final TextEditingController text = TextEditingController();
  final FocusNode focus = FocusNode();
  final ScrollController vertical = ScrollController();
  final ScrollController carousel = ScrollController();

  void dispose() {
    text.dispose();
    focus.dispose();
    vertical.dispose();
    carousel.dispose();
  }
}

/// A WES2/Home-shaped page: a vertical list holding a button, a text field, a
/// horizontal carousel and plenty of rows.
Widget page(Probe p, {bool zoom = true}) {
  final Widget list = ListView(
    controller: p.vertical,
    children: <Widget>[
      SizedBox(
        height: 60,
        child: Row(children: <Widget>[
          ElevatedButton(
            key: const ValueKey<String>('button'),
            onPressed: () => p.presses++,
            child: const Text('Press'),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 120,
            child: TextField(
              key: const ValueKey<String>('field'),
              controller: p.text,
              focusNode: p.focus,
            ),
          ),
        ]),
      ),
      SizedBox(
        height: 80,
        child: ListView(
          key: const ValueKey<String>('carousel'),
          controller: p.carousel,
          scrollDirection: Axis.horizontal,
          children: <Widget>[
            for (int i = 0; i < 12; i++)
              Container(
                width: 100,
                margin: const EdgeInsets.all(4),
                color: Colors.teal,
                child: Text('card $i'),
              ),
          ],
        ),
      ),
      for (int i = 0; i < 30; i++)
        Container(
          key: ValueKey<String>('tile-$i'),
          height: 60,
          color: i.isEven ? Colors.blueGrey : Colors.black,
          alignment: Alignment.centerLeft,
          child: Text('Row $i'),
        ),
    ],
  );
  return MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('Zoom')),
      body: zoom ? PinchZoomArea(child: list) : list,
    ),
  );
}

Future<Probe> pumpPage(WidgetTester tester,
    {bool zoom = true, Size size = const Size(360, 640)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final Probe p = Probe();
  addTearDown(p.dispose);
  await tester.pumpWidget(page(p, zoom: zoom));
  await tester.pumpAndSettle();
  return p;
}

PinchZoomAreaState zoomState(WidgetTester tester) =>
    tester.state<PinchZoomAreaState>(find.byType(PinchZoomArea));

/// Two real fingers, [fromHalf] either side of [center] along x, moved to
/// [toHalf] either side in [steps] frames. Returns the scale after each frame.
Future<List<double>> pinch(
  WidgetTester tester,
  Offset center, {
  required double fromHalf,
  required double toHalf,
  int steps = 12,
  Offset drift = Offset.zero,
}) async {
  final TestGesture a =
      await tester.startGesture(center - Offset(fromHalf, 0));
  final TestGesture b =
      await tester.startGesture(center + Offset(fromHalf, 0));
  await tester.pump();
  final List<double> scales = <double>[];
  for (int i = 1; i <= steps; i++) {
    final double t = i / steps;
    final double d = fromHalf + (toHalf - fromHalf) * t;
    final Offset c = center + drift * t;
    await a.moveTo(c - Offset(d, 0));
    await b.moveTo(c + Offset(d, 0));
    await tester.pump();
    if (find.byType(PinchZoomArea).evaluate().isNotEmpty) {
      scales.add(zoomState(tester).scale);
    }
  }
  await a.up();
  await b.up();
  await tester.pumpAndSettle();
  return scales;
}

Map<String, Rect> geometry(WidgetTester tester) => <String, Rect>{
      for (final String k in <String>[
        'button',
        'field',
        'carousel',
        'tile-0',
        'tile-3',
        'tile-6'
      ])
        k: tester.getRect(find.byKey(ValueKey<String>(k))),
    };

int transformLayers(WidgetTester tester) {
  int n = 0;
  void visit(Layer l) {
    if (l is TransformLayer) n++;
    if (l is ContainerLayer) {
      Layer? c = l.firstChild;
      while (c != null) {
        visit(c);
        c = c.nextSibling;
      }
    }
  }

  visit(tester.layers.first);
  return n;
}

void main() {
  group('at 100% nothing changes', () {
    testWidgets('geometry, scroll extent and layers match the unwrapped page',
        (WidgetTester tester) async {
      final Probe bare = await pumpPage(tester, zoom: false);
      final Map<String, Rect> before = geometry(tester);
      final double extent = bare.vertical.position.maxScrollExtent;
      final int layers = transformLayers(tester);

      final Probe wrapped = await pumpPage(tester);
      expect(geometry(tester), before);
      expect(wrapped.vertical.position.maxScrollExtent, extent);
      expect(transformLayers(tester), layers,
          reason: 'no transform is applied at 100%');
      expect(find.byKey(const ValueKey<String>('pinch-zoom-reset')),
          findsNothing);
    });

    testWidgets('one finger: scroll, tap, edit and carousel behave as before',
        (WidgetTester tester) async {
      final Probe p = await pumpPage(tester);
      await tester.drag(find.text('Row 2'), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(p.vertical.offset, greaterThan(200));
      p.vertical.jumpTo(0);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('button')));
      await tester.pumpAndSettle();
      expect(p.presses, 1);

      await tester.tap(find.byKey(const ValueKey<String>('field')));
      await tester.pumpAndSettle();
      expect(p.focus.hasFocus, isTrue);
      await tester.enterText(find.byKey(const ValueKey<String>('field')), '75');
      expect(p.text.text, '75');

      await tester.drag(find.text('card 1'), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(p.carousel.offset, greaterThan(100));

      // A horizontal drag elsewhere does not pan anything at 100%.
      await tester.drag(find.text('Row 4'), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(zoomState(tester).panX, 0);
      expect(zoomState(tester).scale, 1);
    });
  });

  group('pinch', () {
    testWidgets('spreading two fingers magnifies smoothly, up to 200%',
        (WidgetTester tester) async {
      await pumpPage(tester);
      final List<double> scales = await pinch(
          tester, const Offset(180, 400),
          fromHalf: 40, toHalf: 60);
      for (int i = 1; i < scales.length; i++) {
        expect(scales[i], greaterThanOrEqualTo(scales[i - 1]),
            reason: 'continuous, never jumping back');
      }
      expect(zoomState(tester).scale, closeTo(1.5, 0.02));
      // Further spreading stops at 200%.
      await pinch(tester, const Offset(180, 400), fromHalf: 40, toHalf: 140);
      expect(zoomState(tester).scale, kPinchZoomMaxScale);
    });

    testWidgets('the content under the fingers stays under the fingers',
        (WidgetTester tester) async {
      await pumpPage(tester);
      const Offset focal = Offset(240, 330);
      final Finder tile = find.byKey(const ValueKey<String>('tile-2'));
      final Rect r0 = tester.getRect(tile);
      expect(r0.contains(focal), isTrue);
      final Offset frac = Offset((focal.dx - r0.left) / r0.width,
          (focal.dy - r0.top) / r0.height);

      await pinch(tester, focal, fromHalf: 40, toHalf: 60);
      final Rect r1 = tester.getRect(tile);
      expect(r1.width, closeTo(r0.width * 1.5, 1));
      expect(r1.height, closeTo(r0.height * 1.5, 1));
      expect(r1.left + frac.dx * r1.width, closeTo(focal.dx, 2));
      expect(r1.top + frac.dy * r1.height, closeTo(focal.dy, 2));
    });

    testWidgets('pinching in at 100% never shrinks the page',
        (WidgetTester tester) async {
      await pumpPage(tester);
      final Map<String, Rect> before = geometry(tester);
      await pinch(tester, const Offset(180, 400), fromHalf: 100, toHalf: 30);
      expect(zoomState(tester).scale, 1);
      expect(geometry(tester), before);
    });

    testWidgets('zooming back out restores the original geometry exactly',
        (WidgetTester tester) async {
      final Probe p = await pumpPage(tester);
      final Map<String, Rect> before = geometry(tester);
      await pinch(tester, const Offset(200, 300), fromHalf: 40, toHalf: 70);
      expect(zoomState(tester).scale, greaterThan(1.6));
      await pinch(tester, const Offset(200, 300), fromHalf: 70, toHalf: 20);
      expect(zoomState(tester).scale, 1);
      expect(zoomState(tester).panX, 0);
      expect(p.vertical.offset, 0);
      expect(geometry(tester), before);
      expect(find.byKey(const ValueKey<String>('pinch-zoom-reset')),
          findsNothing);
    });

    testWidgets('a two-finger drag pans the magnified page',
        (WidgetTester tester) async {
      await pumpPage(tester);
      await pinch(tester, const Offset(180, 300), fromHalf: 40, toHalf: 80);
      final double pan = zoomState(tester).panX;
      await pinch(tester, const Offset(180, 300),
          fromHalf: 60, toHalf: 60, drift: const Offset(-80, 0));
      expect(zoomState(tester).panX, greaterThan(pan + 60));
      expect(zoomState(tester).scale, closeTo(2, 0.001));
    });
  });

  group('a pinch never acts on what is under the fingers', () {
    testWidgets('no button press, focus or text change',
        (WidgetTester tester) async {
      final Probe p = await pumpPage(tester);
      p.text.text = '60';
      final Offset button =
          tester.getCenter(find.byKey(const ValueKey<String>('button')));
      final Offset field =
          tester.getCenter(find.byKey(const ValueKey<String>('field')));
      // One finger on the button, the other on the field.
      final TestGesture a = await tester.startGesture(button);
      final TestGesture b = await tester.startGesture(field);
      await tester.pump();
      for (int i = 1; i <= 8; i++) {
        await a.moveTo(button - Offset(4.0 * i, 0));
        await b.moveTo(field + Offset(4.0 * i, 0));
        await tester.pump();
      }
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(zoomState(tester).scale, greaterThan(1));
      expect(p.presses, 0);
      expect(p.focus.hasFocus, isFalse);
      expect(p.text.text, '60');
    });

    testWidgets('a motionless two-finger touch is not two taps',
        (WidgetTester tester) async {
      final Probe p = await pumpPage(tester);
      final TestGesture a = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey<String>('button'))));
      final TestGesture b = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey<String>('field'))));
      await tester.pump(const Duration(milliseconds: 50));
      await a.up();
      await b.up();
      await tester.pumpAndSettle();
      expect(p.presses, 0);
      expect(p.focus.hasFocus, isFalse);
      expect(zoomState(tester).scale, 1);
    });
  });

  group('while magnified', () {
    testWidgets('one finger scrolls vertically and pans sideways',
        (WidgetTester tester) async {
      final Probe p = await pumpPage(tester);
      await pinch(tester, const Offset(180, 300), fromHalf: 40, toHalf: 80);
      expect(zoomState(tester).scale, 2);
      final double v0 = p.vertical.offset;
      final double pan0 = zoomState(tester).panX;

      await tester.dragFrom(const Offset(100, 500), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(p.vertical.offset, greaterThan(v0 + 50),
          reason: 'the page itself scrolls');

      await tester.dragFrom(const Offset(200, 450), const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(zoomState(tester).panX, lessThan(pan0));
      expect(zoomState(tester).scale, 2, reason: 'panning never rescales');
    });

    testWidgets('a horizontal carousel keeps its own drag',
        (WidgetTester tester) async {
      final Probe p = await pumpPage(tester);
      await pinch(tester, const Offset(60, 160), fromHalf: 30, toHalf: 45);
      final double pan = zoomState(tester).panX;
      final Offset card = tester.getCenter(find.text('card 1'));
      await tester.dragFrom(card, const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(p.carousel.offset, greaterThan(50));
      expect(zoomState(tester).panX, pan);
    });

    testWidgets('fields remain tappable and editable; tapping keeps the zoom',
        (WidgetTester tester) async {
      final Probe p = await pumpPage(tester);
      final Offset field =
          tester.getCenter(find.byKey(const ValueKey<String>('field')));
      await pinch(tester, field, fromHalf: 30, toHalf: 45);
      final double scale = zoomState(tester).scale;
      final double pan = zoomState(tester).panX;
      expect(scale, closeTo(1.5, 0.02));

      await tester.tap(find.byKey(const ValueKey<String>('field')));
      await tester.pumpAndSettle();
      expect(p.focus.hasFocus, isTrue);
      await tester.enterText(find.byKey(const ValueKey<String>('field')), '82.5');
      await tester.pumpAndSettle();
      expect(p.text.text, '82.5');
      expect(zoomState(tester).scale, scale);
      expect(zoomState(tester).panX, pan);

      // Pan back to the left edge, where the magnified button now sits, and
      // press it.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.dragFrom(const Offset(100, 450), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(zoomState(tester).panX, 0);
      await tester.tap(find.byKey(const ValueKey<String>('button')));
      await tester.pumpAndSettle();
      expect(p.presses, 1);
      expect(zoomState(tester).scale, scale);
      expect(p.text.text, '82.5', reason: 'the entered value survives');
    });

    testWidgets('the Reset pill returns to exactly 100%',
        (WidgetTester tester) async {
      final Probe p = await pumpPage(tester);
      final Map<String, Rect> before = geometry(tester);
      await pinch(tester, const Offset(180, 200), fromHalf: 40, toHalf: 70);
      expect(find.byKey(const ValueKey<String>('pinch-zoom-reset')),
          findsOneWidget);
      expect(find.text('175%  Reset'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('pinch-zoom-reset')));
      await tester.pumpAndSettle();
      expect(zoomState(tester).scale, 1);
      expect(zoomState(tester).panX, 0);
      expect(p.vertical.offset, 0);
      expect(geometry(tester), before);
      expect(find.byKey(const ValueKey<String>('pinch-zoom-reset')),
          findsNothing);
    });

    testWidgets('narrow phones: no overflow at any scale',
        (WidgetTester tester) async {
      for (final double width in <double>[320, 360]) {
        await pumpPage(tester, size: Size(width, 568));
        await pinch(tester, Offset(width / 2, 300),
            fromHalf: 40, toHalf: 80);
        expect(zoomState(tester).scale, 2);
        expect(tester.takeException(), isNull, reason: '${width}dp');
      }
    });
  });
}
