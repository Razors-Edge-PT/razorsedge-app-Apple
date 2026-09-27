/// The text-and-points part of a leaderboard row that has medals, laid out
/// inside the SAME vertical envelope the row had before medals existed.
///
/// A medal-less row is `[name | action] … points` in a Row whose height is
/// the tallest of: the minimum touch height, the name (plus the relationship
/// control beneath it), and the points column. This layout reproduces exactly
/// that height and never lets a medal add to it: the medals only take space
/// that is already free inside the envelope.
///
///   * No relationship control: the coins sit under the name.
///   * With a control (Add friend / Accept / Requested): the coins sit beside
///     the control, or on the name line (the name then ellipsizes), whichever
///     leaves the larger coin.
///
/// Coins are [kMedalCoinSide] where they fit. Where they do not, the gap
/// between them narrows first and only then do the coins shrink — every medal
/// stays visible, in its order, and nothing wraps or overflows. Each medal's
/// tap area spans its whole cell (coin plus half of each neighbouring gap,
/// full line height), so a smaller coin keeps a usable target.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'medal_badge.dart' show kMedalCoinSide;

class MedalRowLayout extends MultiChildRenderObjectWidget {
  /// Children, in order: [name], [points], the [medals], then [action].
  MedalRowLayout({
    super.key,
    required Widget name,
    required Widget points,
    required List<Widget> medals,
    Widget? action,
    required this.minContentHeight,
    this.nameMinWidth = 24,
  })  : hasAction = action != null,
        super(children: <Widget>[
          name,
          points,
          ...medals,
          if (action != null) action,
        ]);

  /// The row's minimum inner height (minimum touch height less padding).
  final double minContentHeight;
  final bool hasAction;

  /// When the coins share the name line, the name keeps at least this width
  /// (its first character and the ellipsis) so it never disappears.
  final double nameMinWidth;

  @override
  RenderMedalRowLayout createRenderObject(BuildContext context) =>
      RenderMedalRowLayout(
          hasAction: hasAction,
          minContentHeight: minContentHeight,
          nameMinWidth: nameMinWidth);

  @override
  void updateRenderObject(
      BuildContext context, RenderMedalRowLayout renderObject) {
    renderObject
      ..hasAction = hasAction
      ..minContentHeight = minContentHeight
      ..nameMinWidth = nameMinWidth;
  }
}

class MedalRowParentData extends ContainerBoxParentData<RenderBox> {}

/// Where the coins went, for tests and debugging.
enum MedalArea { underName, besideAction, nameLine }

/// A coin size and the gap between coins for one candidate area.
class MedalFit {
  const MedalFit(this.side, this.gap);
  final double side;
  final double gap;

  static const MedalFit none = MedalFit(0, 0);

  /// Preferred gap: 26.5 px squares 34 px apart, the pitch the former 29 px
  /// looped medals had with their 5 px gaps.
  static const double preferredGap = 7.5;
  static const double minGap = 2;

  double widthFor(int n) => n == 0 ? 0 : n * side + (n - 1) * gap;

  /// The largest coin (up to [kMedalCoinSide]) that fits [n] coins in
  /// [width] × [height]: the gap narrows before the coin does.
  static MedalFit fit(int n, double width, double height) {
    if (n <= 0 || width <= 0 || height <= 0) return none;
    double side = math.min(kMedalCoinSide, height);
    if (n == 1) return MedalFit(math.min(side, width), 0);
    double gap = preferredGap;
    if (n * side + (n - 1) * gap > width) {
      gap = math.max(minGap, (width - n * side) / (n - 1));
      if (n * side + (n - 1) * gap > width) {
        gap = minGap;
        side = math.max(0, (width - (n - 1) * gap) / n);
      }
    }
    return MedalFit(side, gap);
  }
}

class RenderMedalRowLayout extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, MedalRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, MedalRowParentData> {
  RenderMedalRowLayout(
      {required bool hasAction,
      required double minContentHeight,
      double nameMinWidth = 24})
      : _hasAction = hasAction,
        _minContentHeight = minContentHeight,
        _nameMinWidth = nameMinWidth;

