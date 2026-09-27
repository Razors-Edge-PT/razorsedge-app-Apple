/// The leaderboard category medal: a compact engraved metallic coin, drawn
/// entirely in vector (CustomPainter + gradients) so it is sharp at every
/// density and adds no asset to the bundle.
///
///   * circular coin with a darker outer rim and a subtle inner highlight ring
///   * diagonal metallic gradient on the face
///   * no loop, ribbon or attachment: the coin alone
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

  /// The coin's radius as a fraction of the square's side.
  static const double coinRadiusFraction = 0.47;

  /// The visible coin diameter painted into a square of [side].
  static double coinDiameterFor(double side) => side * coinRadiusFraction * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final MedalPalette c = MedalPalette.of(tier);
    final double r = size.shortestSide * coinRadiusFraction;
    // Every face detail is proportioned to the coin exactly as on the former
    // looped medal, whose coin radius was 0.43 of its square: `s` is that
    // medal's side for a coin of this radius. Only the loop is gone.
    final double s = r / 0.43;
    final Offset centre = Offset(size.width / 2, size.height / 2);
    final Rect coin = Rect.fromCircle(center: centre, radius: r);

    // Very restrained shadow.
    canvas.drawCircle(
      centre.translate(0, s * 0.025),
      r,
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
    );

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
      this.size = kMedalCoinSide,
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

/// The preferred square of a row medal. Without the loop the coin fills
/// 0.94 of its square, so 26.5 px keeps the visible coin at the 24.9 px the
/// former 29 px looped medal showed.
const double kMedalCoinSide = 26.5;

/// One row medal: the coin, a button with full semantics, and a tap that
/// opens its detail (never the profile). [MedalRowLayout] sizes the coin and
/// gives it a tap area wider and taller than the coin itself.
class MedalButton extends StatelessWidget {
  const MedalButton({super.key, required this.medal, required this.onTap});

  final LeaderboardMedal medal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: medal.semanticsLabel,
      // The action lives here because the GestureDetector's own semantics
      // are excluded with the painted code.
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey<String>(
            'leaderboard-medal-${medal.uid}-${medal.categoryKey}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: CustomPaint(
            painter: MedalPainter(tier: medal.tier, code: medal.code)),
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
