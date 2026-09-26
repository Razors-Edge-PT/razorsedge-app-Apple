/// The leaderboard category medal: a compact engraved metallic coin, drawn
/// entirely in vector (CustomPainter + gradients) so it is sharp at every
/// density and adds no asset to the bundle.
///
///   * circular coin with a darker outer rim and a subtle inner highlight ring
///   * diagonal metallic gradient on the face
///   * a small loop on top, drawn only where it stays legible
///   * a very restrained shadow
///   * the category code (BP, VP, OH, DL, SQ) engraved in the centre
///
/// Placement is the metal (gold / silver / bronze); the category is the code.
/// Neither colour nor the abbreviation is ever the only cue: every medal
/// carries full semantics, and tapping it opens [showMedalDetail] with the
/// full category name.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../profile/core/re_catalog.dart';
import '../profile/ui/profile_theme.dart';
import 'leaderboard_medals.dart';
import 'leaderboard_models.dart';

/// Light, mid, dark-rim and letter colours of one metal.
class MedalPalette {
  const MedalPalette(this.light, this.mid, this.rim, this.letter);

  final Color light;
  final Color mid;
  final Color rim;
  final Color letter;

  static const MedalPalette gold = MedalPalette(Color(0xFFFFE58A),
      Color(0xFFD8AD35), Color(0xFF8B6414), Color(0xFF3B2A05));
  static const MedalPalette silver = MedalPalette(Color(0xFFF5F7FA),
      Color(0xFFB8C0CA), Color(0xFF6D7783), Color(0xFF27303A));
  static const MedalPalette bronze = MedalPalette(Color(0xFFF0AD76),
      Color(0xFFB96832), Color(0xFF713818), Color(0xFF35180A));

  static MedalPalette of(MedalTier tier) => switch (tier) {
        MedalTier.gold => gold,
        MedalTier.silver => silver,
        MedalTier.bronze => bronze,
      };
}

/// Paints one coin into a square of side `size.shortestSide`.
class MedalPainter extends CustomPainter {
  const MedalPainter({required this.tier, required this.code, this.fontFamily});

  final MedalTier tier;
  final String code;

  /// The engraving's font; null is the platform's default.
  final String? fontFamily;

  /// Below this side the loop would be a smudge, so it is left out.
  static const double minLoopSize = 20;

  @override
  void paint(Canvas canvas, Size size) {
    final MedalPalette c = MedalPalette.of(tier);
    final double s = size.shortestSide;
    final bool loop = s >= minLoopSize;
    // The coin sits a little low so the loop fits inside the square.
    final double r = s * (loop ? 0.43 : 0.47);
    final Offset centre =
        Offset(size.width / 2, size.height / 2 + (loop ? s * 0.06 : 0));
    final Rect coin = Rect.fromCircle(center: centre, radius: r);

    // Very restrained shadow.
    canvas.drawCircle(
      centre.translate(0, s * 0.025),
      r,
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
    );

    if (loop) {
      final double loopR = s * 0.075;
      canvas.drawCircle(
        Offset(centre.dx, centre.dy - r - loopR * 0.35),
        loopR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, s * 0.045)
          ..color = c.rim,
      );
    }

    // Outer rim: the darker metal, lit from the top-left.
    canvas.drawCircle(
      centre,
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[c.mid, c.rim, c.rim],
          stops: const <double>[0, 0.55, 1],
        ).createShader(coin),
    );

    // Face: diagonal metallic gradient.
    final double face = r * 0.84;
    canvas.drawCircle(
      centre,
      face,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            c.light,
            c.mid,
            c.light.withValues(alpha: 0.9),
            c.mid
          ],
          stops: const <double>[0, 0.45, 0.7, 1],
        ).createShader(Rect.fromCircle(center: centre, radius: face)),
    );

    // Subtle inner highlight ring.
    canvas.drawCircle(
      centre,
      face * 0.86,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.6, s * 0.022)
        ..color = c.light.withValues(alpha: 0.55),
    );

    // Engraved code: a light lip below, the dark cut on top.
    final TextStyle base = TextStyle(
      fontFamily: fontFamily,
      fontSize: s * 0.3,
      fontWeight: FontWeight.w800,
      letterSpacing: s * 0.004,
      height: 1,
    );
    void letters(Color colour, Offset nudge) {
      final TextPainter tp = TextPainter(
        text: TextSpan(text: code, style: base.copyWith(color: colour)),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        maxLines: 1,
      )..layout(maxWidth: face * 2);
      tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2) + nudge);
    }

    letters(c.light.withValues(alpha: 0.7), Offset(0, s * 0.02));
    letters(c.letter, Offset.zero);
  }

  @override
  bool shouldRepaint(MedalPainter old) =>
      old.tier != tier || old.code != code || old.fontFamily != fontFamily;
}

/// A medal of [size] logical pixels (visible), with no interaction.
class MedalBadge extends StatelessWidget {
  const MedalBadge(
      {super.key,
      required this.tier,
      required this.code,
      this.size = 29,
      this.fontFamily});

  final MedalTier tier;
  final String code;
  final double size;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
            painter:
                MedalPainter(tier: tier, code: code, fontFamily: fontFamily)),
      );
}

/// Height of a medal's tap target: roomy, but it never overlaps a neighbour
/// (each target is exactly one medal pitch wide).
const double kMedalTapHeight = 44;

