import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';

/// Original appearance. The area never shrinks below it.
const double kPinchZoomMinScale = 1.0;

/// Largest magnification: 200%.
const double kPinchZoomMaxScale = 2.0;

/// A pinch released below this scale settles back to exactly 100%, so "almost
/// unzoomed" never leaves the screen subtly magnified or horizontally offset.
const double kPinchZoomSnapBelow = 1.03;

/// Photograph-style pinch-to-zoom for a whole screen region, such as the Home
/// page body or the WES2 workout list.
///
/// ## What it does
/// Spreading two fingers magnifies everything in [child] proportionally, from
/// 100% up to [maxScale], around the fingers' focal point. Content stays fully
/// interactive at every scale: it is real widgets drawn through a transform,
/// not a screenshot, so taps, text editing, selection handles and the keyboard
/// all keep working. While magnified, one finger pans sideways and two fingers
/// pan in any direction. Pinching back down to 100%, or tapping the small
/// "Reset" pill shown only while magnified, returns to the original
/// appearance. Double tap is deliberately NOT used: WES2 uses it to accept a
/// hint.
///
/// ## Why the child is laid out shorter, not just scaled
/// At scale `s` the child is laid out at the area's full width but at `1/s`
/// of its height, then painted `s` times larger. Vertically it therefore fills
/// the area exactly, so the screen's OWN vertical scroll view keeps scrolling
/// the whole (now magnified) page with a normal one-finger drag, and lazily
/// built lists such as WES2's stay lazy. Only the width overflows; that is the
/// sideways pan. Nothing is laid out at a larger font or different width, so
/// this is true magnification, not a responsive reflow.
///
/// ## Gestures
/// * One pointer: this area never claims it at 100%, so single-finger
///   scrolling, taps, long presses, double taps and horizontal carousels
///   behave exactly as before. When magnified, a horizontal drag that no
///   inner horizontal scroller claims pans the view.
/// * Two or more pointers: claimed the moment the second finger lands, which
///   cancels any pending tap, long press or text gesture under either finger.
///   A pinch therefore can never be read as two taps, select a calendar date,
///   press a button or change a workout value.
///
/// At exactly 100% the child receives exactly the constraints, position,
/// paint and hit-testing it would have had without this widget.
class PinchZoomArea extends StatefulWidget {
  const PinchZoomArea({
    super.key,
    required this.child,
    this.maxScale = kPinchZoomMaxScale,
  }) : assert(maxScale >= kPinchZoomMinScale);

  final Widget child;
  final double maxScale;

  @override
  State<PinchZoomArea> createState() => PinchZoomAreaState();
}

