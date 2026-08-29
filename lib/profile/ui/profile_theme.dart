/// Design tokens for the profile page.
///
/// GoodLift's own language: a deep navy ground, blue-grey surfaces, the brand's
/// light blue for action and cyan reserved for achievement. Typography is Monda,
/// the typeface the rest of the app already uses.
///
/// The LAYOUT takes its cues from what makes a photo-first profile easy to
/// scan — one large avatar, an identity block, then a dense three-column grid —
/// but every colour, weight, radius and icon here is GoodLift's.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ProfilePalette {
  /// Page ground.
  static const Color navy = Color(0xFF0B1220);

  /// Cards and wells sitting on [navy].
  static const Color surface = Color(0xFF17202E);

  /// Hairlines and dividers.
  static const Color outline = Color(0xFF2B3849);

  /// Primary action / links. The brand light blue.
  static const Color action = Color(0xFF03A9F4);

  /// Achievement accent. Used sparingly — a record, a proof badge, the story
  /// ring — so that seeing it always means "something was earned".
  static const Color accent = Color(0xFF18FFFF);

  static const Color textPrimary = Color(0xFFF2F6FA);
  static const Color textSecondary = Color(0xFF9FB0C4);
  static const Color textMuted = Color(0xFF6B7C93);

  static const Color danger = Color(0xFFE5534B);
  static const Color success = Color(0xFF3FBF7F);
}

class ProfileSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// The grid's inter-tile gap. Small on purpose: the media should read as one
  /// dense mosaic, not a list of cards.
  static const double gridGap = 2;

  static const double radius = 14;
  static const double radiusSmall = 8;
}

class ProfileText {
  static TextStyle username(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textPrimary,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      );

  static TextStyle bio(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textSecondary,
        fontSize: 13.5,
        height: 1.4,
      );

  static TextStyle link(BuildContext context) => bio(context).copyWith(
        color: ProfilePalette.action,
        decoration: TextDecoration.underline,
        decorationColor: ProfilePalette.action,
      );

  static TextStyle sectionTitle(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      );

  static TextStyle liftName(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w700,
      );

  static TextStyle recordValue(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      );

  static TextStyle recordLabel(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textMuted,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      );

  static TextStyle recordDetail(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textSecondary,
        fontSize: 11.5,
      );

  static TextStyle caption(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textMuted,
        fontSize: 11,
      );

  static TextStyle button(BuildContext context) => GoogleFonts.monda(
        color: ProfilePalette.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w700,
      );
}

/// A quiet pill used for status ("Saved", "Saved offline", "Proof attached").
class ProfilePill extends StatelessWidget {
  const ProfilePill({
    super.key,
    required this.label,
    this.icon,
    this.color = ProfilePalette.textSecondary,
    this.background,
  });

  final String label;
  final IconData? icon;
  final Color color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: GoogleFonts.monda(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}