  /// Between the name column and the points (as in the medal-less row).
  static const double pointsGap = 8;

  /// Between the relationship control or the name and the first coin.
  static const double medalLead = 4;

  bool _hasAction;
  set hasAction(bool v) {
    if (v == _hasAction) return;
    _hasAction = v;
    markNeedsLayout();
  }

  double _minContentHeight;
  set minContentHeight(double v) {
    if (v == _minContentHeight) return;
    _minContentHeight = v;
    markNeedsLayout();
  }

  /// On the name line the name keeps at least this much before ellipsizing.
  double _nameMinWidth;
  set nameMinWidth(double v) {
    if (v == _nameMinWidth) return;
    _nameMinWidth = v;
    markNeedsLayout();
  }

  // Result of the last layout.
  MedalArea? _area;
  MedalFit _fit = MedalFit.none;
  final List<Rect> _cells = <Rect>[];

  MedalArea? get debugArea => _area;
  double get debugCoinSide => _fit.side;
  List<Rect> get debugCells => List<Rect>.unmodifiable(_cells);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MedalRowParentData) {
      child.parentData = MedalRowParentData();
    }
  }

  RenderBox get _name => firstChild!;
  RenderBox get _points => childAfter(_name)!;
  RenderBox? get _action => _hasAction ? lastChild : null;

  List<RenderBox> get _medals {
    final List<RenderBox> out = <RenderBox>[];
    RenderBox? c = childAfter(_points);
    while (c != null && c != _action) {
      out.add(c);
      c = childAfter(c);
    }
    return out;
  }

  Offset _offsetOf(RenderBox c) => (c.parentData! as MedalRowParentData).offset;
  void _place(RenderBox c, Offset o) =>
      (c.parentData! as MedalRowParentData).offset = o;

  double _height(double name, double action, double points) =>
      <double>[_minContentHeight, name + action, points].reduce(math.max);

  // ── Intrinsics: exactly the medal-less row's; medals add nothing ─────────

  @override
  double computeMinIntrinsicWidth(double height) =>
      _points.getMinIntrinsicWidth(height) +
      pointsGap +
      math.max(_name.getMinIntrinsicWidth(height),
          _action?.getMinIntrinsicWidth(height) ?? 0);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _points.getMaxIntrinsicWidth(height) +
      pointsGap +
      math.max(_name.getMaxIntrinsicWidth(height),
          _action?.getMaxIntrinsicWidth(height) ?? 0);

  double _intrinsicHeight(double width) {
    final double pw =
        math.min(_points.getMaxIntrinsicWidth(double.infinity), width);
    final double slot = math.max(0, width - pointsGap - pw);
    return _height(
      _name.getMaxIntrinsicHeight(slot),
      _action?.getMaxIntrinsicHeight(slot) ?? 0,
      _points.getMaxIntrinsicHeight(pw),
    );
  }

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final double w = constraints.maxWidth;
    final Size ps = _points.getDryLayout(BoxConstraints(maxWidth: w));
    final double slot = math.max(0, w - pointsGap - ps.width);
    final BoxConstraints inner = BoxConstraints(maxWidth: slot);
    final double h = _height(_name.getDryLayout(inner).height,
        _action?.getDryLayout(inner).height ?? 0, ps.height);
    return constraints.constrain(Size(w, h));
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToHighestActualBaseline(baseline);

  // ── Layout ────────────────────────────────────────────────────────────────

  @override
  void performLayout() {
    final double w = constraints.maxWidth;
    final RenderBox name = _name;
    final RenderBox points = _points;
    final RenderBox? action = _action;
    final List<RenderBox> medals = _medals;
    final int n = medals.length;

    points.layout(BoxConstraints(maxWidth: w), parentUsesSize: true);
    final Size ps = points.size;
    final double slot = math.max(0, w - pointsGap - ps.width);
    final BoxConstraints inner = BoxConstraints(maxWidth: slot);
    name.layout(inner, parentUsesSize: true);
    action?.layout(inner, parentUsesSize: true);
    final double nameH = name.size.height;
    final double actionH = action?.size.height ?? 0;
    final double actionW = action?.size.width ?? 0;
    final double h =
        constraints.constrainHeight(_height(nameH, actionH, ps.height));

    // Candidate areas inside the envelope, and the coin each allows.
    final MedalArea area;
    final MedalFit fit;
    if (action == null) {
      area = MedalArea.underName;
      fit = MedalFit.fit(n, slot, h - nameH);
    } else {
      final MedalFit beside =
          MedalFit.fit(n, slot - actionW - medalLead, h - nameH);
      final MedalFit onName =
          MedalFit.fit(n, slot - _nameMinWidth - medalLead, h - actionH);
      if (onName.side > beside.side) {
        area = MedalArea.nameLine;
        fit = onName;
      } else {
        area = MedalArea.besideAction;
        fit = beside;
      }
    }
    _area = area;
    _fit = fit;
    final double side = fit.side;
    final double stripW = fit.widthFor(n);

    // Vertical placement: the name column is centred as in the medal-less
    // row; the coins take the free height of the line they sit on.
    double lineTop; // top of the line the coins sit on
    double lineH; // its height (the medals' tap height)
    double x0; // first coin's left edge
    double areaLeft;
    switch (area) {
      case MedalArea.underName:
        final double groupH = nameH + side;
        final double top = (h - groupH) / 2;
        _place(name, Offset(0, top));
        lineTop = top + nameH;
        lineH = h - lineTop;
        x0 = 0;
        areaLeft = 0;
      case MedalArea.besideAction:
        final double rowH = math.max(actionH, side);
        final double top = (h - nameH - rowH) / 2;
        _place(name, Offset(0, top));
        _place(action!, Offset(0, top + nameH + (rowH - actionH) / 2));
        lineTop = top + nameH;
        lineH = h - lineTop;
        x0 = actionW + medalLead;
        areaLeft = actionW + medalLead / 2;
      case MedalArea.nameLine:
        // The name gives up the room the coins need, then ellipsizes.
        name.layout(
            BoxConstraints(maxWidth: math.max(0, slot - stripW - medalLead)),
            parentUsesSize: true);
        final double nh = name.size.height;
        final double rowH = math.max(nh, side);
        final double top = (h - rowH - actionH) / 2;
        _place(name, Offset(0, top + (rowH - nh) / 2));
        _place(action!, Offset(0, top + rowH));
        lineTop = 0;
        lineH = top + rowH;
        x0 = name.size.width + medalLead;
        areaLeft = name.size.width + medalLead / 2;
    }

    _cells.clear();
    for (int i = 0; i < n; i++) {
      final RenderBox m = medals[i];
      m.layout(BoxConstraints.tight(Size.square(side)), parentUsesSize: true);
      final double x = x0 + i * (side + fit.gap);
      _place(m, Offset(x, lineTop + (lineH - side) / 2));
      final double half = n == 1 ? medalLead / 2 : fit.gap / 2;
      _cells.add(Rect.fromLTRB(
        math.max(areaLeft, x - half),
        lineTop,
        math.min(slot, x + side + half),
        lineTop + lineH,
      ));
    }

    _place(points, Offset(w - ps.width, (h - ps.height) / 2));
    size = constraints.constrain(Size(w, h));
  }

  // ── Paint and hit testing ─────────────────────────────────────────────────

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    // A tap anywhere in a medal's cell is that medal's, even off the coin.
    final List<RenderBox> medals = _medals;
    for (int i = 0; i < medals.length && i < _cells.length; i++) {
      if (!_cells[i].contains(position)) continue;
      final RenderBox m = medals[i];
      final Offset o = _offsetOf(m);
      final bool hit = result.addWithPaintOffset(
        offset: o,
        position: o + m.size.center(Offset.zero),
        hitTest: (BoxHitTestResult r, Offset p) => m.hitTest(r, position: p),
      );
      if (hit) return true;
    }
    return defaultHitTestChildren(result, position: position);
  }
}