/// Public so tests (and only tests) can read the current magnification.
class PinchZoomAreaState extends State<PinchZoomArea>
    with TickerProviderStateMixin {
  double _scale = kPinchZoomMinScale;
  double _panX = 0;

  /// Current magnification: 1.0 is 100%.
  double get scale => _scale;

  /// Current horizontal pan, in logical pixels from the left edge.
  double get panX => _panX;

  final GlobalKey _layoutKey = GlobalKey(debugLabel: 'pinch-zoom-layout');

  late final AnimationController _resetCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final AnimationController _flingCtrl =
      AnimationController.unbounded(vsync: this);

  // ── Pinch session ─────────────────────────────────────────────────────────
  ScrollableState? _vertical;
  Offset? _lastFocal;
  double _baseScale = kPinchZoomMinScale;
  double _baseSpan = 0;
  double? _pendingVertical;

  // ── Reset animation ───────────────────────────────────────────────────────
  double _resetFrom = kPinchZoomMinScale;

  @override
  void initState() {
    super.initState();
    _resetCtrl.addListener(_onResetTick);
    _flingCtrl.addListener(_onFlingTick);
  }

  @override
  void dispose() {
    _resetCtrl.dispose();
    _flingCtrl.dispose();
    super.dispose();
  }

  _RenderPinchZoom? get _render =>
      _layoutKey.currentContext?.findRenderObject() as _RenderPinchZoom?;

  Size get _viewport {
    final _RenderPinchZoom? r = _render;
    return r != null && r.hasSize ? r.size : Size.zero;
  }

  Offset _toLocal(Offset global) {
    final _RenderPinchZoom? r = _render;
    return r == null || !r.attached ? global : r.globalToLocal(global);
  }

  /// The shallowest vertical scrollable inside the area: the screen's own
  /// page scroll. Horizontal scrollers (carousels, set rows) are skipped,
  /// along with everything inside them.
  ScrollableState? _findVerticalScrollable() {
    final BuildContext? root = _layoutKey.currentContext;
    if (root == null) return null;
    final List<Element> queue = <Element>[root as Element];
    for (int i = 0; i < queue.length && i < 5000; i++) {
      final Element e = queue[i];
      if (e is StatefulElement && e.state is ScrollableState) {
        final ScrollableState s = e.state as ScrollableState;
        if (axisDirectionToAxis(s.axisDirection) == Axis.vertical) return s;
        continue;
      }
      e.visitChildren(queue.add);
    }
    return null;
  }

  /// Moves to magnification [target] so that the content that was under
  /// [from] ends up under [to] (both in the area's own coordinates). With
  /// `from == to` that is a zoom about a fixed focal point; with an unchanged
  /// scale it is a two-finger pan.
  void _moveTo(double target, Offset from, Offset to) {
    final Size view = _viewport;
    if (view.isEmpty) return;
    final double s0 = _scale;
    final double s1 = target.clamp(kPinchZoomMinScale, widget.maxScale);

    // Horizontal: the area pans the magnified content itself.
    final double contentX = (_panX + from.dx) / s0;
    final double p1 =
        (contentX * s1 - to.dx).clamp(0.0, view.width * (s1 - 1)).toDouble();

    // Vertical: the screen's own scroll view keeps the content under the
    // focal point by scrolling its (unscaled) content coordinates.
    final ScrollableState? scrollable = _vertical;
    if (scrollable != null && scrollable.mounted) {
      final ScrollPosition pos = scrollable.position;
      if (pos.hasPixels && pos.hasContentDimensions) {
        final double laidOut = _render?.laidOutScale ?? s0;
        final double contentY = pos.pixels + from.dy / s0;
        // The scroll viewport is the area's height / scale, so the maximum
        // extent grows by exactly the height the viewport loses.
        final double newMax =
            pos.maxScrollExtent + view.height / laidOut - view.height / s1;
        final double v1 = (contentY - to.dy / s1)
            .clamp(pos.minScrollExtent, math.max(pos.minScrollExtent, newMax))
            .toDouble();
        if (v1 != pos.pixels) {
          if (v1 <= pos.maxScrollExtent) {
            _pendingVertical = null;
            pos.jumpTo(v1);
          } else {
            // Beyond today's extent: only reachable once the shorter viewport
            // has been laid out, so apply it straight after this frame.
            final bool scheduled = _pendingVertical != null;
            _pendingVertical = v1;
            if (!scheduled) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final double? v = _pendingVertical;
                _pendingVertical = null;
                if (v == null || !mounted || !scrollable.mounted) return;
                final ScrollPosition p = scrollable.position;
                p.jumpTo(v.clamp(p.minScrollExtent, p.maxScrollExtent));
              });
            }
          }
        }
      }
    }

    if (s1 != _scale || p1 != _panX) {
      setState(() {
        _scale = s1;
        _panX = p1;
      });
    }
  }

  void _stopAnimations() {
    _resetCtrl.stop();
    _flingCtrl.stop();
  }

  // ── Pinch ─────────────────────────────────────────────────────────────────

  void _onPinchStart(Offset focalGlobal, double span) {
    _stopAnimations();
    _vertical ??= _findVerticalScrollable();
    _baseScale = _scale;
    _baseSpan = span;
    _lastFocal = _toLocal(focalGlobal);
  }

  void _onPinchUpdate(Offset focalGlobal, double span) {
    final Offset? from = _lastFocal;
    if (from == null) return;
    final Offset to = _toLocal(focalGlobal);
    final double target =
        _baseSpan > 1 && span > 1 ? _baseScale * span / _baseSpan : _scale;
    _moveTo(target, from, to);
    _lastFocal = to;
  }

  void _onPinchEnd() {
    final Offset? last = _lastFocal;
    _lastFocal = null;
    if (_scale < kPinchZoomSnapBelow && _scale != kPinchZoomMinScale) {
      final Offset f = last ?? _viewport.center(Offset.zero);
      _moveTo(kPinchZoomMinScale, f, f);
    }
    _vertical = null;
  }

  // ── One-finger sideways pan while magnified ───────────────────────────────

  double get _maxPan => math.max(0, _viewport.width * (_scale - 1));

  void _onPanDown(DragDownDetails _) => _flingCtrl.stop();

  void _onPanUpdate(DragUpdateDetails d) {
    final double p = (_panX - d.delta.dx).clamp(0.0, _maxPan).toDouble();
    if (p != _panX) setState(() => _panX = p);
  }

  void _onPanEnd(DragEndDetails d) {
    final double v = -d.velocity.pixelsPerSecond.dx;
    if (v.abs() < 50) return;
    _flingCtrl.value = _panX;
    _flingCtrl.animateWith(FrictionSimulation(0.135, _panX, v));
  }

  void _onFlingTick() {
    final double p = _flingCtrl.value.clamp(0.0, _maxPan).toDouble();
    if (p != _flingCtrl.value) _flingCtrl.stop();
    if (p != _panX) setState(() => _panX = p);
  }

  // ── Reset to 100% ─────────────────────────────────────────────────────────

  /// Animates back to 100%, keeping the centre of the view steady.
  void resetZoom() {
    if (_scale == kPinchZoomMinScale && _panX == 0) return;
    _flingCtrl.stop();
    _vertical = _findVerticalScrollable();
    _resetFrom = _scale;
    _resetCtrl.forward(from: 0);
  }

  void _onResetTick() {
    final Offset c = _viewport.center(Offset.zero);
    final double t = Curves.easeOut.transform(_resetCtrl.value);
    final double s = _resetFrom + (kPinchZoomMinScale - _resetFrom) * t;
    _moveTo(_resetCtrl.isCompleted ? kPinchZoomMinScale : s, c, c);
    if (_resetCtrl.isCompleted) _vertical = null;
  }

  @override
  Widget build(BuildContext context) {
    final bool zoomed = _scale > kPinchZoomMinScale;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      // Gestures stay out of the semantics tree: screen readers already have
      // their own magnification, and the reset pill is a labelled button.
      excludeFromSemantics: true,
      gestures: <Type, GestureRecognizerFactory>{
        _PinchGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<_PinchGestureRecognizer>(
          () => _PinchGestureRecognizer(debugOwner: this),
          (_PinchGestureRecognizer r) => r
            ..onStart = _onPinchStart
            ..onUpdate = _onPinchUpdate
            ..onEnd = _onPinchEnd,
        ),
        // Only while magnified: at 100% this area adds nothing that could
        // compete with a one-finger gesture.
        if (zoomed)
          HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<
              HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(debugOwner: this),
            (HorizontalDragGestureRecognizer r) => r
              ..onDown = _onPanDown
              ..onUpdate = _onPanUpdate
              ..onEnd = _onPanEnd,
          ),
      },
      child: Stack(
        // Passthrough: the child sees exactly the constraints it had before.
        fit: StackFit.passthrough,
        children: <Widget>[
          _PinchZoomLayout(
            key: _layoutKey,
            scale: _scale,
            panX: _panX,
            child: widget.child,
          ),
          if (zoomed)
            Positioned(
              left: 8,
              bottom: 8,
              child: _ResetZoomPill(
                percent: (_scale * 100).round(),
                onPressed: resetZoom,
              ),
            ),
        ],
      ),
    );
  }
}