/// A row's medals, in the fixed order BP, VP, OH, DL, SQ. Sizes itself to the
/// width it gets: 29 px medals with 5 px gaps; 26 / 4 on narrow layouts;
/// wrapping only as a last resort. Nothing at all for no medals.
class MedalStrip extends StatelessWidget {
  const MedalStrip({super.key, required this.medals, required this.onTap});

  final List<LeaderboardMedal> medals;
  final void Function(LeaderboardMedal medal) onTap;

  static const double _size = 29;
  static const double _gap = 5;
  static const double _narrowSize = 26;
  static const double _narrowGap = 4;

  @override
  Widget build(BuildContext context) {
    if (medals.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
      final int n = medals.length;
      final bool roomy =
          !box.hasBoundedWidth || n * (_size + _gap) <= box.maxWidth;
      final double size = roomy ? _size : _narrowSize;
      final double gap = roomy ? _gap : _narrowGap;
      return Wrap(
        key: const ValueKey<String>('medal-strip'),
        children: <Widget>[
          for (final LeaderboardMedal m in medals)
            _MedalButton(
                medal: m, size: size, pitch: size + gap, onTap: () => onTap(m)),
        ],
      );
    });
  }
}

class _MedalButton extends StatelessWidget {
  const _MedalButton(
      {required this.medal,
      required this.size,
      required this.pitch,
      required this.onTap});

  final LeaderboardMedal medal;
  final double size;
  final double pitch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: medal.semanticsLabel,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey<String>(
            'leaderboard-medal-${medal.uid}-${medal.categoryKey}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: pitch,
          height: kMedalTapHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: MedalBadge(tier: medal.tier, code: medal.code, size: size),
          ),
        ),
      ),
    );
  }
}

/// The compact detail of one medal: placement, full category name and the
/// score it was awarded for. [athleteName] is the row's public name.
/// [recordSource] (all time only) resolves the winning set line, e.g.
/// "158.5 kg × 9", from the medallist's public showcase.
Future<void> showMedalDetail(
  BuildContext context, {
  required LeaderboardMedal medal,
  required String athleteName,
  Future<String?> Function(LeaderboardMedal medal)? recordSource,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ProfilePalette.surface,
    showDragHandle: true,
    builder: (BuildContext context) => MedalDetail(
      medal: medal,
      athleteName: athleteName,
      recordSource: recordSource,
    ),
  );
}

class MedalDetail extends StatelessWidget {
  const MedalDetail(
      {super.key,
      required this.medal,
      required this.athleteName,
      this.recordSource});

  final LeaderboardMedal medal;
  final String athleteName;
  final Future<String?> Function(LeaderboardMedal medal)? recordSource;

  @override
  Widget build(BuildContext context) {
    final TextStyle title = ProfileText.sectionTitle(context);
    final TextStyle body = ProfileText.bio(context);
    final TextStyle caption = ProfileText.caption(context);
    final String category = medal.categoryName;
    final String? exercise = medal.exerciseId == null
        ? null
        : reExerciseById(medal.exerciseId)?.displayName;
    final String? date =
        describeDateKey(medal.recordDateKey ?? medal.achievedDateKey);
    return SafeArea(
      child: Padding(
        key: const ValueKey<String>('medal-detail'),
        padding: const EdgeInsets.fromLTRB(
            ProfileSpacing.lg, 0, ProfileSpacing.lg, ProfileSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              ExcludeSemantics(
                  child:
                      MedalBadge(tier: medal.tier, code: medal.code, size: 44)),
              const SizedBox(width: ProfileSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('${medal.tier.label} — $category', style: title),
                    Text(athleteName,
                        style: caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: ProfileSpacing.md),
            if (!medal.isAllTime) ...<Widget>[
              Text(
                  '${describeMonthKey(medal.periodKey)} category total: ${medal.pointsLabel} RE Points',
                  style: body),
              const SizedBox(height: ProfileSpacing.xs),
              Text(
                'The sum of this athlete\'s winning $category score on each training day this month.',
                style: caption,
              ),
            ] else ...<Widget>[
              Text('Best single score: ${medal.pointsLabel} RE Points',
                  style: body),
              if (exercise != null) ...<Widget>[
                const SizedBox(height: ProfileSpacing.xs),
                _RecordLine(
                    exercise: exercise,
                    medal: medal,
                    recordSource: recordSource,
                    style: body),
              ],
              if (date != null) Text(date, style: caption),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecordLine extends StatefulWidget {
  const _RecordLine(
      {required this.exercise,
      required this.medal,
      required this.recordSource,
      required this.style});

  final String exercise;
  final LeaderboardMedal medal;
  final Future<String?> Function(LeaderboardMedal medal)? recordSource;
  final TextStyle style;

  @override
  State<_RecordLine> createState() => _RecordLineState();
}

class _RecordLineState extends State<_RecordLine> {
  // Fetched once per sheet, never on rebuild.
  late final Future<String?>? _source =
      widget.recordSource?.call(widget.medal).catchError((Object _) => null);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _source,
      builder: (BuildContext context, AsyncSnapshot<String?> snap) {
        final String? s = snap.data;
        return Text(s == null ? widget.exercise : '${widget.exercise} — $s',
            key: const ValueKey<String>('medal-record-line'),
            style: widget.style);
      },
    );
  }
}