/// The small, unmagnified pill that returns the area to 100%.
class _ResetZoomPill extends StatelessWidget {
  const _ResetZoomPill({required this.percent, required this.onPressed});

  final int percent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Zoomed to $percent percent. Reset zoom to 100 percent',
      excludeSemantics: true,
      child: Material(
        key: const ValueKey<String>('pinch-zoom-reset'),
        color: Colors.black.withValues(alpha: 0.72),
        shape: const StadiumBorder(
          side: BorderSide(color: Colors.white24),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.zoom_out, size: 18, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    '$percent%  Reset',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Gesture recognizer ──────────────────────────────────────────────────────

typedef _PinchCallback = void Function(Offset focalGlobal, double span);

/// Claims a gesture only when two or more pointers are down, and claims it
/// immediately, so nothing under the fingers also sees a tap.
///
/// While only one pointer is down it stays undecided and never claims it, so
/// the deepest recognizer (a scroll view, a button, a text field) wins exactly
/// as it would have without this widget. If that one pointer is already owned
/// (a scroll in progress), a second finger does not start a pinch either.
class _PinchGestureRecognizer extends OneSequenceGestureRecognizer {
  _PinchGestureRecognizer({super.debugOwner});

  _PinchCallback? onStart;
  _PinchCallback? onUpdate;
  VoidCallback? onEnd;

  final Map<int, Offset> _positions = <int, Offset>{};
  bool _pinching = false;

  Offset get _focal {
    Offset sum = Offset.zero;
    for (final Offset p in _positions.values) {
      sum += p;
    }
    return sum / _positions.length.toDouble();
  }

  /// Mean distance of the pointers from their focal point.
  double get _span {
    final Offset f = _focal;
    double total = 0;
    for (final Offset p in _positions.values) {
      total += (p - f).distance;
    }
    return total / _positions.length;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _positions[event.pointer] = event.position;
    _maybeBegin();
  }

  void _maybeBegin() {
    if (_positions.length < 2) return;
    // Win every tracked pointer's arena now: the competing tap, long press,
    // drag and text-selection recognizers under BOTH fingers are rejected.
    resolve(GestureDisposition.accepted);
    _pinching = true;
    // Re-baseline whenever the set of fingers changes, so adding or lifting a
    // third finger never makes the view jump.
    onStart?.call(_focal, _span);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      if (_positions.containsKey(event.pointer)) {
        _positions[event.pointer] = event.position;
        if (_pinching) onUpdate?.call(_focal, _span);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _removePointer(event.pointer);
    }
    stopTrackingIfPointerNoLongerDown(event);
  }

  void _removePointer(int pointer) {
    if (_positions.remove(pointer) == null) return;
    if (!_pinching) return;
    if (_positions.length >= 2) {
      onStart?.call(_focal, _span);
    } else {
      _pinching = false;
      onEnd?.call();
    }
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    _removePointer(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _positions.clear();
    if (_pinching) {
      _pinching = false;
      onEnd?.call();
    }
  }

  @override
  String get debugDescription => 'pinch zoom';
}

// ── Layout / paint / hit testing ────────────────────────────────────────────

class _PinchZoomLayout extends SingleChildRenderObjectWidget {
  const _PinchZoomLayout({
    super.key,
    required this.scale,
    required this.panX,
    super.child,
  });

  final double scale;
  final double panX;

  @override
  _RenderPinchZoom createRenderObject(BuildContext context) =>
      _RenderPinchZoom(scale: scale, panX: panX);

  @override
  void updateRenderObject(BuildContext context, _RenderPinchZoom renderObject) {
    renderObject
      ..scale = scale
      ..panX = panX;
  }
}

/// Lays its child out at full width and 1/scale height, then paints and hit
/// tests it through `translate(-pan, 0) * scale(scale)`, clipped to its own
/// bounds. At scale 1 with no pan it behaves exactly like [RenderProxyBox].
class _RenderPinchZoom extends RenderProxyBox {
  _RenderPinchZoom({required double scale, required double panX})
      : _scale = scale,
        _panX = panX;

  double _scale;
  set scale(double value) {
    if (value == _scale) return;
    _scale = value;
    markNeedsLayout();
  }

  double _panX;
  set panX(double value) {
    if (value == _panX) return;
    _panX = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  /// The scale the child was last laid out for.
  double laidOutScale = 1;

  final LayerHandle<ClipRectLayer> _clipHandle = LayerHandle<ClipRectLayer>();
  final LayerHandle<TransformLayer> _transformHandle =
      LayerHandle<TransformLayer>();

  bool get _isIdentity => _scale == 1.0 && _effectivePan == 0.0;

  double get _effectivePan => hasSize
      ? _panX.clamp(0.0, math.max(0.0, size.width * (_scale - 1))).toDouble()
      : 0.0;

  Matrix4 get _transform => Matrix4.translationValues(-_effectivePan, 0, 0)
    ..multiply(Matrix4.diagonal3Values(_scale, _scale, 1));

  @override
  void performLayout() {
    final RenderBox? c = child;
    laidOutScale = _scale;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    if (_scale == 1.0) {
      c.layout(constraints, parentUsesSize: true);
      size = c.size;
      return;
    }
    final BoxConstraints inner = constraints.hasBoundedHeight
        ? constraints.copyWith(
            minHeight: constraints.minHeight / _scale,
            maxHeight: constraints.maxHeight / _scale,
          )
        : constraints;
    c.layout(inner, parentUsesSize: true);
    size = constraints.constrain(Size(c.size.width, c.size.height * _scale));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? c = child;
    if (c == null) return;
    if (_isIdentity) {
      _clipHandle.layer = null;
      _transformHandle.layer = null;
      context.paintChild(c, offset);
      return;
    }
    _clipHandle.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (PaintingContext clipped, Offset o) {
        _transformHandle.layer = clipped.pushTransform(
          needsCompositing,
          o,
          _transform,
          (PaintingContext inner, Offset io) => inner.paintChild(c, io),
          oldLayer: _transformHandle.layer,
        );
      },
      oldLayer: _clipHandle.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? c = child;
    if (c == null) return false;
    if (_isIdentity) return super.hitTestChildren(result, position: position);
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (BoxHitTestResult r, Offset p) => c.hitTest(r, position: p),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (!_isIdentity) transform.multiply(_transform);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _isIdentity ? null : Offset.zero & size;

  @override
  void dispose() {
    _clipHandle.layer = null;
    _transformHandle.layer = null;
    super.dispose();
  }
}
